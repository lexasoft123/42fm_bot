module RateLimiter
  # All Suno-family task types share the 'suno' bucket so the cap applies
  # whether the agent calls compose_song, add_vocals, cover_audio, or cover_art.
  TASK_TYPES = {
    'image' => %w[image_generate],
    'suno'  => %w[suno_generate suno_add_vocals suno_cover_audio suno_cover_art]
  }.freeze

  RATE_LIMIT_REPLIES = {
    'image' => [
      "Не части, %{mins} мин жди ещё.",
      "Харэ спамить, следующая картинка через %{mins} мин.",
      "Охади, художник хуев. Через %{mins} мин.",
      "Лимит исчерпан. Следующая картинка через %{mins} мин, жди.",
    ],
    'suno' => [
      "Не гони, следующая песня через %{mins} мин.",
      "Харэ спамить, через %{mins} мин. сочиню ещё.",
      "Лимит исчерпан. Подожди %{mins} мин., меломан хуев.",
      "Всё, харэ. Следующая песня через %{mins} мин.",
    ]
  }.freeze

  # Resolve the rate-limit bucket for a (chat, service, role) triple.
  #   - Non-admin: per-chat chat.rate_limits[service] → global default → hardcoded.
  #   - Admin: the MORE PERMISSIVE of the per-chat bucket and the admin override
  #     (auth.rate_limits.admin[service]). So a super-admin RAISING their own cap
  #     via the /admin menu applies, but a restrictive per-chat/config-seeded
  #     value can't drop an admin below the admin override. Falls through to the
  #     global default / hardcoded when neither is set.
  # NOTE: menu edits and config seeds both live in chat.rate_limits (written by
  # Chat.sync_from_config!), so they're indistinguishable here — hence "more
  # permissive" rather than "the per-chat value always wins".
  # Counters stay per-chat-shared (the chat counter increments for everyone).
  def self.limit_for(chat_id, service, role: nil)
    chat     = Chat.find_by(chat_id: chat_id)
    per_chat = parse_rate_limits(chat&.rate_limits)&.dig(service)

    if role.to_s == 'admin'
      admin_limit = Settings.auth.dig('rate_limits', 'admin', service)
      return more_permissive(per_chat, admin_limit) if admin_limit
    end
    per_chat || Settings.auth.dig('rate_limits', service) || { 'max' => 1, 'window_minutes' => 20 }
  end

  # The bucket allowing higher throughput (max per minute) wins; nil loses.
  def self.more_permissive(a, b)
    return b unless a
    return a unless b
    rate = ->(l) { l['max'].to_f / [l['window_minutes'].to_f, 0.01].max }
    rate.call(a) >= rate.call(b) ? a : b
  end

  def self.parse_rate_limits(json)
    return nil if json.nil? || json.to_s.empty?
    JSON.parse(json)
  rescue JSON::ParserError
    nil
  end

  def self.exceeded?(chat_id, service, role: nil)
    limit      = limit_for(chat_id, service, role: role)
    task_types = TASK_TYPES[service]
    window     = limit['window_minutes'] * 60
    count      = BackgroundTask
                   .where(task_type: task_types, chat_id: chat_id)
                   .where('created_at > ?', Time.now - window)
                   .count
    count >= limit['max']
  end

  def self.minutes_until_free(chat_id, service, role: nil)
    limit      = limit_for(chat_id, service, role: role)
    task_types = TASK_TYPES[service]
    window     = limit['window_minutes'] * 60
    oldest     = BackgroundTask
                   .where(task_type: task_types, chat_id: chat_id)
                   .where('created_at > ?', Time.now - window)
                   .order(:created_at)
                   .first
    return 0 unless oldest
    [((oldest.created_at + window - Time.now) / 60).ceil, 1].max
  end

  def self.reply(chat_id, service, role: nil)
    mins     = minutes_until_free(chat_id, service, role: role)
    template = RATE_LIMIT_REPLIES[service].sample
    template % { mins: mins }
  end
end

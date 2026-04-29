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
  # Priority order:
  #   1. role == 'admin' AND Settings.auth['rate_limits']['admin'][service] set
  #      → admin global override (e.g. 10x the regular cap).
  #   2. Per-chat chat.rate_limits[service] → set via the admin menu.
  #   3. Settings.auth['rate_limits'][service] → global default from settings.
  #   4. Hard-coded fallback { max: 1, window_minutes: 20 }.
  #
  # Counters remain per-chat-shared: an admin's higher cap means they can
  # keep acting after regular users have exhausted theirs (correct semantics —
  # the chat counter still increments, but the admin's limit allows more).
  def self.limit_for(chat_id, service, role: nil)
    if role.to_s == 'admin'
      admin_limit = Settings.auth.dig('rate_limits', 'admin', service)
      return admin_limit if admin_limit
    end
    chat = Chat.find_by(chat_id: chat_id)
    per_chat = parse_rate_limits(chat&.rate_limits)&.dig(service)
    per_chat ||
      Settings.auth.dig('rate_limits', service) ||
      { 'max' => 1, 'window_minutes' => 20 }
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

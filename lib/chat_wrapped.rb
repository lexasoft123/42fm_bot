# Deterministic weekly chat stats digest («Chat Wrapped») — pure DB
# aggregation, no LLM. Used by the weekly_wrapped background task
# (auto-post) and the «бот итоги» command. Output is plain text (the
# command path runs it through MessageSender's Markdown sanitizer, the
# handler path sends raw — so no Markdown markup here).
module ChatWrapped
  SUNO_TYPES = %w[suno_generate suno_add_vocals suno_cover_audio].freeze

  module_function

  def generate(chat_id, since_seconds: 7 * 86_400)
    since = Time.now - since_seconds

    user_msgs = Message.where(chat_id: chat_id, role: 'user').where('created_at >= ?', since)
    total_msgs = user_msgs.count
    top_uid, top_count = user_msgs.where.not(user_uid: nil).group(:user_uid).count.max_by { |_, c| c }

    images = BackgroundTask.where(chat_id: chat_id, task_type: 'image_generate', status: 'done')
                           .where('created_at >= ?', since).to_a
    commissioner_uid, commissioner_count =
      images.map { |t| t.params_hash['user_uid'] }.compact.tally.max_by { |_, c| c }

    songs = BackgroundTask.where(chat_id: chat_id, task_type: SUNO_TYPES, status: 'done')
                          .where('created_at >= ?', since).count

    funniest = Message.top_reacted(chat_id, since: since_seconds, limit: 1, scope: :all).first
    rules = Agent::Scratchpad.rules(chat_id)

    lines = ['📊 Итоги недели 42FM', '']
    lines << "💬 Сообщений: #{total_msgs}"
    lines << "🗣 Главный трещатель: #{user_label(top_uid)} (#{top_count})" if top_uid
    img_line = "🎨 Картинок нарисовано: #{images.size}"
    img_line += " (главный заказчик: #{user_label(commissioner_uid)}, #{commissioner_count})" if commissioner_uid
    lines << img_line
    lines << "🎵 Песен сочинено: #{songs}"
    lines << "📜 Правил в уставе: #{rules.size}" if rules.any?
    if funniest
      body = funniest.body.to_s.strip
      body = body[0, 120] + '…' if body.length > 120
      author = funniest.role == 'bot' ? 'Жзяцля' : user_label(funniest.user_uid)
      lines << "🔥 Самое огненное (#{funniest.reactions_count} реакций): «#{body}» — #{author}"
    end
    lines.join("\n")
  end

  def user_label(uid)
    u = uid && User.find_by(uid: uid)
    return "uid#{uid}" unless u
    full = [u.first_name, u.last_name].compact.map { |s| s.to_s.strip }.reject(&:empty?).join(' ')
    full.empty? ? (u.name.to_s.strip.empty? ? "uid#{uid}" : u.name) : full
  end
end

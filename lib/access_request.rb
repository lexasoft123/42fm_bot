# /start access-request flow for unauthorized PRIVATE chats. Called by
# BotDispatcher when a message fails the allowlist check — instead of the
# blanket silent drop, a private-chat /start files a request: the chats row
# is created (authorized: false, titled via Chat.label_from_telegram) and
# every super-admin gets a DM with inline ✅/❌ buttons (handled by the
# admin-menu callback router: adm:req_accept / adm:req_decline).
#
# Deliberately private-only: group adds must not be able to buzz the admins
# — authorizing a group stays a deliberate act in the /admin menu. Any
# non-/start text from unauthorized chats keeps the historical silence.
# Anti-spam: an existing unauthorized row means the request is already filed
# (or was declined) — the user gets a "pending" reply, admins are NOT
# re-notified.
module AccessRequest
  # Accepts bare /start, /start@botname, and deep-link payloads
  # ("/start ref123" from t.me/bot?start=ref123 taps).
  START_RE = %r{\A/start(?:@\w+)?(?:\s.*)?\z}

  module_function

  def maybe_handle(bot, message)
    return unless message.chat&.type == 'private'
    return unless message.text.to_s.match?(START_RE)

    chat_id = message.chat.id
    label   = Chat.label_from_telegram(message.chat) || "uid#{chat_id}"
    already_filed = ActiveRecord::Base.connection_pool.with_connection do
      Chat.where(chat_id: chat_id).exists?
    end
    Chat.touch_seen(chat_id, title: label, type: 'private')

    if already_filed
      send_text(bot, chat_id, 'Заявка уже на рассмотрении. Жди решения админов.')
      return
    end

    send_text(bot, chat_id, 'Заявка на доступ отправлена админам. Жди решения.')
    notify_admins(bot, chat_id, label)
    LOGGER.info "[chat=#{chat_id}] AccessRequest: filed for #{label}" if defined?(LOGGER)
  rescue => e
    LOGGER.warn "[chat=#{message.chat&.id}] AccessRequest: #{e.class}: #{e.message}" if defined?(LOGGER)
  end

  def notify_admins(bot, chat_id, label)
    kb = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [[
      Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Принять',  callback_data: "adm:req_accept:#{chat_id}"),
      Telegram::Bot::Types::InlineKeyboardButton.new(text: '❌ Отклонить', callback_data: "adm:req_decline:#{chat_id}"),
    ]])
    Settings.auth['super_admin_uids'].to_a.each do |uid|
      bot.api.sendMessage(chat_id: uid, text: "📨 Заявка на доступ: #{label} (id: #{chat_id})", reply_markup: kb)
    rescue => e
      LOGGER.warn "AccessRequest: notify #{uid} failed: #{e.class}: #{e.message}" if defined?(LOGGER)
    end
  end

  def send_text(bot, chat_id, text)
    bot.api.sendMessage(chat_id: chat_id, text: text)
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] AccessRequest reply failed: #{e.class}: #{e.message}" if defined?(LOGGER)
  end
end

module BotDispatcher
  module_function

  def dispatch(bot, update, radio: nil)
    case update
    when Telegram::Bot::Types::Message
      handle_message(bot, update, radio: radio)
    when Telegram::Bot::Types::CallbackQuery
      AdminMenu::CallbackHandler.handle(bot, update)
    else
      LOGGER.debug "[BotDispatcher] ignored update class #{update.class}"
    end
  end

  def handle_message(bot, message, radio: nil)
    return unless message.from
    chat_id = message.chat.id
    msg_text = message.text || message.caption
    LOGGER.debug "[chat=#{chat_id}] @#{message.from.username}: #{msg_text}"
    LOGGER.debug "[chat=#{chat_id}] chat_seen: title=#{message.chat.title.inspect} type=#{message.chat.type}"

    return unless authorized?(message)

    Chat.touch_seen(chat_id, title: message.chat.title, type: message.chat.type) rescue nil
    MessageResponder.new({ bot: bot, message: message, radio: radio }).respond
  rescue => e
    # Localise per-message faults so one bad update doesn't bounce the entire
    # bot.listen loop into the outer 5s retry-from-scratch cycle. MessageResponder
    # has its own internal rescue, but construction itself (e.g. user save) can
    # raise before that fires.
    LOGGER.error "[chat=#{message.chat.id rescue '?'}] BotDispatcher#handle_message: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
  end

  # Super-admin private chats bypass the chats-table allowlist so /admin works
  # even when the row doesn't exist yet (first-time deploy of super_admin_uids)
  # AND can never be locked out of the menu by a misclick.
  def authorized?(message)
    super_admins = Settings.auth['super_admin_uids'].to_a
    if super_admins.include?(message.from&.id) && message.chat.type == 'private'
      return true
    end
    Chat.where(chat_id: message.chat.id, authorized: true).exists?.tap do |ok|
      LOGGER.warn "[chat=#{message.chat.id}] unauthorized chat" unless ok
    end
  end
end

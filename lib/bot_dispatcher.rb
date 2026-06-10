module BotDispatcher
  module_function

  def dispatch(bot, update, radio: nil)
    case update
    when Telegram::Bot::Types::Message
      handle_message(bot, update, radio: radio)
    when Telegram::Bot::Types::CallbackQuery
      AdminMenu::CallbackHandler.handle(bot, update)
    when Telegram::Bot::Types::MessageReactionCountUpdated
      handle_reaction_count(update)
    when Telegram::Bot::Types::MessageReactionUpdated
      handle_reaction(update)
    else
      LOGGER.debug "[BotDispatcher] ignored update class #{update.class}"
    end
  end

  # Authoritative aggregate: Telegram periodically sends the total reaction
  # count per message. Overwrites (never increments) — self-heals any drift
  # the best-effort per-user delta path accumulates.
  def handle_reaction_count(update)
    return unless reaction_authorized?(update)
    count = update.reactions.to_a.sum(&:total_count)
    ActiveRecord::Base.connection_pool.with_connection do
      Message.where(chat_id: update.chat.id, message_id: update.message_id)
             .update_all(reactions_count: count)
    end
  rescue => e
    LOGGER.warn "[chat=#{update.chat.id rescue '?'}] handle_reaction_count: #{e.class}: #{e.message}"
  end

  # Per-user delta (needs the bot to be a group admin to be delivered).
  # new_reaction/old_reaction are the user's FULL current/previous reaction
  # sets (Telegram coalesces), so the size diff is the per-user delta:
  # swap 👍→❤️ = 0, add a 2nd = +1, remove all = -size. `user` can be nil
  # (anonymous actor_chat) — we only need the delta, not the identity.
  # Best-effort, never authoritative; reconciled by handle_reaction_count.
  def handle_reaction(update)
    return unless reaction_authorized?(update)
    delta = update.new_reaction.to_a.size - update.old_reaction.to_a.size
    return if delta.zero?
    ActiveRecord::Base.connection_pool.with_connection do
      Message.where(chat_id: update.chat.id, message_id: update.message_id)
             .update_all(['reactions_count = MAX(0, reactions_count + ?)', delta])
    end
  rescue => e
    LOGGER.warn "[chat=#{update.chat.id rescue '?'}] handle_reaction: #{e.class}: #{e.message}"
  end

  # Reaction updates carry no `from`/chat-type, so the message-oriented
  # authorized? (super-admin private-chat shortcut included) doesn't apply.
  def reaction_authorized?(update)
    Chat.where(chat_id: update.chat.id, authorized: true).exists?
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

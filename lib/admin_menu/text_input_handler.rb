module AdminMenu
  module TextInputHandler
    module_function

    # Returns true if the input was consumed by the menu (caller should stop
    # further dispatch); false to fall through to normal command dispatch.
    def handle(bot, message, user)
      text = message.text.to_s.strip
      uid = user.uid
      chat_id = message.chat.id

      if text.casecmp?('/cancel') || text.casecmp?('отмена')
        Session.clear_awaiting_input(uid)
        bot.api.sendMessage(chat_id: chat_id, text: 'Отменено.')
        return true
      end

      return false if text.start_with?('/')
      return false if text =~ /\A(?:бот[,]?\s+|жпт|балаболь)/i

      payload = Session.awaiting_input(uid)
      unless payload
        Session.clear_awaiting_input(uid)
        return false
      end

      case payload[:kind]
      when :rate_limit
        process_rate_limit(bot, message, uid, payload, text)
      else
        Session.clear_awaiting_input(uid)
        bot.api.sendMessage(chat_id: chat_id, text: 'Неизвестный тип ввода. Отменено.')
      end
      true
    end

    def process_rate_limit(bot, message, uid, payload, text)
      chat_id = message.chat.id
      target_chat_id = payload[:chat_id]
      bucket = payload[:bucket]
      parts = text.split(',').map(&:strip)
      bad = lambda {
        bot.api.sendMessage(chat_id: chat_id,
                            text: '❌ формат: max,window_minutes (оба целые > 0). Отмена: /cancel')
      }

      return bad.call unless parts.size == 2 && parts.all? { |p| p.match?(/\A\d+\z/) }
      max = parts[0].to_i
      win = parts[1].to_i
      return bad.call unless max.positive? && win.positive?

      chat = Chat.find_by(chat_id: target_chat_id)
      unless chat
        Session.clear_awaiting_input(uid)
        bot.api.sendMessage(chat_id: chat_id, text: "❌ чат #{target_chat_id} не найден")
        return
      end

      begin
        chat.update_rate_limits!(bucket, max: max, window_minutes: win)
      rescue ArgumentError => e
        bot.api.sendMessage(chat_id: chat_id, text: "❌ #{e.message}")
        return
      end

      Session.clear_awaiting_input(uid)
      bot.api.sendMessage(chat_id: chat_id, text: "✓ сохранено: #{bucket} max=#{max}, окно=#{win}мин")

      session = Session.for(uid)
      menu_message_id = session[:message_id]
      if menu_message_id
        view_response = Views.chat_limits(chat_id: target_chat_id)
        begin
          bot.api.editMessageText(
            chat_id: chat_id,
            message_id: menu_message_id,
            text: view_response[:text],
            reply_markup: view_response[:reply_markup],
          )
        rescue => e
          LOGGER.warn "[admin_menu] post-input redraw failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end

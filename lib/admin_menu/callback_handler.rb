module AdminMenu
  module CallbackHandler
    module_function

    def handle(bot, query)
      uid = query.from&.id
      chat_id = query.message&.chat&.id
      message_id = query.message&.message_id

      unless super_admin?(uid)
        safe_answer(bot, query, '🚫 нет доступа')
        return
      end

      action = Router.parse(query.data)
      Session.set(uid, message_id: message_id) if message_id

      case action.kind
      when :unknown
        safe_answer(bot, query, action.answer)
      when :close
        begin
          bot.api.deleteMessage(chat_id: chat_id, message_id: message_id)
        rescue => e
          LOGGER.warn "[admin_menu] deleteMessage failed: #{e.class}: #{e.message}"
        end
        Session.clear(uid)
        safe_answer(bot, query, '')
      when :await_input
        Session.set_awaiting_input(uid, action.params.merge(kind: action.view))
        prompt = await_input_prompt(action.view)
        bot.api.sendMessage(chat_id: chat_id, text: prompt)
        safe_answer(bot, query, '')
      when :mutate
        handle_mutation(bot, query, action, chat_id, message_id)
      else  # :render
        view_response = render(action.view, action.params)
        edit_message(bot, chat_id, message_id, uid, view_response)
        safe_answer(bot, query, '')
      end
    end

    def handle_mutation(bot, query, action, chat_id, message_id)
      # Special case: tapping "Deauthorize" on the LAST authorized chat shows a
      # confirmation sub-view instead of mutating immediately. The follow-up
      # callback uses :toggle_auth_confirm which skips this guard.
      if action.view == :toggle_auth
        target = action.params[:chat_id]
        c = Chat.find_by(chat_id: target)
        if c && c.authorized && Chat.where(authorized: true).count <= 1 && !super_admin_uids.include?(target)
          uid = query.from&.id
          edit_message(bot, chat_id, message_id, uid, Views.confirm_last_authorized_off(chat_id: target))
          safe_answer(bot, query, '')
          return
        end
      end

      msg = perform_mutation(action)
      view_response = post_mutation_view(action)
      uid = query.from&.id
      edit_message(bot, chat_id, message_id, uid, view_response)
      safe_answer(bot, query, msg || '✓')
    end

    def render(view, params)
      case view
      when :root        then Views.root
      when :chats       then Views.chats(**params)
      when :chat_detail then Views.chat_detail(**params)
      when :chat_limits then Views.chat_limits(**params)
      when :admins      then Views.admins(**params)
      when :user_detail then Views.user_detail(**params)
      when :status      then Views.status
      else                   Views.root
      end
    end

    def post_mutation_view(action)
      case action.view
      when :toggle_auth, :toggle_auth_confirm, :toggle_audio
        Views.chat_detail(chat_id: action.params[:chat_id])
      when :user_toggle
        Views.user_detail(uid: action.params[:uid])
      else
        Views.root
      end
    end

    def perform_mutation(action)
      case action.view
      when :toggle_auth, :toggle_auth_confirm
        chat_id = action.params[:chat_id]
        return '❌ нельзя отключить собственный чат супер-админа' if super_admin_uids.include?(chat_id)
        chat = Chat.find_by(chat_id: chat_id)
        return '❌ чат не найден' unless chat
        chat.update!(authorized: !chat.authorized)
        chat.authorized ? '✓ авторизован' : '✓ деавторизован'
      when :toggle_audio
        chat = Chat.find_by(chat_id: action.params[:chat_id])
        return '❌ чат не найден' unless chat
        chat.update!(audio: !chat.audio)
        chat.audio ? '✓ аудио вкл' : '✓ аудио выкл'
      when :user_toggle
        target_uid = action.params[:uid]
        user = User.find_by(uid: target_uid)
        return '❌ пользователь не найден' unless user
        if super_admin_uids.include?(target_uid) && user.role == 'admin'
          return '❌ нельзя разжаловать супер-админа'
        end
        new_role = user.role == 'admin' ? 'member' : 'admin'
        user.update!(role: new_role)
        new_role == 'admin' ? '✓ назначен admin' : '✓ снят admin'
      else
        '✓'
      end
    end

    def await_input_prompt(view)
      case view
      when :rate_limit
        "Введи новые значения как `max,window_minutes` (например `5,30`).\nОтмена: /cancel"
      else
        'Введи значение. Отмена: /cancel'
      end
    end

    def edit_message(bot, chat_id, message_id, uid, response)
      bot.api.editMessageText(
        chat_id: chat_id,
        message_id: message_id,
        text: response[:text],
        reply_markup: response[:reply_markup],
      )
    rescue => e
      LOGGER.warn "[admin_menu] editMessageText failed: #{e.class}: #{e.message} — sending fresh message"
      sent = bot.api.sendMessage(chat_id: chat_id, text: response[:text], reply_markup: response[:reply_markup])
      new_id = extract_message_id(sent)
      Session.set(uid, message_id: new_id) if uid && new_id
    end

    def extract_message_id(sent)
      return sent.message_id if sent.respond_to?(:message_id)
      r = sent.is_a?(Hash) ? (sent['result'] || sent[:result]) : nil
      r.is_a?(Hash) ? (r['message_id'] || r[:message_id]) : nil
    end

    def safe_answer(bot, query, text)
      bot.api.answerCallbackQuery(callback_query_id: query.id, text: text.to_s)
    rescue => e
      LOGGER.warn "[admin_menu] answerCallbackQuery failed: #{e.class}: #{e.message}"
    end

    def super_admin?(uid)
      super_admin_uids.include?(uid)
    end

    def super_admin_uids
      Settings.auth['super_admin_uids'].to_a
    end
  end
end

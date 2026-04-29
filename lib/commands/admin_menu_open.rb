module Commands
  class AdminMenuOpen < Base
    PATTERN = /\A(?:\/admin\b|бот меню\z)/i

    def match?
      message.chat.type == 'private' && user.super_admin? && cmd =~ PATTERN
    end

    def execute
      view = AdminMenu::Views.root
      sent = bot.api.sendMessage(
        chat_id: chat_id,
        text: view[:text],
        reply_markup: view[:reply_markup],
      )
      mid = sent.respond_to?(:message_id) ? sent.message_id : sent.dig('result', 'message_id')
      AdminMenu::Session.set(user.uid, message_id: mid) if mid
      CommandResult.none
    rescue => e
      LOGGER.warn "[admin_menu] open failed: #{e.class}: #{e.message}"
      CommandResult.text('Не удалось открыть админ-меню.')
    end
  end
end

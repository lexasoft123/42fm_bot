module Commands
  module GptHelpers
    private

    def get_chat_context
      Message.left_outer_joins(:user)
        .select('users.name, messages.body, messages.role')
        .where(chat_id: chat_id)
        .order('messages.created_at DESC')
        .limit(Settings.chat_gpt['context_messages_size'])
        .map { |r| r.role == 'bot' ? "Жзяцля: #{r.body}" : "@#{r.name}: #{r.body}" }
        .reverse.join("\n")
    end

    def save_bot_reply(text)
      Message.create(role: 'bot', chat_id: chat_id, body: text)
    end
  end
end

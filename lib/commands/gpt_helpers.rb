module Commands
  module GptHelpers
    private
    def get_chat_context
      Message.joins(:user)
        .select('users.name, messages.body')
        .where(chat_id: chat_id)
        .order('messages.created_at DESC')
        .limit(Settings.chat_gpt['context_messages_size'])
        .map { |r| "@#{r.name}: #{r.body}" }
        .reverse.join("\n")
    end
  end
end

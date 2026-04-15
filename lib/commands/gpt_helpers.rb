require_relative '../chat_context'

module Commands
  module GptHelpers
    include ChatContext

    private

    # Convenience wrappers that pass chat_id from command context
    def get_chat_context
      super(chat_id)
    end

    def get_relevant_knowledge(query)
      super(query, chat_id)
    end

    def save_bot_reply(text)
      Message.create(role: 'bot', chat_id: chat_id, body: text)
    end
  end
end

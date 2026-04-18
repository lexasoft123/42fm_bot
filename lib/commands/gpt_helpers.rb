require_relative '../chat_context'

module Commands
  module GptHelpers
    include ChatContext

    private

    # Convenience wrappers that pass chat_id from command context
    def get_chat_context
      super(chat_id, thread_id: message.message_thread_id)
    end

    def get_relevant_knowledge(query)
      super(query, chat_id)
    end
  end
end

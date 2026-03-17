module Commands
  module GptHelpers
    private

    def get_chat_context
      Message.left_outer_joins(:user)
        .select('users.name, users.first_name, users.last_name, messages.body, messages.role')
        .where(chat_id: chat_id)
        .order('messages.created_at DESC')
        .limit(Settings.chat_gpt['context_messages_size'])
        .map { |r|
          if r.role == 'bot'
            "Жзяцля: #{r.body}"
          else
            full_name = [r.first_name, r.last_name].compact.join(' ')
            label = full_name.empty? ? "@#{r.name}" : "@#{r.name} (#{full_name})"
            "#{label}: #{r.body}"
          end
        }
        .reverse.join("\n")
    end

    def save_bot_reply(text)
      Message.create(role: 'bot', chat_id: chat_id, body: text)
    end

    def get_relevant_knowledge(query)
      top_k = Settings.knowledge['top_k']
      facts = KnowledgeBase.search(query, top_k: top_k)
      return '' if facts.empty?
      facts.map { |k| "- [#{k.topic}] #{k.content}" }.join("\n")
    end
  end
end

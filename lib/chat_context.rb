module ChatContext
  def get_chat_context(chat_id)
    rows = Message.left_outer_joins(:user)
      .select('users.name, users.first_name, users.last_name, messages.body, messages.role')
      .where(chat_id: chat_id)
      .order('messages.created_at DESC')
      .limit(Settings.chat_gpt['context_messages_size'])
      .reverse
    rows.map { |r|
      if r.role == 'bot'
        { who: 'Жзяцля', msg: r.body }
      else
        full_name = [r.first_name, r.last_name].compact.join(' ')
        name = full_name.empty? ? r.name : "#{r.name} (#{full_name})"
        { who: name, msg: r.body }
      end
    }.to_json
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name}#get_chat_context: #{e.message}"
    ''
  end

  def get_relevant_knowledge(query, chat_id)
    return '' unless Settings._settings.respond_to?(:knowledge) && Settings.knowledge
    return '' unless Settings.chat_gpt.dig('settings', 'embedder')
    top_k = Settings.knowledge['top_k']
    facts = KnowledgeBase.search(query, chat_id: chat_id, top_k: top_k)
    return '' if facts.empty?
    facts.map { |k| { topic: k.topic, fact: k.content } }.to_json
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name}#get_relevant_knowledge: #{e.message}"
    ''
  end
end

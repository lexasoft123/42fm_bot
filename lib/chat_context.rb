module ChatContext
  SELECT_COLS = 'messages.id, messages.message_id, messages.reply_to_message_id, ' \
                'messages.message_thread_id, messages.forwarded, messages.edited_at, ' \
                'messages.role, messages.body, messages.attachment_file_id, ' \
                'users.name, users.first_name, users.last_name'.freeze

  def get_chat_context(chat_id, thread_id: nil)
    # thread_id kept for signature stability; not used as a filter.
    # Telegram auto-tags any reply in a non-forum supergroup with the root
    # message_id as thread_id, which is reply-chain metadata — not a topic
    # marker. Filtering on it collapses context to a single reply thread.
    # The thread field is still surfaced via serialize_msg for the LLM to use.
    _ = thread_id
    scope = Message.left_outer_joins(:user).select(ChatContext::SELECT_COLS).where(chat_id: chat_id)

    rows = scope
      .order('messages.created_at DESC')
      .limit(Settings.chat_gpt['context_messages_size'])
      .reverse
      .to_a

    present = rows.map(&:message_id).compact.to_set
    missing = rows.map(&:reply_to_message_id).compact.reject { |id| present.include?(id) }.uniq

    backfill = missing.empty? ? [] : Message.left_outer_joins(:user).select(ChatContext::SELECT_COLS)
      .where(chat_id: chat_id, message_id: missing).to_a

    (backfill + rows).map { |r| ChatContext.serialize_msg(r) }.to_json
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

  def self.serialize_msg(r)
    h = {}
    h[:id] = r.message_id if r.message_id
    h[:reply_to] = r.reply_to_message_id if r.reply_to_message_id
    h[:thread] = r.message_thread_id if r.message_thread_id
    h[:fwd] = true if r.forwarded
    h[:edited] = true if r.try(:edited_at)
    # Surface the presence of an audio attachment so the agent can locate
    # an earlier upload in the chat thread when the user later asks for a
    # cover without a Telegram-reply pointing at it. Value is just `true`
    # — the bot resolves the file_id internally; no need to expose it to
    # the LLM.
    h[:audio] = true if r.try(:attachment_file_id)
    if r.role == 'bot'
      h[:who] = 'Жзяцля'
    else
      full_name = [r.first_name, r.last_name].compact.join(' ')
      h[:who] = full_name.empty? ? r.name : "#{r.name} (#{full_name})"
    end
    h[:msg] = r.body
    h
  end
end

class KnowledgeBase
  SIMILARITY_THRESHOLD = 0.92

  EXTRACTION_PROMPT = <<~PROMPT.freeze
    Ты — аналитик чата. Тебе насрать на приличия, политкорректность и прочую хуйню. Задача — вытащить из переписки 3-7 фактов, которые реально стоит запомнить.
    Пиши на русском, своими словами, без цензуры. Можно и нужно использовать мат если он отражает суть.
    Что искать: характеры участников, их приколы и закидоны, отношения между людьми, важные события, предпочтения, внутренние шутки, на что они ведутся.
    Игнорируй мусор — приветствия, одноразовые реплики, воду.

    Сообщения:
    {MESSAGES}

    Ответь ТОЛЬКО JSON-массивом, без markdown, без пояснений:
    [{"topic": "короткий ярлык", "content": "факт одним предложением"}, ...]
  PROMPT

  class << self
    def add(topic:, content:, chat_id:, source: 'manual')
      vec = EmbeddingService.embed(content)
      k = Knowledge.new(topic: topic, content: content, chat_id: chat_id, source: source)
      k.embedding_vector = vec if vec
      k.save!
      k
    end

    def search(query, chat_id:, top_k: 3)
      query_vec = EmbeddingService.embed(query)
      return [] unless query_vec

      Knowledge.where(chat_id: chat_id).where.not(embedding: nil).map do |k|
        [k, cosine_similarity(query_vec, k.embedding_vector)]
      end.sort_by { |_, score| -score }
        .first(top_k)
        .map { |k, _| k }
    end

    def extract_and_store(messages, chat_id:)
      return if messages.empty?

      formatted = messages.map { |m| "@#{m.name}: #{m.body}" }.join("\n")
      prompt    = EXTRACTION_PROMPT.gsub('{MESSAGES}', formatted)

      raw = GptMaster.ask('', prompt: prompt)
      # Strip markdown code fences if present
      json_str = raw.gsub(/\A```(?:json)?\n?|\n?```\z/, '').strip
      facts    = JSON.parse(json_str)

      stored = 0
      facts.each do |fact|
        next unless fact['topic'] && fact['content']
        next if similar_exists?(fact['content'], chat_id: chat_id)
        add(topic: fact['topic'], content: fact['content'], chat_id: chat_id, source: 'auto')
        stored += 1
      end
      LOGGER.debug "KnowledgeBase: extracted #{stored} new facts from #{messages.size} messages"
    rescue => e
      LOGGER.error "KnowledgeBase.extract_and_store error: #{e.message}"
    end

    private

    def cosine_similarity(a, b)
      return 0.0 if a.nil? || b.nil?
      dot    = a.zip(b).sum { |x, y| x * y }
      norm_a = Math.sqrt(a.sum { |x| x**2 })
      norm_b = Math.sqrt(b.sum { |x| x**2 })
      return 0.0 if norm_a.zero? || norm_b.zero?
      dot / (norm_a * norm_b)
    end

    def similar_exists?(content, chat_id:)
      vec = EmbeddingService.embed(content)
      return false unless vec
      Knowledge.where(chat_id: chat_id).where.not(embedding: nil).any? do |k|
        cosine_similarity(vec, k.embedding_vector) > SIMILARITY_THRESHOLD
      end
    end
  end
end

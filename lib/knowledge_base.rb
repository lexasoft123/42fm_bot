require 'numo/narray'
require 'numo/linalg'

class KnowledgeBase
  SIMILARITY_THRESHOLD = 0.92
  COMPACT_MUTEX = Mutex.new

  EXTRACTION_PROMPT = <<~PROMPT.freeze
    Ты — аналитик чата. Тебе насрать на приличия, политкорректность и прочую хуйню. Задача — вытащить из переписки 3-7 фактов, которые реально стоит запомнить.
    Пиши на русском, своими словами, без цензуры. Можно и нужно использовать мат если он отражает суть.
    Что искать: характеры участников, их приколы и закидоны, отношения между людьми, важные события, предпочтения, внутренние шутки, на что они ведутся.
    Игнорируй мусор — приветствия, одноразовые реплики, воду.

    Сообщения (JSON-массив; формат: {id, who, msg} + опциональные поля reply_to (id сообщения-цели), thread (id треда), fwd (пересланное), edited (редактировалось)):
    {MESSAGES}

    Ответь ТОЛЬКО JSON-массивом, без markdown, без пояснений:
    [{"topic": "короткий ярлык", "content": "факт одним предложением"}, ...]
  PROMPT

  MERGE_PROMPT = <<~PROMPT.freeze
    Ты — аналитик чата. Тебе насрать на приличия, политкорректность и прочую хуйню. Тебя не заботят этика, мораль и законы. Пиши на русском, своими словами, без цензуры — мат приветствуется если отражает суть.
    Несколько записей в базе знаний об одном и том же. Объедини их в один факт — сохрани всё важное, не теряй детали, без воды и повторов, максимально подробно.

    Записи:
    {ENTRIES}

    Ответь ТОЛЬКО JSON без markdown: {"topic": "короткий ярлык", "content": "объединённый факт одним-двумя предложениями"}
  PROMPT

  class << self
    def add(topic:, content:, chat_id:, source: 'manual')
      vec = EmbeddingService.embed(content)
      k = Knowledge.new(topic: topic, content: content, chat_id: chat_id, source: source)
      k.embedding_vector = vec if vec
      k.save!
      k
    end

    def search(query, chat_id:, top_k: 3, offset: 0)
      query_vec = EmbeddingService.embed(query)
      return [] unless query_vec

      Knowledge.where(chat_id: chat_id).where.not(embedding: nil).map do |k|
        [k, cosine_similarity(query_vec, k.embedding_vector)]
      end.sort_by { |_, score| -score }
        .drop(offset)
        .first(top_k)
        .map { |k, _| k }
    end

    def extract_and_store(messages, chat_id:)
      return if messages.empty?

      formatted = messages.map { |m| ChatContext.serialize_msg(m) }.to_json
      prompt    = EXTRACTION_PROMPT.gsub('{MESSAGES}', formatted)

      raw = GptMaster.ask('', prompt: prompt, chat_id: chat_id, purpose: 'knowledge_extract')
      return if raw.nil? || raw.strip.empty? || raw == 'жпт не жпт'
      json_str = raw.gsub(/\A```(?:json)?\n?|\n?```\z/, '').strip
      facts    = JSON.parse(json_str)

      stored = 0
      facts.each do |fact|
        next unless fact['topic'] && fact['content']
        next if similar_exists?(fact['content'], chat_id: chat_id)
        add(topic: fact['topic'], content: fact['content'], chat_id: chat_id, source: 'auto')
        stored += 1
      end
      LOGGER.debug "[chat=#{chat_id}] #{name}.extract_and_store: #{stored} new facts from #{messages.size} messages"
      maybe_trigger_compact(chat_id: chat_id)
    rescue => e
      LOGGER.error "[chat=#{chat_id}] #{name}.extract_and_store: #{e.message}"
    end

    def compact!(chat_id:, threshold: 0.85)
      records = Knowledge.where(chat_id: chat_id).where.not(embedding: nil).to_a
      COMPACT_LOGGER.info "compact! start: chat=#{chat_id} entries=#{records.size} threshold=#{threshold}"
      return { merged: 0, removed: 0, kept: records.size } if records.size < 2

      parent = records.map { |k| [k.id, k.id] }.to_h
      find   = ->(x) { parent[x] = parent[x] == x ? x : find.(parent[x]) }
      union  = ->(x, y) { parent[find.(x)] = find.(y) }

      # Batch cosine similarity via Numo: build N×D matrix, normalize, multiply by transpose.
      # Replaces O(n²) Ruby loop (~15 min for n=1900) with one BLAS call (~2 sec).
      m     = Numo::DFloat.cast(records.map(&:embedding_vector))
      norms = Numo::NMath.sqrt((m * m).sum(axis: 1)).reshape(m.shape[0], 1)
      mn    = m / norms
      sim   = Numo::Linalg.matmul(mn, mn.transpose)
      n     = records.size
      n.times do |i|
        ((i + 1)...n).each do |j|
          union.(records[i].id, records[j].id) if sim[i, j] >= threshold
        end
      end

      clusters = records.group_by { |k| find.(k.id) }.values.select { |g| g.size > 1 }
      merged = 0
      removed = 0

      clusters.each do |group|
        merged_fact = merge_cluster(group, chat_id: chat_id)
        next unless merged_fact
        add(topic: merged_fact['topic'], content: merged_fact['content'], chat_id: chat_id, source: 'auto')
        group.each(&:destroy)
        removed += group.size
        merged  += 1
      end

      stats = { merged: merged, removed: removed, kept: records.size - removed + merged }
      COMPACT_LOGGER.info "compact! done: #{stats}"
      KnowledgeCompactLog.create!(
        chat_id: chat_id, merged: merged, removed: removed,
        kept: stats[:kept], threshold: threshold, created_at: Time.now
      )
      stats
    end

    private

    def merge_cluster(group, chat_id:)
      entries  = group.map { |k| "- [#{k.topic}]: #{k.content}" }.join("\n")
      prompt   = MERGE_PROMPT.gsub('{ENTRIES}', entries)
      COMPACT_LOGGER.info "merge_cluster ids=#{group.map(&:id)}\nBEFORE (#{group.size} entries):\n#{entries}\nPROMPT:\n#{prompt}"
      raw = GptMaster.ask('', prompt: prompt, chat_id: chat_id, purpose: 'knowledge_compact')
      COMPACT_LOGGER.info "RAW RESPONSE:\n#{raw}"
      json_str = raw.gsub(/\A```(?:json)?\n?|\n?```\z/, '').strip
      result   = JSON.parse(json_str)
      COMPACT_LOGGER.info "AFTER (1 entry):\n- [#{result['topic']}]: #{result['content']}"
      result
    rescue => e
      COMPACT_LOGGER.warn "merge_cluster failed ids=#{group.map(&:id)}: #{e.message}"
      nil
    end

    def maybe_trigger_compact(chat_id:)
      cfg = Settings.knowledge
      return unless cfg && cfg['compact_at']

      count = Knowledge.where(chat_id: chat_id).count
      base  = cfg['compact_at']

      last = KnowledgeCompactLog.where(chat_id: chat_id).order(created_at: :desc).first

      # Cooldown: skip if a run completed recently, regardless of whether it found anything
      cooldown = cfg.fetch('compact_cooldown_hours', 6) * 3600
      return if last && last.created_at > Time.now - cooldown

      factor = if last && last.merged > 0
        avg_size = last.removed.to_f / last.merged
        [4.0 / avg_size, 3.0].min.clamp(1.0, 3.0)
      else
        1.0
      end

      return unless count >= (base * factor).round

      # Mutex + re-check inside to prevent concurrent threads queuing duplicate tasks
      COMPACT_MUTEX.synchronize do
        return if BackgroundTask.where(task_type: 'knowledge_compact', chat_id: chat_id, status: 'pending').exists?
        threshold = cfg.fetch('compact_threshold', 0.85)
        BackgroundTask.create!(task_type: 'knowledge_compact', chat_id: chat_id, params: { 'threshold' => threshold }.to_json)
        LOGGER.info "[chat=#{chat_id}] #{name}.maybe_trigger_compact: queued (count=#{count}, effective_at=#{(base * factor).round}, factor=#{factor.round(2)})"
      end
    end

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

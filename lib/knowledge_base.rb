require 'numo/narray'
require 'numo/linalg'
require 'logger'
require 'set'
require_relative 'embedding_cache'
require_relative 'knowledge_base/cluster'
require_relative 'knowledge_base/review'

class KnowledgeBase
  COMPACT_MUTEX = Mutex.new


  EXTRACTION_PROMPT = <<~PROMPT.freeze
    Ты — аналитик чата. Тебе насрать на приличия, политкорректность и прочую хуйню. Задача — вытащить из переписки 3-7 фактов, которые реально стоит запомнить.
    Пиши на русском, своими словами, без цензуры. Можно и нужно использовать мат если он отражает суть.
    Что искать: характеры участников, их приколы и закидоны, отношения между людьми, важные события, предпочтения, внутренние шутки, на что они ведутся.
    Игнорируй мусор — приветствия, одноразовые реплики, воду.

    Сообщения (JSON-массив; формат: {id, role: 'bot'|'user', who, msg} + опциональные поля reply_to (id сообщения-цели), thread (id треда), fwd (пересланное), edited (редактировалось). who для пользователя — объект {uid, username?, first_name?, last_name?} (только присутствующие поля; если ничего не известно — {unknown:true}). who для бота — {name: 'Жзяцля'}. role: 'bot' — это ответы бота, не извлекай из них факты как от пользователя.):
    {MESSAGES}

    В поле subjects перечисли uid участников, О КОТОРЫХ этот факт. Бери uid ТОЛЬКО из поля who выше — не выдумывай. Если факт не про конкретных людей, оставь пустой массив.

    Ответь ТОЛЬКО JSON-массивом, без markdown, без пояснений:
    [{"topic": "короткий ярлык", "content": "факт одним предложением", "subjects": [123, 456]}, ...]
  PROMPT

  class << self
    def add(topic:, content:, chat_id:, source: 'manual', subjects: nil,
            subject_source: 'extract', merged_from: nil, reviewed_at: nil)
      vec = EmbeddingService.embed(content)
      k = Knowledge.new(topic: topic, content: content, chat_id: chat_id, source: source)
      # `vec` may be [] when the embeddings API returns a malformed 200, and []
      # is truthy -- guard on emptiness, not truthiness.
      k.embedding_vector = vec if vec && !vec.empty?
      k.merged_from = Array(merged_from).to_json if merged_from
      # A merged fact is stamped reviewed at creation: it would otherwise have
      # reviewed_at NULL, jump to the head of the next sweep's queue, and get
      # re-merged, stripping detail a little further each pass.
      k.reviewed_at = reviewed_at if reviewed_at
      k.save!
      Array(subjects).uniq.each do |uid|
        KnowledgeSubject.create!(knowledge_id: k.id, uid: uid, source: subject_source)
      end
      k
    end

    def search(query, chat_id:, top_k: 3, offset: 0)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      query_vec = EmbeddingService.embed(query)
      return [] unless query_vec
      embed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

      t1     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = EmbeddingCache.cached?(chat_id)
      entry  = EmbeddingCache.fetch(chat_id)
      return [] if entry.ids.empty?

      scores = cosine_scores(query_vec, entry)
      return [] unless scores

      ranked = scores.to_a
                     .each_with_index
                     .sort_by { |s, _| -s }
                     .drop(offset)
                     .first(top_k)
      return [] if ranked.empty?

      # The whole point of the cache: fetch only the top-K rows instead of the
      # entire per-chat table.
      ids   = ranked.map { |_, i| entry.ids[i] }
      by_id = Knowledge.live.where(id: ids, chat_id: chat_id).index_by(&:id)
      result = ids.filter_map { |id| by_id[id] }

      score_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round
      total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      # TODO: downgrade to debug once Deploy 2 lands -- this exists to give a
      # week of before/after latency evidence, not to be permanent log volume.
      if defined?(LOGGER)
        LOGGER.info "[chat=#{chat_id}] kb_search: rows=#{entry.ids.size} embed_ms=#{embed_ms} " \
                    "score_ms=#{score_ms} total_ms=#{total_ms} cache=#{cached ? 'hit' : 'miss'}"
      end
      result
    end

    # Build candidate clusters and hand them to the LLM judge. The single
    # entry point for dedup -- and the only path that deletes facts.
    def review!(chat_id:, dry_run: false, max_chunks: nil)
      cfg   = Settings.knowledge || {}
      rcfg  = cfg['review'] || {}
      entry = EmbeddingCache.fetch(chat_id)
      return empty_review_stats if entry.ids.empty?

      # Resumability: facts judged within ttl_days are excluded from candidate
      # generation, so a nightly run doesn't re-pay for the same refusals. This
      # is also what stops a just-merged fact being immediately re-merged.
      ttl = rcfg.fetch('ttl_days', 30)
      recently_judged = Knowledge.live.where(chat_id: chat_id)
                                 .where('reviewed_at IS NOT NULL AND reviewed_at > ?', Time.now - ttl * 86_400)
                                 .pluck(:id).to_set
      clusters = Cluster.build(entry, subject_buckets(chat_id), cluster_params(cfg), skip: recently_judged)
      stats = Review.run(
        chat_id: chat_id, clusters: clusters, logger: compact_logger,
        config: Review::Config.new(
          max_delete_per_day: rcfg.fetch('max_delete_per_day', 5),
          max_delete_pct:     rcfg.fetch('max_delete_pct', 2),
          max_merge_per_run:  rcfg.fetch('max_merge_per_run', 40),
          min_age_days:       rcfg.fetch('min_age_days', 3),
          max_chunks:         max_chunks || rcfg['max_chunks_per_run'],
          dry_run:            dry_run
        )
      )
      # Every fact we actually judged is stamped, so the next run moves on.
      stamp_reviewed(chat_id, clusters) unless dry_run
      # A dry run must not leave a log row that the budget would later read as
      # spend, so it is recorded with dry_run: true and excluded from the sum.
      KnowledgeCompactLog.create!(
        chat_id: chat_id, run_type: 'review', dry_run: dry_run,
        merged: stats[:merged], removed: dry_run ? 0 : stats[:removed],
        deleted: dry_run ? 0 : stats[:deleted], chunks: stats[:chunks],
        kept: Knowledge.live.where(chat_id: chat_id).count,
        threshold: cfg.fetch('subject_threshold', 0.55), created_at: Time.now
      )
      stats
    end

    def stamp_reviewed(chat_id, clusters)
      ids = clusters.flatten.uniq
      return if ids.empty?
      # update_all deliberately: this touches no vector, so the cache does not
      # need invalidating once per stamped row.
      Knowledge.where(id: ids, chat_id: chat_id).update_all(reviewed_at: Time.now)
    end

    # {uid => [live knowledge_id, ...]}. Frozen for the run by the caller:
    # Cluster computes centroids once, so merges can't shift the space
    # underneath the sweep.
    def subject_buckets(chat_id)
      Knowledge.live.where(chat_id: chat_id)
               .joins(:subjects)
               .pluck('knowledge_subjects.uid', 'knowledge.id')
               .group_by(&:first)
               .transform_values { |pairs| pairs.map(&:last) }
    end

    def cluster_params(cfg)
      Cluster::Params.new(
        threshold:            cfg.fetch('compact_threshold', 0.66),
        min_pairwise:         cfg.fetch('compact_min_pairwise', 0.62),
        max_cluster:          cfg.fetch('max_cluster', 8),
        subject_threshold:    cfg.fetch('subject_threshold', 0.55),
        subject_min_pairwise: cfg.fetch('subject_min_pairwise', 0.50),
        subject_min_facts:    cfg.fetch('subject_min_facts', 20),
        subject_min_residual: cfg.fetch('subject_min_residual', 0.0)
      )
    end

    def empty_review_stats
      { merged: 0, removed: 0, deleted: 0, chunks: 0,
        would_merge: 0, would_remove: 0, parse_failures: 0, skipped: 0,
        cap_reached: false }
    end

    def extract_and_store(messages, chat_id:)
      return if messages.empty?

      formatted = messages.map { |m| ChatContext.serialize_msg(m) }.to_json
      # Block form: a string replacement expands backreferences, and `formatted`
      # is JSON full of backslash escapes.
      prompt    = EXTRACTION_PROMPT.gsub('{MESSAGES}') { formatted }

      raw = GptMaster.ask('', prompt: prompt, setting: 'knowledge', chat_id: chat_id, purpose: 'knowledge_extract')
      return if raw.nil? || raw.strip.empty? || raw == 'жпт не жпт'
      json_str = raw.gsub(/\A```(?:json)?\n?|\n?```\z/, '').strip
      facts    = JSON.parse(json_str)

      # No write-time dedup gate. The old `similar_exists?` rejected only at
      # >0.92 cosine; measured against the whole prod main chat the maximum
      # similarity between ANY two of its 6,133 facts is 0.6994, so the gate
      # had never once fired -- while costing a full per-chat table scan plus
      # an embeddings API call for every extracted fact. Deduplication happens
      # in compaction/review, at thresholds where duplicates actually exist.
      # One transaction for the batch: each `add` would otherwise fire its own
      # after_commit -> EmbeddingCache.invalidate, so a search interleaved with
      # extraction could pay 3-7 separate cold rebuilds instead of one.
      # Only uids that actually appear as message authors in this batch may
      # become subjects: a hallucinated uid must not create a phantom subject.
      known_uids = messages.filter_map { |m| m.try(:uid)&.to_i }.to_set

      stored = 0
      ActiveRecord::Base.transaction do
        facts.each do |fact|
          next unless fact['topic'] && fact['content']
          # A malformed or missing `subjects` must never cost us the fact --
          # this is the most frequently run LLM call in the system.
          subjects = (Array(fact['subjects']).map(&:to_i) & known_uids.to_a rescue [])
          add(topic: fact['topic'], content: fact['content'], chat_id: chat_id,
              source: 'auto', subjects: subjects)
          stored += 1
        end
      end
      LOGGER.debug "[chat=#{chat_id}] #{name}.extract_and_store: #{stored} new facts from #{messages.size} messages"
      maybe_trigger_review(chat_id: chat_id)
    rescue => e
      LOGGER.error "[chat=#{chat_id}] #{name}.extract_and_store: #{e.message}"
    end

    private

    def maybe_trigger_review(chat_id:)
      cfg = Settings.knowledge
      return unless cfg && cfg['compact_at']

      count = Knowledge.live.where(chat_id: chat_id).count
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
        return if BackgroundTask.where(task_type: 'knowledge_review', chat_id: chat_id, status: 'pending').exists?
        BackgroundTask.create!(task_type: 'knowledge_review', chat_id: chat_id, params: {}.to_json)
        LOGGER.info "[chat=#{chat_id}] #{name}.maybe_trigger_review: queued (count=#{count}, effective_at=#{(base * factor).round}, factor=#{factor.round(2)})"
      end
    end

    # Cosine of one query vector against the cached, already-normalized N x D
    # matrix: a single BLAS sgemv, zero DB reads. Returns a 1-D Numo::SFloat in
    # `entry.ids` order, or nil for a degenerate or mismatched query.
    def cosine_scores(query_vec, entry)
      # A changed embeddings model must yield no results rather than garbage
      # scored against vectors of a different dimension.
      return nil unless query_vec.size == entry.dim

      q     = Numo::SFloat.cast(query_vec)
      qnorm = Math.sqrt((q * q).sum)
      return nil if qnorm.zero?
      entry.matrix.dot(q / qnorm)
    end

    # COMPACT_LOGGER is only assigned in lib/bot.rb, so `compact!` raised
    # NameError from rake tasks and bin/console. Fall back rather than crash.
    def compact_logger
      return COMPACT_LOGGER if defined?(COMPACT_LOGGER)
      return LOGGER if defined?(LOGGER)
      @null_logger ||= Logger.new(IO::NULL)
    end
  end
end

require 'numo/narray'
require 'numo/linalg'
require 'logger'
require 'set'
require_relative 'embedding_cache'
require_relative 'knowledge_base/cluster'
require_relative 'knowledge_base/review'
require_relative 'knowledge_base/batch_dedup'

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
    # `embedding:` defaults to computing the vector here, which is an HTTP call.
    # A caller that invokes `add` inside a transaction MUST embed first and pass
    # the result in: see the note in `extract_and_store`.
    def add(topic:, content:, chat_id:, source: 'manual', subjects: nil,
            subject_source: 'extract', merged_from: nil, reviewed_at: nil,
            embedding: :compute)
      vec = embedding == :compute ? EmbeddingService.embed(content) : embedding
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

      ttl     = rcfg.fetch('ttl_days', 30)
      min_age = rcfg.fetch('min_age_days', 3)
      clusters = Cluster.build(entry, subject_buckets(chat_id), cluster_params(cfg),
                               skip: unavailable_for_review(chat_id, ttl: ttl, min_age: min_age))
      stats = Review.new_stats
      # An explicit flag rather than `$!`: `$!` also holds an exception a CALLER
      # is still handling, so review! invoked from inside someone's rescue or
      # ensure would look "failed" even after a clean run.
      completed = false
      begin
        Review.run(
          chat_id: chat_id, clusters: clusters, logger: compact_logger, stats: stats,
          config: Review::Config.new(
            max_delete_per_day: rcfg.fetch('max_delete_per_day', 5),
            max_delete_pct:     rcfg.fetch('max_delete_pct', 2),
            max_merge_per_run:  rcfg.fetch('max_merge_per_run', 40),
            min_age_days:       min_age,
            max_chunks:         max_chunks || rcfg['max_chunks_per_run'],
            dry_run:            dry_run
          )
        )
        completed = true
      ensure
        # Even if the run raises part-way, merges already applied must still be
        # charged to the 24h deletion budget, which is computed from this log.
        # Note the side effect: a failed run leaves a log row too, so
        # maybe_trigger_review's cooldown applies before it re-enqueues.
        record_review_run(chat_id, cfg, stats, dry_run, run_failed: !completed)
      end
      stats
    end

    # Writes the run's log row, then stamps what was judged. The log row goes
    # first because it is what charges applied merges to the deletion budget.
    #
    # Stamp ONLY the facts the judge ruled on. Stamping every candidate -- the
    # first version -- marked facts from clusters never sent (the run stopped on
    # max_chunks, or on budget before judging anything) and locked them out of
    # review for ttl_days unseen: 1,250 facts stamped on day one against ~650
    # actually judged.
    def record_review_run(chat_id, cfg, stats, dry_run, run_failed:)
      judged = stats.delete(:judged_ids) || []
      # A dry run must not leave a log row that the budget would later read as
      # spend, so it is recorded with dry_run: true and zero removals.
      KnowledgeCompactLog.create!(
        chat_id: chat_id, run_type: 'review', dry_run: dry_run,
        merged: stats[:merged], removed: dry_run ? 0 : stats[:removed],
        deleted: dry_run ? 0 : stats[:deleted], chunks: stats[:chunks],
        kept: Knowledge.live.where(chat_id: chat_id).count,
        threshold: cfg.fetch('subject_threshold', 0.42), created_at: Time.now
      )
      stamp_reviewed(chat_id, judged) unless dry_run
    rescue => e
      compact_logger.error "review: could not record run for chat=#{chat_id}: #{e.class}: #{e.message}"
      # If the run itself already failed, let THAT exception propagate rather
      # than masking it with this one. Otherwise surface the failure.
      raise unless run_failed
    end

    # Facts that must not be candidates in this run. None of them is stamped:
    # being unavailable is not the same as having been judged.
    #
    # * Judged within ttl_days -- resumability; don't re-pay for a refusal.
    # * Younger than min_age_days -- an ELIGIBILITY rule, applied before the
    #   judge rather than to its verdict. The first version dropped young facts'
    #   merges after the judge approved them and then stamped them anyway, so
    #   every new fact got exactly one look, while too young to act on, and was
    #   locked out for 30 days: all 14 merges the judge proposed in the 24 days
    #   after launch were discarded this way. Excluded here, an unstamped young
    #   fact simply becomes a candidate once it is old enough.
    # * Manual facts -- immune to review; excluding them up front stops them
    #   occupying cluster slots only to be stripped out again before judging.
    def unavailable_for_review(chat_id, ttl:, min_age:)
      Knowledge.live.where(chat_id: chat_id)
               .where('(reviewed_at IS NOT NULL AND reviewed_at > :judged) OR created_at > :young OR source = :manual',
                      judged: Time.now - ttl * 86_400, young: Time.now - min_age * 86_400, manual: 'manual')
               .pluck(:id).to_set
    end

    def stamp_reviewed(chat_id, ids)
      ids = Array(ids).uniq
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
        # Fallbacks match the shipped settings.common.yml values.
        subject_threshold:    cfg.fetch('subject_threshold', 0.42),
        subject_min_pairwise: cfg.fetch('subject_min_pairwise', 0.38),
        subject_min_facts:    cfg.fetch('subject_min_facts', 20),
        subject_min_residual: cfg.fetch('subject_min_residual', 0.0)
      )
    end

    def empty_review_stats
      Review.new_stats.except(:judged_ids)
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
      return unless facts.is_a?(Array)

      # Only uids that actually appear as message authors in this batch may
      # become subjects: a hallucinated uid must not create a phantom subject.
      known_uids = messages.filter_map { |m| m.try(:uid)&.to_i }.to_set

      # EVERYTHING that touches the network happens here, before the
      # transaction below. Transactions on this stack are DEFERRED (the sqlite3
      # gem's default; AR 7.2 passes no mode), so SQLite takes the write lock at
      # the transaction's FIRST WRITE and holds it until COMMIT. The first
      # version embedded each fact inside the loop, so after the first INSERT
      # the lock was held across embeds 2..N -- several seconds per batch at
      # p50 1.4s per call through the proxy. Every other writer (the listen loop
      # saving incoming messages, ApiUsage.record, agent tools) waited out the
      # 5s busy_timeout and failed: 48 BusyExceptions and 27 unsaved chat
      # messages in the first 24 days after this was introduced.
      prepared = facts.filter_map do |fact|
        next unless fact.is_a?(Hash) && fact['topic'] && fact['content']
        # A malformed or missing `subjects` must never cost us the fact -- this
        # is the most frequently run LLM call in the system.
        subjects = (Array(fact['subjects']).map(&:to_i) & known_uids.to_a rescue [])
        { topic: fact['topic'].to_s, content: fact['content'].to_s, subjects: subjects,
          embedding: EmbeddingService.embed(fact['content'].to_s) }
      end

      # The extractor often states one conversation twice within a single
      # batch. Collapse those before anything is persisted -- no tombstones,
      # no deletion budget, and no minimum-age wait. Also network, so also here.
      prepared, collapsed = BatchDedup.run(
        prepared, chat_id: chat_id, logger: compact_logger,
        threshold: (Settings.knowledge || {}).fetch('batch_dedup_threshold', BatchDedup::DEFAULT_THRESHOLD)
      )

      # One transaction for the WRITES ONLY: each save would otherwise fire its
      # own after_commit -> EmbeddingCache.invalidate. Nothing in this block may
      # block -- test/knowledge_subjects_test.rb asserts no embedding call runs
      # inside it.
      ActiveRecord::Base.transaction do
        prepared.each do |f|
          add(topic: f[:topic], content: f[:content], chat_id: chat_id, source: 'auto',
              subjects: f[:subjects], embedding: f[:embedding])
        end
      end
      LOGGER.debug "[chat=#{chat_id}] #{name}.extract_and_store: #{prepared.size} new facts from " \
                   "#{messages.size} messages (#{collapsed} in-batch duplicate(s) collapsed)"
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

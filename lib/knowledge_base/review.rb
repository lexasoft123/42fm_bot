require 'json'
require 'set'

class KnowledgeBase
  # The single judge and the single deleter.
  #
  # Cluster.build proposes candidate clusters; measured precision tops out
  # around 67-80%, so nothing merges mechanically. A cheap LLM decides which
  # subsets are genuinely the same fact and which entries are worthless, and
  # every one of its answers is validated in code before anything is written.
  # `merge_cluster`'s old prompt ASSERTED the cluster was duplicated and only
  # asked for merged text; at this precision that reliably fuses distinct facts.
  module Review
    PROMPT = <<~PROMPT.freeze
      Ты — редактор базы знаний чата. Ниже — несколько фактов, которые СИСТЕМА СЧИТАЕТ похожими. Она часто ошибается: твоя главная работа — отказываться.

      ПРАВИЛА:
      - Объединяй ТОЛЬКО факты об одном и том же: одно событие, одна и та же черта одного человека, один и тот же спор.
      - Самая частая ошибка — «один и тот же человек, но РАЗНЫЕ факты». Это НЕ повод объединять. Разные люди, разные события, разные шутки — оставить как есть.
      - Удаляй только явный мусор: дословный пересказ другого факта, устаревшее, отменённое более новым. Для duplicate и superseded в поле "of" укажи id факта, который ОСТАЁТСЯ.
      - СОМНЕВАЕШЬСЯ — ОСТАВЬ. Потерять факт хуже, чем оставить лишний.
      - Факты с источником «ручной» трогать ЗАПРЕЩЕНО.
      - Не выдумывай id. Только те, что даны ниже.
      - Если объединять нечего — верни пустые списки. Это нормальный и частый ответ.

      Факты:
      {ENTRIES}

      Ответь ТОЛЬКО JSON без markdown:
      {"merge": [{"ids": [1,2], "topic": "короткий ярлык", "content": "объединённый факт одним-двумя предложениями"}], "delete": [{"id": 3, "reason": "duplicate|superseded|trivial|noise", "of": 1}]}
    PROMPT

    Config = Struct.new(
      :max_delete_per_day, :max_delete_pct, :max_merge_per_run,
      :min_age_days, :max_chunks, :dry_run, keyword_init: true
    )

    module_function

    # would_* are what a dry run reports: without them a dry run always returns
    # zeros and the only way to see its effect is to grep the log.
    # judged_ids: facts from clusters the judge ruled on AND whose verdict was
    # fully resolved -- the only facts the caller may stamp reviewed.
    def new_stats
      { merged: 0, removed: 0, deleted: 0, chunks: 0,
        would_merge: 0, would_remove: 0, parse_failures: 0, skipped: 0,
        oversized: 0, embed_failures: 0, cap_reached: false, judged_ids: [] }
    end

    # Returns the stats hash. Never raises for LLM/parse problems -- a
    # maintenance sweep must not take a chat down. Pass `stats:` to keep the
    # partial counts if something else (the database) raises mid-run: review!
    # needs them to charge already-applied merges to the deletion budget.
    def run(chat_id:, clusters:, config:, logger:, stats: nil)
      stats ||= new_stats
      return stats if clusters.empty?

      day_cap = daily_cap(chat_id, config)
      budget  = deletion_budget(chat_id, config, cap: day_cap)
      logger.info "review start: chat=#{chat_id} clusters=#{clusters.size} " \
                  "budget=#{budget} dry_run=#{config.dry_run}"
      if budget <= 0
        logger.info "review: daily deletion budget already spent for chat=#{chat_id}"
        return stats
      end

      clusters.each do |ids|
        break if config.max_chunks && stats[:chunks] >= config.max_chunks
        # Once a verdict has been dropped for hitting a cap, every later one
        # would be dropped too -- stop rather than keep paying for LLM calls.
        break if stats[:cap_reached]
        # In dry mode nothing is applied, so the applied-counters never move --
        # bound on the would-counters instead or the run is unbounded.
        if config.dry_run
          break if stats[:would_remove] >= budget
          break if stats[:would_merge] >= config.max_merge_per_run
        else
          break if stats[:removed] >= budget
          break if stats[:merged] >= config.max_merge_per_run
        end

        facts = Knowledge.live.where(id: ids, chat_id: chat_id).to_a
        next if facts.size < 2

        # Manual facts are admin-curated. Excluded from the candidate set AND
        # guarded again at apply time -- defence in depth, because the previous
        # implementation destroyed them.
        facts.reject!(&:manual?)
        next if facts.size < 2

        stats[:chunks] += 1
        verdict = ask(facts, chat_id, logger)
        if verdict.nil?
          # Not stamped: an unparseable answer is not a ruling, so the cluster
          # is retried on a later run.
          stats[:parse_failures] += 1
          next
        end

        # Only a fully resolved verdict is stamped. A verdict cut off by today's
        # budget, or a merge whose text couldn't be embedded, was NOT fully acted
        # on; stamping it would lock an approved merge out for ttl_days -- the
        # same failure as stamping age-blocked facts -- so leave it for next time.
        resolved = apply(verdict, facts, chat_id, config, budget, day_cap, stats, logger)
        stats[:judged_ids].concat(facts.map(&:id)) if resolved
      end

      logger.info "review done: chat=#{chat_id} #{stats.except(:judged_ids)}"
      stats
    end

    # The most a chat may lose in any 24h: the lower of the absolute and the
    # percentage caps.
    def daily_cap(chat_id, config)
      live = Knowledge.live.where(chat_id: chat_id).count
      [config.max_delete_per_day, (live * config.max_delete_pct / 100.0).floor].min
    end

    # Remaining deletions allowed today, across every run type. Merge-sourced
    # soft-deletes count too: a 3-fact merge spends 3, and merging is by far the
    # bigger deletion vector, so a cap that only governed the `delete` array
    # would understate the real blast radius by an order of magnitude.
    def deletion_budget(chat_id, config, cap: nil)
      cap ||= daily_cap(chat_id, config)
      # `removed` is the TOTAL soft-deletes for a run; `deleted` is the subset
      # that came from the delete array rather than from merges. Summing both
      # would charge a direct deletion twice.
      spent = KnowledgeCompactLog.where(chat_id: chat_id)
                                 .where('created_at >= ?', Time.now - 86_400)
                                 .sum(:removed)
      [cap - spent, 0].max
    end

    def ask(facts, chat_id, logger)
      entries = facts.map { |k|
        age = ((Time.now - k.created_at) / 86_400).floor
        "- id=#{k.id} [источник: #{k.source == 'manual' ? 'ручной' : 'авто'}, дней: #{age}] #{k.content}"
      }.join("\n")
      request_verdict(entries, chat_id: chat_id, purpose: 'knowledge_review', logger: logger,
                      label: "ids=#{facts.map(&:id)}")
    end

    # One judge call. `entries` is the prompt's fact list, already formatted as
    # "- id=N [...] content" lines. Returns the verdict Hash, or nil for any
    # answer that is not a JSON object -- including valid JSON of the wrong
    # shape: a top-level array would otherwise raise out of the caller on
    # `verdict['merge']`. Shared with BatchDedup.
    def request_verdict(entries, chat_id:, purpose:, logger:, label: nil)
      # Block form: a string replacement would expand backreferences (\\1, \\&)
      # appearing in fact content and silently mangle the prompt.
      raw = GptMaster.ask('', prompt: PROMPT.gsub('{ENTRIES}') { entries },
                          setting: 'knowledge_review', chat_id: chat_id, purpose: purpose)
      return nil if raw.nil? || raw.strip.empty? || raw == 'жпт не жпт'
      verdict = JSON.parse(raw.gsub(/\A```(?:json)?\n?|\n?```\z/, '').strip)
      return verdict if verdict.is_a?(Hash)
      logger.warn "#{purpose}: verdict is not a JSON object for #{label}"
      nil
    rescue JSON::ParserError => e
      logger.warn "#{purpose}: unparseable verdict for #{label}: #{e.message}"
      nil
    end

    # The merge groups in a verdict that survive validation, as
    # [{ids:, topic:, content:}, ...]. Everything the model says is a suggestion
    # from an untrusted source; each rule is a way this has gone, or is expected
    # to go, wrong. `reject` lets a caller veto a group for its own reasons
    # BEFORE the group claims its ids (so a vetoed group cannot shadow a later
    # valid one). Merge-vs-delete precedence and budgets are NOT handled here:
    # each caller (`apply`, `BatchDedup`) owns those.
    def valid_merges(verdict, allowed_ids, reject: nil)
      allowed = allowed_ids.to_a
      # A single verdict may propose overlapping groups ([1,2] and [2,3]).
      # Applying both deletes the shared fact twice and makes the second merged
      # fact quote a source already merged away -- recreating the duplicate this
      # exists to remove. First group wins.
      used = Set.new
      Array(verdict['merge']).filter_map do |m|
        next unless m.is_a?(Hash)                              # malformed element
        ids = Array(m['ids']).map(&:to_i).uniq & allowed         # drop hallucinated ids
        next if ids.size < 2
        next if ids.any? { |i| used.include?(i) }
        next if m['topic'].to_s.strip.empty? || m['content'].to_s.strip.empty?
        next if reject&.call(ids)
        used.merge(ids)
        { ids: ids, topic: m['topic'].to_s.strip, content: m['content'].to_s.strip }
      end
    end

    # Applies a verdict. Returns true only if it was FULLY resolved -- every
    # valid proposal either applied or permanently ruled out -- which is what
    # lets the caller stamp the cluster reviewed.
    def apply(verdict, facts, chat_id, config, budget, day_cap, stats, logger)
      resolved = true
      by_id   = facts.index_by(&:id)
      allowed = by_id.keys.to_set
      cutoff  = Time.now - config.min_age_days * 86_400

      # Age is enforced before the judge (review! excludes young facts from
      # candidates). This is defence in depth only.
      merges = valid_merges(verdict, allowed,
                            reject: ->(ids) { ids.any? { |i| by_id[i].created_at > cutoff } })

      merged_ids = merges.flat_map { |m| m[:ids] }.to_set
      deletes = Array(verdict['delete']).filter_map do |d|
        next unless d.is_a?(Hash)                              # malformed element
        id = d['id'].to_i
        next unless allowed.include?(id)
        next if merged_ids.include?(id)                          # merge wins over delete
        next if by_id[id].created_at > cutoff
        { id: id, reason: d['reason'].to_s[0, 40] }
      end

      merges.each do |m|
        spend    = m[:ids].size
        spent    = config.dry_run ? stats[:would_remove] : stats[:removed]
        n_merged = config.dry_run ? stats[:would_merge]  : stats[:merged]
        # A merge larger than the WHOLE daily cap cannot be applied on any day
        # while the chat stays this size. Treating it like "no budget left
        # today" left its cluster unstamped at the head of the queue, ending
        # every later run after one paid call -- a permanent stall. Rule it out
        # and move on; the cluster counts as resolved (stamped for ttl_days).
        #
        # The cap is the LOWER of max_delete_per_day and max_delete_pct of the
        # live facts, so it grows with the chat: at the defaults (5, 2%) the
        # percentage decides below 250 facts, and a 60-fact chat has a cap of 1,
        # making every merge oversized there. Such merges become possible as the
        # chat grows; `rake knowledge:reset_reviewed` brings them back sooner.
        if spend > day_cap
          logger.info "review: merge ids=#{m[:ids]} removes #{spend} facts, more than this chat's " \
                      "daily cap of #{day_cap} (lower of max_delete_per_day=#{config.max_delete_per_day} " \
                      "and max_delete_pct=#{config.max_delete_pct}% of its live facts); skipped"
          stats[:oversized] += 1
          next
        end
        if spent + spend > budget || n_merged >= config.max_merge_per_run
          logger.info "review: dropping merge ids=#{m[:ids]} (cap reached, not applied)"
          stats[:skipped] += 1
          stats[:cap_reached] = true
          resolved = false
          next
        end
        sources = m[:ids].map { |i| by_id[i] }
        logger.info "review MERGE ids=#{m[:ids]}\nBEFORE:\n" +
                    sources.map { |k| "  - [#{k.topic}] #{k.content}" }.join("\n") +
                    "\nAFTER:\n  - [#{m[:topic]}] #{m[:content]}"
        if config.dry_run
          stats[:would_merge]  += 1
          stats[:would_remove] += spend
          next
        end
        unless apply_merge(m, sources, chat_id)
          # Transient (the embeddings API failed): nothing was written, and the
          # cluster is left unstamped so the merge is retried on a later run.
          logger.warn "review: could not embed merged text for ids=#{m[:ids]}; merge not applied, will retry"
          stats[:embed_failures] += 1
          resolved = false
          next
        end
        stats[:merged]  += 1
        stats[:removed] += spend
      end

      deletes.each do |d|
        if (config.dry_run ? stats[:would_remove] : stats[:removed]) >= budget
          logger.info "review: dropping delete id=#{d[:id]} (cap reached, not applied)"
          stats[:skipped] += 1
          stats[:cap_reached] = true
          resolved = false
          next
        end
        logger.info "review DELETE id=#{d[:id]} reason=#{d[:reason]}: #{by_id[d[:id]].content}"
        if config.dry_run
          stats[:would_remove] += 1
          next
        end
        by_id[d[:id]].soft_delete!(d[:reason].empty? ? 'review' : d[:reason])
        stats[:deleted] += 1
        stats[:removed] += 1
      end
      resolved
    end

    # Returns true if the merge was written, false if nothing was (the merged
    # text could not be embedded).
    def apply_merge(m, sources, chat_id)
      # Subjects of the merged fact are the UNION of its sources': without this
      # the replacement drops out of every bucket it came from, shrinking those
      # buckets and shifting their centroids.
      uids = KnowledgeSubject.where(knowledge_id: sources.map(&:id)).distinct.pluck(:uid)
      # Embed BEFORE opening the transaction. The transaction takes SQLite's
      # write lock at its first write and holds it until COMMIT, so an HTTP call
      # after that point starves every other writer for its whole duration.
      vec = EmbeddingService.embed(m[:content])
      # Without a vector the merged fact is invisible to search and to review,
      # while its sources would be tombstoned in the same transaction -- the
      # content effectively gone. Write nothing instead.
      return false unless vec.is_a?(Array) && !vec.empty?
      ActiveRecord::Base.transaction do
        KnowledgeBase.add(topic: m[:topic], content: m[:content], chat_id: chat_id,
                          source: 'auto', subjects: uids, subject_source: 'merged',
                          merged_from: m[:ids], reviewed_at: Time.now, embedding: vec)
        sources.each { |k| k.soft_delete!('merged') }
      end
      true
    end
  end
end

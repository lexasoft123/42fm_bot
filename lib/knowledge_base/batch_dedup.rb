require 'set'

class KnowledgeBase
  # Collapses duplicates WITHIN one extraction batch, before anything is saved.
  #
  # The extractor pulls 3-7 facts from a 50-message window and often states one
  # conversation twice ("Sergey and Anton argue about Paxos" as ids 8258/8259).
  # Those siblings were the largest ongoing source of duplicates after launch,
  # and the persisted-fact sweep was the wrong tool for them: it had to wait
  # min_age_days, then tombstone one side and spend deletion budget. Here they
  # never reach the table.
  #
  # Same contract as the sweep: similarity only nominates, the LLM judge decides
  # (Review.request_verdict / Review.valid_merges), and anything that goes wrong
  # keeps the original facts. Losing a fact is worse than keeping a duplicate.
  #
  # Runs outside any transaction -- it makes network calls.
  module BatchDedup
    # Calibrated on the 922 facts extracted in the 24 days after launch: the
    # eight same-day duplicate pairs the judge approved sit at cosine
    # 0.554-0.743, while ordinary siblings from one batch run p50 0.29 /
    # p95 0.50. 0.50 nominates all eight with margin and calls the judge on
    # roughly half of all batches (~88 calls/month) -- the judge, not this
    # number, is the precision filter.
    DEFAULT_THRESHOLD = 0.50
    PURPOSE = 'knowledge_batch_dedup'.freeze

    module_function

    # `prepared` is [{topic:, content:, subjects:, embedding:}, ...] as built by
    # extract_and_store. Returns [prepared', collapsed] where `collapsed` is the
    # net number of facts removed from the batch. Never mutates the input.
    def run(prepared, chat_id:, logger:, threshold: DEFAULT_THRESHOLD)
      return [prepared, 0] if threshold.nil? || prepared.size < 2

      groups = similar_groups(prepared, threshold)
      return [prepared, 0] if groups.empty?

      facts     = prepared.map(&:dup)
      consumed  = Set.new   # positions folded into a merged fact
      dropped   = Set.new   # positions deleted as duplicates of a kept fact
      additions = []
      merged_into = {}      # position => index into additions

      groups.each do |group|
        # Prompt ids are 1-based positions in the batch; nothing has a DB id yet.
        entries = group.map { |i| "- id=#{i + 1} [источник: авто, дней: 0] #{facts[i][:content]}" }.join("\n")
        verdict = Review.request_verdict(entries, chat_id: chat_id, purpose: PURPOSE, logger: logger,
                                         label: "batch positions=#{group.map { |i| i + 1 }}")
        next unless verdict

        apply_merges(verdict, group, facts, consumed, additions, merged_into, chat_id, logger)
        apply_deletes(verdict, group, facts, consumed, dropped, additions, merged_into, chat_id, logger)
      end
      gone = consumed | dropped
      return [prepared, 0] if gone.empty?

      kept = facts.each_with_index.reject { |_, i| gone.include?(i) }.map(&:first)
      [kept + additions, gone.size - additions.size]
    rescue => e
      logger.warn "batch dedup failed for chat=#{chat_id}, keeping all facts: #{e.class}: #{e.message}"
      [prepared, 0]
    end

    def apply_merges(verdict, group, facts, consumed, additions, merged_into, chat_id, logger)
      Review.valid_merges(verdict, group.map { |i| i + 1 }).each do |m|
        members = m[:ids].map { |id| id - 1 }
        next if members.any? { |i| consumed.include?(i) }

        # The merged text needs its own vector. If that call fails, keep the
        # originals rather than store a fact that search can never find.
        vec = EmbeddingService.embed(m[:content])
        next unless usable?(vec)

        logger.info "batch MERGE chat=#{chat_id} positions=#{m[:ids]}\nBEFORE:\n" +
                    members.map { |i| "  - [#{facts[i][:topic]}] #{facts[i][:content]}" }.join("\n") +
                    "\nAFTER:\n  - [#{m[:topic]}] #{m[:content]}"
        additions << { topic: m[:topic], content: m[:content], embedding: vec,
                       subjects: members.flat_map { |i| Array(facts[i][:subjects]) }.uniq }
        members.each { |i| merged_into[i] = additions.size - 1 }
        consumed.merge(members)
      end
    end

    # The shared judge prompt calls a near-verbatim restatement a DELETE, not a
    # merge -- so for the most obvious sibling duplicates the natural verdict is
    # {"merge":[], "delete":[{"id":2,"reason":"duplicate"}]}. Ignoring that made
    # the batch keep both facts and log nothing.
    #
    # Only `duplicate` is honoured -- a freshly extracted fact is not dropped for
    # being "trivial"; other reasons are logged so the calibration can be
    # checked -- and only when the fact it duplicates is KNOWN to survive (see
    # survivor_for). The dropped fact's subjects move to that survivor.
    def apply_deletes(verdict, group, facts, consumed, dropped, additions, merged_into, chat_id, logger)
      positions = group.to_set
      Array(verdict['delete']).each do |d|
        next unless d.is_a?(Hash)
        i = d['id'].to_i - 1
        next unless positions.include?(i)
        next if consumed.include?(i) || dropped.include?(i)   # merge wins over delete

        reason = d['reason'].to_s.strip.downcase
        unless reason == 'duplicate'
          logger.info "batch: ignoring delete position=#{i + 1} reason=#{reason.inspect} " \
                      "(only duplicates are dropped at extraction): #{facts[i][:content]}"
          next
        end

        survivor = survivor_for(d['of'], i, group, consumed, dropped, merged_into)
        unless survivor
          logger.info "batch: ignoring duplicate-delete position=#{i + 1} of=#{d['of'].inspect}: " \
                      "cannot tell which fact carries its content"
          next
        end

        target = survivor[:addition] ? additions[survivor[:addition]] : facts[survivor[:position]]
        target[:subjects] = (Array(target[:subjects]) + Array(facts[i][:subjects])).uniq
        logger.info "batch DELETE duplicate chat=#{chat_id} position=#{i + 1}: #{facts[i][:content]}"
        dropped << i
      end
    end

    # The fact that carries a dropped duplicate's content on, or nil if that
    # can't be established -- in which case the delete is NOT applied.
    #
    # "Some other member of the group survives" is the wrong test: groups are
    # built by chaining similar pairs, so in [A, B, C] where only A and C are
    # duplicates, B surviving says nothing about A's or C's content. Dropping
    # both A and C (each "a duplicate of the other") would lose that content
    # for good -- nothing was saved yet -- and A's subjects would land on B.
    #
    # So: with `of`, that exact fact must survive, directly or folded into a
    # merge, and there is no fallback. Without `of`, only a two-member group is
    # unambiguous.
    def survivor_for(of, i, group, consumed, dropped, merged_into)
      target = if of
        named = of.to_i - 1
        return nil unless named != i && group.include?(named)
        named
      else
        return nil unless group.size == 2
        (group - [i]).first
      end
      return { addition: merged_into[target] } if merged_into.key?(target)
      return nil if consumed.include?(target) || dropped.include?(target)
      { position: target }
    end

    # Connected components over pairs at or above `threshold`, as arrays of
    # batch positions with at least two members. Transitive grouping is fine at
    # this scale (a batch is <= 7 facts) because the judge decides which
    # subsets, if any, are really the same fact.
    def similar_groups(prepared, threshold)
      vecs = prepared.map { |f| usable?(f[:embedding]) ? normalize(f[:embedding]) : nil }
      parent = (0...prepared.size).to_a
      find = ->(x) { x = parent[x] while parent[x] != x; x }
      (0...vecs.size).to_a.combination(2).each do |i, j|
        a, b = vecs[i], vecs[j]
        next unless a && b && a.size == b.size
        next unless a.zip(b).sum { |x, y| x * y } >= threshold
        ri, rj = find.(i), find.(j)
        parent[ri] = rj unless ri == rj
      end
      (0...vecs.size).select { |i| vecs[i] }
                     .group_by { |i| find.(i) }
                     .values
                     .select { |g| g.size >= 2 }
    end

    def usable?(vec)
      vec.is_a?(Array) && !vec.empty?
    end

    def normalize(vec)
      n = Math.sqrt(vec.sum { |x| x.to_f * x.to_f })
      return nil if n.zero?
      vec.map { |x| x.to_f / n }
    end
  end
end

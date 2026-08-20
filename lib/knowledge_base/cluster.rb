require 'numo/narray'
require 'numo/linalg'

class KnowledgeBase
  # Pure candidate generation: turns a chat's embeddings into small clusters of
  # facts that MIGHT be duplicates. It never merges or deletes anything — the
  # LLM judge in KnowledgeBase::Review decides, because sampled candidate
  # precision is only ~67% (G1) to ~80% (G2) -- merging on a threshold alone
  # would destroy information in a fifth to a third of cases.
  #
  # Two generators over two DIFFERENT similarity spaces:
  #
  #   G1 global   raw normalized cosine, threshold 0.66
  #               catches cross-person duplicates.
  #   G2 subject  per-person centroid-removed residual, threshold 0.42
  #               catches same-person, same-incident families.
  #
  # G2 exists because person identity dominates the embedding: two facts about
  # the same participant score ~0.60 largely BECAUSE both are about them.
  # Subtracting the bucket centroid cancels that shared direction. Measured on
  # prod, G2 finds 252 duplicate pairs that G1 cannot see at any safe threshold
  # (reaching them globally means dropping to ~0.58, which yields 5,475 pairs at
  # ~0% precision and a 3,113-fact giant component). The 0.55 threshold was
  # calibrated by sampling: 0.42 clusters whole biographies, 0.50 measures ~37%
  # precision, 0.55 ~80%, and the residual space has no pairs above ~0.65.
  #
  # The spaces must never be mixed inside one clustering pass. Those 252 pairs
  # sit at RAW cosine 0.58-0.66, so any raw-space admission test at 0.66
  # discards them — which would silently throw away the whole reason G2 exists.
  # So: seed-and-absorb runs once per space, and the resulting CLUSTERS are
  # unioned, never the pairs.
  module Cluster
    CHUNK_ROWS = 512

    Params = Struct.new(
      :threshold, :min_pairwise, :max_cluster,
      :subject_threshold, :subject_min_pairwise, :subject_min_facts, :subject_min_residual,
      keyword_init: true
    )

    module_function

    # Per-bucket residual norms, for `rake knowledge:cluster_preview`. Without
    # this there is no way to choose a `subject_min_residual`: a fact sitting
    # near its bucket mean has a tiny residual whose direction is mostly noise
    # once renormalized, and clustering it on equal footing is exactly how
    # confident-but-wrong clusters get made.
    def residual_norms(entry, buckets, params)
      pos = entry.ids.each_with_index.to_h
      out = []
      buckets.each_value do |fact_ids|
        idx = fact_ids.filter_map { |id| pos[id] }.uniq.sort
        next if idx.size < params.subject_min_facts
        sub = entry.matrix[idx, true]
        mu  = sub.mean(axis: 0)
        res = sub - mu.reshape(1, mu.size)
        out.concat(Numo::NMath.sqrt((res * res).sum(axis: 1)).to_a)
      end
      out
    end

    # Returns [[id, id, ...], ...] — each an unordered cluster of >= 2 fact ids,
    # no id appearing twice across the whole result.
    #
    # G2 emits first and claims its facts; G1 then runs over the unclaimed
    # remainder. G2 is the higher-precision generator on the evidence, and
    # first-claim-wins guarantees no fact lands in two clusters — so no merge
    # can ever operate on a row another merge already soft-deleted.
    def build(entry, buckets, params, skip: nil)
      return [] if entry.ids.empty? || entry.matrix.nil?

      # `skip` pre-claims facts judged recently enough that re-judging them
      # would just re-pay for the same refusal.
      claimed = {}
      Array(skip).each { |id| claimed[id] = true }
      out = []

      out.concat(subject_clusters(entry, buckets, params, claimed))
      out.concat(seed_and_absorb(entry.matrix, entry.ids, params.threshold,
                                 params.min_pairwise, params.max_cluster, claimed))
      out
    end

    # G2. `buckets` is {uid => [knowledge_id, ...]}, already filtered to live
    # facts. Bucket membership and centroids are computed ONCE here and frozen
    # for the run: merges soft-delete sources and insert new facts, and a space
    # that moves underneath the sweep produces incoherent clusters.
    def subject_clusters(entry, buckets, params, claimed)
      return [] if buckets.nil? || buckets.empty?
      pos = entry.ids.each_with_index.to_h
      out = []

      # Multi-bucket facts (23% of the prod corpus name two people) are scored
      # in EVERY bucket; the best-scoring cluster wins. Iterating buckets and
      # letting `claimed` lock a fact into whichever came first would make the
      # choice depend on SQLite row order.
      proposals = []
      buckets.each do |_uid, fact_ids|
        idx = fact_ids.filter_map { |id| pos[id] }.uniq.sort
        next if idx.size < params.subject_min_facts

        sub = entry.matrix[idx, true]
        mu  = sub.mean(axis: 0)
        res = sub - mu.reshape(1, mu.size)
        norms = Numo::NMath.sqrt((res * res).sum(axis: 1))

        # A fact sitting near its bucket mean has a tiny residual whose
        # direction is mostly noise once renormalized, so a 0.42 score between
        # two such facts is far weaker evidence than between two distinctive
        # ones. Drop them rather than letting normalization amplify them.
        keep = (0...idx.size).select { |i| norms[i] >= params.subject_min_residual }
        next if keep.size < 2

        res  = res[keep, true] / Numo::SFloat.maximum(norms[keep].reshape(keep.size, 1), 1e-12)
        ids  = keep.map { |i| entry.ids[idx[i]] }
        # Local `claimed` so each bucket proposes independently.
        seed_and_absorb(res, ids, params.subject_threshold,
                        params.subject_min_pairwise, params.max_cluster, {}).each do |cluster|
          proposals << [cohesion(res, ids, cluster), cluster]
        end
      end

      # Strongest proposals first; a fact already taken by a better cluster is
      # not re-clustered.
      proposals.sort_by { |score, _| -score }.each do |_score, cluster|
        next if cluster.any? { |id| claimed[id] }
        cluster.each { |id| claimed[id] = true }
        out << cluster
      end
      out
    end

    # Mean pairwise similarity inside a cluster, in the space it was found in.
    # Used only to rank competing proposals for the same fact.
    def cohesion(matrix, ids, cluster)
      pos = ids.each_with_index.to_h
      rows = cluster.map { |id| pos[id] }
      sub  = matrix[rows, true]
      sim  = Numo::Linalg.matmul(sub, sub.transpose)
      n = rows.size
      return 0.0 if n < 2
      total = 0.0
      (0...n).each { |i| ((i + 1)...n).each { |j| total += sim[i, j] } }
      total / (n * (n - 1) / 2.0)
    end

    # Leader clustering. Every member is within `threshold` of the SEED, so a
    # cluster has a bounded semantic radius and chains cannot form — unlike the
    # union-find this replaced, whose transitive closure produced a 1,385-fact
    # component at 0.62. The size cap is native (top-K by similarity to the
    # seed), which is what makes the merge prompt bounded by construction.
    #
    # `matrix` must be L2-normalized in ITS OWN space, and `ids[i]` names row i.
    # `claimed` is mutated: shared across generators to enforce first-claim-wins.
    def seed_and_absorb(matrix, ids, threshold, min_pairwise, max_cluster, claimed)
      n = ids.size
      return [] if n < 2

      degree = degrees(matrix, threshold)
      order  = (0...n).sort_by { |i| [-degree[i], i] }
      out    = []

      order.each do |seed|
        next if claimed[ids[seed]]
        next if degree[seed].zero?

        row  = matrix.dot(matrix[seed, true])
        cand = (row >= threshold).where.to_a
                                 .reject { |i| claimed[ids[i]] }
                                 .sort_by { |i| [-row[i], i] }
                                 .first(max_cluster)
        next if cand.size < 2

        cand = prune_by_min_pairwise(matrix, cand, min_pairwise)
        next if cand.size < 2

        cand.each { |i| claimed[ids[i]] = true }
        out << cand.map { |i| ids[i] }
      end
      out
    end

    # Number of in-space neighbours at or above the threshold, per row.
    # Row-chunked: the full N x N matrix for the prod main chat would be 143 MB,
    # and this runs inside one of only two TaskRunner workers.
    def degrees(matrix, threshold)
      n  = matrix.shape[0]
      mt = matrix.transpose.dup
      deg = Array.new(n, 0)
      (0...n).step(CHUNK_ROWS) do |i0|
        i1    = [i0 + CHUNK_ROWS, n].min
        block = matrix[i0...i1, true].dot(mt)
        counts = (block >= threshold).count_true(axis: 1)  # Numo::Bit has no #sum
        (i0...i1).each { |i| deg[i] = counts[i - i0] - 1 }  # minus self
      end
      deg
    end

    # Drop members that are close to the seed but far from each other. Keeps a
    # seed's two mutually-unlike neighbours from being force-merged. `cand[0]`
    # is the seed (highest similarity to itself).
    def prune_by_min_pairwise(matrix, cand, min_pairwise)
      return cand if cand.size <= 2
      sub = matrix[cand, true]
      sim = Numo::Linalg.matmul(sub, sub.transpose)
      kept = [0]
      (1...cand.size).each do |j|
        kept << j if kept.all? { |k| sim[j, k] >= min_pairwise }
      end
      kept.map { |j| cand[j] }
    end
  end
end

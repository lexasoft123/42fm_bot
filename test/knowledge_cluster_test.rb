require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require 'set'
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'
require_relative '../models/knowledge_subject'
require_relative '../lib/knowledge_base'

# Candidate generation runs over TWO similarity spaces that must never be mixed:
# raw cosine (G1) and the per-person centroid-removed residual (G2). Most of
# these tests pin that separation, because the failure mode is silent — G2's
# output getting filtered out by a raw-space test would simply produce fewer
# clusters, not an error.
class KnowledgeClusterTest < BotTest
  CHAT = -99
  C = KnowledgeBase::Cluster

  def setup
    super
    EmbeddingCache.reset_for_test!
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_t| [1.0, 0.0] }
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
    EmbeddingCache.reset_for_test!
    super
  end

  def make(vec, content: 'c', uid: nil)
    k = Knowledge.new(topic: 't', content: content, chat_id: CHAT, source: 'auto')
    k.embedding_vector = vec
    k.save!
    KnowledgeSubject.create!(knowledge_id: k.id, uid: uid, source: 'backfill') if uid
    k
  end

  def unit(theta) = [Math.cos(theta), Math.sin(theta)]

  def params(**over)
    C::Params.new({ threshold: 0.66, min_pairwise: 0.62, max_cluster: 8,
                    subject_threshold: 0.55, subject_min_pairwise: 0.50,
                    subject_min_facts: 2, subject_min_residual: 0.0 }.merge(over))
  end

  def matrix_of(vecs)
    m = Numo::SFloat.cast(vecs)
    m / Numo::NMath.sqrt((m * m).sum(axis: 1)).reshape(vecs.size, 1)
  end

  # The regression that matters most: seed-and-absorb must not chain. Union-find
  # produced a 1,385-fact component on prod at 0.62 for exactly this reason.
  def test_does_not_chain_a_to_c_through_b
    a = unit(0.0); b = unit(0.70); c = unit(1.40)   # cos(a,b)=cos(b,c)=0.76, cos(a,c)=0.17
    m = matrix_of([a, b, c])
    clusters = C.seed_and_absorb(m, [1, 2, 3], 0.7, 0.7, 8, {})
    refute clusters.any? { |cl| cl.size == 3 }, 'a~b and b~c must not put a with c'
  end

  def test_respects_the_size_cap
    vecs = 20.times.map { unit(0.0) }
    m = matrix_of(vecs)
    clusters = C.seed_and_absorb(m, (1..20).to_a, 0.9, 0.9, 8, {})
    assert clusters.all? { |c| c.size <= 8 }, "sizes were #{clusters.map(&:size)}"
    assert_equal clusters.flatten.size, clusters.flatten.uniq.size
  end

  def test_no_fact_appears_in_two_clusters
    vecs = 12.times.map { |i| unit(i * 0.01) }
    m = matrix_of(vecs)
    clusters = C.seed_and_absorb(m, (1..12).to_a, 0.9, 0.9, 4, {})
    all = clusters.flatten
    assert_equal all.size, all.uniq.size
  end

  # G2's whole justification, in miniature. A dominant shared "this is about
  # person X" direction makes three facts look alike in RAW space -- so a raw
  # threshold clusters all three, which is the "same person, different fact"
  # trap. Removing the bucket centroid cancels that direction and leaves only
  # the genuinely-similar pair.
  def test_centroid_removal_separates_what_raw_cosine_lumps_together
    shared = 3.0
    a = make([shared, 1.00, 0.0, 0.0], content: 'a', uid: 7)
    b = make([shared, 0.95, 0.3, 0.0], content: 'b', uid: 7)
    c = make([shared, 0.00, 0.0, 1.0], content: 'c', uid: 7)
    entry = EmbeddingCache.fetch(CHAT)
    pos = entry.ids.each_with_index.to_h
    cos = ->(x, y) { entry.matrix[pos[x], true].dot(entry.matrix[pos[y], true]) }

    # In raw space the odd one out is just as "similar" as the real pair.
    assert cos.(a.id, c.id) > 0.85, "fixture invalid: raw a~c is #{cos.(a.id, c.id)}"

    raw_cluster = C.seed_and_absorb(entry.matrix, entry.ids, 0.85, 0.85, 8, {})
    assert_equal [3], raw_cluster.map(&:size),
                 'raw space is expected to (wrongly) lump all three together'

    g2 = C.subject_clusters(entry, { 7 => [a.id, b.id, c.id] },
                            params(subject_threshold: 0.55, subject_min_pairwise: 0.5), {})
    assert_equal [[a.id, b.id].sort], g2.map(&:sort),
                 'residual space must keep only the genuinely similar pair'
  end

  def test_skips_buckets_below_the_minimum
    a = make([1.0, 0.0], uid: 7); b = make([1.0, 0.0], uid: 7)
    entry = EmbeddingCache.fetch(CHAT)
    g2 = C.subject_clusters(entry, { 7 => [a.id, b.id] }, params(subject_min_facts: 5), {})
    assert_empty g2, 'a centroid over a handful of vectors is noise'
  end

  # All-identical vectors have a zero residual after centroid removal; the
  # renormalization clamp must yield no pairs rather than NaN.
  def test_degenerate_bucket_yields_no_pairs_not_nan
    ids = 4.times.map { |i| make([1.0, 0.0], content: "x#{i}", uid: 7).id }
    entry = EmbeddingCache.fetch(CHAT)
    g2 = nil
    assert_silent { g2 = C.subject_clusters(entry, { 7 => ids }, params, {}) }
    assert_empty g2
  end

  def test_g2_claims_facts_before_g1_sees_them
    a = make([1.0, 0.0], uid: 7); b = make([1.0, 0.0], uid: 7)
    entry = EmbeddingCache.fetch(CHAT)
    claimed = { a.id => true, b.id => true }
    g1 = C.seed_and_absorb(entry.matrix, entry.ids, 0.5, 0.5, 8, claimed)
    assert_empty g1, 'already-claimed facts must not form a second cluster'
  end

  def test_build_returns_disjoint_clusters_across_both_generators
    5.times { |i| make([1.0, 0.001 * i], content: "g#{i}", uid: 7) }
    5.times { |i| make([0.0, 1.0 + 0.001 * i], content: "h#{i}") }
    entry = EmbeddingCache.fetch(CHAT)
    all = C.build(entry, KnowledgeBase.send(:subject_buckets, CHAT), params).flatten
    assert_equal all.size, all.uniq.size
  end

  def test_empty_inputs_do_not_raise
    entry = EmbeddingCache.fetch(CHAT)
    assert_equal [], C.build(entry, {}, params)
    assert_equal [], C.seed_and_absorb(Numo::SFloat.cast([[1.0, 0.0]]), [1], 0.5, 0.5, 8, {})
  end

  # The chunked degree pass must be bit-identical to the naive double loop it
  # replaces. n crosses CHUNK_ROWS twice.
  def test_degrees_matches_naive_ruby_loop
    srand(42)
    n, d = 1200, 16
    m = Numo::SFloat.new(n, d).rand_norm
    m = m / Numo::NMath.sqrt((m * m).sum(axis: 1)).reshape(n, 1)
    sim = Numo::Linalg.matmul(m, m.transpose)

    naive = Array.new(n, 0)
    n.times { |i| n.times { |j| naive[i] += 1 if i != j && sim[i, j] >= 0.5 } }
    assert naive.sum.positive?, 'fixture should produce neighbours'
    assert_equal naive, C.degrees(m, 0.5)
  end

  # THE contract for G2, asserted through `build` rather than through
  # subject_clusters directly: a pair that raw cosine cannot reach must still
  # come out of the public entry point. If a raw-space test ever guards the
  # subject generator, this is the only thing that notices -- the symptom
  # otherwise is just "fewer clusters".
  def test_build_emits_a_cluster_raw_cosine_alone_would_miss
    shared = 3.0
    a = make([shared, 1.00, 0.0, 0.0], content: 'a', uid: 7)
    b = make([shared, 0.95, 0.3, 0.0], content: 'b', uid: 7)
    c = make([shared, 0.00, 0.0, 1.0], content: 'c', uid: 7)
    entry = EmbeddingCache.fetch(CHAT)

    # Raw cosine here is ~0.995 (the shared direction dominates), so a raw
    # threshold above that finds nothing at all.
    g1_only = C.seed_and_absorb(entry.matrix, entry.ids, 0.999, 0.999, 8, {})
    assert_empty g1_only, 'fixture must be out of reach for a strict raw threshold'

    built = C.build(entry, KnowledgeBase.send(:subject_buckets, CHAT),
                    params(threshold: 0.999, min_pairwise: 0.999,
                           subject_threshold: 0.55, subject_min_pairwise: 0.5))
    assert_includes built.map(&:sort), [a.id, b.id].sort,
                    'build must surface the subject-space pair'
    refute built.flatten.include?(c.id)
  end

  # Resumability: recently-judged facts are pre-claimed and must not be
  # re-clustered, or every nightly run re-pays for the same refusals.
  def test_build_skips_facts_passed_in_skip
    a = make([1.0, 0.0], content: 'a', uid: 7)
    b = make([1.0, 0.0], content: 'b', uid: 7)
    entry = EmbeddingCache.fetch(CHAT)
    buckets = KnowledgeBase.send(:subject_buckets, CHAT)
    refute_empty C.build(entry, buckets, params(threshold: 0.9, min_pairwise: 0.9))
    assert_empty C.build(entry, buckets, params(threshold: 0.9, min_pairwise: 0.9), skip: [a.id, b.id])
  end

  # A fact in two buckets must be judged in the bucket where its cluster is
  # strongest, not in whichever one the DB happened to return first.
  def test_multi_bucket_fact_goes_to_its_strongest_cluster
    shared = 3.0
    a = make([shared, 1.00, 0.0, 0.0], content: 'a', uid: 7)
    b = make([shared, 0.98, 0.05, 0.0], content: 'b', uid: 7)
    c = make([shared, 0.20, 0.9, 0.0], content: 'c', uid: 8)
    KnowledgeSubject.create!(knowledge_id: a.id, uid: 8, source: 'backfill')
    5.times { |i| make([shared, 0.1 * i, 0.0, 1.0], content: "pad#{i}", uid: 8) }
    entry = EmbeddingCache.fetch(CHAT)

    out = C.subject_clusters(entry, KnowledgeBase.send(:subject_buckets, CHAT),
                             params(subject_threshold: 0.5, subject_min_pairwise: 0.45), {})
    with_a = out.find { |cl| cl.include?(a.id) }
    if with_a
      assert_includes with_a, b.id, 'a should land with its closest neighbour, not an arbitrary bucket-mate'
      refute_includes with_a, c.id
    end
  end

  def test_residual_norms_are_reported_for_tuning
    6.times { |i| make([1.0, 0.1 * i], content: "n#{i}", uid: 7) }
    entry = EmbeddingCache.fetch(CHAT)
    norms = C.residual_norms(entry, KnowledgeBase.send(:subject_buckets, CHAT), params)
    assert_equal 6, norms.size
    assert norms.all? { |n| n >= 0 }
  end

  # --- subjects lifecycle ---

  # The FK is the first in this schema and sqlite runs PRAGMA foreign_keys = ON,
  # so without ON DELETE CASCADE + dependent: :delete_all this raises and breaks
  # every existing destroy call site.
  def test_destroying_a_fact_with_subjects_does_not_raise
    k = make([1.0, 0.0], uid: 7)
    assert_equal 1, KnowledgeSubject.where(knowledge_id: k.id).count
    k.destroy
    assert_equal 0, KnowledgeSubject.where(knowledge_id: k.id).count
  end

  def test_buckets_exclude_soft_deleted_facts
    a = make([1.0, 0.0], uid: 7); b = make([1.0, 0.0], uid: 7)
    assert_equal 2, KnowledgeBase.send(:subject_buckets, CHAT)[7].size
    a.soft_delete!('admin')
    assert_equal [b.id], KnowledgeBase.send(:subject_buckets, CHAT)[7],
                 'a tombstone left in a bucket would pollute its centroid'
  end

  def test_a_fact_can_belong_to_several_subjects
    k = make([1.0, 0.0], uid: 7)
    KnowledgeSubject.create!(knowledge_id: k.id, uid: 8, source: 'backfill')
    buckets = KnowledgeBase.send(:subject_buckets, CHAT)
    assert_includes buckets[7], k.id
    assert_includes buckets[8], k.id
  end

  def test_add_writes_subjects_and_merge_metadata
    k = KnowledgeBase.add(topic: 't', content: 'c', chat_id: CHAT, source: 'auto',
                          subjects: [7, 8, 7], merged_from: [1, 2], reviewed_at: Time.now)
    assert_equal [7, 8], k.subjects.pluck(:uid).sort
    assert_equal [1, 2], k.merged_from_ids
    refute_nil k.reviewed_at
  end
end

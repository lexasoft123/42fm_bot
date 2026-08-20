require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
COMPACT_LOGGER ||= Logger.new(IO::NULL) unless defined?(COMPACT_LOGGER)
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'
require_relative '../lib/knowledge_base'

# Tests for KnowledgeBase#search, which runs on every agent turn. Scoring is a
# single BLAS matvec against EmbeddingCache's pre-normalized per-chat matrix;
# before that it loaded and JSON-parsed the whole per-chat table (~171 MB /
# ~1150 ms for the prod main chat) on every request.
#
# `similar_exists?` and its four tests were deleted along with the 0.92 write
# gate: measured over all 18.8M pairs of the prod main chat the maximum
# similarity between any two facts is 0.6994, so the gate had never fired.
#
# We don't stub Numo — it's the production path under test. We stub
# EmbeddingService.embed because the real one calls OpenAI.
class KnowledgeBaseTest < BotTest
  CHAT = -42

  def setup
    super
    EmbeddingCache.reset_for_test!
    # Stub EmbeddingService.embed to return a configurable vector per call.
    @stub_embed = nil
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |text| KnowledgeBaseTest.stub_embed_for(text) }
    self.class.instance_variable_set(:@stubbed, {})
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
    EmbeddingCache.reset_for_test!
    super
  end

  def self.stub_embed_for(text)
    @stubbed[text]
  end

  def stub_embed(text, vec)
    self.class.instance_variable_get(:@stubbed)[text] = vec
  end

  def make_record(content:, vec:, topic: 't', chat_id: CHAT)
    k = Knowledge.new(topic: topic, content: content, chat_id: chat_id, source: 'manual')
    k.embedding_vector = vec
    k.save!
    k
  end

  # --- search ---

  def test_search_returns_top_k_ordered_by_similarity
    a = make_record(content: 'cats',  vec: [1.0, 0.0])  # exact match for query
    b = make_record(content: 'dogs',  vec: [0.5, 0.5])  # 45° off
    c = make_record(content: 'fish',  vec: [0.0, 1.0])  # orthogonal
    stub_embed('q', [1.0, 0.0])

    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 3)
    assert_equal [a.id, b.id, c.id], result.map(&:id), 'should rank exact > 45° > orthogonal'
  end

  def test_search_respects_top_k_limit
    3.times { |i| make_record(content: "f#{i}", vec: [1.0, i.to_f]) }
    stub_embed('q', [1.0, 0.0])
    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 2)
    assert_equal 2, result.size
  end

  def test_search_respects_offset
    a = make_record(content: 'a', vec: [1.0, 0.0])    # rank 1
    b = make_record(content: 'b', vec: [0.9, 0.1])    # rank 2
    c = make_record(content: 'c', vec: [0.1, 0.9])    # rank 3
    stub_embed('q', [1.0, 0.0])

    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 1, offset: 1)
    assert_equal [b.id], result.map(&:id), 'offset=1 should skip the top match'

    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 5, offset: 2)
    assert_equal [c.id], result.map(&:id), 'offset=2 + top_k=5 should yield only the 3rd entry'
  end

  def test_search_returns_empty_when_no_records
    stub_embed('q', [1.0, 0.0])
    assert_equal [], KnowledgeBase.search('q', chat_id: CHAT)
  end

  def test_search_returns_empty_when_embedder_fails
    make_record(content: 'a', vec: [1.0, 0.0])
    # stub returns nil — embedder failure
    assert_equal [], KnowledgeBase.search('q', chat_id: CHAT)
  end

  def test_search_skips_records_in_other_chats
    own = make_record(content: 'own', vec: [1.0, 0.0], chat_id: CHAT)
    make_record(content: 'other', vec: [1.0, 0.0], chat_id: -999)
    stub_embed('q', [1.0, 0.0])
    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 5)
    assert_equal [own.id], result.map(&:id)
  end

  # Was `test_search_skips_records_with_nil_embedding`. Renamed because the
  # predicate changed with migration 023: a row is now skipped only when BOTH
  # `embedding` and `embedding_blob` are empty, not when `embedding` alone is.
  def test_search_skips_records_with_no_embedding_in_either_column
    a = make_record(content: 'a', vec: [1.0, 0.0])
    nil_row = Knowledge.create!(topic: 't', content: 'b', chat_id: CHAT, source: 'manual',
                                embedding: nil, embedding_blob: nil)
    stub_embed('q', [1.0, 0.0])
    result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 5)
    assert_equal [a.id], result.map(&:id)
    refute_includes result.map(&:id), nil_row.id
  end

  def test_search_handles_zero_norm_query_gracefully
    make_record(content: 'a', vec: [1.0, 0.0])
    stub_embed('q', [0.0, 0.0])  # degenerate query — no direction
    assert_equal [], KnowledgeBase.search('q', chat_id: CHAT)
  end

  # Numerical equivalence: BLAS path returns the SAME ranking as a pure-Ruby
  # cosine loop would. Lock the contract so a future BLAS regression doesn't
  # silently degrade rank quality.
  def test_search_blas_ranking_matches_pure_ruby_cosine
    vecs = [
      [1.0, 0.0, 0.0],
      [0.7, 0.5, 0.5],
      [0.0, 1.0, 0.0],
      [-1.0, 0.1, 0.0],   # negative similarity to query
      [0.5, 0.5, 0.7],
    ]
    records = vecs.each_with_index.map { |v, i| make_record(content: "v#{i}", vec: v) }
    query = [1.0, 0.2, 0.0]
    stub_embed('q', query)

    expected = records.map { |r| [r, ruby_cosine(query, r.embedding_vector)] }
                     .sort_by { |_, s| -s }.first(3).map { |r, _| r.id }
    actual = KnowledgeBase.search('q', chat_id: CHAT, top_k: 3).map(&:id)
    assert_equal expected, actual, 'BLAS ranking must match pure-Ruby cosine ranking'
  end

  # --- storage format (migration 023) ---

  def test_embedding_vector_roundtrips_as_packed_float32
    vec = [0.25, -0.5, 0.75]
    k = make_record(content: 'a', vec: vec)
    k.reload
    assert_equal 4 * vec.size, k.embedding_blob.bytesize
    k.embedding_vector.zip(vec).each { |got, want| assert_in_delta want, got, 1e-6 }
  end

  def test_embedding_vector_reads_legacy_json_when_blob_absent
    k = Knowledge.create!(topic: 't', content: 'legacy', chat_id: CHAT, source: 'manual',
                          embedding: [1.0, 0.0].to_json, embedding_blob: nil)
    assert_equal [1.0, 0.0], k.reload.embedding_vector
  end

  # Dual-write is the rollback path for migration 023: reverting the code must
  # leave post-deploy facts still readable via the legacy JSON column.
  def test_write_populates_both_columns_while_dual_write_is_on
    k = make_record(content: 'a', vec: [1.0, 0.0]).reload
    refute_nil k.embedding_blob
    refute_nil k.embedding
    assert_equal [1.0, 0.0], JSON.parse(k.embedding)
  end

  # A blob-only row (post-cutover, or mid-backfill) must be fully searchable.
  def test_search_returns_blob_only_rows
    k = make_record(content: 'a', vec: [1.0, 0.0])
    k.update_columns(embedding: nil)
    EmbeddingCache.reset_for_test!
    stub_embed('q', [1.0, 0.0])
    assert_equal [k.id], KnowledgeBase.search('q', chat_id: CHAT, top_k: 5).map(&:id)
  end

  # Regression: a stored zero-norm vector used to produce NaN, and NaN makes
  # `sort_by` raise ArgumentError deep inside search.
  def test_search_tolerates_zero_norm_stored_record
    good = make_record(content: 'good', vec: [1.0, 0.0])
    zero = make_record(content: 'zero', vec: [0.0, 0.0])
    stub_embed('q', [1.0, 0.0])
    result = nil
    assert_silent { result = KnowledgeBase.search('q', chat_id: CHAT, top_k: 2) }
    assert_equal good.id, result.first.id
    assert_equal [good.id, zero.id], result.map(&:id)
  end

  # A changed embeddings model must yield no results rather than scores against
  # vectors of a different dimension.
  def test_search_returns_empty_on_query_dimension_mismatch
    make_record(content: 'a', vec: [1.0, 0.0])
    stub_embed('q', [1.0, 0.0, 0.0])
    assert_equal [], KnowledgeBase.search('q', chat_id: CHAT)
  end

  # The cutover branch: once `dual_write_legacy` is off, only the blob is
  # written. This is the irreversible step (drop_legacy_embeddings follows it),
  # and the shared test Settings stub makes it default to ON, so without an
  # explicit stub this branch would never execute in the suite.
  def test_cutover_writes_blob_only_and_stays_searchable
    Knowledge.singleton_class.send(:alias_method, :__dwl, :dual_write_legacy?)
    Knowledge.singleton_class.send(:define_method, :dual_write_legacy?) { false }
    begin
      k = make_record(content: 'a', vec: [1.0, 0.0]).reload
      refute_nil k.embedding_blob
      assert_nil k.embedding, 'legacy column must stay empty after cutover'
      EmbeddingCache.reset_for_test!
      stub_embed('q', [1.0, 0.0])
      assert_equal [k.id], KnowledgeBase.search('q', chat_id: CHAT, top_k: 5).map(&:id)
    ensure
      Knowledge.singleton_class.send(:alias_method, :dual_write_legacy?, :__dwl)
      Knowledge.singleton_class.send(:remove_method, :__dwl)
    end
  end

  # An empty vector must store NOTHING. An empty blob reads back as "no
  # embedding" but would satisfy a naive `embedding_blob IS NOT NULL` scope --
  # which is how drop_legacy_embeddings could have nulled the only surviving
  # copy. EmbeddingService.embed returns [] on a malformed 200, and [] is truthy.
  def test_empty_vector_stores_no_embedding_at_all
    k = Knowledge.new(topic: 't', content: 'empty', chat_id: CHAT, source: 'manual')
    k.embedding_vector = []
    k.save!
    k.reload
    assert_nil k.embedding_blob
    assert_nil k.embedding
    assert_nil k.embedding_vector
    assert_includes Knowledge.where(chat_id: CHAT).pluck(:id), k.id
    refute_includes Knowledge.packed_embeddings.pluck(:id), k.id
    refute_includes Knowledge.unpacked_embeddings.pluck(:id), k.id
  end

  def test_add_ignores_empty_embedding_response
    stub_embed('c', [])
    k = KnowledgeBase.add(topic: 't', content: 'c', chat_id: CHAT, source: 'auto')
    assert_nil k.reload.embedding_blob
  end

  # The scopes the destructive rake task's refuse-guard is built on. A row with
  # an EMPTY blob plus valid JSON must count as unpacked (so the guard fires)
  # and must NOT count as packed (so its JSON is never cleared).
  def test_scopes_treat_empty_blob_as_missing
    legacy = Knowledge.create!(topic: 't', content: 'l', chat_id: CHAT, source: 'manual',
                               embedding: [1.0, 0.0].to_json, embedding_blob: nil)
    empty  = Knowledge.create!(topic: 't', content: 'e', chat_id: CHAT, source: 'manual',
                               embedding: [1.0, 0.0].to_json, embedding_blob: '')
    both   = make_record(content: 'b', vec: [1.0, 0.0])

    unpacked = Knowledge.unpacked_embeddings.pluck(:id)
    packed   = Knowledge.packed_embeddings.pluck(:id)
    assert_includes unpacked, legacy.id
    assert_includes unpacked, empty.id, 'empty blob must count as unpacked, or the guard misses it'
    refute_includes packed, empty.id,  'empty blob must never be treated as safe to clear'
    assert_includes packed, both.id
  end

  private

  # Reference cosine — used only in `test_search_blas_ranking_matches_pure_ruby_cosine`
  # to verify BLAS equivalence. Don't reuse this in production paths.
  def ruby_cosine(a, b)
    dot   = a.zip(b).sum { |x, y| x * y }
    norm_a = Math.sqrt(a.sum { |x| x**2 })
    norm_b = Math.sqrt(b.sum { |x| x**2 })
    return 0.0 if norm_a.zero? || norm_b.zero?
    dot / (norm_a * norm_b)
  end
end

require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
COMPACT_LOGGER ||= Logger.new(IO::NULL) unless defined?(COMPACT_LOGGER)
require_relative '../lib/embedding_service'
require_relative '../lib/knowledge_base'

# Tests for the BLAS-batched cosine similarity in KnowledgeBase#search and
# #similar_exists?. These two methods run on every agent turn and on every
# fact-extraction round respectively, so per-call latency must scale with
# Numo, not a Ruby loop. Pre-fix, a chat with 2249 stored facts spent ~7s in
# the Ruby cosine loop on every `бот <text>` request.
#
# We don't stub Numo — it's the production path under test. We stub
# EmbeddingService.embed because the real one calls OpenAI.
class KnowledgeBaseTest < BotTest
  CHAT = -42

  def setup
    super
    # Stub EmbeddingService.embed to return a configurable vector per call.
    @stub_embed = nil
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |text| KnowledgeBaseTest.stub_embed_for(text) }
    self.class.instance_variable_set(:@stubbed, {})
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
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

  def test_search_skips_records_with_nil_embedding
    a = make_record(content: 'a', vec: [1.0, 0.0])
    nil_row = Knowledge.create!(topic: 't', content: 'b', chat_id: CHAT, source: 'manual', embedding: nil)
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

  # --- similar_exists? ---

  def test_similar_exists_true_when_above_threshold
    make_record(content: 'fact', vec: [1.0, 0.0])
    stub_embed('candidate', [0.999, 0.045])  # cos ≈ 0.999, well above 0.92
    assert KnowledgeBase.send(:similar_exists?, 'candidate', chat_id: CHAT)
  end

  def test_similar_exists_false_when_below_threshold
    make_record(content: 'fact', vec: [1.0, 0.0])
    stub_embed('candidate', [0.5, 0.866])  # cos ≈ 0.5, well below 0.92
    refute KnowledgeBase.send(:similar_exists?, 'candidate', chat_id: CHAT)
  end

  def test_similar_exists_false_on_empty_knowledge
    stub_embed('candidate', [1.0, 0.0])
    refute KnowledgeBase.send(:similar_exists?, 'candidate', chat_id: CHAT)
  end

  def test_similar_exists_false_when_embedder_fails
    make_record(content: 'fact', vec: [1.0, 0.0])
    refute KnowledgeBase.send(:similar_exists?, 'candidate', chat_id: CHAT)
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

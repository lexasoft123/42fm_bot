require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'
require_relative '../lib/knowledge_base'

# EmbeddingCache holds one normalized float32 matrix per chat so that
# KnowledgeBase#search is a single matvec instead of a full per-chat table read
# (~171 MB / ~1150 ms of JSON.parse for the prod main chat, on every turn).
#
# Two contracts matter most and both are covered below:
#   1. Invalidation is driven by an `after_commit` callback on Knowledge, NOT
#      by discipline at each call site — a stale cache means silently wrong
#      search results.
#   2. `fetch` never blocks. It is reached from bot.listen's single-threaded
#      loop, and a build takes ~1.5s on the legacy path.
class EmbeddingCacheTest < BotTest
  CHAT  = -100
  OTHER = -200

  def setup
    super
    EmbeddingCache.reset_for_test!
    # KnowledgeBase.add embeds through the real service otherwise.
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_text| [0.0, 1.0] }
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
    EmbeddingCache.reset_for_test!
    super
  end

  def make(vec, chat_id: CHAT, content: 'c')
    k = Knowledge.new(topic: 't', content: content, chat_id: chat_id, source: 'manual')
    k.embedding_vector = vec
    k.save!
    k
  end

  def count_knowledge_selects
    n = 0
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      n += 1 if payload[:sql] =~ /SELECT.*FROM\s+"knowledge"/i
    end
    yield
    n
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_matrix_is_built_once_and_reused
    make([1.0, 0.0])
    EmbeddingCache.fetch(CHAT)                       # warm
    n = count_knowledge_selects { 3.times { EmbeddingCache.fetch(CHAT) } }
    assert_equal 0, n, 'a warm cache must not touch the knowledge table'
    assert_equal 3, EmbeddingCache.stats[CHAT][:hits]
  end

  def test_add_invalidates
    make([1.0, 0.0])
    assert_equal 1, EmbeddingCache.fetch(CHAT).ids.size
    KnowledgeBase.add(topic: 't', content: 'new', chat_id: CHAT, source: 'manual')
    assert_equal 2, EmbeddingCache.fetch(CHAT).ids.size
  end

  def test_destroy_invalidates
    a = make([1.0, 0.0])
    make([0.0, 1.0])
    assert_equal 2, EmbeddingCache.fetch(CHAT).ids.size
    a.destroy
    assert_equal 1, EmbeddingCache.fetch(CHAT).ids.size
  end

  # The contract is the callback, not the call site: a write that bypasses
  # KnowledgeBase entirely must still invalidate.
  def test_direct_create_invalidates
    make([1.0, 0.0])
    assert_equal 1, EmbeddingCache.fetch(CHAT).ids.size
    k = Knowledge.new(topic: 't', content: 'direct', chat_id: CHAT, source: 'manual')
    k.embedding_vector = [0.0, 1.0]
    k.save!
    assert_equal 2, EmbeddingCache.fetch(CHAT).ids.size
  end

  def test_update_invalidates
    k = make([1.0, 0.0])
    EmbeddingCache.fetch(CHAT)
    k.embedding_vector = [0.0, 1.0]
    k.save!
    entry = EmbeddingCache.fetch(CHAT)
    assert_in_delta 0.0, entry.matrix[0, 0], 1e-6
    assert_in_delta 1.0, entry.matrix[0, 1], 1e-6
  end

  def test_invalidation_is_per_chat
    make([1.0, 0.0], chat_id: CHAT)
    make([1.0, 0.0], chat_id: OTHER)
    EmbeddingCache.fetch(CHAT)
    EmbeddingCache.fetch(OTHER)
    make([0.0, 1.0], chat_id: CHAT)
    refute EmbeddingCache.stats.key?(CHAT),  'written chat must be evicted'
    assert EmbeddingCache.stats.key?(OTHER), 'other chat must stay built'
  end

  # The partial-backfill contract: `rake knowledge:pack_embeddings` converts in
  # batches, so mid-run a chat holds both blob rows and legacy JSON rows. Both
  # must be scored together, in one matrix.
  def test_mixed_blob_and_legacy_json_rows_rank_together
    blob = make([1.0, 0.0], content: 'blob')
    legacy = Knowledge.create!(topic: 't', content: 'legacy', chat_id: CHAT, source: 'manual',
                               embedding: [0.0, 1.0].to_json, embedding_blob: nil)
    entry = EmbeddingCache.fetch(CHAT)
    assert_equal [blob.id, legacy.id].sort, entry.ids.sort
    assert_equal 2, entry.dim
  end

  # Numo's `cast` silently zero-pads ragged rows, which would corrupt every
  # score with no error if the embeddings model ever changed dimension.
  def test_non_modal_dimension_rows_are_excluded
    keep = 3.times.map { |i| make([1.0, i.to_f], content: "k#{i}") }
    odd  = make([1.0, 2.0, 3.0, 4.0], content: 'odd')
    entry = EmbeddingCache.fetch(CHAT)
    assert_equal keep.map(&:id).sort, entry.ids.sort
    refute_includes entry.ids, odd.id
    assert_equal 2, entry.dim
  end

  def test_empty_chat_returns_empty_entry
    entry = EmbeddingCache.fetch(CHAT)
    assert_equal [], entry.ids
    assert_nil entry.matrix
  end

  # A build racing an invalidation must not memoize the stale result: the
  # extraction Thread writes while the listen loop may be mid-build.
  def test_stale_entry_is_not_memoized_when_invalidated_mid_build
    make([1.0, 0.0])
    klass = EmbeddingCache.singleton_class
    klass.send(:alias_method, :__build, :build)
    klass.send(:define_method, :build) do |chat_id|
      result = __build(chat_id)
      EmbeddingCache.invalidate(chat_id) unless @poisoned
      @poisoned = true
      result
    end
    begin
      EmbeddingCache.instance_variable_set(:@poisoned, false)
      EmbeddingCache.fetch(CHAT)
      refute EmbeddingCache.stats.key?(CHAT), 'build invalidated mid-flight must not be stored'
    ensure
      klass.send(:alias_method, :build, :__build)
      klass.send(:remove_method, :__build)
      EmbeddingCache.instance_variable_set(:@poisoned, nil)
    end
  end

  # `fetch` must never wait on another thread's build — a waiting listen loop
  # is exactly the blocking .claude/rules/agent-runtime.md forbids.
  def test_fetch_does_not_block_when_another_thread_is_building
    make([1.0, 0.0])
    lock = Mutex.new
    EmbeddingCache.instance_variable_get(:@build_locks)[CHAT] = lock

    holder_ready = Queue.new
    release      = Queue.new
    holder = Thread.new do
      lock.lock
      holder_ready << true
      release.pop
      lock.unlock
    end
    holder_ready.pop

    begin
      entry = nil
      elapsed = Benchmark.realtime { entry = EmbeddingCache.fetch(CHAT) }
      assert_equal 1, entry.ids.size, 'must still return a correct entry'
      assert elapsed < 1.0, "fetch waited #{elapsed}s on a held build lock"
    ensure
      release << true
      holder.join
    end
  end

  def test_reset_for_test_clears_everything
    make([1.0, 0.0])
    EmbeddingCache.fetch(CHAT)
    refute_empty EmbeddingCache.stats
    EmbeddingCache.reset_for_test!
    assert_empty EmbeddingCache.stats
  end
end

require 'numo/narray'
require 'json'

# Per-chat, in-memory, L2-normalized float32 embedding matrix plus the parallel
# array of Knowledge ids.
#
# KnowledgeBase#search and #compact! read this instead of
# `Knowledge.where(chat_id:).to_a`, which loaded ~171 MB of embedding JSON per
# agent turn on the prod main chat (measured: 1152ms of JSON.parse alone for
# 6,133 facts). Rows are pre-normalized at build time, so scoring a query is a
# single matvec:
#
#   matrix.dot(q / |q|)  ==  cosine scores, in `ids` order
#
# Thread safety: `fetch` is reached from the bot listen loop
# (Commands::GptChat -> get_relevant_knowledge), the detached knowledge
# extraction Thread (MessageResponder#maybe_extract_knowledge), TaskRunner's 2
# workers, and CronScheduler. Mutex-guarded module state, same pattern as
# AdminMenu::Session and TaskRunner, with two rules that matter:
#
#   1. `@mu` is NEVER held across the DB read.
#   2. The per-chat build lock is taken with `try_lock`, never `synchronize` —
#      a waiting listen loop is exactly the blocking that
#      `.claude/rules/agent-runtime.md` forbids. A thread that loses the race
#      builds its own copy instead of waiting; last writer wins.
class EmbeddingCache
  # ids: Array<Integer>, matrix: Numo::SFloat (N x D) or nil, dim: Integer
  Entry = Struct.new(:ids, :matrix, :dim)

  EMPTY = Entry.new([].freeze, nil, 0).freeze

  @mu          = Mutex.new
  @store       = {}                 # chat_id => Entry
  @build_locks = {}                 # chat_id => Mutex
  @gen         = Hash.new(0)        # chat_id => invalidation generation
  @hits        = Hash.new(0)
  @misses      = Hash.new(0)

  class << self
    # Returns an Entry (possibly EMPTY). Never nil, never blocks on another
    # thread's build.
    def fetch(chat_id)
      hit = @mu.synchronize { @store[chat_id] }
      if hit
        @mu.synchronize { @hits[chat_id] += 1 }
        return hit
      end
      @mu.synchronize { @misses[chat_id] += 1 }

      lock = @mu.synchronize { @build_locks[chat_id] ||= Mutex.new }
      return build(chat_id) unless lock.try_lock

      begin
        hit = @mu.synchronize { @store[chat_id] }
        return hit if hit

        gen   = @mu.synchronize { @gen[chat_id] }
        entry = build(chat_id)
        # Discard the build if the chat was invalidated while it ran.
        @mu.synchronize { @store[chat_id] = entry if @gen[chat_id] == gen }
        entry
      ensure
        lock.unlock
      end
    end

    def invalidate(chat_id)
      @mu.synchronize do
        @store.delete(chat_id)
        @gen[chat_id] += 1
      end
      nil
    end

    def invalidate_all
      @mu.synchronize do
        # Bump every chat we've ever seen, not just the ones currently stored:
        # a build is in flight precisely BECAUSE its chat was a cache miss, so
        # bumping only @store would let that build memoize a stale matrix.
        (@store.keys | @build_locks.keys | @gen.keys).each { |c| @gen[c] += 1 }
        @store.clear
      end
      nil
    end

    # Test hook — mirrors AdminMenu::Views#reset_getchat_cache_for_test!.
    # Required in any test that writes Knowledge rows: the per-test transaction
    # rollback would otherwise leave a cache built from rolled-back rows.
    def reset_for_test!
      @mu.synchronize do
        @store.clear
        @build_locks.clear
        @gen.clear
        @hits.clear
        @misses.clear
      end
      nil
    end

    # Cheap hot-path predicate. `stats` allocates a hash per cached chat, which
    # is not something to do on every agent turn just to label a log line.
    def cached?(chat_id)
      @mu.synchronize { @store.key?(chat_id) }
    end

    def stats
      @mu.synchronize do
        @store.to_h do |chat_id, e|
          [chat_id, { rows: e.ids.size, dim: e.dim, bytes: e.ids.size * e.dim * 4,
                      hits: @hits[chat_id], misses: @misses[chat_id] }]
        end
      end
    end

    private

    def build(chat_id)
      rows = Knowledge.live.where(chat_id: chat_id)
                      .where("#{Knowledge::BLOB_PRESENT} OR embedding IS NOT NULL")
                      .order(:id)
                      .pluck(:id, :embedding_blob, :embedding)
      return EMPTY if rows.empty?

      packed = rows.filter_map do |id, blob, json|
        b = (blob && !blob.empty?) ? blob : legacy_pack(json)
        next nil unless b && b.bytesize.positive? && (b.bytesize % 4).zero?
        [id, b]
      end
      return EMPTY if packed.empty?

      # Numo::*Float.cast silently ZERO-PADS ragged rows, so a change of
      # embedding model would corrupt every score with no error. Keep only the
      # modal byte length and warn about the rest.
      dim_bytes  = packed.map { |_, b| b.bytesize }.tally.max_by { |_, c| c }.first
      keep, drop = packed.partition { |_, b| b.bytesize == dim_bytes }
      if !drop.empty? && defined?(LOGGER)
        LOGGER.warn "[chat=#{chat_id}] EmbeddingCache: dropped #{drop.size} row(s) with " \
                    "non-modal embedding dimension (ids=#{drop.first(5).map(&:first).inspect})"
      end
      return EMPTY if keep.empty?

      d = dim_bytes / 4
      m = Numo::SFloat.from_binary(keep.map(&:last).join, [keep.size, d])
      norms = Numo::NMath.sqrt((m * m).sum(axis: 1)).reshape(keep.size, 1)
      # Clamp: a stored zero-norm vector otherwise yields NaN, and NaN makes
      # `sort_by` raise ArgumentError deep inside search.
      m = m / Numo::SFloat.maximum(norms, 1e-12)

      Entry.new(keep.map(&:first).freeze, m, d).freeze
    end

    def legacy_pack(json)
      return nil unless json
      v = JSON.parse(json)
      return nil unless v.is_a?(Array) && !v.empty?
      v.map(&:to_f).pack(Knowledge::PACK_FORMAT)
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end

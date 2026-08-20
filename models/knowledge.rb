require_relative '../lib/embedding_cache'

class Knowledge < ActiveRecord::Base
  self.table_name = 'knowledge'

  # Native-endian float32. Pairs with Numo::SFloat.from_binary, which also
  # reads host-native — do NOT switch to 'e*'/'g*'. Both prod arches
  # (x86_64, aarch64) are little-endian; a big-endian restore of bot.db would
  # misread and needs a re-run of `rake knowledge:pack_embeddings`.
  PACK_FORMAT = 'f*'.freeze

  # An empty blob means "no embedding", exactly as NULL does -- EmbeddingCache
  # treats them alike. Both scopes below must agree with it, or the backfill
  # skips a row while the destructive cleanup still clears its JSON, leaving
  # the fact with no embedding at all and no way back.
  # length(), not `= ''`: SQLite gives BLOB and TEXT different affinities, so a
  # blob never compares equal to a TEXT empty-string literal and the guard
  # would silently miss the exact rows it exists to catch.
  BLOB_MISSING = '(embedding_blob IS NULL OR length(embedding_blob) = 0)'.freeze
  BLOB_PRESENT = '(embedding_blob IS NOT NULL AND length(embedding_blob) > 0)'.freeze

  # Rows still holding ONLY the legacy JSON column. `pack_embeddings` converts
  # these; `drop_legacy_embeddings` refuses to run while any exist.
  scope :unpacked_embeddings, -> { where(BLOB_MISSING).where.not(embedding: nil) }
  # Rows safe to clear the legacy column on.
  scope :packed_embeddings,   -> { where(BLOB_PRESENT).where.not(embedding: nil) }

  # Soft deletion. Explicit scope rather than a default_scope: the purge task
  # and every audit query need to see tombstones, and a default_scope would
  # make them fight the ORM to do it.
  scope :live,    -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }

  # dependent: :delete_all matches the FK's ON DELETE CASCADE. Without both,
  # `destroy` on a fact that has subjects raises ConstraintException.
  has_many :subjects, class_name: 'KnowledgeSubject', dependent: :delete_all

  # Facts about a given participant, live only -- a tombstoned fact left in a
  # bucket would pollute that bucket's centroid and come back as a candidate.
  scope :about, ->(uid) { live.joins(:subjects).where(knowledge_subjects: { uid: uid }) }

  # Reads prefer the packed blob and fall back to the legacy JSON text column,
  # so a partially-completed `rake knowledge:pack_embeddings` can't break search.
  def embedding_vector
    return embedding_blob.unpack(PACK_FORMAT) if embedding_blob && !embedding_blob.empty?
    return nil unless embedding
    JSON.parse(embedding)
  end

  # Writes go to the blob. While `knowledge.dual_write_legacy` is on (the
  # shipped default) the legacy JSON column is written too, so that reverting
  # the code leaves every post-deploy fact still readable by the old path.
  # Never assign packed bytes to `embedding` — AR raises
  # Encoding::UndefinedConversionError binding ASCII-8BIT to a text column.
  # An empty or nil vector stores nothing rather than an empty blob: an empty
  # blob reads back as "no embedding" but would still satisfy a naive
  # `embedding_blob IS NOT NULL` scope. EmbeddingService.embed can return []
  # from a malformed 200, and [] is truthy, so this is reachable.
  def embedding_vector=(vec)
    floats = Array(vec).map(&:to_f)
    if floats.empty?
      self.embedding_blob = nil
      self.embedding      = nil
      return
    end
    self.embedding_blob = floats.pack(PACK_FORMAT)
    self.embedding      = Knowledge.dual_write_legacy? ? floats.to_json : nil
  end

  def manual?
    source == 'manual'
  end

  def deleted?
    !deleted_at.nil?
  end

  def merged?
    !merged_from.nil?
  end

  def merged_from_ids
    return [] unless merged_from
    Array(JSON.parse(merged_from))
  rescue JSON::ParserError
    []
  end

  def soft_delete!(reason)
    update!(deleted_at: Time.now, deleted_reason: reason)
  end

  def restore!
    update!(deleted_at: nil, deleted_reason: nil)
  end

  def self.dual_write_legacy?
    cfg = (Settings.knowledge rescue nil)
    cfg.nil? || cfg.fetch('dual_write_legacy', true)
  end

  # Single choke point for EmbeddingCache invalidation. Covers every writer:
  # KnowledgeBase.add, the knowledge_add/knowledge_delete agent tools,
  # Commands::KnowledgeDelete, and compaction's destroys.
  # NOTE: `update_all` / `delete_all` / raw SQL bypass this — the only such
  # call site is the offline rake backfill, which rewrites the storage format
  # but not the vector values, so skipping invalidation there is correct.
  after_commit :invalidate_embedding_cache, on: %i[create update destroy]

  private

  def invalidate_embedding_cache
    EmbeddingCache.invalidate(chat_id)
  end
end

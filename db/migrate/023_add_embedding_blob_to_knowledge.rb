class AddEmbeddingBlobToKnowledge < ActiveRecord::Migration[7.2]
  # Packed float32 (`Array#pack('f*')`) replacement for the legacy `embedding`
  # TEXT column, which holds a JSON array of ~1536 floats (19-30 KB/row).
  # ~4.8x smaller on disk and ~100x cheaper to decode: JSON.parse of one prod
  # chat's 6,133 embeddings takes ~1150ms, Numo::SFloat.from_binary over the
  # joined blobs takes ~13ms.
  #
  # A NEW column rather than reusing `embedding`: AR 7.2 + sqlite3 2.x raise
  # Encoding::UndefinedConversionError when an ASCII-8BIT string with high
  # bytes is bound to a `text` attribute (sqlite3/quoting.rb#type_cast calls
  # String#encode), so packed bytes cannot be written to `embedding` at all.
  # A `binary` column stores a native BLOB and round-trips byte-exact. Keeping
  # both columns also gives the backfill an exact, resumable predicate
  # (`embedding_blob IS NULL AND embedding IS NOT NULL`) and keeps reads
  # correct while the backfill is only partially done.
  #
  # Additive, NO backfill here: `rake db:migrate` runs in docker-entrypoint.sh
  # before the bot starts, so re-encoding 7k rows would block startup. The
  # backfill is `rake knowledge:pack_embeddings`.
  def change
    add_column :knowledge, :embedding_blob, :binary
  end
end

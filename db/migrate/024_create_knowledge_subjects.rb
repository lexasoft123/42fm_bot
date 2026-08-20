class CreateKnowledgeSubjects < ActiveRecord::Migration[7.2]
  # Many-to-many between a fact and the people it is about. A fact can concern
  # several participants (measured on prod: 1,385 of 6,133 main-chat facts name
  # two, 150 name three), which is why this is a join table and not a column.
  #
  # Purpose: partition facts by subject so near-duplicate detection can subtract
  # the per-person centroid. Person identity dominates the embedding — two facts
  # about the same participant score ~0.60 largely *because* they are both about
  # them — so a global cosine threshold cannot separate "same fact restated"
  # from "same person, new fact". Removing the bucket centroid cancels that
  # shared direction and surfaces 252 duplicate pairs invisible to any safe
  # global threshold.
  #
  # `on_delete: :cascade` is mandatory, not stylistic: this is the first FK in
  # the schema and Rails' sqlite3 adapter runs `PRAGMA foreign_keys = ON`, so
  # without it every existing `Knowledge#destroy` would raise ConstraintException.
  #
  # `source` distinguishes rows derived by the offline alias backfill from those
  # the extractor emitted, so re-curating the alias map can delete and re-derive
  # only its own rows. Re-runnable is not the same as corrective.
  def change
    create_table :knowledge_subjects do |t|
      t.references :knowledge, null: false,
                   foreign_key: { to_table: :knowledge, on_delete: :cascade }
      t.bigint :uid,    null: false
      t.string :source, null: false, default: 'extract'
    end
    add_index :knowledge_subjects, [:uid]
    add_index :knowledge_subjects, %i[knowledge_id uid], unique: true
  end
end

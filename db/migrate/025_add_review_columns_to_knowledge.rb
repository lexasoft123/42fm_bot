class AddReviewColumnsToKnowledge < ActiveRecord::Migration[7.2]
  # Soft deletion + review bookkeeping for the LLM dedup sweep.
  #
  # Deletion is soft because the new deleting actor is a language model, and
  # over-deletion is the expected failure mode rather than a remote one. There
  # is no per-fact undo otherwise: `make backup` restores the whole DB, which
  # would roll back every message, task and cost row since the snapshot.
  #
  # `merged_from` records the source ids a merged fact replaced, which is what
  # makes `rake knowledge:rollback_merges` possible.
  #
  # All knowledge_compact_log columns are defaulted so the existing
  # KnowledgeCompactLog.create! keeps working untouched.
  def change
    add_column :knowledge, :deleted_at,     :datetime
    add_column :knowledge, :deleted_reason, :string
    add_column :knowledge, :reviewed_at,    :datetime
    add_column :knowledge, :merged_from,    :text
    add_index  :knowledge, %i[chat_id deleted_at]
    add_index  :knowledge, %i[chat_id reviewed_at]

    add_column :knowledge_compact_log, :run_type, :string,  null: false, default: 'compact'
    add_column :knowledge_compact_log, :deleted,  :integer, null: false, default: 0
    add_column :knowledge_compact_log, :chunks,   :integer, null: false, default: 0
    add_column :knowledge_compact_log, :dry_run,  :boolean, null: false, default: false
  end
end

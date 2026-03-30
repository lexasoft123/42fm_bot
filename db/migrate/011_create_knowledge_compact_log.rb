class CreateKnowledgeCompactLog < ActiveRecord::Migration[6.0]
  def change
    create_table :knowledge_compact_log do |t|
      t.bigint  :chat_id,   null: false
      t.integer :merged,    null: false, default: 0
      t.integer :removed,   null: false, default: 0
      t.integer :kept,      null: false, default: 0
      t.float   :threshold, null: false
      t.datetime :created_at, null: false
    end
    add_index :knowledge_compact_log, [:chat_id, :created_at]
  end
end

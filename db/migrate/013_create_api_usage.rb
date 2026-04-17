class CreateApiUsage < ActiveRecord::Migration[6.0]
  def change
    create_table :api_usage do |t|
      t.bigint  :chat_id
      t.string  :model,              null: false
      t.string  :purpose,             null: false
      t.integer :input_tokens,        null: false, default: 0
      t.integer :output_tokens,       null: false, default: 0
      t.integer :cache_read_tokens,   null: false, default: 0
      t.integer :cache_write_tokens,  null: false, default: 0
      t.decimal :cost_cents,          precision: 10, scale: 4, null: false, default: 0
      t.datetime :created_at, null: false
    end
    add_index :api_usage, [:chat_id, :created_at]
    add_index :api_usage, :created_at
  end
end

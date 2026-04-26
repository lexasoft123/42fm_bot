class CreateChats < ActiveRecord::Migration[6.0]
  def change
    create_table :chats, primary_key: :chat_id, id: false do |t|
      t.bigint   :chat_id, null: false, primary_key: true
      t.string   :title
      t.string   :chat_type # 'group' | 'supergroup' | 'private' | 'channel'; not :type to avoid AR STI
      t.boolean  :authorized, null: false, default: true
      t.boolean  :audio, null: false, default: false
      t.text     :rate_limits # JSON, mirrors Settings.auth.chats[].rate_limits
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.timestamps
    end
  end
end

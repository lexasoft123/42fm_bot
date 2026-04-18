class AddMessageIds < ActiveRecord::Migration[6.0]
  def change
    add_column :messages, :message_id, :bigint
    add_column :messages, :reply_to_message_id, :bigint
    add_column :messages, :message_thread_id, :bigint
    add_column :messages, :forwarded, :boolean, default: false, null: false
    add_column :messages, :edited_at, :datetime
    add_index  :messages, [:chat_id, :message_id], name: 'idx_messages_chat_msg'
    add_index  :messages, [:chat_id, :message_thread_id], name: 'idx_messages_chat_thread'
  end
end

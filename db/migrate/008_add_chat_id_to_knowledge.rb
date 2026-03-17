class AddChatIdToKnowledge < ActiveRecord::Migration[6.1]
  def change
    add_column :knowledge, :chat_id, :bigint
    add_index :knowledge, :chat_id
  end
end

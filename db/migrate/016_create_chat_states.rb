class CreateChatStates < ActiveRecord::Migration[6.0]
  def change
    create_table :chat_states, primary_key: :chat_id, id: false do |t|
      t.bigint   :chat_id, null: false, primary_key: true
      t.text     :scratchpad, null: false, default: '{}'
      t.datetime :updated_at, null: false
    end
  end
end

class CreateMessages < ActiveRecord::Migration[6.0]
    def change
        create_table :messages, force: true do |t|
            t.integer :user_uid, null: false
            t.bigint  :chat_id, null: false
            t.string :body
            
            t.timestamps
        end
        add_index :messages, :user_uid
        add_index :messages, :chat_id
        add_index :users, :id
        add_index :users, :uid
      end
  end
  
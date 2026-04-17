class AddUserUidToApiUsage < ActiveRecord::Migration[6.0]
  def change
    add_column :api_usage, :user_uid, :bigint
    add_index  :api_usage, [:chat_id, :user_uid, :created_at], name: 'index_api_usage_on_chat_user_created'
  end
end

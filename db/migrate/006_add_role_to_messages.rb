class AddRoleToMessages < ActiveRecord::Migration[6.0]
  def up
    add_column :messages, :role, :string, default: 'user', null: false
    change_column_null :messages, :user_uid, true
  end

  def down
    remove_column :messages, :role
    change_column_null :messages, :user_uid, false
  end
end

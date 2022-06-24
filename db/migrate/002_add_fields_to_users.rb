class AddFieldsToUsers < ActiveRecord::Migration
  def change
    add_column :users, :role, :string, default: 'new'
    add_column :users, :last_order, :datetime
  end
end

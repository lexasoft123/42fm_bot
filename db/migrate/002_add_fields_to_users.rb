class AddFieldsToUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :users, :role, :string, default: 'new'
    add_column :users, :last_order, :datetime
  end
end

class CreateUsers < ActiveRecord::Migration
  def change
    create_table :users, force: true do |t|
      t.integer :uid
      t.string :name
      t.timestamps
    end
  end
end

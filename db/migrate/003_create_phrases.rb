class CreatePhrases < ActiveRecord::Migration
  def change
    create_table :phrases do |t|
      t.integer :user_id
      t.string :content, null: false
      t.timestamps
    end
  end
end

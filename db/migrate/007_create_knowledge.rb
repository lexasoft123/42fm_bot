class CreateKnowledge < ActiveRecord::Migration[6.0]
  def change
    create_table :knowledge do |t|
      t.string  :topic,     null: false
      t.text    :content,   null: false
      t.text    :embedding  # JSON array of floats
      t.string  :source,    null: false, default: 'manual'  # 'manual' or 'auto'
      t.timestamps
    end
  end
end

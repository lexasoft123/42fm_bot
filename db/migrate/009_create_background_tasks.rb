class CreateBackgroundTasks < ActiveRecord::Migration[6.0]
  def change
    create_table :background_tasks do |t|
      t.string  :task_type,    null: false
      t.string  :status,       null: false, default: 'pending'
      t.integer :chat_id,      null: false
      t.string  :external_id
      t.text    :params
      t.text    :result
      t.integer :attempts,     null: false, default: 0
      t.integer :max_attempts, null: false, default: 30
      t.timestamps
    end
    add_index :background_tasks, :status
  end
end

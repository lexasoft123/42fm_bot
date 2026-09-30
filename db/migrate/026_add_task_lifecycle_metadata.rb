class AddTaskLifecycleMetadata < ActiveRecord::Migration[6.0]
  def up
    add_column :background_tasks, :lifecycle_phase, :string, null: false, default: 'queued'
    add_column :background_tasks, :delivery_status, :string, null: false, default: 'unknown'
    add_column :background_tasks, :retry_count, :integer, null: false, default: 0
    add_column :background_tasks, :parent_task_id, :integer

    add_index :messages, [:chat_id, :bg_task_external_id], name: 'idx_messages_chat_bg_task'
    add_index :background_tasks, [:chat_id, :created_at], name: 'idx_tasks_chat_created'
    add_index :background_tasks, [:chat_id, :parent_task_id], name: 'idx_tasks_chat_parent'
    add_index :background_tasks, [:chat_id, :task_type, :created_at], name: 'idx_tasks_chat_type_created'
    add_index :background_tasks, [:chat_id, :lifecycle_phase, :created_at], name: 'idx_tasks_chat_phase_created'

    backfill_lifecycle_columns
  end

  def down
    remove_index :background_tasks, name: 'idx_tasks_chat_phase_created'
    remove_index :background_tasks, name: 'idx_tasks_chat_type_created'
    remove_index :background_tasks, name: 'idx_tasks_chat_parent'
    remove_index :background_tasks, name: 'idx_tasks_chat_created'
    remove_index :messages, name: 'idx_messages_chat_bg_task'
    remove_column :background_tasks, :parent_task_id
    remove_column :background_tasks, :retry_count
    remove_column :background_tasks, :delivery_status
    remove_column :background_tasks, :lifecycle_phase
  end

  # Historical rows predate explicit lifecycle metadata. Keep the backfill
  # conservative: terminal generation does not imply Telegram delivery.
  # JSON inspection happens once during migration, never on the hot status path.
  def backfill_lifecycle_columns
    execute <<~SQL
      UPDATE background_tasks
      SET lifecycle_phase = CASE status
        WHEN 'done' THEN 'completed'
        WHEN 'failed' THEN 'failed'
        ELSE CASE
          WHEN external_id IS NOT NULL AND external_id != '' THEN 'processing'
          ELSE 'queued'
        END
      END,
      delivery_status = 'unknown',
      retry_count = 0
    SQL

    execute <<~SQL
      UPDATE background_tasks
      SET parent_task_id = CAST(json_extract(params, '$.parent_task_id') AS INTEGER)
      WHERE task_type = 'agent_event'
        AND json_valid(COALESCE(params, '{}'))
        AND json_type(params, '$.parent_task_id') = 'integer'
        AND CAST(json_extract(params, '$.parent_task_id') AS INTEGER) > 0
    SQL

    execute <<~SQL
      UPDATE background_tasks
      SET retry_count = CASE WHEN json_valid(COALESCE(params, '{}')) THEN
        COALESCE(CAST(json_extract(params, '$.prompt_failures') AS INTEGER), 0) +
        COALESCE(CAST(json_extract(params, '$.submit_failures') AS INTEGER), 0) +
        COALESCE(CAST(json_extract(params, '$.generation_retries') AS INTEGER), 0) +
        COALESCE(CAST(json_extract(params, '$.delivery_failures') AS INTEGER), 0) +
        COALESCE(CAST(json_extract(params, '$.persistence_failures') AS INTEGER), 0)
      ELSE 0 END
    SQL

    execute <<~SQL
      UPDATE background_tasks
      SET lifecycle_phase = CASE
        WHEN json_type(params, '$.delivery_receipt') IN ('object', 'array') THEN 'persisting_delivery'
        WHEN json_type(params, '$.delivery_result') IN ('object', 'array') THEN 'delivering'
        WHEN retry_count > 0 THEN 'retrying'
        ELSE lifecycle_phase
      END,
      delivery_status = CASE
        WHEN json_type(params, '$.delivery_receipt') IN ('object', 'array') THEN 'delivered'
        WHEN json_type(params, '$.delivery_result') IN ('object', 'array') THEN 'pending'
        ELSE delivery_status
      END
      WHERE status = 'pending' AND json_valid(COALESCE(params, '{}'))
    SQL

    execute <<~SQL
      UPDATE background_tasks AS parent
      SET delivery_status = 'delivered'
      WHERE parent.status = 'done'
        -- Only historically single-output task types are provable from one
        -- correlated Message. Songs, cover art and separation may produce
        -- several outputs; one row must never imply complete delivery.
        AND parent.task_type IN ('image_generate', 'suno_wav_convert')
        AND parent.external_id IS NOT NULL
        AND parent.external_id != ''
        AND EXISTS (
          SELECT 1 FROM messages
          WHERE messages.chat_id = parent.chat_id
            AND messages.bg_task_external_id = parent.external_id
        )
    SQL

    execute <<~SQL
      UPDATE background_tasks AS parent
      SET delivery_status = 'failed'
      WHERE EXISTS (
        SELECT 1 FROM background_tasks AS event
        WHERE event.chat_id = parent.chat_id
          AND event.parent_task_id = parent.id
          AND event.task_type = 'agent_event'
          AND json_valid(COALESCE(event.params, '{}'))
          AND json_extract(event.params, '$.event_type') IN ('song_delivery_failed', 'separation_delivery_failed')
      )
    SQL
  end
end

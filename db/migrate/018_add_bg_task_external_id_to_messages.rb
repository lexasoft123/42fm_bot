class AddBgTaskExternalIdToMessages < ActiveRecord::Migration[6.0]
  # Foreign reference from a bot Message row to the background_tasks row
  # that produced its content (e.g. a delivered Suno song or cover-art).
  # Lets `cover_art` reliably find the source song when the user replies
  # to a bot audio message — no brittle title-matching.
  #
  # Stores the third-party `external_id` (Suno taskId), not the local
  # background_tasks.id, since the cover-art submit endpoint needs the
  # Suno-side task id directly.
  def change
    add_column :messages, :bg_task_external_id, :string
  end
end

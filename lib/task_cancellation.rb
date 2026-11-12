require 'json'

module TaskCancellation
  module_function

  # Cancellation is intentionally limited to pre-start, user-owned image work.
  # It changes only local queue state and never promises provider-side abort.
  def cancel(task_id:, chat_id:, user_id:, forum_thread_id: nil)
    return { status: :invalid } unless task_id.is_a?(Integer) && task_id.positive?
    return { status: :unauthorized } unless user_id.is_a?(Integer) && user_id.positive?

    task = BackgroundTask.find_by(id: task_id, chat_id: chat_id, task_type: 'image_generate')
    return { status: :not_found } unless task

    params = task.params_hash
    owner = params['origin_user_id']
    topic = params['forum_thread_id']
    return { status: :unauthorized } unless owner.is_a?(Integer) && owner.positive? && owner == user_id
    return { status: :unauthorized } unless topic == forum_thread_id

    return { status: :cancelled } if task.status == 'cancelled' && task.lifecycle_phase == 'cancelled'
    return { status: :started } unless task.status == 'pending' && task.lifecycle_phase.to_s == 'queued'

    return { status: :cancelled } if task.cancel_before_start!

    latest = BackgroundTask.find_by(id: task.id)
    return { status: :cancelled } if latest&.status == 'cancelled' && latest.lifecycle_phase == 'cancelled'
    { status: :started }
  end
end

module AgentEventEmitter
  AGENT_EVENT_HOUR_CAP = 10

  # Emit an agent_event BackgroundTask so the agent can react to a noteworthy
  # outcome (task failed after retries, succeeded after retries, etc.).
  # Per-chat rate-limited at AGENT_EVENT_HOUR_CAP per rolling hour to prevent
  # runaway loops. Returns the new task or nil if rate-limited / suppressed.
  def emit_agent_event(parent_task, event_type, summary:)
    chat_id = parent_task.chat_id
    recent = ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.where(chat_id: chat_id, task_type: 'agent_event')
        .where('created_at > ?', Time.now - 3600).count
    end
    if recent >= AGENT_EVENT_HOUR_CAP
      LOGGER.warn "[chat=#{chat_id}] agent_event rate limit (#{AGENT_EVENT_HOUR_CAP}/hour) — suppressing #{event_type}" if defined?(LOGGER)
      return nil
    end

    ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.create!(
        task_type: 'agent_event',
        chat_id: chat_id,
        max_attempts: 5,
        params: {
          event_type: event_type,
          parent_task_id: parent_task.id,
          parent_task_type: parent_task.task_type,
          summary: summary.to_s,
        }.to_json
      )
    end
  end
end

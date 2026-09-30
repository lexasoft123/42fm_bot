require_relative '../agent/error_reporter'

module AgentEventEmitter
  AGENT_EVENT_HOUR_CAP = Agent::ErrorReporter::AGENT_EVENT_HOUR_CAP

  # Emit an agent_event BackgroundTask so the agent can react to a noteworthy
  # outcome (task failed after retries, succeeded after retries, etc.).
  # Per-chat rate-limited at AGENT_EVENT_HOUR_CAP per rolling hour to prevent
  # runaway loops. Returns the new task or nil if rate-limited / suppressed.
  def emit_agent_event(parent_task, event_type, summary:, user_notified: false, forum_thread_id: nil)
    forum_thread_id ||= parent_task.params_hash['forum_thread_id']
    ActiveRecord::Base.connection_pool.with_connection do
      Agent::ErrorReporter.emit(
        chat_id: parent_task.chat_id,
        event_type: event_type,
        summary: summary,
        parent_task: parent_task,
        user_notified: user_notified,
        forum_thread_id: forum_thread_id
      )
    end
  end
end

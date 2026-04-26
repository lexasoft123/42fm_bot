require 'set'

# Periodic dispatcher that wakes up every POLL_INTERVAL seconds and looks for
# scratchpad intentions whose due_at has passed. For each such chat, emits a
# single agent_event(cron_tick) BackgroundTask carrying the due intent ids;
# AgentEventHandler then runs the agent which can act on them or skip.
#
# Marks those intent ids as `acted` immediately to avoid re-dispatching on the
# next tick; the agent is free to remove them via forget if it actually
# handled them, or leave them in the scratchpad for context.
class CronScheduler
  POLL_INTERVAL = 60 # seconds — fine enough for 5-min retry_in_min intents

  @thread = nil
  @mutex  = Mutex.new

  class << self
    def start
      @mutex.synchronize do
        if @thread&.alive?
          LOGGER.info "#{name}: already running"
          return @thread
        end
        @thread = Thread.new do
          loop do
            tick
            sleep POLL_INTERVAL
          rescue => e
            LOGGER.error "#{name}: #{e.class}: #{e.message}"
            sleep POLL_INTERVAL
          end
        end
      end
    end

    def tick
      ActiveRecord::Base.connection_pool.with_connection do
        ChatState.where("scratchpad LIKE ?", '%due_at%').find_each do |state|
          due = Agent::Scratchpad.due_intentions(state.chat_id)
          next if due.empty?
          dispatched = dispatch(state.chat_id, due)
          if dispatched
            Agent::Scratchpad.mark_acted(state.chat_id, due.map { |e| e['id'] })
          end
        end
      end
    end

    def dispatch(chat_id, due_intents)
      recent = BackgroundTask.where(chat_id: chat_id, task_type: 'agent_event')
        .where('created_at > ?', Time.now - 3600).count
      if recent >= AgentEventEmitter::AGENT_EVENT_HOUR_CAP
        LOGGER.warn "[chat=#{chat_id}] CronScheduler: agent_event rate limit (#{AgentEventEmitter::AGENT_EVENT_HOUR_CAP}/hour) — suppressing cron_tick" if defined?(LOGGER)
        return false
      end
      summary = due_intents.map { |e| "[#{e['id']}] #{e['content']}" }.join('; ')
      BackgroundTask.create!(
        task_type: 'agent_event',
        chat_id: chat_id,
        max_attempts: 5,
        params: {
          event_type: 'cron_tick',
          parent_task_id: nil,
          parent_task_type: 'cron',
          summary: summary,
          due_intent_ids: due_intents.map { |e| e['id'] },
        }.to_json
      )
      LOGGER.info "[chat=#{chat_id}] CronScheduler: dispatched cron_tick for #{due_intents.size} due intent(s)" if defined?(LOGGER)
      true
    end
  end
end

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
  OBITUARY_DAY_CAP = 3 # rule_obituary tasks per chat per local day

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
        maybe_fire_digests
        maybe_announce_expired_rules
      end
    end

    # Rules-war obituaries (F4). pop_expired_rules is the ONLY deletion
    # path for expired rules, so each gets announced exactly once. The cron
    # tick owns batching: everything that expired in one tick goes into ONE
    # rule_obituary task (single or «братская могила»). Past the daily cap,
    # expired rules are still popped (deleted) but not announced.
    def maybe_announce_expired_rules
      ChatState.where("scratchpad LIKE ?", '%"rules":[{%').find_each do |state|
        expired = Agent::Scratchpad.pop_expired_rules(state.chat_id)
        next if expired.empty?
        offset = ((Settings.digests['utc_offset'] rescue nil) || 0).to_i * 3600
        local_now = Time.now.utc + offset
        local_midnight_utc = Time.utc(local_now.year, local_now.month, local_now.day) - offset
        posted = BackgroundTask.where(chat_id: state.chat_id, task_type: 'rule_obituary')
                               .where('created_at >= ?', local_midnight_utc).count
        if posted >= OBITUARY_DAY_CAP
          LOGGER.info "[chat=#{state.chat_id}] CronScheduler: #{expired.size} rule(s) expired silently (obituary day cap)" if defined?(LOGGER)
          next
        end
        BackgroundTask.create!(
          task_type: 'rule_obituary', chat_id: state.chat_id, max_attempts: 3,
          params: { rules: expired.map { |r| r.slice('id', 'content', 'set_by_name', 'court') } }.to_json
        )
        LOGGER.info "[chat=#{state.chat_id}] CronScheduler: obituary for #{expired.size} rule(s)" if defined?(LOGGER)
      end
    rescue => e
      LOGGER.error "CronScheduler#maybe_announce_expired_rules: #{e.class}: #{e.message}" if defined?(LOGGER)
    end

    # Wall-clock digest scheduling (Settings.digests). Round 1 fires the
    # weekly Wrapped only; digests.news is reserved config — daily_news has
    # no registered handler yet, and TaskRunner would mark such tasks failed
    # and error-notify the chat.
    def maybe_fire_digests
      cfg = Settings.digests rescue nil
      return unless cfg && cfg['enabled'] && cfg['chat_id']
      chat_id = cfg['chat_id'].to_i
      offset  = (cfg['utc_offset'] || 0).to_i * 3600
      local_now = Time.now.utc + offset
      # created_at is stored UTC, so the guard boundary is local midnight
      # expressed back in UTC.
      local_midnight_utc = Time.utc(local_now.year, local_now.month, local_now.day) - offset

      wrapped = cfg['wrapped'] || {}
      return unless local_now.wday == (wrapped['wday'] || 0).to_i
      return unless after_local_time?(local_now, wrapped)
      return if BackgroundTask.where(chat_id: chat_id, task_type: 'weekly_wrapped')
                              .where('created_at >= ?', local_midnight_utc).exists?
      BackgroundTask.create!(task_type: 'weekly_wrapped', chat_id: chat_id,
                             max_attempts: 3, params: {}.to_json)
      LOGGER.info "[chat=#{chat_id}] CronScheduler: fired weekly_wrapped" if defined?(LOGGER)
    rescue => e
      LOGGER.error "CronScheduler#maybe_fire_digests: #{e.class}: #{e.message}" if defined?(LOGGER)
    end

    def after_local_time?(local_now, sched)
      (local_now.hour * 60 + local_now.min) >=
        ((sched['hour'] || 0).to_i * 60 + (sched['minute'] || 0).to_i)
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

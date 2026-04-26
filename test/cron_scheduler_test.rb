require_relative 'test_helper'
require_relative '../lib/agent/scratchpad'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/cron_scheduler'

class CronSchedulerTest < BotTest
  CHAT = -1234567890

  def setup
    super
    LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
  end

  def test_tick_dispatches_agent_event_for_due_intentions
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'do later', due_at: Time.now - 60)
    CronScheduler.tick

    tasks = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').to_a
    assert_equal 1, tasks.size
    p = tasks.first.params_hash
    assert_equal 'cron_tick', p['event_type']
    assert_includes p['summary'], 'do later'
    assert_kind_of Array, p['due_intent_ids']
    assert_equal 1, p['due_intent_ids'].size
  end

  def test_tick_marks_dispatched_intents_as_acted
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'do later', due_at: Time.now - 60)
    CronScheduler.tick
    assert_empty Agent::Scratchpad.due_intentions(CHAT) # acted=true now
  end

  def test_tick_does_not_double_dispatch
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'do later', due_at: Time.now - 60)
    CronScheduler.tick
    CronScheduler.tick # no new due intents → no second dispatch
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end

  def test_tick_skips_chats_without_due
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'much later', due_at: Time.now + 3600)
    CronScheduler.tick
    assert_equal 0, BackgroundTask.where(task_type: 'agent_event').count
  end

  def test_tick_respects_hour_cap
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'd', due_at: Time.now - 60)
    AgentEventEmitter::AGENT_EVENT_HOUR_CAP.times do |i|
      BackgroundTask.create!(task_type: 'agent_event', chat_id: CHAT,
                             attempts: 0, max_attempts: 5,
                             params: '{}', created_at: Time.now - 100)
    end
    before = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
    CronScheduler.tick
    after = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
    assert_equal before, after # cap blocked the dispatch
  end
end

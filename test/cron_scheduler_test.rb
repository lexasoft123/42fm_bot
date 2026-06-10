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

  # ── Digest scheduling (S2 — wrapped branch only this round) ──────────

  def with_digests(cfg)
    Settings.singleton_class.send(:define_method, :digests) { cfg }
    yield
  ensure
    Settings.singleton_class.send(:remove_method, :digests)
  end

  def due_now_cfg(chat_id: CHAT)
    now = Time.now.utc
    { 'enabled' => true, 'chat_id' => chat_id, 'utc_offset' => 0,
      'news'    => { 'hour' => 0, 'minute' => 0 },
      'wrapped' => { 'wday' => now.wday, 'hour' => 0, 'minute' => 0 } }
  end

  def test_wrapped_fires_once_per_day
    with_digests(due_now_cfg) do
      CronScheduler.tick
      CronScheduler.tick
    end
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'weekly_wrapped').count
  end

  def test_wrapped_skips_on_wrong_weekday
    cfg = due_now_cfg
    cfg['wrapped']['wday'] = (Time.now.utc.wday + 1) % 7
    with_digests(cfg) { CronScheduler.tick }
    assert_equal 0, BackgroundTask.where(task_type: 'weekly_wrapped').count
  end

  def test_digests_noop_without_chat_id
    with_digests(due_now_cfg(chat_id: nil)) { CronScheduler.tick }
    assert_equal 0, BackgroundTask.where(task_type: 'weekly_wrapped').count
  end

  def test_news_branch_never_fires_in_round_one
    with_digests(due_now_cfg) { CronScheduler.tick }
    assert_equal 0, BackgroundTask.where(task_type: 'daily_news').count,
                 'daily_news has no handler yet — S2 must not enqueue it'
  end

  # ── Rule obituaries (F4) ─────────────────────────────────────────────

  def expired_rule(content, set_by: 100)
    Agent::Scratchpad.add_rule(CHAT, content: content, set_by: set_by,
                               set_by_name: '@u', hours: -1)
  end

  def test_expired_rule_yields_one_obituary_task_then_silence
    expired_rule('мертвец')
    CronScheduler.tick
    tasks = BackgroundTask.where(chat_id: CHAT, task_type: 'rule_obituary').to_a
    assert_equal 1, tasks.size
    assert_equal ['мертвец'], tasks.first.params_hash['rules'].map { |r| r['content'] }
    CronScheduler.tick # already popped — nothing new
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'rule_obituary').count
  end

  def test_mass_expiry_in_one_tick_batches_into_single_task
    expired_rule('первое', set_by: 100)
    expired_rule('второе', set_by: 200)
    CronScheduler.tick
    tasks = BackgroundTask.where(chat_id: CHAT, task_type: 'rule_obituary').to_a
    assert_equal 1, tasks.size, 'cron owns combining — one task per tick'
    assert_equal %w[первое второе].sort,
                 tasks.first.params_hash['rules'].map { |r| r['content'] }.sort
  end

  def test_obituary_day_cap_pops_silently
    CronScheduler::OBITUARY_DAY_CAP.times do
      BackgroundTask.create!(task_type: 'rule_obituary', chat_id: CHAT,
                             attempts: 0, max_attempts: 3, params: '{}')
    end
    expired_rule('тихая смерть')
    CronScheduler.tick
    assert_equal CronScheduler::OBITUARY_DAY_CAP,
                 BackgroundTask.where(chat_id: CHAT, task_type: 'rule_obituary').count,
                 'past the cap no new task'
    assert_empty Agent::Scratchpad.rules(CHAT)
    raw = JSON.parse(ChatState.find(CHAT).scratchpad)
    assert_empty raw['rules'], 'expired rule must still be popped (deleted)'
  end
end

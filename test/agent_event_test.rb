require_relative 'test_helper'
require_relative '../lib/task_handlers/agent_event_emitter'

class AgentEventEmitterTest < BotTest
  CHAT = -1234567890

  class FakeHandler
    include AgentEventEmitter
  end

  def setup
    super
    LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
    @parent = BackgroundTask.create!(task_type: 'image_generate', status: 'failed',
                                     chat_id: CHAT, attempts: 1, max_attempts: 60,
                                     params: '{}')
  end

  def test_emit_creates_agent_event_task
    t = FakeHandler.new.emit_agent_event(@parent, 'image_failed', summary: 'something')
    refute_nil t
    assert_equal 'agent_event', t.task_type
    assert_equal CHAT, t.chat_id
    assert_equal 'image_failed', t.params_hash['event_type']
    assert_equal @parent.id, t.params_hash['parent_task_id']
  end

  def test_emit_respects_hour_cap
    h = FakeHandler.new
    AgentEventEmitter::AGENT_EVENT_HOUR_CAP.times do |i|
      refute_nil h.emit_agent_event(@parent, 'image_failed', summary: "n=#{i}")
    end
    # 11th emit in the same hour gets suppressed
    suppressed = h.emit_agent_event(@parent, 'image_failed', summary: 'too many')
    assert_nil suppressed
    assert_equal AgentEventEmitter::AGENT_EVENT_HOUR_CAP,
                 BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end

  def test_emit_does_not_count_old_events
    h = FakeHandler.new
    # Old events outside the 1-hour window don't count
    AgentEventEmitter::AGENT_EVENT_HOUR_CAP.times do |i|
      t = h.emit_agent_event(@parent, 'image_failed', summary: "n=#{i}")
      t.update_column(:created_at, Time.now - 7200) # 2h ago
    end
    fresh = h.emit_agent_event(@parent, 'image_failed', summary: 'new')
    refute_nil fresh
  end
end

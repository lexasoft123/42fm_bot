require_relative 'test_helper'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/agent/error_reporter'

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

  def test_runtime_failure_is_sanitized_and_returned_to_agent_queue
    error = RuntimeError.new('request failed https://secret.example/job/1 token=ABCDEFGHIJKLMNOPQRSTUVWX12345678')
    event = Agent::ErrorReporter.report(
      chat_id: CHAT, source: 'task_runner.test', error: error, parent_task: @parent
    )

    refute_nil event
    params = event.params_hash
    assert_equal 'runtime_error', params['event_type']
    assert_equal @parent.id, params['parent_task_id']
    assert_includes params['summary'], '[url]'
    assert_includes params['summary'], 'token=[redacted]'
    refute_includes params['summary'], 'secret.example'
  end

  def test_sanitizer_redacts_json_secrets_and_authorization_headers
    raw = %({"api_key":"sk-live+abc/123","password":"hunter2"} Authorization: Basic dXNlcjpwYXNz)
    safe = Agent::ErrorReporter.sanitize(raw)

    refute_includes safe, 'sk-live'
    refute_includes safe, 'hunter2'
    refute_includes safe, 'dXNlcjpwYXNz'
    assert_includes safe, '[redacted]'
  end

  def test_sanitizer_redacts_quoted_json_authorization_header
    safe = Agent::ErrorReporter.sanitize('{"Authorization":"Basic dXNlcjpwYXNz"}')

    refute_includes safe, 'dXNlcjpwYXNz'
    assert_includes safe, '[redacted]'
  end

  def test_parentless_runtime_errors_are_coalesced
    first = Agent::ErrorReporter.report(chat_id: CHAT, source: 'dispatcher', error: 'same failure')
    second = Agent::ErrorReporter.report(chat_id: CHAT, source: 'dispatcher', error: 'same failure')

    refute_nil first
    assert_nil second
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end

  def test_task_failure_does_not_duplicate_existing_specialized_event
    specialized = FakeHandler.new.emit_agent_event(@parent, 'image_failed', summary: 'specific')
    returned = Agent::ErrorReporter.report_task_failure(@parent)

    assert_equal specialized.id, returned.id
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end

  def test_agent_event_failure_never_creates_recursive_event
    parent = BackgroundTask.create!(task_type: 'agent_event', status: 'failed',
                                    chat_id: CHAT, attempts: 1, max_attempts: 5,
                                    params: '{}', result: '{"error":"boom"}')
    assert_nil Agent::ErrorReporter.report_task_failure(parent)
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event')
      .where.not(id: parent.id).count
  end

  def test_terminal_error_is_not_dropped_by_informational_event_cap
    AgentEventEmitter::AGENT_EVENT_HOUR_CAP.times do |i|
      refute_nil FakeHandler.new.emit_agent_event(@parent, 'image_failed', summary: "n=#{i}")
    end
    other = BackgroundTask.create!(task_type: 'other', status: 'failed', chat_id: CHAT,
                                   attempts: 1, max_attempts: 1, params: '{}',
                                   result: '{"error":"terminal"}')

    refute_nil Agent::ErrorReporter.report_task_failure(other)
    assert_equal AgentEventEmitter::AGENT_EVENT_HOUR_CAP + 1,
                 BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end
end

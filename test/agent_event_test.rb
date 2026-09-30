require_relative 'test_helper'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/agent/error_reporter'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_handler'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

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
    assert_equal @parent.id, t.parent_task_id
  end

  def test_emit_atomically_includes_delivery_metadata
    t = FakeHandler.new.emit_agent_event(
      @parent, 'image_delivery_failed', summary: 'delivery rejected',
      user_notified: true, forum_thread_id: 77
    )

    assert_equal true, t.params_hash['user_notified']
    assert_equal 77, t.params_hash['forum_thread_id']
    assert_equal @parent.id, t.parent_task_id
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


class AgentEventDeliverySuppressionTest < BotTest
  CHAT = -1234567891

  class FakeRunner
    class << self
      attr_reader :kwargs, :calls

      def reset!
        @kwargs = nil
        @calls = 0
      end
    end

    def initialize(**kwargs)
      self.class.instance_variable_set(:@kwargs, kwargs)
      self.class.instance_variable_set(:@calls, self.class.calls.to_i + 1)
    end

    def run
      'Вот ещё одно сообщение, которое нельзя отправлять'
    end
  end

  class FakeApi
    attr_reader :calls

    def initialize
      @calls = []
    end

    def sendMessage(**params)
      @calls << params
      OpenStruct.new(message_id: 501, message_thread_id: params[:message_thread_id])
    end
  end

  def setup
    super
    LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
    @original_runner = Agent.const_get(:Runner, false) if Agent.const_defined?(:Runner, false)
    Agent.send(:remove_const, :Runner) if Agent.const_defined?(:Runner, false)
    Agent.const_set(:Runner, FakeRunner)
    FakeRunner.reset!
  end

  def teardown
    Agent.send(:remove_const, :Runner) if Agent.const_defined?(:Runner, false)
    Agent.const_set(:Runner, @original_runner) if @original_runner
    super
  end

  def event_task(user_notified:, forum_thread_id: 91)
    BackgroundTask.create!(
      task_type: 'agent_event', chat_id: CHAT, max_attempts: 5,
      params: {
        event_type: 'image_delivery_failed', summary: 'delivery rejected',
        user_notified: user_notified, forum_thread_id: forum_thread_id,
      }.to_json
    )
  end

  def handler
    AgentEventHandler.new.tap do |instance|
      instance.define_singleton_method(:get_chat_context) { |_, thread_id: nil| '' }
      instance.define_singleton_method(:get_relevant_knowledge) { |_, _| '' }
    end
  end

  def test_user_notified_event_reaches_agent_but_structurally_suppresses_second_reply
    task = event_task(user_notified: true)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_empty api.calls
    assert_equal 0, FakeRunner.calls, 'already-notified event must not construct an agent runner'
    assert_nil FakeRunner.kwargs
    result = BackgroundTask.find(task.id).result_hash
    assert_equal false, result['replied']
    assert_equal true, result['user_notified']
  end

  def test_unnotified_event_reply_stays_in_forum_thread
    task = event_task(user_notified: false, forum_thread_id: 92)
    api = FakeApi.new
    captured_thread_id = nil
    event_handler = handler
    event_handler.define_singleton_method(:get_chat_context) do |_, thread_id: nil|
      captured_thread_id = thread_id
      ''
    end

    assert_equal :done, event_handler.call(task, api)

    assert_equal 1, FakeRunner.calls
    assert_equal 92, captured_thread_id
    assert_equal 1, api.calls.size
    assert_equal 92, api.calls.first[:message_thread_id]
    row = Message.find_by(chat_id: CHAT, message_id: 501)
    assert_equal 92, row.message_thread_id
  end
end

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
      attr_accessor :response

      def reset!
        @kwargs = nil
        @calls = 0
        @response = 'Вот ещё одно сообщение, которое нельзя отправлять'
      end
    end

    def initialize(**kwargs)
      self.class.instance_variable_set(:@kwargs, kwargs)
      self.class.instance_variable_set(:@calls, self.class.calls.to_i + 1)
    end

    def run
      raise self.class.response if self.class.response.is_a?(Exception)
      self.class.response
    end
  end

  class FakeApi
    attr_reader :calls
    attr_accessor :response

    def initialize
      @calls = []
      @response = OpenStruct.new(message_id: 501, message_thread_id: nil)
    end

    def sendMessage(**params)
      @calls << params
      return @response unless @response.respond_to?(:message_thread_id) && @response.message_thread_id.nil?
      OpenStruct.new(message_id: @response.message_id,
                     message_thread_id: params[:message_thread_id])
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

  def event_task(user_notified:, forum_thread_id: 91,
                 event_type: 'image_delivery_failed', parent_task_id: nil)
    BackgroundTask.create!(
      task_type: 'agent_event', chat_id: CHAT, max_attempts: 5,
      params: {
        event_type: event_type, summary: 'delivery rejected',
        user_notified: user_notified, forum_thread_id: forum_thread_id,
        parent_task_id: parent_task_id,
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

  def test_blank_image_failure_reply_uses_persisted_fallback_in_forum_thread
    FakeRunner.response = '(skip)'
    task = event_task(user_notified: false, forum_thread_id: 93,
                      event_type: 'image_failed', parent_task_id: 712)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 1, api.calls.size
    assert_equal 93, api.calls.first[:message_thread_id]
    assert_match(/задача #712/, api.calls.first[:text])
    row = Message.find_by(chat_id: CHAT, message_id: 501)
    assert_equal api.calls.first[:text], row.body
    result = BackgroundTask.find(task.id).result_hash
    assert_equal true, result['replied']
    assert_equal true, result['fallback']
  end

  def test_image_failure_turn_cannot_persist_provider_moderation_as_memory
    task = event_task(user_notified: false, event_type: 'image_failed', parent_task_id: 714)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal %w[remember forget set_rule repeal_rule challenge_rule court_rule],
                 FakeRunner.kwargs[:excluded_tools]
    assert_equal false, FakeRunner.kwargs[:persist_deferred_intents]
    prompt = FakeRunner.kwargs[:text]
    assert_includes prompt, 'не вызывай remember'
    assert_includes prompt, 'не сохраняй такие ограничения в scratchpad'
    refute_includes prompt, 'Помни про scratchpad: можно сохранить'
  end

  def test_agent_exception_uses_persisted_image_failure_fallback
    FakeRunner.response = RuntimeError.new('provider secret token=ABCDEFGHIJKLMNOPQRSTUVWX12345678')
    task = event_task(user_notified: false, event_type: 'image_failed_after_retries',
                      parent_task_id: 713)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 1, api.calls.size
    assert_match(/повторных попыток/, api.calls.first[:text])
    assert_match(/задача #713/, api.calls.first[:text])
    assert Message.exists?(chat_id: CHAT, message_id: 501, role: 'bot')
    assert_equal true, BackgroundTask.find(task.id).result_hash['fallback']
  end

  def test_blank_non_image_event_remains_silent
    FakeRunner.response = ''
    task = event_task(user_notified: false, event_type: 'cron_tick')
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_empty api.calls
    result = BackgroundTask.find(task.id).result_hash
    assert_equal false, result['replied']
    refute result.key?('fallback')
  end

  def test_unacknowledged_reply_stays_pending_and_reuses_cached_agent_text
    [nil, OpenStruct.new(message_id: '501'), OpenStruct.new(message_id: 0)].each do |response|
      task = event_task(user_notified: false)
      api = FakeApi.new
      api.response = response

      assert_equal :pending, handler.call(task, api)

      persisted = BackgroundTask.find(task.id)
      assert_equal 'pending', persisted.status
      assert_equal 'retrying', persisted.lifecycle_phase
      assert persisted.params_hash['reply_text']
      refute persisted.params_hash.key?('reply_receipt')
      refute Message.exists?(chat_id: CHAT, role: 'bot')
    end
    assert_equal 3, FakeRunner.calls
  end

  def test_persistence_failure_retries_receipt_without_resending_or_rerunning_agent
    task = event_task(user_notified: false, forum_thread_id: 94)
    api = FakeApi.new
    original = Message.method(:persist_bot_reply)
    Message.singleton_class.send(:define_method, :persist_bot_reply) { |**_| nil }

    assert_equal :pending, handler.call(task, api)
    pending = BackgroundTask.find(task.id)
    assert_equal 501, pending.params_hash.dig('reply_receipt', 'message_id')
    assert_equal 'delivered', pending.delivery_status
    assert_equal 1, api.calls.size
    assert_equal 1, FakeRunner.calls

    Message.singleton_class.send(:define_method, :persist_bot_reply, original)
    assert_equal :done, handler.call(task, api)
    assert_equal 1, api.calls.size, 'persist retry must not resend an acknowledged message'
    assert_equal 1, FakeRunner.calls, 'persist retry must reuse the cached agent reply'
    assert Message.exists?(chat_id: CHAT, message_id: 501, role: 'bot')
    assert_equal true, BackgroundTask.find(task.id).result_hash['replied']
  ensure
    Message.singleton_class.send(:define_method, :persist_bot_reply, original) if original
  end
end

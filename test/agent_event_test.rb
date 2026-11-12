require_relative 'test_helper'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/agent/error_reporter'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_handler'
require 'telegram/bot'
require 'faraday'
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

  def test_image_failure_metadata_is_written_atomically_and_allowlisted
    event = FakeHandler.new.emit_agent_event(
      @parent, 'image_failed', summary: 'diagnostics',
      failure_stage: 'poll', failure_reason: 'model_source_conflict'
    )
    stored = BackgroundTask.find(event.id)
    assert_equal 'poll', stored.params_hash['failure_stage']
    assert_equal 'model_source_conflict', stored.params_hash['failure_reason']

    invalid = FakeHandler.new.emit_agent_event(
      @parent, 'image_failed', summary: 'diagnostics',
      failure_stage: 'raw provider url', failure_reason: 'secret details'
    )
    assert_equal 'unknown', BackgroundTask.find(invalid.id).params_hash['failure_stage']
    assert_equal 'unknown', BackgroundTask.find(invalid.id).params_hash['failure_reason']

    ambiguous_submit = FakeHandler.new.emit_agent_event(
      @parent, 'image_failed', summary: 'diagnostics',
      failure_stage: 'submit', failure_reason: 'submit_outcome_unknown'
    )
    assert_equal 'submit_outcome_unknown',
                 BackgroundTask.find(ambiguous_submit.id).params_hash['failure_reason']
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
      raise @response if @response.is_a?(Exception)
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
                 event_type: 'runtime_error', parent_task_id: nil,
                 failure_stage: nil, failure_reason: nil)
    BackgroundTask.create!(
      task_type: 'agent_event', chat_id: CHAT, max_attempts: 5,
      params: {
        event_type: event_type, summary: 'delivery rejected',
        user_notified: user_notified, forum_thread_id: forum_thread_id,
        parent_task_id: parent_task_id,
        failure_stage: failure_stage, failure_reason: failure_reason,
      }.to_json
    )
  end

  def handler
    AgentEventHandler.new.tap do |instance|
      instance.define_singleton_method(:get_chat_context) { |_, thread_id: nil| '' }
      instance.define_singleton_method(:get_relevant_knowledge) { |_, _| '' }
    end
  end

  def test_user_notified_event_structurally_suppresses_second_reply
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

  def test_image_failure_reply_is_deterministic_and_stays_in_forum_thread
    FakeRunner.response = '(skip)'
    task = event_task(user_notified: false, forum_thread_id: 93,
                      event_type: 'image_failed', parent_task_id: 712)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 0, FakeRunner.calls, 'image failure notices must not depend on a model response'
    assert_equal 1, api.calls.size
    assert_equal 93, api.calls.first[:message_thread_id]
    assert_match(/[Зз]адача #712/, api.calls.first[:text])
    assert_match(/попросить попробовать ещё раз позже/, api.calls.first[:text])
    row = Message.find_by(chat_id: CHAT, message_id: 501)
    assert_equal api.calls.first[:text], row.body
    result = BackgroundTask.find(task.id).result_hash
    assert_equal true, result['replied']
    assert_equal true, result['fallback']
  end

  def test_image_failure_notice_uses_allowlisted_reason_without_agent_memory
    task = event_task(user_notified: false, event_type: 'image_failed', parent_task_id: 714,
                      failure_stage: 'submit', failure_reason: 'moderation')
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 0, FakeRunner.calls
    assert_match(/провайдер сообщил об ограничении содержимого/, api.calls.first[:text])
    assert_match(/[Зз]адача #714/, api.calls.first[:text])
    refute_match(/moderation|submit/, api.calls.first[:text])
  end

  def test_model_unavailable_reason_recommends_a_available_model
    task = event_task(user_notified: false, event_type: 'image_failed', parent_task_id: 715,
                      failure_stage: 'submit', failure_reason: 'model_unavailable')
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 0, FakeRunner.calls
    assert_includes api.calls.first[:text], 'запрошенная модель сейчас недоступна'
    assert_includes api.calls.first[:text], 'Выберите модель, которая сейчас доступна.'
    refute_match(/model_unavailable|submit/, api.calls.first[:text])
  end

  def test_unknown_submit_outcome_warns_retry_may_duplicate_paid_generation
    task = event_task(user_notified: false, event_type: 'image_failed', parent_task_id: 719,
                      failure_stage: 'submit', failure_reason: 'submit_outcome_unknown')
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 0, FakeRunner.calls
    text = api.calls.first[:text]
    assert_match(/не удалось подтвердить, принял ли провайдер запрос/, text)
    assert_match(/Запрос мог быть принят/, text)
    assert_match(/списать оплату повторно/, text)
    assert_match(/Явно попросите повторить только если согласны/, text)
  end

  def test_image_failure_notice_does_not_call_agent_even_when_it_would_fail
    FakeRunner.response = RuntimeError.new('provider secret token=ABCDEFGHIJKLMNOPQRSTUVWX12345678')
    task = event_task(user_notified: false, event_type: 'image_failed_after_retries',
                      parent_task_id: 713)
    api = FakeApi.new

    assert_equal :done, handler.call(task, api)

    assert_equal 1, api.calls.size
    assert_equal 0, FakeRunner.calls
    assert_match(/повторных попыток/, api.calls.first[:text])
    assert_match(/[Зз]адача #713/, api.calls.first[:text])
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

  def test_truncated_telegram_json_is_ambiguous_and_retries_cached_reply
    task = event_task(user_notified: false, event_type: 'image_failed',
                      parent_task_id: 716, failure_stage: 'submit',
                      failure_reason: 'provider_rejected')
    api = FakeApi.new
    api.response = begin
      JSON.parse('{"ok":true,"result":')
    rescue JSON::ParserError => error
      error
    end

    assert_equal :pending, handler.call(task, api)
    pending = BackgroundTask.find(task.id)
    assert_equal 'unknown', pending.delivery_status
    assert_equal 'retrying', pending.lifecycle_phase
    cached_text = pending.params_hash['reply_text']
    refute_nil cached_text

    api.response = OpenStruct.new(message_id: 502, message_thread_id: 91)
    assert_equal :done, handler.call(pending, api)
    complete = BackgroundTask.find(task.id)
    assert_equal 'delivered', complete.delivery_status
    assert_equal cached_text, api.calls.last[:text]
    assert_equal 2, api.calls.length
    assert Message.exists?(chat_id: CHAT, message_id: 502, role: 'bot')
  end

  def test_only_structured_definitive_telegram_rejection_marks_delivery_failed
    task = event_task(user_notified: false, event_type: 'image_failed',
                      parent_task_id: 717, failure_stage: 'submit',
                      failure_reason: 'provider_rejected')
    response = OpenStruct.new(body: { error_code: 400, description: 'Bad Request' }.to_json,
                              status: 400,
                              env: OpenStruct.new(url: 'https://api.telegram.org/botTOKEN/sendMessage'))
    api = FakeApi.new
    api.response = Telegram::Bot::Exceptions::ResponseError.new(response: response)

    assert_equal :failed, handler.call(task, api)
    failed = BackgroundTask.find(task.id)
    assert_equal 'failed', failed.status
    assert_equal 'failed', failed.delivery_status
  end

  def test_installed_telegram_client_ok_without_result_retries_then_exhausts_as_unknown
    api = telegram_api_for_body('{"ok":true}')
    assert_raises(NoMethodError) { api.sendMessage(chat_id: CHAT, text: 'probe') }

    task = event_task(user_notified: false, event_type: 'image_failed',
                      parent_task_id: 718, failure_stage: 'submit',
                      failure_reason: 'provider_rejected')
    task.update!(max_attempts: 2)
    runner = TaskRunner.new(telegram_api_for_body('{"ok":true}'))

    runner.process_one(task.id)
    pending = BackgroundTask.find(task.id)
    assert_equal 'pending', pending.status
    assert_equal 'unknown', pending.delivery_status
    assert_equal 'retrying', pending.lifecycle_phase
    refute_nil pending.params_hash['reply_text']

    runner.process_one(task.id)
    exhausted = BackgroundTask.find(task.id)
    assert_equal 'failed', exhausted.status
    assert_equal 'unknown', exhausted.delivery_status
    assert_equal 2, exhausted.attempts
    assert_equal 1, BackgroundTask.where(task_type: 'agent_event').count
  end

  def telegram_api_for_body(body)
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post('/botTOKEN/sendMessage') do
      [200, { 'content-type' => 'application/json' }, body]
    end
    connection = Faraday.new do |builder|
      builder.adapter :test, stubs
    end
    api = Telegram::Bot::Api.new('TOKEN', url: 'https://api.telegram.org')
    api.define_singleton_method(:connection) { connection }
    api
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

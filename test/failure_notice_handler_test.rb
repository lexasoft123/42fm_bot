require_relative 'test_helper'
require_relative '../lib/task_runner'
require_relative '../lib/agent/error_reporter'
require_relative '../lib/task_handlers/failure_notice_handler'
require 'ostruct'
require 'net/http'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

class FailureNoticeHandlerTest < BotTest
  CHAT = -100200300

  class FakeApi
    attr_reader :calls
    attr_accessor :response

    def initialize
      @calls = []
      @response = OpenStruct.new(message_id: 801, message_thread_id: nil)
    end

    def sendMessage(**params)
      @calls << params
      raise @response if @response.is_a?(Exception)
      @response
    end
  end

  def task(thread_id: 55, max_attempts: 5)
    BackgroundTask.create!(
      task_type: 'failure_notice', chat_id: CHAT, max_attempts: max_attempts,
      params: { text: 'Не удалось нарисовать', forum_thread_id: thread_id,
                parent_task_id: 42, parent_task_type: 'image_generate' }.to_json
    )
  end

  def test_success_requires_acknowledgement_and_persistence
    notice = task
    api = FakeApi.new

    assert_equal :done, FailureNoticeHandler.new.call(notice, api)

    persisted = BackgroundTask.find(notice.id)
    assert_equal 'done', persisted.status
    assert_equal 'delivered', persisted.delivery_status
    row = Message.find_by(chat_id: CHAT, message_id: 801)
    refute_nil row
    assert_equal 55, row.message_thread_id
  end

  def test_malformed_acknowledgements_remain_pending_for_bounded_task_retry
    [nil, OpenStruct.new(message_id: '801'), OpenStruct.new(message_id: 0)].each do |response|
      notice = task
      api = FakeApi.new
      api.response = response

      assert_equal :pending, FailureNoticeHandler.new.call(notice, api)

      persisted = BackgroundTask.find(notice.id)
      assert_equal 'pending', persisted.status
      assert_equal 'retrying', persisted.lifecycle_phase
      refute persisted.params_hash.key?('delivery_receipt')
    end
  end

  def test_persistence_retry_reuses_receipt_without_resending
    notice = task(thread_id: 56)
    api = FakeApi.new
    original = Message.method(:persist_bot_reply)
    Message.singleton_class.send(:define_method, :persist_bot_reply) { |**_| nil }

    assert_equal :pending, FailureNoticeHandler.new.call(notice, api)
    pending = BackgroundTask.find(notice.id)
    assert_equal 801, pending.params_hash.dig('delivery_receipt', 'message_id')
    assert_equal 'delivered', pending.delivery_status
    assert_equal 1, api.calls.size

    Message.singleton_class.send(:define_method, :persist_bot_reply, original)
    assert_equal :done, FailureNoticeHandler.new.call(notice, api)
    assert_equal 1, api.calls.size, 'persistence retry must not resend'
    assert Message.exists?(chat_id: CHAT, message_id: 801, role: 'bot')
  ensure
    Message.singleton_class.send(:define_method, :persist_bot_reply, original) if original
  end

  def test_error_reporter_treats_durable_notice_as_specialized_parent_event
    parent = BackgroundTask.create!(task_type: 'image_generate', status: 'failed',
                                    chat_id: CHAT, max_attempts: 60, params: '{}')
    notice = BackgroundTask.create!(task_type: 'failure_notice', chat_id: CHAT,
                                    parent_task_id: parent.id, max_attempts: 5,
                                    params: { parent_task_id: parent.id, text: 'failed' }.to_json)

    assert_equal notice.id, Agent::ErrorReporter.report_task_failure(parent).id
    assert_equal 0, BackgroundTask.where(task_type: 'agent_event').count
  end

  def test_task_runner_bounds_transport_exceptions_without_generic_notice
    notice = task(max_attempts: 3)
    api = FakeApi.new
    api.response = Net::ReadTimeout.new('telegram timed out')
    runner = TaskRunner.new(api)

    3.times { runner.process_one(BackgroundTask.find(notice.id)) }

    terminal = BackgroundTask.find(notice.id)
    assert_equal 'failed', terminal.status
    assert_equal 'failed', terminal.delivery_status
    assert_equal 3, terminal.attempts
    assert_equal 3, api.calls.size
    assert api.calls.all? { |params| params[:message_thread_id] == 55 }
    assert_equal 0, BackgroundTask.where(task_type: 'agent_event').count
    refute Message.exists?(chat_id: CHAT, role: 'bot')
  end

  def test_task_runner_bounds_malformed_ack_without_generic_timeout_notice
    notice = task(max_attempts: 3)
    api = FakeApi.new
    api.response = OpenStruct.new(message_id: 0)
    runner = TaskRunner.new(api)

    3.times { runner.process_one(BackgroundTask.find(notice.id)) }

    terminal = BackgroundTask.find(notice.id)
    assert_equal 'failed', terminal.status
    assert_equal 'failed', terminal.delivery_status
    assert_equal 3, terminal.attempts
    assert_equal 3, api.calls.size
    assert_equal 0, BackgroundTask.where(task_type: 'agent_event').count
    refute Message.exists?(chat_id: CHAT, role: 'bot')
  end

  def test_task_runner_persistence_exhaustion_keeps_delivered_without_resend
    notice = task(thread_id: 57, max_attempts: 3)
    api = FakeApi.new
    runner = TaskRunner.new(api)
    original = Message.method(:persist_bot_reply)
    Message.singleton_class.send(:define_method, :persist_bot_reply) { |**_| nil }

    3.times { runner.process_one(BackgroundTask.find(notice.id)) }

    terminal = BackgroundTask.find(notice.id)
    assert_equal 'failed', terminal.status
    assert_equal 'delivered', terminal.delivery_status
    assert_equal 3, terminal.attempts
    assert_equal 1, api.calls.size, 'accepted notice must not be resent during persistence exhaustion'
    assert_equal 801, terminal.params_hash.dig('delivery_receipt', 'message_id')
    assert_equal 0, BackgroundTask.where(task_type: 'agent_event').count
  ensure
    Message.singleton_class.send(:define_method, :persist_bot_reply, original) if original
  end
end

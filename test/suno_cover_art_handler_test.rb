require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:suno)
  Settings.singleton_class.send(:define_method, :suno) {
    { 'api_url' => 'https://api.sunoapi.org', 'api_key' => 'k', 'model' => 'V5' }
  }
end

require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/media_download'
require_relative '../lib/task_runner'
require_relative '../lib/suno_client'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/task_handlers/suno_cover_art_handler'

class SunoCoverArtHandlerTest < BotTest
  CHAT = -1234567891

  class FakeApi
    attr_reader :sent_messages
    def initialize; @sent_messages = []; end
    def sendMessage(**kw); @sent_messages << kw; { 'ok' => true, 'result' => { 'message_id' => 1 } }; end
  end

  def setup
    super
    @handler = SunoCoverArtHandler.new
    @api = FakeApi.new
  end

  def make_task(external_id: 'cov-task-1', generation_retries: nil)
    p = { source_task_id: 'sun-source-1', source_title: 'Тестовая' }
    p[:generation_retries] = generation_retries if generation_retries
    BackgroundTask.create!(
      task_type: 'suno_cover_art', chat_id: CHAT, max_attempts: 60,
      external_id: external_id, params: p.to_json
    )
  end

  def stub_poll(result_value)
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    fake = Object.new
    fake.define_singleton_method(:poll_cover_art_once) { |_id| result_value }
    SunoClient.singleton_class.send(:define_method, :new) { fake }
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new)
    SunoClient.singleton_class.send(:remove_method, :__new)
  end

  def test_retry_clears_external_id_and_increments_counter
    task = make_task
    stub_poll(:retry) { @handler.send(:poll_and_deliver, task, @api) }
    task.reload
    assert_nil task.external_id, ':retry must clear external_id so next call re-submits'
    assert_equal 1, task.params_hash['generation_retries']
  end

  def test_retry_capped_marks_failed_and_notifies
    task = make_task(generation_retries: SunoCoverArtHandler::MAX_GENERATION_RETRIES)
    result = stub_poll(:retry) { @handler.send(:poll_and_deliver, task, @api) }
    assert_equal :failed, result
    task.reload
    assert_equal 'failed', task.status
    assert_equal 'cover_art_failed_after_retries', task.result_hash['error']
    assert_equal 1, @api.sent_messages.size, 'must notify chat with a sendMessage'
    assert_equal 'Не удалось нарисовать обложку', @api.sent_messages.first[:text]
  end

  def test_failed_branch_marks_failed_and_notifies_chat
    task = make_task
    result = stub_poll(:failed) { @handler.send(:poll_and_deliver, task, @api) }
    assert_equal :failed, result
    assert_equal 1, @api.sent_messages.size, 'plain :failed branch must also notify chat'
  end

  def test_pending_branch_returns_pending_with_no_side_effects
    task = make_task
    result = stub_poll(:pending) { @handler.send(:poll_and_deliver, task, @api) }
    assert_equal :pending, result
    assert_empty @api.sent_messages
    task.reload
    assert_equal 'pending', task.status
  end

  # Failure-with-detail propagates from poll_cover_art_once's Hash return
  # to mark_failed_and_notify's agent_event summary. Mirror of the
  # SunoTaskHandler test in suno_handler_chain_test.rb — pins the same
  # contract for the cover-art path so a refactor in either handler
  # can't silently drop the summary-append.
  def test_failure_hash_propagates_error_detail_to_agent_event_summary
    task = make_task
    failure_hash = { failed: true, error: 'Suno [403]: Image content blocked' }
    stub_poll(failure_hash) { @handler.send(:poll_and_deliver, task, @api) }

    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event, 'cover_art Hash failure must emit agent_event'
    summary = event.params_hash['summary']
    assert_match(/cover_art_failed/,        summary)
    assert_match(/Image content blocked/,   summary,
                 'Suno error detail must reach the agent_event summary verbatim')
  end
end

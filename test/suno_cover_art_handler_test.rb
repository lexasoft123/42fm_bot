require_relative 'test_helper'
require 'tempfile'
require 'telegram/bot'
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
    attr_reader :sent_messages, :media_group_calls
    attr_accessor :media_group_result
    def initialize; @sent_messages = []; @media_group_calls = []; end
    def sendMessage(**kw); @sent_messages << kw; { 'ok' => true, 'result' => { 'message_id' => 1 } }; end
    def sendMediaGroup(**kw)
      @media_group_calls << kw
      count = JSON.parse(kw[:media]).size
      media_group_result || { 'ok' => true, 'result' => count.times.map { |i| { 'message_id' => 100 + i } } }
    end
  end

  def setup
    super
    @handler = SunoCoverArtHandler.new
    @api = FakeApi.new
    @handler.define_singleton_method(:download_to_tempfile) do |*_args, **_kwargs|
      tmp = Tempfile.new(['cover', '.png']); tmp.write('png'); tmp.rewind; tmp
    end
  end

  def make_task(external_id: 'cov-task-1', generation_retries: nil, forum_thread_id: nil)
    p = { source_task_id: 'sun-source-1', source_title: 'Тестовая' }
    p[:generation_retries] = generation_retries if generation_retries
    p[:forum_thread_id] = forum_thread_id if forum_thread_id
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
    assert_equal 'retrying', task.lifecycle_phase
    assert_equal 1, task.retry_count
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
  def with_raising_cover_art(message)
    stub = Object.new
    stub.define_singleton_method(:cover_art) { |**_| raise message }
    SunoClient.singleton_class.send(:alias_method, :__new_perm, :new)
    SunoClient.singleton_class.send(:define_method, :new) { stub }
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_perm) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_perm) rescue nil
  end

  # Permanent Suno rejection → handler fails with agent_event instead of
  # re-raising into TaskRunner's raw "Ошибка: …" notice.
  def test_permanent_submit_rejection_fails_now_with_agent_event
    task = make_task(external_id: nil)
    result = with_raising_cover_art('Suno /api/v1/suno/cover/generate failed: 400 cover already generated') do
      @handler.send(:submit, task, @api)
    end
    assert_equal :failed, result
    assert_equal 'cover_art_submit_rejected', BackgroundTask.find(task.id).result_hash['error']
    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event
    assert_match(/cover already generated/, event.params_hash['summary'])
  end

  def test_retryable_submit_error_still_reraises
    task = make_task(external_id: nil)
    assert_raises(RuntimeError) do
      with_raising_cover_art('Suno /api/v1/suno/cover/generate failed: 503 upstream') { @handler.send(:submit, task, @api) }
    end
    assert_equal 1, BackgroundTask.find(task.id).params_hash['submit_failures']
    assert_equal 'retrying', BackgroundTask.find(task.id).lifecycle_phase
    assert_equal 1, BackgroundTask.find(task.id).retry_count
  end

  def test_success_requires_valid_ids_and_marks_delivered_after_persistence
    task = make_task
    clips = [{ image_url: 'https://cdn/one.png' }, { image_url: 'https://cdn/two.png' }]
    assert_equal :pending, stub_poll(clips) { @handler.send(:poll_and_deliver, task, @api) }
    assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api)
    assert_equal :done, @handler.call(BackgroundTask.find(task.id), @api)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'done', persisted.status
    assert_equal 'completed', persisted.lifecycle_phase
    assert_equal 'delivered', persisted.delivery_status
    assert_equal 2, Message.where(chat_id: CHAT, role: 'bot').count
  end

  def test_receipt_reentry_persists_without_resending_and_keeps_forum_thread
    task = make_task(forum_thread_id: 404)
    clips = [{ image_url: 'https://cdn/one.png' }]
    assert_equal :pending, stub_poll(clips) { @handler.call(task, @api) }
    assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api)

    checkpoint = BackgroundTask.find(task.id)
    assert_equal 'persisting_delivery', checkpoint.lifecycle_phase
    assert_equal 404, @api.media_group_calls.first[:message_thread_id]
    assert_equal :done, @handler.call(checkpoint, @api)
    assert_equal 1, @api.media_group_calls.size, 'durable receipt must prevent a Telegram resend'
    assert_equal 404, Message.where(chat_id: CHAT, role: 'bot').last.message_thread_id
  end

  def test_terminal_provider_result_resets_attempt_budget_and_photo_receipt_stays_viewable
    task = make_task(forum_thread_id: 404)
    task.update!(attempts: 59)
    clips = [{ image_url: 'https://cdn/one.png' }]
    assert_equal :pending, stub_poll(clips) { @handler.call(task, @api) }
    assert_equal 0, BackgroundTask.find(task.id).attempts
    @api.media_group_result = { 'result' => [{ 'message_id' => 123, 'photo' => [
      { 'file_id' => 'SMALL', 'width' => 320 }, { 'file_id' => 'VIEWABLE', 'width' => 1280 }
    ] }] }
    assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api)
    receipt = BackgroundTask.find(task.id).params_hash['delivery_receipt'].first
    assert_equal 'VIEWABLE', receipt['photo'].last['file_id']
    assert_equal :done, @handler.call(BackgroundTask.find(task.id), @api)
    row = Message.find_by(chat_id: CHAT, message_id: 123)
    assert_equal 'VIEWABLE', row.attachment_photo_file_id
    assert_equal 404, row.message_thread_id
  end

  def test_truthy_malformed_media_group_response_is_delivery_failure
    task = make_task
    @api.media_group_result = { 'ok' => true, 'result' => [{ 'message_id' => '1' }] }
    clips = [{ image_url: 'https://cdn/one.png' }]
    assert_equal :pending, stub_poll(clips) { @handler.send(:poll_and_deliver, task, @api) }
    2.times { assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api) }
    assert_equal :failed, @handler.call(BackgroundTask.find(task.id), @api)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'failed', persisted.status
    assert_equal 'failed', persisted.delivery_status
    refute Message.where(chat_id: CHAT, role: 'bot').where('body LIKE ?', '%обложка для%').exists?
  end
end

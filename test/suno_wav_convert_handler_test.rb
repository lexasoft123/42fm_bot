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
require_relative '../lib/task_handlers/suno_wav_convert_handler'

# Pins the WAV-convert handler's poll_and_deliver discrimination contract
# and error-detail propagation to agent_event summaries.
#
# Why this exists: SunoWavConvertHandler's `case Hash` arm is overloaded —
# `{ wav_url: '...' }` means success, `{ failed: true, error: '...' }` means
# failure with detail. Without explicit key-checks, an unknown future shape
# would silently fall into the success branch and crash inside send_wav.
class SunoWavConvertHandlerTest < BotTest
  CHAT = -1234567896

  class FakeApi
    attr_reader :sent_messages, :audio_calls
    attr_accessor :audio_result
    def initialize; @sent_messages = []; @audio_calls = []; end
    def sendMessage(**kw); @sent_messages << kw; { 'ok' => true, 'result' => { 'message_id' => 1 } }; end
    def sendAudio(**kw); @audio_calls << kw; audio_result || { 'message_id' => 91 }; end
  end

  def setup
    super
    @handler = SunoWavConvertHandler.new
    @api = FakeApi.new
    @handler.define_singleton_method(:download_to_tempfile) do |*_args, **_kwargs|
      tmp = Tempfile.new(['wav', '.wav']); tmp.write('wav'); tmp.rewind; tmp
    end
  end

  def make_task(forum_thread_id: nil)
    params = { source_task_id: 'src-1', source_title: 'X', source_performer: 'Y',
               clip_index: 1, audio_id: 'aud-1', user_uid: 1 }
    params[:forum_thread_id] = forum_thread_id if forum_thread_id
    BackgroundTask.create!(
      task_type: 'suno_wav_convert', chat_id: CHAT, max_attempts: 60,
      external_id: 'wav-task-1',
      params: params.to_json
    )
  end

  def stub_poll(result_value)
    SunoClient.singleton_class.send(:alias_method, :__new_wav_test, :new)
    SunoClient.singleton_class.send(:define_method, :new) {
      stub = Object.new
      stub.define_singleton_method(:poll_wav_once) { |_id| result_value }
      stub
    }
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_wav_test) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_wav_test)      rescue nil
  end

  def test_failure_hash_propagates_error_detail_to_agent_event_summary
    task = make_task
    failure = { failed: true, error: 'Suno [413]: Source audio not found' }
    stub_poll(failure) { @handler.send(:poll_and_deliver, task, @api) }

    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event, 'WAV failure-hash must emit agent_event'
    summary = event.params_hash['summary']
    assert_match(/wav_failed/,                summary)
    assert_match(/Source audio not found/,    summary,
                 'Suno error detail must reach the agent_event summary verbatim')
  end

  # Unknown Hash shape (future Suno change, parser regression) must NOT
  # fall through into the success branch and crash send_wav with nil
  # wav_url. Handler must log + emit a typed failure with the raw Hash
  # in the detail so we can debug from prod.
  def test_unknown_hash_shape_fails_loudly_with_diagnostic_detail
    task = make_task
    weird = { unexpected: 'nothing useful' }
    stub_poll(weird) { @handler.send(:poll_and_deliver, task, @api) }

    task.reload
    assert_equal 'failed',                       task.status
    assert_equal 'wav_unknown_response_shape',   task.result_hash['error']
    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event
    assert_match(/unexpected poll Hash/,         event.params_hash['summary'])
    assert_match(/nothing useful|unexpected/,    event.params_hash['summary'])
  end


  def test_empty_success_resubmit_uses_canonical_retry_lifecycle
    task = make_task
    assert_equal :pending, stub_poll(:retry) { @handler.send(:poll_and_deliver, task, @api) }
    persisted = BackgroundTask.find(task.id)
    assert_nil persisted.external_id
    assert_equal 'retrying', persisted.lifecycle_phase
    assert_equal 1, persisted.retry_count
    assert_equal 1, persisted.params_hash['generation_retries']
  end
  def test_permanent_submit_rejection_fails_now_with_agent_event
    task = BackgroundTask.create!(
      task_type: 'suno_wav_convert', chat_id: CHAT, max_attempts: 60,
      params: { source_task_id: 'src-1', source_title: 'X', clip_index: 1, audio_id: 'aud-1', user_uid: 1 }.to_json
    )
    stub = Object.new
    stub.define_singleton_method(:convert_to_wav) { |**_| raise 'Suno /api/v1/wav/generate failed: 429 insufficient credits' }
    SunoClient.singleton_class.send(:alias_method, :__new_perm, :new)
    SunoClient.singleton_class.send(:define_method, :new) { stub }
    result = @handler.send(:submit, task, @api)
    assert_equal :failed, result
    assert_equal 'wav_submit_rejected', BackgroundTask.find(task.id).result_hash['error']
    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event
    assert_match(/insufficient credits/, event.params_hash['summary'])
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_perm) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_perm) rescue nil
  end


  def test_success_marks_delivered_only_after_valid_persisted_send
    task = make_task
    result = { wav_url: 'https://cdn/audio.wav' }
    assert_equal :pending, stub_poll(result) { @handler.send(:poll_and_deliver, task, @api) }
    assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api)
    assert_equal :done, @handler.call(BackgroundTask.find(task.id), @api)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'done', persisted.status
    assert_equal 'completed', persisted.lifecycle_phase
    assert_equal 'delivered', persisted.delivery_status
    assert Message.where(chat_id: CHAT, role: 'bot').where('body LIKE ?', '%wav%').exists?
  end

  def test_receipt_reentry_persists_without_resending_and_keeps_forum_thread
    task = make_task(forum_thread_id: 505)
    assert_equal :pending, stub_poll({ wav_url: 'https://cdn/audio.wav' }) { @handler.call(task, @api) }
    assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api)

    checkpoint = BackgroundTask.find(task.id)
    assert_equal 'persisting_delivery', checkpoint.lifecycle_phase
    assert_equal 505, @api.audio_calls.first[:message_thread_id]
    assert_equal :done, @handler.call(checkpoint, @api)
    assert_equal 1, @api.audio_calls.size, 'durable receipt must prevent a Telegram resend'
    assert_equal 505, Message.where(chat_id: CHAT, role: 'bot').last.message_thread_id
  end

  def test_terminal_provider_result_resets_poll_attempt_budget
    task = make_task
    task.update!(attempts: 59)
    assert_equal :pending, stub_poll({ wav_url: 'https://cdn/audio.wav' }) { @handler.call(task, @api) }
    assert_equal 0, BackgroundTask.find(task.id).attempts
  end

  def test_truthy_malformed_audio_response_is_delivery_failure
    task = make_task
    @api.audio_result = { 'ok' => true, 'result' => { 'message_id' => 0 } }
    assert_equal :pending, stub_poll({ wav_url: 'https://cdn/audio.wav' }) { @handler.send(:poll_and_deliver, task, @api) }
    2.times { assert_equal :pending, @handler.call(BackgroundTask.find(task.id), @api) }
    assert_equal :failed, @handler.call(BackgroundTask.find(task.id), @api)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'failed', persisted.status
    assert_equal 'failed', persisted.delivery_status
    refute Message.where(chat_id: CHAT, role: 'bot').pluck(:body).any? { |body| body.start_with?('[wav:') }
  end
end

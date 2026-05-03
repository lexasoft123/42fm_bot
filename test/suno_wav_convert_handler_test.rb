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
    attr_reader :sent_messages
    def initialize; @sent_messages = []; end
    def sendMessage(**kw); @sent_messages << kw; { 'ok' => true, 'result' => { 'message_id' => 1 } }; end
  end

  def setup
    super
    @handler = SunoWavConvertHandler.new
    @api = FakeApi.new
  end

  def make_task
    BackgroundTask.create!(
      task_type: 'suno_wav_convert', chat_id: CHAT, max_attempts: 60,
      external_id: 'wav-task-1',
      params: { source_task_id: 'src-1', source_title: 'X', source_performer: 'Y',
                clip_index: 1, audio_id: 'aud-1', user_uid: 1 }.to_json
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
end

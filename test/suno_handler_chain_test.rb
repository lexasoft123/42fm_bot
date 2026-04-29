require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/media_download'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/task_handlers/suno_handler'

# Tests for the with_cover_art chaining logic in SunoTaskHandler#poll_and_deliver.
# We don't drive a full poll cycle — we exercise maybe_chain_cover_art directly
# since it carries the dedup, rate-limit, and chain-on-success rules.
class SunoHandlerChainTest < BotTest
  CHAT = -1234567890

  def setup
    super
    LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
    Settings.singleton_class.send(:define_method, :auth) {
      { 'rate_limits' => { 'suno' => { 'max' => 100, 'window_minutes' => 60 } } }
    } unless Settings.respond_to?(:auth)

    @handler = SunoTaskHandler.new
  end

  def make_song_task(with_cover_art:, external_id: 'sun-task-123', title: 'Тестовая')
    BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      external_id: external_id,
      params: { title: title, with_cover_art: with_cover_art, user_uid: 1 }.to_json
    )
  end

  def test_chain_creates_cover_art_task_when_flag_true
    task = make_song_task(with_cover_art: true)
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')

    chained = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').to_a
    assert_equal 1, chained.size
    assert_equal task.external_id, chained.first.params_hash['source_task_id']
    assert_equal 'Тестовая', chained.first.params_hash['source_title']
  end

  def test_chain_skips_when_flag_false
    task = make_song_task(with_cover_art: false)
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').count
  end

  def test_chain_dedup_on_re_entry
    task = make_song_task(with_cover_art: true)
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').count,
                 'second call must not enqueue another cover-art row for the same source'
  end

  def test_chain_skips_when_external_id_missing
    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      params: { title: 'x', with_cover_art: true }.to_json
    )
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'x')
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').count
  end

  def test_chain_skips_when_rate_limit_exhausted
    # Stub the rate limiter to report exhausted
    RateLimiter.singleton_class.send(:alias_method, :__exceeded, :exceeded?)
    RateLimiter.singleton_class.send(:define_method, :exceeded?) { |_, _| true }

    task = make_song_task(with_cover_art: true)
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').count
  ensure
    RateLimiter.singleton_class.send(:alias_method, :exceeded?, :__exceeded)
    RateLimiter.singleton_class.send(:remove_method, :__exceeded)
  end

  def test_with_cover_art_param_persists_across_retry
    # Sanity that a 'retry' branch (clearing external_id) doesn't drop the flag.
    # We don't simulate the full retry — just confirm params_hash round-trips.
    task = make_song_task(with_cover_art: true)
    p = task.params_hash
    p['generation_retries'] = 1
    task.update!(external_id: nil, params: p.to_json)
    reloaded = BackgroundTask.find(task.id)
    assert_equal true, reloaded.params_hash['with_cover_art']
  end
end

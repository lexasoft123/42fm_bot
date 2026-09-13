require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    { 'rate_limits' => { 'suno' => { 'max' => 100, 'window_minutes' => 60 } } }
  }
end
unless Settings.respond_to?(:replies)
  Settings.singleton_class.send(:define_method, :replies) { {} }
end

require_relative '../lib/pending_audio_request'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/telegram_file'
require_relative '../lib/agent/tools/cover_art' # SONG_TASK_TYPES
require_relative '../lib/agent/tools/cover_audio'
require_relative '../lib/agent/tools/add_vocals'
require_relative '../lib/agent/tools/separate_vocals'
require_relative '../lib/agent/tools/suno'

# PendingAudioRequest: the DM-only "send the audio next" follow-up registry,
# and the source tools that offer it when no audio was found. The
# MessageResponder hook that replays it lives in production_errors_test.rb
# (PendingAudioFollowupTest) next to the other responder tests.
class PendingAudioRequestTest < BotTest
  DM = 424242

  def setup
    super
    PendingAudioRequest.reset!
    @user = OpenStruct.new(uid: DM, role: 'member')
  end

  def teardown
    PendingAudioRequest.reset!
    super
  end

  def ctx(private_chat: true, user_initiated: true, text: 'сделай кавер в стиле блюз', chat_id: DM)
    { chat_id: chat_id, user: @user, api: Object.new, private_chat: private_chat,
      user_initiated: user_initiated, request_text: text, message_id: 9, audio: nil, audio_source: nil }
  end

  # --- registry ---

  def test_take_returns_entry_once
    PendingAudioRequest.register(chat_id: DM, uid: DM, text: 'x', message_id: 1, tool: 'cover_audio')
    entry = PendingAudioRequest.take(DM, DM)
    assert_equal 'x', entry[:text]
    assert_nil PendingAudioRequest.take(DM, DM), 'an entry replays at most once'
  end

  def test_entry_expires_after_ttl
    t0 = Time.now
    PendingAudioRequest.register(chat_id: DM, uid: DM, text: 'x', message_id: 1, tool: 'cover_audio', now: t0)
    assert_nil PendingAudioRequest.take(DM, DM, now: t0 + PendingAudioRequest::TTL_SECONDS + 1)
  end

  def test_entry_is_keyed_by_chat_and_user
    PendingAudioRequest.register(chat_id: DM, uid: DM, text: 'x', message_id: 1, tool: 'cover_audio')
    assert_nil PendingAudioRequest.take(DM, 777), 'another user must not consume it'
    refute_nil PendingAudioRequest.take(DM, DM)
  end

  def test_clear_removes_entry
    PendingAudioRequest.register(chat_id: DM, uid: DM, text: 'x', message_id: 1, tool: 'cover_audio')
    PendingAudioRequest.clear(DM, DM)
    assert_nil PendingAudioRequest.take(DM, DM)
  end

  def test_offer_only_on_private_user_initiated_turns_with_text
    assert PendingAudioRequest.offer(ctx, tool: 'cover_audio')
    PendingAudioRequest.reset!
    assert_nil PendingAudioRequest.offer(ctx(private_chat: false), tool: 'cover_audio'), 'groups never register'
    assert_nil PendingAudioRequest.offer(ctx(user_initiated: false), tool: 'cover_audio'), 'agent_event/cron turns never register'
    assert_nil PendingAudioRequest.offer(ctx(text: '  '), tool: 'cover_audio')
    assert_nil PendingAudioRequest.take(DM, DM)
  end

  # --- tools ---

  def call(tool, args, c)
    Agent::ToolRegistry.find(tool).handler.call(args, c)
  end

  def cover_args
    { 'style' => 'blues', 'title' => 'T', 'lyrics' => '', 'topic' => '', 'upload_url' => '',
      'vocal_gender' => '', 'negative_tags' => '', 'instrumental' => false, 'with_cover_art' => false }
  end

  def test_cover_audio_without_source_in_dm_registers_and_returns_plain_text
    result = call('cover_audio', cover_args, ctx)
    assert_kind_of String, result, 'plain string, not ToolResult.deferred — no orphan scratchpad intention'
    assert_match(/следующим сообщением/, result)
    entry = PendingAudioRequest.take(DM, DM)
    assert_equal 'сделай кавер в стиле блюз', entry[:text]
    assert_equal 'cover_audio', entry[:tool]
    assert_equal 0, BackgroundTask.count
  end

  def test_cover_audio_without_source_in_group_keeps_deferral
    result = call('cover_audio', cover_args, ctx(private_chat: false, chat_id: -100))
    assert result.is_a?(Agent::ToolResult) && result.deferred?
    assert_nil PendingAudioRequest.take(-100, DM)
  end

  def test_rate_limited_turn_does_not_register
    RateLimiter.singleton_class.send(:alias_method, :__exceeded_pa, :exceeded?)
    RateLimiter.singleton_class.send(:define_method, :exceeded?) { |_, _, **_| true }
    result = call('add_vocals', { 'theme' => 'x', 'style' => 's', 'title' => 't', 'upload_url' => '',
                                  'vocal_gender' => '', 'negative_tags' => '', 'with_cover_art' => false }, ctx)
    assert result.is_a?(Agent::ToolResult) && result.deferred?
    assert_nil PendingAudioRequest.take(DM, DM), 'a follow-up that would be rate-limited must not be promised'
  ensure
    RateLimiter.singleton_class.send(:alias_method, :exceeded?, :__exceeded_pa) rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__exceeded_pa) rescue nil
  end

  def test_separate_vocals_without_source_in_dm_registers
    result = call('separate_vocals', {}, ctx(text: 'убери вокал'))
    assert_kind_of String, result
    assert_equal 'separate_vocals', PendingAudioRequest.take(DM, DM)[:tool]
  end

  def test_agent_event_turn_without_source_does_not_register
    call('separate_vocals', {}, ctx(user_initiated: false))
    assert_nil PendingAudioRequest.take(DM, DM)
  end

  # Review #1: a turn can offer the follow-up and then still create a task
  # (a later tool call found a source). The entry must not survive — the
  # user's next unrelated captionless audio would bill a second job.
  def test_task_created_later_in_the_same_turn_clears_the_offer
    call('cover_audio', cover_args, ctx)
    refute_nil PendingAudioRequest.take(DM, DM) # sanity: offer registered
    call('cover_audio', cover_args, ctx)       # registers again
    call('cover_audio', cover_args.merge('upload_url' => 'https://example.com/found.mp3'), ctx)
    assert_equal 1, BackgroundTask.where(task_type: 'suno_cover_audio').count
    assert_nil PendingAudioRequest.take(DM, DM), 'creating the task must clear the pending follow-up'
  end

  def test_every_suno_task_creation_clears_the_offer
    creators = {
      'separate_vocals' => { 'upload_url' => 'https://example.com/a.mp3' },
      'add_vocals'      => { 'theme' => 'x', 'style' => 's', 'title' => 't', 'upload_url' => 'https://example.com/a.mp3',
                             'vocal_gender' => '', 'negative_tags' => '', 'with_cover_art' => false },
      'compose_song'    => { 'theme' => 'про море', 'title' => 'Море', 'genre' => 'рок', 'artist' => '',
                             'lyrics' => '', 'negative_tags' => '', 'with_cover_art' => false },
    }
    creators.each do |tool, args|
      PendingAudioRequest.register(chat_id: DM, uid: DM, text: 'x', message_id: 1, tool: 'cover_audio')
      call(tool, args, ctx)
      assert_nil PendingAudioRequest.take(DM, DM), "#{tool} creating a task must clear the pending follow-up"
    end
    assert_equal 3, BackgroundTask.count
  end
end

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

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/agent/tools/convert_to_wav'

# Mirrors cover_art_tool_test.rb — same source-resolution chain:
#   1. explicit args['suno_task_id']
#   2. reply_to_message_id → Message.bg_task_external_id → BackgroundTask
#   3. most recent done song in chat (any suno_* type)
class ConvertToWavToolTest < BotTest
  CHAT = -1234567893

  def setup
    super
    @tool = Agent::ToolRegistry.find('convert_to_wav')
    @user = OpenStruct.new(uid: 999, role: 'member')
  end

  def make_song(task_type: 'suno_generate', external_id:, title:, performer: '')
    BackgroundTask.create!(task_type: task_type, chat_id: CHAT, max_attempts: 60,
                           status: 'done', external_id: external_id,
                           params: { title: title, artist: performer, user_uid: 1 }.to_json)
  end

  def make_bot_audio_msg(message_id:, body:, bg_task_external_id: nil)
    Message.create!(role: 'bot', chat_id: CHAT, message_id: message_id, body: body,
                    bg_task_external_id: bg_task_external_id)
  end

  def call_tool(args, reply_to_message_id: nil)
    ctx = { chat_id: CHAT, user: @user, reply_to_message_id: reply_to_message_id }
    @tool.handler.call(args, ctx)
  end

  def test_explicit_suno_task_id_wins
    make_song(external_id: 'recent-id', title: 'Recent')
    result = call_tool({ 'suno_task_id' => 'explicit-id-123' })
    assert_match(/Делаю WAV/, result)
    wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
    assert_equal 'explicit-id-123', wav.params_hash['source_task_id']
    assert_equal 1, wav.params_hash['clip_index'], 'default clip_index is 1'
  end

  def test_reply_resolution_picks_song_via_bg_task_external_id
    older = make_song(external_id: 'old-task-id', title: 'Old Song', performer: 'lex')
    make_song(external_id: 'new-task-id', title: 'New Song') # would win without reply
    msg_id = 543310
    make_bot_audio_msg(message_id: msg_id, body: '[песня: Old Song]',
                       bg_task_external_id: older.external_id)
    call_tool({ 'suno_task_id' => '' }, reply_to_message_id: msg_id)
    wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
    assert_equal 'old-task-id', wav.params_hash['source_task_id']
    assert_equal 'Old Song',    wav.params_hash['source_title']
    assert_equal 'lex',         wav.params_hash['source_performer']
  end

  def test_no_reply_uses_most_recent_done_song
    make_song(external_id: 'oldest', title: 'O')
    make_song(external_id: 'newest', title: 'N')
    call_tool({})
    wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
    assert_equal 'newest', wav.params_hash['source_task_id']
  end

  def test_no_song_in_chat_defers_with_intent
    result = call_tool({})
    assert result.is_a?(Agent::ToolResult), 'must return a deferred ToolResult, not a string'
    assert result.deferred?
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').count
  end

  def test_clip_index_2_passed_through
    make_song(external_id: 'task-x', title: 'X')
    call_tool({ 'clip_index' => 2 })
    wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
    assert_equal 2, wav.params_hash['clip_index']
  end

  def test_clip_index_clamps_to_default_when_invalid
    make_song(external_id: 'task-y', title: 'Y')
    [0, 3, 99, -1, 'bogus'].each do |bad|
      call_tool({ 'clip_index' => bad })
      wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
      assert_equal 1, wav.params_hash['clip_index'],
                   "clip_index=#{bad.inspect} must clamp to 1, got #{wav.params_hash['clip_index'].inspect}"
    end
  end

  # Audio_id is resolved later (in the handler via fetch_audio_ids), not at
  # tool-call time. Locks the contract: tool persists clip_index, handler
  # turns it into audio_id.
  def test_tool_does_not_resolve_audio_id_at_dispatch_time
    make_song(external_id: 'task-z', title: 'Z')
    call_tool({})
    wav = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').last
    assert_nil wav.params_hash['audio_id'], 'audio_id resolution belongs to the handler'
  end

  def test_rate_limited_user_gets_deferred
    # Force the bucket exhausted just for this test.
    RateLimiter.singleton_class.send(:alias_method, :__exceeded, :exceeded?)
    RateLimiter.singleton_class.send(:define_method, :exceeded?) { |_, _, **_| true }
    RateLimiter.singleton_class.send(:alias_method, :__minutes,  :minutes_until_free)
    RateLimiter.singleton_class.send(:define_method, :minutes_until_free) { |_, _, **_| 5 }
    RateLimiter.singleton_class.send(:alias_method, :__reply,    :reply)
    RateLimiter.singleton_class.send(:define_method, :reply) { |_, _, **_| 'try in 5 min' }
    make_song(external_id: 'task-q', title: 'Q')
    result = call_tool({})
    assert result.is_a?(Agent::ToolResult)
    assert result.deferred?
    assert_equal 5, result.retry_in_min
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_wav_convert').count,
                 'rate-limit deferral must NOT enqueue a task'
  ensure
    RateLimiter.singleton_class.send(:alias_method, :exceeded?,         :__exceeded) rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__exceeded)                    rescue nil
    RateLimiter.singleton_class.send(:alias_method, :minutes_until_free,:__minutes)  rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__minutes)                     rescue nil
    RateLimiter.singleton_class.send(:alias_method, :reply,             :__reply)    rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__reply)                       rescue nil
  end
end

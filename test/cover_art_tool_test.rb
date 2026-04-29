require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Settings stubs the cover_art tool / handler ecosystem touches.
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
require_relative '../lib/agent/tools/cover_art'

# Tests for cover_art tool's source-song resolution chain:
#   1. explicit args['suno_task_id']
#   2. reply_to_message_id → Message.bg_task_external_id → BackgroundTask
#   3. most recent done song in chat (any suno_* type)
class CoverArtToolTest < BotTest
  CHAT = -1234567892

  def setup
    super
    @tool = Agent::ToolRegistry.find('cover_art')
    @user = OpenStruct.new(uid: 999, role: 'member')
  end

  def make_song(task_type: 'suno_generate', external_id:, title:)
    BackgroundTask.create!(task_type: task_type, chat_id: CHAT, max_attempts: 60,
                           status: 'done', external_id: external_id,
                           params: { title: title, user_uid: 1 }.to_json)
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
    assert_match(/Рисую обложку/, result)
    art = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').last
    assert_equal 'explicit-id-123', art.params_hash['source_task_id']
  end

  def test_reply_resolution_picks_song_via_bg_task_external_id
    older = make_song(external_id: 'old-task-id', title: 'Old Song')
    make_song(external_id: 'new-task-id', title: 'New Song') # would win without reply
    msg_id = 543210
    make_bot_audio_msg(message_id: msg_id,
                       body: '[песня: Old Song]',
                       bg_task_external_id: older.external_id)

    call_tool({ 'suno_task_id' => '' }, reply_to_message_id: msg_id)

    art = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').last
    assert_equal 'old-task-id', art.params_hash['source_task_id'],
                 'replying to older song must produce art for THAT song, not the most recent'
    assert_equal 'Old Song', art.params_hash['source_title']
  end

  def test_reply_resolution_falls_through_when_message_lacks_bg_task_id
    # Old bot rows from before the migration won't have bg_task_external_id.
    # Should fall through to "most recent done song" instead of failing.
    make_song(external_id: 'newest-id', title: 'Newest')
    legacy_msg_id = 543211
    make_bot_audio_msg(message_id: legacy_msg_id, body: '[песня: Legacy]',
                       bg_task_external_id: nil)

    call_tool({ 'suno_task_id' => '' }, reply_to_message_id: legacy_msg_id)

    art = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').last
    assert_equal 'newest-id', art.params_hash['source_task_id']
  end

  def test_no_reply_uses_most_recent_done_song
    make_song(external_id: 'oldest', title: 'O')
    make_song(external_id: 'middle',  title: 'M')
    make_song(external_id: 'newest',  title: 'N')
    call_tool({ 'suno_task_id' => '' })
    art = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').last
    assert_equal 'newest', art.params_hash['source_task_id']
  end

  def test_most_recent_includes_add_vocals_and_cover_audio
    # Earlier review finding: cover_art only resolved suno_generate sources.
    # All three song-producing types should be searchable.
    make_song(task_type: 'suno_generate',    external_id: 'gen-id',    title: 'G')
    make_song(task_type: 'suno_add_vocals',  external_id: 'vocals-id', title: 'V')
    make_song(task_type: 'suno_cover_audio', external_id: 'cover-id',  title: 'C')
    call_tool({ 'suno_task_id' => '' })
    art = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').last
    assert_equal 'cover-id', art.params_hash['source_task_id'],
                 'most recent across all song types should win'
  end

  def test_no_songs_in_chat_returns_deferred
    result = call_tool({ 'suno_task_id' => '' })
    assert_kind_of Agent::ToolResult, result
    assert result.deferred?
    assert_match(/ещё не пела/, result.user_text)
  end
end

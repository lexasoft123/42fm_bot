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
require_relative '../lib/agent/tools/cover_art'   # provides SONG_TASK_TYPES
require_relative '../lib/agent/tools/cover_audio'

# Tests for the cover_audio tool's source-lyrics resolution chain — the
# handler-side fallback that copies lyrics from a previously-generated
# bot Suno song when the user replies to it asking for a cover. Mirrors
# cover_art_tool_test's reply-target resolution pattern.
#
# Why this exists: the tool description tells the agent to copy original
# lyrics into `lyrics` when remaking a prior bot song, but the agent only
# sees lyrics that are still in the 50-msg chat-context window. For songs
# scrolled past that window, the agent leaves `lyrics` empty and the
# handler resolves via reply target → bg_task_external_id → source task.
class CoverAudioToolTest < BotTest
  CHAT = -1234567894

  def setup
    super
    @tool = Agent::ToolRegistry.find('cover_audio')
    @user = OpenStruct.new(uid: 999, role: 'member')
  end

  def make_song(task_type:, external_id:, title:, lyrics: nil, result: nil)
    params = { title: title, user_uid: 1 }
    params[:lyrics] = lyrics if lyrics
    BackgroundTask.create!(
      task_type: task_type, chat_id: CHAT, max_attempts: 60,
      status: 'done', external_id: external_id,
      params: params.to_json,
      result: result&.to_json
    )
  end

  def make_bot_audio_msg(message_id:, body:, bg_task_external_id: nil)
    Message.create!(role: 'bot', chat_id: CHAT, message_id: message_id, body: body,
                    bg_task_external_id: bg_task_external_id)
  end

  def call_tool(args, reply_to_message_id: nil)
    args = { 'upload_url' => 'https://example.com/source.mp3' }.merge(args)
    ctx = { chat_id: CHAT, user: @user, reply_to_message_id: reply_to_message_id }
    @tool.handler.call(args, ctx)
  end

  # compose_song path: the source task carries locally-composed lyrics in
  # params['lyrics']. Reply target → bg_task_external_id → those lyrics.
  def test_reply_to_compose_song_copies_params_lyrics_when_args_lyrics_empty
    make_song(task_type: 'suno_generate', external_id: 'src-task-1',
              title: 'Звёзды', lyrics: "[Verse 1]\nЗвёзды зажигают,\n[Chorus]\nДля кого-то нужно")
    msg_id = 71001
    make_bot_audio_msg(message_id: msg_id, body: '[песня: Звёзды]',
                       bg_task_external_id: 'src-task-1')

    call_tool({ 'style' => 'jazz', 'title' => 'Звёзды (jazz)' },
              reply_to_message_id: msg_id)

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_match(/\[Verse 1\]/, cover.params_hash['lyrics'])
    assert_match(/Для кого-то нужно/, cover.params_hash['lyrics'])
  end

  # add_vocals / cover_audio path: source's params['lyrics'] is nil — lyrics
  # come from Suno's response and live in result clips' :lyrics field.
  def test_reply_to_add_vocals_copies_clip_lyrics_when_params_lyrics_empty
    make_song(task_type: 'suno_add_vocals', external_id: 'src-task-2',
              title: 'Подпевка',
              result: [{ 'lyrics' => "[Chorus]\nSuno-echoed lyrics", 'audio_url' => 'x' },
                       { 'lyrics' => 'second clip',                  'audio_url' => 'y' }])
    msg_id = 71002
    make_bot_audio_msg(message_id: msg_id, body: '[песня: Подпевка]',
                       bg_task_external_id: 'src-task-2')

    call_tool({ 'style' => 'metal', 'title' => 'Подпевка (metal)' },
              reply_to_message_id: msg_id)

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_equal "[Chorus]\nSuno-echoed lyrics", cover.params_hash['lyrics']
  end

  # Explicit `lyrics` from the agent must always win over the auto-resolved
  # source — covers the "user wants to change a verse" use case.
  def test_explicit_lyrics_arg_wins_over_source_resolution
    make_song(task_type: 'suno_generate', external_id: 'src-task-3',
              title: 'Original', lyrics: 'original verses')
    msg_id = 71003
    make_bot_audio_msg(message_id: msg_id, body: '[песня: Original]',
                       bg_task_external_id: 'src-task-3')

    call_tool({ 'style' => 'punk', 'title' => 'Original (edit)',
                'lyrics' => "[Verse 1]\nedited verbatim text" },
              reply_to_message_id: msg_id)

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_match(/edited verbatim/, cover.params_hash['lyrics'])
    refute_match(/original verses/, cover.params_hash['lyrics'])
  end

  # No reply target → no resolution attempted, lyrics stays as args said
  # (empty here). Down-stream, `resolve_cover_prompt` will pick topic/title.
  def test_no_reply_target_leaves_lyrics_empty
    make_song(task_type: 'suno_generate', external_id: 'src-task-4',
              title: 'Untouched', lyrics: 'must not be reused')

    call_tool({ 'style' => 'ambient', 'title' => 'New', 'topic' => 'про закат' })

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_equal '', cover.params_hash['lyrics']
    assert_equal 'про закат', cover.params_hash['topic']
  end

  # Reply target points at a bot message with no bg_task_external_id (e.g.
  # a bot text reply, not a song). Resolution must skip cleanly without
  # crashing or polluting lyrics.
  def test_reply_to_non_song_bot_message_does_not_resolve_lyrics
    msg_id = 71005
    make_bot_audio_msg(message_id: msg_id, body: 'просто текст бота',
                       bg_task_external_id: nil)

    call_tool({ 'style' => 'jazz', 'title' => 'X' }, reply_to_message_id: msg_id)

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_equal '', cover.params_hash['lyrics']
  end

  # Source task whose `result` is malformed/non-Array JSON must not raise —
  # resolution falls through silently and lyrics stays empty. Guards
  # against schema drift in older rows.
  def test_malformed_source_result_does_not_crash_and_leaves_lyrics_empty
    BackgroundTask.create!(
      task_type: 'suno_cover_audio', chat_id: CHAT, max_attempts: 60,
      status: 'done', external_id: 'src-task-6',
      params: { title: 'Bad', user_uid: 1 }.to_json,
      result: 'not-json-at-all'
    )
    msg_id = 71006
    make_bot_audio_msg(message_id: msg_id, body: '[песня: Bad]',
                       bg_task_external_id: 'src-task-6')

    call_tool({ 'style' => 'jazz', 'title' => 'X' }, reply_to_message_id: msg_id)

    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last
    assert_equal '', cover.params_hash['lyrics']
  end
end

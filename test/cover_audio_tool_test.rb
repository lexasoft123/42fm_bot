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
require_relative '../lib/telegram_file'
require_relative '../lib/agent/tools/cover_art'   # provides SONG_TASK_TYPES
require_relative '../lib/agent/tools/cover_audio'
require_relative '../lib/agent/tools/add_vocals'

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
  # --- retry_of_task_id: re-run a failed cover with the same source ---

  def make_failed_cover(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'failed')
    BackgroundTask.create!(task_type: task_type, chat_id: chat_id, max_attempts: 60, status: status,
                           params: { upload_url: 'https://api.telegram.org/file/botX/music/file_1667.mp3',
                                     upload_file_id: 'FID-1667', style: 'rhythm and blues', title: 'Остаться собой',
                                     lyrics: "[Verse]\nСколько печальных историй", topic: '', instrumental: false,
                                     user_uid: 1 }.to_json)
  end

  def call_retry(args)
    ctx = { chat_id: CHAT, user: @user, reply_to_message_id: nil, audio: nil }
    @tool.handler.call(args, ctx)
  end

  def test_retry_of_failed_cover_copies_source_and_params
    src = make_failed_cover
    call_retry({ 'retry_of_task_id' => src.id, 'style' => '', 'title' => '', 'lyrics' => '', 'topic' => '', 'upload_url' => '' })
    cover = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').last
    p = cover.params_hash
    assert_equal 'https://api.telegram.org/file/botX/music/file_1667.mp3', p['upload_url']
    assert_equal 'FID-1667', p['upload_file_id'], 'file_id carried over so the handler can refresh the link'
    assert_equal 'rhythm and blues', p['style']
    assert_equal 'Остаться собой', p['title']
    assert_match(/Сколько печальных историй/, p['lyrics'])
    assert_equal src.id, p['retry_of_task_id']
  end

  def test_retry_explicit_args_override_source_params
    src = make_failed_cover
    call_retry({ 'retry_of_task_id' => src.id, 'style' => 'chicago blues', 'title' => '' })
    p = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').last.params_hash
    assert_equal 'chicago blues', p['style']
    assert_equal 'Остаться собой', p['title']
  end

  def test_retry_rejects_other_chat_non_failed_and_non_cover_tasks
    [make_failed_cover(chat_id: -999), make_failed_cover(status: 'done'),
     make_failed_cover(task_type: 'suno_add_vocals')].each do |src|
      result = call_retry({ 'retry_of_task_id' => src.id })
      assert_kind_of String, result
      assert_match(/повторять нечего/, result, "task #{src.id} (#{src.chat_id}/#{src.status}/#{src.task_type}) must be rejected")
    end
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').count
  end

  def test_attached_audio_file_id_is_saved_for_link_refresh
    TelegramFile.singleton_class.send(:alias_method, :__public_url_cov, :public_url)
    TelegramFile.singleton_class.send(:define_method, :public_url) { |_api, _fid, chat_id: nil| 'https://api.telegram.org/file/botX/a.mp3' }
    ctx = { chat_id: CHAT, user: @user, reply_to_message_id: nil, api: Object.new,
            audio: { file_id: 'NEW-FID', title: 'Демо' }, audio_source: :message }
    @tool.handler.call({ 'style' => 'jazz', 'title' => 'Демо (jazz)', 'upload_url' => '' }, ctx)
    p = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').last.params_hash
    assert_equal 'NEW-FID', p['upload_file_id']
    assert_equal 'https://api.telegram.org/file/botX/a.mp3', p['upload_url']
  ensure
    TelegramFile.singleton_class.send(:alias_method, :public_url, :__public_url_cov) rescue nil
    TelegramFile.singleton_class.send(:remove_method, :__public_url_cov) rescue nil
  end
  # Review #2: a failed task stays 'failed' forever — a second retry of the
  # same task (user "повтори" + a cron intention from a rate-limited retry)
  # must be refused, or Suno bills both.
  def test_second_retry_of_same_failed_task_is_refused_while_first_is_pending_or_done
    src = make_failed_cover
    call_retry({ 'retry_of_task_id' => src.id })
    first = BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').last
    refute_nil first

    result = call_retry({ 'retry_of_task_id' => src.id })
    assert_match(/уже в работе \(task ##{first.id}\)/, result)
    first.update_columns(status: 'done')
    result = call_retry({ 'retry_of_task_id' => src.id })
    assert_match(/уже сделан \(task ##{first.id}\)/, result)
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio').where.not(id: src.id).count
  end

  # Negative control: if the earlier retry itself failed, retrying again is fine.
  def test_retry_allowed_again_after_previous_retry_failed
    src = make_failed_cover
    call_retry({ 'retry_of_task_id' => src.id })
    BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').last.update_columns(status: 'failed')
    call_retry({ 'retry_of_task_id' => src.id })
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_audio', status: 'pending').count
  end

  def test_add_vocals_second_retry_of_same_failed_task_is_refused
    src = make_failed_cover(task_type: 'suno_add_vocals')
    tool = Agent::ToolRegistry.find('add_vocals')
    ctx = { chat_id: CHAT, user: @user, reply_to_message_id: nil, audio: nil }
    tool.handler.call({ 'retry_of_task_id' => src.id }, ctx)
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_add_vocals', status: 'pending').count
    result = tool.handler.call({ 'retry_of_task_id' => src.id }, ctx)
    assert_match(/уже в работе/, result)
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_add_vocals', status: 'pending').count
  end
end

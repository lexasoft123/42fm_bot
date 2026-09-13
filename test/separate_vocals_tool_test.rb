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
require_relative '../lib/agent/tools/cover_art' # provides SONG_TASK_TYPES
require_relative '../lib/agent/tools/separate_vocals'

# separate_vocals tool: mode mapping, stem_name validation, source resolved
# BEFORE the rate limit (so a deferral records which track), and the
# source-resolution chain (explicit suno_task_id → source_message_id → reply
# to bot song unless the message has its own attachment → upload_url →
# current/reply audio → on real user turns only, the newest fresh lookback
# upload vs latest same-topic bot song → defer).
class SeparateVocalsToolTest < BotTest
  CHAT = -1234567897
  TG_URL = 'https://api.telegram.org/file/botX:Y/music/file_9.mp3'.freeze

  def setup
    super
    @tool = Agent::ToolRegistry.find('separate_vocals')
    @user = OpenStruct.new(uid: 999, role: 'member')
    @public_url = TG_URL
    url = -> { @public_url }
    TelegramFile.singleton_class.send(:alias_method, :__public_url_sv, :public_url)
    TelegramFile.singleton_class.send(:define_method, :public_url) { |_api, _fid, chat_id: nil| url.call }
  end

  def teardown
    TelegramFile.singleton_class.send(:alias_method, :public_url, :__public_url_sv) rescue nil
    TelegramFile.singleton_class.send(:remove_method, :__public_url_sv) rescue nil
    super
  end

  def make_song(external_id:, title:, updated_at: Time.now, performer: '')
    t = BackgroundTask.create!(task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
                               status: 'done', external_id: external_id,
                               params: { title: title, artist: performer, user_uid: 1 }.to_json)
    t.update_columns(updated_at: updated_at)
    t
  end

  # A delivered bot song as the chat sees it: done task + the bot's media row.
  def make_song_row(external_id:, title:, minutes_ago:, message_id:, clip: 1, thread: nil)
    make_song(external_id: external_id, title: title)
    Message.create!(role: 'bot', chat_id: CHAT, message_id: message_id, message_thread_id: thread,
                    body: "[песня: #{title} (#{clip}/2)]", bg_task_external_id: external_id,
                    created_at: Time.now - minutes_ago * 60)
  end

  def audio(source:, age_min: nil, title: 'Демо', message_id: 77)
    { file_id: 'FILE1', mime_type: 'audio/mpeg', duration: 178, title: title,
      performer: nil, source: source, age_min: age_min, message_id: message_id }
  end

  def call_tool(args = {}, audio: nil, reply_to_message_id: nil, user_initiated: true, forum_thread_id: nil)
    ctx = { chat_id: CHAT, user: @user, api: Object.new, reply_to_message_id: reply_to_message_id,
            audio: audio, audio_source: audio && audio[:source],
            user_initiated: user_initiated, forum_thread_id: forum_thread_id }
    @tool.handler.call(args, ctx)
  end

  def with_rate_limited(minutes: 7)
    RateLimiter.singleton_class.send(:alias_method, :__exceeded_sv, :exceeded?)
    RateLimiter.singleton_class.send(:define_method, :exceeded?) { |_, _, **_| true }
    RateLimiter.singleton_class.send(:alias_method, :__minutes_sv, :minutes_until_free)
    RateLimiter.singleton_class.send(:define_method, :minutes_until_free) { |_, _, **_| minutes }
    RateLimiter.singleton_class.send(:alias_method, :__reply_sv, :reply)
    RateLimiter.singleton_class.send(:define_method, :reply) { |_, _, **_| 'wait' }
    yield
  ensure
    RateLimiter.singleton_class.send(:alias_method, :exceeded?, :__exceeded_sv) rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__exceeded_sv) rescue nil
    RateLimiter.singleton_class.send(:alias_method, :minutes_until_free, :__minutes_sv) rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__minutes_sv) rescue nil
    RateLimiter.singleton_class.send(:alias_method, :reply, :__reply_sv) rescue nil
    RateLimiter.singleton_class.send(:remove_method, :__reply_sv) rescue nil
  end

  def last_task
    BackgroundTask.where(chat_id: CHAT, task_type: 'suno_separate_vocals').last
  end

  def test_default_mode_separates_vocals_of_attached_audio
    result = call_tool({}, audio: audio(source: :message))
    assert_match(/вокал и минус/, result)
    p = last_task.params_hash
    assert_equal 'separate_vocal', p['type']
    assert_equal TG_URL, p['audio_url']
    assert_nil p['source_task_id']
    assert_equal 'Демо', p['source_title']
  end

  def test_modes_map_to_suno_types
    call_tool({ 'mode' => 'stems' }, audio: audio(source: :message))
    assert_equal 'split_stem', last_task.params_hash['type']
    call_tool({ 'mode' => 'instrument', 'stem_name' => 'drum kit' }, audio: audio(source: :message))
    assert_equal 'split_stem_advanced', last_task.params_hash['type']
    assert_equal 'Drum Kit', last_task.params_hash['stem_name'], 'stem_name is canonicalized to the Suno enum'
  end

  def test_unknown_mode_is_rejected_without_task
    result = call_tool({ 'mode' => 'karaoke' }, audio: audio(source: :message))
    assert_match(/Неизвестный mode/, result)
    assert_nil last_task
  end

  def test_instrument_mode_without_valid_stem_name_suggests_options
    result = call_tool({ 'mode' => 'instrument', 'stem_name' => 'drums' }, audio: audio(source: :message))
    assert_match(/Drum Kit/, result, 'close matches must be suggested')
    assert_nil last_task, 'no billed task for an invalid stem_name'
    result = call_tool({ 'mode' => 'instrument' }, audio: audio(source: :message))
    assert_match(/stem_name/, result)
    assert_nil last_task
  end

  # A reply to the bot's own song also carries that song's audio (source
  # :reply) — the Suno clip (taskId+audioId, exact clip) must win.
  def test_reply_to_bot_song_uses_suno_clip_over_reply_audio
    make_song(external_id: 'song-1', title: 'Хит', performer: 'Band')
    Message.create!(role: 'bot', chat_id: CHAT, message_id: 500, body: '[песня: Хит (2/2)]',
                    bg_task_external_id: 'song-1')
    call_tool({}, audio: audio(source: :reply), reply_to_message_id: 500)
    p = last_task.params_hash
    assert_equal 'song-1', p['source_task_id']
    assert_equal 2, p['clip_index'], 'clip index comes from the replied message body'
    assert_nil p['audio_url']
    assert_equal 'Хит', p['source_title']
    assert_equal 'Band', p['source_performer']
  end

  def test_clip_index_from_body_is_anchored_to_the_end
    assert_equal 2,   SeparateVocalsTool.clip_index_from_body('[песня: Хит (2/2)]')
    assert_equal 1,   SeparateVocalsTool.clip_index_from_body('[песня: Part (2/3) (1/2)]')
    assert_nil        SeparateVocalsTool.clip_index_from_body('[песня: Хит (1/2) live]')
    assert_nil        SeparateVocalsTool.clip_index_from_body('[песня: Хит]')
  end

  def test_explicit_suno_task_id_wins
    make_song(external_id: 'recent', title: 'Recent')
    call_tool({ 'suno_task_id' => 'explicit-1', 'clip_index' => 2 }, audio: audio(source: :message))
    p = last_task.params_hash
    assert_equal 'explicit-1', p['source_task_id']
    assert_equal 2, p['clip_index']
    assert_nil p['audio_url']
  end

  def test_upload_url_used_when_given
    call_tool({ 'upload_url' => 'https://example.com/track.mp3' })
    assert_equal 'https://example.com/track.mp3', last_task.params_hash['audio_url']
  end

  def test_fresh_lookback_audio_newer_than_last_song_is_used
    make_song_row(external_id: 'song-old', title: 'Song', minutes_ago: 20, message_id: 600)
    call_tool({}, audio: audio(source: :lookback, age_min: 5))
    assert_equal TG_URL, last_task.params_hash['audio_url']
  end

  def test_recent_bot_song_beats_older_lookback_audio
    make_song_row(external_id: 'song-new', title: 'Fresh Song', minutes_ago: 3, message_id: 601, clip: 2)
    call_tool({}, audio: audio(source: :lookback, age_min: 20))
    p = last_task.params_hash
    assert_equal 'song-new', p['source_task_id']
    assert_equal 2, p['clip_index'], 'implied song keeps the clip of its newest row'
    assert_nil p['audio_url']
  end

  # Prod 2026-08-24 / 09-04: stale sources got used silently. Separation is
  # billed per call, so nothing older than the lookback window is implied.
  def test_stale_bot_song_without_audio_defers_instead_of_billing
    make_song_row(external_id: 'song-stale', title: 'Old', minutes_ago: 45, message_id: 602)
    result = call_tool({})
    assert result.is_a?(Agent::ToolResult) && result.deferred?
    assert_nil last_task
  end

  # Review #3: the message's OWN attachment beats the song it replies to
  # (same priority as AudioAttachment).
  def test_attached_file_beats_reply_to_bot_song
    make_song_row(external_id: 'song-1', title: 'Хит', minutes_ago: 2, message_id: 500)
    call_tool({}, audio: audio(source: :message), reply_to_message_id: 500)
    p = last_task.params_hash
    assert_equal TG_URL, p['audio_url'], 'user attachment on this message must win'
    assert_nil p['source_task_id']
  end

  # Review #3: in a forum chat the implied song must come from the same topic.
  def test_implied_bot_song_is_scoped_to_forum_topic
    make_song_row(external_id: 'song-topic-a', title: 'A', minutes_ago: 2, message_id: 700, thread: 11)
    result = call_tool({}, forum_thread_id: 22)
    assert result.deferred?, 'a song from another topic must not be implied'
    assert_nil last_task
    call_tool({}, forum_thread_id: 11)
    assert_equal 'song-topic-a', last_task.params_hash['source_task_id']
  end

  # Review #2: cron/agent_event turns carry no audio/reply context — never
  # imply "latest song" there (it may not be what the user pointed at).
  def test_no_implied_source_on_non_user_turns
    make_song_row(external_id: 'song-new', title: 'Fresh', minutes_ago: 2, message_id: 603)
    result = call_tool({}, user_initiated: false)
    assert result.deferred?
    assert_nil last_task
  end

  # Review #2: a rate-limited call records WHICH track in the intent, so the
  # later retry re-selects it explicitly.
  def test_rate_limited_deferral_records_concrete_source_handle
    with_rate_limited do
      result = call_tool({ 'mode' => 'stems' }, audio: audio(source: :message, message_id: 4321))
      assert result.deferred?
      assert_equal 7, result.retry_in_min
      assert_match(/source_message_id=4321/, result.deferred_intent)
      assert_match(/mode=stems/, result.deferred_intent)
    end
    assert_nil last_task
  end

  def test_rate_limited_deferral_for_bot_song_records_task_and_clip
    make_song_row(external_id: 'song-9', title: 'Хит', minutes_ago: 1, message_id: 800, clip: 2)
    with_rate_limited do
      result = call_tool({}, reply_to_message_id: 800)
      assert_match(/suno_task_id=song-9/, result.deferred_intent)
      assert_match(/clip_index=2/, result.deferred_intent)
    end
  end

  def test_no_source_defers_even_when_rate_limited
    with_rate_limited do
      result = call_tool({})
      assert result.deferred?
      assert_nil result.retry_in_min, 'nothing to retry on a timer without a source'
    end
    assert_nil last_task
  end

  # The handle from a deferred intent re-selects the same upload on a
  # context-free (cron) turn, with no age bound.
  def test_source_message_id_resolves_user_upload_row_on_cron_turn
    Message.create!(role: 'user', chat_id: CHAT, message_id: 4321, body: '[аудио]',
                    attachment_file_id: 'UPLOAD', attachment_title: 'Демо Кати',
                    created_at: Time.now - 3 * 3600)
    call_tool({ 'source_message_id' => 4321 }, user_initiated: false)
    p = last_task.params_hash
    assert_equal TG_URL, p['audio_url']
    assert_equal 'Демо Кати', p['source_title']
  end

  def test_source_message_id_resolves_bot_song_row
    make_song_row(external_id: 'song-x', title: 'X', minutes_ago: 90, message_id: 900, clip: 2)
    call_tool({ 'source_message_id' => 900 }, user_initiated: false)
    p = last_task.params_hash
    assert_equal 'song-x', p['source_task_id']
    assert_equal 2, p['clip_index']
  end

  def test_unresolvable_telegram_file_reports_without_task
    @public_url = nil
    result = call_tool({}, audio: audio(source: :message))
    assert_match(/20 МБ/, result)
    assert_nil last_task
  end

  def test_all_params_optional_and_mode_enum_in_schema
    defn = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: 'anthropic')
                              .find { |d| d[:name] == 'separate_vocals' }
    assert_equal [], defn[:input_schema][:required], 'no param may be forced on the model'
    assert_equal %w[vocals stems instrument], defn[:input_schema][:properties]['mode'][:enum]
  end
end

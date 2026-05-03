require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/media_download'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/suno_client'
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

  def test_chain_proceeds_even_when_rate_limit_would_say_exhausted
    # The chain bypasses the 'suno' bucket on purpose: the parent suno_generate
    # row is itself counted in the bucket, so under default settings
    # (max=1, window=20min) the bucket is *always* exhausted by the time we
    # get here. Gating on it would silently drop the cover-art that the user
    # was already promised.
    RateLimiter.singleton_class.send(:alias_method, :__exceeded, :exceeded?)
    RateLimiter.singleton_class.send(:define_method, :exceeded?) { |_, _| true }

    task = make_song_task(with_cover_art: true)
    @handler.send(:maybe_chain_cover_art, task, task.params_hash, 'Тестовая')
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'suno_cover_art').count,
                 'chain must proceed regardless of bucket state'
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

  # --- resolve_delivery_lyrics: lyrics fallback for add_vocals/cover_audio ---

  # compose_song path: `params['lyrics']` is set locally at submit time and
  # wins over whatever Suno echoes back in the clip.
  def test_resolve_delivery_lyrics_prefers_params_when_present
    clips = [{ lyrics: 'suno-echoed' }]
    result = @handler.send(:resolve_delivery_lyrics, { 'lyrics' => 'composed locally' }, clips)
    assert_equal 'composed locally', result
  end

  # cover_audio / add_vocals path: no local lyrics → fall through to the
  # clip's `:lyrics` (mapped from Suno's response.sunoData[].prompt).
  def test_resolve_delivery_lyrics_falls_back_to_clip_when_params_empty
    clips = [{ lyrics: "[Verse] cover lyrics from suno" }]
    result = @handler.send(:resolve_delivery_lyrics, {}, clips)
    assert_equal "[Verse] cover lyrics from suno", result
  end

  # `params['lyrics']` of whitespace-only is treated as empty and falls
  # through — guards against an old retry path stashing a blank string.
  def test_resolve_delivery_lyrics_treats_whitespace_params_as_empty
    clips = [{ lyrics: 'real lyrics' }]
    result = @handler.send(:resolve_delivery_lyrics, { 'lyrics' => "   \n  " }, clips)
    assert_equal 'real lyrics', result
  end

  # If neither source has anything, return empty so the caller skips the
  # sendMessage call entirely (the lone caller has `return if lyrics.empty?`).
  def test_resolve_delivery_lyrics_returns_empty_when_neither_present
    assert_equal '', @handler.send(:resolve_delivery_lyrics, {}, [{ lyrics: nil }])
    assert_equal '', @handler.send(:resolve_delivery_lyrics, {}, [])
    assert_equal '', @handler.send(:resolve_delivery_lyrics, { 'lyrics' => '' }, nil)
  end

  # --- resolve_cover_prompt: lyrics-vs-topic → customMode mapping ---
  #
  # Bug context: pre-split, the cover_audio tool had one `prompt` field that
  # the agent was filling with style descriptions ("Hungarian prog-rock 80s"),
  # which Suno literally sang as lyrics under hardcoded customMode=true.
  # The split forces the agent to pick a lane: literal lyrics → custom; topic
  # for auto-gen → non-custom.

  def test_resolve_cover_prompt_uses_lyrics_in_custom_mode
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => "[Verse 1]\nNeon nights\nFading lights",
        'topic'  => 'про ночь' }) # both set — lyrics wins
    assert_equal true, custom
    assert_match(/\[Verse 1\]/, prompt)
  end

  def test_resolve_cover_prompt_uses_topic_in_auto_mode_when_no_lyrics
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => '', 'topic' => 'про усталого программиста', 'title' => 'X' })
    assert_equal false, custom
    assert_equal 'про усталого программиста', prompt
  end

  def test_resolve_cover_prompt_truncates_topic_to_500_chars
    long = 'а' * 800
    _, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => '', 'topic' => long })
    assert_equal 500, prompt.length
  end

  def test_resolve_cover_prompt_falls_back_to_title_when_both_empty
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => '', 'topic' => '', 'title' => 'Кавер от 42FM' })
    assert_equal false, custom
    assert_equal 'Кавер от 42FM', prompt
  end

  def test_resolve_cover_prompt_treats_whitespace_lyrics_as_empty
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => "   \n  ", 'topic' => 'тема' })
    assert_equal false, custom
    assert_equal 'тема', prompt
  end

  # Back-compat: legacy in-flight tasks created before the split have only
  # `prompt` (no lyrics/topic keys). Treat as topic — we no longer trust the
  # agent to put real lyrics there, and topic is the safer interpretation.
  def test_resolve_cover_prompt_legacy_prompt_treated_as_topic
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'prompt' => 'про закат', 'title' => 'Sunset' })
    assert_equal false, custom
    assert_equal 'про закат', prompt
  end

  # When lyrics/topic keys exist (post-split task) but are both empty, do NOT
  # fall back to a stray legacy `prompt` — the new schema is authoritative.
  # Otherwise an agent-driven empty would silently pick up an old field.
  def test_resolve_cover_prompt_ignores_legacy_prompt_when_split_keys_present
    _, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => '', 'topic' => '', 'prompt' => 'old style desc',
        'title' => 'New Title' })
    assert_equal 'New Title', prompt
  end

  # Suno V5 caps custom-mode prompt at ≤5000 chars. Long lyrics from a
  # paste-heavy agent (e.g. concatenated multi-song lyrics) must be
  # truncated rather than being rejected by Suno + burning retries.
  def test_resolve_cover_prompt_truncates_lyrics_to_5000_chars
    long_lyrics = '[Verse 1]' + 'а' * 10_000
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => long_lyrics, 'topic' => '' })
    assert_equal true, custom
    assert_equal 5000, prompt.length
  end

  # Tool description claims `lyrics`/`topic` are ignored when
  # `instrumental=true`. Handler must honor that contract: force
  # auto-mode + a sensible non-empty prompt (Suno still requires `prompt`
  # to exist; it just won't sing it under instrumental).
  def test_resolve_cover_prompt_instrumental_forces_auto_mode_and_uses_title
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'instrumental' => true,
        'lyrics' => "[Verse 1]\nshould be ignored",
        'topic'  => 'should also be ignored',
        'title'  => 'Minus Track' })
    assert_equal false, custom
    assert_equal 'Minus Track', prompt
  end

  def test_resolve_cover_prompt_instrumental_falls_back_when_title_empty
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'instrumental' => true, 'lyrics' => '', 'topic' => '', 'title' => '' })
    assert_equal false, custom
    assert_equal 'Кавер', prompt
  end

  # JSON-null pinning: an agent that emits {"lyrics": null, "topic": null}
  # parses to {'lyrics' => nil, 'topic' => nil}. `nil.to_s.strip == ""` so
  # both branches fall through to the title fallback (NOT to legacy prompt
  # — the gate `!key?('lyrics')` returns false because the key IS present
  # with value nil). This pins the desired behaviour.
  def test_resolve_cover_prompt_handles_json_null_lyrics_and_topic
    custom, prompt = @handler.send(:resolve_cover_prompt,
      { 'lyrics' => nil, 'topic' => nil, 'prompt' => 'legacy field',
        'title' => 'Fresh Title' })
    assert_equal false, custom
    assert_equal 'Fresh Title', prompt,
                 'must not silently fall back to legacy prompt when split keys are present-but-nil'
  end

  # End-to-end submit_cover_audio test: instrumental=true + lyrics='X' →
  # SunoClient receives custom_mode=false + prompt=title (NOT prompt=lyrics).
  # Pins the description-vs-handler contract from finding #2 of the post-hoc
  # code review of the lyrics/topic split.
  def test_submit_cover_audio_instrumental_overrides_lyrics_in_suno_payload
    captured = []
    suno_stub = Object.new
    suno_stub.define_singleton_method(:cover_audio) do |**kw|
      captured << kw
      'fake-suno-task-id'
    end
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    task = BackgroundTask.create!(
      task_type: 'suno_cover_audio', chat_id: CHAT, max_attempts: 60,
      params: { upload_url: 'https://example.com/in.mp3',
                style: 'jazz', title: 'Minus Track',
                lyrics: "[Verse 1]\nshould not be sung",
                topic: '', instrumental: true,
                user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:submit_cover_audio, task, api)

    kw = captured.last
    assert_equal false,         kw[:custom_mode], 'instrumental must force auto-mode'
    assert_equal 'Minus Track', kw[:prompt],     'instrumental must replace lyrics with title'
    assert_equal true,          kw[:instrumental]
    assert_equal 'jazz',        kw[:style]
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end
end

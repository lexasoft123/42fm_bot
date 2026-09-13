require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/media_download'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/gpt_master'
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

  # Suno (V5_5/V6) caps custom-mode prompt at ≤5000 chars. Long lyrics from a
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
                topic: '', instrumental: true, model: 'V6',
                user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:submit_cover_audio, task, api)

    kw = captured.last
    assert_equal false,         kw[:custom_mode], 'instrumental must force auto-mode'
    assert_equal 'Minus Track', kw[:prompt],     'instrumental must replace lyrics with title'
    assert_equal true,          kw[:instrumental]
    assert_equal 'jazz',        kw[:style]
    assert_equal 'V6',          kw[:model], 'the task\'s model reaches SunoClient'
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # Pins the regression that motivated the compose_song theme/lyrics split:
  # when params['lyrics'] is nil, compose_and_submit_generate must call
  # GptMaster.new(setting: 'lyrics') (the dedicated Sonnet composer). Pre-
  # split, the agent always inline-composed via the `agent` setting
  # (DeepSeek), bypassing the Sonnet upgrade entirely. We assert the
  # `setting:` kwarg by stubbing GptMaster.new and capturing it.
  # --- Error-detail propagation: Suno errorCode/errorMessage → agent ---
  #
  # Pre-fix, mark_failed_and_notify built the agent_event summary from
  # generic categorical reason ('suno_failed', 'wav_failed', ...) only —
  # the actual Suno error (e.g. "[413] Uploaded audio matches existing
  # work of art") was logged with WARN and discarded. The agent had to
  # guess copyright reject vs content flag vs worker hiccup. Now poll_*
  # methods return { failed: true, error: '<detail>' } and handlers thread
  # error_detail through to the summary.
  #
  # These tests pin the contract from the Suno API response down to the
  # agent_event params['summary'] string.

  # Stub api.sendMessage — mark_failed_and_notify sends a user-facing chat
  # message via api.sendMessage; tests don't need a real bot, just a
  # responder. Returns a minimal Response-shaped object so
  # Message.persist_bot_reply doesn't crash.
  def silent_api
    Class.new {
      def sendMessage(**); OpenStruct.new(result: OpenStruct.new(message_id: 999)); end
    }.new
  end

  def test_mark_failed_and_notify_appends_error_detail_to_agent_event_summary
    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      external_id: 'sun-task-failed',
      params: { topic: 'про любовь', genre: 'рок', artist: '', user_uid: 1 }.to_json
    )
    @handler.send(:mark_failed_and_notify, task, silent_api,
                  'suno_failed',
                  error_detail: 'Suno [413]: Uploaded audio matches existing work of art')

    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event, 'mark_failed_and_notify must emit agent_event'
    summary = event.params_hash['summary']
    assert_match(/Тема: про любовь/,                            summary)
    assert_match(/Причина: suno_failed/,                         summary)
    assert_match(/413/,                                          summary)
    assert_match(/Uploaded audio matches existing work of art/,  summary)
  end

  def test_mark_failed_and_notify_summary_omits_detail_block_when_nil
    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      external_id: 'sun-task-bare', params: { topic: 'X', genre: 'pop' }.to_json
    )
    @handler.send(:mark_failed_and_notify, task, silent_api, 'suno_failed')
    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    summary = event.params_hash['summary']
    refute_match(/\| Suno/, summary, 'must not append empty detail block when error_detail is nil')
  end

  # End-to-end through poll_and_deliver: feed a stubbed poll_once that
  # returns { failed: true, error: '...' } and assert the same detail
  # reaches the agent_event summary.
  def test_poll_and_deliver_propagates_failure_hash_detail_to_agent_event
    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      external_id: 'sun-task-e2e',
      params: { topic: 'про шефа', genre: 'pop', artist: '', user_uid: 1 }.to_json
    )

    suno_stub = Object.new
    suno_stub.define_singleton_method(:poll_once) { |_id|
      { failed: true, error: 'Suno [413]: Copyright reject' }
    }
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    @handler.send(:poll_and_deliver, task, silent_api)

    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event
    assert_match(/Copyright reject/, event.params_hash['summary'])
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # Combined-call refactor: when params['lyrics'] is empty, the handler now
  # makes ONE Sonnet call (purpose: 'suno_compose') that returns both lyrics
  # and tags in <lyrics>...</lyrics><tags>...</tags> XML blocks. Setting is
  # still 'lyrics' (Anthropic Sonnet 4.6).
  def test_compose_and_submit_generate_uses_lyrics_setting_when_lyrics_empty
    Settings.singleton_class.send(:define_method, :suno) {
      { 'lyrics_prompt' => 'Compose: {REQUEST} | {GENRE} | {ARTIST} | {CONTEXT} | {KNOWLEDGE}' }
    } unless Settings.respond_to?(:suno)

    captured_settings = []
    fake_gpt = Object.new
    fake_gpt.define_singleton_method(:call) {
      "<lyrics>\n[Verse]\nfake composed lyrics\n[Chorus]\nfor test\n</lyrics>\n\n<tags>\njazz, smooth, mellow, late night, lo-fi, brushed drums, upright bass, soft piano\n</tags>"
    }
    GptMaster.singleton_class.send(:alias_method, :__new, :new)
    GptMaster.singleton_class.send(:define_method, :new) do |_msgs, **opts|
      captured_settings << opts[:setting]
      fake_gpt
    end

    suno_stub = Object.new
    suno_stub.define_singleton_method(:submit) { |**_| 'fake-suno-id' }
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      params: { title: 'Test', lyrics: nil,
                topic: 'про шефа', genre: 'поп', user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:compose_and_submit_generate, task, api)

    assert_includes captured_settings, 'lyrics',
                    "expected GptMaster.new(setting: 'lyrics') for Sonnet composition; got #{captured_settings.inspect}"
  ensure
    GptMaster.singleton_class.send(:alias_method, :new, :__new)  rescue nil
    GptMaster.singleton_class.send(:remove_method, :__new)       rescue nil
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # Regression for prod task 1360 (2026-05-18): agent submitted a Suno gen
  # with empty `artist` and 8 generic NDH tags. The old enrichment heuristic
  # only fired when artist was non-empty / tags were <=3 / tags matched
  # GENRES.values exactly — none of those applied, so enrichment was skipped
  # and the agent's generic tags went straight to Suno. New contract: handler
  # ALWAYS runs the dedicated LLM call. With the combined refactor, the
  # lyrics-empty path uses purpose:'suno_compose' (one call producing both
  # lyrics and tags). This test pins that — tags is NOT in params, artist is
  # empty, yet GptMaster.new(purpose: 'suno_compose') still gets called.
  def test_compose_and_submit_generate_always_runs_tag_enrichment
    Settings.singleton_class.send(:define_method, :suno) {
      { 'lyrics_prompt' => 'Compose: {REQUEST} | {GENRE} | {ARTIST} | {CONTEXT} | {KNOWLEDGE}' }
    } unless Settings.respond_to?(:suno)

    fake_gpt = Object.new
    fake_gpt.define_singleton_method(:call) {
      "<lyrics>\n[Verse]\ntest\n</lyrics>\n<tags>\nindustrial metal, theatrical, mid-tempo stomp, heavy riffs, German vocals, dark, powerful, glossy production\n</tags>"
    }
    captured_purposes = []
    GptMaster.singleton_class.send(:alias_method, :__new, :new)
    GptMaster.singleton_class.send(:define_method, :new) do |_msgs, **opts|
      captured_purposes << opts[:purpose]
      fake_gpt
    end

    suno_stub = Object.new
    suno_stub.define_singleton_method(:submit) { |**_| 'fake-suno-id' }
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      params: { title: 'Weiße Birke', lyrics: nil, topic: 'про березу',
                genre: 'industrial metal', artist: '', user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:compose_and_submit_generate, task, api)

    assert_includes captured_purposes, 'suno_compose',
                    'combined-call composition must always run regardless of artist/tags state'
  ensure
    GptMaster.singleton_class.send(:alias_method, :new, :__new)  rescue nil
    GptMaster.singleton_class.send(:remove_method, :__new)       rescue nil
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # User-supplied lyrics path: when params['lyrics'] is non-empty (verbatim
  # text from the user), the handler SKIPS the combined call and falls back
  # to the tags-only LLM call (purpose: 'suno_tags'). Pins that branch.
  def test_compose_and_submit_generate_uses_tags_only_when_lyrics_provided
    Settings.singleton_class.send(:define_method, :suno) {
      { 'lyrics_prompt' => 'should-not-be-used' }
    } unless Settings.respond_to?(:suno)

    captured_purposes = []
    fake_gpt = Object.new
    fake_gpt.define_singleton_method(:call) { 'jazz, smooth, brushed drums' }
    GptMaster.singleton_class.send(:alias_method, :__new, :new)
    GptMaster.singleton_class.send(:define_method, :new) do |_msgs, **opts|
      captured_purposes << opts[:purpose]
      fake_gpt
    end

    suno_stub = Object.new
    suno_stub.define_singleton_method(:submit) { |**_| 'fake-suno-id' }
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      params: { title: 'Verbatim', lyrics: "[Verse]\nUser-supplied lyrics here\n[Outro]\nThe end",
                topic: '', genre: 'джаз', artist: '', user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:compose_and_submit_generate, task, api)

    assert_includes    captured_purposes, 'suno_tags',
                       'verbatim-lyrics path must fall back to tags-only LLM call'
    refute_includes captured_purposes, 'suno_compose',
                       'verbatim-lyrics path must NOT invoke the combined call'
  ensure
    GptMaster.singleton_class.send(:alias_method, :new, :__new)  rescue nil
    GptMaster.singleton_class.send(:remove_method, :__new)       rescue nil
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # Malformed combined response (missing <lyrics> or <tags> block) must
  # raise, so compose_and_submit_generate's bail_or_retry kicks in via the
  # prompt_failures counter — same retry path the lyrics-only call had.
  def test_compose_lyrics_and_tags_raises_on_missing_xml_blocks
    Settings.singleton_class.send(:define_method, :suno) {
      { 'lyrics_prompt' => 'Compose: {REQUEST} | {GENRE} | {ARTIST} | {CONTEXT} | {KNOWLEDGE}' }
    } unless Settings.respond_to?(:suno)

    fake_gpt = Object.new
    fake_gpt.define_singleton_method(:call) { '<lyrics>only lyrics, no tags block</lyrics>' }
    GptMaster.singleton_class.send(:alias_method, :__new, :new)
    GptMaster.singleton_class.send(:define_method, :new) { |_msgs, **_| fake_gpt }

    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      params: { title: 'Test', lyrics: nil, topic: 'про осень',
                genre: 'рок', artist: '', user_uid: 1 }.to_json
    )

    err = assert_raises(RuntimeError) do
      @handler.send(:compose_lyrics_and_tags, task.params_hash, task,
                    genre: 'рок', artist: '', title: 'Test')
    end
    assert_match(/missing <tags> block/, err.message)
  ensure
    GptMaster.singleton_class.send(:alias_method, :new, :__new) rescue nil
    GptMaster.singleton_class.send(:remove_method, :__new)      rescue nil
  end

  # Pins the end-to-end thread of `negative_tags` from BackgroundTask.params
  # (written by compose_song agent tool) → SunoClient#submit kwarg → Suno's
  # `negativeTags` POST field. Regression guard for the post-review fix that
  # moved negatives out of TAGS_PROMPT's inline ladder into a structured
  # channel.
  def test_compose_and_submit_generate_threads_negative_tags_to_suno_submit
    Settings.singleton_class.send(:define_method, :suno) {
      { 'lyrics_prompt' => 'Compose: {REQUEST} | {GENRE} | {ARTIST} | {CONTEXT} | {KNOWLEDGE}' }
    } unless Settings.respond_to?(:suno)

    fake_gpt = Object.new
    fake_gpt.define_singleton_method(:call) {
      "<lyrics>\n[Verse]\nfake\n[Chorus]\nfake\n</lyrics>\n<tags>\nrock, anthemic, mid-tempo, distorted guitars, male vocals, dark, powerful, glossy\n</tags>"
    }
    GptMaster.singleton_class.send(:alias_method, :__new, :new)
    GptMaster.singleton_class.send(:define_method, :new) { |_msgs, **_opts| fake_gpt }

    captured = []
    suno_stub = Object.new
    suno_stub.define_singleton_method(:submit) { |**kw| captured << kw; 'fake-suno-id' }
    SunoClient.singleton_class.send(:alias_method, :__new, :new)
    SunoClient.singleton_class.send(:define_method, :new) { suno_stub }

    task = BackgroundTask.create!(
      task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
      # `tags` deliberately omitted from params — the agent's compose_song
      # tool no longer supplies it; handler regenerates via the combined call.
      # The fake_gpt stub above returns XML-shaped output so the parser is happy.
      params: { negative_tags: 'female vocals, slow tempo',
                title: 'Test', lyrics: nil, topic: 'про шефа',
                genre: 'рок', user_uid: 1 }.to_json
    )
    api = OpenStruct.new
    @handler.send(:compose_and_submit_generate, task, api)

    assert_equal 'female vocals, slow tempo', captured.last[:negative_tags],
                 'compose_and_submit_generate must thread params.negative_tags into SunoClient#submit'
  ensure
    GptMaster.singleton_class.send(:alias_method, :new, :__new)  rescue nil
    GptMaster.singleton_class.send(:remove_method, :__new)       rescue nil
    SunoClient.singleton_class.send(:alias_method, :new, :__new) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new)      rescue nil
  end
  # --- Permanent submit rejections (SunoClient#submit_error renders 400/401/
  # 404/413/429 bare) must fail in the handler with an agent_event — NOT be
  # re-raised into TaskRunner, whose permanent regex would post a raw
  # "Ошибка: …" and skip the agent_event (prod add-vocals 1044/1246/3789).

  def with_raising_client(method, message)
    stub = Object.new
    stub.define_singleton_method(method) { |**_| raise message }
    SunoClient.singleton_class.send(:alias_method, :__new_perm, :new)
    SunoClient.singleton_class.send(:define_method, :new) { stub }
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_perm) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_perm) rescue nil
  end

  def make_add_vocals_task
    BackgroundTask.create!(task_type: 'suno_add_vocals', chat_id: CHAT, max_attempts: 60,
                           params: { upload_url: 'https://example.com/in.mp3', theme: 'про море',
                                     title: 'Море', style: 'soul', user_uid: 1 }.to_json)
  end

  def test_permanent_submit_rejection_fails_now_with_agent_event
    task = make_add_vocals_task
    msg = 'Suno /api/v1/generate/add-vocals failed: 400 No taskId in response: negativeTags is required'
    result = with_raising_client(:add_vocals, msg) { @handler.send(:submit_add_vocals, task, silent_api) }
    assert_equal :failed, result
    fresh = BackgroundTask.find(task.id)
    assert_equal 'failed', fresh.status
    assert_equal 'submit_rejected', fresh.result_hash['error']
    event = BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last
    refute_nil event, 'permanent rejection must emit agent_event'
    assert_match(/negativeTags is required/, event.params_hash['summary'])
  end

  # Negative control: a retryable code keeps the old re-raise + counter path.
  def test_retryable_submit_error_still_reraises_and_counts
    task = make_add_vocals_task
    msg = 'Suno /api/v1/generate/add-vocals failed: code=430 call frequency too high'
    assert_raises(RuntimeError) do
      with_raising_client(:add_vocals, msg) { @handler.send(:submit_add_vocals, task, silent_api) }
    end
    fresh = BackgroundTask.find(task.id)
    assert_equal 'pending', fresh.status
    assert_equal 1, fresh.params_hash['submit_failures']
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
  end
  # --- Generation failures are task-type aware (prod 2026-07-20..09-13) ---

  class NoticeApi
    attr_reader :texts
    def initialize; @texts = []; end
    def sendMessage(chat_id:, text:); @texts << text; OpenStruct.new(result: OpenStruct.new(message_id: 999)); end
  end

  def with_poll(result)
    stub = Object.new
    stub.define_singleton_method(:poll_once) { |_id| result }
    SunoClient.singleton_class.send(:alias_method, :__new_gen, :new)
    SunoClient.singleton_class.send(:define_method, :new) { stub }
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_gen) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_gen) rescue nil
  end

  def make_polling_task(type, **params)
    BackgroundTask.create!(task_type: type, chat_id: CHAT, max_attempts: 60, external_id: 'suno-job-1',
                           attempts: 42, params: { title: 'Остаться собой', user_uid: 1 }.merge(params).to_json)
  end

  GEN_FAIL = { generation_failed: true, error: 'Suno: GENERATE_AUDIO_FAILED' }.freeze

  def last_event
    BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').last&.params_hash
  end

  def test_cover_generation_failure_fails_now_without_resubmit
    task = make_polling_task('suno_cover_audio', style: 'rhythm and blues', topic: 'про себя', lyrics: '')
    api = NoticeApi.new
    result = with_poll(GEN_FAIL) { @handler.send(:poll_and_deliver, task, api) }
    assert_equal :failed, result
    fresh = BackgroundTask.find(task.id)
    assert_equal 'failed', fresh.status
    assert_equal 'suno_source_rejected', fresh.result_hash['error']
    assert_nil fresh.params_hash['generation_retries'], 'an uploaded source is never blind-resubmitted'
    assert_equal ['Не удалось сделать кавер'], api.texts
    ev = last_event
    assert_equal 'cover_failed', ev['event_type']
    assert_match(/Кавер «Остаться собой» \(task ##{task.id}, режим auto/, ev['summary'])
    assert_match(/Стиль: rhythm and blues/, ev['summary'])
    assert_match(/GENERATE_AUDIO_FAILED/, ev['summary'])
  end

  def test_add_vocals_generation_failure_uses_its_own_notice_and_event
    task = make_polling_task('suno_add_vocals', theme: 'про море', style: 'soul')
    api = NoticeApi.new
    with_poll(GEN_FAIL) { @handler.send(:poll_and_deliver, task, api) }
    assert_equal ['Не удалось добавить вокал'], api.texts
    assert_equal 'add_vocals_failed', last_event['event_type']
  end

  # Negative control: a song composed from scratch still resubmits — with or
  # without a reason from Suno — and each fresh job gets a fresh poll budget.
  def test_song_generation_failure_resubmits_with_fresh_poll_budget
    task = make_polling_task('suno_generate', topic: 'про шефа', genre: 'pop', artist: '')
    [GEN_FAIL, { generation_failed: true, error: 'Suno [500]: worker crashed' }].each do |failure|
      result = with_poll(failure) { @handler.send(:poll_and_deliver, BackgroundTask.find(task.id), silent_api) }
      assert_equal :pending, result
    end
    fresh = BackgroundTask.find(task.id)
    assert_nil fresh.external_id, 'external_id cleared so the next call resubmits'
    assert_equal 2, fresh.params_hash['generation_retries']
    assert_equal 0, fresh.attempts, 'resubmit resets the poll budget (prod task 3715 timed out mid-resubmit)'
    assert_nil last_event
  end

  def test_song_generation_failure_at_cap_fails_with_detail
    task = make_polling_task('suno_generate', topic: 'про шефа', generation_retries: SunoTaskHandler::MAX_GENERATION_RETRIES)
    with_poll({ generation_failed: true, error: 'Suno [500]: worker crashed' }) do
      @handler.send(:poll_and_deliver, task, silent_api)
    end
    ev = last_event
    assert_equal 'song_failed_after_retries', ev['event_type']
    assert_match(/worker crashed/, ev['summary'])
  end

  # :retry (SUCCESS without clips) is a different glitch — resubmits even for covers.
  def test_empty_success_retry_resubmits_uploads_too
    task = make_polling_task('suno_cover_audio', style: 'jazz')
    assert_equal :pending, with_poll(:retry) { @handler.send(:poll_and_deliver, task, silent_api) }
    assert_nil BackgroundTask.find(task.id).external_id
  end

  # Driven through TaskRunner#process_one: a resubmit near the attempt cap
  # must not time the task out.
  def test_resubmit_near_attempt_cap_survives_task_runner_accounting
    task = make_polling_task('suno_generate', topic: 'x')
    task.update_columns(attempts: 59, max_attempts: 60)
    runner = TaskRunner.new(silent_api)
    with_poll(GEN_FAIL) { runner.process_one(BackgroundTask.find(task.id)) }
    fresh = BackgroundTask.find(task.id)
    assert_equal 'pending', fresh.status, 'the fresh job must get its own poll budget, not inherit 59/60'
    assert_equal 1, fresh.attempts
  end

  def test_song_summary_topic_falls_back_past_empty_strings
    task = BackgroundTask.create!(task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60,
                                  params: { topic: '', request: nil, title: 'Про кота', genre: 'rock' }.to_json)
    @handler.send(:mark_failed_and_notify, task, silent_api, 'suno_failed')
    assert_match(/Тема: Про кота/, last_event['summary'])
  end

  def test_fresh_upload_url_prefers_file_id_and_falls_back
    TelegramFile.singleton_class.send(:alias_method, :__public_url_fresh, :public_url)
    returned = 'https://api.telegram.org/file/botX/music/new.mp3'
    TelegramFile.singleton_class.send(:define_method, :public_url) { |_api, _fid, chat_id: nil| returned }
    task = make_polling_task('suno_cover_audio', upload_url: 'https://old/expired.mp3', upload_file_id: 'FID')
    assert_equal 'https://api.telegram.org/file/botX/music/new.mp3', @handler.send(:fresh_upload_url, task, nil, task.params_hash)
    returned = nil
    assert_equal 'https://old/expired.mp3', @handler.send(:fresh_upload_url, task, nil, task.params_hash)
    legacy = make_polling_task('suno_cover_audio', upload_url: 'https://agent/link.mp3')
    assert_equal 'https://agent/link.mp3', @handler.send(:fresh_upload_url, legacy, nil, legacy.params_hash)
  ensure
    TelegramFile.singleton_class.send(:alias_method, :public_url, :__public_url_fresh) rescue nil
    TelegramFile.singleton_class.send(:remove_method, :__public_url_fresh) rescue nil
  end
end

require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Stub Settings for SunoClient — it reads api_url/api_key/model at init.
unless Settings.respond_to?(:suno)
  Settings.singleton_class.send(:define_method, :suno) {
    { 'api_url' => 'https://api.sunoapi.org', 'api_key' => 'test-key', 'model' => 'V5' }
  }
end

require_relative '../lib/suno_client'

# Tests for the three new SunoClient submit methods. We don't hit the
# network — HTTParty.post is stubbed to return a canned 200 response.
class SunoClientTest < Minitest::Test
  class FakeResponse
    def initialize(code:, body:); @code = code; @body = body; end
    attr_reader :code
    def body; @body.is_a?(String) ? @body : @body.to_json; end
    def parsed_response; @body.is_a?(String) ? JSON.parse(@body) : @body; end
  end

  def with_stubbed_post(captured: [], code: 200, body: { 'data' => { 'taskId' => 'fake-task-1' } })
    HTTParty.singleton_class.send(:alias_method, :__post, :post)
    HTTParty.singleton_class.send(:define_method, :post) do |url, opts|
      captured << { url: url, body: JSON.parse(opts[:body]), headers: opts[:headers] }
      FakeResponse.new(code: code, body: body)
    end
    yield
  ensure
    HTTParty.singleton_class.send(:alias_method, :post, :__post)
    HTTParty.singleton_class.send(:remove_method, :__post)
  end

  def test_add_vocals_posts_to_correct_endpoint_with_required_fields
    captured = []
    task_id = with_stubbed_post(captured: captured) do
      SunoClient.new.add_vocals(
        upload_url: 'https://example.com/in.mp3',
        prompt: 'sad song', title: 'Sad', style: 'jazz, melancholic',
        negative_tags: 'aggressive', vocal_gender: 'f'
      )
    end
    assert_equal 'fake-task-1', task_id
    req = captured.last
    assert_match %r{/api/v1/generate/add-vocals\z}, req[:url]
    assert_equal 'https://example.com/in.mp3', req[:body]['uploadUrl']
    assert_equal 'sad song', req[:body]['prompt']
    assert_equal 'Sad', req[:body]['title']
    assert_equal 'jazz, melancholic', req[:body]['style']
    assert_equal 'aggressive', req[:body]['negativeTags']
    assert_equal 'f', req[:body]['vocalGender']
    assert_equal 'V5', req[:body]['model']
    assert_equal 'https://example.com/noop', req[:body]['callBackUrl']
  end

  # Custom mode (literal-lyrics path): user gave verbatim text → Suno sings
  # it as-is. Caller is responsible for choosing custom_mode=true; SunoClient
  # is a thin pass-through.
  def test_cover_audio_custom_mode_true_passes_prompt_as_lyrics
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'synthwave', title: 'Retro',
        prompt: "[Verse 1]\nNeon nights\nFading lights",
        custom_mode: true
      )
    end
    req = captured.last
    assert_match %r{/api/v1/generate/upload-cover\z}, req[:url]
    assert_equal true,  req[:body]['customMode']
    assert_equal false, req[:body]['instrumental']
    assert_equal 'synthwave', req[:body]['style']
    assert_equal 'Retro', req[:body]['title']
    assert_match(/\[Verse 1\]/, req[:body]['prompt'])
  end

  # Auto mode (topic path): user gave a theme but no actual lyrics → Suno
  # auto-generates fresh lyrics from the topic. The bug this guards: agent
  # used to pass style descriptions in `prompt` with hardcoded customMode=true,
  # so Suno literally sang "Hungarian prog-rock 80s" as the chorus. Now the
  # tool→handler path picks customMode=false for topic input.
  def test_cover_audio_custom_mode_false_passes_prompt_as_topic
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'synthwave', title: 'Retro',
        prompt: 'про ночной город', custom_mode: false
      )
    end
    assert_equal false, captured.last[:body]['customMode']
    assert_equal 'про ночной город', captured.last[:body]['prompt']
  end

  # Instrumental cover: `instrumental: true` skips vocals regardless of mode;
  # pre-existing regression guard for the "переделай чтоб был минус" path.
  def test_cover_audio_passes_instrumental_true_to_api
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'instrumental, ambient', title: 'Minus',
        prompt: 'ambient instrumental', custom_mode: false,
        instrumental: true
      )
    end
    assert_equal true, captured.last[:body]['instrumental']
  end

  # vocal_gender is meaningless when there's no vocal; drop it to avoid
  # confusing Suno's pipeline.
  def test_cover_audio_omits_vocal_gender_when_instrumental
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'instrumental', title: 'Minus',
        prompt: 'mood ambient', custom_mode: false,
        instrumental: true, vocal_gender: 'm'
      )
    end
    refute captured.last[:body].key?('vocalGender'),
           'vocalGender must not be sent when instrumental=true'
  end

  def test_cover_art_posts_with_just_task_id
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_art(suno_task_id: 'sun-task-XYZ')
    end
    req = captured.last
    assert_match %r{/api/v1/suno/cover/generate\z}, req[:url]
    assert_equal 'sun-task-XYZ', req[:body]['taskId']
    assert_equal 'https://example.com/noop', req[:body]['callBackUrl']
  end

  def test_add_vocals_omits_vocal_gender_when_nil
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.add_vocals(
        upload_url: 'https://example.com/in.mp3',
        prompt: 'x', title: 'x', style: 'x'
      )
    end
    refute_includes captured.last[:body].keys, 'vocalGender'
  end

  def test_post_raises_on_non_200
    err = assert_raises(RuntimeError) do
      with_stubbed_post(code: 500, body: 'oops') do
        SunoClient.new.cover_art(suno_task_id: 'x')
      end
    end
    assert_match(/Suno .* failed: 500/, err.message)
  end

  def test_post_raises_when_task_id_missing
    err = assert_raises(RuntimeError) do
      with_stubbed_post(body: { 'data' => {} }) do
        SunoClient.new.cover_art(suno_task_id: 'x')
      end
    end
    assert_match(/No taskId/, err.message)
  end

  def with_stubbed_get(captured: [], code: 200, body: {})
    HTTParty.singleton_class.send(:alias_method, :__get, :get)
    HTTParty.singleton_class.send(:define_method, :get) do |url, opts|
      captured << { url: url, query: opts[:query] }
      FakeResponse.new(code: code, body: body)
    end
    yield
  ensure
    HTTParty.singleton_class.send(:alias_method, :get, :__get)
    HTTParty.singleton_class.send(:remove_method, :__get)
  end

  def test_poll_cover_art_once_uses_dedicated_cover_endpoint
    captured = []
    with_stubbed_get(captured: captured, body: { 'data' => { 'successFlag' => 2 } }) do
      SunoClient.new.poll_cover_art_once('any-id')
    end
    assert_match %r{/api/v1/suno/cover/record-info\z}, captured.last[:url],
                 'cover-art uses /api/v1/suno/cover/record-info, not /api/v1/generate/record-info'
    assert_equal 'any-id', captured.last[:query][:taskId]
  end

  def test_poll_cover_art_once_extracts_image_urls_on_success_flag_1
    images = ['https://cdn/cover-1.png', 'https://cdn/cover-2.png']
    body = { 'data' => { 'successFlag' => 1,
                         'response' => { 'images' => images } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_cover_art_once('any-id') }
    assert_kind_of Array, result
    assert_equal 2, result.size
    assert_equal images.first, result.first[:image_url]
  end

  def test_poll_cover_art_once_returns_pending_when_in_progress
    # successFlag=2, no images yet, no error fields — still working.
    body = { 'data' => { 'successFlag' => 2, 'response' => nil,
                         'errorCode' => nil, 'errorMessage' => nil } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_cover_art_once('any-id') }
    assert_equal :pending, result
  end

  # Failure with detail: poll_* methods return { failed: true, error: '...' }
  # so the handler can thread the Suno-reported reason into the agent_event
  # summary. Bare `:failed` symbol is reserved for paths with no detail.

  def test_poll_cover_art_once_returns_failure_hash_with_detail_on_error_code
    body = { 'data' => { 'successFlag' => 2, 'response' => nil,
                         'errorCode' => 405, 'errorMessage' => 'rate limited' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_cover_art_once('any-id') }
    assert_kind_of Hash, result
    assert_equal true, result[:failed]
    assert_match(/405/,         result[:error])
    assert_match(/rate limited/, result[:error])
  end

  def test_poll_cover_art_once_returns_failure_hash_with_detail_on_error_message_only
    body = { 'data' => { 'successFlag' => 2, 'response' => nil,
                         'errorCode' => 0, 'errorMessage' => 'sensitive content' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_cover_art_once('any-id') }
    assert_equal true, result[:failed]
    assert_match(/sensitive content/, result[:error])
  end

  def test_poll_cover_art_once_treats_zero_errorcode_as_not_an_error
    body = { 'data' => { 'successFlag' => 2, 'response' => nil,
                         'errorCode' => 0, 'errorMessage' => '' } }
    assert_equal :pending,
                 with_stubbed_get(body: body) { SunoClient.new.poll_cover_art_once('any-id') }
  end

  # poll_once (song endpoint): mirror of cover-art error-field handling.
  # Suno can leave status='PENDING' for minutes while errorCode/errorMessage
  # already report a permanent rejection (e.g. uploaded audio matched a
  # copyrighted work — error 413). Detect early instead of polling out.

  def test_poll_once_returns_pending_for_unknown_status_with_no_error
    body = { 'data' => { 'status' => 'PENDING',
                         'errorCode' => nil, 'errorMessage' => nil } }
    assert_equal :pending,
                 with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
  end

  def test_poll_once_returns_failure_hash_with_detail_when_pending_status_carries_error_code
    body = { 'data' => { 'status' => 'PENDING',
                         'errorCode' => 413,
                         'errorMessage' => 'Uploaded audio matches existing work of art' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_equal true, result[:failed]
    # Real prod failure mode: copyright reject. The detail must reach the
    # agent so it can suggest the user pick a different source rather than
    # blind-retry.
    assert_match(/413/,                                       result[:error])
    assert_match(/Uploaded audio matches existing work of art/, result[:error])
  end

  def test_poll_once_returns_failure_hash_with_detail_when_pending_status_carries_error_message_only
    body = { 'data' => { 'status' => 'PENDING',
                         'errorCode' => 0, 'errorMessage' => 'copyright violation' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_equal true, result[:failed]
    assert_match(/copyright violation/, result[:error])
  end

  # SENSITIVE_WORD_ERROR is a permanent reject — return a failure hash with a
  # static, agent-actionable detail. Pre-detail era this returned bare :failed
  # so the agent never knew it was a content-flag (vs network hiccup, etc.).
  def test_poll_once_returns_failure_hash_for_sensitive_word_error
    body = { 'data' => { 'status' => 'SENSITIVE_WORD_ERROR' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_equal true, result[:failed]
    assert_match(/SENSITIVE_WORD_ERROR|чувствительн/, result[:error])
  end

  # SECURITY: Suno's errorMessage on certain 4xx paths can echo the input
  # URL back. For cover_audio/add_vocals that URL is the Telegram file URL
  # containing the bot token (`api.telegram.org/file/bot<id>:<token>/...`).
  # The detail flows into agent_event summary (DB-persisted, LLM-context),
  # so a leaked token has wide blast radius. format_suno_error must strip
  # URLs before composing.
  def test_poll_once_redacts_urls_in_error_detail_to_protect_bot_token
    body = { 'data' => { 'status' => 'PENDING', 'errorCode' => 400,
                         'errorMessage' => 'Failed to fetch https://api.telegram.org/file/bot1234:SECRETTOKEN/file.mp3 — bad gateway' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_equal true, result[:failed]
    refute_match(/SECRETTOKEN/,                  result[:error], 'must not leak bot token')
    refute_match(%r{https?://api\.telegram\.org}, result[:error], 'must redact Telegram URL')
    assert_match(/<url-redacted>/,               result[:error])
    assert_match(/bad gateway/,                   result[:error], 'non-URL context must remain so the agent can still reason')
  end

  def test_poll_once_treats_zero_errorcode_and_empty_message_as_not_an_error
    body = { 'data' => { 'status' => 'PENDING',
                         'errorCode' => 0, 'errorMessage' => '' } }
    assert_equal :pending,
                 with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
  end

  # --- WAV-convert endpoints ---

  def test_convert_to_wav_posts_taskid_and_audioid
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.convert_to_wav(task_id: 'task-1', audio_id: 'audio-1')
    end
    req = captured.last
    assert_match %r{/api/v1/wav/generate\z}, req[:url]
    assert_equal 'task-1',  req[:body]['taskId']
    assert_equal 'audio-1', req[:body]['audioId']
    assert_equal 'https://example.com/noop', req[:body]['callBackUrl']
  end

  def test_poll_wav_once_returns_url_on_success
    body = { 'data' => { 'successFlag' => 'SUCCESS',
                         'response' => { 'audioWavUrl' => 'https://cdn/song.wav' } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_wav_once('any-id') }
    assert_kind_of Hash, result
    assert_equal 'https://cdn/song.wav', result[:wav_url]
  end

  def test_poll_wav_once_returns_pending_for_pending_flag
    body = { 'data' => { 'successFlag' => 'PENDING' } }
    assert_equal :pending,
                 with_stubbed_get(body: body) { SunoClient.new.poll_wav_once('any-id') }
  end

  def test_poll_wav_once_returns_failure_hash_with_detail_on_failed_flag
    %w[CREATE_TASK_FAILED GENERATE_WAV_FAILED CALLBACK_EXCEPTION].each do |flag|
      body = { 'data' => { 'successFlag' => flag, 'errorCode' => 500, 'errorMessage' => 'boom' } }
      result = with_stubbed_get(body: body) { SunoClient.new.poll_wav_once('any-id') }
      assert_equal true, result[:failed], "expected failure hash for flag=#{flag}, got #{result.inspect}"
      assert_match(/boom|500/, result[:error], "expected error detail for flag=#{flag}")
    end
  end

  # SUCCESS but empty url → :retry so the handler re-submits a fresh job.
  def test_poll_wav_once_returns_retry_when_success_url_missing
    body = { 'data' => { 'successFlag' => 'SUCCESS', 'response' => { 'audioWavUrl' => '' } } }
    assert_equal :retry,
                 with_stubbed_get(body: body) { SunoClient.new.poll_wav_once('any-id') }
  end

  def test_fetch_audio_ids_extracts_ids_from_record_info
    body = { 'data' => { 'response' => { 'sunoData' => [
      { 'id' => 'aud-1', 'audioUrl' => 'x' },
      { 'id' => 'aud-2', 'audioUrl' => 'y' },
    ] } } }
    assert_equal %w[aud-1 aud-2],
                 with_stubbed_get(body: body) { SunoClient.new.fetch_audio_ids('any-id') }
  end

  def test_fetch_audio_ids_returns_empty_on_missing_data
    assert_equal [], with_stubbed_get(body: {}) { SunoClient.new.fetch_audio_ids('any-id') }
  end

  # poll_once must surface the lyrics Suno used in the clip via the
  # `prompt` field, mapped to `:lyrics` in the result hash. This is the
  # only path by which add_vocals / cover_audio (which don't compose
  # lyrics locally) get any text to send back to the chat.
  def test_poll_once_extracts_lyrics_from_prompt_field
    body = { 'data' => { 'status' => 'SUCCESS',
                         'response' => { 'sunoData' => [
                           { 'audioUrl' => 'https://cdn/clip-1.mp3',
                             'title'    => 'Cover',
                             'duration' => 120,
                             'prompt'   => "[Verse 1]\nDoom doom dada doom\n[Chorus]\nLa la la" },
                         ] } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_kind_of Array, result
    assert_equal 1, result.size
    assert_equal "[Verse 1]\nDoom doom dada doom\n[Chorus]\nLa la la", result.first[:lyrics]
    assert_equal 'https://cdn/clip-1.mp3', result.first[:audio_url]
  end
end

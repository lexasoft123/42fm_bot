require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Stub Settings for SunoClient — it reads api_url/api_key/model at init.
unless Settings.respond_to?(:suno)
  Settings.singleton_class.send(:define_method, :suno) {
    { 'api_url' => 'https://api.sunoapi.org', 'api_key' => 'test-key', 'model' => 'V5' }
  }
end

require_relative '../lib/suno_client'
require_relative '../lib/task_runner' # submit_error must match its error regexes

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

  # submit() accepts `negative_tags` for the structured Suno `negativeTags`
  # field. Negatives must flow only through this channel — TAGS_PROMPT
  # explicitly forbids inlining "no X / without Y" inside the positive
  # `tags`/`style` string, which Suno would parse as positive descriptors.
  def test_submit_includes_negative_tags_when_provided
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.submit(title: 'Test', lyrics: '[Verse]\nfoo',
                            tags: 'rock, anthemic',
                            negative_tags: 'female vocals, acoustic guitar')
    end
    req = captured.last
    assert_match %r{/api/v1/generate\z}, req[:url]
    assert_equal 'female vocals, acoustic guitar', req[:body]['negativeTags']
  end

  def test_submit_omits_negative_tags_when_empty
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.submit(title: 'Test', lyrics: '[Verse]\nfoo', tags: 'rock')
    end
    refute_includes captured.last[:body].keys, 'negativeTags',
                    'negativeTags must be dropped from the POST body when empty'
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

  # add-vocals documents negativeTags as REQUIRED (unlike generate /
  # upload-cover); prod submits without it came back HTTP 200 with no taskId.
  def test_add_vocals_always_sends_negative_tags_even_when_empty
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.add_vocals(
        upload_url: 'https://example.com/in.mp3',
        prompt: 'x', title: 'x', style: 'x'
      )
    end
    assert_includes captured.last[:body].keys, 'negativeTags',
                    'negativeTags is required by add-vocals and must always be sent'
    assert_equal '', captured.last[:body]['negativeTags']
  end

  def test_cover_audio_omits_negative_tags_when_empty
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'synthwave', title: 'Retro',
        prompt: 'theme', custom_mode: false
      )
    end
    refute_includes captured.last[:body].keys, 'negativeTags',
                    'negativeTags must be dropped from cover_audio POST body when empty'
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

  # SENSITIVE_WORD_ERROR is a permanent reject. Suno's status is the
  # categorical bucket; the actual `errorMessage` carries the actionable
  # reason. Always prefer it when present.
  def test_poll_once_sensitive_word_error_prefers_actual_error_message
    # Real-world prod failure: "kuban" in tags read as artist name. The
    # agent must see the actionable reason ("change tags"), not a
    # hardcoded "rephrase theme" line that misdirects the next iteration.
    body = { 'data' => { 'status' => 'SENSITIVE_WORD_ERROR',
                         'errorCode' => 0,
                         'errorMessage' => "Your tags contain artist name kuban - we don't reference specific artists on Our, please change your tags and try again." } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_equal true, result[:failed]
    assert_match(/artist name kuban/, result[:error],
                 'must surface the actual Suno errorMessage so the agent fixes tags, not theme')
    assert_match(/change your tags/,  result[:error])
    refute_match(/нужна переформулировка темы/, result[:error],
                 'static fallback string must not override real Suno message')
  end

  # Fallback: when Suno gives no errorMessage (status only), use the
  # static line as last resort so the agent at least knows it's a
  # content flag rather than a network hiccup.
  def test_poll_once_sensitive_word_error_falls_back_to_static_line_when_no_message
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
  # --- Vocal / stem separation ---

  def test_separate_vocals_with_audio_url_sends_only_audio_url
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.separate_vocals(type: 'separate_vocal', audio_url: 'https://example.com/in.mp3')
    end
    req = captured.last
    assert_match %r{/api/v1/vocal-removal/generate\z}, req[:url]
    assert_equal 'separate_vocal', req[:body]['type']
    assert_equal 'https://example.com/in.mp3', req[:body]['audioUrl']
    refute_includes req[:body].keys, 'taskId',  'audioUrl and taskId/audioId are mutually exclusive'
    refute_includes req[:body].keys, 'audioId', 'audioUrl and taskId/audioId are mutually exclusive'
    refute_includes req[:body].keys, 'stemName'
    assert_equal 'https://example.com/noop', req[:body]['callBackUrl']
  end

  def test_separate_vocals_with_suno_clip_sends_task_and_audio_id
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.separate_vocals(type: 'split_stem', task_id: 'task-1', audio_id: 'aud-1')
    end
    body = captured.last[:body]
    assert_equal 'split_stem', body['type']
    assert_equal 'task-1', body['taskId']
    assert_equal 'aud-1',  body['audioId']
    refute_includes body.keys, 'audioUrl'
  end

  def test_separate_vocals_advanced_sends_stem_name_other_types_do_not
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.separate_vocals(type: 'split_stem_advanced', audio_url: 'https://x/a.mp3', stem_name: 'Drum Kit')
      SunoClient.new.separate_vocals(type: 'separate_vocal', audio_url: 'https://x/a.mp3', stem_name: 'Drum Kit')
    end
    assert_equal 'Drum Kit', captured[0][:body]['stemName']
    refute_includes captured[1][:body].keys, 'stemName', 'stemName only applies to split_stem_advanced'
  end

  def test_separate_vocals_rejects_unknown_type_and_missing_source
    assert_raises(ArgumentError) { SunoClient.new.separate_vocals(type: 'karaoke', audio_url: 'https://x/a.mp3') }
    assert_raises(ArgumentError) { SunoClient.new.separate_vocals(type: 'separate_vocal', task_id: 't') }
  end

  def test_poll_separation_once_uses_vocal_removal_endpoint
    captured = []
    with_stubbed_get(captured: captured, body: { 'data' => { 'successFlag' => 'PENDING' } }) do
      assert_equal :pending, SunoClient.new.poll_separation_once('sep-1')
    end
    assert_match %r{/api/v1/vocal-removal/record-info\z}, captured.last[:url]
    assert_equal 'sep-1', captured.last[:query][:taskId]
  end

  def test_poll_separation_once_separate_vocal_returns_vocals_and_instrumental
    body = { 'data' => { 'successFlag' => 'SUCCESS', 'response' => {
      'vocalUrl' => 'https://cdn/v.mp3', 'instrumentalUrl' => 'https://cdn/i.mp3',
      'drumsUrl' => nil, 'originUrl' => 'https://cdn/src.mp3' } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_equal [{ name: 'Vocals', url: 'https://cdn/v.mp3' },
                  { name: 'Instrumental', url: 'https://cdn/i.mp3' }], result[:stems]
  end

  def test_poll_separation_once_split_stem_returns_every_present_stem_in_order
    response = SunoClient::STEM_FIELDS.keys.each_with_object({}) { |f, h| h[f] = "https://cdn/#{f}.mp3" }
    response['instrumentalUrl'] = nil # docs: null for split_stem
    body = { 'data' => { 'successFlag' => 'SUCCESS', 'response' => response } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_equal SunoClient::STEM_FIELDS.size - 1, result[:stems].size
    assert_equal 'Vocals', result[:stems].first[:name]
    refute(result[:stems].any? { |st| st[:name] == 'Instrumental' })
  end

  def test_poll_separation_once_falls_back_to_origin_data_skipping_source_track
    body = { 'data' => { 'successFlag' => 'SUCCESS', 'response' => {
      'originUrl' => 'https://cdn/src.mp3',
      'originData' => [
        { 'audio_url' => 'https://cdn/src.mp3', 'stem_type_group_name' => 'Original' },
        { 'audio_url' => 'https://cdn/drums.mp3', 'stem_type_group_name' => 'Drum Kit' },
      ] } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_equal [{ name: 'Drum Kit', url: 'https://cdn/drums.mp3' }], result[:stems]
  end

  def test_poll_separation_once_success_without_urls_is_a_failure_not_a_retry
    body = { 'data' => { 'successFlag' => 'SUCCESS', 'response' => { 'vocalUrl' => nil } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_equal true, result[:failed], 'a resubmit is billed again — never :retry on empty SUCCESS'
  end

  def test_poll_separation_once_failure_flags_return_redacted_detail
    %w[CREATE_TASK_FAILED GENERATE_AUDIO_FAILED CALLBACK_EXCEPTION].each do |flag|
      body = { 'data' => { 'successFlag' => flag, 'errorCode' => 400,
                           'errorMessage' => 'cannot fetch https://api.telegram.org/file/bot1:SECRET/a.mp3' } }
      result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
      assert_equal true, result[:failed], "flag=#{flag}"
      refute_match(/SECRET/, result[:error])
      assert_match(/cannot fetch/, result[:error])
    end
  end

  def test_poll_separation_once_failure_flag_without_message_names_the_flag
    body = { 'data' => { 'successFlag' => 'GENERATE_AUDIO_FAILED' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_match(/GENERATE_AUDIO_FAILED/, result[:error])
  end

  def test_poll_separation_once_callback_exception_with_stems_is_success
    body = { 'data' => { 'successFlag' => 'CALLBACK_EXCEPTION', 'response' => {
      'vocalUrl' => 'https://cdn/v.mp3', 'instrumentalUrl' => 'https://cdn/i.mp3' } } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_separation_once('sep-1') }
    assert_equal 2, result[:stems].size, 'callback delivery failure to our placeholder URL is not a separation failure'
  end

  # --- Submit error messages: token-safe on BOTH branches ---

  TOKEN_URL = 'https://api.telegram.org/file/bot123:SECRETTOKEN/music/file_1.mp3'.freeze

  def test_post_non_200_redacts_urls_from_body
    err = assert_raises(RuntimeError) do
      with_stubbed_post(code: 400, body: "bad uploadUrl #{TOKEN_URL}") do
        SunoClient.new.separate_vocals(type: 'separate_vocal', audio_url: TOKEN_URL)
      end
    end
    refute_match(/SECRETTOKEN/, err.message)
    assert_match(/<url-redacted>/, err.message)
  end

  def test_post_200_without_task_id_surfaces_body_code_and_msg_redacted
    err = assert_raises(RuntimeError) do
      with_stubbed_post(body: { 'code' => 400, 'msg' => "negativeTags is required for #{TOKEN_URL}" }) do
        SunoClient.new.add_vocals(upload_url: TOKEN_URL, prompt: 'p', title: 't', style: 's')
      end
    end
    assert_match(/No taskId/, err.message)
    assert_match(/negativeTags is required/, err.message)
    assert_match(/ 400 /, err.message)
    refute_match(/SECRETTOKEN/, err.message)
  end

  def test_submit_error_code_rendering_matches_task_runner_classification
    c = SunoClient.new
    permanent = TaskRunner::PERMANENT_ERROR_RE
    transient = TaskRunner::TRANSIENT_ERROR_RE
    [400, 401, 404, 413, 429].each do |code|
      assert_match permanent, c.send(:submit_error, '/p', code, ''), "#{code} must classify as permanent"
      assert_match permanent, c.send(:submit_error, '/p', code, 'detail'), "#{code} must classify as permanent"
    end
    [405, 430, 455].each do |code|
      msg = c.send(:submit_error, '/p', code, 'try later')
      refute_match permanent, msg, "#{code} (rate/maintenance) must NOT classify as permanent"
      assert_match(/code=#{code}/, msg)
    end
    assert_match transient, c.send(:submit_error, '/p', 503, 'upstream down')
    assert_match transient, c.send(:submit_error, '/p', 500, '')
  end
  # GENERATE_AUDIO_FAILED / CREATE_TASK_FAILED are no longer a bare :retry —
  # the handler decides by task type, and needs Suno's reason to report it.
  def test_poll_once_generation_failure_returns_hash_with_reason
    %w[CREATE_TASK_FAILED GENERATE_AUDIO_FAILED].each do |status|
      body = { 'data' => { 'status' => status, 'errorCode' => 500,
                           'errorMessage' => "cannot read #{TOKEN_URL}" } }
      result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
      assert_equal true, result[:generation_failed], "status=#{status}"
      assert_nil result[:failed], 'generation failure is not the permanent :failed shape'
      assert_match(/cannot read/, result[:error])
      refute_match(/SECRETTOKEN/, result[:error])
    end
  end

  def test_poll_once_generation_failure_without_message_names_status
    body = { 'data' => { 'status' => 'GENERATE_AUDIO_FAILED' } }
    result = with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
    assert_match(/GENERATE_AUDIO_FAILED/, result[:error])
  end

  # :retry is reserved for SUCCESS without clips — a different glitch.
  def test_poll_once_success_without_clips_is_retry
    body = { 'data' => { 'status' => 'SUCCESS', 'response' => { 'sunoData' => [] } } }
    assert_equal :retry, with_stubbed_get(body: body) { SunoClient.new.poll_once('any-id') }
  end
end

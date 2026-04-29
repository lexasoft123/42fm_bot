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

  def test_cover_audio_posts_to_correct_endpoint_with_custom_mode_true
    captured = []
    with_stubbed_post(captured: captured) do
      SunoClient.new.cover_audio(
        upload_url: 'https://example.com/in.mp3',
        style: 'synthwave', title: 'Retro', prompt: 'neon nights'
      )
    end
    req = captured.last
    assert_match %r{/api/v1/generate/upload-cover\z}, req[:url]
    assert_equal true, req[:body]['customMode']
    assert_equal false, req[:body]['instrumental']
    assert_equal 'synthwave', req[:body]['style']
    assert_equal 'Retro', req[:body]['title']
    assert_equal 'neon nights', req[:body]['prompt']
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

  def test_poll_cover_art_once_extracts_image_urls_on_success
    images = ['https://cdn/cover-1.png', 'https://cdn/cover-2.png']
    HTTParty.singleton_class.send(:alias_method, :__get, :get)
    HTTParty.singleton_class.send(:define_method, :get) do |_url, _opts|
      FakeResponse.new(code: 200, body: {
        'data' => { 'status' => 'SUCCESS', 'response' => { 'images' => images } }
      })
    end
    result = SunoClient.new.poll_cover_art_once('any-id')
    assert_kind_of Array, result
    assert_equal 2, result.size
    assert_equal images.first, result.first[:image_url]
  ensure
    HTTParty.singleton_class.send(:alias_method, :get, :__get)
    HTTParty.singleton_class.send(:remove_method, :__get)
  end

  def test_poll_cover_art_once_returns_failed_on_sensitive_word
    HTTParty.singleton_class.send(:alias_method, :__get, :get)
    HTTParty.singleton_class.send(:define_method, :get) do |_url, _opts|
      FakeResponse.new(code: 200, body: { 'data' => { 'status' => 'SENSITIVE_WORD_ERROR' } })
    end
    assert_equal :failed, SunoClient.new.poll_cover_art_once('any-id')
  ensure
    HTTParty.singleton_class.send(:alias_method, :get, :__get)
    HTTParty.singleton_class.send(:remove_method, :__get)
  end

  def test_poll_cover_art_once_returns_pending_on_unknown_status
    HTTParty.singleton_class.send(:alias_method, :__get, :get)
    HTTParty.singleton_class.send(:define_method, :get) do |_url, _opts|
      FakeResponse.new(code: 200, body: { 'data' => { 'status' => 'PROCESSING' } })
    end
    assert_equal :pending, SunoClient.new.poll_cover_art_once('any-id')
  ensure
    HTTParty.singleton_class.send(:alias_method, :get, :__get)
    HTTParty.singleton_class.send(:remove_method, :__get)
  end
end

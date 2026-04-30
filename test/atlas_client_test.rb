require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require 'httparty'
require 'openssl'
require_relative '../lib/atlas_client'

class AtlasClientTest < Minitest::Test
  CFG = { 'api_url' => 'https://api.atlascloud.ai', 'api_key' => 'sk-test' }.freeze

  class FakeResponse
    def initialize(code:, body:); @code = code; @body = body; end
    attr_reader :code
    def body; @body.is_a?(String) ? @body : @body.to_json; end
    def parsed_response; @body.is_a?(String) ? JSON.parse(@body) : @body; end
  end

  def with_stubbed(method, captured: [], code: 200, body: { 'id' => 'x' }, raises: nil)
    real = HTTParty.singleton_class.instance_method(method)
    HTTParty.singleton_class.send(:define_method, method) do |url, opts|
      captured << { url: url, opts: opts }
      raise raises if raises
      FakeResponse.new(code: code, body: body)
    end
    yield
  ensure
    HTTParty.singleton_class.send(:define_method, method, real)
  end

  # POST -------------------------------------------------------------

  def test_post_2xx_returns_parsed_body
    out = with_stubbed(:post, code: 200, body: { 'id' => 'abc' }) do
      AtlasClient.new(CFG).post('/api/v1/model/generateImage', { model: 'm' })
    end
    assert_equal({ 'id' => 'abc' }, out)
  end

  def test_post_non_2xx_raises_with_code_and_body
    err = assert_raises(RuntimeError) do
      with_stubbed(:post, code: 400, body: '{"error":"bad"}') do
        AtlasClient.new(CFG).post('/api/v1/model/generateImage', {})
      end
    end
    assert_match(/AtlasClient POST .*: 400/, err.message)
    assert_match(/bad/, err.message)
  end

  def test_post_sends_authorization_bearer_and_json_content_type
    captured = []
    with_stubbed(:post, captured: captured) do
      AtlasClient.new(CFG).post('/x', { foo: 1 })
    end
    headers = captured.first[:opts][:headers]
    assert_equal 'Bearer sk-test', headers['Authorization']
    assert_equal 'application/json', headers['Content-Type']
  end

  def test_post_does_not_swallow_ssl_errors
    # Asymmetry: submit failures must surface raw so handler bail/retry sees
    # the right exception class. (review-finding 8)
    assert_raises(OpenSSL::SSL::SSLError) do
      with_stubbed(:post, raises: OpenSSL::SSL::SSLError.new('handshake failed')) do
        AtlasClient.new(CFG).post('/x', {})
      end
    end
  end

  # GET --------------------------------------------------------------

  def test_get_200_returns_code_and_body_tuple
    code, body = with_stubbed(:get, code: 200, body: { 'status' => 'ok' }) do
      AtlasClient.new(CFG).get('/api/v1/model/prediction/abc')
    end
    assert_equal 200, code
    assert_equal({ 'status' => 'ok' }, body)
  end

  def test_get_500_still_returns_tuple_for_graceful_polling
    code, body = with_stubbed(:get, code: 500, body: { 'error' => 'boom' }) do
      AtlasClient.new(CFG).get('/x')
    end
    assert_equal 500, code
    assert_equal({ 'error' => 'boom' }, body)
  end

  def test_get_swallows_ssl_errors_returning_nil_tuple
    # Polling degrades to :pending on transient TLS — same pattern FluxClient
    # uses today. The handler treats [nil, nil] as :pending.
    code, body = with_stubbed(:get, raises: OpenSSL::SSL::SSLError.new('boom')) do
      AtlasClient.new(CFG).get('/x')
    end
    assert_nil code
    assert_nil body
  end

  # tag: --------------------------------------------------------------

  def test_tag_ctor_param_affects_error_message
    err = assert_raises(RuntimeError) do
      with_stubbed(:post, code: 400, body: 'nope') do
        AtlasClient.new(CFG, tag: 'AtlasLLM').post('/v1/chat/completions', {})
      end
    end
    assert_match(/\AAtlasLLM POST/, err.message)
    refute_match(/AtlasClient/, err.message)
  end
end

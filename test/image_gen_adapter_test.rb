require_relative 'test_helper'
require 'ostruct'
require 'base64'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Settings stub — image_gen reads two levels (provider + providers.<name>).
# Tests mutate these directly. We also stub `flux` for the back-compat-shim test.
unless Settings.respond_to?(:image_gen)
  Settings.singleton_class.send(:define_method, :image_gen) { @image_gen }
  Settings.singleton_class.send(:define_method, :image_gen=) { |v| @image_gen = v }
end
unless Settings.respond_to?(:flux)
  Settings.singleton_class.send(:define_method, :flux) { @flux }
  Settings.singleton_class.send(:define_method, :flux=) { |v| @flux = v }
end

require_relative '../lib/model_provider_client'
require_relative '../lib/image_gen'

class ImageGenFactoryTest < Minitest::Test
  def teardown
    Settings.image_gen = nil
    Settings.flux = nil
  end

  def test_current_adapter_returns_flux_when_provider_flux
    Settings.image_gen = { 'provider' => 'flux',
                           'providers' => { 'flux' => { 'api_url' => 'u', 'api_key' => 'k' } } }
    adapter = ImageGen.current_adapter
    assert_kind_of ImageGen::FluxAdapter, adapter
    assert_equal 'flux', adapter.name
  end

  def test_current_adapter_returns_atlas_when_provider_atlas
    Settings.image_gen = { 'provider' => 'atlas',
                           'providers' => { 'atlas' => { 'api_url' => 'u', 'api_key' => 'k' } } }
    adapter = ImageGen.current_adapter
    assert_kind_of ImageGen::AtlasAdapter, adapter
    assert_equal 'atlas', adapter.name
  end

  def test_current_adapter_raises_when_provider_missing
    Settings.image_gen = nil
    err = assert_raises(RuntimeError) { ImageGen.current_adapter }
    assert_match(/image_gen.provider not configured/, err.message)
  end

  def test_current_adapter_raises_on_unknown_provider
    Settings.image_gen = { 'provider' => 'midjourney' }
    err = assert_raises(RuntimeError) { ImageGen.current_adapter }
    assert_match(/unknown image_gen provider/, err.message)
    assert_match(/midjourney/, err.message)
  end

  def test_adapter_for_resolves_snapshot
    Settings.image_gen = { 'provider' => 'flux',
                           'providers' => { 'flux'  => { 'api_url' => 'u', 'api_key' => 'k' },
                                            'atlas' => { 'api_url' => 'u', 'api_key' => 'k' } } }
    assert_kind_of ImageGen::AtlasAdapter, ImageGen.adapter_for('atlas')
    assert_kind_of ImageGen::FluxAdapter,  ImageGen.adapter_for('flux')
  end

  def test_adapter_for_falls_back_to_current_for_legacy_rows
    # Old tasks (pre-snapshot) have no params['provider']. adapter_for should
    # gracefully resolve to whatever current_adapter says.
    Settings.image_gen = { 'provider' => 'flux',
                           'providers' => { 'flux' => { 'api_url' => 'u', 'api_key' => 'k' } } }
    assert_kind_of ImageGen::FluxAdapter, ImageGen.adapter_for(nil)
    assert_kind_of ImageGen::FluxAdapter, ImageGen.adapter_for('')
  end
end

# Back-compat shim: FluxAdapter reads top-level `flux:` settings when
# `image_gen.providers.flux` is missing — so step-1 deploys safely on a prod
# settings.yml that hasn't been migrated yet.
class FluxAdapterBackCompatTest < Minitest::Test
  def teardown
    Settings.image_gen = nil
    Settings.flux = nil
  end

  def test_reads_top_level_flux_when_image_gen_missing
    Settings.image_gen = nil
    Settings.flux = { 'api_url' => 'https://api.bfl.ai', 'api_key' => 'legacy', 'model' => 'flux-2-pro' }
    adapter = ImageGen::FluxAdapter.new
    # Indirect assertion: we can construct it without raising. Prompt template
    # is stable across config sources.
    assert_same ImageGen::PromptTemplates::TEXT_TO_IMAGE,
                adapter.prompt_template(:text_to_image)
  end

  def test_prefers_image_gen_over_top_level_flux
    Settings.image_gen = { 'providers' => { 'flux' => { 'api_url' => 'new', 'api_key' => 'new-key' } } }
    Settings.flux      = { 'api_url' => 'old', 'api_key' => 'old-key' }
    adapter = ImageGen::FluxAdapter.new
    api_key = adapter.instance_variable_get(:@api_key)
    assert_equal 'new-key', api_key
  end

  def test_falls_through_to_top_level_when_nested_missing_api_key
    # Prod scenario right after this commit lands: settings.common.yml provides
    # image_gen.providers.flux with api_url + model but NO api_key (secrets
    # never live in common.yml). Prod's settings.yml still has only the legacy
    # top-level flux: { api_key }. Adapter must merge both, NOT just take the
    # nested incomplete block (which would leave @api_key nil → 401 from FLUX).
    Settings.image_gen = { 'providers' => { 'flux' => { 'api_url' => 'https://api.bfl.ai', 'model' => 'flux-2-pro' } } }
    Settings.flux      = { 'api_key' => 'legacy-key' }
    adapter = ImageGen::FluxAdapter.new
    assert_equal 'legacy-key',         adapter.instance_variable_get(:@api_key)
    assert_equal 'https://api.bfl.ai', adapter.instance_variable_get(:@base_url)
    assert_equal 'flux-2-pro',         adapter.instance_variable_get(:@model)
  end

  def test_raises_when_no_config_available
    Settings.image_gen = nil
    Settings.flux = nil
    err = assert_raises(RuntimeError) { ImageGen::FluxAdapter.new }
    assert_match(/flux config missing/, err.message)
  end

  def test_raises_when_api_key_missing_from_both_sources
    # Both schemas present but neither has api_key → fail fast with clear msg
    # (instead of letting nil api_key 401 against bfl.ai later).
    Settings.image_gen = { 'providers' => { 'flux' => { 'api_url' => 'u', 'model' => 'm' } } }
    Settings.flux      = { 'api_url' => 'u' }
    err = assert_raises(RuntimeError) { ImageGen::FluxAdapter.new }
    assert_match(/api_key missing/, err.message)
  end
end

# FluxAdapter#submit — stubs HTTParty.post (FLUX talks HTTP directly, not via
# ModelProviderClient). Verifies the per-request model: kwarg lands in the URL
# path (FLUX selects the model by URL, e.g. /v1/flux-2-pro).
class FluxAdapterSubmitTest < Minitest::Test
  FLUX_CFG = { 'providers' => { 'flux' => { 'api_url' => 'https://api.bfl.ai',
                                            'api_key' => 'k', 'model' => 'flux-2-pro' } } }.freeze
  def setup;    Settings.image_gen = FLUX_CFG; Settings.flux = nil; end
  def teardown; Settings.image_gen = nil;      Settings.flux = nil; end

  def with_post_capture
    captured = []
    real = HTTParty.method(:post)
    HTTParty.singleton_class.send(:define_method, :post) do |url, **_kw|
      captured << url
      OpenStruct.new(code: 200, parsed_response: { 'id' => 'flux-id' })
    end
    yield captured
  ensure
    HTTParty.singleton_class.send(:define_method, :post, real)
  end

  def test_submit_uses_configured_model_in_url_by_default
    with_post_capture do |urls|
      ImageGen::FluxAdapter.new.submit(prompt: 'x')
      assert_equal 'https://api.bfl.ai/v1/flux-2-pro', urls.first
    end
  end

  def test_submit_explicit_model_overrides_url
    with_post_capture do |urls|
      ImageGen::FluxAdapter.new.submit(prompt: 'x', model: 'flux-2-flex')
      assert_equal 'https://api.bfl.ai/v1/flux-2-flex', urls.first
    end
  end

  def test_submit_log_redacts_provider_supplied_model_url
    token = 'FLUXSUBMITTOKEN1234567890123456'
    model = "https://models.example/flux?token=#{token}"
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    with_post_capture { ImageGen::FluxAdapter.new.submit(prompt: 'x', model: model) }

    assert_includes output.string, '[url]'
    refute_includes output.string, token
    refute_includes output.string, 'models.example'
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_poll_log_redacts_status_and_external_identifier
    token = 'FLUXPOLLTOKEN123456789012345678'
    signed_url = "https://status.example/job?token=#{token}"
    real_get = HTTParty.method(:get)
    HTTParty.singleton_class.send(:define_method, :get) do |*_args, **_kwargs|
      OpenStruct.new(code: 200, parsed_response: { 'status' => signed_url })
    end
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    assert_equal :pending, ImageGen::FluxAdapter.new.poll_once(token)

    assert_includes output.string, '[url]'
    refute_includes output.string, token
    refute_includes output.string, 'status.example'
  ensure
    HTTParty.singleton_class.send(:define_method, :get, real_get) if defined?(real_get) && real_get
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end
end

# AtlasAdapter — stubs ModelProviderClient at the class level (not HTTParty) so we
# test adapter logic above the HTTP layer; ModelProviderClient itself is covered by
# atlas_client_test.rb.
class AtlasAdapterTest < Minitest::Test
  ATLAS_CFG = {
    'provider'  => 'atlas',
    'providers' => {
      'atlas' => {
        'api_url' => 'https://api.atlascloud.ai',
        'api_key' => 'sk-test',
        'text_to_image_model' => 'alibaba/wan-2.7/text-to-image',
        'image_edit_model'    => 'alibaba/wan-2.7/image-edit',
        'width' => 1024, 'height' => 1024
      }
    }
  }.freeze

  class FakeModelProviderClient
    attr_reader :calls
    def initialize(post_returns: { 'id' => 'pred-1' }, get_returns: [200, { 'status' => 'processing' }])
      @post_returns = post_returns
      @get_returns  = get_returns
      @calls = []
    end
    def post(path, body, **_); @calls << [:post, path, body]; @post_returns; end
    def get(path, **_);        @calls << [:get,  path];       @get_returns;  end
  end

  def setup
    Settings.image_gen = ATLAS_CFG
  end

  def teardown
    Settings.image_gen = nil
  end

  # Constructor failure modes — these are the "deploy before prod settings.yml
  # is updated" scenarios. Both should raise a clear message that propagates
  # through the handler's `adapter_config_error` path to a chat notification.

  def test_initialize_raises_when_atlas_block_missing
    Settings.image_gen = { 'provider' => 'atlas', 'providers' => {} }
    err = assert_raises(RuntimeError) { ImageGen::AtlasAdapter.new }
    assert_match(/atlas config missing/, err.message)
  end

  def test_initialize_raises_when_api_key_missing
    cfg = Marshal.load(Marshal.dump(ATLAS_CFG))
    cfg['providers']['atlas'].delete('api_key')
    Settings.image_gen = cfg
    err = assert_raises(KeyError) { ImageGen::AtlasAdapter.new }
    assert_match(/api_key/, err.message)
  end

  def with_fake_client(client)
    real = ModelProviderClient.method(:new)
    ModelProviderClient.singleton_class.send(:define_method, :new) { |_cfg, **_| client }
    yield
  ensure
    ModelProviderClient.singleton_class.send(:define_method, :new, real)
  end

  # submit -----------------------------------------------------------

  def test_submit_text_to_image_sends_correct_body_shape
    # Live probe 2026-04-30: flat shape, NOT input.{} wrapper.
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'abc' } })
    id = with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(prompt: 'cat in hat')
    end
    assert_equal 'abc', id

    method, path, body = fake.calls.first
    assert_equal :post, method
    assert_equal '/api/v1/model/generateImage', path
    assert_equal 'alibaba/wan-2.7/text-to-image', body[:model]
    assert_equal 'cat in hat', body[:prompt]
    assert_equal 1024,         body[:width]
    assert_equal 1024,         body[:height]
    refute body.key?(:input), 'request must NOT wrap fields in :input — Atlas rejects that'
  end

  def test_submit_image_edit_wan_uses_singular_image_field
    # Default edit model is Wan (alibaba/wan-2.7/image-edit) → singular `image`.
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'edit-id' } })
    id = with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'add sunglasses',
        input_images: [{ data: 'BASE64BYTES', media_type: 'image/png' }]
      )
    end
    assert_equal 'edit-id', id

    _, _, body = fake.calls.first
    assert_equal 'alibaba/wan-2.7/image-edit', body[:model]
    assert_equal 'add sunglasses', body[:prompt]
    assert_equal 'data:image/png;base64,BASE64BYTES', body[:image]
    refute body.key?(:images), 'Wan reads singular `image`, not the `images` array'
    refute body.key?(:width),  'image-edit body should not include width'
    refute body.key?(:height), 'image-edit body should not include height'
  end

  def test_submit_image_edit_nano_banana_uses_images_array
    # nano-banana edit models read a plural `images` array (and ignore a
    # singular `image`, silently degrading to text-to-image — the bug this fixes).
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'nb-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'add the teacher',
        input_images: [{ data: 'B64A', media_type: 'image/jpeg' }],
        model: 'google/nano-banana-2/edit'
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'google/nano-banana-2/edit', body[:model]
    assert_equal ['data:image/jpeg;base64,B64A'], body[:images]
    refute body.key?(:image), 'nano-banana reads plural `images`, not singular `image`'
  end

  def test_submit_image_edit_nano_banana_combines_multiple_images
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'nb-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'combine',
        input_images: [{ data: 'B64A', media_type: 'image/jpeg' },
                       { data: 'B64B', media_type: 'image/png' }],
        model: 'google/nano-banana-2/edit'
      )
    end
    _, _, body = fake.calls.first
    assert_equal ['data:image/jpeg;base64,B64A', 'data:image/png;base64,B64B'], body[:images]
  end

  def test_submit_image_edit_wan_with_multiple_images_uses_first
    # A combine routed to Wan (single-image) keeps only the first image.
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'w-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'combine',
        input_images: [{ data: 'B64A', media_type: 'image/jpeg' },
                       { data: 'B64B', media_type: 'image/png' }]
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'data:image/jpeg;base64,B64A', body[:image], 'Wan edits only the first image'
    refute body.key?(:images)
  end

  def test_submit_text_to_image_seedream_uses_size_field
    # Seedream takes `size: "WIDTH*HEIGHT"`, NOT width/height integers.
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'sd-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(prompt: 'seascape', model: 'bytedance/seedream-v5.0-pro/text-to-image')
    end
    _, _, body = fake.calls.first
    assert_equal 'bytedance/seedream-v5.0-pro/text-to-image', body[:model]
    assert_equal '1024*1024', body[:size]
    refute body.key?(:width),  'Seedream uses `size`, not width'
    refute body.key?(:height), 'Seedream uses `size`, not height'
  end

  def test_submit_image_edit_seedream_uses_images_array
    # Seedream edit reads a plural `images` array (like nano-banana). Sending a
    # singular `image` would make it silently regenerate from scratch.
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'sd-edit' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'add a crown',
        input_images: [{ data: 'B64A', media_type: 'image/jpeg' },
                       { data: 'B64B', media_type: 'image/png' }],
        model: 'bytedance/seedream-v5.0-pro/edit'
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'bytedance/seedream-v5.0-pro/edit', body[:model]
    assert_equal ['data:image/jpeg;base64,B64A', 'data:image/png;base64,B64B'], body[:images]
    refute body.key?(:image), 'Seedream reads plural `images`, not singular `image`'
  end

  def test_submit_text_to_image_gpt_image_sunburst_uses_x_size_field
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'gpt-image-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'precise poster',
        model: 'openai/gpt-image-2.5-sunburst/text-to-image'
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'openai/gpt-image-2.5-sunburst/text-to-image', body[:model]
    assert_equal '1024x1024', body[:size]
    refute body.key?(:width), 'GPT Image uses `size`, not width'
    refute body.key?(:height), 'GPT Image uses `size`, not height'
  end

  def test_submit_image_edit_gpt_image_sunburst_uses_images_array
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'gpt-image-edit' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'preserve the faces',
        input_images: [{ data: 'B64A', media_type: 'image/jpeg' },
                       { data: 'B64B', media_type: 'image/png' }],
        model: 'openai/gpt-image-2.5-sunburst/edit'
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'openai/gpt-image-2.5-sunburst/edit', body[:model]
    assert_equal ['data:image/jpeg;base64,B64A', 'data:image/png;base64,B64B'], body[:images]
    refute body.key?(:image), 'GPT Image reads plural `images`, not singular `image`'
  end

  def test_submit_text_to_image_qwen_3_uses_size_field
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'qwen-id' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(prompt: 'newspaper layout', model: 'qwen-image-3.0-pro/text-to-image')
    end
    _, _, body = fake.calls.first
    assert_equal 'qwen-image-3.0-pro/text-to-image', body[:model]
    assert_equal '1024*1024', body[:size]
    refute body.key?(:width), 'Qwen Image 3.0 uses `size`, not width'
    refute body.key?(:height), 'Qwen Image 3.0 uses `size`, not height'
  end

  def test_submit_image_edit_qwen_3_uses_reference_image_urls_and_caps_at_three
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'qwen-edit' } })
    images = (1..4).map { |n| { data: "B64#{n}", media_type: 'image/png' } }
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'combine into a poster',
        input_images: images,
        model: 'qwen-image-3.0-pro/edit'
      )
    end
    _, _, body = fake.calls.first
    assert_equal 'qwen-image-3.0-pro/edit', body[:model]
    assert_equal %w[B641 B642 B643].map { |data| "data:image/png;base64,#{data}" }, body[:reference_image_urls]
    refute body.key?(:images)
    refute body.key?(:image)
  end

  def test_submit_handles_unwrapped_id_response_shape
    # Defensive: if Atlas ever returns the id at top level instead of data.id.
    fake = FakeModelProviderClient.new(post_returns: { 'id' => 'top-level' })
    id = with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'x') }
    assert_equal 'top-level', id
  end

  def test_submit_raises_when_no_id_field_found
    fake = FakeModelProviderClient.new(post_returns: { 'something_else' => 'oops' })
    err = assert_raises(RuntimeError) do
      with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'x') }
    end
    assert_match(/no id in response/, err.message)
  end

  def test_submit_error_redacts_provider_response_before_escape
    token = 'ATLASSUBMITTOKEN123456789012345'
    signed_url = "https://atlas.example/result?token=#{token}"
    fake = FakeModelProviderClient.new(post_returns: {
      'error' => signed_url,
      'authorization' => "Bearer #{token}"
    })
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    error = assert_raises(RuntimeError) do
      with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'x') }
    end

    assert_includes error.message, '[url]'
    refute_includes error.message, token
    refute_includes error.message, 'atlas.example'
    refute_includes output.string, token
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_submit_uses_configured_model_and_dimensions
    cfg = Marshal.load(Marshal.dump(ATLAS_CFG))
    cfg['providers']['atlas']['text_to_image_model'] = 'qwen-image'
    cfg['providers']['atlas']['width'] = 512
    cfg['providers']['atlas']['height'] = 768
    Settings.image_gen = cfg

    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'x' } })
    with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'y') }

    _, _, body = fake.calls.first
    assert_equal 'qwen-image', body[:model]
    assert_equal 512, body[:width]
    assert_equal 768, body[:height]
  end

  # poll_once --------------------------------------------------------
  # Atlas wraps the prediction state under `data.{...}` per live-probe
  # response shape. Adapter also accepts unwrapped (defensive).

  def test_poll_completed_returns_url
    body = { 'code' => 200, 'data' => { 'status' => 'completed', 'outputs' => ['https://x.png'] } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('pred-1') }
    assert_equal({ url: 'https://x.png' }, out)
    assert_equal '/api/v1/model/prediction/pred-1', fake.calls.first[1]
  end

  def test_poll_succeeded_returns_url
    body = { 'data' => { 'status' => 'succeeded', 'outputs' => ['https://y.png'] } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('pred-1') }
    assert_equal({ url: 'https://y.png' }, out)
  end

  def test_poll_processing_returns_pending
    fake = FakeModelProviderClient.new(get_returns: [200, { 'data' => { 'status' => 'processing' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_queued_returns_pending
    fake = FakeModelProviderClient.new(get_returns: [200, { 'data' => { 'status' => 'queued' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_failed_returns_failed
    body = { 'code' => 400, 'data' => { 'status' => 'failed', 'error' => 'oops' } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal({ failed: true, error: 'oops' }, out)
  end

  def test_poll_failure_log_redacts_error_url_and_external_identifier
    token = 'ATLASPOLLTOKEN12345678901234567'
    signed_url = "https://atlas.example/result?token=#{token}"
    body = { 'data' => { 'status' => 'failed', 'error' => "provider failed at #{signed_url}" } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once(token) }

    assert_equal({ failed: true, error: 'provider failed at [url]' }, out)
    assert_includes output.string, '[url]'
    refute_includes output.string, token
    refute_includes output.string, 'atlas.example'
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_poll_unknown_status_logs_once_returns_pending
    fake = FakeModelProviderClient.new(get_returns: [200, { 'data' => { 'status' => 'mystery_state' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('uniq-id-mystery') }
    assert_equal :pending, out
  end

  # A non-200 poll (HTTP 500/400) or a swallowed transient ([nil,nil]) is NOT
  # "processing" — signal :poll_error so the handler can fail fast after a few
  # CONSECUTIVE errors instead of masking a failed job as pending until timeout.
  def test_poll_http_500_returns_poll_error
    fake = FakeModelProviderClient.new(get_returns: [500, { 'error' => 'boom' }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :poll_error, out
  end

  def test_poll_http_400_returns_poll_error
    fake = FakeModelProviderClient.new(get_returns: [400, nil])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :poll_error, out
  end

  def test_poll_transient_ssl_returns_poll_error
    # ModelProviderClient#get returns [nil, nil] on SSL/timeout.
    fake = FakeModelProviderClient.new(get_returns: [nil, nil])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :poll_error, out
  end

  def test_poll_completed_without_outputs_returns_failed
    # Defensive: status says done but no URL means we can't deliver. Mark
    # failed rather than crash later trying to download nothing.
    body = { 'data' => { 'status' => 'completed', 'outputs' => [] } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal({ failed: true, error: 'terminal status without image output' }, out)
  end

  def test_poll_tolerates_unwrapped_response_shape
    # If Atlas ever returns the prediction at top level (instead of data.{}),
    # adapter still handles it.
    fake = FakeModelProviderClient.new(get_returns: [200, { 'status' => 'completed', 'outputs' => ['https://z.png'] }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal({ url: 'https://z.png' }, out)
  end

  # prompt_template --------------------------------------------------

  def test_prompt_template_text_to_image_is_model_agnostic_with_placeholders
    fake = FakeModelProviderClient.new
    template = with_fake_client(fake) { ImageGen::AtlasAdapter.new.prompt_template(:text_to_image) }
    # Model name is now interpolated (de-hardcoded from "Wan 2.7") so the same
    # Atlas adapter can serve nano-banana-2 etc.
    assert_match(/%\{model_name\}/, template)
    refute_match(/Wan 2\.7/, template, 'model name must be de-hardcoded')
    assert_match(/%\{request\}/, template)
    assert_match(/%\{context\}/, template)
    assert_match(/%\{knowledge\}/, template)
    refute_match(/FLUX 2 приоритизирует/, template, 'should drop FLUX-specific guidance')
  end

  def test_prompt_template_edit_mode_is_direct_and_model_agnostic
    fake = FakeModelProviderClient.new
    template = with_fake_client(fake) { ImageGen::AtlasAdapter.new.prompt_template(:edit) }
    assert_match(/%\{model_name\}/, template)
    refute_match(/Wan/, template, 'edit template model name must be de-hardcoded')
    assert_match(/Опиши только изменение/, template)
    assert_match(/%\{request\}/, template)
  end

  # Per-request model override: explicit model: kwarg wins over @t2i_model/@edit_model.
  def test_submit_explicit_model_overrides_configured_t2i
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'x' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(prompt: 'y', model: 'google/nano-banana-2/text-to-image')
    end
    _, _, body = fake.calls.first
    assert_equal 'google/nano-banana-2/text-to-image', body[:model]
  end

  def test_submit_explicit_model_overrides_configured_edit
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'x' } })
    with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(prompt: 'y',
        input_images: [{ data: 'B64', media_type: 'image/jpeg' }],
        model: 'google/nano-banana-2/edit')
    end
    _, _, body = fake.calls.first
    assert_equal 'google/nano-banana-2/edit', body[:model]
  end

  def test_submit_nil_model_falls_back_to_configured
    fake = FakeModelProviderClient.new(post_returns: { 'data' => { 'id' => 'x' } })
    with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'y', model: nil) }
    _, _, body = fake.calls.first
    assert_equal 'alibaba/wan-2.7/text-to-image', body[:model], 'nil model → configured default'
  end
end

# CloseRouterImgAdapter unit tests — same FakeModelProviderClient stubbing
# pattern as AtlasAdapter. Verifies request body shape (singular T2I vs plural
# `images` for edit), URL extraction from data[0].url, synchronous? predicate,
# and poll_once defensive raise.
class CloseRouterImgAdapterTest < Minitest::Test
  CR_CFG = {
    'provider'  => 'closerouter',
    'providers' => {
      'closerouter' => {
        'api_url' => 'https://api.closerouter.dev',
        'api_key' => 'sk-test-cr',
        'text_to_image_model' => 'google/nano-banana-pro',
        'image_edit_model'    => 'google/nano-banana-pro-edit',
      }
    }
  }.freeze

  class FakeModelProviderClient
    attr_reader :calls
    def initialize(post_returns: { 'data' => [{ 'url' => 'https://cdn/x.png' }] })
      @post_returns = post_returns
      @calls = []
    end
    def post(path, body, **_); @calls << [:post, path, body]; @post_returns; end
  end

  def setup
    Settings.image_gen = CR_CFG
  end

  def teardown
    Settings.image_gen = nil
  end

  def with_fake_client(client)
    real = ModelProviderClient.method(:new)
    ModelProviderClient.singleton_class.send(:define_method, :new) { |_cfg, **_| client }
    yield
  ensure
    ModelProviderClient.singleton_class.send(:define_method, :new, real)
  end

  def test_synchronous_predicate_is_true
    fake = FakeModelProviderClient.new
    adapter = with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new }
    assert adapter.synchronous?, 'CloseRouter image generations return synchronously'
  end

  def test_submit_text_to_image_sends_prompt_and_t2i_model
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [{ 'url' => 'https://cdn/t2i.png' }] })
    result = with_fake_client(fake) do
      ImageGen::CloseRouterImgAdapter.new.submit(prompt: 'cat in hat')
    end
    method, path, body = fake.calls.first
    assert_equal :post, method
    assert_equal '/v1/images/generations', path
    assert_equal 'google/nano-banana-pro', body[:model]
    assert_equal 'cat in hat', body[:prompt]
    refute body.key?(:images), 'T2I body must not include images param'
    assert_equal({ url: 'https://cdn/t2i.png' }, result)
  end

  def test_submit_edit_sends_plural_images_and_edit_model
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [{ 'url' => 'https://cdn/edit.png' }] })
    result = with_fake_client(fake) do
      ImageGen::CloseRouterImgAdapter.new.submit(
        prompt: 'add a hat',
        input_images: [{ data: 'ZmFrZWJ5dGVz', media_type: 'image/png' }], # base64 'fakebytes'
      )
    end
    _method, _path, body = fake.calls.first
    assert_equal 'google/nano-banana-pro-edit', body[:model]
    assert_equal 'add a hat', body[:prompt]
    assert_kind_of Array, body[:images], 'edit body must use plural `images` array'
    assert_equal 1, body[:images].length
    assert_equal 'data:image/png;base64,ZmFrZWJ5dGVz', body[:images].first
    assert_equal({ url: 'https://cdn/edit.png' }, result)
  end

  def test_submit_edit_combines_multiple_images
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [{ 'url' => 'https://cdn/edit.png' }] })
    with_fake_client(fake) do
      ImageGen::CloseRouterImgAdapter.new.submit(
        prompt: 'combine',
        input_images: [{ data: 'AAA', media_type: 'image/jpeg' },
                       { data: 'BBB', media_type: 'image/png' }],
      )
    end
    _m, _p, body = fake.calls.first
    assert_equal ['data:image/jpeg;base64,AAA', 'data:image/png;base64,BBB'], body[:images]
  end

  def test_submit_raises_when_response_missing_data_url
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [] })
    err = assert_raises(RuntimeError) do
      with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new.submit(prompt: 'x') }
    end
    assert_match(/no data\[0\]\.url/, err.message)
  end

  def test_submit_explicit_model_overrides_configured
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [{ 'url' => 'https://cdn/x.png' }] })
    with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new.submit(prompt: 'y', model: 'custom/model') }
    _, _, body = fake.calls.first
    assert_equal 'custom/model', body[:model]
  end

  def test_submit_edit_explicit_model_overrides_configured
    fake = FakeModelProviderClient.new(post_returns: { 'data' => [{ 'url' => 'https://cdn/x.png' }] })
    with_fake_client(fake) do
      ImageGen::CloseRouterImgAdapter.new.submit(prompt: 'y', input_images: [{ data: 'ZmFrZQ==', media_type: 'image/jpeg' }], model: 'custom/edit')
    end
    _, _, body = fake.calls.first
    assert_equal 'custom/edit', body[:model]
  end

  def test_initialize_raises_when_closerouter_block_missing
    Settings.image_gen = { 'provider' => 'closerouter', 'providers' => {} }
    err = assert_raises(RuntimeError) { ImageGen::CloseRouterImgAdapter.new }
    assert_match(/closerouter image config missing/, err.message)
  end

  def test_initialize_raises_when_api_key_missing
    cfg = Marshal.load(Marshal.dump(CR_CFG))
    cfg['providers']['closerouter'].delete('api_key')
    Settings.image_gen = cfg
    err = assert_raises(RuntimeError) { ImageGen::CloseRouterImgAdapter.new }
    assert_match(/api_key/, err.message)
  end

  def test_poll_once_raises_for_synchronous_adapter
    fake = FakeModelProviderClient.new
    adapter = with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new }
    err = assert_raises(NotImplementedError) { adapter.poll_once('whatever') }
    assert_match(/synchronous/, err.message)
  end

  def test_prompt_template_is_shared_and_model_agnostic
    fake = FakeModelProviderClient.new
    template = with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new.prompt_template(:text_to_image) }
    assert_same ImageGen::PromptTemplates::TEXT_TO_IMAGE, template
    assert_match(/%{model_name}/, template)
    assert_match(/%\{request\}/, template)
  end
end

# FakeAdapter — captures calls + returns canned results so we can drive the
# real ImageGenTaskHandler without hitting any backend.
class FakeAdapter < ImageGen::Adapter
  NAME = 'fake'
  attr_accessor :submit_calls, :poll_calls, :submit_returns, :poll_returns, :sync, :adapter_for_args

  def initialize(submit_returns: 'fake-extid', poll_returns: { url: 'http://x/img.jpg' }, sync: false)
    @submit_calls     = []
    @poll_calls       = []
    @adapter_for_args = []
    @submit_returns   = submit_returns
    @poll_returns     = poll_returns
    @sync             = sync
  end

  def submit(prompt:, input_images: nil, model: nil)
    @submit_calls << { prompt: prompt, input_images: input_images, model: model }
    raise @submit_returns if @submit_returns.is_a?(Exception)
    @submit_returns
  end

  def poll_once(external_id)
    @poll_calls << external_id
    raise @poll_returns if @poll_returns.is_a?(Exception)
    @poll_returns
  end

  # Template references %{model_name} so handler-interpolation tests exercise the
  # mandatory model_name key on every path (a missing key would raise KeyError).
  def prompt_template(mode)
    "[#{mode}] %{request} | %{context} | %{knowledge} | model=%{model_name}"
  end

  def synchronous?
    @sync
  end
end

# Loaded lazily so models are registered first.
require_relative '../lib/gpt_master'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/image_gen_handler'
require 'telegram/bot'
require 'stringio'

# Handler↔adapter integration. Stubs ImageGen module methods to inject a
# FakeAdapter, plus GptMaster + ChatContext + the bot api so we never reach
# real services. Asserts the handler:
#   - selects prompt_template by mode
#   - snapshots provider into params on submit
#   - dispatches by snapshot on poll (survives a config flip)
class HandlerAdapterIntegrationTest < BotTest
  # Captures the messages array passed at construct so tests can inspect what
  # template the handler picked. Returns a canned string from #call.
  class FakeGptMaster
    @@captured = []
    @@kwargs = []
    @@response = 'enriched prompt'
    def self.captured; @@captured; end
    def self.kwargs; @@kwargs; end
    def self.settings; @@kwargs.map { |kw| kw[:setting] }; end
    def self.response=(value); @@response = value; end
    def self.reset!; @@captured = []; @@kwargs = []; @@response = 'enriched prompt'; end
    def initialize(messages, **kw); @@captured << messages; @@kwargs << kw; end
    def call
      raise @@response if @@response.is_a?(Exception)
      @@response
    end
  end

  class FakeBotApi
    attr_reader :calls
    def initialize
      @calls = []
      @photo_outcomes = []
      @message_outcomes = []
    end
    def queue_photo_outcomes(*outcomes); @photo_outcomes.concat(outcomes); end
    def queue_message_outcomes(*outcomes); @message_outcomes.concat(outcomes); end
    def sendMessage(**kw)
      @calls << [:sendMessage, kw]
      outcome = @message_outcomes.empty? ? OpenStruct.new(message_id: 1, message_thread_id: nil) : @message_outcomes.shift
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
    def sendPhoto(**kw)
      @calls << [:sendPhoto, kw]
      outcome = @photo_outcomes.empty? ? OpenStruct.new(message_id: 2, message_thread_id: nil) : @photo_outcomes.shift
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
  end

  HANDLER_CATALOG = {
    'provider' => 'atlas',
    'default_model' => 'nano-banana-2',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'desc' => 'd' },
      'wan-2.7'       => { 'provider' => 'atlas', 't2i' => 'alibaba/wan-2.7-pro/text-to-image',
                           'edit' => 'alibaba/wan-2.7/image-edit', 'desc' => 'd' },
      'flux-2-pro'    => { 'provider' => 'flux', 't2i' => 'flux-2-pro', 'edit' => 'flux-2-pro', 'desc' => 'd' },
      'bad-provider'  => { 'provider' => 'nope', 't2i' => 'x/y', 'edit' => false, 'desc' => 'd' },
    },
  }.freeze

  def setup
    super
    @original_download_to_tempfile = ImageGenTaskHandler.instance_method(:download_to_tempfile)
    @fake_adapter = FakeAdapter.new
    @bot          = FakeBotApi.new
    @original_gpt = ::GptMaster if defined?(::GptMaster)
    Object.send(:remove_const, :GptMaster) if defined?(::GptMaster)
    Object.const_set(:GptMaster, FakeGptMaster)
    FakeGptMaster.reset!

    Settings.image_gen = Marshal.load(Marshal.dump(HANDLER_CATALOG))
    ImageGen::Catalog.reset!

    ImageGen.singleton_class.send(:alias_method, :__current_adapter, :current_adapter)
    ImageGen.singleton_class.send(:alias_method, :__adapter_for,     :adapter_for)
    fa = @fake_adapter
    ImageGen.define_singleton_method(:current_adapter) { fa }
    ImageGen.define_singleton_method(:adapter_for)     { |n| fa.adapter_for_args << n; fa }

    # Stub away ChatContext lookups + tempfile download (forces sendPhoto's
    # URL-fallback path so we don't need a real image to deliver).
    ImageGenTaskHandler.class_eval do
      define_method(:get_chat_context)        { |_, thread_id: nil| 'ctx' }
      define_method(:get_relevant_knowledge)  { |_, _| 'kn' }
      define_method(:download_to_tempfile)    { |_url| nil }
    end

    # Stub history-photo downloads: file_id 'BADDL' fails (simulates a transient
    # download error), everything else returns a canned image so that
    # source_message_ids resolution is deterministic.
    @orig_download_image = TelegramFile.method(:download_image)
    TelegramFile.singleton_class.send(:define_method, :download_image) do |_api, file_id, **_|
      file_id == 'BADDL' ? nil : { data: "DL_#{file_id}", media_type: 'image/jpeg' }
    end

    Chat.create!(chat_id: -1, title: 't', chat_type: 'group', authorized: true, audio: false)
  end

  def teardown
    Object.send(:remove_const, :GptMaster) if defined?(::GptMaster)
    Object.const_set(:GptMaster, @original_gpt) if @original_gpt
    ImageGen.singleton_class.send(:alias_method, :current_adapter, :__current_adapter)
    ImageGen.singleton_class.send(:alias_method, :adapter_for,     :__adapter_for)
    ImageGen.singleton_class.send(:remove_method, :__current_adapter)
    ImageGen.singleton_class.send(:remove_method, :__adapter_for)
    TelegramFile.singleton_class.send(:define_method, :download_image, @orig_download_image) if @orig_download_image
    ImageGenTaskHandler.send(:define_method, :download_to_tempfile, @original_download_to_tempfile) if @original_download_to_tempfile
    Settings.image_gen = nil
    ImageGen::Catalog.reset!
    super
  end

  def fresh_task(input_image: nil, input_images: nil, source_message_ids: nil, model: nil, award: false,
                 forum_thread_id: nil)
    params = { 'request' => 'кот в шляпе', 'user_uid' => 42 }
    params['input_image']        = input_image if input_image
    params['input_media_type']   = 'image/jpeg' if input_image
    params['input_images']       = input_images if input_images
    params['source_message_ids'] = source_message_ids if source_message_ids
    params['model'] = model if model
    params['award'] = true  if award
    params['forum_thread_id'] = forum_thread_id if forum_thread_id
    BackgroundTask.create!(task_type: 'image_generate', chat_id: -1, max_attempts: 60, params: params.to_json)
  end

  # Pull out the text the handler sent to GptMaster (works for both plain text
  # and image+text content arrays).
  def gpt_text(messages)
    content = messages.first[:content]
    return content if content.is_a?(String)
    content.find { |c| c.is_a?(Hash) && c[:type] == 'text' }[:text]
  end

  def test_submit_uses_text_to_image_template_and_snapshots_provider
    task = fresh_task
    ImageGenTaskHandler.new.call(task, @bot)

    # Adapter received the GPT-enriched prompt
    refute_empty @fake_adapter.submit_calls
    assert_equal 'enriched prompt', @fake_adapter.submit_calls.first[:prompt]

    # Provider snapshotted into params
    task.reload
    assert_equal 'fake-extid', task.external_id
    assert_equal 'fake', task.params_hash['provider']
    assert_equal 'processing', task.lifecycle_phase
    assert_equal 'unknown', task.delivery_status

    # Template selection: handler asked adapter for :text_to_image template,
    # which our FakeAdapter prefixes with [text_to_image] — that string
    # appears in the LLM prompt FakeGptMaster captured.
    refute_empty FakeGptMaster.captured
    assert_match(/\[text_to_image\]/, gpt_text(FakeGptMaster.captured.first))
  end

  # Both modes use the dedicated multimodal prompt composer. This keeps prompt
  # length/creativity tuning independent from the full agent tool loop.
  def test_image_edit_uses_image_prompt_setting
    task = fresh_task(input_image: Base64.strict_encode64('fakebytes'))
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'image_prompt', FakeGptMaster.settings.first
  end

  def test_text_to_image_uses_image_prompt_setting
    task = fresh_task # no image
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'image_prompt', FakeGptMaster.settings.first
    assert_equal false, FakeGptMaster.kwargs.first[:report_errors]
  end

  def test_prompt_composer_refusal_falls_back_to_raw_user_request
    task = fresh_task(input_image: Base64.strict_encode64('fakebytes'))
    raw_request = task.params_hash['request']
    FakeGptMaster.response = "I can't help create that image."

    ImageGenTaskHandler.new.call(task, @bot)

    assert_equal raw_request, @fake_adapter.submit_calls.first[:prompt]
    persisted = BackgroundTask.find(task.id).params_hash
    assert_equal raw_request, persisted['prompt']
  end

  def test_blank_prompt_composer_output_falls_back_to_raw_user_request
    task = fresh_task(input_image: Base64.strict_encode64('fakebytes'))
    raw_request = task.params_hash['request']
    FakeGptMaster.response = " \n\t "

    ImageGenTaskHandler.new.call(task, @bot)

    assert_equal raw_request, @fake_adapter.submit_calls.first[:prompt]
    persisted = BackgroundTask.find(task.id).params_hash
    assert_equal raw_request, persisted['prompt']
  end

  def test_prompt_composer_provider_failure_falls_back_without_retrying_task
    task = fresh_task
    raw_request = task.params_hash['request']
    FakeGptMaster.response = 'жпт не жпт'

    result = ImageGenTaskHandler.new.call(task, @bot)

    assert_equal :pending, result
    assert_equal raw_request, @fake_adapter.submit_calls.first[:prompt]
    persisted = BackgroundTask.find(task.id).params_hash
    assert_equal raw_request, persisted['prompt']
    refute persisted.key?('prompt_failures')
  end

  def test_prompt_composer_exception_falls_back_without_retrying_task
    task = fresh_task
    raw_request = task.params_hash['request']
    FakeGptMaster.response = RuntimeError.new('composer unavailable')

    result = ImageGenTaskHandler.new.call(task, @bot)

    assert_equal :pending, result
    assert_equal raw_request, @fake_adapter.submit_calls.first[:prompt]
    persisted = BackgroundTask.find(task.id).params_hash
    assert_equal raw_request, persisted['prompt']
    refute persisted.key?('prompt_failures')
  end

  def test_prompt_composer_failure_still_uses_submit_retry_path
    task = fresh_task
    raw_request = task.params_hash['request']
    FakeGptMaster.response = 'жпт не жпт'
    @fake_adapter.submit_returns = RuntimeError.new('image backend unavailable')

    error = assert_raises(RuntimeError) { ImageGenTaskHandler.new.call(task, @bot) }

    assert_equal 'image backend unavailable', error.message
    assert_equal raw_request, @fake_adapter.submit_calls.first[:prompt]
    persisted = BackgroundTask.find(task.id).params_hash
    assert_equal raw_request, persisted['prompt']
    assert_equal 1, persisted['submit_failures']
    refute persisted.key?('prompt_failures')
  end

  def test_provider_submit_exception_is_redacted_before_rethrow_and_log
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    @fake_adapter.submit_returns = RuntimeError.new(
      "provider 503 https://provider.example/jobs/9?token=#{token}"
    )
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    error = assert_raises(RuntimeError) { ImageGenTaskHandler.new.call(fresh_task, @bot) }

    assert_includes error.message, '503'
    assert_includes error.message, '[url]'
    refute_includes error.message, token
    refute_includes output.string, token
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_submit_uses_edit_template_when_input_image_present
    task = fresh_task(input_image: Base64.strict_encode64('fakebytes'))
    ImageGenTaskHandler.new.call(task, @bot)

    refute_empty FakeGptMaster.captured
    assert_match(/\[edit\]/, gpt_text(FakeGptMaster.captured.first))
  end

  def test_poll_dispatches_via_snapshot_then_marks_done
    task = fresh_task
    handler = ImageGenTaskHandler.new
    handler.call(task, @bot) # submits → :pending

    task.reload
    assert_equal 'fake', task.params_hash['provider']
    refute_nil task.external_id

    # Now poll. Adapter returns { url: ... } → handler delivers + marks done.
    handler.call(task, @bot)
    task.reload
    assert_equal 'done', task.status
    assert_equal 'completed', task.lifecycle_phase
    assert_equal 'delivered', task.delivery_status

    assert_equal [task.external_id], @fake_adapter.poll_calls
    assert_equal :sendPhoto, @bot.calls.last[0]
    assert Message.exists?(chat_id: -1, message_id: 2, role: 'bot'), 'delivery persisted before completion'
  end

  def test_async_image_process_failed_marks_delivery_failed_and_queues_agent_notice
    @bot.queue_photo_outcomes(telegram_error(400, 'Bad Request: IMAGE_PROCESS_FAILED'))
    task = fresh_task
    handler = ImageGenTaskHandler.new

    assert_equal :pending, handler.call(task, @bot)
    assert_equal :failed, handler.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'failed', persisted.status
    assert_equal 'failed', persisted.lifecycle_phase
    assert_equal 'failed', persisted.delivery_status
    assert_equal 'image_delivery_failed', persisted.result_hash['error']
    assert_equal '[url]', persisted.params_hash.dig('delivery_result', 'url')
    assert_equal 1, @fake_adapter.poll_calls.size, 'terminal generation result must not be polled again'
    assert_equal 1, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }

    event = BackgroundTask.where(task_type: 'agent_event')
      .detect { |candidate| candidate.params_hash['parent_task_id'] == task.id }
    assert_equal 'image_delivery_failed', event.params_hash['event_type']
    refute event.params_hash['user_notified']
    assert_includes event.params_hash['summary'], "Задача ##{task.id}"
  end

  def test_async_retryable_telegram_500_retries_delivery_without_repolling
    @bot.queue_photo_outcomes(
      telegram_error(500, 'Internal Server Error'),
      OpenStruct.new(message_id: 902, message_thread_id: nil)
    )
    task = fresh_task
    handler = ImageGenTaskHandler.new

    assert_equal :pending, handler.call(task, @bot) # submit
    assert_equal :pending, handler.call(task, @bot) # poll succeeds; Telegram 500
    retrying = BackgroundTask.find(task.id)
    assert_equal 'retrying', retrying.lifecycle_phase
    assert_equal 'pending', retrying.delivery_status
    assert_equal 1, retrying.retry_count
    assert_equal 1, @fake_adapter.poll_calls.size
    assert_equal :done, handler.call(task, @bot)    # cached result; delivery only

    assert_equal 1, @fake_adapter.poll_calls.size, 'delivery retry must not poll generation again'
    assert_equal 1, @fake_adapter.submit_calls.size
    assert_equal 2, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 'done', BackgroundTask.find(task.id).status
    assert_equal 'delivered', BackgroundTask.find(task.id).delivery_status
  end

  def test_malformed_truthy_send_photo_response_is_unconfirmed_delivery_failure
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/malformed.png' }
    @bot.queue_photo_outcomes({ 'ok' => true, 'result' => {} })
    task = fresh_task

    assert_equal :failed, ImageGenTaskHandler.new.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'image_delivery_failed', persisted.result_hash['error']
    refute persisted.params_hash.key?('delivery_receipt')
    refute persisted.params_hash.key?('persistence_failures')
    assert_equal 1, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    event = BackgroundTask.where(task_type: 'agent_event').last
    refute event.params_hash['user_notified']
  end

  def test_send_photo_requires_strict_positive_integer_message_id
    @fake_adapter.sync = true
    malformed_ids = ['902', 902.0, 0]

    malformed_ids.each_with_index do |message_id, index|
      @fake_adapter.submit_returns = { url: "http://x/malformed-#{index}.png" }
      @bot.queue_photo_outcomes(OpenStruct.new(message_id: message_id, message_thread_id: nil))
      task = fresh_task

      assert_equal :failed, ImageGenTaskHandler.new.call(task, @bot)
      persisted = BackgroundTask.find(task.id)
      assert_equal 'image_delivery_failed', persisted.result_hash['error']
      refute persisted.params_hash.key?('delivery_receipt')
    end
  end

  def test_async_hash_response_is_persisted_before_task_is_done
    @bot.queue_photo_outcomes(
      { 'result' => { 'message_id' => 901, 'message_thread_id' => 77,
                      'photo' => [{ 'file_id' => 'SMALL', 'width' => 320 }] } }
    )
    task = fresh_task
    handler = ImageGenTaskHandler.new

    handler.call(task, @bot)
    assert_equal :done, handler.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'done', persisted.status
    msg = Message.find_by(chat_id: -1, message_id: 901)
    refute_nil msg
    assert_equal 77, msg.message_thread_id
    assert_equal 'SMALL', msg.attachment_photo_file_id
    assert_equal persisted.external_id, msg.bg_task_external_id
  end

  def test_async_signed_completion_url_is_redacted_from_logs_and_terminal_task_state
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    signed_url = "https://images.example/out.png?token=#{token}"
    task = fresh_task
    handler = ImageGenTaskHandler.new
    assert_equal :pending, handler.call(task, @bot)
    @fake_adapter.poll_returns = { url: signed_url }
    output = StringIO.new
    original_logger = LOGGER
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    assert_equal :done, handler.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal({}, persisted.result_hash)
    refute persisted.params_hash.key?('delivery_result')
    refute_includes output.string, token
    refute_includes output.string, 'images.example'
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  # Synchronous adapter path: submit returns {url:, completed:true}, handler
  # short-circuits to delivery and marks the task done in ONE call (no
  # external_id written, poll_once never invoked).
  def test_synchronous_adapter_short_circuits_to_done
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/sync.png' }

    task = fresh_task
    result = ImageGenTaskHandler.new.call(task, @bot)

    assert_equal :done, result
    task.reload
    assert_equal 'done', task.status
    assert_nil task.external_id, 'synchronous adapter writes no external_id'
    assert_equal 'fake', task.params_hash['provider']
    assert_empty @fake_adapter.poll_calls, 'poll_once must not be called for synchronous adapter'
    assert_equal :sendPhoto, @bot.calls.last[0]
  end

  def test_synchronous_transient_delivery_failure_retries_without_regenerating
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/sync-retry.png' }
    @bot.queue_photo_outcomes(Faraday::TimeoutError.new('telegram timeout'),
                              OpenStruct.new(message_id: 903, message_thread_id: nil))
    task = fresh_task
    handler = ImageGenTaskHandler.new

    assert_equal :pending, handler.call(task, @bot)
    after_first = BackgroundTask.find(task.id)
    assert_equal 'pending', after_first.status
    assert_equal 'http://x/sync-retry.png', after_first.params_hash.dig('delivery_result', 'url')
    assert_equal 1, after_first.params_hash['delivery_failures']

    assert_equal :done, handler.call(task, @bot)
    assert_equal 'done', BackgroundTask.find(task.id).status
    assert_equal 1, @fake_adapter.submit_calls.size, 'delivery retry must not regenerate the image'
    assert_empty @fake_adapter.poll_calls
    assert_equal 2, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert Message.exists?(chat_id: -1, message_id: 903, role: 'bot')
  end

  def test_synchronous_image_process_failed_never_marks_done
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/sync-fail.png' }
    @bot.queue_photo_outcomes(RuntimeError.new('Bad Request: IMAGE_PROCESS_FAILED'))
    task = fresh_task

    assert_equal :failed, ImageGenTaskHandler.new.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'failed', persisted.status
    assert_equal 'image_delivery_failed', persisted.result_hash['error']
    assert_equal '[url]', persisted.params_hash.dig('delivery_result', 'url')
    assert_equal 1, @fake_adapter.submit_calls.size
    events = BackgroundTask.where(task_type: 'agent_event').map(&:params_hash)
    assert_equal 1, events.count { |p| p['parent_task_id'] == task.id && p['event_type'] == 'image_delivery_failed' }
  end

  def test_synchronous_transient_delivery_failures_are_bounded_across_cycles
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/sync-timeout.png' }
    @bot.queue_photo_outcomes(*Array.new(3) { Faraday::TimeoutError.new('telegram timeout') })
    task = fresh_task
    handler = ImageGenTaskHandler.new

    assert_equal :pending, handler.call(task, @bot)
    assert_equal :pending, handler.call(task, @bot)
    assert_equal :failed, handler.call(task, @bot)

    persisted = BackgroundTask.find(task.id)
    assert_equal 'failed', persisted.status
    assert_equal 3, persisted.params_hash['delivery_failures']
    assert_equal 1, @fake_adapter.submit_calls.size, 'bounded delivery retries must reuse the generated result'
    assert_equal 3, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    events = BackgroundTask.where(task_type: 'agent_event').map(&:params_hash)
    assert_equal 1, events.count { |p| p['parent_task_id'] == task.id && p['event_type'] == 'image_delivery_failed' }
  end

  def test_accepted_photo_with_persistence_nil_retries_persistence_without_resending
    @fake_adapter.sync = true
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    signed_url = "https://images.example/sync-persist.png?token=#{token}"
    @fake_adapter.submit_returns = {
      url: signed_url,
      provider_payload: { callback_url: "https://provider.example/callback?token=#{token}" }
    }
    task = fresh_task
    handler = ImageGenTaskHandler.new
    original = Message.method(:persist_bot_reply)
    Message.singleton_class.send(:define_method, :persist_bot_reply) { |**_| nil }

    assert_equal :pending, handler.call(task, @bot)
    first = BackgroundTask.find(task.id)
    assert_equal 2, first.params_hash.dig('delivery_receipt', 'message_id')
    refute first.params_hash.key?('delivery_result')
    refute_includes first.params, token
    refute_includes first.params, 'images.example'
    refute_includes first.params, 'provider.example'
    assert_equal 1, first.params_hash['persistence_failures']
    assert_equal 'retrying', first.lifecycle_phase
    assert_equal 'delivered', first.delivery_status
    assert_equal 1, first.retry_count
    assert_equal 1, @bot.calls.count { |kind, _| kind == :sendPhoto }

    assert_equal :pending, handler.call(task, @bot)
    assert_equal :failed, handler.call(task, @bot)
    persisted = BackgroundTask.find(task.id)
    assert_equal 'image_persistence_failed', persisted.result_hash['error']
    assert_equal 'failed', persisted.lifecycle_phase
    assert_equal 'delivered', persisted.delivery_status
    assert_equal 3, persisted.params_hash['persistence_failures']
    refute persisted.params_hash.key?('delivery_result')
    refute_includes persisted.params, token
    assert_equal 1, @bot.calls.count { |kind, _| kind == :sendPhoto }, 'receipt retry must never resend'
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    event = BackgroundTask.where(task_type: 'agent_event').last
    refute event.params_hash['user_notified']
  ensure
    Message.singleton_class.send(:define_method, :persist_bot_reply, original) if original
  end

  def test_recovery_event_failure_after_receipt_persistence_cannot_undo_success
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/recovered.png' }
    task = fresh_task
    p = task.params_hash
    p['generation_retries'] = 1
    task.update!(params: p.to_json)
    handler = ImageGenTaskHandler.new
    handler.define_singleton_method(:emit_agent_event) do |*_, **_kwargs|
      raise ActiveRecord::StatementInvalid, 'event insert failed https://db.example/?token=SECRET'
    end
    original_logger = LOGGER
    output = StringIO.new
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    assert_equal :done, handler.call(task, @bot)

    assert_equal 'done', BackgroundTask.find(task.id).status
    assert_equal 1, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    assert Message.exists?(chat_id: task.chat_id, role: 'bot',
                           bg_task_external_id: "image-task:#{task.id}")
    assert_includes output.string, '[url]'
    refute_includes output.string, 'db.example'
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_existing_persisted_delivery_reconciles_after_crash_without_resending
    task = fresh_task
    handler = ImageGenTaskHandler.new
    assert_equal :pending, handler.call(task, @bot)
    task.reload
    p = task.params_hash
    p['delivery_result'] = { 'url' => 'http://x/already-sent.png' }
    task.update!(params: p.to_json)
    Message.create!(role: 'bot', chat_id: task.chat_id, body: '[image]', message_id: 444,
                    bg_task_external_id: task.external_id)

    assert_equal :done, handler.call(task, @bot)
    assert_equal 'done', BackgroundTask.find(task.id).status
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_empty @fake_adapter.poll_calls
  end

  def test_recovery_event_failure_after_existing_message_reconciliation_cannot_undo_success
    task = fresh_task
    handler = ImageGenTaskHandler.new
    assert_equal :pending, handler.call(task, @bot)
    task.reload
    p = task.params_hash
    p['delivery_result'] = { 'url' => 'http://x/already-sent-recovered.png' }
    p['generation_retries'] = 2
    task.update!(params: p.to_json)
    Message.create!(role: 'bot', chat_id: task.chat_id, body: '[image]', message_id: 445,
                    bg_task_external_id: task.external_id)
    handler.define_singleton_method(:emit_agent_event) do |*_, **_kwargs|
      raise ActiveRecord::StatementInvalid, 'event insert failed https://db.example/?token=SECRET'
    end

    assert_equal :done, handler.call(task, @bot)

    assert_equal 'done', BackgroundTask.find(task.id).status
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendPhoto }
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
  end

  def test_forum_thread_is_used_for_photo_and_failure_event
    task = fresh_task(forum_thread_id: 73)
    @bot.queue_photo_outcomes(telegram_error(400, 'Bad Request: IMAGE_PROCESS_FAILED'))
    handler = ImageGenTaskHandler.new

    handler.call(task, @bot)
    assert_equal :failed, handler.call(task, @bot)

    photo_call = @bot.calls.find { |kind, _| kind == :sendPhoto }
    assert_equal 73, photo_call[1][:message_thread_id]
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    event = BackgroundTask.where(task_type: 'agent_event').last
    assert_equal 73, event.params_hash['forum_thread_id']
    refute event.params_hash['user_notified']
  end

  def test_event_queue_suppression_enqueues_durable_fallback
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/fail.png' }
    @bot.queue_photo_outcomes(telegram_error(400, 'Bad Request: IMAGE_PROCESS_FAILED'))
    task = fresh_task(forum_thread_id: 75)
    handler = ImageGenTaskHandler.new
    handler.define_singleton_method(:emit_agent_event) { |*_, **_| nil }

    assert_equal :failed, handler.call(task, @bot)

    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    notice = BackgroundTask.where(task_type: 'failure_notice').last
    refute_nil notice
    assert_equal task.id, notice.parent_task_id
    assert_match(/Telegram не смог/, notice.params_hash['text'])
    assert_equal 75, notice.params_hash['forum_thread_id']
    assert_empty BackgroundTask.where(task_type: 'agent_event')
  end

  def test_event_queue_exception_enqueues_durable_fallback
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/fail-notice.png' }
    @bot.queue_photo_outcomes(telegram_error(400, 'Bad Request: IMAGE_PROCESS_FAILED'))
    task = fresh_task
    handler = ImageGenTaskHandler.new
    handler.define_singleton_method(:emit_agent_event) do |*_, **_|
      raise ActiveRecord::StatementInvalid, 'event insert failed'
    end

    assert_equal :failed, handler.call(task, @bot)

    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    notice = BackgroundTask.where(task_type: 'failure_notice').last
    refute_nil notice
    assert_equal task.id, notice.parent_task_id
  end

  def test_durable_fallback_enqueue_is_idempotent_for_parent_task
    task = fresh_task
    handler = ImageGenTaskHandler.new

    first = handler.send(:enqueue_failure_notice, task, 'failed', nil)
    second = handler.send(:enqueue_failure_notice, task, 'failed again', nil)

    assert_equal first.id, second.id
    assert_equal 1, BackgroundTask.where(task_type: 'failure_notice', parent_task_id: task.id).count
  end

  def test_successful_forum_delivery_persists_in_originating_thread
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/forum.png' }
    task = fresh_task(forum_thread_id: 74)

    assert_equal :done, ImageGenTaskHandler.new.call(task, @bot)

    photo_call = @bot.calls.find { |kind, _| kind == :sendPhoto }
    assert_equal 74, photo_call[1][:message_thread_id]
    row = Message.find_by(chat_id: task.chat_id, message_id: 2)
    assert_equal 74, row.message_thread_id
    assert_equal "image-task:#{task.id}", row.bg_task_external_id
  end

  def test_real_telegram_response_codes_classify_429_and_5xx_as_retryable
    handler = ImageGenTaskHandler.new

    assert handler.send(:retryable_telegram_response?, telegram_error(429, 'Too Many Requests'))
    assert handler.send(:retryable_telegram_response?, telegram_error(502, 'Bad Gateway'))
    refute handler.send(:retryable_telegram_response?, telegram_error(400, 'IMAGE_PROCESS_FAILED'))
  end

  def test_non_json_telegram_error_log_redacts_bot_token_url
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/retry.png' }
    token = '123456789:FAKE_SECRET_TELEGRAM_TOKEN'
    response = Struct.new(:body, :status, :env).new(
      'upstream exploded', 502,
      OpenStruct.new(url: URI("https://api.telegram.org/bot#{token}/sendPhoto"))
    )
    @bot.queue_photo_outcomes(Telegram::Bot::Exceptions::ResponseError.new(response: response))

    original_logger = LOGGER
    output = StringIO.new
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))

    assert_equal :pending, ImageGenTaskHandler.new.call(fresh_task, @bot)
    refute_includes output.string, token
    assert_includes output.string, '[url]'
  ensure
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_download_metadata_controls_upload_mime_and_filename_and_tempfile_is_cleaned
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/image.png' }
    tmp = Tempfile.new(['delivery-test', '.png'])
    path = tmp.path
    handler = ImageGenTaskHandler.new
    handler.define_singleton_method(:download_to_tempfile) do |_url|
      { file: tmp, mime_type: 'image/png', filename: 'image.png' }
    end

    assert_equal :done, handler.call(fresh_task, @bot)

    upload = @bot.calls.find { |kind, _| kind == :sendPhoto }[1][:photo]
    assert_equal 'image/png', upload.content_type
    assert_equal 'image.png', upload.original_filename
    refute File.exist?(path), 'delivery tempfile must be unlinked after send'
  end

  def test_download_failure_redacts_signed_url_and_token_from_log
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    signed_url = "https://images.example/out.png?token=#{token}"
    original_get = HTTParty.method(:get)
    HTTParty.singleton_class.send(:define_method, :get) do |*_args, **_kwargs|
      raise RuntimeError, "download 502 from #{signed_url}"
    end
    original_logger = LOGGER
    output = StringIO.new
    Object.send(:remove_const, :LOGGER)
    Object.const_set(:LOGGER, Logger.new(output))
    handler = ImageGenTaskHandler.new
    original_download = @original_download_to_tempfile
    handler.define_singleton_method(:download_to_tempfile) do |url|
      original_download.bind_call(self, url)
    end

    assert_nil handler.send(:download_to_tempfile, signed_url)
    assert_includes output.string, '[url]'
    refute_includes output.string, token
    refute_includes output.string, 'images.example'
  ensure
    HTTParty.singleton_class.send(:define_method, :get, original_get) if defined?(original_get) && original_get
    if defined?(original_logger) && original_logger
      Object.send(:remove_const, :LOGGER) if Object.const_defined?(:LOGGER)
      Object.const_set(:LOGGER, original_logger)
    end
  end

  def test_poll_retry_path_clears_external_id_and_increments_counter
    task = fresh_task
    @fake_adapter.poll_returns = :retry

    handler = ImageGenTaskHandler.new
    handler.call(task, @bot) # submit
    task.reload
    original_extid = task.external_id

    handler.call(task, @bot) # poll → :retry
    task.reload
    assert_nil task.external_id, 'external_id cleared so handler re-submits next cycle'
    assert_equal 1, task.params_hash['generation_retries']
    assert_equal 'pending', task.status
    refute_nil original_extid
  end

  def test_provider_failure_reason_reaches_agent_event_sanitized
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    task = fresh_task
    handler = ImageGenTaskHandler.new
    assert_equal :pending, handler.call(task, @bot)
    @fake_adapter.poll_returns = {
      failed: true,
      error: "content safety policy rejected at https://provider.example/job/1 token=#{token}",
    }

    assert_equal :failed, handler.call(task, @bot)

    event = BackgroundTask.where(task_type: 'agent_event').last
    summary = event.params_hash['summary']
    assert_includes summary, 'content safety policy rejected'
    assert_includes summary, '[url]'
    assert_includes summary, 'token=[redacted]'
    refute_includes summary, token
    refute_includes summary, 'provider.example'
  end

  def test_poll_exception_is_redacted_before_rethrow_without_losing_status_classification
    token = 'ABCDEFGHIJKLMNOPQRSTUVWX12345678'
    task = fresh_task
    handler = ImageGenTaskHandler.new
    assert_equal :pending, handler.call(task, @bot)
    @fake_adapter.poll_returns = RuntimeError.new(
      "provider 503 https://provider.example/status?token=#{token}"
    )

    error = assert_raises(RuntimeError) { handler.call(task, @bot) }

    assert_includes error.message, '503'
    assert_includes error.message, '[url]'
    refute_includes error.message, token
  end

  def telegram_error(code, description)
    response = Faraday::Response.new(
      status: code,
      response_body: { ok: false, error_code: code, description: description }.to_json
    )
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  # --- per-request model selection (catalog) --------------------------------

  # A task carrying a catalog model key threads the entry's provider-specific
  # t2i id into adapter.submit(model:) and snapshots the key into params.
  def test_model_key_threads_catalog_t2i_into_submit
    task = fresh_task(model: 'wan-2.7')
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'alibaba/wan-2.7-pro/text-to-image', @fake_adapter.submit_calls.first[:model]
    task.reload
    assert_equal 'wan-2.7', task.params_hash['model'], 'model key snapshotted for forensics'
    # model_name interpolated into the enrichment prompt
    assert_match(/model=wan-2\.7/, gpt_text(FakeGptMaster.captured.first))
  end

  # Edit mode threads the catalog edit id.
  def test_model_key_threads_catalog_edit_id
    task = fresh_task(model: 'wan-2.7', input_image: Base64.strict_encode64('fakebytes'))
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'alibaba/wan-2.7/image-edit', @fake_adapter.submit_calls.first[:model]
  end

  # Legacy/no-model task → current_adapter path, model: nil (today's behavior).
  def test_legacy_task_without_model_passes_nil_model
    task = fresh_task # no model key
    ImageGenTaskHandler.new.call(task, @bot)
    assert_nil @fake_adapter.submit_calls.first[:model]
    task.reload
    assert_equal 'fake', task.params_hash['provider']
    refute task.params_hash.key?('model'), 'no model snapshot for legacy tasks'
  end

  # A stored model key that isn't in the catalog resolves to the default's t2i id.
  def test_unknown_model_key_resolves_to_default_t2i
    task = fresh_task(model: 'bogus')
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'google/nano-banana-2/text-to-image', @fake_adapter.submit_calls.first[:model]
  end

  # Catalog entry with a provider not in ImageGen::ADAPTERS → re-resolve to the
  # default KEY so adapter and model id stay coherent (finding #6).
  def test_unknown_provider_reresolves_to_default_key
    task = fresh_task(model: 'bad-provider')
    ImageGenTaskHandler.new.call(task, @bot)
    assert_includes @fake_adapter.adapter_for_args, 'atlas', 'rebuilds default model provider adapter'
    assert_equal 'google/nano-banana-2/text-to-image', @fake_adapter.submit_calls.first[:model]
    task.reload
    assert_equal 'nano-banana-2', task.params_hash['model'], 'snapshot re-resolved to default key'
  end

  # Selection dispatches the adapter by the ENTRY's provider, not the global one.
  def test_model_key_dispatches_by_entry_provider
    task = fresh_task(model: 'flux-2-pro')  # entry provider 'flux' ≠ global 'atlas'
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'flux', @fake_adapter.adapter_for_args.last
  end

  # Award task (made by make_award) carries no model key; the Atlas template's
  # %{model_name} must still interpolate (no KeyError) with the generic fallback.
  def test_award_task_without_model_interpolates_default_model_name
    @fake_adapter.sync = true
    @fake_adapter.submit_returns = { url: 'http://x/award.png' }
    task = fresh_task(award: true)
    assert_equal :done, ImageGenTaskHandler.new.call(task, @bot)  # would raise KeyError pre-fix
    assert_match(/model=AI image generator/, gpt_text(FakeGptMaster.captured.first))
    assert_match(/🏆/, @bot.calls.last[1][:caption])
  end

  # --- multi-image edit sourcing (inline + chat history) --------------------

  # A legacy single-image task (input_image, enqueued before this deploy) still
  # resolves into the input_images array the adapter now expects.
  def test_legacy_input_image_resolves_into_input_images
    b64 = Base64.strict_encode64('fakebytes')
    task = fresh_task(model: 'nano-banana-2', input_image: b64)
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal [{ data: b64, media_type: 'image/jpeg' }], @fake_adapter.submit_calls.first[:input_images]
  end

  # History photo referenced by message_id is resolved (DB → file_id → download)
  # in the handler and passed as an edit source.
  def test_source_message_id_downloads_and_edits
    Message.create!(chat_id: -1, message_id: 555, role: 'user', body: '[фото]', user_uid: 7,
                    attachment_photo_file_id: 'FID1')
    task = fresh_task(model: 'nano-banana-2', source_message_ids: [555])
    ImageGenTaskHandler.new.call(task, @bot)
    imgs = @fake_adapter.submit_calls.first[:input_images]
    assert_equal [{ data: 'DL_FID1', media_type: 'image/jpeg' }], imgs
    assert_match(/\[edit\]/, gpt_text(FakeGptMaster.captured.first), 'history image makes it an edit')
  end

  # Inline image (current/reply) comes first, then history images, in order.
  def test_inline_and_history_combined_inline_first
    Message.create!(chat_id: -1, message_id: 710, role: 'user', body: '[фото]', user_uid: 7,
                    attachment_photo_file_id: 'FIDH')
    task = fresh_task(model: 'nano-banana-2',
                      input_images: [{ 'data' => 'INLINE', 'media_type' => 'image/png' }],
                      source_message_ids: [710])
    ImageGenTaskHandler.new.call(task, @bot)
    imgs = @fake_adapter.submit_calls.first[:input_images]
    assert_equal 'INLINE',     imgs[0][:data], 'inline/current image first'
    assert_equal 'image/png',  imgs[0][:media_type]
    assert_equal 'DL_FIDH',    imgs[1][:data]
  end

  # A stale/missing message_id (no stored photo) is skipped; the rest proceed.
  def test_stale_source_message_id_skipped_others_proceed
    Message.create!(chat_id: -1, message_id: 600, role: 'user', body: '[фото]', user_uid: 7,
                    attachment_photo_file_id: 'FID2')
    # 601 has no message row → no file_id → skipped.
    task = fresh_task(model: 'nano-banana-2', source_message_ids: [601, 600])
    ImageGenTaskHandler.new.call(task, @bot)
    imgs = @fake_adapter.submit_calls.first[:input_images]
    assert_equal [{ data: 'DL_FID2', media_type: 'image/jpeg' }], imgs
  end

  # Edit was requested but NOTHING usable resolved → fail into the agent
  # loop, never silently regenerate from scratch (the bug class being killed).
  def test_edit_intended_but_all_sources_unavailable_queues_agent_event
    task = fresh_task(model: 'nano-banana-2', source_message_ids: [999]) # no message row
    result = ImageGenTaskHandler.new.call(task, @bot)
    assert_equal :failed, result
    task.reload
    assert_equal 'failed', task.status
    assert_empty @fake_adapter.submit_calls, 'must not submit a text-to-image fallback'
    assert_equal 0, @bot.calls.count { |kind, _| kind == :sendMessage }
    event = BackgroundTask.where(task_type: 'agent_event').last
    assert_equal 'image_failed', event.params_hash['event_type']
    refute event.params_hash['user_notified']
    assert_includes event.params_hash['summary'], 'edit sources unavailable'
  end
end

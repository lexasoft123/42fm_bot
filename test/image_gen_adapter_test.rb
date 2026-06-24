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
    assert_match(/FLUX 2 AI/, adapter.prompt_template(:text_to_image))
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
    assert_equal :failed, out
  end

  def test_poll_unknown_status_logs_once_returns_pending
    fake = FakeModelProviderClient.new(get_returns: [200, { 'data' => { 'status' => 'mystery_state' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('uniq-id-mystery') }
    assert_equal :pending, out
  end

  def test_poll_transient_ssl_returns_pending
    # ModelProviderClient#get returns [nil, nil] on SSL/timeout. Adapter treats as :pending.
    fake = FakeModelProviderClient.new(get_returns: [nil, nil])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_completed_without_outputs_returns_failed
    # Defensive: status says done but no URL means we can't deliver. Mark
    # failed rather than crash later trying to download nothing.
    body = { 'data' => { 'status' => 'completed', 'outputs' => [] } }
    fake = FakeModelProviderClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :failed, out
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

  def test_prompt_template_edit_mode_is_imperative_and_model_agnostic
    fake = FakeModelProviderClient.new
    template = with_fake_client(fake) { ImageGen::AtlasAdapter.new.prompt_template(:edit) }
    assert_match(/%\{model_name\}/, template)
    refute_match(/Wan/, template, 'edit template model name must be de-hardcoded')
    assert_match(/повелительно/, template)
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

  def test_prompt_template_mentions_nano_banana
    fake = FakeModelProviderClient.new
    template = with_fake_client(fake) { ImageGen::CloseRouterImgAdapter.new.prompt_template(:text_to_image) }
    assert_match(/Nano Banana/, template)
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
    @submit_returns
  end

  def poll_once(external_id)
    @poll_calls << external_id
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
    @@settings = []
    def self.captured; @@captured; end
    def self.settings; @@settings; end
    def self.reset!; @@captured = []; @@settings = []; end
    def initialize(messages, **kw); @@captured << messages; @@settings << kw[:setting]; end
    def call; 'enriched prompt'; end
  end

  class FakeBotApi
    attr_reader :calls
    def initialize; @calls = []; end
    def sendMessage(**kw); @calls << [:sendMessage, kw]; OpenStruct.new(message_id: 1, message_thread_id: nil); end
    def sendPhoto(**kw);   @calls << [:sendPhoto, kw];   OpenStruct.new(message_id: 2, message_thread_id: nil); end
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
      define_method(:get_chat_context)        { |_| 'ctx' }
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
    Settings.image_gen = nil
    ImageGen::Catalog.reset!
    super
  end

  def fresh_task(input_image: nil, input_images: nil, source_message_ids: nil, model: nil, award: false)
    params = { 'request' => 'кот в шляпе', 'user_uid' => 42 }
    params['input_image']        = input_image if input_image
    params['input_media_type']   = 'image/jpeg' if input_image
    params['input_images']       = input_images if input_images
    params['source_message_ids'] = source_message_ids if source_message_ids
    params['model'] = model if model
    params['award'] = true  if award
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

    # Template selection: handler asked adapter for :text_to_image template,
    # which our FakeAdapter prefixes with [text_to_image] — that string
    # appears in the LLM prompt FakeGptMaster captured.
    refute_empty FakeGptMaster.captured
    assert_match(/\[text_to_image\]/, gpt_text(FakeGptMaster.captured.first))
  end

  # Regression: prompt enrichment for image-edit MUST go to a vision-capable
  # provider. Pre-fix, the handler hardcoded `setting: 'agent'` (DeepSeek),
  # which rejects the {type: 'image', source: {...}} content block with
  # `400 unknown variant 'image', expected 'text'`. Fix routes editing to
  # `agent_vision` (grok-4-fast-reasoning today; Anthropic-shape blocks are
  # auto-translated to OpenAI shape at the GptMaster boundary) and keeps
  # text-to-image on the cheaper `agent` setting where no image is sent.
  def test_image_edit_uses_agent_vision_setting
    task = fresh_task(input_image: Base64.strict_encode64('fakebytes'))
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'agent_vision', FakeGptMaster.settings.first,
      'image-edit prompt enrichment must use agent_vision; DeepSeek rejects vision content blocks'
  end

  def test_text_to_image_uses_agent_setting
    task = fresh_task # no image
    ImageGenTaskHandler.new.call(task, @bot)
    assert_equal 'agent', FakeGptMaster.settings.first,
      'text-to-image prompt enrichment stays on cheap `agent` (DeepSeek)'
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

    assert_equal [task.external_id], @fake_adapter.poll_calls
    assert_equal :sendPhoto, @bot.calls.last[0]
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

  # Edit was requested but NOTHING usable resolved → fail with a user-facing
  # notice, never silently regenerate from scratch (the bug class being killed).
  def test_edit_intended_but_all_sources_unavailable_fails_with_notice
    task = fresh_task(model: 'nano-banana-2', source_message_ids: [999]) # no message row
    result = ImageGenTaskHandler.new.call(task, @bot)
    assert_equal :failed, result
    task.reload
    assert_equal 'failed', task.status
    assert_empty @fake_adapter.submit_calls, 'must not submit a text-to-image fallback'
    msg = @bot.calls.find { |c| c[0] == :sendMessage }
    assert msg, 'a failure notice was sent to the chat'
    assert_match(/редактирован/i, msg[1][:text])
  end
end

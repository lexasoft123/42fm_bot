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

require_relative '../lib/atlas_client'
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

# AtlasAdapter — stubs AtlasClient at the class level (not HTTParty) so we
# test adapter logic above the HTTP layer; AtlasClient itself is covered by
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

  class FakeAtlasClient
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
    real = AtlasClient.method(:new)
    AtlasClient.singleton_class.send(:define_method, :new) { |_cfg, **_| client }
    yield
  ensure
    AtlasClient.singleton_class.send(:define_method, :new, real)
  end

  # submit -----------------------------------------------------------

  def test_submit_text_to_image_sends_correct_body_shape
    # Live probe 2026-04-30: flat shape, NOT input.{} wrapper.
    fake = FakeAtlasClient.new(post_returns: { 'data' => { 'id' => 'abc' } })
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

  def test_submit_image_edit_uses_edit_model_and_data_uri
    fake = FakeAtlasClient.new(post_returns: { 'data' => { 'id' => 'edit-id' } })
    id = with_fake_client(fake) do
      ImageGen::AtlasAdapter.new.submit(
        prompt: 'add sunglasses',
        input_image: 'BASE64BYTES',
        input_media_type: 'image/png'
      )
    end
    assert_equal 'edit-id', id

    _, _, body = fake.calls.first
    assert_equal 'alibaba/wan-2.7/image-edit', body[:model]
    assert_equal 'add sunglasses', body[:prompt]
    assert_equal 'data:image/png;base64,BASE64BYTES', body[:image]
    refute body.key?(:width),  'image-edit body should not include width'
    refute body.key?(:height), 'image-edit body should not include height'
  end

  def test_submit_handles_unwrapped_id_response_shape
    # Defensive: if Atlas ever returns the id at top level instead of data.id.
    fake = FakeAtlasClient.new(post_returns: { 'id' => 'top-level' })
    id = with_fake_client(fake) { ImageGen::AtlasAdapter.new.submit(prompt: 'x') }
    assert_equal 'top-level', id
  end

  def test_submit_raises_when_no_id_field_found
    fake = FakeAtlasClient.new(post_returns: { 'something_else' => 'oops' })
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

    fake = FakeAtlasClient.new(post_returns: { 'data' => { 'id' => 'x' } })
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
    fake = FakeAtlasClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('pred-1') }
    assert_equal({ url: 'https://x.png' }, out)
    assert_equal '/api/v1/model/prediction/pred-1', fake.calls.first[1]
  end

  def test_poll_succeeded_returns_url
    body = { 'data' => { 'status' => 'succeeded', 'outputs' => ['https://y.png'] } }
    fake = FakeAtlasClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('pred-1') }
    assert_equal({ url: 'https://y.png' }, out)
  end

  def test_poll_processing_returns_pending
    fake = FakeAtlasClient.new(get_returns: [200, { 'data' => { 'status' => 'processing' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_queued_returns_pending
    fake = FakeAtlasClient.new(get_returns: [200, { 'data' => { 'status' => 'queued' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_failed_returns_failed
    body = { 'code' => 400, 'data' => { 'status' => 'failed', 'error' => 'oops' } }
    fake = FakeAtlasClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :failed, out
  end

  def test_poll_unknown_status_logs_once_returns_pending
    fake = FakeAtlasClient.new(get_returns: [200, { 'data' => { 'status' => 'mystery_state' } }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('uniq-id-mystery') }
    assert_equal :pending, out
  end

  def test_poll_transient_ssl_returns_pending
    # AtlasClient#get returns [nil, nil] on SSL/timeout. Adapter treats as :pending.
    fake = FakeAtlasClient.new(get_returns: [nil, nil])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :pending, out
  end

  def test_poll_completed_without_outputs_returns_failed
    # Defensive: status says done but no URL means we can't deliver. Mark
    # failed rather than crash later trying to download nothing.
    body = { 'data' => { 'status' => 'completed', 'outputs' => [] } }
    fake = FakeAtlasClient.new(get_returns: [200, body])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal :failed, out
  end

  def test_poll_tolerates_unwrapped_response_shape
    # If Atlas ever returns the prediction at top level (instead of data.{}),
    # adapter still handles it.
    fake = FakeAtlasClient.new(get_returns: [200, { 'status' => 'completed', 'outputs' => ['https://z.png'] }])
    out = with_fake_client(fake) { ImageGen::AtlasAdapter.new.poll_once('p') }
    assert_equal({ url: 'https://z.png' }, out)
  end

  # prompt_template --------------------------------------------------

  def test_prompt_template_text_to_image_mentions_wan_and_has_placeholders
    fake = FakeAtlasClient.new
    template = with_fake_client(fake) { ImageGen::AtlasAdapter.new.prompt_template(:text_to_image) }
    assert_match(/Wan 2\.7/, template)
    assert_match(/%\{request\}/, template)
    assert_match(/%\{context\}/, template)
    assert_match(/%\{knowledge\}/, template)
    refute_match(/FLUX 2 приоритизирует/, template, 'should drop FLUX-specific guidance')
  end

  def test_prompt_template_edit_mode_is_imperative
    fake = FakeAtlasClient.new
    template = with_fake_client(fake) { ImageGen::AtlasAdapter.new.prompt_template(:edit) }
    assert_match(/image-edit/, template)
    assert_match(/Wan/, template)
    assert_match(/%\{request\}/, template)
  end
end

# FakeAdapter — captures calls + returns canned results so we can drive the
# real ImageGenTaskHandler without hitting any backend.
class FakeAdapter < ImageGen::Adapter
  NAME = 'fake'
  attr_accessor :submit_calls, :poll_calls, :submit_returns, :poll_returns

  def initialize(submit_returns: 'fake-extid', poll_returns: { url: 'http://x/img.jpg' })
    @submit_calls   = []
    @poll_calls     = []
    @submit_returns = submit_returns
    @poll_returns   = poll_returns
  end

  def submit(prompt:, input_image: nil, input_media_type: nil)
    @submit_calls << { prompt: prompt, input_image: input_image, input_media_type: input_media_type }
    @submit_returns
  end

  def poll_once(external_id)
    @poll_calls << external_id
    @poll_returns
  end

  def prompt_template(mode)
    "[#{mode}] %{request} | %{context} | %{knowledge}"
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
    def self.captured; @@captured; end
    def self.reset!; @@captured = []; end
    def initialize(messages, **_); @@captured << messages; end
    def call; 'enriched prompt'; end
  end

  class FakeBotApi
    attr_reader :calls
    def initialize; @calls = []; end
    def sendMessage(**kw); @calls << [:sendMessage, kw]; OpenStruct.new(message_id: 1, message_thread_id: nil); end
    def sendPhoto(**kw);   @calls << [:sendPhoto, kw];   OpenStruct.new(message_id: 2, message_thread_id: nil); end
  end

  def setup
    super
    @fake_adapter = FakeAdapter.new
    @bot          = FakeBotApi.new
    @original_gpt = ::GptMaster if defined?(::GptMaster)
    Object.send(:remove_const, :GptMaster) if defined?(::GptMaster)
    Object.const_set(:GptMaster, FakeGptMaster)
    FakeGptMaster.reset!

    ImageGen.singleton_class.send(:alias_method, :__current_adapter, :current_adapter)
    ImageGen.singleton_class.send(:alias_method, :__adapter_for,     :adapter_for)
    fa = @fake_adapter
    ImageGen.define_singleton_method(:current_adapter) { fa }
    ImageGen.define_singleton_method(:adapter_for)     { |_n| fa }

    # Stub away ChatContext lookups + tempfile download (forces sendPhoto's
    # URL-fallback path so we don't need a real image to deliver).
    ImageGenTaskHandler.class_eval do
      define_method(:get_chat_context)        { |_| 'ctx' }
      define_method(:get_relevant_knowledge)  { |_, _| 'kn' }
      define_method(:download_to_tempfile)    { |_url| nil }
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
    super
  end

  def fresh_task(input_image: nil)
    params = { 'request' => 'кот в шляпе', 'user_uid' => 42 }
    params['input_image']      = input_image if input_image
    params['input_media_type'] = 'image/jpeg' if input_image
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
end

require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# High image rate limit so the tool never short-circuits to a deferred result.
unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    { 'rate_limits' => { 'image' => { 'max' => 100, 'window_minutes' => 60 } } }
  }
end
unless Settings.respond_to?(:replies)
  Settings.singleton_class.send(:define_method, :replies) { {} }
end
unless Settings.respond_to?(:image_gen)
  Settings.singleton_class.send(:define_method, :image_gen) { @image_gen }
  Settings.singleton_class.send(:define_method, :image_gen=) { |v| @image_gen = v }
end

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/image_gen'
require_relative '../lib/agent/tools/image_gen'

# The tool reads ImageGen::MAX_EDIT_IMAGES; assert it's defined for the cap test.

class GenerateImageToolTest < BotTest
  CHAT = -1234567899

  CATALOG = {
    'provider' => 'atlas',
    'default_model' => 'nano-banana-2',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'multi_image' => true, 'desc' => 'NB2' },
      'wan-2.7'       => { 'provider' => 'atlas', 't2i' => 'alibaba/wan-2.7-pro/text-to-image',
                           'edit' => 'alibaba/wan-2.7/image-edit', 'desc' => 'Wan' },
    },
  }.freeze

  def setup
    super
    Settings.image_gen = Marshal.load(Marshal.dump(CATALOG))
    ImageGen::Catalog.reset!
    @tool = Agent::ToolRegistry.find('generate_image')
    @user = OpenStruct.new(uid: 999, role: 'member')
  end

  def teardown
    Settings.image_gen = nil
    ImageGen::Catalog.reset!
    super
  end

  def call_tool(args)
    @tool.handler.call(args, { chat_id: CHAT, user: @user })
  end

  def last_params
    BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').last.params_hash
  end

  def test_valid_model_key_persisted
    call_tool('prompt' => 'кот', 'model' => 'wan-2.7')
    assert_equal 'wan-2.7', last_params['model']
    assert_equal 'кот',     last_params['request']
  end

  def test_omitted_model_defaults_to_catalog_default
    call_tool('prompt' => 'кот')
    assert_equal 'nano-banana-2', last_params['model']
  end

  def test_invalid_model_falls_back_to_default
    call_tool('prompt' => 'кот', 'model' => 'midjourney')
    assert_equal 'nano-banana-2', last_params['model']
  end

  # --- multi-image / chat-history sourcing ----------------------------------

  def test_source_message_ids_persisted
    call_tool('prompt' => 'объедини', 'source_message_ids' => [10, 11])
    assert_equal [10, 11], last_params['source_message_ids']
  end

  # >1 source image + a model that can't combine (wan) → switch to the capable
  # default so the user actually gets a combine.
  def test_combine_switches_incapable_model_to_capable_default
    call_tool('prompt' => 'объедини', 'model' => 'wan-2.7', 'source_message_ids' => [10, 11])
    assert_equal 'nano-banana-2', last_params['model']
    assert_equal [10, 11], last_params['source_message_ids']
  end

  # A single source image needs no combine — keep the agent's model choice.
  def test_single_source_keeps_chosen_model
    call_tool('prompt' => 'правка', 'model' => 'wan-2.7', 'source_message_ids' => [10])
    assert_equal 'wan-2.7', last_params['model']
  end

  # Total source images capped at ImageGen::MAX_EDIT_IMAGES.
  def test_source_message_ids_capped
    call_tool('prompt' => 'много', 'model' => 'nano-banana-2', 'source_message_ids' => (1..10).to_a)
    assert_equal ImageGen::MAX_EDIT_IMAGES, last_params['source_message_ids'].length
  end

  # Zero/blank ids are dropped; no source_message_ids key when none survive.
  def test_blank_source_message_ids_dropped
    call_tool('prompt' => 'кот', 'source_message_ids' => [0])
    refute last_params.key?('source_message_ids')
  end

  # edit_source + an attached photo (ctx[:image]) → stored as input_images.
  def test_edit_source_inline_image_becomes_input_images
    ctx = { chat_id: CHAT, user: @user, image: { data: 'INLINEB64', media_type: 'image/png' } }
    @tool.handler.call({ 'prompt' => 'дорисуй', 'edit_source' => true }, ctx)
    assert_equal [{ 'data' => 'INLINEB64', 'media_type' => 'image/png' }], last_params['input_images']
  end

  # Inline image consumes one slot of the cap; history ids fill the rest.
  def test_inline_plus_history_capped_at_max
    ctx = { chat_id: CHAT, user: @user, image: { data: 'INLINE', media_type: 'image/jpeg' } }
    ids = (1..(ImageGen::MAX_EDIT_IMAGES + 2)).to_a
    @tool.handler.call({ 'prompt' => 'комбо', 'model' => 'nano-banana-2',
                         'edit_source' => true, 'source_message_ids' => ids }, ctx)
    assert_equal ImageGen::MAX_EDIT_IMAGES - 1, last_params['source_message_ids'].length,
      'inline image takes one slot; source ids trimmed to fill the rest'
  end

  # definitions_for builds the model enum from the catalog and marks model +
  # edit_source optional (not required), while prompt stays required.
  def test_definitions_build_model_enum_and_required_array
    %w[anthropic openai].each do |api|
      defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: api)
      d = defs.find { |x| (api == 'anthropic' ? x[:name] : x[:function][:name]) == 'generate_image' }
      refute_nil d, "#{api}: generate_image must be present"
      schema = api == 'anthropic' ? d[:input_schema] : d[:function][:parameters]
      assert_equal %w[nano-banana-2 wan-2.7], schema[:properties]['model'][:enum], "#{api}: enum from catalog"
      assert_match(/NB2/, schema[:properties]['model'][:description], "#{api}: desc suffix appended")
      assert_includes schema[:required], 'prompt', "#{api}: prompt required"
      refute_includes schema[:required], 'model', "#{api}: model optional"
      refute_includes schema[:required], 'edit_source', "#{api}: edit_source optional"
      refute_includes schema[:required], 'source_message_ids', "#{api}: source_message_ids optional"
      assert_equal 'array', schema[:properties]['source_message_ids'][:type], "#{api}: source_message_ids is an array"
    end
  end
end

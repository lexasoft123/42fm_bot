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

class GenerateImageToolTest < BotTest
  CHAT = -1234567899

  CATALOG = {
    'provider' => 'atlas',
    'default_model' => 'nano-banana-2',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'desc' => 'NB2' },
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
    end
  end
end

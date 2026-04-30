require_relative 'test_helper'

require 'ostruct'

# Setup production-like Settings (not the minimal test_helper stub)
Object.send(:remove_const, :Settings) if defined?(Settings)
require_relative '../lib/settings'

# Load a minimal live Settings with pricing + agent prompt using cache-break
Settings.instance_variable_set(:@_settings, OpenStruct.new(
  telegram: { 'token' => '123:abc' },
  chat_gpt: {
    'agent_prompt' => "STATIC PREFIX BLAH\n{CACHE_BREAK}\nKnowledge: {KNOWLEDGE}\nContext: {CONTEXT}\nRequest: {REQUEST}",
    'providers' => { 'anthropic' => { 'api_key' => 'k', 'api_type' => 'anthropic' } },
    'settings'  => {
      'main'  => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6', 'max_tokens' => 100 },
      'agent' => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6', 'max_tokens' => 100 },
    },
    'pricing' => {
      'claude-sonnet-4-6' => { 'input' => 3, 'output' => 15, 'cache_read' => 0.30, 'cache_write' => 3.75 },
    },
  }
))

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require 'httparty'
require_relative '../models/api_usage'
require_relative '../lib/gpt_master'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/runner'

class FakeResponse2
  def initialize(body)
    @body = body
  end
  def code; 200; end
  def body; @body.to_json; end
  def parsed_response; @body; end
  def [](key); @body[key]; end
  def dig(*keys); @body.dig(*keys); end
end

def anthropic_body(text, usage)
  {
    'content' => [{ 'type' => 'text', 'text' => text }],
    'stop_reason' => 'end_turn',
    'usage' => usage,
  }
end

class E2EAgentCachingTest < BotTest
  def setup
    super
    @user = OpenStruct.new(name: 'bob', role: 'member')
    @saved_tools = Agent::ToolRegistry.instance_variable_get(:@tools)&.dup || []
    Agent::ToolRegistry.instance_variable_set(:@tools, [])
  end

  def teardown
    Agent::ToolRegistry.instance_variable_set(:@tools, @saved_tools)
    super
  end

  def run_agent(knowledge: '', context: '')
    Agent::Runner.new(
      text: 'hi', context: context, knowledge: knowledge,
      radio: nil, chat_id: -555, user: @user, bot: nil,
      image: nil, phrase: nil
    ).run
  end

  def test_two_sequential_agent_calls_record_cache_write_then_cache_read
    # 1st call: all input new → cache_creation > 0, cache_read = 0
    body1 = anthropic_body('reply1', {
      'input_tokens' => 50, 'output_tokens' => 10,
      'cache_creation_input_tokens' => 800, 'cache_read_input_tokens' => 0,
    })
    # 2nd call: same static prefix → input is tiny, cache_read > 0
    body2 = anthropic_body('reply2', {
      'input_tokens' => 20, 'output_tokens' => 10,
      'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 800,
    })
    queue = [FakeResponse2.new(body1), FakeResponse2.new(body2)]
    HTTParty.define_singleton_method(:post) { |*_| queue.shift }
    begin
      assert_equal 'reply1', run_agent(knowledge: 'k1')
      assert_equal 'reply2', run_agent(knowledge: 'k2')
    ensure
      HTTParty.singleton_class.remove_method(:post)
    end

    rows = ApiUsage.where(chat_id: -555).order(:created_at).to_a
    assert_equal 2, rows.size
    assert rows[0].cache_write_tokens > 0, 'first call should record cache_write'
    assert_equal 0, rows[0].cache_read_tokens
    assert rows[1].cache_read_tokens > 0, 'second call should hit cache (cache_read)'
    assert_equal 0, rows[1].cache_write_tokens
    assert rows[1].cost_cents < rows[0].cost_cents, 'caching should make 2nd call cheaper'
    assert_equal 'agent', rows[0].purpose
    assert_equal 'agent', rows[1].purpose
  end

  def test_agent_request_body_includes_cache_control_on_system
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse2.new(anthropic_body('x', {
        'input_tokens' => 1, 'output_tokens' => 1,
        'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0,
      }))
    end
    begin
      run_agent
    ensure
      HTTParty.singleton_class.remove_method(:post)
    end
    # System must be an array with cache_control on the single text block
    assert_kind_of Array, captured['system']
    assert_equal 'ephemeral', captured['system'].first['cache_control']['type']
    assert_includes captured['system'].first['text'], 'STATIC PREFIX'
    # Dynamic user message must NOT contain the static prefix
    user = captured['messages'].first['content']
    refute_includes user, 'STATIC PREFIX'
    assert_includes user, 'Request: hi'
  end
end

class E2ETranslateTest < BotTest
  def test_translate_records_with_translate_purpose_no_cache_split
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse2.new(anthropic_body('перевод', {
        'input_tokens' => 10, 'output_tokens' => 5,
        'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0,
      }))
    end
    begin
      GptMaster.ask('hello', prompt: 'Translate to RU: {REQUEST}', setting: 'agent', chat_id: 7, purpose: 'translate')
    ensure
      HTTParty.singleton_class.remove_method(:post)
    end
    row = ApiUsage.first
    assert_equal 'translate', row.purpose
    assert_equal 7, row.chat_id
    # .ask does NOT split on CACHE_BREAK
    refute captured.key?('system')
  end
end

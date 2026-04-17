require_relative 'test_helper'

# Stub Settings before loading gpt_master
module Settings
  @chat_gpt = {
    'prompt' => "STATIC PREFIX\n{CACHE_BREAK}\nKnowledge: {KNOWLEDGE}\nContext: {CONTEXT}\nRequest: {REQUEST}",
    'providers' => {
      'anthropic' => { 'api_key' => 'k', 'api_type' => 'anthropic' },
      'openai'    => { 'api_key' => 'k', 'api_type' => 'openai' },
    },
    'settings' => {
      'main'    => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6', 'max_tokens' => 100 },
      'agent'   => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6', 'max_tokens' => 100 },
      'legacy_thinking' => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6', 'max_tokens' => 100, 'thinking_budget' => 1600 },
      'adaptive_thinking' => { 'provider' => 'anthropic', 'model' => 'claude-opus-4-7', 'max_tokens' => 100, 'thinking' => { 'type' => 'adaptive' }, 'output_config' => { 'effort' => 'high' } },
      'openai'  => { 'provider' => 'openai',    'model' => 'gpt-4' },
    },
    'pricing' => {
      'claude-sonnet-4-6' => { 'input' => 3, 'output' => 15, 'cache_read' => 0.30, 'cache_write' => 3.75 },
      'gpt-4'             => { 'input' => 10, 'output' => 30, 'cache_read' => 5, 'cache_write' => 0 },
    }
  }
  def self.chat_gpt; @chat_gpt; end
end unless Settings.respond_to?(:chat_gpt)

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require 'httparty'
require_relative '../models/api_usage'
require_relative '../lib/gpt_master'

# Mock HTTParty responses
class FakeResponse
  def initialize(code, body)
    @code = code
    @body = body
    @parsed = body
  end
  def code; @code; end
  def body; @body.to_json; end
  def parsed_response; @body; end
  def [](key); @body[key]; end
  def dig(*keys); @body.dig(*keys); end
end

module HTTPartyStub
  def self.with_response(response)
    HTTParty.define_singleton_method(:post) { |*_| response }
    yield
  ensure
    HTTParty.singleton_class.remove_method(:post) rescue nil
  end

  def self.with_responses(responses)
    queue = responses.dup
    HTTParty.define_singleton_method(:post) { |*_| queue.shift }
    yield
  ensure
    HTTParty.singleton_class.remove_method(:post) rescue nil
  end
end

class SplitCacheBreakTest < BotTest
  def test_marker_splits_into_system_and_user
    system, user = GptMaster.split_cache_break("A\n{CACHE_BREAK}\nB")
    assert_equal 'A', system
    assert_equal 'B', user
  end

  def test_no_marker_returns_nil_system
    system, user = GptMaster.split_cache_break("hello world")
    assert_nil system
    assert_equal 'hello world', user
  end

  def test_only_first_marker_splits
    system, user = GptMaster.split_cache_break("A{CACHE_BREAK}B{CACHE_BREAK}C")
    assert_equal 'A', system
    assert_equal "B{CACHE_BREAK}C", user
  end
end

class GptMasterAnthropicUsageTest < BotTest
  def test_call_records_usage_from_anthropic_response
    body = {
      'content' => [{ 'type' => 'text', 'text' => 'hi' }],
      'usage' => {
        'input_tokens' => 100, 'output_tokens' => 20,
        'cache_creation_input_tokens' => 50, 'cache_read_input_tokens' => 300,
      }
    }
    HTTPartyStub.with_response(FakeResponse.new(200, body)) do
      result = GptMaster.new([{ role: 'user', content: 'x' }],
                             chat_id: -1, purpose: 'agent').call
      assert_equal 'hi', result
    end

    assert_equal 1, ApiUsage.count
    row = ApiUsage.first
    assert_equal 100, row.input_tokens
    assert_equal 20,  row.output_tokens
    assert_equal 50,  row.cache_write_tokens
    assert_equal 300, row.cache_read_tokens
    assert_equal -1,  row.chat_id
    assert_equal 'agent', row.purpose
    assert_equal 'claude-sonnet-4-6', row.model
  end

  def test_call_raw_records_usage
    body = {
      'content' => [{ 'type' => 'text', 'text' => 'ok' }],
      'stop_reason' => 'end_turn',
      'usage' => { 'input_tokens' => 5, 'output_tokens' => 2,
                   'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 },
    }
    HTTPartyStub.with_response(FakeResponse.new(200, body)) do
      GptMaster.new([{ role: 'user', content: 'x' }],
                    chat_id: 42, purpose: 'agent').call_raw(tools: [])
    end
    assert_equal 1, ApiUsage.count
    assert_equal 42, ApiUsage.first.chat_id
  end

  def test_missing_usage_block_does_not_create_row
    body = { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] }
    HTTPartyStub.with_response(FakeResponse.new(200, body)) do
      GptMaster.new([{ role: 'user', content: 'x' }],
                    chat_id: 1, purpose: 'agent').call
    end
    assert_equal 0, ApiUsage.count
  end

  def test_telemetry_failure_does_not_break_call
    body = {
      'content' => [{ 'type' => 'text', 'text' => 'hi' }],
      'usage' => { 'input_tokens' => 10, 'output_tokens' => 5,
                   'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 },
    }
    ApiUsage.stub(:record, ->(*_) { raise 'db down' }) do
      HTTPartyStub.with_response(FakeResponse.new(200, body)) do
        result = GptMaster.new([{ role: 'user', content: 'x' }],
                               chat_id: 1, purpose: 'agent').call
        assert_equal 'hi', result
      end
    end
  end
end

class GptMasterOpenAIUsageTest < BotTest
  def test_openai_response_cached_tokens_subtracted_from_input
    body = {
      'choices' => [{ 'message' => { 'content' => 'hi' }, 'finish_reason' => 'stop' }],
      'usage' => {
        'prompt_tokens' => 100, 'completion_tokens' => 20,
        'prompt_tokens_details' => { 'cached_tokens' => 40 },
      }
    }
    HTTPartyStub.with_response(FakeResponse.new(200, body)) do
      GptMaster.new([{ role: 'user', content: 'x' }],
                    setting: 'openai', chat_id: 7, purpose: 'main_chat').call
    end
    row = ApiUsage.first
    assert_equal 60, row.input_tokens        # prompt(100) - cached(40)
    assert_equal 20, row.output_tokens
    assert_equal 40, row.cache_read_tokens
    assert_equal 0,  row.cache_write_tokens
  end
end

class GptMasterBodyBuildingTest < BotTest
  def test_anthropic_body_includes_system_with_cache_control_when_given
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], system_prompt: 'STATIC',
                    chat_id: 1, purpose: 'agent').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    sys = captured['system']
    assert_kind_of Array, sys
    assert_equal 'STATIC', sys.first['text']
    assert_equal 'ephemeral', sys.first['cache_control']['type']
  end

  def test_anthropic_body_omits_system_when_not_given
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], chat_id: 1, purpose: 'agent').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    refute captured.key?('system')
  end

  def test_last_tool_gets_cache_control_on_anthropic_call_raw
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'done' }],
        'stop_reason' => 'end_turn',
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      tools = [{ name: 'a', description: 'a' }, { name: 'b', description: 'b' }]
      GptMaster.new([{ role: 'user', content: 'hi' }], chat_id: 1, purpose: 'agent')
               .call_raw(tools: tools)
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert_equal 'ephemeral', captured['tools'].last['cache_control']['type']
    refute captured['tools'].first.key?('cache_control')
  end

  def test_openai_body_uses_system_role_message
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'openai',
                    system_prompt: 'STATIC', chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    refute captured.key?('system')
    assert_equal 'system', captured['messages'].first['role']
    assert_equal 'STATIC', captured['messages'].first['content']
  end

  def test_legacy_thinking_budget_serializes_to_enabled_shape
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'legacy_thinking',
                    chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert_equal 'enabled', captured['thinking']['type']
    assert_equal 1600,      captured['thinking']['budget_tokens']
    refute captured.key?('output_config')
  end

  def test_new_adaptive_thinking_passes_through_verbatim_plus_output_config
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'adaptive_thinking',
                    chat_id: 1, purpose: 'agent').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert_equal 'adaptive', captured['thinking']['type']
    refute captured['thinking'].key?('budget_tokens'), 'adaptive mode must not include legacy budget_tokens'
    assert_equal 'high', captured['output_config']['effort']
  end

  def test_openai_tools_do_not_get_cache_control
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    begin
      tools = [{ name: 'a' }, { name: 'b' }]
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'openai',
                    chat_id: 1, purpose: 'main_chat').call_raw(tools: tools)
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert captured['tools'].none? { |t| t.key?('cache_control') }
  end
end

class GptMasterClassMethodsTest < BotTest
  def test_chat_splits_on_cache_break_and_passes_system
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.chat('hello', context: 'ctx', knowledge: 'kb', chat_id: -5, purpose: 'main_chat')
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    # System should contain "STATIC PREFIX" (before marker); user content should contain filled template
    assert_equal 'STATIC PREFIX', captured['system'].first['text']
    user = captured['messages'].first['content']
    assert_includes user, 'Knowledge: kb'
    assert_includes user, 'Context: ctx'
    assert_includes user, 'Request: hello'
    # And telemetry row includes chat_id + purpose
    assert_equal -5, ApiUsage.first.chat_id
    assert_equal 'main_chat', ApiUsage.first.purpose
  end

  def test_ask_does_not_split_cache_break
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'content' => [{ 'type' => 'text', 'text' => 'k' }],
        'usage' => { 'input_tokens' => 1, 'output_tokens' => 1,
                     'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 0 })
    end
    begin
      GptMaster.ask('hi', prompt: 'Do: {REQUEST}', chat_id: 1, purpose: 'translate')
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    refute captured.key?('system')
    assert_equal 'translate', ApiUsage.first.purpose
  end
end

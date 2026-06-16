require_relative 'test_helper'

# Stub Settings before loading gpt_master
module Settings
  @chat_gpt = {
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
      'deepseek_thinking' => { 'provider' => 'openai', 'model' => 'deepseek-v4-pro', 'thinking' => { 'type' => 'enabled' } },
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

  def test_openai_branch_passes_through_thinking_when_set
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'deepseek_thinking',
                    chat_id: 1, purpose: 'agent').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert_equal 'enabled', captured['thinking']['type']
    refute captured['thinking'].key?('budget_tokens'),
      'DeepSeek thinking shape is bare {type: enabled}, no Anthropic-style budget_tokens'
  end

  def test_openai_branch_omits_thinking_when_not_set
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'openai',
                    chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    refute captured.key?('thinking'),
      'openai-compatible body must not include thinking when @thinking is nil'
  end

  # Cost-tracking insurance against future API drift: if a provider ever splits
  # reasoning_tokens OUT of completion_tokens (OpenAI o-series convention),
  # extract_usage must derive output from total - prompt so reasoning is still
  # billed. Today DeepSeek folds reasoning INTO completion_tokens, so this
  # branch is a no-op — the test locks in the safety net.
  def test_openai_extract_usage_handles_reasoning_split_from_completion
    HTTParty.define_singleton_method(:post) do |_url, _opts|
      # total > prompt + completion → reasoning is separate. Output should be total-prompt.
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 100, 'completion_tokens' => 30, 'total_tokens' => 200,
                     'completion_tokens_details' => { 'reasoning_tokens' => 70 } })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'openai',
                    chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    row = ApiUsage.last
    assert_equal 100, row.input_tokens
    assert_equal 100, row.output_tokens, 'output should be total(200) - prompt(100) = 100, not raw completion=30'
  end

  def test_openai_extract_usage_uses_completion_when_total_matches
    HTTParty.define_singleton_method(:post) do |_url, _opts|
      # total == prompt + completion → reasoning already in completion (DeepSeek today).
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 100, 'completion_tokens' => 50, 'total_tokens' => 150,
                     'completion_tokens_details' => { 'reasoning_tokens' => 20 } })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'hi' }], setting: 'openai',
                    chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    row = ApiUsage.last
    assert_equal 50, row.output_tokens, 'output should be completion=50 (no double-count of reasoning_tokens)'
  end

  # Anthropic-format vision blocks must be auto-translated to OpenAI format
  # for any openai-compat provider (Grok, DeepSeek vision-capable, OpenAI).
  def test_openai_branch_converts_anthropic_vision_block_to_image_url
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'a husky' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 100, 'completion_tokens' => 5 })
    end
    anthropic_msg = [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'ABCDEF' } },
        { type: 'text', text: 'what is this?' },
      ],
    }]
    begin
      GptMaster.new(anthropic_msg, setting: 'openai', chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    block = captured['messages'].first['content'].find { |b| b['type'] == 'image_url' }
    assert block, 'image block must be converted to image_url type'
    assert_equal 'data:image/jpeg;base64,ABCDEF', block['image_url']['url']
    text = captured['messages'].first['content'].find { |b| b['type'] == 'text' }
    assert_equal 'what is this?', text['text'], 'text blocks pass through unchanged'
    assert(captured['messages'].first['content'].none? { |b| b['type'] == 'image' },
      'no Anthropic-style image blocks should reach the openai wire')
  end

  def test_openai_branch_passes_through_string_content_messages
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    begin
      GptMaster.new([{ role: 'user', content: 'plain text' }], setting: 'openai',
                    chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    assert_equal 'plain text', captured['messages'].first['content'],
      'string-content messages must pass through the conversion unchanged'
  end

  def test_openai_branch_handles_string_keyed_anthropic_image_block
    # Provider responses come back parsed as JSON (string keys). Make sure
    # conversion handles both symbol and string keys on the input.
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'k' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    string_keyed = [{
      'role' => 'user',
      'content' => [
        { 'type' => 'image', 'source' => { 'type' => 'base64', 'media_type' => 'image/png', 'data' => 'XYZ' } },
        { 'type' => 'text', 'text' => 'go' },
      ],
    }]
    begin
      GptMaster.new(string_keyed, setting: 'openai', chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    block = captured['messages'].first['content'].find { |b| b['type'] == 'image_url' }
    assert_equal 'data:image/png;base64,XYZ', block['image_url']['url']
  end

  # Multi-iteration regression: when an assistant turn with tool_calls + nil
  # content gets appended back into @messages, the conversion helper must
  # tolerate `content: nil` and not crash. Mirrors what Agent::Runner does on
  # its second iteration with openai api_type.
  def test_openai_branch_passes_through_assistant_message_with_nil_content
    captured = nil
    HTTParty.define_singleton_method(:post) do |_url, opts|
      captured = JSON.parse(opts[:body])
      FakeResponse.new(200,
        'choices' => [{ 'message' => { 'content' => 'final' }, 'finish_reason' => 'stop' }],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 })
    end
    history = [
      { role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'ZZZ' } },
          { type: 'text',  text: 'see this' },
        ] },
      { 'role' => 'assistant', 'content' => nil,
        'tool_calls' => [{ 'id' => 'call_1', 'type' => 'function',
                           'function' => { 'name' => 'echo', 'arguments' => '{}' } }] },
      { role: 'tool', tool_call_id: 'call_1', content: 'echoed' },
    ]
    begin
      GptMaster.new(history, setting: 'openai', chat_id: 1, purpose: 'main_chat').call
    ensure
      HTTParty.singleton_class.remove_method(:post) rescue nil
    end
    # User turn 0: image converted
    assert_equal 'data:image/jpeg;base64,ZZZ',
      captured['messages'][0]['content'].find { |b| b['type'] == 'image_url' }['image_url']['url']
    # Assistant turn 1: content stays nil, tool_calls preserved
    assert_nil captured['messages'][1]['content']
    assert_equal 'echo', captured['messages'][1]['tool_calls'][0]['function']['name']
    # Tool turn 2: string content passes through
    assert_equal 'echoed', captured['messages'][2]['content']
  end
end

class GptMasterErrorBodyTest < BotTest
  # Regression: Grok/xAI sometimes returns a non-200 with a bare-string body
  # (or a JSON string literal), which HTTParty parses into a Ruby String. The
  # error-log line called #dig on it, raising `TypeError: String does not have
  # #dig method` — turning a routine API failure into an unhandled crash that
  # propagated out of call_raw. Both call paths must degrade gracefully instead.
  def test_call_raw_returns_nil_on_non200_with_string_body
    HTTPartyStub.with_response(FakeResponse.new(500, 'upstream exploded')) do
      result = GptMaster.new([{ role: 'user', content: 'x' }],
                             setting: 'openai', chat_id: 1, purpose: 'agent').call_raw(tools: [])
      assert_nil result
    end
  end

  def test_call_returns_fallback_on_non200_with_string_body
    HTTPartyStub.with_response(FakeResponse.new(500, 'upstream exploded')) do
      result = GptMaster.new([{ role: 'user', content: 'x' }],
                             setting: 'openai', chat_id: 1, purpose: 'main_chat').call
      assert_equal 'жпт не жпт', result
    end
  end

  # Sibling failure mode: a non-JSON body (HTML 502 page, plain-text proxy
  # error) under a JSON content-type makes HTTParty's #parsed_response itself
  # raise JSON::ParserError — error_message must swallow it and fall back to the
  # raw body rather than letting it propagate out of call/call_raw.
  def test_call_raw_returns_nil_when_parsed_response_raises
    raising = Object.new
    def raising.code; 502; end
    def raising.body; '<html>502 Bad Gateway</html>'; end
    def raising.parsed_response; raise JSON::ParserError, 'unexpected token'; end
    HTTPartyStub.with_response(raising) do
      result = GptMaster.new([{ role: 'user', content: 'x' }],
                             setting: 'openai', chat_id: 1, purpose: 'agent').call_raw(tools: [])
      assert_nil result
    end
  end

  # Hash error bodies still get their nested error.message extracted for the log.
  def test_call_raw_returns_nil_on_non200_with_hash_error_body
    HTTPartyStub.with_response(FakeResponse.new(402, { 'error' => { 'message' => 'Insufficient Balance' } })) do
      result = GptMaster.new([{ role: 'user', content: 'x' }],
                             setting: 'openai', chat_id: 1, purpose: 'agent').call_raw(tools: [])
      assert_nil result
    end
  end
end

class GptMasterClassMethodsTest < BotTest
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

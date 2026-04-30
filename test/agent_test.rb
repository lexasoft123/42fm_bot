require_relative 'test_helper'

require 'ostruct'

# --- Require production code ---
# Re-define Settings with the full production module (test_helper defines a minimal one)
Object.send(:remove_const, :Settings) if defined?(Settings)
require_relative '../lib/settings'
require_relative '../lib/gpt_master'
require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/runner'
require_relative '../lib/commands/base'
require_relative '../lib/chat_context'
require_relative '../lib/commands/gpt_helpers'
require_relative '../lib/commands/gpt_chat'

# --- Global logger stubs ---
LOGGER       = Logger.new(IO::NULL) unless defined?(LOGGER)

# ==========================================================================
# FakeGptMaster — scripted replacement for GptMaster in Runner tests
# ==========================================================================
class FakeGptMaster
  @@responses = []
  @@calls     = []

  def self.enqueue(*responses)
    @@responses = responses.dup
  end

  def self.calls
    @@calls
  end

  def self.reset!
    @@responses = []
    @@calls     = []
  end

  def self.resolve_setting(_name)
    { api_key: 'fake', api_type: 'anthropic', api_url: 'http://fake',
      model: 'fake', max_tokens: 100, thinking_budget: nil }
  end

  def self.split_cache_break(content)
    marker = '{CACHE_BREAK}'
    return [nil, content] unless content.include?(marker)
    prefix, suffix = content.split(marker, 2)
    [prefix.strip, suffix.strip]
  end

  def initialize(messages, setting: 'main', chat_id: nil, user_uid: nil, purpose: nil, system_prompt: nil)
    @messages      = messages
    @setting       = setting
    @chat_id       = chat_id
    @user_uid      = user_uid
    @purpose       = purpose
    @system_prompt = system_prompt
  end

  def call_raw(tools: [])
    @@calls << { messages: @messages.dup, setting: @setting, tools: tools,
                 chat_id: @chat_id, user_uid: @user_uid, purpose: @purpose,
                 system_prompt: @system_prompt, method: :call_raw }
    @@responses.shift
  end

  def call
    @@calls << { messages: @messages.dup, setting: @setting,
                 chat_id: @chat_id, user_uid: @user_uid, purpose: @purpose,
                 system_prompt: @system_prompt, method: :call }
    @@responses.shift
  end
end

# ==========================================================================
# Helpers
# ==========================================================================
module AgentTestHelpers
  def anthropic_text(text)
    { 'content' => [{ 'type' => 'text', 'text' => text }] }
  end

  def anthropic_tool_call(name, input, id: 'call_1')
    { 'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }] }
  end

  def anthropic_multi_tool(calls)
    { 'content' => calls.map { |c| { 'type' => 'tool_use', 'id' => c[:id], 'name' => c[:name], 'input' => c[:input] } } }
  end

  def stub_settings!(overrides = {})
    defaults = {
      radio: { 'path' => '/music', 'host_path' => nil },
      telegram: { 'token' => '123456:ABCDEF' },
      chat_gpt: {
        'agent_prompt' => "<%- if image -%>[IMAGE]\n<%- end -%><%- if phrase -%>PHRASE: <%= phrase %>\n<%- end -%>FROM={USER} | {REQUEST} | {CONTEXT} | {KNOWLEDGE}",
        'context_messages_size' => 10,
        'providers' => { 'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' } },
        'settings' => { 'agent' => { 'provider' => 'anthropic', 'model' => 'fake', 'max_tokens' => 100 } }
      }
    }
    merged = defaults.merge(overrides)
    Settings.instance_variable_set(:@_settings, OpenStruct.new(merged))
  end

  def build_runner(text:, user:, **opts)
    defaults = {
      context: '[]', knowledge: '', radio: nil,
      chat_id: 100, bot: nil, image: nil, phrase: nil
    }
    Agent::Runner.new(**defaults.merge(opts).merge(text: text, user: user))
  end

  def build_ctx(cmd:, user:, message: nil, bot: nil)
    message ||= OpenStruct.new(text: cmd, message_id: 1, reply_to_message: nil, message_thread_id: nil)
    CommandContext.new(
      bot: bot, message: message, user: user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: cmd
    )
  end
end

# ==========================================================================
# ToolRegistryTest
# ==========================================================================
class ToolRegistryTest < BotTest
  def setup
    super
    @saved_tools = Agent::ToolRegistry.instance_variable_get(:@tools)&.dup || []
    Agent::ToolRegistry.instance_variable_set(:@tools, [])
  end

  def teardown
    Agent::ToolRegistry.instance_variable_set(:@tools, @saved_tools)
    super
  end

  # Registering a tool adds it to the tools list
  def test_register_adds_tool
    Agent::ToolRegistry.register(name: 'test_tool', description: 'A test', handler: ->(_a, _c) { 'ok' })
    assert_equal 1, Agent::ToolRegistry.tools.size
    assert_equal 'test_tool', Agent::ToolRegistry.tools.first.name
  end

  # find returns the correct tool when multiple are registered
  def test_find_by_name
    Agent::ToolRegistry.register(name: 'a', description: 'first', handler: ->(_a, _c) { 'a' })
    Agent::ToolRegistry.register(name: 'b', description: 'second', handler: ->(_a, _c) { 'b' })
    found = Agent::ToolRegistry.find('b')
    assert_equal 'b', found.name
  end

  # find returns nil for a tool name that was never registered
  def test_find_unknown_returns_nil
    assert_nil Agent::ToolRegistry.find('nonexistent')
  end

  # definitions_for excludes admin_only tools when user role is 'member'
  def test_definitions_filters_admin_for_member
    Agent::ToolRegistry.register(name: 'public', description: 'pub', handler: ->(_a, _c) { '' })
    Agent::ToolRegistry.register(name: 'secret', description: 'sec', handler: ->(_a, _c) { '' }, admin_only: true)
    defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: 'anthropic')
    assert_equal 1, defs.size
    assert_equal 'public', defs.first[:name]
  end

  # definitions_for includes admin_only tools when user role is 'admin'
  def test_definitions_includes_admin_for_admin
    Agent::ToolRegistry.register(name: 'public', description: 'pub', handler: ->(_a, _c) { '' })
    Agent::ToolRegistry.register(name: 'secret', description: 'sec', handler: ->(_a, _c) { '' }, admin_only: true)
    defs = Agent::ToolRegistry.definitions_for(user_role: 'admin', api_type: 'anthropic')
    assert_equal 2, defs.size
  end

  # Anthropic format uses input_schema with type/properties/required
  def test_definitions_anthropic_format
    Agent::ToolRegistry.register(
      name: 'weather', description: 'Get weather',
      parameters: { 'city' => { type: 'string', description: 'City name' } },
      handler: ->(_a, _c) { '' }
    )
    defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: 'anthropic')
    d = defs.first
    assert_equal 'weather', d[:name]
    assert d.key?(:input_schema)
    assert_equal 'object', d[:input_schema][:type]
    assert d[:input_schema][:properties].key?('city')
  end

  # OpenAI format wraps tool in { type: 'function', function: { ... } }
  def test_definitions_openai_format
    Agent::ToolRegistry.register(
      name: 'weather', description: 'Get weather',
      parameters: { 'city' => { type: 'string', description: 'City name' } },
      handler: ->(_a, _c) { '' }
    )
    defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: 'openai')
    d = defs.first
    assert_equal 'function', d[:type]
    assert_equal 'weather', d[:function][:name]
    assert d[:function][:parameters].key?(:properties)
  end
end

# ==========================================================================
# RunnerTest
# ==========================================================================
class RunnerTest < BotTest
  include AgentTestHelpers
  include Fixtures::Users

  def setup
    super
    @saved_tools = Agent::ToolRegistry.instance_variable_get(:@tools)&.dup || []
    Agent::ToolRegistry.instance_variable_set(:@tools, [])
    @original_gpt_master = ::GptMaster
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, FakeGptMaster)
    FakeGptMaster.reset!
    stub_settings!
    @user = member_user
  end

  def teardown
    Agent::ToolRegistry.instance_variable_set(:@tools, @saved_tools)
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, @original_gpt_master)
    super
  end

  # API returns text-only response — Runner returns it directly
  def test_text_response
    FakeGptMaster.enqueue(anthropic_text('Hello world'))
    result = build_runner(text: 'hi', user: @user).run
    assert_equal 'Hello world', result
  end

  # API returns nil (failure) — Runner returns fallback string
  def test_nil_response_fallback
    FakeGptMaster.enqueue(nil)
    result = build_runner(text: 'hi', user: @user).run
    assert_equal 'жпт не жпт', result
  end

  # API returns one tool call, then text — tool is executed and final text returned
  def test_single_tool_call_then_text
    called = false
    Agent::ToolRegistry.register(
      name: 'echo', description: 'Echo',
      handler: ->(args, _ctx) { called = true; "echoed: #{args['msg']}" }
    )
    FakeGptMaster.enqueue(
      anthropic_tool_call('echo', { 'msg' => 'test' }),
      anthropic_text('Done')
    )
    result = build_runner(text: 'do it', user: @user).run
    assert called, 'tool handler should have been called'
    assert_equal 'Done', result
  end

  # Tool handler receives the exact input hash from the API response
  def test_tool_receives_correct_input
    received_args = nil
    Agent::ToolRegistry.register(
      name: 'capture', description: 'Capture args',
      handler: ->(args, _ctx) { received_args = args; 'ok' }
    )
    FakeGptMaster.enqueue(
      anthropic_tool_call('capture', { 'query' => 'hello', 'count' => 5 }),
      anthropic_text('ok')
    )
    build_runner(text: 'go', user: @user).run
    assert_equal({ 'query' => 'hello', 'count' => 5 }, received_args)
  end

  # ToolResult.deferred auto-writes scratchpad and forwards a structured prefix
  def test_deferred_tool_result_persists_intent_and_decorates_text
    Agent::ToolRegistry.register(
      name: 'flaky', description: 'flaky',
      handler: ->(_a, _c) {
        Agent::ToolResult.deferred(user_text: 'Wait 5 min',
                                   intent: 'do the thing later',
                                   retry_in_min: 5)
      }
    )
    FakeGptMaster.enqueue(
      anthropic_tool_call('flaky', {}),
      anthropic_text('ok')
    )
    build_runner(text: 'go', user: @user, chat_id: 999).run

    # Scratchpad got the intent
    data = Agent::Scratchpad.read(999)
    assert_equal 1, data['intentions'].size
    assert_equal 'do the thing later', data['intentions'].first['content']

    # Second LLM call's messages array contains a tool_result with the structured prefix
    second_call = FakeGptMaster.calls[1]
    tool_result_msg = second_call[:messages].last
    content = tool_result_msg[:content].first[:content]
    assert_includes content, '[deferred retry_in=5min'
    assert_includes content, 'intent saved to scratchpad'
    assert_includes content, 'Wait 5 min'
  end

  # Plain ToolResult.text passes through unchanged, no scratchpad write
  def test_plain_tool_result_text_passthrough
    Agent::ToolRegistry.register(
      name: 'plain', description: 'plain',
      handler: ->(_a, _c) { Agent::ToolResult.text('all good') }
    )
    FakeGptMaster.enqueue(
      anthropic_tool_call('plain', {}),
      anthropic_text('ok')
    )
    build_runner(text: 'go', user: @user, chat_id: 998).run

    second_call = FakeGptMaster.calls[1]
    content = second_call[:messages].last[:content].first[:content]
    assert_equal 'all good', content
    assert_empty Agent::Scratchpad.read(998)['intentions']
  end

  # Two tool_use blocks in one response — both handlers are called in order
  def test_multiple_tools_in_one_response
    call_log = []
    Agent::ToolRegistry.register(name: 'a', description: 'A', handler: ->(_a, _c) { call_log << 'a'; 'a' })
    Agent::ToolRegistry.register(name: 'b', description: 'B', handler: ->(_a, _c) { call_log << 'b'; 'b' })
    FakeGptMaster.enqueue(
      anthropic_multi_tool([
        { id: 'c1', name: 'a', input: {} },
        { id: 'c2', name: 'b', input: {} }
      ]),
      anthropic_text('All done')
    )
    result = build_runner(text: 'go', user: @user).run
    assert_equal %w[a b], call_log
    assert_equal 'All done', result
  end

  # admin_only tool called by member user — returns permission error in tool result
  def test_admin_tool_blocked_for_member
    Agent::ToolRegistry.register(name: 'nuke', description: 'Admin only', handler: ->(_a, _c) { 'boom' }, admin_only: true)
    FakeGptMaster.enqueue(
      anthropic_tool_call('nuke', {}),
      anthropic_text('Denied')
    )
    result = build_runner(text: 'nuke', user: @user).run
    assert_equal 'Denied', result
    # Verify the tool result message contains permission error
    call_raw_calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    last_messages = call_raw_calls.last[:messages]
    tool_result = last_messages.find { |m| m[:role] == 'user' && m[:content].is_a?(Array) && m[:content].any? { |b| b[:type] == 'tool_result' } }
    assert tool_result, 'should have a tool_result message'
    content_str = tool_result[:content].find { |b| b[:type] == 'tool_result' }[:content]
    assert_match(/недостаточно прав/, content_str)
  end

  # admin_only tool called by admin user — handler is executed normally
  def test_admin_tool_allowed_for_admin
    called = false
    Agent::ToolRegistry.register(name: 'nuke', description: 'Admin only', handler: ->(_a, _c) { called = true; 'done' }, admin_only: true)
    admin = admin_user
    FakeGptMaster.enqueue(
      anthropic_tool_call('nuke', {}),
      anthropic_text('Nuked')
    )
    build_runner(text: 'nuke', user: admin).run
    assert called, 'admin tool handler should have been called'
  end

  # API calls a tool name not in registry — tool result contains "unknown tool" error
  def test_unknown_tool_error
    FakeGptMaster.enqueue(
      anthropic_tool_call('nonexistent', {}),
      anthropic_text('ok')
    )
    build_runner(text: 'go', user: @user).run
    call_raw_calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    last_messages = call_raw_calls.last[:messages]
    tool_result = last_messages.flat_map { |m|
      next [] unless m[:role] == 'user' && m[:content].is_a?(Array)
      m[:content].select { |b| b[:type] == 'tool_result' }
    }.first
    assert tool_result
    assert_match(/неизвестный инструмент/, tool_result[:content])
  end

  # Tool handler raises an exception — Runner catches it and returns error fallback
  def test_tool_error_returns_fallback
    Agent::ToolRegistry.register(name: 'bomb', description: 'Boom', handler: ->(_a, _c) { raise 'kaboom' })
    FakeGptMaster.enqueue(
      anthropic_tool_call('bomb', {}),
      anthropic_text('recovered')
    )
    result = build_runner(text: 'go', user: @user).run
    assert_equal 'recovered', result
  end

  # After MAX_ITERATIONS of tool calls, Runner forces a final text-only call
  def test_max_iterations_forced_final
    Agent::ToolRegistry.register(name: 'loop', description: 'Loop', handler: ->(_a, _c) { 'again' })
    responses = Array.new(Agent::Runner::MAX_ITERATIONS) { anthropic_tool_call('loop', {}) }
    responses << 'forced final text'  # for the .call (not call_raw)
    FakeGptMaster.enqueue(*responses)
    result = build_runner(text: 'go', user: @user).run
    assert_equal 'forced final text', result
  end

  # Image-hallucination watchdog: when the agent ends a turn with the
  # `🎨 <caption>` pattern but never called generate_image, runner should
  # nudge once and re-loop instead of returning the hallucinated text.
  def test_watchdog_nudges_when_emoji_caption_in_text_without_tool_call
    Agent::ToolRegistry.register(
      name: 'generate_image', description: 'Make a picture',
      parameters: { 'request' => { type: 'string' } },
      handler: ->(_a, _c) { 'ok, queued' }
    )
    long_caption = 'Бастрыкин в кабинете с лупой над дилдо, нуар-освещение, ' \
                   'детализированный костюм, сосредоточенное лицо, мрачная атмосфера.'
    FakeGptMaster.enqueue(
      anthropic_text("Сейчас нарисуем.\n🎨 #{long_caption}"),  # iter1: hallucination
      anthropic_tool_call('generate_image', { 'request' => 'бастрыкин с лупой' }, id: 'c1'), # iter2: actual call after nudge
      anthropic_text('Готово') # iter3: final text
    )
    result = build_runner(text: 'нарисуй бастрыкина', user: @user).run
    assert_equal 'Готово', result

    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 3, calls.size, 'should have made 3 call_raw calls (hallucination + retry + final)'

    # Iter2's messages must contain the assistant hallucination + the nudge user message
    iter2_messages = calls[1][:messages]
    nudge = iter2_messages.last
    nudge_text = nudge[:content].is_a?(Array) ? nudge[:content].first[:text] : nudge[:content]
    assert_match(/generate_image/, nudge_text)
  end

  # Watchdog must not fire when generate_image was actually called this turn,
  # even if final text contains a 🎨 caption.
  def test_watchdog_does_not_fire_when_generate_image_was_called
    Agent::ToolRegistry.register(
      name: 'generate_image', description: 'Make a picture',
      parameters: { 'request' => { type: 'string' } },
      handler: ->(_a, _c) { 'ok' }
    )
    long_caption = 'A' * 200
    FakeGptMaster.enqueue(
      anthropic_tool_call('generate_image', { 'request' => 'cat' }, id: 'c1'),
      anthropic_text("\n🎨 #{long_caption}")  # final text has 🎨 but the tool was already called
    )
    result = build_runner(text: 'draw a cat', user: @user).run
    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 2, calls.size, 'no retry — generate_image was already called'
    assert_match(/🎨/, result)
  end

  # Watchdog must not fire when 🎨 appears inline (not at line start) — that
  # is normal narration, not the caption pattern.
  def test_watchdog_skips_inline_emoji_use
    short_text = "Я уже нарисовал тебе 🎨 кошку и зверя — вот, см. выше."
    FakeGptMaster.enqueue(anthropic_text(short_text))
    result = build_runner(text: 'что было?', user: @user).run
    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 1, calls.size, 'no retry — inline 🎨 is fine'
    assert_equal short_text, result
  end

  # Watchdog must not fire when 🎨 is inline AND followed by a long-enough
  # narration — the line-anchor in the regex (not the length threshold) is
  # what distinguishes narration from a caption hallucination.
  def test_watchdog_skips_inline_emoji_even_when_trailing_text_is_long
    inline_long = "вот тебе котик 🎨 #{'X' * 200} — всё, конец фразы"
    FakeGptMaster.enqueue(anthropic_text(inline_long))
    build_runner(text: 'что было?', user: @user).run
    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 1, calls.size, 'inline 🎨 with long trailing text must not trigger watchdog'
  end

  # Watchdog must fire only once per turn — if the model still hallucinates
  # after the nudge, return that text rather than looping forever.
  def test_watchdog_fires_only_once_per_turn
    long_caption = 'B' * 200
    FakeGptMaster.enqueue(
      anthropic_text("\n🎨 #{long_caption}"),  # iter1: first hallucination
      anthropic_text("\n🎨 #{long_caption}")   # iter2: still hallucinating after nudge
    )
    result = build_runner(text: 'нарисуй', user: @user).run
    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 2, calls.size, 'must not loop infinitely'
    assert_match(/🎨/, result)
  end

  # Tool result longer than MAX_TOOL_RESULT_LENGTH is truncated with '...'
  def test_tool_result_truncation
    long_result = 'x' * 3000
    Agent::ToolRegistry.register(name: 'long', description: 'Long', handler: ->(_a, _c) { long_result })
    FakeGptMaster.enqueue(
      anthropic_tool_call('long', {}),
      anthropic_text('done')
    )
    build_runner(text: 'go', user: @user).run
    call_raw_calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    last_messages = call_raw_calls.last[:messages]
    tool_result = last_messages.flat_map { |m|
      next [] unless m[:role] == 'user' && m[:content].is_a?(Array)
      m[:content].select { |b| b[:type] == 'tool_result' }
    }.first
    assert tool_result
    assert_equal Agent::Runner::MAX_TOOL_RESULT_LENGTH + 3, tool_result[:content].length  # 2000 + '...'
    assert tool_result[:content].end_with?('...')
  end

  # DeepSeek thinking-mode rule: when tools are involved, the assistant's
  # reasoning_content from a prior turn MUST be carried in the message history
  # on the follow-up turn. Our runner relies on `raw.dig('choices', 0, 'message')`
  # in build_assistant_message (openai branch) to return the WHOLE assistant
  # message including reasoning_content + tool_calls. Lock that contract.
  def test_runner_carries_reasoning_content_across_iterations_for_openai
    # Capture original resolve_setting (a `def self.` class method) and override
    # to force the openai branch. ensure-block restores via the captured Method
    # so other tests in the suite (including production_errors_test.rb's own
    # FakeGptMaster reopening) aren't disturbed.
    original_resolve = FakeGptMaster.method(:resolve_setting)
    FakeGptMaster.define_singleton_method(:resolve_setting) do |_name|
      { api_key: 'fake', api_type: 'openai', api_url: 'http://fake',
        model: 'deepseek-v4-pro', max_tokens: 100 }
    end

    Agent::ToolRegistry.register(name: 'echo', description: 'Echo it',
      parameters: { 'msg' => { type: 'string' } },
      handler: ->(_a, _c) { 'ok' })

    iter1 = {
      'choices' => [{
        'message' => {
          'role' => 'assistant',
          'content' => nil,
          'reasoning_content' => 'I should call the echo tool to verify.',
          'tool_calls' => [{
            'id' => 'call_1', 'type' => 'function',
            'function' => { 'name' => 'echo', 'arguments' => '{"msg":"hi"}' },
          }],
        },
        'finish_reason' => 'tool_calls',
      }],
    }
    iter2 = {
      'choices' => [{
        'message' => { 'role' => 'assistant',
                       'content' => 'done',
                       'reasoning_content' => 'Tool returned ok, I respond.' },
        'finish_reason' => 'stop',
      }],
    }

    FakeGptMaster.enqueue(iter1, iter2)
    result = build_runner(text: 'go', user: @user).run
    assert_equal 'done', result

    # Iter 2's request body must contain the prior assistant message with
    # reasoning_content intact — that's the load-bearing multi-turn rule.
    calls = FakeGptMaster.calls.select { |c| c[:method] == :call_raw }
    assert_equal 2, calls.size
    iter2_messages = calls[1][:messages]
    assistant_msg = iter2_messages.find { |m| (m['role'] || m[:role]) == 'assistant' }
    assert assistant_msg, 'iter2 must contain prior assistant message in history'
    reasoning = assistant_msg['reasoning_content'] || assistant_msg[:reasoning_content]
    assert_equal 'I should call the echo tool to verify.', reasoning,
      'reasoning_content from iter1 must be preserved into iter2 (DeepSeek multi-turn rule)'
  ensure
    FakeGptMaster.define_singleton_method(:resolve_setting, original_resolve) if original_resolve
  end

  # When image is provided, message content is an array with image and text blocks
  def test_build_messages_with_image
    FakeGptMaster.enqueue(anthropic_text('I see a cat'))
    image = { data: 'base64data', media_type: 'image/jpeg' }
    build_runner(text: 'what is this', user: @user, image: image).run
    first_call = FakeGptMaster.calls.first
    user_msg = first_call[:messages].first
    assert_equal 'user', user_msg[:role]
    assert user_msg[:content].is_a?(Array), 'content should be array for image messages'
    types = user_msg[:content].map { |b| b[:type] }
    assert_includes types, 'image'
    assert_includes types, 'text'
  end

  # Without image, message content is a plain string
  def test_build_messages_without_image
    FakeGptMaster.enqueue(anthropic_text('hi'))
    build_runner(text: 'hello', user: @user).run
    first_call = FakeGptMaster.calls.first
    user_msg = first_call[:messages].first
    assert_equal 'user', user_msg[:role]
    assert user_msg[:content].is_a?(String), 'content should be string without image'
  end

  # Phrase parameter is rendered into the prompt via ERB
  def test_build_messages_with_phrase
    FakeGptMaster.enqueue(anthropic_text('ha'))
    build_runner(text: 'ты дурак', user: @user, phrase: 'жирный хомяк').run
    first_call = FakeGptMaster.calls.first
    content = first_call[:messages].first[:content]
    assert_match(/PHRASE: жирный хомяк/, content)
  end

  # Trigger user attribution: the prompt must include the actual sender so
  # the agent doesn't address the wrong participant when multiple users have
  # recent messages in the context window. Pre-fix the prompt was
  # `Запрос из чата: [...]` with no sender, and the agent occasionally
  # addressed e.g. snels when the trigger came from lexasoft.
  def test_build_messages_includes_trigger_user_username
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_match(/FROM=testuser\b/, content, 'prompt must identify the trigger user by username')
  end

  def test_build_messages_includes_full_name_when_present
    user_with_name = member_user(uid: 9999, name: 'snels', first_name: 'Snels', last_name: 'Doe')
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: user_with_name).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_match(/FROM=snels \(Snels Doe\)/, content,
                 "trigger user line should match ChatContext.serialize_msg's `who` format")
  end

  def test_build_messages_falls_back_when_no_full_name
    user_no_full = member_user(uid: 9998, name: 'minimal_uid')
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: user_no_full).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_match(/FROM=minimal_uid \|/, content,
                 'no first/last name → fall back to bare username (no parentheses)')
  end

  # Message_id substitution: gives the agent an unambiguous handle on the
  # exact context entry that triggered this turn (so it can read `who`,
  # `reply_to`, `thread`, etc. without guessing). Wired separately from
  # {USER} so callers without a real message (e.g. agent_event handler)
  # can leave it nil.
  def test_build_messages_substitutes_message_id_when_provided
    Settings.chat_gpt['agent_prompt'] = '{REQUEST}|MID={MESSAGE_ID}'
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user, message_id: 544688).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_match(/MID=544688\b/, content)
  end

  def test_build_messages_message_id_blank_when_nil
    Settings.chat_gpt['agent_prompt'] = '{REQUEST}|MID={MESSAGE_ID}'
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_match(/MID=$/, content, 'nil message_id should render as empty string, not "MID=" literal')
  end

  # --- ERB injection regression ---
  # User-controlled strings (text/context/knowledge) MUST NOT be evaluated as ERB.
  # Previously the template was built by substituting user text first, then calling
  # ERB.result — which let a user send `бот <%= exec('pwd') %>` and run arbitrary
  # Ruby in the bot process. Fix: render ERB on the pristine template, then substitute.

  def test_user_text_with_erb_tags_is_not_evaluated
    FakeGptMaster.enqueue(anthropic_text('ok'))
    payload = 'hello <%= 7 * 7 %> world'
    build_runner(text: payload, user: @user).run
    first_call = FakeGptMaster.calls.first
    content = first_call[:messages].first[:content]
    assert_includes content, '<%= 7 * 7 %>',  'raw ERB tag must survive verbatim'
    refute_includes content, '49', 'ERB must not evaluate arithmetic in user text'
  end

  def test_user_text_with_dangerous_erb_does_not_raise
    FakeGptMaster.enqueue(anthropic_text('ok'))
    # A payload that previously raised NameError (or worse — actually executed).
    payload = "бот <%= exec('uname -a') %> <% Date.new %>"
    result = build_runner(text: payload, user: @user).run
    assert_equal 'ok', result
    first_call = FakeGptMaster.calls.first
    content = first_call[:messages].first[:content]
    assert_includes content, "<%= exec('uname -a') %>"
    assert_includes content, '<% Date.new %>'
  end

  def test_context_with_erb_tags_is_not_evaluated
    FakeGptMaster.enqueue(anthropic_text('ok'))
    context_json = '[{"who":"alice","msg":"hi <%= File.read(\'/etc/passwd\') %>"}]'
    build_runner(text: 'normal', user: @user, context: context_json).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_includes content, "File.read('/etc/passwd')"
  end

  def test_knowledge_with_erb_tags_is_not_evaluated
    FakeGptMaster.enqueue(anthropic_text('ok'))
    knowledge = '[{"topic":"x","fact":"y <%= system(\'rm -rf /tmp\') %>"}]'
    build_runner(text: 'normal', user: @user, knowledge: knowledge).run
    content = FakeGptMaster.calls.first[:messages].first[:content]
    assert_includes content, "system('rm -rf /tmp')"
  end

  # Runner threads chat_id and purpose='agent' into every GptMaster call
  def test_runner_passes_chat_id_and_purpose_agent
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user, chat_id: -999).run
    first_call = FakeGptMaster.calls.first
    assert_equal -999, first_call[:chat_id]
    assert_equal 'agent', first_call[:purpose]
  end

  def test_runner_passes_user_uid
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user).run
    first_call = FakeGptMaster.calls.first
    assert_equal @user.uid, first_call[:user_uid]
  end

  # When the agent_prompt contains {CACHE_BREAK}, the static prefix goes to system_prompt
  # and the user message gets only the dynamic suffix.
  def test_cache_break_splits_prompt_into_system_and_user
    stub_settings!(chat_gpt: Settings.chat_gpt.merge(
      'agent_prompt' => "STATIC AGENT HEADER\n{CACHE_BREAK}\nKnowledge: {KNOWLEDGE}\nReq: {REQUEST}"
    ))
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hello', user: @user, knowledge: 'facts here').run
    first_call = FakeGptMaster.calls.first
    assert_equal 'STATIC AGENT HEADER', first_call[:system_prompt]
    content = first_call[:messages].first[:content]
    assert_includes content, 'Knowledge: facts here'
    assert_includes content, 'Req: hello'
    refute_includes content, 'STATIC AGENT HEADER'
  end

  # Without marker, system_prompt is nil (no caching)
  def test_no_cache_break_means_no_system_prompt
    FakeGptMaster.enqueue(anthropic_text('ok'))
    build_runner(text: 'hi', user: @user).run
    first_call = FakeGptMaster.calls.first
    assert_nil first_call[:system_prompt]
  end
end

# ==========================================================================
# GptChatTest
# ==========================================================================
class GptChatTest < BotTest
  include AgentTestHelpers
  include Fixtures::Users

  def setup
    super
    stub_settings!
    @user = member_user
  end

  # --- match? ---

  # "бот, привет" matches via PATTERN (bot prefix with comma)
  def test_match_bot_prefix
    ctx = build_ctx(cmd: "бот, привет", user: @user)
    assert Commands::GptChat.new(ctx).match?
  end

  # "бот привет" matches via PATTERN (bot prefix without comma)
  def test_match_bot_no_comma
    ctx = build_ctx(cmd: "бот привет", user: @user)
    assert Commands::GptChat.new(ctx).match?
  end

  # ". привет" matches via PATTERN (dot prefix shortcut)
  def test_match_dot_prefix
    ctx = build_ctx(cmd: ". привет", user: @user)
    assert Commands::GptChat.new(ctx).match?
  end

  # "жпт привет" matches via PATTERN (alternative bot name)
  def test_match_zhpt_prefix
    ctx = build_ctx(cmd: "жпт привет", user: @user)
    assert Commands::GptChat.new(ctx).match?
  end

  # Plain text without bot prefix does not match
  def test_no_match_plain_text
    ctx = build_ctx(cmd: "привет", user: @user)
    refute Commands::GptChat.new(ctx).match?
  end

  # Reply to a bot message matches even without "бот" prefix
  def test_match_reply_to_bot
    bot_id = 123456  # matches token '123456:ABCDEF'
    reply_msg = OpenStruct.new(text: 'bot said this', from: OpenStruct.new(id: bot_id), photo: nil)
    msg = OpenStruct.new(text: 'some reply', message_id: 1, reply_to_message: reply_msg)
    ctx = build_ctx(cmd: "some reply", user: @user, message: msg)
    assert Commands::GptChat.new(ctx).match?
  end

  # --- maybe_save_phrase ---

  # "ты дурак" saves phrase "дурак" and returns a random phrase from DB
  def test_maybe_save_phrase_saves_and_returns
    Phrase.create!(user: @user, content: 'existing phrase')
    ctx = build_ctx(cmd: "бот ты дурак", user: @user)
    command = Commands::GptChat.new(ctx)
    result = command.send(:maybe_save_phrase, "ты дурак")
    assert_equal 2, Phrase.count  # existing + new
    assert Phrase.exists?(content: 'дурак')
    assert result.is_a?(String)
  end

  # "а ты балбес" saves phrase "балбес" (handles optional "а" prefix)
  def test_maybe_save_phrase_a_prefix
    ctx = build_ctx(cmd: "бот а ты балбес", user: @user)
    command = Commands::GptChat.new(ctx)
    command.send(:maybe_save_phrase, "а ты балбес")
    assert Phrase.exists?(content: 'балбес')
  end

  # Text without "ты" pattern returns nil and saves nothing
  def test_maybe_save_phrase_no_match
    ctx = build_ctx(cmd: "бот как дела", user: @user)
    command = Commands::GptChat.new(ctx)
    result = command.send(:maybe_save_phrase, "как дела")
    assert_nil result
    assert_equal 0, Phrase.count
  end

  # --- extract_image (current message photo) ---

  # extract_image returns nil when message has no photo
  def test_extract_image_no_photo
    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: nil, photo: nil)
    ctx = build_ctx(cmd: "бот что", user: @user, message: msg)
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_image)
  end

  # extract_image returns nil when photo array is empty
  def test_extract_image_empty_photo
    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: nil, photo: [])
    ctx = build_ctx(cmd: "бот что", user: @user, message: msg)
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_image)
  end

  # extract_image downloads photo from the current message
  def test_extract_image_downloads_photo
    photo = OpenStruct.new(file_id: 'photo123')
    msg = OpenStruct.new(text: nil, caption: 'бот что это', message_id: 1, reply_to_message: nil, photo: [photo])

    file_obj = OpenStruct.new(file_path: 'photos/file_0.jpg')
    api = Object.new
    api.define_singleton_method(:getFile) { |**_| file_obj }
    bot = OpenStruct.new(api: api)

    ctx = CommandContext.new(
      bot: bot, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "бот что это"
    )
    command = Commands::GptChat.new(ctx)

    # Stub HTTParty.get to return fake image data
    fake_response = OpenStruct.new(code: 200, body: 'fake_image_bytes')
    HTTParty.stub(:get, fake_response) do
      result = command.send(:extract_image)
      assert result.is_a?(Hash)
      assert_equal 'image/jpeg', result[:media_type]
      assert_equal Base64.strict_encode64('fake_image_bytes'), result[:data]
    end
  end

  # download_photo returns nil when getFile raises an error
  def test_download_photo_getfile_error
    photo = OpenStruct.new(file_id: 'photo123')
    msg = OpenStruct.new(text: nil, caption: 'бот что', message_id: 1, reply_to_message: nil, photo: [photo])

    api = Object.new
    api.define_singleton_method(:getFile) { |**_| raise "API error" }
    bot = OpenStruct.new(api: api)

    ctx = CommandContext.new(
      bot: bot, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_image)
  end
end

# ==========================================================================
# GptChatExecuteTest — tests that require FakeGptMaster for execute flow
# ==========================================================================
class GptChatExecuteTest < BotTest
  include AgentTestHelpers
  include Fixtures::Users

  def setup
    super
    @saved_tools = Agent::ToolRegistry.instance_variable_get(:@tools)&.dup || []
    Agent::ToolRegistry.instance_variable_set(:@tools, [])
    @original_gpt_master = ::GptMaster
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, FakeGptMaster)
    FakeGptMaster.reset!
    stub_settings!
    @user = member_user
  end

  def teardown
    Agent::ToolRegistry.instance_variable_set(:@tools, @saved_tools)
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, @original_gpt_master)
    super
  end

  # "бот ты ..." phrases go to the agent — not to a canned pattern-based response
  def test_phrase_goes_to_agent
    FakeGptMaster.enqueue(anthropic_text('agent reply about язь'))

    msg = OpenStruct.new(text: "бот ты причинно-следственная язь", message_id: 1, reply_to_message: nil)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "бот ты причинно-следственная язь"
    )
    result = Commands::GptChat.new(ctx).execute
    assert_equal :text, result.type
    assert_equal 'agent reply about язь', result.payload
  end

  # Keyword-matching messages also go to agent
  def test_keyword_message_goes_to_agent
    FakeGptMaster.enqueue(anthropic_text('agent reply'))

    msg = OpenStruct.new(text: "бот расскажи про язь", message_id: 1, reply_to_message: nil)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "бот расскажи про язь"
    )
    result = Commands::GptChat.new(ctx).execute
    assert_equal :text, result.type
    assert_equal 'agent reply', result.payload
  end

  # Photo with caption "бот что это" — agent receives the image from the current message
  # (production bug: photo messages were dropped because message.text is nil for photos,
  #  and even after fixing that, only reply_to photos were extracted, not current message photos)
  def test_photo_with_caption_sends_image_to_agent
    photo = OpenStruct.new(file_id: 'photo123')
    file_obj = OpenStruct.new(file_path: 'photos/file_0.jpg')
    api = Object.new
    api.define_singleton_method(:getFile) { |**_| file_obj }
    bot = OpenStruct.new(api: api)

    msg = OpenStruct.new(text: nil, caption: "бот что это", message_id: 1,
                         reply_to_message: nil, photo: [photo])

    FakeGptMaster.enqueue(anthropic_text('I see a cat'))

    fake_response = OpenStruct.new(code: 200, body: 'fake_image_bytes')
    HTTParty.stub(:get, fake_response) do
      ctx = CommandContext.new(
        bot: bot, message: msg, user: @user,
        chat_id: 100, radio: nil,
        reply_master: OpenStruct.new,
        cmd: "бот что это"
      )
      result = Commands::GptChat.new(ctx).execute
      assert_equal :text, result.type
      assert_equal 'I see a cat', result.payload

      # Verify agent received image in the message
      first_call = FakeGptMaster.calls.first
      user_msg = first_call[:messages].first
      assert user_msg[:content].is_a?(Array), 'content should be array for image messages'
      types = user_msg[:content].map { |b| b[:type] }
      assert_includes types, 'image'
    end
  end

  # Photo with caption but no "бот" prefix — not matched, no execute
  # (message_responder uses caption as text fallback, but GptChat still needs pattern match)
  def test_photo_without_bot_prefix_no_match
    msg = OpenStruct.new(text: nil, caption: "просто фото", message_id: 1,
                         reply_to_message: nil, photo: [OpenStruct.new(file_id: 'x')])
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "просто фото"
    )
    refute Commands::GptChat.new(ctx).match?
  end

  private

  def default_chat_gpt
    {
      'agent_prompt' => "<%- if image -%>[IMAGE]\n<%- end -%><%- if phrase -%>PHRASE: <%= phrase %>\n<%- end -%>{REQUEST} | {CONTEXT} | {KNOWLEDGE}",
      'context_messages_size' => 10,
      'providers' => { 'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' } },
      'settings' => { 'agent' => { 'provider' => 'anthropic', 'model' => 'fake', 'max_tokens' => 100 } }
    }
  end
end

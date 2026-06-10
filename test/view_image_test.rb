require_relative 'test_helper'

require 'ostruct'

# Re-define Settings with the full production module (test_helper defines a minimal one)
Object.send(:remove_const, :Settings) if defined?(Settings)
require_relative '../lib/settings'
require_relative '../lib/gpt_master'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/runner'
require_relative '../lib/telegram_file'
require_relative '../lib/chat_context'
require_relative '../lib/agent/tools/view_image'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# ==========================================================================
# Helpers
# ==========================================================================
module ViewImageTestHelpers
  # Two openai-compat settings (agent + agent_vision) — the live prod shape
  # (DeepSeek + grok). Overridable per test for the mismatch / absent cases.
  def stub_settings!(settings_overrides: nil, providers_overrides: nil)
    Settings.instance_variable_set(:@_settings, OpenStruct.new(
      radio: { 'path' => '/music', 'host_path' => nil },
      telegram: { 'token' => '123456:ABCDEF' },
      chat_gpt: {
        'agent_prompt' => "{REQUEST} | {CONTEXT} | {KNOWLEDGE}",
        'context_messages_size' => 10,
        'providers' => providers_overrides || {
          'deepseek' => { 'api_key' => 'fake', 'api_type' => 'openai' },
          'xai'      => { 'api_key' => 'fake', 'api_type' => 'openai' },
        },
        'settings' => settings_overrides || {
          'agent'        => { 'provider' => 'deepseek', 'model' => 'deepseek-v4', 'max_tokens' => 100 },
          'agent_vision' => { 'provider' => 'xai', 'model' => 'grok-4-fast', 'max_tokens' => 100 },
        }
      }
    ))
  end

  def openai_text(text)
    { 'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => text },
                      'finish_reason' => 'stop' }] }
  end

  def openai_tool_calls(calls, reasoning: nil)
    msg = { 'role' => 'assistant', 'content' => nil,
            'tool_calls' => calls.map { |c|
              { 'id' => c[:id], 'type' => 'function',
                'function' => { 'name' => c[:name], 'arguments' => (c[:input] || {}).to_json } }
            } }
    msg['reasoning_content'] = reasoning if reasoning
    { 'choices' => [{ 'message' => msg, 'finish_reason' => 'tool_calls' }] }
  end

  def anthropic_text(text)
    { 'content' => [{ 'type' => 'text', 'text' => text }] }
  end

  def anthropic_tool_call(name, input, id: 'call_1')
    { 'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }] }
  end

  def build_runner(text:, user:, **opts)
    defaults = { context: '[]', knowledge: '', radio: nil,
                 chat_id: 100, api: nil, image: nil, phrase: nil }
    Agent::Runner.new(**defaults.merge(opts).merge(text: text, user: user))
  end
end

# Scripted GptMaster replacement. Unlike agent_test's fake, resolve_setting
# reads the stubbed Settings so per-setting api_type (agent vs agent_vision)
# resolves the way production GptMaster.resolve_setting does — that's the
# contract can_view_image? and the mid-loop upgrade depend on.
class ViFakeGptMaster
  @@responses = []
  @@calls     = []

  def self.enqueue(*responses) = @@responses = responses.dup
  def self.calls               = @@calls
  def self.reset!              = (@@responses = []; @@calls = [])

  def self.resolve_setting(name)
    cfg = Settings.chat_gpt
    setting  = cfg['settings'][name] || raise("Unknown chat_gpt setting: #{name}")
    provider = cfg['providers'][setting['provider']] || raise("Unknown provider")
    { api_key: 'fake', api_type: provider['api_type'], api_url: 'http://fake',
      model: setting['model'], max_tokens: setting['max_tokens'] }
  end

  def self.split_cache_break(content)
    marker = '{CACHE_BREAK}'
    return [nil, content] unless content.include?(marker)
    prefix, suffix = content.split(marker, 2)
    [prefix.strip, suffix.strip]
  end

  def initialize(messages, setting: 'main', chat_id: nil, user_uid: nil, purpose: nil, system_prompt: nil)
    @messages = messages
    @setting  = setting
  end

  def call_raw(tools: [])
    @@calls << { messages: @messages.map(&:dup), setting: @setting, method: :call_raw }
    @@responses.shift
  end

  def call
    @@calls << { messages: @messages.map(&:dup), setting: @setting, method: :call }
    @@responses.shift
  end
end

# ==========================================================================
# ToolResult.image variant
# ==========================================================================
class ToolResultImageTest < Minitest::Test
  IMG = { data: 'b64payload', media_type: 'image/jpeg' }.freeze

  def test_image_constructor_and_readers
    r = Agent::ToolResult.image(user_text: 'loaded', image: IMG)
    assert r.image?
    assert_equal 'loaded', r.user_text
    assert_equal IMG, r.image
  end

  def test_image_result_is_not_deferred
    r = Agent::ToolResult.image(user_text: 'loaded', image: IMG)
    refute r.deferred?
  end

  def test_text_and_deferred_results_are_not_image
    refute Agent::ToolResult.text('hi').image?
    refute Agent::ToolResult.deferred(user_text: 'later', intent: 'do it').image?
  end
end

# ==========================================================================
# serialize_msg photo flag
# ==========================================================================
class SerializeMsgPhotoTest < Minitest::Test
  Row = Struct.new(:message_id, :reply_to_message_id, :message_thread_id,
                   :forwarded, :edited_at, :role, :body,
                   :attachment_file_id, :attachment_mime_type,
                   :attachment_title, :attachment_performer, :attachment_duration,
                   :attachment_photo_file_id,
                   :uid, :name, :first_name, :last_name, keyword_init: true) do
    def try(attr); respond_to?(attr) ? send(attr) : nil; end
  end

  def make(**attrs)
    defaults = { message_id: 1, role: 'user', body: 'hi', forwarded: false,
                 uid: 111, name: 'u', first_name: nil, last_name: nil }
    Row.new(**defaults.merge(attrs))
  end

  def test_photo_flag_set_when_photo_attachment_present
    h = ChatContext.serialize_msg(make(attachment_photo_file_id: 'PH1', body: '[фото]'))
    assert_equal true, h[:photo]
  end

  def test_photo_flag_omitted_when_no_photo
    h = ChatContext.serialize_msg(make)
    refute h.key?(:photo), 'photo key should be omitted (not false) when no photo'
  end

  def test_photo_row_does_not_emit_audio_flag
    h = ChatContext.serialize_msg(make(attachment_photo_file_id: 'PH1'))
    refute h.key?(:audio), 'photo attachment must not masquerade as audio'
  end

  def test_audio_row_does_not_emit_photo_flag
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AUD1', attachment_mime_type: 'audio/mpeg'))
    assert_equal true, h[:audio]
    refute h.key?(:photo)
  end

  def test_file_id_never_leaks_into_serialized_row
    h = ChatContext.serialize_msg(make(attachment_photo_file_id: 'SECRET_FILE_ID'))
    refute_includes h.to_json, 'SECRET_FILE_ID'
  end
end

# ==========================================================================
# save_message photo persistence (real MessageResponder against in-memory DB)
# ==========================================================================
class SaveMessagePhotoTest < BotTest
  include ViewImageTestHelpers
  include Fixtures::Users

  def setup
    super
    stub_settings!
    require_relative '../lib/message_responder'
    @user = member_user
  end

  PhotoSize = Struct.new(:file_id, :width, keyword_init: true)

  def msg(photo: nil, text: nil, caption: nil, audio: nil)
    OpenStruct.new(
      text: text, caption: caption, message_id: 42,
      reply_to_message: nil, message_thread_id: nil,
      edit_date: nil, date: Time.now.to_i, forward_origin: nil,
      voice: nil, audio: audio, document: nil, photo: photo,
      chat: OpenStruct.new(id: 100, title: 't'),
      from: OpenStruct.new(id: @user.uid, username: @user.name, first_name: 'T', last_name: nil)
    )
  end

  def save(message)
    MessageResponder.new(bot: nil, message: message, radio: nil).send(:save_message)
    Message.find_by(chat_id: 100, message_id: 42)
  end

  def test_photo_only_message_persists_with_marker_body
    row = save(msg(photo: [PhotoSize.new(file_id: 'P90', width: 90),
                           PhotoSize.new(file_id: 'P800', width: 800)]))
    assert row, 'photo-only message must be persisted'
    assert_equal '[фото]', row.body
    assert_equal 'P800', row.attachment_photo_file_id
  end

  def test_photo_with_caption_keeps_caption_as_body
    row = save(msg(photo: [PhotoSize.new(file_id: 'P1', width: 320)], caption: 'смотри какой кот'))
    assert_equal 'смотри какой кот', row.body
    assert_equal 'P1', row.attachment_photo_file_id
  end

  def test_photo_size_capped_at_1280
    row = save(msg(photo: [PhotoSize.new(file_id: 'P90', width: 90),
                           PhotoSize.new(file_id: 'P1280', width: 1280),
                           PhotoSize.new(file_id: 'P2560', width: 2560)]))
    assert_equal 'P1280', row.attachment_photo_file_id, 'must pick the largest size ≤ 1280px, not the absolute largest'
  end

  def test_photo_without_width_falls_back_to_smallest
    row = save(msg(photo: [OpenStruct.new(file_id: 'PA'), OpenStruct.new(file_id: 'PB')]))
    assert_equal 'PA', row.attachment_photo_file_id,
                 'no width info → conservative fallback to the smallest size'
  end

  def test_text_message_has_no_photo_file_id
    row = save(msg(text: 'просто текст'))
    assert_nil row.attachment_photo_file_id
  end

  def test_audio_only_message_still_uses_audio_marker
    audio = OpenStruct.new(file_id: 'AUD', mime_type: 'audio/mpeg', title: nil, performer: nil, duration: 10)
    row = save(msg(audio: audio))
    assert_equal '[аудио]', row.body
    assert_equal 'AUD', row.attachment_file_id
    assert_nil row.attachment_photo_file_id
  end
end

# ==========================================================================
# Bot-generated images: photo file_id capture on bot-side persistence
# ==========================================================================
class BotGeneratedImageTest < BotTest
  PHOTO_SIZES_HASH = [
    { 'file_id' => 'S90',   'width' => 90 },
    { 'file_id' => 'S800',  'width' => 800 },
    { 'file_id' => 'S1280', 'width' => 1280 },
    { 'file_id' => 'S2560', 'width' => 2560 },
  ].freeze

  def test_pick_photo_file_id_with_hash_sizes
    assert_equal 'S1280', Message.pick_photo_file_id(PHOTO_SIZES_HASH)
  end

  def test_pick_photo_file_id_with_object_sizes
    sizes = [OpenStruct.new(file_id: 'O90', width: 90), OpenStruct.new(file_id: 'O800', width: 800)]
    assert_equal 'O800', Message.pick_photo_file_id(sizes)
  end

  def test_pick_photo_file_id_nil_for_blank
    assert_nil Message.pick_photo_file_id(nil)
    assert_nil Message.pick_photo_file_id([])
  end

  def test_photo_file_id_from_result_envelope_hash
    resp = { 'result' => { 'message_id' => 7, 'photo' => PHOTO_SIZES_HASH } }
    assert_equal 'S1280', Message.photo_file_id_from(resp)
  end

  def test_photo_file_id_from_object_response
    resp = OpenStruct.new(message_id: 7, photo: [OpenStruct.new(file_id: 'X', width: 320)])
    assert_equal 'X', Message.photo_file_id_from(resp)
  end

  def test_photo_file_id_from_non_photo_response
    assert_nil Message.photo_file_id_from(OpenStruct.new(message_id: 7))
    assert_nil Message.photo_file_id_from({ 'result' => { 'message_id' => 7 } })
  end

  # persist_bot_reply captures the photo file_id from a sendPhoto response —
  # this is what makes the bot's own generated images viewable later.
  def test_persist_bot_reply_captures_photo_file_id
    resp = OpenStruct.new(message_id: 900, message_thread_id: nil,
                          photo: [OpenStruct.new(file_id: 'GEN1', width: 800)])
    Message.persist_bot_reply(chat_id: 100, body: '[картинка]', response: resp)
    row = Message.find_by(chat_id: 100, message_id: 900)
    assert_equal 'GEN1', row.attachment_photo_file_id
    assert_equal 'bot', row.role
  end

  def test_persist_bot_reply_text_response_has_no_photo_file_id
    resp = OpenStruct.new(message_id: 901, message_thread_id: nil)
    Message.persist_bot_reply(chat_id: 100, body: 'обычный текст', response: resp)
    assert_nil Message.find_by(chat_id: 100, message_id: 901).attachment_photo_file_id
  end

  # The serialized context row for a bot-generated image carries photo: true
  # → the agent can call view_image on its own output.
  def test_bot_photo_row_serializes_with_photo_flag
    resp = { 'result' => { 'message_id' => 902, 'photo' => PHOTO_SIZES_HASH } }
    Message.persist_bot_reply(chat_id: 100, body: '🎨 кот в скафандре', response: resp)
    row = Message.left_outer_joins(:user).select(ChatContext::SELECT_COLS)
                 .find_by(chat_id: 100, message_id: 902)
    h = ChatContext.serialize_msg(row)
    assert_equal true, h[:photo]
    assert_equal 'bot', h[:role]
  end
end

# ==========================================================================
# view_image tool handler
# ==========================================================================
class ViewImageToolTest < BotTest
  include ViewImageTestHelpers
  include Fixtures::Users
  include Fixtures::Messages

  CHAT = 100
  IMG  = { data: 'b64', media_type: 'image/jpeg' }.freeze

  def setup
    super
    stub_settings!
    @tool = Agent::ToolRegistry.find('view_image')
    assert @tool, 'view_image tool must be registered'
    @user = member_user
    @api  = Object.new # never actually called when download is stubbed
  end

  def call_tool(args, ctx_overrides = {})
    ctx = { chat_id: CHAT, api: @api, user: @user, can_view_image: true }.merge(ctx_overrides)
    @tool.handler.call(args, ctx)
  end

  def with_download_stub(result)
    original = TelegramFile.method(:download_image)
    TelegramFile.define_singleton_method(:download_image) { |*_a, **_k| result }
    yield
  ensure
    TelegramFile.define_singleton_method(:download_image, original)
  end

  def test_returns_image_result_for_stored_photo
    user_message(chat_id: CHAT, body: '[фото]', user: @user,
                 attrs: { message_id: 555, attachment_photo_file_id: 'PH555' })
    result = with_download_stub(IMG) { call_tool({ 'message_id' => 555 }) }
    assert_kind_of Agent::ToolResult, result
    assert result.image?
    assert_equal IMG, result.image
    assert_includes result.user_text, '555'
  end

  def test_degrades_when_can_view_image_false
    result = call_tool({ 'message_id' => 555 }, can_view_image: false)
    assert_kind_of String, result
    assert_match(/недоступен/, result)
  end

  def test_errors_without_api
    result = call_tool({ 'message_id' => 555 }, api: nil)
    assert_kind_of String, result
    assert_match(/Telegram API/, result)
  end

  def test_reports_missing_photo
    user_message(chat_id: CHAT, body: 'обычный текст', user: @user, attrs: { message_id: 556 })
    result = call_tool({ 'message_id' => 556 })
    assert_kind_of String, result
    assert_match(/нет сохранённой картинки/, result)
  end

  def test_reports_unknown_message_id
    result = call_tool({ 'message_id' => 99_999 })
    assert_kind_of String, result
    assert_match(/нет сохранённой картинки/, result)
  end

  def test_reports_download_failure
    user_message(chat_id: CHAT, body: '[фото]', user: @user,
                 attrs: { message_id: 557, attachment_photo_file_id: 'PH557' })
    result = with_download_stub(nil) { call_tool({ 'message_id' => 557 }) }
    assert_kind_of String, result
    assert_match(/Не смог скачать/, result)
  end

  def test_does_not_cross_chats
    user_message(chat_id: 200, body: '[фото]', user: @user,
                 attrs: { message_id: 558, attachment_photo_file_id: 'PH558' })
    result = call_tool({ 'message_id' => 558 }) # ctx chat is 100
    assert_kind_of String, result
    assert_match(/нет сохранённой картинки/, result)
  end
end

# ==========================================================================
# Runner: can_view_image flag + mid-loop image injection + vision upgrade
# ==========================================================================
class RunnerImageInjectionTest < BotTest
  include ViewImageTestHelpers
  include Fixtures::Users

  IMG = { data: 'b64imgdata', media_type: 'image/jpeg' }.freeze

  def setup
    super
    @saved_tools = Agent::ToolRegistry.instance_variable_get(:@tools)&.dup || []
    Agent::ToolRegistry.instance_variable_set(:@tools, [])
    @original_gpt_master = ::GptMaster
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, ViFakeGptMaster)
    ViFakeGptMaster.reset!
    stub_settings!
    @user = member_user
  end

  def teardown
    Agent::ToolRegistry.instance_variable_set(:@tools, @saved_tools)
    Object.send(:remove_const, :GptMaster)
    Object.const_set(:GptMaster, @original_gpt_master)
    super
  end

  def register_image_tool(name: 'fetch_pic', image: IMG)
    Agent::ToolRegistry.register(
      name: name, description: 'fetch',
      handler: ->(_a, _c) { Agent::ToolResult.image(user_text: 'картинка загружена', image: image) }
    )
  end

  # --- can_view_image ctx flag ---

  def captured_ctx_flag
    flag = :unset
    Agent::ToolRegistry.register(
      name: 'probe', description: 'probe',
      handler: ->(_a, ctx) { flag = ctx[:can_view_image]; 'ok' }
    )
    ViFakeGptMaster.enqueue(openai_tool_calls([{ id: 'c1', name: 'probe' }]), openai_text('done'))
    build_runner(text: 'go', user: @user).run
    flag
  end

  def test_can_view_image_true_when_settings_share_api_type
    assert_equal true, captured_ctx_flag
  end

  def test_can_view_image_false_when_agent_vision_absent
    stub_settings!(settings_overrides: {
      'agent' => { 'provider' => 'deepseek', 'model' => 'deepseek-v4', 'max_tokens' => 100 }
    })
    assert_equal false, captured_ctx_flag
  end

  def test_can_view_image_false_on_api_type_mismatch
    stub_settings!(
      providers_overrides: {
        'deepseek'  => { 'api_key' => 'fake', 'api_type' => 'openai' },
        'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' },
      },
      settings_overrides: {
        'agent'        => { 'provider' => 'deepseek', 'model' => 'd', 'max_tokens' => 100 },
        'agent_vision' => { 'provider' => 'anthropic', 'model' => 'a', 'max_tokens' => 100 },
      }
    )
    assert_equal false, captured_ctx_flag
  end

  def test_can_view_image_true_when_already_on_vision
    # image: present → pick_setting routes to agent_vision (mismatched
    # api_type is irrelevant: no switch will be needed).
    stub_settings!(
      providers_overrides: {
        'deepseek'  => { 'api_key' => 'fake', 'api_type' => 'openai' },
        'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' },
      },
      settings_overrides: {
        'agent'        => { 'provider' => 'deepseek', 'model' => 'd', 'max_tokens' => 100 },
        'agent_vision' => { 'provider' => 'anthropic', 'model' => 'a', 'max_tokens' => 100 },
      }
    )
    flag = :unset
    Agent::ToolRegistry.register(
      name: 'probe', description: 'probe',
      handler: ->(_a, ctx) { flag = ctx[:can_view_image]; 'ok' }
    )
    ViFakeGptMaster.enqueue(anthropic_tool_call('probe', {}), anthropic_text('done'))
    build_runner(text: 'go', user: @user, image: IMG).run
    assert_equal true, flag
  end

  # --- openai injection path (live prod shape) ---

  def test_image_tool_injects_user_image_message_and_upgrades_setting
    register_image_tool
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'fetch_pic' }]),
      openai_text('вижу кота')
    )
    result = build_runner(text: 'глянь фото', user: @user).run
    assert_equal 'вижу кота', result

    calls = ViFakeGptMaster.calls
    assert_equal 2, calls.size
    assert_equal 'agent', calls[0][:setting]
    assert_equal 'agent_vision', calls[1][:setting], 'second iteration must run on agent_vision'

    iter2 = calls[1][:messages]
    image_msg = iter2.find { |m| (m[:role] || m['role']) == 'user' && (m[:content] || m['content']).is_a?(Array) }
    assert image_msg, 'an image-bearing user message must be appended'
    blocks = image_msg[:content] || image_msg['content']
    img_block = blocks.find { |b| (b[:type] || b['type']) == 'image' }
    assert img_block, 'user message must carry an image block'
    assert_equal 'b64imgdata', img_block.dig(:source, :data)
  end

  def test_tool_result_text_still_delivered_alongside_image
    register_image_tool
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'fetch_pic' }]),
      openai_text('ok')
    )
    build_runner(text: 'go', user: @user).run
    iter2 = ViFakeGptMaster.calls[1][:messages]
    tool_msg = iter2.find { |m| (m[:role] || m['role']) == 'tool' }
    assert tool_msg, 'tool result message must still exist'
    assert_includes tool_msg[:content].to_s, 'картинка загружена'
  end

  # Reviewer finding 2: with several tool calls in one iteration, ALL tool
  # messages must precede the injected user image message (openai contract:
  # every tool_call answered before another role appears).
  def test_image_user_message_comes_after_all_tool_results
    register_image_tool
    Agent::ToolRegistry.register(name: 'other', description: 'x', handler: ->(_a, _c) { 'plain' })
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'fetch_pic' }, { id: 'c2', name: 'other' }]),
      openai_text('done')
    )
    build_runner(text: 'go', user: @user).run
    iter2 = ViFakeGptMaster.calls[1][:messages]
    roles = iter2.map { |m| m[:role] || m['role'] }
    last_tool_idx  = roles.rindex('tool')
    image_user_idx = iter2.index { |m| (m[:role] || m['role']) == 'user' && (m[:content] || m['content']).is_a?(Array) }
    assert image_user_idx > last_tool_idx, 'image user turn must come after ALL tool messages'
  end

  # Reviewer finding 3: DeepSeek's reasoning_content must be stripped from
  # accumulated assistant messages when switching providers — another
  # openai-compat endpoint (grok) may reject the unknown field on replay.
  def test_reasoning_content_stripped_on_upgrade
    register_image_tool
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'fetch_pic' }], reasoning: 'thinking about cats'),
      openai_text('done')
    )
    build_runner(text: 'go', user: @user).run
    iter2 = ViFakeGptMaster.calls[1][:messages]
    assistant = iter2.find { |m| (m['role'] || m[:role]) == 'assistant' }
    assert assistant, 'assistant message must be replayed'
    refute assistant.key?('reasoning_content'),
           'reasoning_content must be stripped before replaying to the vision provider'
  end

  # No-switch baseline: reasoning_content is PRESERVED when no image tool
  # fires (the DeepSeek multi-turn rule from agent_test still holds).
  def test_reasoning_content_preserved_without_upgrade
    Agent::ToolRegistry.register(name: 'plain', description: 'x', handler: ->(_a, _c) { 'ok' })
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'plain' }], reasoning: 'keep me'),
      openai_text('done')
    )
    build_runner(text: 'go', user: @user).run
    iter2 = ViFakeGptMaster.calls[1][:messages]
    assistant = iter2.find { |m| (m['role'] || m[:role]) == 'assistant' }
    assert_equal 'keep me', assistant['reasoning_content']
  end

  # Cross-iteration: a second image fetch in a later iteration must not
  # re-trigger the upgrade (already on agent_vision) and still injects.
  def test_two_image_fetches_across_iterations
    register_image_tool
    ViFakeGptMaster.enqueue(
      openai_tool_calls([{ id: 'c1', name: 'fetch_pic' }]),
      openai_tool_calls([{ id: 'c2', name: 'fetch_pic' }]),
      openai_text('обе вижу')
    )
    result = build_runner(text: 'сравни два фото', user: @user).run
    assert_equal 'обе вижу', result
    calls = ViFakeGptMaster.calls
    assert_equal %w[agent agent_vision agent_vision], calls.map { |c| c[:setting] }
    iter3 = calls[2][:messages]
    image_user_msgs = iter3.select { |m| (m[:role] || m['role']) == 'user' && (m[:content] || m['content']).is_a?(Array) }
    assert_equal 2, image_user_msgs.size, 'each iteration injects its own image user message'
  end

  # MAX_ITERATIONS forced-final after an upgrade keeps the vision setting.
  def test_forced_final_uses_upgraded_setting
    register_image_tool
    responses = Array.new(Agent::Runner::MAX_ITERATIONS) { |i| openai_tool_calls([{ id: "c#{i}", name: 'fetch_pic' }]) }
    responses << 'forced final'
    ViFakeGptMaster.enqueue(*responses)
    result = build_runner(text: 'go', user: @user).run
    assert_equal 'forced final', result
    final_call = ViFakeGptMaster.calls.find { |c| c[:method] == :call }
    assert_equal 'agent_vision', final_call[:setting]
  end

  # --- anthropic merge path ---

  def stub_anthropic_settings!
    stub_settings!(
      providers_overrides: { 'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' } },
      settings_overrides: {
        'agent'        => { 'provider' => 'anthropic', 'model' => 'a', 'max_tokens' => 100 },
        'agent_vision' => { 'provider' => 'anthropic', 'model' => 'av', 'max_tokens' => 100 },
      }
    )
  end

  # Reviewer finding 3: lock the anthropic forced-final shape after an image
  # injection — the tail is [user: tool_result+image][user: budget
  # instruction]. Two consecutive user turns is the pre-existing forced-final
  # pattern (Anthropic merges consecutive same-role turns); the image must
  # ride the tool_result turn, never the budget-instruction turn.
  def test_anthropic_forced_final_after_image_injection
    stub_anthropic_settings!
    register_image_tool
    responses = Array.new(Agent::Runner::MAX_ITERATIONS) { |i| anthropic_tool_call('fetch_pic', {}, id: "c#{i}") }
    responses << 'forced final'
    ViFakeGptMaster.enqueue(*responses)
    result = build_runner(text: 'go', user: @user).run
    assert_equal 'forced final', result

    final_call = ViFakeGptMaster.calls.find { |c| c[:method] == :call }
    assert_equal 'agent_vision', final_call[:setting]
    msgs = final_call[:messages]

    budget_turn = msgs.last
    assert_equal 'user', budget_turn[:role]
    assert_match(/Лимит вызова инструментов/, budget_turn[:content].first[:text])
    refute(budget_turn[:content].any? { |b| (b[:type] || b['type']) == 'image' },
           'budget instruction turn must not carry image blocks')

    tool_turn = msgs[-2]
    types = tool_turn[:content].map { |b| b[:type] || b['type'] }
    assert_includes types, 'tool_result'
    assert_includes types, 'image', 'last iteration image must ride the tool_result turn'
  end

  def test_anthropic_image_merges_into_last_tool_result_message
    stub_anthropic_settings!
    register_image_tool
    ViFakeGptMaster.enqueue(
      anthropic_tool_call('fetch_pic', {}, id: 'c1'),
      anthropic_text('вижу')
    )
    result = build_runner(text: 'глянь', user: @user).run
    assert_equal 'вижу', result

    iter2 = ViFakeGptMaster.calls[1][:messages]
    assert_equal 'agent_vision', ViFakeGptMaster.calls[1][:setting]
    user_turns = iter2.select { |m| (m[:role] || m['role']) == 'user' && (m[:content] || m['content']).is_a?(Array) }
    last = user_turns.last
    types = last[:content].map { |b| b[:type] || b['type'] }
    assert_includes types, 'tool_result', 'image must merge into the tool_result turn'
    assert_includes types, 'image', 'image block must ride the same user turn (no consecutive user turns)'
    # No separate image-only user turn was appended after it.
    assert_equal iter2.rindex(last), iter2.size - 1
  end
end

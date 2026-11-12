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
    'default_model' => 'qwen-image-3-pro',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'multi_image' => true, 'desc' => 'NB2' },
      'wan-2.7'       => { 'provider' => 'atlas', 't2i' => 'alibaba/wan-2.7-pro/text-to-image',
                           'edit' => 'alibaba/wan-2.7/image-edit', 'desc' => 'Wan' },
      'qwen-image-3-pro' => { 'provider' => 'atlas', 't2i' => 'qwen-image-3.0-pro/text-to-image',
                              'edit' => 'qwen-image-3.0-pro/edit', 'multi_image' => true, 'desc' => 'Qwen' },
      'gpt-image-2.5-sunburst' => { 'provider' => 'atlas', 't2i' => 'openai/gpt-image-2.5-sunburst/text-to-image',
                                    'edit' => 'openai/gpt-image-2.5-sunburst/edit', 'multi_image' => true, 'desc' => 'Sunburst' },
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
    result = call_tool('prompt' => 'кот', 'model' => 'wan-2.7')
    assert_equal 'wan-2.7', last_params['model']
    assert_equal 'кот',     last_params['request']
    assert_kind_of Agent::ToolResult, result
    assert result.action?
    assert_equal 'queued', result.action_status
    assert_equal 'generate_image', result.action
    assert_equal BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').last.id, result.task_id
    assert_match(/очеред/, result.user_text)
  end

  def test_forum_thread_id_is_persisted_for_background_delivery
    @tool.handler.call({ 'prompt' => 'кот' },
                       { chat_id: CHAT, user: @user, forum_thread_id: 71 })
    assert_equal 71, last_params['forum_thread_id']
  end

  def test_omitted_model_defaults_to_catalog_default
    call_tool('prompt' => 'кот')
    assert_equal 'qwen-image-3-pro', last_params['model']
  end

  def test_invalid_model_falls_back_to_default
    call_tool('prompt' => 'кот', 'model' => 'midjourney')
    assert_equal 'qwen-image-3-pro', last_params['model']
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
    assert_equal 'wan-2.7', last_params['model']
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
    assert_equal 10, last_params['source_message_ids'].length
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
    assert_equal ids, last_params['source_message_ids'], 'worker caps after byte deduplication'
  end

  def test_exact_directive_and_inline_identity_are_authoritative
    ctx = { chat_id: CHAT, user: @user, user_initiated: true,
            request_text: 'Wan: Нарисуй «#42»!', photo_source_message_id: 11,
            image: { data: 'INLINE', media_type: 'image/jpeg' }, image_prompt_context: '[{"id":11,"msg":"снимок"}]' }
    @tool.handler.call({ 'prompt' => 'смягчённый текст', 'model' => 'nano-banana-2',
                         'edit_source' => true, 'source_message_ids' => [11] }, ctx)
    assert_equal 'Wan: Нарисуй «#42»!', last_params['request']
    assert_equal 'wan-2.7', last_params['model']
    assert_equal 'wan-2.7', last_params['user_requested_model']
    refute last_params.key?('source_message_ids')
    assert_equal 'снимок', JSON.parse(last_params['prompt_context']).first['msg']
    assert_equal 999, last_params['origin_user_id']
  end

  def test_explicit_single_image_model_conflict_does_not_enqueue
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Wan объедини фото' }
    result = @tool.handler.call({ 'prompt' => 'объедини', 'source_message_ids' => [10, 11] }, ctx)
    assert_equal 'queued', result.action_status
    assert_equal 'wan-2.7', last_params['user_requested_model']
    assert_equal [10, 11], last_params['source_message_ids']
  end

  def test_failed_inline_download_remains_edit_intent
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'исправь фото', photo_source_present: true }
    @tool.handler.call({ 'prompt' => 'исправь', 'edit_source' => true }, ctx)
    assert_equal true, last_params['edit_intended']
  end

  def test_missing_inline_file_does_not_discard_history_alias
    Message.create!(chat_id: CHAT, message_id: 44, attachment_photo_file_id: 'same', role: 'user')
    Message.create!(chat_id: CHAT, message_id: 45, attachment_photo_file_id: 'same', role: 'user')
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'исправь фото',
            photo_source_present: true, photo_source_message_id: 44 }
    @tool.handler.call({ 'prompt' => 'смягчённо', 'edit_source' => true, 'source_message_ids' => [45] }, ctx)
    assert_equal true, last_params['edit_intended']
    assert_equal [44], last_params['source_message_ids']
  end

  def test_snapshot_keeps_complete_rows_and_prioritizes_reply
    rows = [{ id: 3, msg: 'target' }, { id: 4, msg: 'x' * 9000 }, { id: 5, msg: 'recent' }]
    snapshot = ImageGen::EnqueueSnapshot.capture(rows.to_json, limit: 100, reply_to: 3)
    assert_equal [3, 5], JSON.parse(snapshot).map { |row| row['id'] }
    assert_operator snapshot.bytesize, :<=, 100
  end

  def test_rate_limit_retains_original_directive
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Дорисуй «#42»!' }
    RateLimiter.stub(:exceeded?, true) do
      RateLimiter.stub(:minutes_until_free, 5) do
        RateLimiter.stub(:reply, 'лимит') do
          result = @tool.handler.call({ 'prompt' => 'смягчённый запрос' }, ctx)
          assert_includes result.deferred_intent, 'Дорисуй «#42»!'
          refute_includes result.deferred_intent, 'смягчённый'
        end
      end
    end
  end

  def test_rejects_excess_candidates_before_any_database_lookup
    result = Message.stub(:where, ->(*) { flunk 'must not query messages' }) do
      call_tool('prompt' => 'комбо', 'source_message_ids' => (1..25).to_a)
    end
    assert_equal 'failed', result.action_status
    assert_nil BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').last
  end

  def test_knowledge_snapshot_keeps_most_relevant_first
    rows = [{ fact: 'high' }, { fact: 'low', padding: 'x' * 90 }]
    snapshot = ImageGen::EnqueueSnapshot.capture(rows.to_json, limit: 35, recent_first: false)
    assert_equal ['high'], JSON.parse(snapshot).map { |row| row['fact'] }
  end

  def test_missing_model_edit_flag_still_uses_attached_photo
    ['Поменяй фон', 'Переодень человека'].each do |request|
      ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: request,
              photo_source_present: true, photo_source_message_id: 11,
              image: { data: 'INLINE', media_type: 'image/jpeg' } }
      @tool.handler.call({ 'prompt' => request }, ctx)
      assert_equal true, last_params['edit_intended']
      assert_equal 'INLINE', last_params['input_images'].first['data']
    end
  end

  def test_missing_edit_bytes_never_turns_caption_into_text_to_image
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Поменяй фон',
            photo_source_present: true, photo_source_message_id: 11 }
    @tool.handler.call({ 'prompt' => 'фон' }, ctx)
    assert_equal true, last_params['edit_intended']
    assert_equal [11], last_params['source_message_ids']
  end

  def test_edit_intent_ignores_negated_and_quoted_verbs
    refute ImageGen::EditIntent.requested?('Не меняй фон')
    refute ImageGen::EditIntent.requested?('Напиши «переодень человека»')
    assert ImageGen::EditIntent.requested?('Не меняй фон, но добавь шляпу')
  end

  def test_positive_choice_survives_excluded_model_and_records_origin
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, message_id: 77,
            request_text: 'Нарисуй кота в Qwen, не используй GPT Image 2.5 Sunburst' }
    @tool.handler.call({ 'prompt' => 'кот', 'model' => 'gpt-image-2.5-sunburst' }, ctx)
    assert_equal 'qwen-image-3-pro', last_params['model']
    assert_equal true, last_params['model_explicit']
    assert_equal ['gpt-image-2.5-sunburst'], last_params['excluded_models']
  end

  def test_excluded_only_model_cannot_be_autonomously_selected
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Нарисуй кота, не используй Qwen' }
    @tool.handler.call({ 'prompt' => 'кот', 'model' => 'qwen-image-3-pro' }, ctx)
    refute_equal 'qwen-image-3-pro', last_params['model']
    assert_equal false, last_params['model_explicit']
    assert_equal ['qwen-image-3-pro'], last_params['excluded_models']
  end

  def test_coordinated_model_exclusions_are_preserved_for_fallback
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Нарисуй кота без Wan, Flux и Qwen' }
    @tool.handler.call({ 'prompt' => 'кот', 'model' => 'wan-2.7' }, ctx)
    assert_equal false, last_params['model_explicit']
    assert_equal ['wan-2.7', 'qwen-image-3-pro'], last_params['excluded_models']
    refute_includes last_params['excluded_models'], last_params['model']
  end

  def test_history_only_edit_has_no_missing_inline_source
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Измени фото из сообщения 123',
            photo_source_present: false, image: nil }
    @tool.handler.call({ 'prompt' => 'измени фото', 'edit_source' => true, 'source_message_ids' => [123] }, ctx)
    assert_equal true, last_params['edit_intended']
    assert_equal false, last_params['missing_inline_source']
    assert_equal [123], last_params['source_message_ids']
  end

  def test_mixed_inline_and_history_sources_are_kept_for_combine
    ['Добавь кота из фото #41 на это прикреплённое фото', 'Объедини это фото и фото #41'].each do |request|
      ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: request,
              photo_source_present: true, photo_source_message_id: 90,
              image: { data: 'INLINE', media_type: 'image/jpeg' } }
      result = @tool.handler.call({ 'prompt' => request, 'source_message_ids' => [41] }, ctx)
      assert_equal 'queued', result.action_status
      assert_equal true, last_params['edit_intended']
      assert_equal [41], last_params['source_message_ids']
      assert_equal 'INLINE', last_params['input_images'].first['data']
      assert_equal 90, last_params['input_images'].first['source_message_id']
    end
  end

  def test_find_photo_then_edit_requires_a_real_source_before_enqueue
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Найди фото Земфиры и добавь ей очки' }
    result = @tool.handler.call({ 'prompt' => 'Земфира в очках' }, ctx)
    assert_equal 'failed', result.action_status
    assert_match(/Ответь на выбранное фото/, result.user_text)
    assert_empty BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate')
  end

  def test_find_photo_and_edit_allows_existing_source
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Найди фото Земфиры и добавь ей очки',
            photo_source_present: true, photo_source_message_id: 41, image: { data: 'INLINE', media_type: 'image/jpeg' } }
    result = @tool.handler.call({ 'prompt' => 'Земфира в очках', 'edit_source' => true }, ctx)
    assert_equal 'queued', result.action_status
    assert_equal 'INLINE', last_params['input_images'].first['data']
  end

  def test_find_photo_and_edit_accepts_explicit_source_id
    ctx = { chat_id: CHAT, user: @user, user_initiated: true, request_text: 'Найди фото Земфиры и добавь ей очки' }
    result = @tool.handler.call({ 'prompt' => 'очки', 'source_message_ids' => [41] }, ctx)
    assert_equal 'queued', result.action_status
    assert_equal [41], last_params['source_message_ids']
    assert_equal true, last_params['edit_intended']
  end

  def test_find_and_draw_is_not_confused_with_find_and_edit
    refute ImageGen::EditIntent.find_photo_then_edit?('Найди фото Земфиры и нарисуй её портрет')
    refute ImageGen::EditIntent.find_photo_then_edit?('Найди фото Земфиры, нарисуй портрет и добавь очки')
    assert ImageGen::EditIntent.find_photo_then_edit?('Найди фото Земфиры, дорисуй на нём фон и нарисуй дерево')
    refute ImageGen::EditIntent.find_photo_then_edit?('Не ищи фото Земфиры, добавь очки')
    refute ImageGen::EditIntent.find_photo_then_edit?('Напиши «найди фото и добавь очки»')
  end

  def test_scene_exclusion_preserves_positive_sunburst_selection
    ctx = { chat_id: CHAT, user: @user, user_initiated: true,
            request_text: 'Нарисуй кота без шляпы через Sunburst' }
    @tool.handler.call({ 'prompt' => 'кот', 'model' => 'qwen-image-3-pro' }, ctx)
    assert_equal 'gpt-image-2.5-sunburst', last_params['model']
    assert_equal true, last_params['model_explicit']
    assert_empty last_params['excluded_models']
  end

  def test_history_source_aliases_resolve_once_by_telegram_file_identity
    [501, 502].each do |mid|
      Message.create!(chat_id: CHAT, message_id: mid, role: 'user', attachment_photo_file_id: 'same-telegram-file')
    end
    call_tool('prompt' => 'объедини', 'source_message_ids' => [501, 502])
    assert_equal [501], last_params['source_message_ids']
    assert_equal true, last_params['edit_intended']
  end

  def test_unresolved_history_sources_remain_distinct
    call_tool('prompt' => 'объедини', 'source_message_ids' => [501, 502])
    assert_equal [501, 502], last_params['source_message_ids']
  end

  def test_distinct_history_source_files_are_not_collapsed
    Message.create!(chat_id: CHAT, message_id: 501, role: 'user', attachment_photo_file_id: 'file-one')
    Message.create!(chat_id: CHAT, message_id: 502, role: 'user', attachment_photo_file_id: 'file-two')
    call_tool('prompt' => 'объедини', 'source_message_ids' => [501, 502])
    assert_equal [501, 502], last_params['source_message_ids']
  end

  # definitions_for builds the model enum from the catalog and marks model +
  # edit_source optional (not required), while prompt stays required.
  def test_definitions_build_model_enum_and_required_array
    %w[anthropic openai].each do |api|
      defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: api)
      d = defs.find { |x| (api == 'anthropic' ? x[:name] : x[:function][:name]) == 'generate_image' }
      refute_nil d, "#{api}: generate_image must be present"
      schema = api == 'anthropic' ? d[:input_schema] : d[:function][:parameters]
      assert_equal %w[nano-banana-2 wan-2.7 qwen-image-3-pro gpt-image-2.5-sunburst], schema[:properties]['model'][:enum], "#{api}: enum from catalog"
      assert_match(/NB2/, schema[:properties]['model'][:description], "#{api}: desc suffix appended")
      assert_includes schema[:required], 'prompt', "#{api}: prompt required"
      refute_includes schema[:required], 'model', "#{api}: model optional"
      refute_includes schema[:required], 'edit_source', "#{api}: edit_source optional"
      refute_includes schema[:required], 'source_message_ids', "#{api}: source_message_ids optional"
      assert_equal 'array', schema[:properties]['source_message_ids'][:type], "#{api}: source_message_ids is an array"
    end
  end
end

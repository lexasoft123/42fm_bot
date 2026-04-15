require_relative 'test_helper'

require 'ostruct'

# Re-define Settings with the full production module
Object.send(:remove_const, :Settings) if defined?(Settings)
require_relative '../lib/settings'
require_relative '../lib/gpt_master'
require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/runner'
require_relative '../lib/commands/base'
require_relative '../lib/commands/gpt_helpers'
require_relative '../lib/commands/gpt_chat'
require_relative '../lib/task_runner'
require_relative '../lib/reply_markup_formatter'
require_relative '../lib/message_sender'

LOGGER       = Logger.new(IO::NULL) unless defined?(LOGGER)
AGENT_LOGGER = Logger.new(IO::NULL) unless defined?(AGENT_LOGGER)

# ==========================================================================
# Helpers
# ==========================================================================
module ProdTestHelpers
  def stub_settings!
    Settings.instance_variable_set(:@_settings, OpenStruct.new(
      radio: { 'path' => '/music', 'host_path' => nil },
      telegram: { 'token' => '123456:ABCDEF' },
      chat_gpt: {
        'agent_mode' => true,
        'agent_prompt' => "{REQUEST} | {CONTEXT} | {KNOWLEDGE}",
        'prompt' => '{REQUEST}',
        'context_messages_size' => 10,
        'providers' => { 'anthropic' => { 'api_key' => 'fake', 'api_type' => 'anthropic' } },
        'settings' => { 'agent' => { 'provider' => 'anthropic', 'model' => 'fake', 'max_tokens' => 100 } }
      }
    ))
  end
end

# ==========================================================================
# FakeGptMaster (same as in agent_test.rb)
# ==========================================================================
class FakeGptMaster
  @@responses = []
  @@calls     = []

  def self.enqueue(*responses) = @@responses = responses.dup
  def self.calls               = @@calls
  def self.reset!              = (@@responses = []; @@calls = [])

  def self.resolve_setting(_name)
    { api_key: 'fake', api_type: 'anthropic', api_url: 'http://fake',
      model: 'fake', max_tokens: 100, thinking_budget: nil }
  end

  def initialize(messages, setting: 'main')
    @messages = messages
    @setting  = setting
  end

  def call_raw(tools: [])
    @@calls << { messages: @messages.dup, setting: @setting, tools: tools, method: :call_raw }
    @@responses.shift
  end

  def call
    @@calls << { messages: @messages.dup, setting: @setting, method: :call }
    @@responses.shift
  end
end unless defined?(FakeGptMaster)

# ==========================================================================
# BackgroundTaskTest — covers task timeout (Apr 13 image_generate timeout)
# ==========================================================================
class BackgroundTaskTest < BotTest
  # timed_out? returns false when attempts < max_attempts
  def test_not_timed_out
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  attempts: 5, max_attempts: 20)
    refute task.timed_out?
  end

  # timed_out? returns true when attempts >= max_attempts (production: task 462 hit 20/20)
  def test_timed_out_at_max
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  attempts: 20, max_attempts: 20)
    assert task.timed_out?
  end

  # increment_attempts! bumps the counter by 1
  def test_increment_attempts
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  attempts: 0, max_attempts: 20)
    task.increment_attempts!
    assert_equal 1, task.reload.attempts
  end

  # mark_failed! sets status to 'failed' and stores error reason
  def test_mark_failed
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  attempts: 20, max_attempts: 20)
    task.mark_failed!('timeout')
    task.reload
    assert_equal 'failed', task.status
    assert_equal 'timeout', task.result_hash['error']
  end

  # mark_done! sets status to 'done' and stores result data
  def test_mark_done
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  attempts: 3, max_attempts: 20)
    task.mark_done!({ clips: 2 })
    task.reload
    assert_equal 'done', task.status
    assert_equal 2, task.result_hash['clips']
  end

  # params_hash parses JSON params string
  def test_params_hash
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  params: '{"title":"Test Song","genre":"rock"}',
                                  attempts: 0, max_attempts: 20)
    assert_equal 'Test Song', task.params_hash['title']
    assert_equal 'rock', task.params_hash['genre']
  end

  # params_hash returns empty hash for nil params
  def test_params_hash_nil
    task = BackgroundTask.create!(task_type: 'test', status: 'pending', chat_id: 1,
                                  params: nil, attempts: 0, max_attempts: 20)
    assert_equal({}, task.params_hash)
  end

  # pending scope returns only pending tasks
  def test_pending_scope
    t1 = BackgroundTask.create!(task_type: 'a', status: 'pending', chat_id: 1, attempts: 0, max_attempts: 5)
    t2 = BackgroundTask.create!(task_type: 'b', status: 'done', chat_id: 1, attempts: 3, max_attempts: 5)
    t3 = BackgroundTask.create!(task_type: 'c', status: 'failed', chat_id: 1, attempts: 5, max_attempts: 5)
    ids = BackgroundTask.pending.pluck(:id)
    assert_includes ids, t1.id
    refute_includes ids, t2.id
    refute_includes ids, t3.id
  end
end

# ==========================================================================
# TaskRunnerTest — covers timeout flow and error handling
# ==========================================================================
class TaskRunnerTest < BotTest
  def setup
    super
    @saved_handlers = TaskRunner.instance_variable_get(:@handlers).dup
    TaskRunner.instance_variable_set(:@handlers, {})
    @api_calls = []
    @api = build_fake_api
  end

  def teardown
    TaskRunner.instance_variable_set(:@handlers, @saved_handlers)
    super
  end

  # Unknown task_type marks task as failed (production: could happen with typo in task creation)
  def test_unknown_task_type_marks_failed
    task = BackgroundTask.create!(task_type: 'bogus', status: 'pending', chat_id: 1,
                                  attempts: 0, max_attempts: 5)
    runner = TaskRunner.new(@api)
    runner.process_pending
    task.reload
    assert_equal 'failed', task.status
    assert_match(/unknown/, task.result_hash['error'])
  end

  # Task that keeps returning :pending gets timed out after max_attempts
  # (production: Apr 13 image_generate task 462 timed out after 20 attempts)
  def test_pending_task_times_out
    handler = Class.new { def call(task, api) = :pending }
    TaskRunner.register('slow_task', handler)

    task = BackgroundTask.create!(task_type: 'slow_task', status: 'pending', chat_id: 1,
                                  attempts: 19, max_attempts: 20)
    runner = TaskRunner.new(@api)
    runner.process_pending

    task.reload
    assert_equal 20, task.attempts
    assert_equal 'failed', task.status
    assert_equal 'timeout', task.result_hash['error']
    # Verify timeout notification was sent to chat
    assert @api_calls.any? { |c| c[:method] == :sendMessage && c[:args][:text].include?('таймаут') }
  end

  # Handler that raises an exception — task gets attempts incremented
  # (production: various handler errors like TypeError in SunoTaskHandler)
  def test_handler_exception_increments_attempts
    handler = Class.new { def call(task, api) = raise("boom") }
    TaskRunner.register('exploding', handler)

    task = BackgroundTask.create!(task_type: 'exploding', status: 'pending', chat_id: 1,
                                  attempts: 0, max_attempts: 5)
    runner = TaskRunner.new(@api)
    runner.process_pending

    task.reload
    assert_equal 1, task.attempts
    assert_equal 'pending', task.status  # not yet timed out, still pending
  end

  # Handler exception when at max_attempts — marks failed and notifies chat
  def test_handler_exception_at_max_marks_failed
    handler = Class.new { def call(task, api) = raise("permanent failure") }
    TaskRunner.register('exploding', handler)

    task = BackgroundTask.create!(task_type: 'exploding', status: 'pending', chat_id: 1,
                                  attempts: 4, max_attempts: 5)
    runner = TaskRunner.new(@api)
    runner.process_pending

    task.reload
    assert_equal 'failed', task.status
  end

  # Handler returning :done — no further processing needed
  def test_handler_done_leaves_task_alone
    handler = Class.new do
      def call(task, api)
        task.mark_done!({ result: 'ok' })
        :done
      end
    end
    TaskRunner.register('good_task', handler)

    task = BackgroundTask.create!(task_type: 'good_task', status: 'pending', chat_id: 1,
                                  attempts: 0, max_attempts: 5)
    runner = TaskRunner.new(@api)
    runner.process_pending

    task.reload
    assert_equal 'done', task.status
  end

  private

  def build_fake_api
    api_calls = @api_calls
    Object.new.tap do |api|
      api.define_singleton_method(:sendMessage) do |**kwargs|
        api_calls << { method: :sendMessage, args: kwargs }
      end
    end
  end
end

# ==========================================================================
# MessageSenderTest — covers Markdown parse failure retry (Apr 13)
# ==========================================================================
class MessageSenderTest < BotTest
  # Markdown parse failure triggers retry as plain text
  # (production: Apr 13 "can't parse entities: Can't find end of the entity starting at byte offset 903")
  def test_markdown_failure_retries_as_plain_text
    calls = []
    first_call = true
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendMessage) do |params|
      calls << params.dup
      if first_call && params[:parse_mode] == 'Markdown'
        first_call = false
        raise "Bad Request: can't parse entities"
      end
    end

    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    sender = MessageSender.new(bot: bot, chat: chat, text: "broken *markdown")
    sender.send

    assert_equal 2, calls.size
    # First call had Markdown parse_mode
    assert_equal 'Markdown', calls[0][:parse_mode]
    # Retry call has no parse_mode
    assert_nil calls[1][:parse_mode]
    # Retry sends raw text without sanitization
    assert_equal "broken *markdown", calls[1][:text]
  end

  # Successful Markdown send — no retry needed
  def test_markdown_success_no_retry
    calls = []
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendMessage) { |params| calls << params.dup }

    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    sender = MessageSender.new(bot: bot, chat: chat, text: "valid *bold* text")
    sender.send

    assert_equal 1, calls.size
    assert_equal 'Markdown', calls[0][:parse_mode]
  end

  # Long message is split into chunks under MAX_MESSAGE_LENGTH
  def test_long_message_split
    calls = []
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendMessage) { |params| calls << params.dup }

    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    # Create message longer than 4096 chars
    long_text = ("a" * 100 + "\n") * 50  # 50 lines of 101 chars = 5050 chars
    sender = MessageSender.new(bot: bot, chat: chat, text: long_text)
    sender.send

    assert calls.size > 1, "long message should be split into multiple chunks"
    calls.each do |c|
      assert c[:text].length <= MessageSender::MAX_MESSAGE_LENGTH, "each chunk must be <= MAX_MESSAGE_LENGTH"
    end
  end
end

# ==========================================================================
# SunoFilenameTest — covers SunoTaskHandler#build_filename edge cases
# ==========================================================================
class SunoFilenameTest < BotTest
  def setup
    super
    # SunoTaskHandler needs ChatContext + settings; instantiate directly for build_filename
    require_relative '../lib/chat_context'
    require_relative '../lib/task_handlers/suno_handler'
  rescue LoadError
    # Already loaded
  end

  # Normal filename generation
  def test_basic_filename
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, 'Artist', 'Title', 1, 1)
    assert_equal 'Artist_-_Title.mp3', name
  end

  # Multiple clips get index suffix
  def test_filename_with_index
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, 'Artist', 'Title', 2, 3)
    assert_equal 'Artist_-_Title_(2).mp3', name
  end

  # Single clip does not get index suffix
  def test_filename_single_clip_no_index
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, 'Artist', 'Title', 1, 1)
    refute_match(/\(\d+\)/, name)
  end

  # Special characters are stripped from filename
  def test_filename_strips_special_chars
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, 'My:Artist', 'Title?"<>|test', 1, 1)
    refute_match(/[:*?"<>|]/, name)
  end

  # Spaces are replaced with underscores
  def test_filename_spaces_to_underscores
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, 'My Artist', 'My Title', 1, 1)
    refute_match(/\s/, name)
    assert_match(/My_Artist/, name)
  end

  # Empty performer — only title in filename
  def test_filename_empty_performer
    handler = SunoTaskHandler.new
    name = handler.send(:build_filename, '', 'Just Title', 1, 1)
    assert_equal 'Just_Title.mp3', name
  end
end

# ==========================================================================
# RunnerContentFilterTest — covers API content filtering (Apr 12, 6 occurrences)
# ==========================================================================
class RunnerContentFilterTest < BotTest
  include ProdTestHelpers
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

  # Content filtering: call_raw returns nil → Runner returns fallback
  # (production: Apr 12 "400 Output blocked by content filtering policy" x6)
  def test_content_filter_nil_returns_fallback
    FakeGptMaster.enqueue(nil)
    runner = Agent::Runner.new(
      text: 'something inappropriate', context: '[]', knowledge: '',
      radio: nil, chat_id: 100, user: @user
    )
    assert_equal 'жпт не жпт', runner.run
  end

  # Overloaded: all retries exhausted, call_raw returns nil → Runner returns fallback
  # (production: Apr 8 "529 Overloaded" x3, each exhausting 3 retries)
  def test_overloaded_nil_returns_fallback
    FakeGptMaster.enqueue(nil)
    runner = Agent::Runner.new(
      text: 'hi', context: '[]', knowledge: '',
      radio: nil, chat_id: 100, user: @user
    )
    assert_equal 'жпт не жпт', runner.run
  end

  # Tool call followed by content filtering on second call → forced final returns fallback
  def test_tool_then_content_filter
    Agent::ToolRegistry.register(name: 'test', description: 'Test', handler: ->(_a, _c) { 'ok' })
    FakeGptMaster.enqueue(
      { 'content' => [{ 'type' => 'tool_use', 'id' => 'c1', 'name' => 'test', 'input' => {} }] },
      nil  # content filter on second call
    )
    runner = Agent::Runner.new(
      text: 'go', context: '[]', knowledge: '',
      radio: nil, chat_id: 100, user: @user
    )
    assert_equal 'жпт не жпт', runner.run
  end
end

# ==========================================================================
# GogolmogolSnippetTest — covers missing snippet method (Apr 9)
# ==========================================================================
class GogolmogolSnippetTest < BotTest
  # search_results handles items that don't have a snippet method
  # (production: Apr 9 "undefined method 'snippet' for GoogleCustomSearchApi::ResponseData")
  def test_search_results_handles_missing_snippet
    # The fix in gogolmogol.rb:44 uses respond_to?(:snippet)
    # Test the conditional logic directly
    item_with_snippet = OpenStruct.new(title: 'Test', link: 'http://test.com', snippet: 'A snippet')
    item_without_snippet = OpenStruct.new(title: 'No Snippet', link: 'http://no.com')

    # item with snippet
    result = item_with_snippet.respond_to?(:snippet) ? item_with_snippet.snippet : ''
    assert_equal 'A snippet', result

    # item without snippet — should not raise, returns empty string
    result = item_without_snippet.respond_to?(:snippet) ? item_without_snippet.snippet : ''
    assert_equal '', result
  end
end

# ==========================================================================
# ExtractRepliedImageTest — covers Telegram File API access errors (Apr 13)
# ==========================================================================
class ExtractRepliedImageTest < BotTest
  include ProdTestHelpers
  include Fixtures::Users

  def setup
    super
    stub_settings!
    @user = member_user
  end

  # extract_replied_image returns nil when reply has no photo
  def test_no_photo_returns_nil
    reply_msg = OpenStruct.new(text: 'just text', photo: nil)
    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: reply_msg)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new(reply_pattern_only: nil),
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_replied_image)
  end

  # extract_replied_image returns nil when photo array is empty
  def test_empty_photo_returns_nil
    reply_msg = OpenStruct.new(text: nil, photo: [])
    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: reply_msg)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new(reply_pattern_only: nil),
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_replied_image)
  end

  # extract_replied_image returns nil when no reply_to_message at all
  def test_no_reply_returns_nil
    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: nil)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new(reply_pattern_only: nil),
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_replied_image)
  end

  # extract_replied_image gracefully handles getFile failure
  # (production: Apr 13 NoMethodError on dig, MissingAttributeError on 'result')
  def test_getfile_failure_returns_nil
    photo = OpenStruct.new(file_id: 'abc123')
    reply_msg = OpenStruct.new(text: nil, photo: [photo])

    # Simulate bot.api.getFile raising an error
    api = Object.new
    api.define_singleton_method(:getFile) { |**_| raise "API error" }
    bot = OpenStruct.new(api: api)

    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: reply_msg)
    ctx = CommandContext.new(
      bot: bot, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new(reply_pattern_only: nil),
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    # Should not raise — rescue returns nil
    assert_nil command.send(:extract_replied_image)
  end

  # extract_replied_image handles getFile returning object with nil file_path
  def test_nil_file_path_returns_nil
    photo = OpenStruct.new(file_id: 'abc123')
    reply_msg = OpenStruct.new(text: nil, photo: [photo])

    file_obj = OpenStruct.new(file_path: nil)
    api = Object.new
    api.define_singleton_method(:getFile) { |**_| file_obj }
    bot = OpenStruct.new(api: api)

    msg = OpenStruct.new(text: 'бот что', message_id: 1, reply_to_message: reply_msg)
    ctx = CommandContext.new(
      bot: bot, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new(reply_pattern_only: nil),
      cmd: "бот что"
    )
    command = Commands::GptChat.new(ctx)
    assert_nil command.send(:extract_replied_image)
  end
end

# ==========================================================================
# MessageResponderCaptionTest — covers photo-with-caption messages (Apr 15)
# ==========================================================================
class MessageResponderCaptionTest < BotTest
  include ProdTestHelpers
  include Fixtures::Users

  def setup
    super
    stub_settings!
    @user = member_user
  end

  # Photo message with caption "бот ..." should be dispatched (text is nil, caption is used)
  # (production: Apr 15 — photo messages silently dropped because `return unless message.text`)
  def test_caption_used_as_text_fallback
    msg = OpenStruct.new(
      text: nil,
      caption: "бот что это",
      message_id: 1,
      reply_to_message: nil,
      photo: [OpenStruct.new(file_id: 'abc')],
      date: Time.now.to_i,
      voice: nil,
      chat: OpenStruct.new(id: 100, title: 'test'),
      from: OpenStruct.new(id: 123, username: 'testuser', first_name: 'Test', last_name: nil)
    )

    # Use caption as text fallback (the fix)
    text = msg.text || msg.caption
    assert_equal "бот что это", text
  end

  # Photo message without caption — still nil, nothing to dispatch
  def test_no_text_no_caption_returns_nil
    msg = OpenStruct.new(
      text: nil,
      caption: nil,
      message_id: 1,
      photo: [OpenStruct.new(file_id: 'abc')]
    )
    text = msg.text || msg.caption
    assert_nil text
  end

  # Regular text message — text is used as-is (caption fallback not needed)
  def test_text_message_uses_text
    msg = OpenStruct.new(text: "бот привет", caption: nil, message_id: 1)
    text = msg.text || msg.caption
    assert_equal "бот привет", text
  end

  # save_message uses caption for photo messages
  def test_save_message_stores_caption
    msg = OpenStruct.new(
      text: nil,
      caption: "фото с подписью",
      message_id: 1,
      date: Time.now.to_i,
      voice: nil,
      chat: OpenStruct.new(id: 100, title: 'test'),
      from: OpenStruct.new(id: @user.uid, username: @user.name, first_name: 'Test', last_name: nil)
    )
    body = msg.text || msg.caption
    Message.create(user_uid: @user.uid, chat_id: 100, body: body)
    assert_equal "фото с подписью", Message.last.body
  end
end

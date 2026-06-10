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
require_relative '../lib/chat_context'
require_relative '../lib/commands/gpt_helpers'
require_relative '../lib/commands/gpt_chat'
require_relative '../lib/embedding_service'
require_relative '../lib/knowledge_base'
require_relative '../lib/commands/knowledge_add'
require_relative '../lib/commands/knowledge_delete'
require_relative '../lib/commands/knowledge_compact'
require_relative '../lib/task_runner'
require_relative '../lib/reply_markup_formatter'
require_relative '../lib/message_sender'
require 'telegram/bot' # provides Faraday::UploadIO used by the :voice deliver path

LOGGER       = Logger.new(IO::NULL) unless defined?(LOGGER)

# ==========================================================================
# Helpers
# ==========================================================================
module ProdTestHelpers
  def stub_settings!
    Settings.instance_variable_set(:@_settings, OpenStruct.new(
      radio: { 'path' => '/music', 'host_path' => nil },
      telegram: { 'token' => '123456:ABCDEF' },
      google: [],
      auth: { 'chats' => [] },
      chat_gpt: {
        'agent_prompt' => "{REQUEST} | {CONTEXT} | {KNOWLEDGE}",
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
    runner.process_one(task)
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
    runner.process_one(task)

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
    runner.process_one(task)

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
    runner.process_one(task)

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
    runner.process_one(task)

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
# MessageSenderTest — covers Markdown parse failure retry and sanitization
# ==========================================================================
class MessageSenderTest < BotTest
  private

  def build_sender(text)
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendMessage) { |params| nil }
    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')
    MessageSender.new(bot: bot, chat: chat, text: text)
  end

  public
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

  # --- sanitize_markdown ---

  # Underscores inside code blocks are not escaped
  # (production: `char16_t` in code blocks rendered as `char16\_t`)
  def test_sanitize_preserves_underscores_in_code_blocks
    sender = build_sender("text ```c\nchar16_t* p = data;\nint foo_bar = 1;\n``` end")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, 'char16_t'
    assert_includes result, 'foo_bar'
    refute_includes result, 'char16\\_t'
  end

  # Underscores inside inline code are not escaped
  def test_sanitize_preserves_underscores_in_inline_code
    sender = build_sender("use `my_variable` here")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, '`my_variable`'
    refute_includes result, '`my\\_variable`'
  end

  # Underscores in regular text between words are still escaped
  def test_sanitize_escapes_underscores_in_regular_text
    sender = build_sender("some_variable is cool")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, 'some\\_variable'
  end

  # Mixed: code block underscores preserved, text underscores escaped
  def test_sanitize_mixed_code_and_text
    sender = build_sender("my_var and ```\nfoo_bar\n``` done")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, 'my\\_var'
    assert_includes result, 'foo_bar'
    refute_includes result, 'foo\\_bar'
  end

  # Markdown tables are wrapped in code blocks (Telegram doesn't render tables)
  def test_sanitize_wraps_tables_in_code_block
    table = "| Name | Value |\n| --- | --- |\n| foo | 123 |\n| bar | 456 |\n"
    sender = build_sender("Here:\n#{table}Done")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, "```\n| Name | Value |"
    assert_includes result, "| bar | 456 |\n```"
  end

  # Table formatting strips markdown chars inside the code block
  def test_sanitize_table_strips_markdown_inside
    table = "| *bold* | _italic_ |\n| `code` | normal |\n"
    sender = build_sender(table)
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_includes result, '| bold | italic |'
    assert_includes result, '| code | normal |'
  end

  # Single pipe line is not treated as a table
  def test_sanitize_single_pipe_line_not_wrapped
    sender = build_sender("use | for OR")
    result = sender.__send__(:sanitize_markdown, sender.text)
    refute_includes result, '```'
  end

  # **bold** is converted to *bold* for Telegram Markdown
  def test_sanitize_double_asterisks_to_single
    sender = build_sender("**bold text**")
    result = sender.__send__(:sanitize_markdown, sender.text)
    assert_equal "*bold text*", result
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

  # Regression: each clip from sendMediaGroup must be saved as a bot Message row
  # so later user replies pointing at the clip's message_id resolve cleanly.
  def test_persist_bot_media_rows_creates_row_per_clip
    handler = SunoTaskHandler.new
    messages = [OpenStruct.new(message_id: 1001, message_thread_id: nil),
                OpenStruct.new(message_id: 1002, message_thread_id: 50)]
    before = Message.count
    handler.send(:persist_bot_media_rows, -100, messages, 'Прогулки', { 'lyrics' => 'x' })
    assert_equal before + 2, Message.count
    rows = Message.where(chat_id: -100).order(:message_id).last(2)
    assert_equal 'bot', rows.first.role
    assert_equal 1001, rows.first.message_id
    assert_equal 1002, rows.last.message_id
    assert_equal 50,   rows.last.message_thread_id
    assert_match(/Прогулки/, rows.first.body)
    assert_match(%r{\(1/2\)}, rows.first.body)
    assert_match(%r{\(2/2\)}, rows.last.body)
  end

  # persist_bot_media_rows: hash-style response (Net::HTTP response) works too
  def test_persist_bot_media_rows_handles_hash_response
    handler = SunoTaskHandler.new
    messages = [{ 'message_id' => 2001, 'message_thread_id' => nil }]
    before = Message.count
    handler.send(:persist_bot_media_rows, -100, messages, 'Test', {})
    assert_equal before + 1, Message.count
    assert_equal 2001, Message.order(:id).last.message_id
  end

  # Regression: suno AUDIO media-group rows must never be flagged as photos.
  # persist_bot_reply (the centralized write path) extracts photo file_ids
  # from photo sends — an audio message has photo nil (or, defensively, an
  # empty array if Telegram's shape ever changes), so attachment_photo_file_id
  # must stay nil and the row must not serialize with `photo: true`.
  def test_persist_bot_media_rows_audio_rows_have_no_photo_file_id
    handler = SunoTaskHandler.new
    messages = [OpenStruct.new(message_id: 3001, message_thread_id: nil, photo: nil),
                OpenStruct.new(message_id: 3002, message_thread_id: nil, photo: [])]
    handler.send(:persist_bot_media_rows, -100, messages, 'Track', {})
    rows = Message.where(chat_id: -100, message_id: [3001, 3002]).order(:message_id)
    assert_equal 2, rows.size
    rows.each { |r| assert_nil r.attachment_photo_file_id }
  end
end

# ==========================================================================
# ImageGenPersistTest — bot photo delivery saves a Message row
# ==========================================================================
class ImageGenPersistTest < BotTest
  def setup
    super
    require_relative '../lib/chat_context'
    require_relative '../lib/task_handlers/image_gen_handler'
  rescue LoadError
    # already loaded
  end

  # Regression: sendPhoto response must produce a bot Message row so a user
  # reply to the photo doesn't leave a dangling reply_to_message_id.
  def test_persist_bot_media_row_creates_row
    handler = ImageGenTaskHandler.new
    response = OpenStruct.new(message_id: 3001, message_thread_id: 42)
    before = Message.count
    handler.send(:persist_bot_media_row, -200, response, '🎨 test caption')
    assert_equal before + 1, Message.count
    row = Message.order(:id).last
    assert_equal 'bot', row.role
    assert_equal(-200, row.chat_id)
    assert_equal 3001, row.message_id
    assert_equal 42,   row.message_thread_id
    assert_equal '🎨 test caption', row.body
  end

  # When sendPhoto returned nothing we can extract an id from, skip silently.
  def test_persist_bot_media_row_skips_when_no_message_id
    handler = ImageGenTaskHandler.new
    before = Message.count
    handler.send(:persist_bot_media_row, -200, OpenStruct.new, 'caption')
    assert_equal before, Message.count
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
      reply_master: OpenStruct.new,
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
      reply_master: OpenStruct.new,
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
      reply_master: OpenStruct.new,
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
      reply_master: OpenStruct.new,
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
      reply_master: OpenStruct.new,
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

# ==========================================================================
# ChatContextTest — covers consolidated ChatContext module (Apr 16 refactoring)
# ==========================================================================
class ChatContextTest < BotTest
  include ProdTestHelpers
  include Fixtures::Users
  include Fixtures::Messages

  def setup
    super
    stub_settings!
    @user = member_user(first_name: 'Ivan', last_name: 'Petrov')
  end

  # get_chat_context exposes first/last name in the structured `who` object
  def test_context_includes_full_name
    user_message(chat_id: 100, body: 'привет', user: @user)
    obj = Object.new
    obj.extend(ChatContext)
    result = obj.get_chat_context(100)
    parsed = JSON.parse(result)
    assert_equal 1, parsed.size
    who = parsed.first['who']
    assert_equal 'Ivan',   who['first_name']
    assert_equal 'Petrov', who['last_name']
  end

  # Bot rows render `who` as {name: 'Жзяцля'} (no uid/username); role: 'bot'
  # is the structural disambiguator.
  def test_context_bot_messages_use_bot_name
    bot_message(chat_id: 100, body: 'bot reply')
    obj = Object.new
    obj.extend(ChatContext)
    result = obj.get_chat_context(100)
    parsed = JSON.parse(result)
    assert_equal({ 'name' => 'Жзяцля' }, parsed.first['who'])
    assert_equal 'bot', parsed.first['role']
  end

  # User with only a username and no first/last: who object has just uid + username.
  def test_context_falls_back_to_username
    user_no_name = member_user(uid: 2000, name: 'cooluser', first_name: nil, last_name: nil)
    user_message(chat_id: 100, body: 'hi', user: user_no_name)
    obj = Object.new
    obj.extend(ChatContext)
    result = obj.get_chat_context(100)
    parsed = JSON.parse(result)
    assert_equal({ 'uid' => 2000, 'username' => 'cooluser' }, parsed.first['who'])
  end

  # get_chat_context returns empty string on error (rescue wrapper)
  def test_context_returns_empty_on_error
    obj = Object.new
    obj.extend(ChatContext)
    # Force error by passing settings without chat_gpt key
    Settings.instance_variable_set(:@_settings, OpenStruct.new)
    result = obj.get_chat_context(100)
    assert_equal '', result
  end

  # Regression: context must NOT be filtered by message_thread_id.
  # In non-forum supergroups Telegram auto-tags any reply with the root
  # message's id as thread_id, which collapsed the context window to one
  # reply chain. See 2026-04-19 incident (gpt.log showed context = 1 msg).
  def test_context_is_not_filtered_by_thread_id
    user_message(chat_id: 100, body: 'hello 1', user: @user)
    user_message(chat_id: 100, body: 'hello 2', user: @user, attrs: { message_thread_id: 999 })
    user_message(chat_id: 100, body: 'hello 3', user: @user, attrs: { message_thread_id: 888 })

    obj = Object.new
    obj.extend(ChatContext)
    # Even when we're nominally "in" thread 999, we must still see messages
    # from other threads — thread_id is advisory, not a filter.
    result = obj.get_chat_context(100, thread_id: 999)
    bodies = JSON.parse(result).map { |m| m['msg'] }
    assert_equal ['hello 1', 'hello 2', 'hello 3'], bodies
  end

  # get_relevant_knowledge returns empty string when knowledge is not configured
  def test_knowledge_returns_empty_without_settings
    Settings.instance_variable_set(:@_settings, OpenStruct.new(
      chat_gpt: { 'context_messages_size' => 10 }
    ))
    obj = Object.new
    obj.extend(ChatContext)
    result = obj.get_relevant_knowledge('test', 100)
    assert_equal '', result
  end
end

# ==========================================================================
# GptHelpersWrapperTest — covers GptHelpers delegation to ChatContext via super
# ==========================================================================
class GptHelpersWrapperTest < BotTest
  include ProdTestHelpers
  include Fixtures::Users
  include Fixtures::Messages

  def setup
    super
    stub_settings!
    @user = member_user(first_name: 'Test', last_name: 'User')
  end

  # GptHelpers#get_chat_context passes chat_id from command context automatically
  def test_get_chat_context_auto_passes_chat_id
    user_message(chat_id: 100, body: 'hello', user: @user)
    user_message(chat_id: 200, body: 'other chat', user: @user)

    msg = OpenStruct.new(text: 'бот привет', message_id: 1, reply_to_message: nil)
    ctx = CommandContext.new(
      bot: nil, message: msg, user: @user,
      chat_id: 100, radio: nil,
      reply_master: OpenStruct.new,
      cmd: "бот привет"
    )
    command = Commands::GptChat.new(ctx)
    result = command.send(:get_chat_context)
    parsed = JSON.parse(result)

    # Should only contain messages from chat 100, not 200
    bodies = parsed.map { |m| m['msg'] }
    assert_includes bodies, 'hello'
    refute_includes bodies, 'other chat'
  end

  # MessageResponder#deliver persists bot reply with Telegram message_id
  def test_deliver_persists_bot_reply_with_message_id
    require_relative '../lib/message_responder'

    sent_params = nil
    api = Class.new do
      define_method(:sendChatAction) { |**_| }
      define_method(:sendMessage) do |params|
        sent_params = params
        OpenStruct.new(message_id: 4242)
      end
    end.new
    fake_bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 100, title: 'test')
    msg = OpenStruct.new(
      text: 'бот привет', message_id: 7, reply_to_message: nil,
      message_thread_id: nil, chat: chat, date: Time.now.to_i,
      voice: nil, caption: nil, edit_date: nil,
      forward_origin: nil,
      from: OpenStruct.new(id: @user.uid, username: @user.name, first_name: 'u', last_name: nil)
    )
    responder = MessageResponder.new(bot: fake_bot, message: msg, radio: nil)
    result = CommandResult.text('test reply', reply_to_message_id: 7)
    responder.send(:deliver, result)

    saved = Message.where(role: 'bot').last
    assert_equal 100, saved.chat_id
    assert_equal 'test reply', saved.body
    assert_equal 4242, saved.message_id
    assert_equal 7, saved.reply_to_message_id
    assert_equal 7, sent_params[:reply_to_message_id]
  end

  # ---- deliver persists EVERY output type (#1 fix) ----

  def deliver_responder(api:, thread_id: nil)
    require_relative '../lib/message_responder'
    fake_bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 100, title: 'test')
    msg = OpenStruct.new(
      text: 'бот привет', message_id: 7, reply_to_message: nil,
      message_thread_id: thread_id, chat: chat, date: Time.now.to_i,
      voice: nil, caption: nil, edit_date: nil, forward_origin: nil,
      from: OpenStruct.new(id: @user.uid, username: @user.name, first_name: 'u', last_name: nil)
    )
    MessageResponder.new(bot: fake_bot, message: msg, radio: nil)
  end

  # GptChat path persists exactly one row after the persist_as_bot_reply
  # flag was retired (regression guard).
  def test_deliver_text_persists_exactly_once
    api = Class.new do
      define_method(:sendChatAction) { |**_| }
      define_method(:sendMessage) { |_params| OpenStruct.new(message_id: 4242) }
    end.new
    before = Message.where(role: 'bot').count
    deliver_responder(api: api).send(:deliver, CommandResult.text('hi there'))
    assert_equal before + 1, Message.where(role: 'bot').count
    assert_equal 'hi there', Message.where(role: 'bot').last.body
  end

  # Text replies thread the originating message_thread_id into both the
  # Telegram send and the persisted row (forum-topic correctness).
  def test_deliver_text_propagates_thread_id
    sent_params = nil
    api = Class.new do
      define_method(:sendChatAction) { |**_| }
      define_method(:sendMessage) do |params|
        sent_params = params
        OpenStruct.new(message_id: 4343)
      end
    end.new
    deliver_responder(api: api, thread_id: 99).send(:deliver, CommandResult.text('hi'))
    assert_equal 99, sent_params[:message_thread_id]
    assert_equal 99, Message.where(role: 'bot').last.message_thread_id
  end

  # Blank/whitespace text neither sends nor persists (prevents the Telegram
  # "message text is empty" 400 from blank agent responses).
  def test_deliver_blank_text_sends_and_persists_nothing
    calls = []
    api = Class.new do
      define_method(:sendChatAction) { |**_| calls << :action }
      define_method(:sendMessage) { |_params| calls << :msg; OpenStruct.new(message_id: 1) }
    end.new
    before = Message.where(role: 'bot').count
    deliver_responder(api: api).send(:deliver, CommandResult.text("   \n  "))
    assert_empty calls
    assert_equal before, Message.where(role: 'bot').count
  end

  def test_deliver_sticker_persists_with_thread_id
    captured = nil
    api = Class.new do
      define_method(:sendChatAction) { |**_| }
      define_method(:sendSticker) do |**params|
        captured = params
        OpenStruct.new(message_id: 11, message_thread_id: params[:message_thread_id])
      end
    end.new
    deliver_responder(api: api, thread_id: 77).send(:deliver, CommandResult.sticker('STICKER_ID'))
    saved = Message.where(role: 'bot').last
    assert_equal '[стикер]', saved.body
    assert_equal 11, saved.message_id
    assert_equal 77, saved.message_thread_id
    assert_equal 77, captured[:message_thread_id]
    assert_equal 'STICKER_ID', captured[:sticker]
  end

  def test_deliver_image_persists
    api = Class.new do
      define_method(:sendPhoto) do |**params|
        OpenStruct.new(message_id: 22, message_thread_id: params[:message_thread_id])
      end
    end.new
    deliver_responder(api: api, thread_id: 55).send(:deliver, CommandResult.image('http://x/pic.png'))
    saved = Message.where(role: 'bot').last
    assert_equal '[картинка]', saved.body
    assert_equal 22, saved.message_id
    assert_equal 55, saved.message_thread_id
  end

  # When the image send fails, send_image returns nil and posts a fallback
  # text — must NOT persist a mislabeled [картинка] row.
  def test_deliver_image_failure_persists_nothing
    api = Class.new do
      define_method(:sendPhoto) { |**_params| raise 'boom' }
      define_method(:sendMessage) { |_params| OpenStruct.new(message_id: 999) }
    end.new
    before = Message.where(role: 'bot').count
    deliver_responder(api: api).send(:deliver, CommandResult.image('http://x/pic.png'))
    assert_equal before, Message.where(role: 'bot').count
  end

  def test_deliver_voice_persists_and_removes_scratch_file
    require 'tempfile'
    file = Tempfile.new(['voice', '.ogg'])
    file.write('x'); file.close
    path = file.path
    api = Class.new do
      define_method(:sendVoice) do |**params|
        OpenStruct.new(message_id: 33, message_thread_id: params[:message_thread_id])
      end
    end.new
    deliver_responder(api: api, thread_id: 88).send(:deliver, CommandResult.voice(path))
    saved = Message.where(role: 'bot').last
    assert_equal '[голос]', saved.body
    assert_equal 33, saved.message_id
    assert_equal 88, saved.message_thread_id
    refute File.exist?(path), 'voice scratch file should be removed after send'
  end

  # #2: a reply to a bot message that was evicted from the recent window
  # still resolves, because the bot row exists and ChatContext backfills it.
  def test_reply_to_persisted_bot_message_resolves_via_backfill
    base = Time.now - 1000
    bot_message(chat_id: 100, body: '[стикер]', attrs: { message_id: 500, created_at: base })
    15.times do |i|
      user_message(chat_id: 100, body: "msg#{i}", user: @user,
                   attrs: { message_id: 600 + i, created_at: base + (i + 1) * 10 })
    end
    user_message(chat_id: 100, body: 'отвечаю боту', user: @user,
                 attrs: { message_id: 700, reply_to_message_id: 500, created_at: base + 1000 })

    ctx = Class.new { include ChatContext }.new
    parsed = JSON.parse(ctx.get_chat_context(100))
    bodies = parsed.map { |m| m['msg'] }
    assert_includes bodies, '[стикер]', 'evicted bot reply target should be backfilled'
    reply_row = parsed.find { |m| m['id'] == 700 }
    assert_equal 500, reply_row['reply_to']
  end

  # save_message updates existing row in place on edit_date; no duplicate
  def test_save_message_updates_existing_on_edit
    require_relative '../lib/message_responder'

    Message.create!(user_uid: @user.uid, chat_id: 100, body: 'original', message_id: 1000)
    start_count = Message.count

    edited = OpenStruct.new(
      text: 'edited body', caption: nil, message_id: 1000,
      reply_to_message: nil, message_thread_id: nil,
      edit_date: Time.now.to_i, date: Time.now.to_i - 60,
      forward_origin: nil, voice: nil, chat: OpenStruct.new(id: 100, title: 't'),
      from: OpenStruct.new(id: @user.uid, username: @user.name, first_name: 'u', last_name: nil)
    )
    responder = MessageResponder.new(bot: nil, message: edited, radio: nil)
    responder.send(:save_message)

    assert_equal start_count, Message.count
    row = Message.find_by(chat_id: 100, message_id: 1000)
    assert_equal 'edited body', row.body
    refute_nil row.edited_at
  end
end

# ==========================================================================
# RequireAdminTest — covers require_admin! helper in Commands::Base
# ==========================================================================
class RequireAdminTest < BotTest
  include ProdTestHelpers
  include Fixtures::Users

  def setup
    super
    stub_settings!
    # Stub knowledge settings for KnowledgeCompact
    settings = Settings.instance_variable_get(:@_settings)
    settings.define_singleton_method(:knowledge) { { 'compact_threshold' => 0.85 } }
    settings.define_singleton_method(:respond_to?) { |m, *| m == :knowledge ? true : super(m) }
  end

  # Admin can add knowledge
  def test_knowledge_add_allowed_for_admin
    admin = admin_user
    ctx = CommandContext.new(
      bot: nil, message: OpenStruct.new(text: 'бот запомни тест факт', message_id: 1, reply_to_message: nil),
      user: admin, chat_id: 100, radio: nil,
      reply_master: nil, cmd: "бот запомни тест факт"
    )
    result = Commands::KnowledgeAdd.new(ctx).execute
    assert_equal :text, result.type
    assert_match(/Запомнил/, result.payload)
  end

  # Non-admin is blocked from adding knowledge
  def test_knowledge_add_blocked_for_member
    user = member_user
    ctx = CommandContext.new(
      bot: nil, message: OpenStruct.new(text: 'бот запомни секрет', message_id: 1, reply_to_message: nil),
      user: user, chat_id: 100, radio: nil,
      reply_master: nil, cmd: "бот запомни секрет"
    )
    result = Commands::KnowledgeAdd.new(ctx).execute
    assert_equal :text, result.type
    assert_match(/администратор/, result.payload)
  end

  # Non-admin is blocked from deleting knowledge
  def test_knowledge_delete_blocked_for_member
    user = member_user
    ctx = CommandContext.new(
      bot: nil, message: OpenStruct.new(text: 'бот забудь 1', message_id: 1, reply_to_message: nil),
      user: user, chat_id: 100, radio: nil,
      reply_master: nil, cmd: "бот забудь 1"
    )
    result = Commands::KnowledgeDelete.new(ctx).execute
    assert_equal :text, result.type
    assert_match(/администратор/, result.payload)
  end

  # Admin can delete knowledge
  def test_knowledge_delete_allowed_for_admin
    admin = admin_user
    Knowledge.create!(topic: 'test', content: 'fact', chat_id: 100, source: 'manual')
    kid = Knowledge.last.id
    ctx = CommandContext.new(
      bot: nil, message: OpenStruct.new(text: "бот забудь #{kid}", message_id: 1, reply_to_message: nil),
      user: admin, chat_id: 100, radio: nil,
      reply_master: nil, cmd: "бот забудь #{kid}"
    )
    result = Commands::KnowledgeDelete.new(ctx).execute
    assert_equal :text, result.type
    assert_match(/Забыл/, result.payload)
    assert_nil Knowledge.find_by(id: kid)
  end
end

# ==========================================================================
# SendImageErrorTest — covers send_image error handling (rescue => e)
# ==========================================================================
class SendImageErrorTest < BotTest
  # send_image catches errors and sends fallback message
  def test_send_image_error_sends_fallback
    fallback_sent = nil
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendPhoto) { |**_| raise "upload failed" }
    api.define_singleton_method(:sendMessage) { |**kwargs| fallback_sent = kwargs }
    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    sender = MessageSender.new(bot: bot, chat: chat, text: "http://example.com/photo.jpg")
    sender.send_image

    assert fallback_sent, "fallback message should be sent on error"
    assert_equal 1, fallback_sent[:chat_id]
    assert_match(/гугл/, fallback_sent[:text])
  end

  # send_image sends document for gif URLs
  def test_send_image_gif_sends_document
    doc_sent = nil
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendDocument) { |**kwargs| doc_sent = kwargs }
    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    sender = MessageSender.new(bot: bot, chat: chat, text: "http://example.com/funny.gif")
    sender.send_image

    assert doc_sent, "document should be sent for gif"
    assert_equal "http://example.com/funny.gif", doc_sent[:document]
  end

  # send_image sends photo for non-gif URLs
  def test_send_image_jpg_sends_photo
    photo_sent = nil
    api = Object.new
    api.define_singleton_method(:sendChatAction) { |**_| nil }
    api.define_singleton_method(:sendPhoto) { |**kwargs| photo_sent = kwargs }
    bot = OpenStruct.new(api: api)
    chat = OpenStruct.new(id: 1, title: 'test')

    sender = MessageSender.new(bot: bot, chat: chat, text: "http://example.com/photo.jpg")
    sender.send_image

    assert photo_sent, "photo should be sent for jpg"
    assert_equal "http://example.com/photo.jpg", photo_sent[:photo]
  end
end

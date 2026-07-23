require_relative 'test_helper'
require 'ostruct'
require 'telegram/bot'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/message_sender'

# MessageSender's rich-first / classic-fallback behaviour. The rich client is
# injected; the classic path is exercised against a fake bot.api.
class MessageSenderRichTest < Minitest::Test
  class FakeApi
    attr_reader :calls
    def initialize; @calls = []; end
    def sendChatAction(**k); @calls << [:sendChatAction, k]; end
    def sendMessage(params); @calls << [:sendMessage, params]; OpenStruct.new(message_id: 111); end
  end
  FakeBot  = Struct.new(:api)
  FakeChat = Struct.new(:id, :title)

  class FakeRich
    attr_reader :calls
    def initialize(result: nil, raise_with: nil, raise_class: TelegramRichClient::Error)
      @result = result; @raise_with = raise_with; @raise_class = raise_class; @calls = []
    end
    def send_rich(**kw)
      @calls << kw
      raise @raise_class, @raise_with if @raise_with
      @result
    end
  end

  def setup
    @prev = Settings.instance_variable_get(:@_settings)
    set_rich(true)
    @api  = FakeApi.new
    @bot  = FakeBot.new(@api)
    @chat = FakeChat.new(-100, 'Test')
  end

  def teardown
    Settings.instance_variable_set(:@_settings, @prev)
  end

  def set_rich(on)
    Settings.instance_variable_set(:@_settings,
      OpenStruct.new(telegram: { 'rich_messages' => on, 'token' => 'T' }))
  end

  def sender(rich:, text: 'hello', **opts)
    MessageSender.new(bot: @bot, chat: @chat, text: text, rich_client: rich, **opts)
  end

  def sent_messages; @api.calls.select { |c| c[0] == :sendMessage }; end

  def test_rich_success_returns_id_and_skips_classic
    rich = FakeRich.new(result: { 'message_id' => 777 })
    id = sender(rich: rich).send
    assert_equal 777, id
    assert_equal 1, rich.calls.size
    assert_empty sent_messages, 'classic sendMessage must NOT run on rich success'
  end

  def test_rejected_rich_falls_back_to_classic
    rich = FakeRich.new(raise_with: 'bad markdown', raise_class: TelegramRichClient::Rejected)
    id = sender(rich: rich).send
    assert_equal 111, id, 'returns the classic sendMessage id'
    assert_equal 1, rich.calls.size
    assert_equal 1, sent_messages.size, 'rejected (definitely not sent) must fall back'
  end

  # The whole point of finding #1: a maybe-delivered rich send must NOT trigger
  # a classic re-send (would duplicate the message in the chat).
  def test_ambiguous_rich_does_not_fall_back
    rich = FakeRich.new(raise_with: 'read timeout', raise_class: TelegramRichClient::Ambiguous)
    id = sender(rich: rich).send
    assert_nil id, 'no DB row when the id is unknown'
    assert_empty sent_messages, 'ambiguous (maybe-sent) must NOT duplicate via classic'
  end

  def test_ok_without_message_id_suppresses_fallback
    rich = FakeRich.new(result: {}) # ok:true-equivalent Message hash, but no message_id
    id = sender(rich: rich).send
    assert_nil id
    assert_empty sent_messages, 'confirmed-sent-without-id must NOT double-send'
  end

  def test_classic_path_strips_gfm_only_markers
    set_rich(false)
    rich = FakeRich.new(result: { 'message_id' => 1 })
    MessageSender.new(bot: @bot, chat: @chat, rich_client: rich,
                      text: "# Заголовок\n||секрет|| и ~~старое~~").send
    sent = sent_messages.first[1][:text]
    refute_includes sent, '||'
    refute_includes sent, '~~'
    refute_includes sent, '#'
    assert_includes sent, 'секрет'
    assert_includes sent, 'старое'
    assert_includes sent, 'Заголовок'
  end

  def test_classic_path_preserves_code_span_pipes
    set_rich(false)
    rich = FakeRich.new(result: { 'message_id' => 1 })
    MessageSender.new(bot: @bot, chat: @chat, rich_client: rich, text: 'logic: `a || b`').send
    assert_includes sent_messages.first[1][:text], '`a || b`', 'pipes inside code must survive'
  end

  def test_flag_off_skips_rich_entirely
    set_rich(false)
    rich = FakeRich.new(result: { 'message_id' => 1 })
    id = sender(rich: rich).send
    assert_empty rich.calls, 'rich must not be attempted when flag off'
    assert_equal 1, sent_messages.size
    assert_equal 111, id
  end

  def test_reply_keyboard_forces_classic
    rich = FakeRich.new(result: { 'message_id' => 5 })
    MessageSender.new(bot: @bot, chat: @chat, text: 'q',
                      answers: [{ text: 'a' }, { text: 'b' }], rich_client: rich).send
    assert_empty rich.calls, 'messages carrying a reply keyboard must use classic'
    assert_equal 1, sent_messages.size
  end

  def test_rich_forwards_thread_and_reply_and_raw_text
    rich = FakeRich.new(result: { 'message_id' => 9 })
    MessageSender.new(bot: @bot, chat: @chat, text: '**x**', rich_client: rich,
                      message_thread_id: 3, reply_to_message_id: 8).send
    kw = rich.calls.first
    assert_equal 3, kw[:message_thread_id]
    assert_equal 8, kw[:reply_to_message_id]
    assert_equal '**x**', kw[:markdown], 'text is sent raw (no sanitize_markdown)'
  end

  def test_missing_telegram_settings_is_safe_classic
    Settings.instance_variable_set(:@_settings, OpenStruct.new) # no telegram key
    rich = FakeRich.new(result: { 'message_id' => 1 })
    id = sender(rich: rich).send
    assert_empty rich.calls
    assert_equal 111, id
  end
end

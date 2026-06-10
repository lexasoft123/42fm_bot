require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) { @auth ||= { 'super_admin_uids' => [] } }
  Settings.singleton_class.send(:define_method, :auth=) { |v| @auth = v }
end

require 'telegram/bot'
require_relative '../lib/access_request'

# /start access-request flow for unauthorized private chats.
class AccessRequestTest < BotTest
  ADMIN = 9001
  USER  = 555

  class FakeApi
    attr_reader :sent
    def initialize; @sent = []; end
    def sendMessage(**kwargs); @sent << kwargs; OpenStruct.new(message_id: 1); end
  end

  FakeBot = Struct.new(:api)

  def setup
    super
    Settings.auth = { 'super_admin_uids' => [ADMIN] }
    @bot = FakeBot.new(FakeApi.new)
  end

  def start_msg(text: '/start', chat_id: USER, type: 'private')
    OpenStruct.new(
      text: text,
      chat: OpenStruct.new(id: chat_id, type: type, title: nil,
                           first_name: 'Вася', last_name: nil, username: 'vasya'),
    )
  end

  def test_start_files_request_and_notifies_admins
    AccessRequest.maybe_handle(@bot, start_msg)
    chat = Chat.find_by(chat_id: USER)
    refute_nil chat
    refute chat.authorized, 'request must NOT auto-authorize'
    assert_equal 'Вася', chat.title

    to_user  = @bot.api.sent.select { |m| m[:chat_id] == USER }
    to_admin = @bot.api.sent.select { |m| m[:chat_id] == ADMIN }
    assert_equal 1, to_user.size
    assert_includes to_user.first[:text], 'отправлена'
    assert_equal 1, to_admin.size
    assert_includes to_admin.first[:text], 'Вася'
    cb = to_admin.first[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_includes cb, "adm:req_accept:#{USER}"
    assert_includes cb, "adm:req_decline:#{USER}"
  end

  def test_second_start_does_not_renotify
    AccessRequest.maybe_handle(@bot, start_msg)
    AccessRequest.maybe_handle(@bot, start_msg)
    to_admin = @bot.api.sent.select { |m| m[:chat_id] == ADMIN }
    assert_equal 1, to_admin.size, 'admins must be notified once'
    pending = @bot.api.sent.select { |m| m[:chat_id] == USER }.last
    assert_includes pending[:text], 'уже на рассмотрении'
  end

  def test_start_with_bot_mention_matches
    AccessRequest.maybe_handle(@bot, start_msg(text: '/start@my42fmbot'))
    refute_nil Chat.find_by(chat_id: USER)
  end

  def test_start_with_deep_link_payload_matches
    AccessRequest.maybe_handle(@bot, start_msg(text: '/start ref123'))
    refute_nil Chat.find_by(chat_id: USER), 't.me/bot?start=... taps must file a request too'
  end

  def test_startover_command_does_not_match
    AccessRequest.maybe_handle(@bot, start_msg(text: '/startover'))
    assert_nil Chat.find_by(chat_id: USER)
  end

  def test_non_start_text_stays_silent
    AccessRequest.maybe_handle(@bot, start_msg(text: 'привет'))
    assert_empty @bot.api.sent
    assert_nil Chat.find_by(chat_id: USER)
  end

  def test_group_chats_stay_silent
    AccessRequest.maybe_handle(@bot, start_msg(type: 'supergroup', chat_id: -100500))
    assert_empty @bot.api.sent
    assert_nil Chat.find_by(chat_id: -100500)
  end
end

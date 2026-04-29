require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Bare-minimum Settings.auth + Settings.replies surface for the menu code.
unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    @auth ||= { 'super_admin_uids' => [], 'rate_limits' => { 'image' => { 'max' => 1, 'window_minutes' => 20 }, 'suno' => { 'max' => 1, 'window_minutes' => 20 } } }
  }
  Settings.singleton_class.send(:define_method, :auth=) { |v| @auth = v }
end
unless Settings.respond_to?(:replies)
  Settings.singleton_class.send(:define_method, :replies) { {} }
end

require 'telegram/bot'
require_relative '../lib/admin_menu'

# Records every API call so tests can assert what was sent.
class FakeBotApi
  attr_reader :calls
  def initialize; @calls = []; end
  def method_missing(name, **kwargs)
    @calls << [name, kwargs]
    OpenStruct.new(message_id: 99999)
  end
  def respond_to_missing?(_name, _priv = false); true; end
end

class FakeBot
  attr_reader :api
  def initialize; @api = FakeBotApi.new; end
end

def make_query(uid:, data:, message_id: 1, chat_id: nil)
  chat_id ||= uid
  OpenStruct.new(
    id: 'cbq-id',
    from: OpenStruct.new(id: uid),
    data: data,
    message: OpenStruct.new(chat: OpenStruct.new(id: chat_id, type: 'private'),
                            message_id: message_id),
  )
end

class AdminMenuSessionTest < BotTest
  def setup
    super
    AdminMenu::Session.reset_for_test!
  end

  def test_state_is_per_uid
    AdminMenu::Session.set(1, view: :root)
    AdminMenu::Session.set(2, view: :chats)
    assert_equal :root,  AdminMenu::Session.for(1)[:view]
    assert_equal :chats, AdminMenu::Session.for(2)[:view]
  end

  def test_clear_removes_state
    AdminMenu::Session.set(1, view: :root, message_id: 10)
    AdminMenu::Session.clear(1)
    assert_equal({}, AdminMenu::Session.for(1))
  end

  def test_awaiting_input_ttl_expires
    AdminMenu::Session.set_awaiting_input(1, kind: :rate_limit, chat_id: -100, bucket: 'suno')
    assert AdminMenu::Session.awaiting_input?(1)
    # Mutate set_at into the past via internal handle.
    AdminMenu::Session.instance_variable_get(:@state)[1][:awaiting_set_at] = Time.now - 6 * 60
    refute AdminMenu::Session.awaiting_input?(1), 'should auto-expire after 5 min'
  end

  def test_awaiting_input_within_ttl_stays_set
    AdminMenu::Session.set_awaiting_input(1, kind: :rate_limit, chat_id: -100, bucket: 'suno')
    assert AdminMenu::Session.awaiting_input?(1)
    AdminMenu::Session.clear_awaiting_input(1)
    refute AdminMenu::Session.awaiting_input?(1)
  end
end

class AdminMenuRouterTest < BotTest
  def test_root
    a = AdminMenu::Router.parse('adm:root')
    assert a.render?
    assert_equal :root, a.view
  end

  def test_close
    assert AdminMenu::Router.parse('adm:close').close?
  end

  def test_chats_with_page
    a = AdminMenu::Router.parse('adm:chats:2')
    assert a.render?
    assert_equal({ page: 2 }, a.params)
  end

  def test_chat_detail
    a = AdminMenu::Router.parse('adm:chat:-100123')
    assert_equal :chat_detail, a.view
    assert_equal({ chat_id: -100123 }, a.params)
  end

  def test_chat_limit_edit_is_input
    a = AdminMenu::Router.parse('adm:chat_limit_edit:-100:suno')
    assert a.input?
    assert_equal({ chat_id: -100, bucket: 'suno' }, a.params)
  end

  def test_unknown
    assert AdminMenu::Router.parse('adm:nonsense').unknown?
    assert AdminMenu::Router.parse('garbage').unknown?
    assert AdminMenu::Router.parse('adm:').unknown?
  end

  def test_user_toggle
    a = AdminMenu::Router.parse('adm:user_toggle:777')
    assert a.mutating?
    assert_equal :user_toggle, a.view
    assert_equal({ uid: 777 }, a.params)
  end
end

class AdminMenuViewsTest < BotTest
  def test_root_has_four_buttons
    v = AdminMenu::Views.root
    assert_match(/Админ-меню/, v[:text])
    rows = v[:reply_markup].inline_keyboard
    assert_equal 4, rows.size
    callbacks = rows.flatten.map(&:callback_data)
    assert_includes callbacks, 'adm:chats:0'
    assert_includes callbacks, 'adm:admins:0'
    assert_includes callbacks, 'adm:status'
    assert_includes callbacks, 'adm:close'
  end

  def test_chats_pagination_boundary
    7.times { |i| Chat.create!(chat_id: -1000 - i, title: "Chat #{i}", chat_type: 'group', authorized: true, audio: false) }
    v0 = AdminMenu::Views.chats(page: 0)
    assert_match(/стр\. 1\/2/, v0[:text])
    cb = v0[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_includes cb, 'adm:chats:1'   # next
    refute_includes cb, 'adm:chats:-1'  # no prev on page 0

    v1 = AdminMenu::Views.chats(page: 1)
    cb1 = v1[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_includes cb1, 'adm:chats:0'  # prev
    refute_includes cb1, 'adm:chats:2'  # no next on last page
  end

  def test_chat_detail_shows_status
    Chat.create!(chat_id: -42, title: 'x', chat_type: 'group', authorized: true, audio: false)
    v = AdminMenu::Views.chat_detail(chat_id: -42)
    assert_match(/authorized: ✓/, v[:text])
    cb = v[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_includes cb, 'adm:chat_toggle_auth:-42'
    assert_includes cb, 'adm:chat_toggle_audio:-42'
    assert_includes cb, 'adm:chat_limits:-42'
  end

  def test_chat_detail_missing_chat
    v = AdminMenu::Views.chat_detail(chat_id: -999)
    assert_match(/не найден/, v[:text])
  end
end

class AdminMenuCallbackHandlerTest < BotTest
  ME = 1001
  CHAT = -100500

  def setup
    super
    AdminMenu::Session.reset_for_test!
    Settings.auth = { 'super_admin_uids' => [ME],
                      'rate_limits' => { 'suno' => { 'max' => 1, 'window_minutes' => 20 }, 'image' => { 'max' => 1, 'window_minutes' => 20 } } }
  end

  def test_non_super_admin_gets_denied
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: 999, data: 'adm:chat_toggle_auth:' + CHAT.to_s))
    assert Chat.find_by(chat_id: CHAT).authorized, 'must not flip authorized for non-super-admin'
    answer = bot.api.calls.find { |n, _| n == :answerCallbackQuery }
    assert_match(/нет доступа/, answer[1][:text])
  end

  def test_toggle_audio_flips_column
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:chat_toggle_audio:#{CHAT}"))
    assert Chat.find_by(chat_id: CHAT).audio
  end

  def test_toggle_auth_on_last_authorized_shows_confirmation
    # Only one authorized chat; tapping deauth must NOT flip.
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:chat_toggle_auth:#{CHAT}"))
    assert Chat.find_by(chat_id: CHAT).authorized, 'must not flip on first tap when last authorized'
    edit = bot.api.calls.find { |n, _| n == :editMessageText }
    refute_nil edit
    assert_match(/Останется 0 авторизованных/, edit[1][:text])
  end

  def test_toggle_auth_confirm_flips_on_last
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:chat_toggle_auth_confirm:#{CHAT}"))
    refute Chat.find_by(chat_id: CHAT).authorized, 'confirm path must flip even when it was last'
  end

  def test_refuse_to_deauthorize_super_admin_private_chat
    # private chat for super-admin has chat_id == uid
    Chat.create!(chat_id: ME, title: 'me', chat_type: 'private', authorized: true, audio: false)
    Chat.create!(chat_id: CHAT, title: 'g', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:chat_toggle_auth:#{ME}"))
    assert Chat.find_by(chat_id: ME).authorized, 'must NOT deauthorize super-admin private chat'
    answer = bot.api.calls.find { |n, _| n == :answerCallbackQuery }
    assert_match(/собственный чат/, answer[1][:text])
  end

  def test_refuse_to_demote_super_admin_role
    User.create!(uid: ME, name: 'me', role: 'admin')
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:user_toggle:#{ME}"))
    assert_equal 'admin', User.find_by(uid: ME).role
    answer = bot.api.calls.find { |n, _| n == :answerCallbackQuery }
    assert_match(/разжаловать/, answer[1][:text])
  end

  def test_promote_user
    User.create!(uid: 5050, name: 'bob', role: 'member')
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: 'adm:user_toggle:5050'))
    assert_equal 'admin', User.find_by(uid: 5050).role
  end

  def test_unknown_action
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: 'adm:nonsense'))
    assert_empty bot.api.calls.select { |n, _| n == :editMessageText }
  end

  def test_close_deletes_message_and_clears_session
    AdminMenu::Session.set(ME, message_id: 7, view: :root)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: 'adm:close', message_id: 7))
    assert bot.api.calls.any? { |n, _| n == :deleteMessage }
    assert_equal({}, AdminMenu::Session.for(ME))
  end

  def test_chat_limit_edit_sets_awaiting_input
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: "adm:chat_limit_edit:#{CHAT}:suno"))
    assert AdminMenu::Session.awaiting_input?(ME)
    payload = AdminMenu::Session.awaiting_input(ME)
    assert_equal :rate_limit, payload[:kind]
    assert_equal CHAT, payload[:chat_id]
    assert_equal 'suno', payload[:bucket]
  end
end

class AdminMenuTextInputHandlerTest < BotTest
  ME = 1001
  CHAT = -100777

  def setup
    super
    AdminMenu::Session.reset_for_test!
    Settings.auth = { 'super_admin_uids' => [ME],
                      'rate_limits' => { 'suno' => { 'max' => 1, 'window_minutes' => 20 }, 'image' => { 'max' => 1, 'window_minutes' => 20 } } }
    @user = OpenStruct.new(uid: ME)
    @bot  = FakeBot.new
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false)
    AdminMenu::Session.set_awaiting_input(ME, kind: :rate_limit, chat_id: CHAT, bucket: 'suno')
  end

  def fake_msg(text)
    OpenStruct.new(text: text, chat: OpenStruct.new(id: ME, type: 'private'))
  end

  def test_valid_input_writes_rate_limits
    AdminMenu::TextInputHandler.handle(@bot, fake_msg('5,30'), @user)
    rl = JSON.parse(Chat.find_by(chat_id: CHAT).rate_limits)
    assert_equal 5, rl['suno']['max']
    assert_equal 30, rl['suno']['window_minutes']
    refute AdminMenu::Session.awaiting_input?(ME), 'should clear awaiting_input after success'
  end

  def test_bad_inputs
    %w[abc 5 5,abc 0,30 -1,5 5,0 1.5,30 5,30,extra].each do |bad|
      AdminMenu::TextInputHandler.handle(@bot, fake_msg(bad), @user)
      assert AdminMenu::Session.awaiting_input?(ME), "should stay in awaiting_input for #{bad.inspect}"
      assert_nil Chat.find_by(chat_id: CHAT).rate_limits, "must NOT write for #{bad.inspect}"
    end
  end

  def test_cancel_clears
    AdminMenu::TextInputHandler.handle(@bot, fake_msg('/cancel'), @user)
    refute AdminMenu::Session.awaiting_input?(ME)
    assert @bot.api.calls.any? { |n, kw| n == :sendMessage && kw[:text] == 'Отменено.' }
  end

  def test_cancel_otmena_word
    AdminMenu::TextInputHandler.handle(@bot, fake_msg('Отмена'), @user)
    refute AdminMenu::Session.awaiting_input?(ME)
  end

  def test_slash_prefix_passes_through
    consumed = AdminMenu::TextInputHandler.handle(@bot, fake_msg('/admin'), @user)
    refute consumed, 'must NOT consume slash-commands'
    assert AdminMenu::Session.awaiting_input?(ME), 'awaiting_input stays for re-entry'
  end

  def test_bot_prefix_passes_through
    consumed = AdminMenu::TextInputHandler.handle(@bot, fake_msg('бот привет'), @user)
    refute consumed
    assert AdminMenu::Session.awaiting_input?(ME)
  end
end

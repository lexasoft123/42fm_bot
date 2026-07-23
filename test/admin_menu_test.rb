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

  def test_access_request_actions
    a = AdminMenu::Router.parse('adm:req_accept:555')
    assert a.mutating?
    assert_equal :req_accept, a.view
    assert_equal({ chat_id: 555 }, a.params)
    d = AdminMenu::Router.parse('adm:req_decline:555')
    assert d.mutating?
    assert_equal :req_decline, d.view
  end
end

class AdminMenuViewsTest < BotTest
  def setup
    super
    AdminMenu::Views.reset_getchat_cache_for_test!
  end

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

  # --- "unknown" titles (legacy config-seeded rows) ---

  class FakeGetChatApi
    attr_reader :calls
    def initialize(title: nil, fail_for: [], fail_message: 'kicked')
      @title = title
      @fail_for = fail_for
      @fail_message = fail_message
      @calls = []
    end

    def getChat(chat_id:)
      @calls << chat_id
      raise Telegram::Bot::Exceptions::Base, @fail_message if @fail_for.include?(chat_id)
      OpenStruct.new(title: @title)
    end
  end

  def test_unknown_title_falls_back_to_chat_id_on_buttons
    Chat.create!(chat_id: -555, title: 'unknown', chat_type: '', authorized: true, audio: false)
    v = AdminMenu::Views.chats(page: 0)
    labels = v[:reply_markup].inline_keyboard.flatten.map(&:text)
    assert(labels.any? { |l| l.include?('-555') }, "expected chat_id in labels: #{labels}")
    refute(labels.any? { |l| l.include?('unknown') }, 'literal "unknown" must not be shown')
  end

  def test_chats_ordered_authorized_and_recent_first
    Chat.create!(chat_id: -1, title: 'dead',  chat_type: '', authorized: false, audio: false)
    Chat.create!(chat_id: -2, title: 'live',  chat_type: 'supergroup', authorized: true, audio: false, last_seen_at: Time.now)
    Chat.create!(chat_id: -3, title: 'stale', chat_type: 'supergroup', authorized: true, audio: false)
    v = AdminMenu::Views.chats(page: 0)
    labels = v[:reply_markup].inline_keyboard.flatten.map(&:text)
    live_idx  = labels.index { |l| l.include?('live') }
    stale_idx = labels.index { |l| l.include?('stale') }
    dead_idx  = labels.index { |l| l.include?('dead') }
    assert live_idx < stale_idx, 'recently-seen authorized chat first'
    assert stale_idx < dead_idx, 'unauthorized chats sink below authorized'
  end

  def test_refresh_titles_backfills_via_get_chat
    Chat.create!(chat_id: -777, title: 'unknown', chat_type: '', authorized: true, audio: false)
    Chat.create!(chat_id: -778, title: 'Котики', chat_type: 'group', authorized: true, audio: false)
    api = FakeGetChatApi.new(title: 'Старый чат')
    v = AdminMenu::Views.chats(page: 0, api: api)
    assert_equal [-777], api.calls, 'getChat only for unknown-titled rows'
    assert_equal 'Старый чат', Chat.find_by(chat_id: -777).title
    labels = v[:reply_markup].inline_keyboard.flatten.map(&:text)
    assert(labels.any? { |l| l.include?('Старый чат') })
  end

  def test_transient_getchat_failure_cached_in_process
    Chat.create!(chat_id: -888, title: 'unknown', chat_type: '', authorized: true, audio: false)
    api = FakeGetChatApi.new(title: 'x', fail_for: [-888]) # message 'kicked' — not definitive
    v = AdminMenu::Views.chats(page: 0, api: api)
    assert_equal 'unknown', Chat.find_by(chat_id: -888).title, 'transient failure leaves row untouched'
    labels = v[:reply_markup].inline_keyboard.flatten.map(&:text)
    assert(labels.any? { |l| l.include?('-888') }, 'failed chat keeps showing its id')
    AdminMenu::Views.chats(page: 0, api: api)
    assert_equal 1, api.calls.size, 'transient failure must NOT retry within the same process'
  end

  def test_chat_not_found_persists_dead_marker_and_never_retries
    Chat.create!(chat_id: -890, title: 'unknown', chat_type: '', authorized: true, audio: false)
    api = FakeGetChatApi.new(fail_for: [-890],
                             fail_message: 'Bad Request: chat not found')
    AdminMenu::Views.chats(page: 0, api: api)
    assert_equal '💀 -890', Chat.find_by(chat_id: -890).title,
                 'definitive not-found gets a persistent dead marker'
    AdminMenu::Views.reset_getchat_cache_for_test! # even a fresh process...
    AdminMenu::Views.chats(page: 0, api: api)
    assert_equal 1, api.calls.size, '...must not re-fetch a 💀-marked row'
  end

  def test_refresh_titles_never_fetches_unauthorized_rows
    # Unauthorized legacy rows are the ones most likely to hang getChat —
    # and these calls run in bot.listen's single-threaded loop.
    Chat.create!(chat_id: -889, title: 'unknown', chat_type: '', authorized: false, audio: false)
    api = FakeGetChatApi.new(title: 'x')
    AdminMenu::Views.chats(page: 0, api: api)
    assert_empty api.calls, 'unauthorized rows must not trigger getChat'
  end

  def test_chat_detail_unknown_title_shows_id_line
    Chat.create!(chat_id: -556, title: 'unknown', chat_type: '', authorized: false, audio: false)
    v = AdminMenu::Views.chat_detail(chat_id: -556)
    assert_match(/^id: -556$/, v[:text])
    refute_match(/unknown \(id/, v[:text])
  end

  # --- "Open profile / open chat" links (url buttons) ---

  class FakeLinkApi
    attr_reader :calls
    def initialize(username: nil, invite_link: nil, raise_with: nil)
      @username = username; @invite_link = invite_link; @raise_with = raise_with; @calls = []
    end

    def getChat(chat_id:)
      @calls << chat_id
      raise Telegram::Bot::Exceptions::Base, @raise_with if @raise_with
      OpenStruct.new(username: @username, invite_link: @invite_link)
    end
  end

  def urls_of(view)
    view[:reply_markup].inline_keyboard.flatten.map(&:url).compact
  end

  def test_user_detail_has_profile_link
    User.create!(uid: 12345, name: 'Вася', role: 'member')
    v = AdminMenu::Views.user_detail(uid: 12345)
    assert_includes urls_of(v), 'tg://user?id=12345'
  end

  # A private chat's id IS the user's uid → link straight to the profile,
  # no API call needed (this is the access-request "Принят: φ (id: …)" case).
  def test_chat_detail_private_has_profile_link
    Chat.create!(chat_id: 755777089, title: 'φ', chat_type: 'private', authorized: true, audio: false)
    v = AdminMenu::Views.chat_detail(chat_id: 755777089) # no api needed
    assert_includes urls_of(v), 'tg://user?id=755777089'
  end

  def test_chat_detail_public_group_gets_tme_link
    Chat.create!(chat_id: -100200, title: 'Cool', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(username: 'coolchat')
    v = AdminMenu::Views.chat_detail(chat_id: -100200, api: api)
    assert_includes urls_of(v), 'https://t.me/coolchat'
    assert_equal [-100200], api.calls
  end

  def test_chat_detail_falls_back_to_invite_link
    Chat.create!(chat_id: -100250, title: 'Priv', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(invite_link: 'https://t.me/+abc123')
    v = AdminMenu::Views.chat_detail(chat_id: -100250, api: api)
    assert_includes urls_of(v), 'https://t.me/+abc123'
  end

  def test_chat_detail_no_link_when_group_is_unlinkable
    Chat.create!(chat_id: -100260, title: 'Priv', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new # no username, no invite_link
    v = AdminMenu::Views.chat_detail(chat_id: -100260, api: api)
    assert_empty urls_of(v), 'private group with no public handle gets no link button'
    cb = v[:reply_markup].inline_keyboard.flatten.map(&:callback_data).compact
    assert_includes cb, 'adm:chat_toggle_auth:-100260', 'normal controls still present'
  end

  def test_chat_detail_getchat_failure_is_silent
    Chat.create!(chat_id: -100300, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(raise_with: 'Bad Request: chat not found')
    v = AdminMenu::Views.chat_detail(chat_id: -100300, api: api)
    assert_empty urls_of(v), 'getChat failure must not add a broken link'
    cb = v[:reply_markup].inline_keyboard.flatten.map(&:callback_data).compact
    assert_includes cb, 'adm:chat_toggle_auth:-100300'
  end

  def test_chat_detail_group_no_getchat_without_api
    Chat.create!(chat_id: -100400, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    v = AdminMenu::Views.chat_detail(chat_id: -100400) # api nil
    assert_empty urls_of(v)
  end

  def test_chat_detail_unauthorized_group_never_calls_getchat
    Chat.create!(chat_id: -100600, title: 'x', chat_type: 'group', authorized: false, audio: false)
    api = FakeLinkApi.new(username: 'c')
    v = AdminMenu::Views.chat_detail(chat_id: -100600, api: api)
    assert_empty api.calls, 'unauthorized rows must not trigger getChat (single-threaded stall)'
    assert_empty urls_of(v)
  end

  def test_chat_detail_username_link_is_cached_per_process
    Chat.create!(chat_id: -100500, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(username: 'c')
    AdminMenu::Views.chat_detail(chat_id: -100500, api: api)
    AdminMenu::Views.chat_detail(chat_id: -100500, api: api)
    assert_equal 1, api.calls.size, 'stable @username result cached — no repeat hammering'
  end

  # Finding 1: invite links get revoked/rotated → returned live, never cached.
  def test_invite_link_is_not_cached_so_revoked_invites_self_heal
    Chat.create!(chat_id: -100251, title: 'Priv', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(invite_link: 'https://t.me/+abc')
    AdminMenu::Views.chat_detail(chat_id: -100251, api: api)
    AdminMenu::Views.chat_detail(chat_id: -100251, api: api)
    assert_equal 2, api.calls.size, 'invite-link result must not be cached (invites rotate)'
  end

  # Finding 2: a permanent "chat not found" is cached; transient errors are not.
  def test_definitive_chat_not_found_is_cached
    Chat.create!(chat_id: -100310, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(raise_with: 'Bad Request: chat not found')
    AdminMenu::Views.chat_detail(chat_id: -100310, api: api)
    AdminMenu::Views.chat_detail(chat_id: -100310, api: api)
    assert_equal 1, api.calls.size, 'permanent "chat not found" cached, not re-fetched'
  end

  def test_transient_getchat_failure_retries_next_open
    Chat.create!(chat_id: -100320, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    api = FakeLinkApi.new(raise_with: 'Too Many Requests: retry after 5')
    AdminMenu::Views.chat_detail(chat_id: -100320, api: api)
    AdminMenu::Views.chat_detail(chat_id: -100320, api: api)
    assert_equal 2, api.calls.size, 'transient failure not cached — retry on next open'
  end

  # Finding 3: exercise the Hash / 'result'-envelope branch of tg_attr.
  class HashGetChatApi
    def getChat(chat_id:); { 'result' => { 'username' => 'hashchat' } }; end
  end

  def test_chat_detail_reads_hash_shaped_getchat_result
    Chat.create!(chat_id: -100700, title: 'x', chat_type: 'supergroup', authorized: true, audio: false)
    v = AdminMenu::Views.chat_detail(chat_id: -100700, api: HashGetChatApi.new)
    assert_includes urls_of(v), 'https://t.me/hashchat', 'tg_attr must read the Hash/result-envelope shape'
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

  def test_req_accept_authorizes_and_notifies_requester
    Chat.create!(chat_id: 555, title: 'Вася', chat_type: 'private', authorized: false, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: 'adm:req_accept:555'))
    assert Chat.find_by(chat_id: 555).authorized
    sent = bot.api.calls.select { |n, kw| n == :sendMessage && kw[:chat_id] == 555 }
    assert_equal 1, sent.size
    assert_match(/Доступ открыт/, sent.first[1][:text])
    edit = bot.api.calls.find { |n, _| n == :editMessageText }
    assert_match(/✅ Принят: Вася/, edit[1][:text])
  end

  def test_req_decline_keeps_unauthorized_and_notifies
    Chat.create!(chat_id: 556, title: 'Спамер', chat_type: 'private', authorized: false, audio: false)
    bot = FakeBot.new
    AdminMenu::CallbackHandler.handle(bot, make_query(uid: ME, data: 'adm:req_decline:556'))
    refute Chat.find_by(chat_id: 556).authorized
    sent = bot.api.calls.select { |n, kw| n == :sendMessage && kw[:chat_id] == 556 }
    assert_match(/отказано/, sent.first[1][:text])
    edit = bot.api.calls.find { |n, _| n == :editMessageText }
    assert_match(/❌ Отклонён: Спамер/, edit[1][:text])
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

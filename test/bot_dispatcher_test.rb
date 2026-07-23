require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    @auth ||= { 'super_admin_uids' => [] }
  }
  Settings.singleton_class.send(:define_method, :auth=) { |v| @auth = v }
end

require 'telegram/bot'
require_relative '../lib/bot_dispatcher'
require_relative '../lib/access_request'

# Locks in the security invariant from the admin-menu PR: super-admins bypass
# the chats-table allowlist ONLY in private chats. A regression like dropping
# `&& chat.type == 'private'` from BotDispatcher#authorized? would silently
# auto-authorize the super-admin in any group — these tests would catch it.
class BotDispatcherAuthorizedTest < BotTest
  ME = 9001
  GROUP = -1009999

  def setup
    super
    Settings.auth = { 'super_admin_uids' => [ME] }
  end

  def make_msg(uid:, chat_id:, chat_type:)
    OpenStruct.new(
      from: OpenStruct.new(id: uid),
      chat: OpenStruct.new(id: chat_id, type: chat_type),
    )
  end

  def test_super_admin_private_chat_bypasses_allowlist
    refute Chat.where(chat_id: ME, authorized: true).exists?, 'no chats row should exist'
    msg = make_msg(uid: ME, chat_id: ME, chat_type: 'private')
    assert BotDispatcher.authorized?(msg), 'super-admin private chat must auto-authorize'
  end

  def test_super_admin_in_group_does_NOT_bypass
    msg = make_msg(uid: ME, chat_id: GROUP, chat_type: 'supergroup')
    refute BotDispatcher.authorized?(msg),
           'super-admin in a group chat must NOT bypass the allowlist'
    Chat.create!(chat_id: GROUP, title: 'g', chat_type: 'supergroup', authorized: true, audio: false)
    assert BotDispatcher.authorized?(msg),
           'super-admin in an authorized group chat is allowed via the allowlist'
  end

  def test_non_super_admin_private_chat_requires_allowlist
    other = 12345
    msg = make_msg(uid: other, chat_id: other, chat_type: 'private')
    refute BotDispatcher.authorized?(msg),
           'non-super-admin private chat must NOT auto-authorize'
  end

  def test_authorized_chat_lets_anyone_through
    Chat.create!(chat_id: GROUP, title: 'g', chat_type: 'supergroup', authorized: true, audio: false)
    msg = make_msg(uid: 555, chat_id: GROUP, chat_type: 'supergroup')
    assert BotDispatcher.authorized?(msg)
  end

  def test_unauthorized_chat_drops_message
    Chat.create!(chat_id: GROUP, title: 'g', chat_type: 'supergroup', authorized: false, audio: false)
    msg = make_msg(uid: 555, chat_id: GROUP, chat_type: 'supergroup')
    refute BotDispatcher.authorized?(msg)
  end
end

# Unauthorized-chat recording (admin-menu surfacing fix). A group the bot is
# added to must land in the chats table as authorized=false so it can be seen
# and toggled from /admin — WITHOUT notifying admins. Private chats stay owned
# by the AccessRequest /start flow and must NOT be recorded on the drop path.
class BotDispatcherUnauthorizedRecordingTest < BotTest
  GROUP = -1002883573395

  class FakeApi
    attr_reader :sent
    def initialize; @sent = []; end
    def sendMessage(**kwargs); @sent << kwargs; OpenStruct.new(message_id: 1); end
  end
  FakeBot = Struct.new(:api)

  def setup
    super
    Settings.auth = { 'super_admin_uids' => [] }
    @bot = FakeBot.new(FakeApi.new)
  end

  def msg(chat_id:, type:, text: 'бот привет', title: 'Fun and nausea',
          first_name: nil, last_name: nil, username: nil, uid: 555)
    OpenStruct.new(
      from: OpenStruct.new(id: uid, username: username),
      text: text, caption: nil,
      chat: OpenStruct.new(id: chat_id, type: type, title: title,
                           first_name: first_name, last_name: last_name, username: username),
    )
  end

  def test_unauthorized_group_recorded_unauthorized_without_notifying
    refute Chat.where(chat_id: GROUP).exists?
    BotDispatcher.handle_message(@bot, msg(chat_id: GROUP, type: 'supergroup'))
    chat = Chat.find_by(chat_id: GROUP)
    refute_nil chat, 'unauthorized group must be recorded so it surfaces in /admin'
    refute chat.authorized, 'recorded group must stay unauthorized'
    assert_equal 'Fun and nausea', chat.title
    assert_equal 'supergroup', chat.chat_type
    assert_empty @bot.api.sent, 'groups must NOT notify admins'
  end

  def test_unauthorized_private_non_start_not_recorded
    BotDispatcher.handle_message(@bot, msg(chat_id: 777, type: 'private', text: 'привет',
                                           title: nil, first_name: 'Вася'))
    assert_nil Chat.find_by(chat_id: 777),
               'random unauthorized DMs must not pollute the chats table'
    assert_empty @bot.api.sent
  end

  # Recording an already-seen unauthorized group refreshes its metadata
  # (title/last_seen — so the menu's "dead rows sink" ordering stays fresh)
  # but must never touch `authorized` (touch_seen sets it only on new rows).
  # NB: the real guard against flipping an *authorized* chat is the enclosing
  # `unless authorized?` — such a chat never reaches this branch at all.
  def test_recording_refreshes_metadata_but_preserves_unauthorized_state
    Chat.create!(chat_id: GROUP, title: 'old', chat_type: 'supergroup', authorized: false, audio: false)
    BotDispatcher.handle_message(@bot, msg(chat_id: GROUP, type: 'supergroup'))
    row = Chat.find_by(chat_id: GROUP)
    refute row.authorized, 'recording must never flip auth state'
    assert_equal 'Fun and nausea', row.title, 'recording should refresh the title'
  end

  # End-to-end through handle_message: a private /start still files the access
  # request (row + admin notification) while the new non-private recording
  # branch stays skipped — locks in the ordering interaction from review #1.
  def test_private_start_files_request_and_skips_recording_branch
    admin = 9001
    Settings.auth = { 'super_admin_uids' => [admin] }
    BotDispatcher.handle_message(@bot, msg(chat_id: 777, type: 'private', text: '/start',
                                           title: nil, first_name: 'Вася', uid: 777))
    row = Chat.find_by(chat_id: 777)
    refute_nil row, 'private /start must still create the AccessRequest row'
    refute row.authorized, 'request must not auto-authorize'
    to_admin = @bot.api.sent.select { |m| m[:chat_id] == admin }
    to_user  = @bot.api.sent.select { |m| m[:chat_id] == 777 }
    assert_equal 1, to_admin.size, 'super-admin must be notified exactly once'
    assert_includes to_admin.first[:reply_markup].inline_keyboard.flatten.map(&:callback_data),
                    'adm:req_accept:777'
    assert_equal 1, to_user.size
    assert_includes to_user.first[:text], 'отправлена'
  end
end

# Reaction-count capture (S1). The per-user delta path is best-effort and
# lossy; message_reaction_count is authoritative and must OVERWRITE (not
# increment) so it provably reconciles drift.
class BotDispatcherReactionTest < BotTest
  GROUP = -1008888

  def setup
    super
    Chat.create!(chat_id: GROUP, title: 'g', chat_type: 'supergroup', authorized: true, audio: false)
    @msg = Message.create!(chat_id: GROUP, message_id: 42, role: 'user', body: 'смешно', user_uid: 7)
  end

  def reaction(chat_id: GROUP, message_id: 42, old: 0, new: 1, user: OpenStruct.new(id: 7))
    OpenStruct.new(chat: OpenStruct.new(id: chat_id), message_id: message_id,
                   old_reaction: Array.new(old) { OpenStruct.new },
                   new_reaction: Array.new(new) { OpenStruct.new }, user: user)
  end

  def count_update(chat_id: GROUP, message_id: 42, totals: [2])
    OpenStruct.new(chat: OpenStruct.new(id: chat_id), message_id: message_id,
                   reactions: totals.map { |t| OpenStruct.new(total_count: t) })
  end

  def test_delta_add_increments
    BotDispatcher.handle_reaction(reaction(old: 0, new: 1))
    BotDispatcher.handle_reaction(reaction(old: 1, new: 2))
    assert_equal 2, @msg.reload.reactions_count
  end

  def test_swap_is_zero_delta
    @msg.update!(reactions_count: 1)
    BotDispatcher.handle_reaction(reaction(old: 1, new: 1)) # 👍→❤️
    assert_equal 1, @msg.reload.reactions_count
  end

  def test_removal_clamps_at_zero
    @msg.update!(reactions_count: 1)
    BotDispatcher.handle_reaction(reaction(old: 2, new: 0))
    assert_equal 0, @msg.reload.reactions_count
  end

  def test_nil_user_tolerated
    BotDispatcher.handle_reaction(reaction(old: 0, new: 1, user: nil))
    assert_equal 1, @msg.reload.reactions_count
  end

  def test_count_update_overwrites_not_increments
    @msg.update!(reactions_count: 5) # deliberately drifted
    BotDispatcher.handle_reaction_count(count_update(totals: [1, 1]))
    assert_equal 2, @msg.reload.reactions_count, 'authoritative count must reconcile drift'
  end

  def test_unauthorized_chat_ignored
    other = Message.create!(chat_id: -1007777, message_id: 42, role: 'user', body: 'x', user_uid: 7)
    BotDispatcher.handle_reaction(reaction(chat_id: -1007777))
    BotDispatcher.handle_reaction_count(count_update(chat_id: -1007777, totals: [9]))
    assert_equal 0, other.reload.reactions_count
  end

  def test_unknown_message_is_noop
    BotDispatcher.handle_reaction(reaction(message_id: 777)) # no row — must not raise
    BotDispatcher.handle_reaction_count(count_update(message_id: 777))
    assert_equal 0, @msg.reload.reactions_count
  end
end

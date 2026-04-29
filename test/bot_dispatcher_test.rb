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

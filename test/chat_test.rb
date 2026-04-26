require_relative 'test_helper'
require_relative '../lib/agent/scratchpad'

class ChatTest < BotTest
  CHAT = -1001234567890

  def test_touch_seen_creates_row
    c = Chat.touch_seen(CHAT, title: 'Test Chat', type: 'supergroup')
    assert_equal CHAT, c.chat_id
    assert_equal 'Test Chat', c.title
    assert_equal 'supergroup', c.chat_type
    assert c.first_seen_at
    assert c.last_seen_at
  end

  def test_touch_seen_is_idempotent
    Chat.touch_seen(CHAT, title: 'A', type: 'group')
    first_seen = Chat.find(CHAT).first_seen_at
    sleep 0.01
    Chat.touch_seen(CHAT, title: 'B', type: 'supergroup')
    c = Chat.find(CHAT)
    assert_equal 'B', c.title
    assert_equal 'supergroup', c.chat_type
    assert_equal first_seen, c.first_seen_at # unchanged
    assert_operator c.last_seen_at, :>=, first_seen
  end

  def test_touch_seen_skips_nil_fields
    Chat.touch_seen(CHAT, title: 'Original', type: 'group')
    Chat.touch_seen(CHAT, title: nil, type: nil)
    c = Chat.find(CHAT)
    assert_equal 'Original', c.title
    assert_equal 'group', c.chat_type
  end

  def test_chat_state_association
    Chat.touch_seen(CHAT, title: 't', type: 'supergroup')
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'hello')
    chat = Chat.find(CHAT)
    refute_nil chat.chat_state
    assert_includes chat.chat_state.scratchpad, 'hello'
  end

  def test_sync_from_config_populates_chats
    fake_settings_auth({
      'chats' => [
        { 'id' => -100, 'name' => 'Alpha', 'audio' => true },
        { 'id' => -200, 'name' => 'Beta', 'rate_limits' => { 'image' => { 'max' => 2 } } },
      ]
    }) do
      n = Chat.sync_from_config!
      assert_equal 2, n
      a = Chat.find(-100)
      assert_equal 'Alpha', a.title
      assert_equal true, a.audio
      b = Chat.find(-200)
      assert_equal 'Beta', b.title
      assert_includes b.rate_limits, 'image'
    end
  end

  def test_sync_from_config_is_idempotent_and_preserves_first_seen_at
    fake_settings_auth({ 'chats' => [{ 'id' => -100, 'name' => 'Alpha' }] }) do
      Chat.sync_from_config!
      first = Chat.find(-100).first_seen_at
      sleep 0.01
      Chat.sync_from_config!
      assert_equal first, Chat.find(-100).first_seen_at
    end
  end

  private

  def fake_settings_auth(auth_hash)
    prev = Settings.respond_to?(:auth) ? Settings.auth : nil
    Settings.singleton_class.send(:define_method, :auth) { auth_hash }
    yield
  ensure
    Settings.singleton_class.send(:define_method, :auth) { prev }
  end
end

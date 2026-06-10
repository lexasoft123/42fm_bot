require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Message.top_reacted scope behaviour (S1):
#   scope: :user → human rows only (Quote of the day)
#   scope: :all  → bot rows included (Wrapped "funniest" — bot memes count)
class TopReactedTest < BotTest
  CHAT = -1006666

  def setup
    super
    @human = Message.create!(chat_id: CHAT, message_id: 1, role: 'user', user_uid: 7,
                             body: 'человеческая шутка', reactions_count: 3)
    @meme  = Message.create!(chat_id: CHAT, message_id: 2, role: 'bot',
                             body: '[картинка]', reactions_count: 9)
    @dud   = Message.create!(chat_id: CHAT, message_id: 3, role: 'user', user_uid: 8,
                             body: 'без реакций', reactions_count: 0)
  end

  def test_scope_user_excludes_bot_rows
    got = Message.top_reacted(CHAT, since: 86_400, scope: :user).to_a
    assert_equal [@human.id], got.map(&:id)
  end

  def test_scope_all_includes_bot_memes_ordered_desc
    got = Message.top_reacted(CHAT, since: 86_400, scope: :all).to_a
    assert_equal [@meme.id, @human.id], got.map(&:id)
  end

  def test_zero_reaction_rows_filtered
    refute_includes Message.top_reacted(CHAT, since: 86_400, scope: :all).to_a.map(&:id), @dud.id
  end

  def test_window_filter
    @human.update!(created_at: Time.now - 40 * 86_400)
    got = Message.top_reacted(CHAT, since: 30 * 86_400, scope: :all).to_a
    assert_equal [@meme.id], got.map(&:id)
  end
end

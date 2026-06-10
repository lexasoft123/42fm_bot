require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/commands/base'
require_relative '../lib/commands/quote'

class QuoteCommandTest < BotTest
  CHAT = -1004444

  def ctx(cmd: 'бот цитата')
    OpenStruct.new(cmd: cmd, chat_id: CHAT)
  end

  def test_pattern
    assert Commands::Quote.new(ctx).match?
    assert Commands::Quote.new(ctx(cmd: 'Бот, цитату')).match?
    refute Commands::Quote.new(ctx(cmd: 'бот цитата дня про котов')).match?
  end

  def test_empty_fallback
    res = Commands::Quote.new(ctx).execute
    assert_includes res.payload, 'Цитатник пуст'
  end

  def test_quotes_only_humans_with_mention
    User.create!(uid: 7, name: 'kat', first_name: 'Катя', role: 'member')
    Message.create!(chat_id: CHAT, message_id: 1, role: 'user', user_uid: 7,
                    body: 'гениальная мысль', reactions_count: 2)
    Message.create!(chat_id: CHAT, message_id: 2, role: 'bot',
                    body: 'бот-мем вне конкурса', reactions_count: 99)
    res = Commands::Quote.new(ctx).execute
    assert_includes res.payload, 'гениальная мысль'
    refute_includes res.payload, 'вне конкурса'
    assert_includes res.payload, 'tg://user?id=7'
    assert_includes res.payload, '(2 🔥)'
  end
end

require_relative 'test_helper'
require 'ostruct'
require_relative '../lib/reply_master'

class ReplyMasterTest < BotTest
  def setup
    super
    @user = User.create!(uid: 42, name: 'tester')
    @telegram_user = OpenStruct.new(first_name: 'Test', last_name: 'User')
  end

  def test_disabled_master_never_returns_regex_reply
    reply = ReplyMaster.new(enabled: false).reply(@user, @telegram_user, 'где?')

    assert_nil reply
  end

  def test_disabled_master_never_returns_random_saved_phrase
    Phrase.create!(user: @user, content: 'случайная обзывалка')

    reply = ReplyMaster.new(enabled: false).reply(@user, @telegram_user, 'обычный текст')

    assert_nil reply
  end

  def test_enabled_override_keeps_yaml_replies_available_for_rollback
    reply = ReplyMaster.new(enabled: true).reply(@user, @telegram_user, 'где?')

    assert_includes [
      'в пизде!', 'в Гарварде!', 'у кижуча в голове',
      'у бобра в кандибобере', 'у поней на крупе'
    ], reply
  end
end

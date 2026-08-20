require_relative 'test_helper'
require 'ostruct'
require 'yaml'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# reply_to_bot? reads the bot id off the token; define a stub before
# gpt_chat is exercised (each test file runs in its own process).
unless Settings.respond_to?(:telegram)
  Settings.singleton_class.send(:define_method, :telegram) { { 'token' => '4242:FAKE' } }
end

require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/commands/base'
require_relative '../lib/commands/gpt_helpers'
require_relative '../lib/commands/gpt_chat'

# Registry-level dispatch coverage needs every command class loaded.
%w[admin_menu_open tts_voice bober_voice order_block order_request
   radio_search radio_track stats radio_queue weather listeners
   remove_track remaining history radio_top meta help knowledge_add
   knowledge_list knowledge_delete knowledge_review knowledge_restore news rules quote
   wrapped dice phrase_top task_queue cost_report fallback_reply
   registry].each { |f| require_relative "../lib/commands/#{f}" }

# Fake agent runner so execute() never talks to an LLM. Safe to define:
# this file never requires the real lib/agent/runner.
module Agent
  class Runner
    class << self
      attr_accessor :last_kwargs
    end

    def initialize(**kwargs)
      self.class.last_kwargs = kwargs
    end

    def run = 'ok'
  end
end

# Prefix-less interaction in private chats: bare DM text routes to the
# agent; groups still require a prefix (or reply-to-bot).
class GptChatMatchTest < BotTest
  FakeUser = Struct.new(:uid, :name, :role) do
    def super_admin? = false
  end

  def fake_user
    FakeUser.new(5, 'vasya', 'member')
  end

  def msg(text, type:, reply_to: nil)
    OpenStruct.new(
      text: text, message_id: 100, reply_to_message: reply_to,
      photo: nil, message_thread_id: nil, from: OpenStruct.new(id: 1),
      chat: OpenStruct.new(type: type)
    )
  end

  def ctx_for(text, type: 'supergroup', user: fake_user, reply_to: nil)
    CommandContext.new(
      bot: nil, message: msg(text, type: type, reply_to: reply_to),
      user: user, chat_id: -100123, radio: nil, reply_master: nil,
      cmd: text.downcase
    )
  end

  def gpt(ctx) = Commands::GptChat.new(ctx)

  # --- match? ---

  def test_private_bare_text_matches
    assert gpt(ctx_for('привет, как дела?', type: 'private')).match?
  end

  def test_group_bare_text_does_not_match
    refute gpt(ctx_for('привет, как дела?')).match?
  end

  def test_private_slash_command_does_not_match
    refute gpt(ctx_for('/start', type: 'private')).match?
    refute gpt(ctx_for('/unknown_cmd', type: 'private')).match?
  end

  def test_prefixed_still_matches_everywhere
    assert gpt(ctx_for('бот привет', type: 'private')).match?
    assert gpt(ctx_for('бот привет')).match?
  end

  def test_reply_to_bot_still_matches_in_group
    bot_id = Settings.telegram['token'].split(':').first.to_i
    reply = OpenStruct.new(from: OpenStruct.new(id: bot_id), photo: nil)
    assert gpt(ctx_for('а подробнее?', reply_to: reply)).match?
  end

  # --- registry: which command actually wins ---

  def winner(ctx)
    Commands::REGISTRY.find { |klass| klass.new(ctx).match? }
  end

  def test_bare_private_text_dispatches_to_gpt_chat
    assert_equal Commands::GptChat, winner(ctx_for('как дела', type: 'private'))
  end

  def test_bober_easter_egg_still_wins_in_private
    # Deliberate: unprefixed Easter eggs above GptChat keep priority in DMs.
    # BoberVoice is unanchored — matches mid-sentence.
    assert_equal Commands::BoberVoice,
                 winner(ctx_for('у меня дома бобёр живёт', type: 'private'))
  end

  def test_tts_easter_egg_still_wins_in_private
    # TtsVoice is start-anchored but unprefixed — bare «ублюдки …» wins.
    assert_equal Commands::TtsVoice,
                 winner(ctx_for('ублюдки привет ребята', type: 'private'))
  end

  def test_bare_group_text_falls_to_fallback_reply
    assert_equal Commands::FallbackReply, winner(ctx_for('просто текст'))
  end

  def test_prefixed_command_keeps_priority_in_private
    assert_equal Commands::Rules, winner(ctx_for('бот правила', type: 'private'))
  end
end

# execute(): prefix stripping + phrase harvesting stays prefix-gated.
class GptChatExecuteTest < BotTest
  def setup
    super
    Agent::Runner.last_kwargs = nil
    @user = User.create!(uid: 7, name: 'kat', first_name: 'Катя', role: 'member')
  end

  def msg(text, type:)
    OpenStruct.new(
      text: text, message_id: 100, reply_to_message: nil,
      photo: nil, message_thread_id: nil, from: OpenStruct.new(id: 1),
      chat: OpenStruct.new(type: type)
    )
  end

  def command(text, type: 'private')
    ctx = CommandContext.new(
      bot: nil, message: msg(text, type: type), user: @user,
      chat_id: -100123, radio: nil, reply_master: nil, cmd: text.downcase
    )
    c = Commands::GptChat.new(ctx)
    # Keep execute() off the network/heavy paths; phrase + runner are real.
    c.define_singleton_method(:get_chat_context) { [] }
    c.define_singleton_method(:get_relevant_knowledge) { |_q| nil }
    c.define_singleton_method(:attached_audio) { nil }
    c
  end

  def test_prefixed_text_is_stripped_before_the_agent
    command('бот привет').execute
    assert_equal 'привет', Agent::Runner.last_kwargs[:text]
  end

  def test_bare_private_text_goes_to_agent_verbatim
    command('привет').execute
    assert_equal 'привет', Agent::Runner.last_kwargs[:text]
  end

  def test_bare_private_ty_text_is_not_harvested_as_phrase
    command('ты молодец').execute
    assert_equal 0, Phrase.count, 'DM small talk must not feed the Phrase collection'
  end

  def test_prefixed_ty_text_still_feeds_phrase_collection
    command('бот ты молодец').execute
    assert_equal 1, Phrase.count
    assert_equal 'молодец', Phrase.last.content
  end
end

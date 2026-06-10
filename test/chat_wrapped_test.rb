require_relative 'test_helper'
require 'ostruct'
require 'net/protocol' # Net::ReadTimeout for the retry test
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/agent/scratchpad'
require_relative '../lib/chat_wrapped'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/wrapped_digest_handler'
require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/commands/base'
require_relative '../lib/commands/wrapped'

class FakeWrappedApi
  attr_reader :sent
  def initialize(fail_send: false)
    @sent = []
    @fail_send = fail_send
  end

  def sendMessage(chat_id:, text:)
    raise Net::ReadTimeout if @fail_send
    @sent << text
    { 'result' => { 'message_id' => 1000 + @sent.size } }
  end
end

class ChatWrappedTest < BotTest
  CHAT = -1005555

  def seed!
    User.create!(uid: 7, name: 'kat', first_name: 'Катя', role: 'member')
    3.times { |i| Message.create!(chat_id: CHAT, message_id: i + 1, role: 'user', user_uid: 7, body: "msg #{i}") }
    Message.create!(chat_id: CHAT, message_id: 9, role: 'bot', body: '[картинка]', reactions_count: 5)
    BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, status: 'done',
                           attempts: 0, max_attempts: 60, params: { 'user_uid' => 7 }.to_json)
    BackgroundTask.create!(task_type: 'suno_generate', chat_id: CHAT, status: 'done',
                           attempts: 0, max_attempts: 60, params: '{}')
  end

  def test_generate_aggregates_week
    seed!
    text = ChatWrapped.generate(CHAT)
    assert_includes text, 'Сообщений: 3'
    assert_includes text, 'Катя'                  # top poster by name
    assert_includes text, 'Картинок нарисовано: 1'
    assert_includes text, 'Песен сочинено: 1'
    assert_includes text, 'Самое огненное (5 реакций)'
    assert_includes text, 'Жзяцля'                # funniest is the bot meme (scope :all)
  end

  def test_generate_empty_chat_does_not_crash
    text = ChatWrapped.generate(CHAT)
    assert_includes text, 'Сообщений: 0'
  end
end

class WrappedRevolutionTest < BotTest
  CHAT = -1005556

  def make_task(params = {})
    BackgroundTask.create!(task_type: 'weekly_wrapped', chat_id: CHAT,
                           attempts: 0, max_attempts: 3, params: params.to_json)
  end

  def add_rule!
    Agent::Scratchpad.add_rule(CHAT, content: 'правило', set_by: 1, set_by_name: '@u')
  end

  def test_roll_is_persisted_into_params_before_send
    task = make_task
    WrappedDigestHandler.new.call(task, FakeWrappedApi.new)
    assert_includes [true, false], task.reload.params_hash['revolution']
    assert_equal 'done', task.reload.status
  end

  def test_persisted_true_wipes_rules_and_announces
    add_rule!
    task = make_task('revolution' => true)
    api = FakeWrappedApi.new
    WrappedDigestHandler.new.call(task, api)
    assert_empty Agent::Scratchpad.rules(CHAT)
    assert_includes api.sent.first, 'РЕВОЛЮЦИЯ'
  end

  def test_persisted_false_keeps_rules_quiet
    add_rule!
    task = make_task('revolution' => false)
    api = FakeWrappedApi.new
    WrappedDigestHandler.new.call(task, api)
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size
    refute_includes api.sent.first, 'РЕВОЛЮЦИЯ'
  end

  def test_retry_rereads_persisted_roll_instead_of_rerolling
    add_rule!
    task = make_task('revolution' => false)
    assert_raises(Net::ReadTimeout) { WrappedDigestHandler.new.call(task, FakeWrappedApi.new(fail_send: true)) }
    assert_equal false, task.reload.params_hash['revolution'], 'failed send must not change the roll'
    api = FakeWrappedApi.new
    WrappedDigestHandler.new.call(task.reload, api)
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size, 'retry must not flip into a revolution'
    refute_includes api.sent.first, 'РЕВОЛЮЦИЯ'
  end

  def test_on_demand_command_never_rolls
    add_rule!
    ctx = OpenStruct.new(cmd: 'бот итоги', chat_id: CHAT)
    cmd = Commands::Wrapped.new(ctx)
    assert cmd.match?
    50.times { cmd.execute }
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size, 'бот итоги must stay read-only'
  end
end

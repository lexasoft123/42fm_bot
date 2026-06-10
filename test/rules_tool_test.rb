require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/agent/scratchpad'
require_relative '../lib/agent/tools/rules'

# Dice-trial mechanics for the rules-war game. The dice API is stubbed —
# what's pinned here is the outcome map (4–6 repeal / 2–3 extend / 1
# critical fail), the no-sleep contract, post-increment surfacing of
# challenges_survived, the rand fallback, and the hourly trial cap.
class RulesToolTest < BotTest
  CHAT = -1234567896

  class FakeDiceApi
    attr_reader :calls
    def initialize(value: nil, fail_send: false)
      @value = value
      @fail_send = fail_send
      @calls = 0
    end

    def send_dice(chat_id:)
      @calls += 1
      raise 'telegram down' if @fail_send
      OpenStruct.new(dice: OpenStruct.new(value: @value))
    end
  end

  def setup
    super
    @user = OpenStruct.new(uid: 100, name: 'kat', first_name: 'Kat', role: 'member')
  end

  def tool(name) = Agent::ToolRegistry.find(name)

  def ctx(api: nil, user: @user)
    { chat_id: CHAT, user: user, api: api }
  end

  def make_rule(set_by: 200, name: '@bob')
    Agent::Scratchpad.add_rule(CHAT, content: 'все говорят стихами',
                               set_by: set_by, set_by_name: name)[:rule]
  end

  # --- set_rule ---

  def test_set_rule_creates_rule_for_ctx_user
    out = tool('set_rule').handler.call({ 'content' => 'без мата по вторникам' }, ctx)
    assert_match(/r-\d{3}/, out)
    rule = Agent::Scratchpad.rules(CHAT).first
    assert_equal 100, rule['set_by']
    assert_equal '@kat', rule['set_by_name']
  end

  def test_set_rule_announces_trade_in
    tool('set_rule').handler.call({ 'content' => 'первое' }, ctx)
    out = tool('set_rule').handler.call({ 'content' => 'второе' }, ctx)
    assert_includes out, 'отозвано'
    assert_includes out, 'первое'
  end

  # --- challenge_rule outcome map ---

  def test_roll_high_repeals_rule
    rule = make_rule
    api = FakeDiceApi.new(value: 5)
    out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: api))
    assert_equal 1, api.calls
    assert_includes out, 'выпало 5'
    assert_includes out, 'отменено'
    assert_empty Agent::Scratchpad.rules(CHAT)
  end

  def test_roll_mid_extends_and_surfaces_post_increment_count
    rule = make_rule
    before = Time.parse(Agent::Scratchpad.find_rule(CHAT, rule['id'])['expires_at'])
    out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: FakeDiceApi.new(value: 2)))
    assert_includes out, 'отклонена'
    assert_includes out, 'выстояло апелляций: 1', 'tool result must carry the POST-increment count'
    after = Time.parse(Agent::Scratchpad.find_rule(CHAT, rule['id'])['expires_at'])
    assert_in_delta before + 6 * 3600, after, 5
  end

  def test_third_survival_suggests_constitution_award
    rule = make_rule
    out = nil
    3.times { out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: FakeDiceApi.new(value: 3))) }
    assert_includes out, 'выстояло апелляций: 3'
    assert_includes out, 'make_award'
  end

  def test_roll_one_is_critical_fail_with_court_rule_instruction
    rule = make_rule
    out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: FakeDiceApi.new(value: 1)))
    assert_includes out, 'КРИТИЧЕСКИЙ ПРОВАЛ'
    assert_includes out, 'court_rule'
    assert_includes out, '@kat' # counter-rule targets the challenger
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size, 'rule survives a critical fail'
  end

  def test_send_dice_failure_falls_back_to_internal_rand_and_says_so
    rule = make_rule
    out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: FakeDiceApi.new(fail_send: true)))
    assert_includes out, 'Кость сломалась'
    assert_match(/выпало [1-6]/, out)
  end

  def test_unknown_rule_does_not_roll
    api = FakeDiceApi.new(value: 6)
    out = tool('challenge_rule').handler.call({ 'id' => 'r-999' }, ctx(api: api))
    assert_includes out, 'не найдено'
    assert_equal 0, api.calls
  end

  def test_hourly_trial_cap_refuses_seventh
    rule = make_rule
    Agent::Scratchpad::CHALLENGE_HOUR_CAP.times { Agent::Scratchpad.register_challenge(CHAT) }
    api = FakeDiceApi.new(value: 6)
    out = tool('challenge_rule').handler.call({ 'id' => rule['id'] }, ctx(api: api))
    assert_includes out, 'перегружен'
    assert_equal 0, api.calls, 'no dice animation past the cap'
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size
  end

  # --- court_rule ---

  def test_court_rule_authored_by_court_keeps_citizen_slot
    tool('set_rule').handler.call({ 'content' => 'гражданское' }, ctx)
    out = tool('court_rule').handler.call({ 'content' => 'заявитель пишет капсом', 'target' => '@kat' }, ctx)
    assert_includes out, 'Судебное правило'
    rules = Agent::Scratchpad.rules(CHAT)
    assert_equal 2, rules.size
    court = rules.find { |r| r['court'] }
    assert_equal 0, court['set_by']
    assert_equal 'суд', court['set_by_name']
  end

  # --- repeal_rule ---

  def test_repeal_by_author_works
    tool('set_rule').handler.call({ 'content' => 'моё правило' }, ctx)
    id = Agent::Scratchpad.rules(CHAT).first['id']
    out = tool('repeal_rule').handler.call({ 'id' => id }, ctx)
    assert_includes out, 'отменено'
    assert_empty Agent::Scratchpad.rules(CHAT)
  end

  def test_repeal_by_stranger_refused_suggests_challenge
    rule = make_rule(set_by: 200, name: '@bob')
    out = tool('repeal_rule').handler.call({ 'id' => rule['id'] }, ctx) # ctx user uid=100
    assert_includes out, 'оспорь'
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size
  end

  def test_admin_can_repeal_court_rule_but_author_target_cannot
    tool('court_rule').handler.call({ 'content' => 'капс запрещён', 'target' => '@kat' }, ctx)
    id = Agent::Scratchpad.rules(CHAT).first['id']
    out = tool('repeal_rule').handler.call({ 'id' => id }, ctx) # member
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size, "member can't repeal court rule: #{out}"
    admin = OpenStruct.new(uid: 1, name: 'boss', role: 'admin')
    tool('repeal_rule').handler.call({ 'id' => id }, ctx(user: admin))
    assert_empty Agent::Scratchpad.rules(CHAT)
  end
end

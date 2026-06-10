require_relative 'test_helper'
require_relative '../lib/agent/scratchpad'

class ScratchpadTest < BotTest
  CHAT = -1234567890

  def test_read_returns_default_shape_for_new_chat
    data = Agent::Scratchpad.read(CHAT)
    assert_equal({ 'intentions' => [], 'notes' => [], 'expectations' => [], 'rules' => [] }, data)
  end

  def test_render_empty_returns_blank_string
    assert_equal '', Agent::Scratchpad.render(CHAT)
  end

  def test_add_returns_id_and_persists
    id = Agent::Scratchpad.add(CHAT, category: 'intentions', content: 'wait for task 680')
    assert_match(/\Asp-\d+\z/, id)

    data = Agent::Scratchpad.read(CHAT)
    assert_equal 1, data['intentions'].size
    assert_equal 'wait for task 680', data['intentions'].first['content']
    assert_equal id, data['intentions'].first['id']
  end

  def test_add_rejects_unknown_category
    assert_raises(ArgumentError) do
      Agent::Scratchpad.add(CHAT, category: 'bogus', content: 'x')
    end
  end

  def test_remove_by_id
    id = Agent::Scratchpad.add(CHAT, category: 'notes', content: 'something')
    assert Agent::Scratchpad.remove(CHAT, id)
    refute Agent::Scratchpad.remove(CHAT, id) # already gone
    assert_empty Agent::Scratchpad.read(CHAT)['notes']
  end

  def test_remove_unknown_id_returns_false
    refute Agent::Scratchpad.remove(CHAT, 'sp-999')
  end

  def test_render_includes_all_non_empty_categories
    Agent::Scratchpad.add(CHAT, category: 'intentions', content: 'plan A')
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'mood: ok')
    rendered = Agent::Scratchpad.render(CHAT)
    assert_includes rendered, 'intentions:'
    assert_includes rendered, 'plan A'
    assert_includes rendered, 'notes:'
    assert_includes rendered, 'mood: ok'
    refute_includes rendered, 'expectations:' # empty category not shown
  end

  def test_eviction_when_over_cap
    big = 'x' * 1000
    20.times { |i| Agent::Scratchpad.add(CHAT, category: 'notes', content: "#{i}-#{big}") }
    data = Agent::Scratchpad.read(CHAT)
    assert_operator data.to_json.bytesize, :<=, Agent::Scratchpad::MAX_CHARS
    # FIFO: oldest evicted, newest survive
    assert_includes data['notes'].last['content'], '19-'
  end

  def test_id_increments
    id1 = Agent::Scratchpad.add(CHAT, category: 'notes', content: 'a')
    id2 = Agent::Scratchpad.add(CHAT, category: 'intentions', content: 'b')
    refute_equal id1, id2
    n1 = id1[/\d+\z/].to_i
    n2 = id2[/\d+\z/].to_i
    assert_operator n2, :>, n1
  end

  def test_isolation_per_chat
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'chat A note')
    other = CHAT + 1
    assert_empty Agent::Scratchpad.read(other)['notes']
    refute_includes Agent::Scratchpad.render(other), 'chat A note'
  end

  def test_corrupt_json_falls_back_to_default_shape
    # Write garbage directly
    ChatState.create!(chat_id: CHAT, scratchpad: 'not-json{{{', updated_at: Time.now)
    data = Agent::Scratchpad.read(CHAT)
    assert_equal({ 'intentions' => [], 'notes' => [], 'expectations' => [], 'rules' => [] }, data)
  end

  def test_add_with_due_at_persists_iso_timestamp
    due = Time.now + 300
    id = Agent::Scratchpad.add(CHAT, category: 'intentions',
                               content: 'retry later', due_at: due)
    entry = Agent::Scratchpad.read(CHAT)['intentions'].first
    assert_equal id, entry['id']
    assert_equal due.utc.iso8601, entry['due_at']
  end

  def test_due_intentions_returns_only_past_due_unacted
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'past', due_at: Time.now - 60)
    Agent::Scratchpad.add(CHAT, category: 'intentions',
                          content: 'future', due_at: Time.now + 600)
    Agent::Scratchpad.add(CHAT, category: 'intentions', content: 'no due')
    due = Agent::Scratchpad.due_intentions(CHAT)
    assert_equal 1, due.size
    assert_equal 'past', due.first['content']
  end

  def test_mark_acted_excludes_from_due_intentions
    id = Agent::Scratchpad.add(CHAT, category: 'intentions',
                               content: 'past', due_at: Time.now - 60)
    assert_equal 1, Agent::Scratchpad.due_intentions(CHAT).size
    Agent::Scratchpad.mark_acted(CHAT, id)
    assert_empty Agent::Scratchpad.due_intentions(CHAT)
  end

  def test_add_prunes_expired_inline
    # expires_at in the past — pruned on next add
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'doomed',
                          expires_at: Time.now - 10)
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'fresh')
    contents = Agent::Scratchpad.read(CHAT)['notes'].map { |e| e['content'] }
    refute_includes contents, 'doomed'
    assert_includes contents, 'fresh'
  end

  # ── Rules-war store ──────────────────────────────────────────────────

  def add_rule(content: 'правило', set_by: 100, name: '@kat', hours: 24, court: false)
    Agent::Scratchpad.add_rule(CHAT, content: content, set_by: set_by,
                               set_by_name: name, hours: hours, court: court)
  end

  def test_add_rule_returns_rule_with_r_id
    res = add_rule
    assert_match(/\Ar-\d{3}\z/, res[:rule]['id'])
    assert_nil res[:repealed]
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size
  end

  def test_generic_add_still_returns_bare_string_id
    # Regression (round-6 finding 5): the deferred-intent writer depends on
    # `add` returning a plain "sp-NNN" string — add_rule is a NEW method.
    id = Agent::Scratchpad.add(CHAT, category: 'intentions', content: 'x')
    assert_instance_of String, id
    assert_match(/\Asp-\d+\z/, id)
  end

  def test_generic_add_rejects_rules_category
    assert_raises(ArgumentError) do
      Agent::Scratchpad.add(CHAT, category: 'rules', content: 'cheat')
    end
  end

  def test_one_rule_per_citizen_repeals_prior_and_returns_it
    first = add_rule(content: 'старое')
    res   = add_rule(content: 'новое')
    assert_equal first[:rule]['id'], res[:repealed]['id']
    rules = Agent::Scratchpad.rules(CHAT)
    assert_equal 1, rules.size
    assert_equal 'новое', rules.first['content']
  end

  def test_rule_ids_never_reused_after_repeal
    first = add_rule(content: 'старое')
    res   = add_rule(content: 'новое')
    refute_equal first[:rule]['id'], res[:rule]['id']
  end

  def test_court_rule_does_not_consume_citizen_slot_and_replaces_prior_court
    citizen = add_rule(content: 'гражданское', set_by: 100)
    court1  = add_rule(content: 'судебное 1', set_by: 0, name: 'суд', court: true)
    assert_nil court1[:repealed], 'court rule must not repeal the citizen rule'
    court2  = add_rule(content: 'судебное 2', set_by: 0, name: 'суд', court: true)
    assert_equal court1[:rule]['id'], court2[:repealed]['id']
    rules = Agent::Scratchpad.rules(CHAT)
    assert_equal 2, rules.size # citizen + one court
    assert_includes rules.map { |r| r['content'] }, 'гражданское'
    assert_includes rules.map { |r| r['content'] }, 'судебное 2'
  end

  def test_max_rules_backstop_evicts_oldest
    (Agent::Scratchpad::MAX_RULES + 1).times do |i|
      add_rule(content: "правило #{i}", set_by: 1000 + i, name: "@u#{i}")
    end
    rules = Agent::Scratchpad.rules(CHAT)
    assert_equal Agent::Scratchpad::MAX_RULES, rules.size
    refute_includes rules.map { |r| r['content'] }, 'правило 0'
  end

  def test_rule_content_truncated
    res = add_rule(content: 'я' * 500)
    assert_equal Agent::Scratchpad::RULE_CONTENT_MAX, res[:rule]['content'].length
  end

  def test_rules_exempt_from_eviction_cap
    rule = add_rule(content: 'неприкосновенное')
    big = 'x' * 1000
    20.times { |i| Agent::Scratchpad.add(CHAT, category: 'notes', content: "#{i}-#{big}") }
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size,
                 'active rule must survive notes-driven eviction'
    assert_equal rule[:rule]['id'], Agent::Scratchpad.rules(CHAT).first['id']
  end

  def test_expired_rule_filtered_at_read_and_render_but_not_deleted
    add_rule(content: 'мертвец', hours: -1)
    assert_empty Agent::Scratchpad.rules(CHAT)
    refute_includes Agent::Scratchpad.render(CHAT), 'мертвец'
    raw = JSON.parse(ChatState.find(CHAT).scratchpad)
    assert_equal 1, raw['rules'].size, 'expired rule must await pop_expired_rules, not vanish'
  end

  def test_generic_add_does_not_prune_expired_rules
    add_rule(content: 'мертвец', hours: -1)
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'триггерим prune')
    raw = JSON.parse(ChatState.find(CHAT).scratchpad)
    assert_equal 1, raw['rules'].size, 'prune_expired must be rules-exempt'
  end

  def test_pop_expired_rules_returns_exactly_once
    add_rule(content: 'мертвец', hours: -1)
    add_rule(content: 'живое', set_by: 200, name: '@bob', hours: 24)
    popped = Agent::Scratchpad.pop_expired_rules(CHAT)
    assert_equal ['мертвец'], popped.map { |r| r['content'] }
    assert_empty Agent::Scratchpad.pop_expired_rules(CHAT)
    assert_equal ['живое'], Agent::Scratchpad.rules(CHAT).map { |r| r['content'] }
  end

  def test_extend_and_survive_increments_and_extends
    res = add_rule(hours: 1)
    before = Time.parse(res[:rule]['expires_at'])
    updated = Agent::Scratchpad.extend_and_survive(CHAT, res[:rule]['id'], hours: 6)
    assert_equal 1, updated['challenges_survived']
    assert_in_delta before + 6 * 3600, Time.parse(updated['expires_at']), 5
    updated = Agent::Scratchpad.extend_and_survive(CHAT, res[:rule]['id'], hours: 6)
    assert_equal 2, updated['challenges_survived']
  end

  def test_clear_rules_wipes_only_rules
    add_rule
    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'останется')
    assert_equal 1, Agent::Scratchpad.clear_rules(CHAT)
    assert_empty Agent::Scratchpad.rules(CHAT)
    assert_equal 1, Agent::Scratchpad.read(CHAT)['notes'].size
  end

  def test_remove_cannot_delete_rules
    res = add_rule
    refute Agent::Scratchpad.remove(CHAT, res[:rule]['id']),
           '`forget` must not bypass the game — rules are repealed via tools'
    assert_equal 1, Agent::Scratchpad.rules(CHAT).size
  end

  def test_repeal_rule_entry_removes_and_returns
    res = add_rule
    removed = Agent::Scratchpad.repeal_rule_entry(CHAT, res[:rule]['id'])
    assert_equal res[:rule]['id'], removed['id']
    assert_empty Agent::Scratchpad.rules(CHAT)
  end

  def test_register_challenge_caps_per_hour_and_prunes
    Agent::Scratchpad::CHALLENGE_HOUR_CAP.times do
      assert Agent::Scratchpad.register_challenge(CHAT)
    end
    refute Agent::Scratchpad.register_challenge(CHAT), '7th trial within the hour must be refused'
    log = JSON.parse(ChatState.find(CHAT).scratchpad)['challenge_log']
    assert_operator log.size, :<=, Agent::Scratchpad::CHALLENGE_HOUR_CAP
  end

  def test_render_shows_active_rules_with_author_and_target
    add_rule(content: 'все говорят стихами', name: '@kat')
    rendered = Agent::Scratchpad.render(CHAT)
    assert_includes rendered, 'rules'
    assert_includes rendered, '@kat→все'
    assert_includes rendered, 'все говорят стихами'
  end

  def test_compact_removes_old_and_expired
    # Old entry — past max_age
    old_id = Agent::Scratchpad.add(CHAT, category: 'notes', content: 'old')
    # Force created_at to 60 days ago
    state = ChatState.find(CHAT)
    data = JSON.parse(state.scratchpad)
    data['notes'].first['created_at'] = (Time.now - 60 * 86400).utc.iso8601
    state.update!(scratchpad: data.to_json)

    Agent::Scratchpad.add(CHAT, category: 'notes', content: 'recent')

    stats = Agent::Scratchpad.compact(CHAT, max_age_days: 30)
    assert_equal 1, stats[:removed]
    assert_equal 1, stats[:kept]

    contents = Agent::Scratchpad.read(CHAT)['notes'].map { |e| e['content'] }
    refute_includes contents, 'old'
    assert_includes contents, 'recent'
  end
end

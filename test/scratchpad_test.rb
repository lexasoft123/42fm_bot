require_relative 'test_helper'
require_relative '../lib/agent/scratchpad'

class ScratchpadTest < BotTest
  CHAT = -1234567890

  def test_read_returns_default_shape_for_new_chat
    data = Agent::Scratchpad.read(CHAT)
    assert_equal({ 'intentions' => [], 'notes' => [], 'expectations' => [] }, data)
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
    assert_equal({ 'intentions' => [], 'notes' => [], 'expectations' => [] }, data)
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

require 'time'

module Agent
  # Per-chat working memory for the agent: intentions, notes, expectations.
  # Distinct from KnowledgeBase (facts about the world) — this is the agent's
  # reflection on its own plans and pending follow-ups.
  #
  # Storage: chat_states.scratchpad as JSON. Permissive layout to start.
  # Hard cap: 6000 characters (~1500 tokens). On overflow, oldest entries are
  # evicted from the largest category.
  module Scratchpad
    MAX_CHARS = 6000

    # 'rules' is the rules-war game store. It is EXEMPT from the FIFO cap
    # eviction and from generic expiry pruning: an active rule must never
    # vanish silently mid-game, and expired rules are removed ONLY via
    # pop_expired_rules (CronScheduler) so each gets its obituary exactly
    # once. Rules are bounded instead by one-rule-per-citizen + MAX_RULES +
    # RULE_CONTENT_MAX + their own expiry.
    CATEGORIES = %w[intentions notes expectations rules].freeze
    EVICTABLE_CATEGORIES = %w[intentions notes expectations].freeze

    MAX_RULES        = 20   # per-chat backstop (one-rule-per-citizen is primary)
    RULE_CONTENT_MAX = 200  # chars — rules render into every agent prompt
    CHALLENGE_HOUR_CAP = 6  # dice trials per chat per hour

    module_function

    # Return parsed Hash for chat. Always {} or {<category> => [..]} shape.
    def read(chat_id)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.where(chat_id: chat_id).first
        parse(row&.scratchpad)
      end
    end

    # Format scratchpad for inclusion in agent prompt. Empty string if nothing
    # to show, otherwise a Markdown-ish block. Caller decides where to splice.
    def render(chat_id)
      data = read(chat_id)
      lines = []
      EVICTABLE_CATEGORIES.each do |cat|
        entries = Array(data[cat])
        next if entries.empty?
        lines << "#{cat}:"
        entries.each { |e| lines << "  - [#{e['id']}] #{e['content']}" }
      end
      # Custom branch for rules: expired rules are filtered AT READ (they
      # await pop_expired_rules for deletion + obituary, but must never be
      # enforced by the agent in the meantime).
      active = active_rules(Array(data['rules']))
      if active.any?
        lines << 'rules (правила игры — соблюдай их):'
        active.each { |r| lines << "  - #{rule_line(r)}" }
      end
      lines.join("\n")
    end

    def rule_line(r)
      author = r['court'] ? 'суд' : (r['set_by_name'] || "uid#{r['set_by']}")
      target = r['target'].to_s.strip.empty? ? 'все' : r['target']
      left   = hours_left(r['expires_at'])
      line = "[#{r['id']}] #{author}→#{target}: #{r['content']} · истекает через #{left}"
      line += " · выстояло апелляций: #{r['challenges_survived']}" if r['challenges_survived'].to_i > 0
      line
    end

    def hours_left(expires_at)
      return '?' unless expires_at
      secs = Time.parse(expires_at) - Time.now.utc
      secs < 3600 ? "#{[(secs / 60).ceil, 1].max}м" : "#{(secs / 3600.0).round}ч"
    rescue ArgumentError
      '?'
    end

    # Add an entry to a category. Returns the new entry's id.
    # `due_at` (optional ISO timestamp) marks when an intention should be
    # revisited — CronScheduler dispatches cron_tick agent_event for entries
    # whose due_at has passed.
    def add(chat_id, category:, content:, expires_at: nil, due_at: nil)
      # 'rules' is deliberately NOT addressable here — the game store is
      # written only via add_rule (one-rule-per-citizen, caps, r- ids).
      raise ArgumentError, "unknown category #{category}" unless EVICTABLE_CATEGORIES.include?(category.to_s)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.find_or_initialize_by(chat_id: chat_id)
        data = parse(row.scratchpad)
        entry = {
          'id' => next_id(data),
          'content' => content.to_s,
          'created_at' => Time.now.utc.iso8601,
        }
        entry['expires_at'] = expires_at.is_a?(Time) ? expires_at.utc.iso8601 : expires_at if expires_at
        entry['due_at']     = due_at.is_a?(Time)     ? due_at.utc.iso8601     : due_at     if due_at
        data[category.to_s] ||= []
        data[category.to_s] << entry
        prune_expired(data)
        evict_until_under_cap(data)
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        entry['id']
      end
    end

    # Remove an entry by id from any evictable category. Returns true if
    # removed. Rules are NOT removable here (the `forget` tool must not
    # bypass the game) — use repeal_rule_entry / pop_expired_rules.
    def remove(chat_id, id)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.where(chat_id: chat_id).first
        return false unless row
        data = parse(row.scratchpad)
        removed = false
        EVICTABLE_CATEGORIES.each do |cat|
          before = Array(data[cat]).size
          data[cat] = Array(data[cat]).reject { |e| e['id'] == id }
          removed ||= data[cat].size < before
        end
        return false unless removed
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        true
      end
    end

    # Mutates data in place. Removes entries whose expires_at has passed.
    # Rules are exempt: their expiry deletion happens ONLY in
    # pop_expired_rules so the obituary path sees each expired rule once.
    def prune_expired(data)
      now = Time.now.utc.iso8601
      EVICTABLE_CATEGORIES.each do |cat|
        Array(data[cat]).reject! { |e| e['expires_at'] && e['expires_at'] <= now }
      end
    end

    # Compact a chat's scratchpad: drop expired entries and entries older than
    # max_age_days. Returns a stats hash. Pure-Ruby; no LLM calls.
    def compact(chat_id, max_age_days: 30)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.where(chat_id: chat_id).first
        return { removed: 0, kept: 0 } unless row
        data = parse(row.scratchpad)
        before = EVICTABLE_CATEGORIES.sum { |cat| Array(data[cat]).size }
        prune_expired(data)
        cutoff = (Time.now.utc - max_age_days * 86400).iso8601
        EVICTABLE_CATEGORIES.each do |cat|
          Array(data[cat]).reject! { |e| e['created_at'] && e['created_at'] < cutoff }
        end
        after = EVICTABLE_CATEGORIES.sum { |cat| Array(data[cat]).size }
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        { removed: before - after, kept: after }
      end
    end

    # Find intentions whose due_at has passed and which haven't been acted on
    # yet (no `acted` flag). Used by CronScheduler.
    def due_intentions(chat_id)
      data = read(chat_id)
      now = Time.now.utc.iso8601
      Array(data['intentions']).select { |e| e['due_at'] && e['due_at'] <= now && !e['acted'] }
    end

    # Mark an intention as acted-on so CronScheduler doesn't re-dispatch it.
    def mark_acted(chat_id, ids)
      ids = Array(ids).map(&:to_s)
      return 0 if ids.empty?
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.where(chat_id: chat_id).first
        return 0 unless row
        data = parse(row.scratchpad)
        marked = 0
        Array(data['intentions']).each do |e|
          if ids.include?(e['id'])
            e['acted'] = true
            marked += 1
          end
        end
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        marked
      end
    end

    def parse(json)
      return default_shape if json.nil? || json.to_s.strip.empty?
      h = JSON.parse(json)
      default_shape.merge(h)
    rescue JSON::ParserError
      default_shape
    end

    def default_shape
      CATEGORIES.each_with_object({}) { |cat, h| h[cat] = [] }
    end

    def next_id(data)
      ids = EVICTABLE_CATEGORIES.flat_map { |cat| Array(data[cat]).map { |e| e['id'].to_s } }
      n = ids.map { |s| s[/\d+$/].to_i }.max.to_i + 1
      "sp-#{n.to_s.rjust(3, '0')}"
    end

    # Evict oldest entries from largest category until JSON fits MAX_CHARS.
    # Loop bounded by total entry count to avoid pathological loops.
    # Rules are exempt — an active rule must never vanish silently mid-game.
    def evict_until_under_cap(data)
      total = EVICTABLE_CATEGORIES.sum { |cat| Array(data[cat]).size }
      total.times do
        break if data.to_json.bytesize <= MAX_CHARS
        biggest = EVICTABLE_CATEGORIES.max_by { |cat| Array(data[cat]).size }
        next if Array(data[biggest]).empty?
        data[biggest].shift # FIFO eviction — oldest first
      end
    end

    # ── Rules-war game store ────────────────────────────────────────────
    # Entry shape: { id: 'r-NNN', content:, set_by: <uid>, set_by_name:,
    #   target: <display or nil=all>, created_at:, expires_at:,
    #   challenges_survived: 0, court: true? }

    # Returns { rule:, repealed:, evicted: } — `repealed` is the same
    # author's previous rule replaced under one-rule-per-citizen (or the
    # previous court rule when court: true); `evicted` is the oldest rule
    # dropped by the MAX_RULES backstop. NEW method: the generic `add`
    # keeps its bare-string-id contract (deferred-intent writer depends
    # on it).
    def add_rule(chat_id, content:, set_by:, set_by_name: nil, target: nil, hours: 24, court: false)
      mutate(chat_id) do |data|
        rules = (data['rules'] ||= [])
        new_id = next_rule_id(data) # before deletions — never reuse an id
        prior = court ? rules.find { |r| r['court'] } :
                        rules.find { |r| r['set_by'] == set_by && !r['court'] }
        rules.delete(prior) if prior
        evicted = nil
        evicted = rules.shift if active_rules(rules).size >= MAX_RULES
        rule = {
          'id'                  => new_id,
          'content'             => content.to_s.strip[0, RULE_CONTENT_MAX],
          'set_by'              => set_by,
          'set_by_name'         => set_by_name,
          'target'              => target,
          'created_at'          => Time.now.utc.iso8601,
          'expires_at'          => (Time.now.utc + hours.to_f * 3600).iso8601,
          'challenges_survived' => 0,
        }
        rule['court'] = true if court
        rules << rule
        { rule: rule, repealed: prior, evicted: evicted }
      end
    end

    # Active (non-expired) rules, read-only. Expired ones linger until
    # pop_expired_rules collects them for obituaries.
    def rules(chat_id)
      active_rules(Array(read(chat_id)['rules']))
    end

    def find_rule(chat_id, id)
      rules(chat_id).find { |r| r['id'] == id.to_s }
    end

    # Remove a rule by id (repeal / dice-trial win). Returns the removed
    # rule Hash or nil.
    def repeal_rule_entry(chat_id, id)
      mutate(chat_id) do |data|
        rules = Array(data['rules'])
        rule = rules.find { |r| r['id'] == id.to_s }
        data['rules'] = rules.reject { |r| r['id'] == id.to_s }
        rule
      end
    end

    # Survived a challenge: extend expiry and bump the survival counter.
    # Returns the updated rule (post-increment) or nil.
    def extend_and_survive(chat_id, id, hours: 6)
      mutate(chat_id) do |data|
        rule = Array(data['rules']).find { |r| r['id'] == id.to_s }
        next nil unless rule
        begin
          rule['expires_at'] = (Time.parse(rule['expires_at']) + hours * 3600).utc.iso8601
        rescue ArgumentError, TypeError
          # Corrupt/missing timestamp: keep the old value — nil-ing it out
          # would make the rule immortal (nil expires_at = never expires).
        end
        rule['challenges_survived'] = rule['challenges_survived'].to_i + 1
        rule
      end
    end

    # THE only expiry-deletion path for rules: atomically removes and
    # returns just-expired rules so CronScheduler can announce each exactly
    # once.
    def pop_expired_rules(chat_id)
      mutate(chat_id) do |data|
        now = Time.now.utc.iso8601
        rules = Array(data['rules'])
        expired, alive = rules.partition { |r| r['expires_at'] && r['expires_at'] <= now }
        data['rules'] = alive
        expired
      end
    end

    # F7 «Революция». Returns the number of rules wiped.
    def clear_rules(chat_id)
      mutate(chat_id) do |data|
        n = Array(data['rules']).size
        data['rules'] = []
        n
      end
    end

    # Dice-trial throttle: top-level `challenge_log` of ISO timestamps,
    # pruned to the trailing hour on every write so it never grows past
    # ~CHALLENGE_HOUR_CAP entries. Returns true if the trial may proceed
    # (and records it), false when the hourly cap is hit.
    def register_challenge(chat_id)
      mutate(chat_id) do |data|
        cutoff = (Time.now.utc - 3600).iso8601
        log = Array(data['challenge_log']).select { |t| t.to_s > cutoff }
        if log.size >= CHALLENGE_HOUR_CAP
          data['challenge_log'] = log
          next false
        end
        data['challenge_log'] = log << Time.now.utc.iso8601
        true
      end
    end

    def active_rules(rules)
      now = Time.now.utc.iso8601
      Array(rules).reject { |r| r['expires_at'] && r['expires_at'] <= now }
    end

    def next_rule_id(data)
      n = Array(data['rules']).map { |r| r['id'].to_s[/\d+$/].to_i }.max.to_i + 1
      "r-#{n.to_s.rjust(3, '0')}"
    end

    # Shared read-modify-write for the rules/challenge_log paths. The block
    # mutates `data` and its return value is passed through.
    def mutate(chat_id)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.find_or_initialize_by(chat_id: chat_id)
        data = parse(row.scratchpad)
        result = yield(data)
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        result
      end
    end
  end
end

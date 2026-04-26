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

    CATEGORIES = %w[intentions notes expectations].freeze

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
      return '' if data.values.flatten.compact.empty?
      lines = []
      CATEGORIES.each do |cat|
        entries = Array(data[cat])
        next if entries.empty?
        lines << "#{cat}:"
        entries.each { |e| lines << "  - [#{e['id']}] #{e['content']}" }
      end
      lines.join("\n")
    end

    # Add an entry to a category. Returns the new entry's id.
    def add(chat_id, category:, content:, expires_at: nil)
      raise ArgumentError, "unknown category #{category}" unless CATEGORIES.include?(category.to_s)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.find_or_initialize_by(chat_id: chat_id)
        data = parse(row.scratchpad)
        entry = {
          'id' => next_id(data),
          'content' => content.to_s,
          'created_at' => Time.now.utc.iso8601,
        }
        entry['expires_at'] = expires_at if expires_at
        data[category.to_s] ||= []
        data[category.to_s] << entry
        evict_until_under_cap(data)
        row.scratchpad = data.to_json
        row.updated_at = Time.now
        row.save!
        entry['id']
      end
    end

    # Remove an entry by id from any category. Returns true if removed.
    def remove(chat_id, id)
      ActiveRecord::Base.connection_pool.with_connection do
        row = ChatState.where(chat_id: chat_id).first
        return false unless row
        data = parse(row.scratchpad)
        removed = false
        CATEGORIES.each do |cat|
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
      ids = CATEGORIES.flat_map { |cat| Array(data[cat]).map { |e| e['id'].to_s } }
      n = ids.map { |s| s[/\d+$/].to_i }.max.to_i + 1
      "sp-#{n.to_s.rjust(3, '0')}"
    end

    # Evict oldest entries from largest category until JSON fits MAX_CHARS.
    # Loop bounded by total entry count to avoid pathological loops.
    def evict_until_under_cap(data)
      total = CATEGORIES.sum { |cat| Array(data[cat]).size }
      total.times do
        break if data.to_json.bytesize <= MAX_CHARS
        biggest = CATEGORIES.max_by { |cat| Array(data[cat]).size }
        next if Array(data[biggest]).empty?
        data[biggest].shift # FIFO eviction — oldest first
      end
    end
  end
end

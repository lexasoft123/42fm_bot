module AdminMenu
  module Session
    AWAITING_TTL_SECONDS = 5 * 60

    @mu = Mutex.new
    @state = {}

    def self.for(uid)
      @mu.synchronize { (@state[uid] ||= {}).dup }
    end

    def self.set(uid, **kv)
      @mu.synchronize { (@state[uid] ||= {}).merge!(kv) }
    end

    def self.clear(uid)
      @mu.synchronize { @state.delete(uid) }
    end

    def self.clear_awaiting_input(uid)
      @mu.synchronize do
        @state[uid]&.delete(:awaiting_input)
        @state[uid]&.delete(:awaiting_set_at)
      end
    end

    def self.awaiting_input?(uid)
      @mu.synchronize do
        s = @state[uid]
        return false unless s && s[:awaiting_input]
        if s[:awaiting_set_at] && Time.now - s[:awaiting_set_at] > AWAITING_TTL_SECONDS
          s.delete(:awaiting_input)
          s.delete(:awaiting_set_at)
          return false
        end
        true
      end
    end

    def self.awaiting_input(uid)
      @mu.synchronize { @state[uid]&.dig(:awaiting_input)&.dup }
    end

    def self.set_awaiting_input(uid, payload)
      @mu.synchronize do
        s = (@state[uid] ||= {})
        s[:awaiting_input] = payload
        s[:awaiting_set_at] = Time.now
      end
    end

    def self.reset_for_test!
      @mu.synchronize { @state.clear }
    end
  end
end

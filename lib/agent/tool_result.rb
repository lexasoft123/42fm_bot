module Agent
  # Structured tool result. Tools may return a plain String (passed through
  # as-is) OR an Agent::ToolResult to signal richer outcomes — currently
  # "deferred", meaning the action couldn't be performed now but the agent
  # should remember it for later.
  #
  # Agent::Runner unpacks ToolResult and:
  #   - For :deferred — auto-writes the intent to chat scratchpad (no extra
  #     LLM round-trip; the tool already knows what it deferred), then
  #     forwards a structured prefix to the LLM so the agent sees the user
  #     text along with the persistence acknowledgment.
  class ToolResult
    attr_reader :user_text, :deferred_intent, :retry_in_min

    def self.text(str)
      new(user_text: str.to_s)
    end

    def self.deferred(user_text:, intent:, retry_in_min: nil)
      new(user_text: user_text.to_s, deferred_intent: intent.to_s, retry_in_min: retry_in_min)
    end

    def initialize(user_text:, deferred_intent: nil, retry_in_min: nil)
      @user_text = user_text
      @deferred_intent = deferred_intent
      @retry_in_min = retry_in_min
    end

    def deferred?
      !@deferred_intent.nil? && !@deferred_intent.empty?
    end
  end
end

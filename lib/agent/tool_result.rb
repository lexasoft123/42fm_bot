module Agent
  # Structured tool result. Tools may return a plain String (passed through
  # as-is) OR an Agent::ToolResult to signal richer outcomes:
  #   - "deferred" — the action couldn't be performed now but the agent
  #     should remember it for later.
  #   - "image" — the tool fetched an image the model should actually SEE
  #     (not just read about), e.g. view_image pulling a photo from history.
  #
  # Agent::Runner unpacks ToolResult and:
  #   - For :image — queues the payload for injection into the conversation
  #     as a vision block after this iteration's tool results (the
  #     tool_result message itself can only carry text).
  #   - For :deferred — auto-writes the intent to chat scratchpad (no extra
  #     LLM round-trip; the tool already knows what it deferred), then
  #     forwards a structured prefix to the LLM so the agent sees the user
  #     text along with the persistence acknowledgment.
  # The two variants are mutually exclusive by construction.
  class ToolResult
    attr_reader :user_text, :deferred_intent, :retry_in_min, :image

    def self.text(str)
      new(user_text: str.to_s)
    end

    def self.deferred(user_text:, intent:, retry_in_min: nil)
      new(user_text: user_text.to_s, deferred_intent: intent.to_s, retry_in_min: retry_in_min)
    end

    # image: { data: <base64>, media_type: 'image/jpeg' } — the same shape
    # Agent::Runner#build_initial_messages uses for current-message vision.
    def self.image(user_text:, image:)
      new(user_text: user_text.to_s, image: image)
    end

    def initialize(user_text:, deferred_intent: nil, retry_in_min: nil, image: nil)
      @user_text = user_text
      @deferred_intent = deferred_intent
      @retry_in_min = retry_in_min
      @image = image
    end

    def deferred?
      !@deferred_intent.nil? && !@deferred_intent.empty?
    end

    def image?
      !@image.nil?
    end
  end
end

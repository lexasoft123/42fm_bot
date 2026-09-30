module Agent
  # Structured tool result. Tools may return a plain String (passed through
  # as-is) OR an Agent::ToolResult to signal richer outcomes:
  #   - "deferred" — the action couldn't be performed now but the agent
  #     should remember it for later.
  #   - "image" — the tool fetched an image the model should actually SEE
  #     (not just read about), e.g. view_image pulling a photo from history.
  #   - "action" — an authoritative queued/sent/failed/deferred action state
  #     with optional task id and sent count.
  #
  # Agent::Runner unpacks ToolResult and:
  #   - For :image — queues the payload for injection into the conversation
  #     as a vision block after this iteration's tool results (the
  #     tool_result message itself can only carry text).
  #   - For :deferred — auto-writes the intent to chat scratchpad (no extra
  #     LLM round-trip; the tool already knows what it deferred), then
  #     forwards a structured prefix to the LLM so the agent sees the user
  #     text along with the persistence acknowledgment.
  # The variants are mutually exclusive by construction.
  class ToolResult
    ACTION_STATUSES = %w[queued sent failed deferred].freeze
    ACTION_PHASES = %w[queued processing retrying delivering persisting_delivery completed failed deferred].freeze
    ACTION_DELIVERIES = %w[pending delivered failed unknown].freeze
    ITEM_STATUSES = %w[pending done failed queued sent deferred].freeze

    attr_reader :user_text, :deferred_intent, :retry_in_min, :image,
                :action_status, :action, :task_id, :task_type, :sent_count, :phase, :delivery,
                :items

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

    # Machine-readable outcome for tools that start or complete an external
    # action. `user_text` is the only prose the model may repeat to the user;
    # the remaining fields are authoritative state, not narrative hints.
    def self.action(status:, action:, user_text:, task_id: nil, task_type: nil,
                    sent_count: nil, phase: nil, delivery: nil, items: nil)
      status = status.to_s
      raise ArgumentError, "invalid action status: #{status}" unless ACTION_STATUSES.include?(status)
      action = action.to_s
      raise ArgumentError, "invalid action: #{action}" unless action.match?(/\A[a-z0-9_]{1,64}\z/)
      phase = phase.to_s unless phase.nil?
      raise ArgumentError, "invalid action phase: #{phase}" if phase && !ACTION_PHASES.include?(phase)
      delivery = delivery.to_s unless delivery.nil?
      if delivery && !ACTION_DELIVERIES.include?(delivery)
        raise ArgumentError, "invalid action delivery: #{delivery}"
      end
      unless task_id.nil? || (task_id.is_a?(Integer) && task_id.positive?)
        raise ArgumentError, 'action task_id must be positive'
      end
      unless sent_count.nil? || (sent_count.is_a?(Integer) && sent_count >= 0)
        raise ArgumentError, 'action sent_count must be non-negative'
      end
      task_type = validate_task_type(task_type)
      items = validate_items(items)

      new(user_text: user_text.to_s, action_status: status, action: action,
          task_id: task_id, task_type: task_type, sent_count: sent_count, phase: phase,
          delivery: delivery, items: items)
    end

    def self.validate_task_type(value)
      return if value.nil?
      type = value.to_s
      raise ArgumentError, "invalid task type: #{type}" unless type.match?(/\A[a-z0-9_]{1,64}\z/)
      type
    end

    def self.validate_items(items)
      return if items.nil?
      raise ArgumentError, 'action items must be an array' unless items.is_a?(Array)

      items.map do |raw|
        raise ArgumentError, 'action item must be a hash' unless raw.is_a?(Hash)
        item = raw.transform_keys(&:to_sym)
        id = item[:task_id]
        raise ArgumentError, 'action item task_id must be positive' unless id.is_a?(Integer) && id.positive?
        action = item[:action].to_s
        raise ArgumentError, "invalid item action: #{action}" unless action.match?(/\A[a-z0-9_]{1,64}\z/)
        type = validate_task_type(item[:task_type])
        raise ArgumentError, 'action item task_type is required' unless type
        status = item[:status].to_s
        raise ArgumentError, "invalid item status: #{status}" unless ITEM_STATUSES.include?(status)
        phase = item[:phase]&.to_s
        raise ArgumentError, "invalid item phase: #{phase}" if phase && !ACTION_PHASES.include?(phase)
        delivery = item[:delivery]&.to_s
        if delivery && !ACTION_DELIVERIES.include?(delivery)
          raise ArgumentError, "invalid item delivery: #{delivery}"
        end
        { action: action, task_id: id, task_type: type, status: status,
          phase: phase, delivery: delivery }.compact
      end.freeze
    end

    def initialize(user_text:, deferred_intent: nil, retry_in_min: nil, image: nil,
                   action_status: nil, action: nil, task_id: nil, sent_count: nil, phase: nil,
                   delivery: nil, task_type: nil, items: nil)
      @user_text = user_text
      @deferred_intent = deferred_intent
      @retry_in_min = retry_in_min
      @image = image
      @action_status = action_status
      @action = action
      @task_id = task_id
      @task_type = task_type
      @sent_count = sent_count
      @phase = phase
      @delivery = delivery
      @items = items
    end

    def deferred?
      !@deferred_intent.nil? && !@deferred_intent.empty?
    end

    def image?
      !@image.nil?
    end

    def action?
      !@action_status.nil?
    end

    def action_payload
      return unless action?

      {
        status: @action_status,
        action: @action,
        task_id: @task_id,
        task_type: @task_type,
        sent_count: @sent_count,
        phase: @phase,
        delivery: @delivery,
        items: @items,
        message: @user_text,
      }.compact
    end
  end
end

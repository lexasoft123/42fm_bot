class BackgroundTask < ActiveRecord::Base
  LIFECYCLE_PHASES = %w[queued processing retrying delivering persisting_delivery completed failed].freeze
  DELIVERY_STATUSES = %w[unknown pending delivered failed].freeze

  scope :pending, -> { where(status: 'pending') }

  def params_hash
    @params_hash ||= JSON.parse(params || '{}')
  end

  def result_hash
    @result_hash ||= JSON.parse(result || '{}')
  end

  def mark_done!(result_data = nil, delivery_status: nil, **result_keywords)
    result_data = result_keywords if result_data.nil?
    result_data = result_data.merge(result_keywords) if result_data.is_a?(Hash) && !result_keywords.empty?
    result_data ||= {}
    delivery_status ||= self.delivery_status == 'delivered' ? 'delivered' : 'unknown'
    attrs = {
      status: 'done', lifecycle_phase: 'completed',
      delivery_status: normalized_delivery(delivery_status), result: result_data.to_json
    }
    update!(attrs)
  end

  def mark_failed!(reason = nil, delivery_status: nil)
    delivery_status ||= self.delivery_status == 'delivered' ? 'delivered' : 'unknown'
    attrs = {
      status: 'failed', lifecycle_phase: 'failed',
      delivery_status: normalized_delivery(delivery_status), result: { error: reason }.to_json
    }
    update!(attrs)
  end

  def increment_attempts!
    update!(attempts: attempts + 1)
  end

  def mark_processing!(delivery_status: nil)
    update_lifecycle!('processing', delivery_status: delivery_status)
  end

  def mark_delivering!
    update_lifecycle!('delivering', delivery_status: 'pending')
  end

  def mark_persisting_delivery!
    update_lifecycle!('persisting_delivery', delivery_status: 'delivered')
  end

  def mark_retrying!(delivery_status: nil, **attributes)
    attributes[:lifecycle_phase] = 'retrying'
    attributes[:retry_count] = retry_count.to_i + 1
    attributes[:delivery_status] = normalized_delivery(delivery_status) if delivery_status
    update!(attributes)
  end

  def update_lifecycle!(phase, delivery_status: nil, **attributes)
    phase = phase.to_s
    raise ArgumentError, "invalid lifecycle phase: #{phase}" unless LIFECYCLE_PHASES.include?(phase)

    attributes[:lifecycle_phase] = phase
    attributes[:delivery_status] = normalized_delivery(delivery_status) if delivery_status
    update!(attributes)
  end

  def timed_out?
    attempts >= max_attempts
  end

  private

  def normalized_delivery(value)
    value = value.to_s
    raise ArgumentError, "invalid delivery status: #{value}" unless DELIVERY_STATUSES.include?(value)
    value
  end
end

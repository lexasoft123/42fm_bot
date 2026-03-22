class BackgroundTask < ActiveRecord::Base
  scope :pending, -> { where(status: 'pending') }

  def params_hash
    @params_hash ||= JSON.parse(params || '{}')
  end

  def result_hash
    @result_hash ||= JSON.parse(result || '{}')
  end

  def mark_done!(result_data = {})
    update!(status: 'done', result: result_data.to_json)
  end

  def mark_failed!(reason = nil)
    update!(status: 'failed', result: { error: reason }.to_json)
  end

  def increment_attempts!
    update!(attempts: attempts + 1)
  end

  def timed_out?
    attempts >= max_attempts
  end
end

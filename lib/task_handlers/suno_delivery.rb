require 'json'

# Durable boundary between a paid Suno result, Telegram acceptance and local
# Message persistence.  Handlers store the provider payload before sending,
# then store only compact Telegram receipts immediately after acceptance.  A
# later TaskRunner cycle reconciles those receipts without sending again.
module SunoDelivery
  MAX_DELIVERY_FAILURES = 3
  MAX_PERSISTENCE_FAILURES = 3
  URL_SUBSTRING_RE = %r{https?://[^\s\"'<>]+}i

  private

  def suno_delivery_result(task)
    task.params_hash['delivery_result']
  end

  def suno_delivery_receipt(task)
    task.params_hash['delivery_receipt']
  end

  def cache_suno_delivery_result(task, value)
    params = task.params_hash
    params['delivery_result'] = json_safe(value)
    ActiveRecord::Base.connection_pool.with_connection do
      # Provider polling and delivery have independent budgets. TaskRunner
      # increments attempts after this :pending return, so reset here to give
      # the bounded delivery/persistence phases their full max_attempts window.
      task.update_lifecycle!('delivering', params: params.to_json,
                             delivery_status: 'pending', attempts: 0)
    end
    :pending
  end

  def cache_suno_delivery_receipt(task, messages)
    forum_thread_id = task.params_hash['forum_thread_id']
    receipts = Array(messages).map do |message|
      telegram_receipt(message, forum_thread_id: forum_thread_id)
    end
    return false if receipts.empty? || receipts.any?(&:nil?)

    params = task.params_hash
    params['delivery_receipt'] = receipts
    # URLs are needed only until Telegram accepts the upload. Do not retain
    # provider/CDN links in completed or persistence-retry state.
    params['delivery_result'] = redact_urls(params['delivery_result'])
    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(params: params.to_json, lifecycle_phase: 'persisting_delivery',
                   delivery_status: 'delivered')
    end
    true
  end

  def telegram_messages(response, expected_count:)
    messages = response.is_a?(Hash) && (response.key?('result') || response.key?(:result)) ?
      (response['result'] || response[:result]) : response
    messages = [messages] unless messages.is_a?(Array)
    return unless messages.size == expected_count
    return unless messages.all? { |message| telegram_message_id(message) }
    messages
  end

  def telegram_message_id(message)
    value = if message.respond_to?(:message_id)
      message.message_id
    elsif message.is_a?(Hash)
      message['message_id'] || message[:message_id]
    end
    value if value.is_a?(Integer) && value.positive?
  end

  def telegram_receipt(message, forum_thread_id: nil)
    id = telegram_message_id(message)
    return unless id
    thread_id = if message.respond_to?(:message_thread_id)
      message.message_thread_id
    elsif message.is_a?(Hash)
      message['message_thread_id'] || message[:message_thread_id]
    end
    thread_id ||= forum_thread_id if forum_thread_id.is_a?(Integer) && forum_thread_id.positive?
    receipt = { 'message_id' => id, 'message_thread_id' => thread_id }.compact
    photo = telegram_photo_sizes(message)
    receipt['photo'] = photo unless photo.empty?
    receipt
  end

  def receipt_response(receipt)
    { 'message_id' => receipt['message_id'],
      'message_thread_id' => receipt['message_thread_id'],
      'photo' => receipt['photo'] }.compact
  end

  def forum_send_params(params)
    id = params['forum_thread_id']
    id.is_a?(Integer) && id.positive? ? { message_thread_id: id } : {}
  end

  def retry_suno_delivery(task, counter, delivery_status: 'pending')
    params = task.params_hash
    params[counter] = params.fetch(counter, 0).to_i + 1
    cap = counter.end_with?('persistence_failures') ? MAX_PERSISTENCE_FAILURES : MAX_DELIVERY_FAILURES
    return false if params[counter] >= cap
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_retrying!(params: params.to_json, delivery_status: delivery_status)
    end
    true
  end

  def json_safe(value)
    JSON.parse(JSON.generate(value))
  end

  def redact_urls(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), redacted|
        next if key.to_s.match?(/url/i)
        redacted[key] = redact_urls(nested)
      end
    when Array
      value.map { |v| redact_urls(v) }
    when String
      value.gsub(URL_SUBSTRING_RE, '<url-redacted>')
    else value
    end
  end

  def telegram_photo_sizes(message)
    photos = if message.respond_to?(:photo)
      message.photo
    elsif message.is_a?(Hash)
      message['photo'] || message[:photo]
    end
    Array(photos).filter_map do |photo|
      file_id = if photo.respond_to?(:file_id)
        photo.file_id
      elsif photo.is_a?(Hash)
        photo['file_id'] || photo[:file_id]
      end
      next if file_id.to_s.empty?
      width = if photo.respond_to?(:width)
        photo.width
      elsif photo.is_a?(Hash)
        photo['width'] || photo[:width]
      end
      { 'file_id' => file_id, 'width' => width }.compact
    end
  end

  def safe_suno_detail(value)
    Agent::ErrorReporter.sanitize(value)
  end

  def scrub_terminal_delivery_result!(task)
    params = task.params_hash
    return unless params.key?('delivery_result')
    params['delivery_result'] = redact_urls(params['delivery_result'])
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: params.to_json) }
  end
end

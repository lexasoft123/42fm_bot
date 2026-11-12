require_relative 'image_failure_notice'
require_relative 'task_delivery_errors'

class FailureNoticeHandler
  DeliveryError = Class.new(StandardError)

  def call(task, api)
    p = task.params_hash
    text = if p['event_type'] || p['failure_stage'] || p['failure_reason']
      ImageFailureNotice.render(
        event_type: p['event_type'] || 'image_failed',
        parent_task_id: p['parent_task_id'] || task.parent_task_id,
        stage: p['failure_stage'],
        reason: p['failure_reason']
      )
    else
      p['text'].to_s
    end
    forum_thread_id = p['forum_thread_id']
    receipt = p['delivery_receipt']

    unless receipt.is_a?(Hash)
      send_params = { chat_id: task.chat_id, text: text }
      send_params[:message_thread_id] = forum_thread_id if forum_thread_id
      response = begin
        api.sendMessage(**send_params)
      rescue => e
        raise DeliveryError, "failure notice send failed: #{Agent::ErrorReporter.sanitize(e.message)}"
      end
      receipt = serialize_receipt(response, forum_thread_id)
      raise DeliveryError, 'Telegram did not acknowledge failure notice' unless valid_message_id?(receipt['message_id'])

      p['delivery_receipt'] = receipt
      ActiveRecord::Base.connection_pool.with_connection do
        task.update!(params: p.to_json, lifecycle_phase: 'persisting_delivery',
                     delivery_status: 'delivered')
      end
    end

    persisted = Message.find_by(chat_id: task.chat_id, role: 'bot',
                                message_id: receipt['message_id']) ||
      Message.persist_bot_reply(chat_id: task.chat_id, body: text,
                                response: { 'result' => receipt },
                                message_thread_id: forum_thread_id)
    raise DeliveryError, 'failure notice receipt was not persisted' unless persisted

    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_done!({ replied: true, parent_task_id: p['parent_task_id'] },
                      delivery_status: 'delivered')
    end
    :done
  rescue DeliveryError, ActiveRecord::ActiveRecordError => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: delivery pending: " \
                "#{Agent::ErrorReporter.sanitize(e.message)}"
    definitive_rejection = TaskDeliveryErrors.definitive_telegram_rejection?(e)
    params = task.params_hash
    params['delivery_ambiguous'] = true unless definitive_rejection || params['delivery_receipt']
    if definitive_rejection || task.attempts + 1 >= task.max_attempts
      delivery_status = if params['delivery_receipt']
        'delivered'
      elsif params['delivery_ambiguous']
        'unknown'
      else
        TaskDeliveryErrors.terminal_delivery_status(e)
      end
      ActiveRecord::Base.connection_pool.with_connection do
        task.update!(attempts: task.attempts + 1, params: params.to_json)
        task.mark_failed!(Agent::ErrorReporter.sanitize(e.message), delivery_status: delivery_status)
      end
      return :failed
    end
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_retrying!(params: params.to_json,
                          delivery_status: params['delivery_receipt'] ? 'delivered' : 'unknown')
    end
    :pending
  end

  private

  def valid_message_id?(message_id)
    message_id.is_a?(Integer) && message_id.positive?
  end

  def serialize_receipt(response, forum_thread_id)
    raw = response.is_a?(Hash) ? (response['result'] || response[:result] || response) : response
    message_id = raw.respond_to?(:message_id) ? raw.message_id :
      (raw.is_a?(Hash) ? (raw['message_id'] || raw[:message_id]) : nil)
    thread_id = raw.respond_to?(:message_thread_id) ? raw.message_thread_id :
      (raw.is_a?(Hash) ? (raw['message_thread_id'] || raw[:message_thread_id]) : nil)
    { 'message_id' => message_id, 'message_thread_id' => thread_id || forum_thread_id }.compact
  end
end

TaskRunner.register('failure_notice', FailureNoticeHandler)

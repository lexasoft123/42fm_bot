class FailureNoticeHandler
  DeliveryError = Class.new(StandardError)

  def call(task, api)
    p = task.params_hash
    text = p['text'].to_s
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
    if task.attempts + 1 >= task.max_attempts
      delivery_status = task.params_hash['delivery_receipt'] ? 'delivered' : 'failed'
      ActiveRecord::Base.connection_pool.with_connection do
        task.update!(attempts: task.attempts + 1)
        task.mark_failed!(Agent::ErrorReporter.sanitize(e.message), delivery_status: delivery_status)
      end
      return :failed
    end
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_retrying!(delivery_status: task.params_hash['delivery_receipt'] ? 'delivered' : 'unknown')
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

require_relative 'agent_event_emitter'
require_relative 'suno_delivery'
require_relative '../media_download'

class SunoCoverArtHandler
  include AgentEventEmitter
  include MediaDownload
  include SunoDelivery

  MAX_SUBMIT_FAILURES = 3
  MAX_GENERATION_RETRIES = 3

  def call(task, api)
    if suno_delivery_receipt(task)
      persist_images_receipt(task)
    elsif suno_delivery_result(task)
      deliver_cached_images(task, api)
    elsif task.external_id.nil?
      submit(task, api)
    else
      poll_and_deliver(task, api)
    end
  end

  private

  def submit(task, api)
    p = task.params_hash
    source_task_id = p['source_task_id'].to_s
    if source_task_id.empty?
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: missing source_task_id in params"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('missing_source') }
      return :failed
    end

    begin
      cover_task_id = SunoClient.new.cover_art(suno_task_id: source_task_id)
    rescue => e
      # Permanent Suno rejection: fail now with the detail rather than
      # re-raising into TaskRunner's raw "Ошибка: …" (no agent_event).
      if TaskRunner.permanent_error?(e)
        mark_failed_and_notify(task, api, 'cover_art_submit_rejected', error_detail: e.message)
        return :failed
      end
      attempts = (p['submit_failures'] || 0) + 1
      p['submit_failures'] = attempts
      if attempts >= MAX_SUBMIT_FAILURES
        ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{safe_suno_detail(e.message)}"
        mark_failed_and_notify(task, api, 'cover_art_submit_failed_after_retries')
        return :failed
      end
      ActiveRecord::Base.connection_pool.with_connection { task.mark_retrying!(params: p.to_json) }
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{safe_suno_detail(e.message)}"
      raise e
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted cover_art"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: cover_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_cover_art_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll attempt #{task.attempts + 1}/#{task.max_attempts} → #{result.is_a?(Array) ? "#{result.size} images" : safe_suno_detail(result.inspect)}"

    case result
    when :pending
      :pending
    when :retry
      # Mirror SunoTaskHandler: Suno worker died on its side. Clear our
      # external_id so the next handler call re-submits a fresh job; capped
      # at MAX_GENERATION_RETRIES to bound total Suno spend per task.
      p = task.params_hash
      retries = (p['generation_retries'] || 0) + 1
      p['generation_retries'] = retries
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Suno transient failure for #{task.external_id} (retry #{retries}/#{MAX_GENERATION_RETRIES})"
      if retries <= MAX_GENERATION_RETRIES
        ActiveRecord::Base.connection_pool.with_connection do
          task.mark_retrying!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'cover_art_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'cover_art_failed')
      :failed
    when Hash
      # Failure-with-detail from poll_cover_art_once. See SunoClient#format_suno_error.
      mark_failed_and_notify(task, api, 'cover_art_failed', error_detail: result[:error])
      :failed
    when Array
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result.size} images"
      cache_suno_delivery_result(task, result)
    end
  end

  def deliver_cached_images(task, api)
    p = task.params_hash
    response = send_images(api, task.chat_id, p['delivery_result'], p)
    messages = telegram_messages(response, expected_count: p['delivery_result'].size)
    return :pending if messages && cache_suno_delivery_receipt(task, messages)
    return :pending if retry_suno_delivery(task, 'delivery_failures')
    mark_failed_and_notify(task, api, 'cover_art_delivery_failed')
    :failed
  end

  def persist_images_receipt(task)
    p = task.params_hash
    title = p['source_title']
    caption = title ? "🎨 обложка для «#{title}»" : '🎨 обложка'
    persisted = p.fetch('delivery_receipt').all? do |receipt|
      row = Message.find_by(chat_id: task.chat_id, message_id: receipt['message_id']) ||
        Message.persist_bot_reply(chat_id: task.chat_id, body: "[#{caption}]",
          response: receipt_response(receipt), bg_task_external_id: task.external_id,
          message_thread_id: p['forum_thread_id'])
      row&.persisted?
    end
    unless persisted
      return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('cover_art_persistence_failed', delivery_status: 'delivered') }
      emit_agent_event(task, 'cover_art_persistence_failed',
        summary: "Обложка принята Telegram, но не сохранена локально; не отправляй её повторно.")
      return :failed
    end
    ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(p['delivery_result'], delivery_status: 'delivered') }
    :done
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: cover-art persistence failed: #{e.class}: #{safe_suno_detail(e.message)}"
    return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_failed!('cover_art_persistence_failed', delivery_status: 'delivered')
    end
    emit_agent_event(task, 'cover_art_persistence_failed',
      summary: 'Обложка принята Telegram, но не сохранена локально; не отправляй её повторно.')
    :failed
  end

  def send_images(api, chat_id, clips, params, bg_task_external_id: nil)
    source_title = params['source_title']
    caption = source_title ? "🎨 обложка для «#{source_title}»" : '🎨 обложка'

    # Build media + temp_files together so attach keys stay aligned even when
    # a download fails. Each successful download takes the next sequential
    # index for both `attach://photoN` (in media) and the `photoN` upload
    # param. Skipping a clip here without re-indexing would mismatch the
    # JSON references against the actual upload params and Telegram would
    # reject with 400.
    temp_files = []
    media = []
    clips.each do |clip|
      tmp = download_to_tempfile(clip['image_url'] || clip[:image_url], "cover_#{temp_files.size}.png", chat_id: chat_id, suffix: '.png')
      next unless tmp
      i = temp_files.size
      temp_files << tmp
      entry = { type: 'photo', media: "attach://photo#{i}" }
      entry[:caption] = caption if i == 0
      media << entry
    end

    if media.size != clips.size
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_images: no clips downloaded — skipping send"
      return nil
    end

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_images: sendMediaGroup → #{media.size} images"

    result = begin
      send_params = { chat_id: chat_id, media: media.to_json }
      send_params.merge!(forum_send_params(params))
      temp_files.each_with_index { |tf, i| send_params[:"photo#{i}"] = Faraday::UploadIO.new(tf.path, 'image/png', "cover_#{i}.png") }
      api.sendMediaGroup(**send_params)
    rescue => e
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendMediaGroup failed: #{e.class}: #{safe_suno_detail(e.message)}"
      nil
    ensure
      temp_files.each { |tf| tf.close; tf.unlink rescue nil }
    end

    result
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_images failed: #{e.class}: #{safe_suno_detail(e.message)}"
    false
  end

  def telegram_media_messages(response, expected_count:)
    messages = response.is_a?(Hash) ? response['result'] : response
    return unless messages.is_a?(Array) && messages.size == expected_count
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

  # See SunoTaskHandler#mark_failed_and_notify for `error_detail` rationale —
  # threads Suno's actual errorCode/errorMessage into the agent_event
  # summary so the agent can pick a meaningful next move.
  def mark_failed_and_notify(task, api, reason, error_detail: nil)
    error_detail = safe_suno_detail(error_detail) if error_detail
    scrub_terminal_delivery_result!(task)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cover-art #{reason}#{error_detail ? " (#{error_detail})" : ''}"
    delivery = reason.to_s.include?('delivery_failed') ? 'failed' : nil
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_failed!(reason, delivery_status: delivery)
    end

    # User-facing chat notification — same two-channel pattern as
    # SunoTaskHandler so the user always hears something even if the agent
    # event hits the 10/hour cap or the agent picks (skip).
    text = 'Не удалось нарисовать обложку'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text, **forum_send_params(task.params_hash))
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp,
                                message_thread_id: task.params_hash['forum_thread_id'])
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{safe_suno_detail(e.message)}"
    end

    p = task.params_hash
    summary = "Обложка для «#{p['source_title']}» (source #{p['source_task_id']}): #{reason}"
    summary += " | #{error_detail}" if error_detail && !error_detail.to_s.empty?
    emit_agent_event(task, 'cover_art_failed', summary: summary)
  end
end

TaskRunner.register('suno_cover_art', SunoCoverArtHandler)

require_relative 'agent_event_emitter'
require_relative 'suno_delivery'
require_relative '../media_download'

# Handles `suno_wav_convert` tasks: fetch the audio_id for a given clip of
# a previously-generated Suno song, submit `/api/v1/wav/generate`, poll
# `/api/v1/wav/record-info`, then deliver the resulting WAV to the chat
# as an audio message (so the user can play AND download from Telegram).
#
# Architecture mirrors SunoCoverArtHandler — submit/poll/deliver split
# with the same retry+notify pattern. Lives in its own handler (vs. being
# folded into SunoTaskHandler) because the response shape, polling
# endpoint, and deliverable type are all distinct.
class SunoWavConvertHandler
  include AgentEventEmitter
  include MediaDownload
  include SunoDelivery

  MAX_SUBMIT_FAILURES    = 3
  MAX_GENERATION_RETRIES = 3

  def call(task, api)
    return persist_wav_receipt(task) if suno_delivery_receipt(task)
    return deliver_cached_wav(task, api) if suno_delivery_result(task)
    task.external_id.nil? ? submit(task, api) : poll_and_deliver(task, api)
  end

  private

  def submit(task, api)
    p = task.params_hash
    source_task_id = p['source_task_id'].to_s
    if source_task_id.empty?
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: missing source_task_id"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('missing_source') }
      return :failed
    end

    audio_id = p['audio_id'].to_s
    if audio_id.empty?
      ids = SunoClient.new.fetch_audio_ids(source_task_id)
      idx = (p['clip_index'] || 1).to_i.clamp(1, [ids.size, 1].max)
      audio_id = ids[idx - 1].to_s
      if audio_id.empty?
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cannot resolve audio_id for requested clip_index=#{idx}"
        mark_failed_and_notify(task, api, 'wav_unknown_audio_id')
        return :failed
      end
      p['audio_id'] = audio_id
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    begin
      wav_task_id = SunoClient.new.convert_to_wav(task_id: source_task_id, audio_id: audio_id)
    rescue => e
      # Permanent Suno rejection: fail now with the detail rather than
      # re-raising into TaskRunner's raw "Ошибка: …" (no agent_event).
      if TaskRunner.permanent_error?(e)
        mark_failed_and_notify(task, api, 'wav_submit_rejected', error_detail: e.message)
        return :failed
      end
      attempts = (p['submit_failures'] || 0) + 1
      p['submit_failures'] = attempts
      if attempts >= MAX_SUBMIT_FAILURES
        ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{safe_suno_detail(e.message)}"
        mark_failed_and_notify(task, api, 'wav_submit_failed_after_retries')
        return :failed
      end
      ActiveRecord::Base.connection_pool.with_connection { task.mark_retrying!(params: p.to_json) }
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{safe_suno_detail(e.message)}"
      raise e
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted wav-convert"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: wav_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_wav_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll attempt #{task.attempts + 1}/#{task.max_attempts} → #{result.is_a?(Hash) && result[:wav_url] ? 'wav ready' : safe_suno_detail(result.inspect)}"

    case result
    when :pending
      :pending
    when :retry
      # SUCCESS but no url — Suno worker hiccup; re-submit fresh.
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
      mark_failed_and_notify(task, api, 'wav_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'wav_failed')
      :failed
    when Hash
      # Hash is overloaded for this poll: { wav_url: '...' } on success
      # vs { failed: true, error: '...' } on Suno-reported failure.
      # Discriminate explicitly by key — falling through on an unknown
      # shape (future Suno change, parser regression) into the success
      # branch with `result[:wav_url] = nil` would crash deep inside
      # send_wav. Better to log + fail loudly here.
      if result[:failed]
        mark_failed_and_notify(task, api, 'wav_failed', error_detail: result[:error])
        :failed
      elsif result[:wav_url]
        LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation complete"
        cache_suno_delivery_result(task, result)
      else
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: unknown poll_wav_once Hash shape: #{safe_suno_detail(result.inspect)}"
        mark_failed_and_notify(task, api, 'wav_unknown_response_shape',
                               error_detail: "unexpected poll Hash: #{safe_suno_detail(result.inspect)}")
        :failed
      end
    end
  end

  def deliver_cached_wav(task, api)
    p = task.params_hash
    result = p['delivery_result']
    response = send_wav(api, task.chat_id, result['wav_url'], p)
    messages = telegram_messages(response, expected_count: 1)
    if messages && cache_suno_delivery_receipt(task, messages)
      :pending
    elsif retry_suno_delivery(task, 'delivery_failures')
      :pending
    else
      mark_failed_and_notify(task, api, 'wav_delivery_failed')
      :failed
    end
  end

  def persist_wav_receipt(task)
    p = task.params_hash
    receipt = p.fetch('delivery_receipt').first
    title = p['source_title'].to_s
    existing = Message.find_by(chat_id: task.chat_id, message_id: receipt['message_id'])
    row = existing || Message.persist_bot_reply(chat_id: task.chat_id, body: "[wav: #{title}]",
      response: receipt_response(receipt), bg_task_external_id: task.external_id,
      message_thread_id: p['forum_thread_id'])
    unless row&.persisted?
      return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('wav_persistence_failed', delivery_status: 'delivered') }
      emit_agent_event(task, 'wav_persistence_failed',
        summary: 'WAV принят Telegram, но не сохранён локально; не отправляй его повторно.')
      return :failed
    end
    ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(p['delivery_result'], delivery_status: 'delivered') }
    :done
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: WAV persistence failed: #{e.class}: #{safe_suno_detail(e.message)}"
    return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_failed!('wav_persistence_failed', delivery_status: 'delivered')
    end
    emit_agent_event(task, 'wav_persistence_failed',
      summary: 'WAV принят Telegram, но не сохранён локально; не отправляй его повторно.')
    :failed
  end

  def send_wav(api, chat_id, wav_url, params, bg_task_external_id: nil)
    title     = params['source_title'].to_s
    performer = params['source_performer'].to_s
    title     = 'WAV' if title.empty?
    filename  = build_filename(performer, title)

    tmp = download_to_tempfile(wav_url, filename, chat_id: chat_id, suffix: '.wav')
    return false unless tmp

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_wav: sendAudio → #{File.size(tmp.path)} bytes"
    result = begin
      send_params = {
        chat_id: chat_id,
        audio: Faraday::UploadIO.new(tmp.path, 'audio/wav', filename),
        title: title,
        performer: performer.empty? ? '42FM Bot' : performer,
        caption: "🎵 #{title} (WAV)"
      }.merge(forum_send_params(params))
      api.sendAudio(**send_params)
    rescue => e
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendAudio failed: #{e.class}: #{safe_suno_detail(e.message)}"
      nil
    ensure
      tmp.close
      tmp.unlink rescue nil
    end

    result
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_wav failed: #{e.class}: #{safe_suno_detail(e.message)}"
    false
  end

  def telegram_message_id(response)
    message = response.is_a?(Hash) && response.key?('result') ? response['result'] : response
    value = if message.respond_to?(:message_id)
              message.message_id
            elsif message.is_a?(Hash)
              message['message_id'] || message[:message_id]
            end
    value if value.is_a?(Integer) && value.positive?
  end

  # Mirrors SunoTaskHandler#build_filename — Performer_-_Title.wav, Telegram-safe.
  def build_filename(performer, title)
    name = [performer, title].reject { |s| s.to_s.empty? }.join('_-_')
    name = name.gsub(/[\/\\:*?"<>|]/, '').gsub(/\s+/, '_')
    name = 'wav' if name.empty?
    "#{name}.wav"
  end

  # See SunoTaskHandler#mark_failed_and_notify for `error_detail` rationale.
  def mark_failed_and_notify(task, api, reason, error_detail: nil)
    error_detail = safe_suno_detail(error_detail) if error_detail
    scrub_terminal_delivery_result!(task)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: WAV #{reason}#{error_detail ? " (#{error_detail})" : ''}"
    delivery = reason.to_s.include?('delivery_failed') ? 'failed' : nil
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_failed!(reason, delivery_status: delivery)
    end

    text = 'Не удалось сконвертировать в WAV'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text, **forum_send_params(task.params_hash))
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp,
                                message_thread_id: task.params_hash['forum_thread_id'])
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{safe_suno_detail(e.message)}"
    end

    p = task.params_hash
    summary = "WAV для «#{p['source_title']}» (source #{p['source_task_id']}, audio #{p['audio_id']}): #{reason}"
    summary += " | #{error_detail}" if error_detail && !error_detail.to_s.empty?
    emit_agent_event(task, 'wav_failed', summary: summary)
  end
end

TaskRunner.register('suno_wav_convert', SunoWavConvertHandler)

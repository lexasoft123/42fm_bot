require_relative 'agent_event_emitter'
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

  MAX_SUBMIT_FAILURES    = 3
  MAX_GENERATION_RETRIES = 3

  def call(task, api)
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
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cannot resolve audio_id for source #{source_task_id} (clip_index=#{idx} ids=#{ids.inspect})"
        mark_failed_and_notify(task, api, 'wav_unknown_audio_id')
        return :failed
      end
      p['audio_id'] = audio_id
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    begin
      wav_task_id = SunoClient.new.convert_to_wav(task_id: source_task_id, audio_id: audio_id)
    rescue => e
      attempts = (p['submit_failures'] || 0) + 1
      p['submit_failures'] = attempts
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      if attempts >= MAX_SUBMIT_FAILURES
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{e.message}"
        mark_failed_and_notify(task, api, 'wav_submit_failed_after_retries')
        return :failed
      end
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{e.message}"
      raise e
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted wav-convert #{wav_task_id} for source #{source_task_id} audio #{audio_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: wav_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_wav_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

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
          task.update!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'wav_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'wav_failed')
      :failed
    when Hash
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:wav_url]}"
      delivered = send_wav(api, task.chat_id, result[:wav_url], task.params_hash, bg_task_external_id: task.external_id)
      if delivered
        ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
        :done
      else
        mark_failed_and_notify(task, api, 'wav_delivery_failed')
        :failed
      end
    end
  end

  def send_wav(api, chat_id, wav_url, params, bg_task_external_id: nil)
    title     = params['source_title'].to_s
    performer = params['source_performer'].to_s
    title     = 'WAV' if title.empty?
    filename  = build_filename(performer, title)

    tmp = download_to_tempfile(wav_url, filename, chat_id: chat_id, suffix: '.wav')
    return false unless tmp

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_wav: sendAudio → #{File.size(tmp.path)} bytes"
    retries = 0
    result = begin
      api.sendAudio(
        chat_id: chat_id,
        audio: Faraday::UploadIO.new(tmp.path, 'audio/wav', filename),
        title: title,
        performer: performer.empty? ? '42FM Bot' : performer,
        caption: "🎵 #{title} (WAV)"
      )
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendAudio retry #{retries}: #{e.class}: #{e.message}"
      if retries <= 3
        sleep 3
        retry
      end
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendAudio gave up after #{retries} retries"
      nil
    ensure
      tmp.close
      tmp.unlink rescue nil
    end

    return false unless result

    persist_bot_media_row(chat_id, result, title, bg_task_external_id: bg_task_external_id)
    true
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_wav failed: #{e.class}: #{e.message}"
    false
  end

  # Mirrors SunoTaskHandler#build_filename — Performer_-_Title.wav, Telegram-safe.
  def build_filename(performer, title)
    name = [performer, title].reject { |s| s.to_s.empty? }.join('_-_')
    name = name.gsub(/[\/\\:*?"<>|]/, '').gsub(/\s+/, '_')
    name = 'wav' if name.empty?
    "#{name}.wav"
  end

  def persist_bot_media_row(chat_id, response, title, bg_task_external_id: nil)
    msg = response.is_a?(Hash) ? response['result'] : response
    mid = msg.respond_to?(:message_id) ? msg.message_id : msg&.dig('message_id')
    tid = msg.respond_to?(:message_thread_id) ? msg.message_thread_id : msg&.dig('message_thread_id')
    return unless mid
    body = "[wav: #{title}]"
    ActiveRecord::Base.connection_pool.with_connection do
      Message.create(role: 'bot', chat_id: chat_id, body: body, message_id: mid,
                     message_thread_id: tid, bg_task_external_id: bg_task_external_id)
    end
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} persist_bot_media_row failed: #{e.class}: #{e.message}"
  end

  def mark_failed_and_notify(task, api, reason)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: WAV #{reason} for #{task.external_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }

    text = 'Не удалось сконвертировать в WAV'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text)
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
    end

    p = task.params_hash
    summary = "WAV для «#{p['source_title']}» (source #{p['source_task_id']}, audio #{p['audio_id']}): #{reason}"
    emit_agent_event(task, 'wav_failed', summary: summary)
  end
end

TaskRunner.register('suno_wav_convert', SunoWavConvertHandler)

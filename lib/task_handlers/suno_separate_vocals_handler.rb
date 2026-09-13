require_relative 'agent_event_emitter'
require_relative '../media_download'

# Handles `suno_separate_vocals` tasks (agent tool `separate_vocals`):
# submit `/api/v1/vocal-removal/generate`, poll
# `/api/v1/vocal-removal/record-info`, then deliver every stem to the chat
# as audio (media groups of ≤10), so the user can play AND download them.
#
# Shape mirrors SunoWavConvertHandler (submit/poll/deliver split, same
# notify + agent_event pattern), with two deliberate differences:
#   - never resubmits after Suno accepted the job — every separation call is
#     billed (10/50/20 credits) and there is no server-side cache;
#   - mark_done! runs BEFORE delivery (like SunoTaskHandler) so the stem URLs
#     (valid 14 days) land in `result` even when the Telegram send fails.
#     Delivery therefore must never raise out of this handler: an exception
#     reaching TaskRunner#process_one would overwrite :done with :failed.
class SunoSeparateVocalsHandler
  include AgentEventEmitter
  include MediaDownload

  MAX_SUBMIT_FAILURES = 3
  MEDIA_GROUP_MAX     = 10 # Bot API sendMediaGroup limit

  AUDIO_MIME = { '.mp3' => 'audio/mpeg', '.wav' => 'audio/wav', '.flac' => 'audio/flac', '.m4a' => 'audio/mp4' }.freeze

  def call(task, api)
    task.external_id.nil? ? submit(task, api) : poll_and_deliver(task, api)
  end

  private

  def submit(task, api)
    p = task.params_hash
    audio_url = p['audio_url'].to_s
    source_task_id = p['source_task_id'].to_s
    audio_id = p['audio_id'].to_s

    if audio_url.empty? && source_task_id.empty?
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: no audio_url or source_task_id"
      mark_failed_and_notify(task, api, 'separation_missing_source')
      return :failed
    end

    if audio_url.empty? && audio_id.empty?
      ids = SunoClient.new.fetch_audio_ids(source_task_id)
      idx = (p['clip_index'] || 1).to_i.clamp(1, [ids.size, 1].max)
      audio_id = ids[idx - 1].to_s
      if audio_id.empty?
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cannot resolve audio_id for source #{source_task_id} (clip_index=#{idx} ids=#{ids.inspect})"
        mark_failed_and_notify(task, api, 'separation_unknown_audio_id')
        return :failed
      end
      p['audio_id'] = audio_id
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    begin
      sep_task_id = SunoClient.new.separate_vocals(
        type:      p['type'],
        audio_url: audio_url.empty? ? nil : audio_url,
        task_id:   audio_url.empty? ? source_task_id : nil,
        audio_id:  audio_url.empty? ? audio_id : nil,
        stem_name: p['stem_name']
      )
    rescue ArgumentError => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: invalid separation params: #{e.message}"
      mark_failed_and_notify(task, api, 'separation_invalid_params', error_detail: e.message)
      return :failed
    rescue => e
      # Permanent Suno rejection (bad input, out of credits, …): fail with
      # the detail now instead of letting TaskRunner post a raw "Ошибка:"
      # that skips the agent_event. The message is already URL-redacted.
      if TaskRunner.permanent_error?(e)
        mark_failed_and_notify(task, api, 'separation_submit_rejected', error_detail: e.message)
        return :failed
      end
      attempts = (p['submit_failures'] || 0) + 1
      p['submit_failures'] = attempts
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      if attempts >= MAX_SUBMIT_FAILURES
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{e.message}"
        mark_failed_and_notify(task, api, 'separation_submit_failed_after_retries', error_detail: e.message)
        return :failed
      end
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{e.message}"
      raise e
    end

    LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{p['type']} #{sep_task_id} (#{audio_url.empty? ? "suno #{source_task_id}/#{audio_id}" : 'audio_url'})"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: sep_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_separation_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.is_a?(Hash) && result[:stems] ? "#{result[:stems].size} stems" : result.inspect}"

    if result == :pending
      :pending
    elsif result.is_a?(Hash) && result[:failed]
      mark_failed_and_notify(task, api, 'separation_failed', error_detail: result[:error])
      :failed
    elsif result.is_a?(Hash) && result[:stems].is_a?(Array) && !result[:stems].empty?
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:stems].map { |s| s[:name] }.join(', ')}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      deliver_stems(task, api, result[:stems])
      :done
    else
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: unexpected poll_separation_once result: #{result.inspect}"
      mark_failed_and_notify(task, api, 'separation_unknown_response_shape')
      :failed
    end
  end

  # Sends stems in media groups of ≤10. Never raises (see class comment).
  # Stems that fail to download or whose group fails to send are reported
  # together once at the end, so the agent can tell "nothing arrived" from
  # "some stems are missing".
  def deliver_stems(task, api, stems)
    p = task.params_hash
    title     = p['source_title'].to_s.strip
    title     = 'Трек' if title.empty?
    performer = p['source_performer'].to_s.strip
    delivered = []

    stems.each_slice(MEDIA_GROUP_MAX).with_index do |group, gi|
      sent = send_group(api, task.chat_id, group, title, performer, caption: gi.zero? ? caption_for(p, title) : nil)
      delivered.concat(sent)
    end

    missing = stems.map { |s| s[:name] } - delivered
    return if missing.empty?

    notify_delivery_failed(task, api, title, delivered: delivered, missing: missing)
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}] deliver_stems failed: #{e.class}: #{e.message}"
  end

  # Returns the stem names that actually went out in this group.
  def send_group(api, chat_id, group, title, performer, caption:)
    temp_files = []
    media = []
    group.each do |stem|
      ext = stem_extension(stem[:url])
      filename = build_filename(performer, title, stem[:name], ext)
      tmp = download_to_tempfile(stem[:url], filename, chat_id: chat_id, suffix: ext)
      next unless tmp

      key = "stem#{temp_files.size}"
      temp_files << { file: tmp, name: filename, mime: AUDIO_MIME[ext] || 'audio/mpeg', stem: stem[:name] }
      entry = { type: 'audio', media: "attach://#{key}",
                title: "#{title} (#{stem[:name]})", performer: performer.empty? ? '42FM Bot' : performer }
      entry[:caption] = caption if caption && media.empty?
      media << entry
    end
    return [] if media.empty?

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_group: sendMediaGroup → #{media.size} stems (#{temp_files.sum { |tf| File.size(tf[:file].path) }} bytes total)"
    retries = 0
    result = begin
      send_params = { chat_id: chat_id, media: media.to_json }
      temp_files.each_with_index { |tf, i| send_params[:"stem#{i}"] = Faraday::UploadIO.new(tf[:file].path, tf[:mime], tf[:name]) }
      api.sendMediaGroup(**send_params)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed, Faraday::TimeoutError => e
      retries += 1
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendMediaGroup retry #{retries}: #{e.class}: #{e.message}"
      if retries <= 3
        sleep 3
        retry
      end
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendMediaGroup gave up after #{retries} retries"
      nil
    end
    return [] unless result

    messages = result.is_a?(Hash) ? result['result'] : result
    Array(messages).each_with_index do |msg, i|
      stem_name = temp_files[i] && temp_files[i][:stem]
      Message.persist_bot_reply(chat_id: chat_id, body: "[стем: #{title} — #{stem_name}]", response: msg)
    end
    temp_files.map { |tf| tf[:stem] }
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_group failed: #{e.class}: #{e.message}"
    []
  ensure
    temp_files&.each { |tf| tf[:file].close; tf[:file].unlink rescue nil }
  end

  def caption_for(params, title)
    case params['type']
    when 'separate_vocal' then "🎚 #{title} — вокал и минус"
    when 'split_stem'     then "🎚 #{title} — дорожки"
    else                       "🎚 #{title} — #{params['stem_name']}"
    end
  end

  def stem_extension(url)
    ext = File.extname(URI.parse(url.to_s).path.to_s).downcase
    AUDIO_MIME.key?(ext) ? ext : '.mp3'
  rescue URI::InvalidURIError
    '.mp3'
  end

  # Performer_-_Title_(Vocals).mp3, Telegram-safe (mirrors SunoTaskHandler).
  def build_filename(performer, title, stem_name, ext)
    name = [performer, title].reject { |s| s.to_s.empty? }.join('_-_')
    name = "#{name}_(#{stem_name})"
    name = name.gsub(/[\/\\:*?"<>|]/, '').gsub(/\s+/, '_')
    "#{name}#{ext}"
  end

  def notify_delivery_failed(task, api, title, delivered:, missing:)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: separation_delivery_failed for '#{title}' — delivered=#{delivered.inspect} missing=#{missing.inspect}"
    if delivered.empty?
      text = 'Дорожки получились, но отправить их в чат не вышло 😔'
      begin
        resp = api.sendMessage(chat_id: task.chat_id, text: text)
        Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
      rescue => e
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify delivery failure: #{e.class}: #{e.message}"
      end
    end
    summary = "«#{title}» (task ##{task.id}): не доставлены дорожки #{missing.join(', ')}"
    summary += "; доставлены: #{delivered.join(', ')}" unless delivered.empty?
    emit_agent_event(task, 'separation_delivery_failed', summary: summary)
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: notify_delivery_failed itself failed: #{e.class}: #{e.message}"
  end

  # See SunoTaskHandler#mark_failed_and_notify for `error_detail` rationale.
  def mark_failed_and_notify(task, api, reason, error_detail: nil)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{reason} for #{task.external_id.inspect}#{error_detail ? " (#{error_detail})" : ''}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }

    text = 'Не удалось разделить трек на дорожки'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text)
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
    end

    p = task.params_hash
    title = p['source_title'].to_s.strip
    summary = "«#{title.empty? ? 'трек' : title}» (режим #{p['mode'] || p['type']}#{p['stem_name'] ? ", #{p['stem_name']}" : ''}, task ##{task.id}): #{reason}"
    summary += " | #{error_detail}" if error_detail && !error_detail.to_s.empty?
    emit_agent_event(task, 'separation_failed', summary: summary)
  end
end

TaskRunner.register('suno_separate_vocals', SunoSeparateVocalsHandler)

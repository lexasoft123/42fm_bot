require_relative 'agent_event_emitter'
require_relative 'suno_delivery'
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
#   - completion is recorded only after delivery has a truthful outcome.
#     Full confirmed+persistent delivery is `delivered`; partial or failed
#     delivery preserves the generated stem URLs but records delivery failed.
class SunoSeparateVocalsHandler
  include AgentEventEmitter
  include MediaDownload
  include SunoDelivery

  MAX_SUBMIT_FAILURES = 3
  MEDIA_GROUP_MAX     = 10 # Bot API sendMediaGroup limit

  AUDIO_MIME = { '.mp3' => 'audio/mpeg', '.wav' => 'audio/wav', '.flac' => 'audio/flac', '.m4a' => 'audio/mp4' }.freeze

  def call(task, api)
    return persist_stem_receipts(task) if suno_delivery_receipt(task)
    return deliver_cached_stem_batch(task, api) if suno_delivery_result(task)
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
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cannot resolve audio_id for requested clip_index=#{idx}"
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
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: invalid separation params: #{safe_suno_detail(e.message)}"
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
      if attempts >= MAX_SUBMIT_FAILURES
        ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{safe_suno_detail(e.message)}"
        mark_failed_and_notify(task, api, 'separation_submit_failed_after_retries', error_detail: e.message)
        return :failed
      end
      ActiveRecord::Base.connection_pool.with_connection { task.mark_retrying!(params: p.to_json) }
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{safe_suno_detail(e.message)}"
      raise e
    end

    LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{p['type']}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: sep_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_separation_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll attempt #{task.attempts + 1}/#{task.max_attempts} → #{result.is_a?(Hash) && result[:stems] ? "#{result[:stems].size} stems" : safe_suno_detail(result.inspect)}"

    if result == :pending
      :pending
    elsif result.is_a?(Hash) && result[:failed]
      mark_failed_and_notify(task, api, 'separation_failed', error_detail: result[:error])
      :failed
    elsif result.is_a?(Hash) && result[:stems].is_a?(Array) && !result[:stems].empty?
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:stems].map { |s| s[:name] }.join(', ')}"
      cache_suno_delivery_result(task, result)
    else
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: unexpected poll_separation_once result: #{safe_suno_detail(result.inspect)}"
      mark_failed_and_notify(task, api, 'separation_unknown_response_shape')
      :failed
    end
  end

  # Sends at most one Telegram media group per TaskRunner cycle. Receipts from
  # accepted groups are checkpointed before returning, so a crash or later
  # batch failure never resends a group the user already received.
  def deliver_cached_stem_batch(task, api)
    p = task.params_hash
    result = p.fetch('delivery_result')
    stems = result.fetch('stems')
    batches = stems.each_slice(MEDIA_GROUP_MAX).to_a
    batch_index = p.fetch('delivery_batch_index', 0).to_i
    receipts = Array(p['delivery_receipts'])
    return finalize_stem_receipts(task, p, receipts) if batch_index >= batches.size

    persisted_count = p.fetch('delivery_persisted_count', 0).to_i
    if persisted_count < receipts.size
      unless persist_stem_receipt_rows(task, receipts, p)
        return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
        scrub_terminal_delivery_result!(task)
        ActiveRecord::Base.connection_pool.with_connection do
          task.mark_failed!('separation_persistence_failed', delivery_status: 'delivered')
        end
        return :failed
      end
      p['delivery_persisted_count'] = receipts.size
      ActiveRecord::Base.connection_pool.with_connection do
        task.update_lifecycle!('delivering', params: p.to_json, delivery_status: 'pending')
      end
      return :pending
    end

    title = p['source_title'].to_s.strip
    title = 'Трек' if title.empty?
    performer = p['source_performer'].to_s.strip
    group = batches.fetch(batch_index)
    outcome = send_stem_group(api, task, group, title, performer,
                              caption: batch_index.zero? ? caption_for(p, title) : nil)
    unless outcome
      delivered = receipts.map { |r| r['stem_name'] }
      missing = stems.map { |s| s['name'] } - delivered
      if retry_suno_delivery(task, 'delivery_failures', delivery_status: 'pending')
        return :pending
      end
      scrub_terminal_delivery_result!(task)
      ActiveRecord::Base.connection_pool.with_connection do
        task.mark_failed!('separation_delivery_failed', delivery_status: 'failed')
      end
      notify_delivery_failed(task, api, title, delivered: delivered, missing: missing)
      return :failed
    end

    receipts.concat(outcome)
    p = task.params_hash
    p['delivery_receipts'] = receipts
    p['delivery_batch_index'] = batch_index + 1
    if p['delivery_batch_index'] >= batches.size
      finalize_stem_receipts(task, p, receipts)
    else
      ActiveRecord::Base.connection_pool.with_connection do
        task.update_lifecycle!('delivering', params: p.to_json, delivery_status: 'pending')
      end
      :pending
    end
  end

  def finalize_stem_receipts(task, params, receipts)
    params['delivery_receipt'] = receipts
    params.delete('delivery_receipts')
    params['delivery_result'] = redact_urls(params['delivery_result'])
    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(params: params.to_json, lifecycle_phase: 'persisting_delivery', delivery_status: 'delivered')
    end
    :pending
  end

  def send_stem_group(api, task, group, title, performer, caption:)
    temp_files = []
    media = []
    group.each do |stem|
      url = stem['url'] || stem[:url]
      name = stem['name'] || stem[:name]
      ext = stem_extension(url)
      filename = build_filename(performer, title, name, ext)
      tmp = download_to_tempfile(url, filename, chat_id: task.chat_id, suffix: ext)
      next unless tmp
      key = "stem#{temp_files.size}"
      temp_files << { file: tmp, name: filename, mime: AUDIO_MIME[ext] || 'audio/mpeg', stem: name }
      entry = { type: 'audio', media: "attach://#{key}", title: "#{title} (#{name})",
                performer: performer.empty? ? '42FM Bot' : performer }
      entry[:caption] = caption if caption && media.empty?
      media << entry
    end
    return nil unless media.size == group.size

    send_params = { chat_id: task.chat_id, media: media.to_json }.merge(forum_send_params(task.params_hash))
    temp_files.each_with_index do |tf, i|
      send_params[:"stem#{i}"] = Faraday::UploadIO.new(tf[:file].path, tf[:mime], tf[:name])
    end
    response = api.sendMediaGroup(**send_params)
    messages = telegram_messages(response, expected_count: group.size)
    return nil unless messages
    messages.each_with_index.map do |message, i|
      telegram_receipt(message, forum_thread_id: task.params_hash['forum_thread_id'])
        .merge('stem_name' => temp_files[i][:stem])
    end
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: stem batch send failed: #{e.class}: #{safe_suno_detail(e.message)}"
    nil
  ensure
    temp_files&.each { |tf| tf[:file].close; tf[:file].unlink rescue nil }
  end

  def persist_stem_receipts(task)
    p = task.params_hash
    title = p['source_title'].to_s.strip
    title = 'Трек' if title.empty?
    receipts = p.fetch('delivery_receipt')
    persisted = persist_stem_receipt_rows(task, receipts, p)
    unless persisted
      return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
      ActiveRecord::Base.connection_pool.with_connection do
        task.mark_failed!('separation_persistence_failed', delivery_status: 'delivered')
      end
      emit_agent_event(task, 'separation_persistence_failed',
        summary: "Дорожки «#{title}» приняты Telegram, но не сохранены локально; не отправляй их повторно.")
      return :failed
    end
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_done!(p['delivery_result'], delivery_status: 'delivered')
    end
    :done
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: stem persistence failed: #{e.class}: #{safe_suno_detail(e.message)}"
    return :pending if retry_suno_delivery(task, 'persistence_failures', delivery_status: 'delivered')
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_failed!('separation_persistence_failed', delivery_status: 'delivered')
    end
    emit_agent_event(task, 'separation_persistence_failed',
      summary: "Дорожки «#{title}» приняты Telegram, но не сохранены локально; не отправляй их повторно.")
    :failed
  end

  def persist_stem_receipt_rows(task, receipts, params)
    title = params['source_title'].to_s.strip
    title = 'Трек' if title.empty?
    receipts.all? do |receipt|
      row = Message.find_by(chat_id: task.chat_id, message_id: receipt['message_id']) ||
        Message.persist_bot_reply(chat_id: task.chat_id,
          body: "[стем: #{title} — #{receipt['stem_name']}]",
          response: receipt_response(receipt), bg_task_external_id: task.external_id,
          message_thread_id: params['forum_thread_id'])
      row&.persisted?
    end
  end

  def telegram_message_id(message)
    value = if message.respond_to?(:message_id)
              message.message_id
            elsif message.is_a?(Hash)
              message['message_id'] || message[:message_id]
            end
    value if value.is_a?(Integer) && value.positive?
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
        resp = api.sendMessage(chat_id: task.chat_id, text: text, **forum_send_params(task.params_hash))
        Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp,
                                  message_thread_id: task.params_hash['forum_thread_id'])
      rescue => e
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify delivery failure: #{e.class}: #{safe_suno_detail(e.message)}"
      end
    end
    summary = "«#{title}» (task ##{task.id}): не доставлены дорожки #{missing.join(', ')}"
    summary += "; доставлены: #{delivered.join(', ')}" unless delivered.empty?
    emit_agent_event(task, 'separation_delivery_failed', summary: summary)
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: notify_delivery_failed itself failed: #{e.class}: #{safe_suno_detail(e.message)}"
  end

  # See SunoTaskHandler#mark_failed_and_notify for `error_detail` rationale.
  def mark_failed_and_notify(task, api, reason, error_detail: nil)
    error_detail = safe_suno_detail(error_detail) if error_detail
    scrub_terminal_delivery_result!(task)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{reason}#{error_detail ? " (#{error_detail})" : ''}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }

    text = 'Не удалось разделить трек на дорожки'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text, **forum_send_params(task.params_hash))
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp,
                                message_thread_id: task.params_hash['forum_thread_id'])
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{safe_suno_detail(e.message)}"
    end

    p = task.params_hash
    title = p['source_title'].to_s.strip
    summary = "«#{title.empty? ? 'трек' : title}» (режим #{p['mode'] || p['type']}#{p['stem_name'] ? ", #{p['stem_name']}" : ''}, task ##{task.id}): #{reason}"
    summary += " | #{error_detail}" if error_detail && !error_detail.to_s.empty?
    emit_agent_event(task, 'separation_failed', summary: summary)
  end
end

TaskRunner.register('suno_separate_vocals', SunoSeparateVocalsHandler)

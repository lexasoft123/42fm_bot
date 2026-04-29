require_relative 'agent_event_emitter'
require_relative '../media_download'

class SunoCoverArtHandler
  include AgentEventEmitter
  include MediaDownload

  MAX_SUBMIT_FAILURES = 3
  MAX_GENERATION_RETRIES = 3

  def call(task, api)
    if task.external_id.nil?
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
      attempts = (p['submit_failures'] || 0) + 1
      p['submit_failures'] = attempts
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      if attempts >= MAX_SUBMIT_FAILURES
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts} (max #{MAX_SUBMIT_FAILURES}), giving up: #{e.message}"
        mark_failed_and_notify(task, api, 'cover_art_submit_failed_after_retries')
        return :failed
      end
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit_failures=#{attempts}/#{MAX_SUBMIT_FAILURES} — will retry: #{e.message}"
      raise e
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted cover_art #{cover_task_id} for source #{source_task_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: cover_task_id) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_cover_art_once(task.external_id)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

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
          task.update!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'cover_art_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'cover_art_failed')
      :failed
    when Array
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result.size} images"
      delivered = send_images(api, task.chat_id, result, task.params_hash)
      if delivered
        ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
        :done
      else
        # Suno produced clips but we couldn't get them to the chat (download
        # error / Telegram rejection). Don't mark `done` — that would lie
        # about delivery and leave the user with no recourse. Mark failed +
        # notify (chat msg + agent_event) so the agent can apologize.
        mark_failed_and_notify(task, api, 'cover_art_delivery_failed')
        :failed
      end
    end
  end

  def send_images(api, chat_id, clips, params)
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
      tmp = download_to_tempfile(clip[:image_url], "cover_#{temp_files.size}.png", chat_id: chat_id, suffix: '.png')
      next unless tmp
      i = temp_files.size
      temp_files << tmp
      entry = { type: 'photo', media: "attach://photo#{i}" }
      entry[:caption] = caption if i == 0
      media << entry
    end

    if media.empty?
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_images: no clips downloaded — skipping send"
      return false
    end

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_images: sendMediaGroup → #{media.size} images"

    retries = 0
    result = begin
      send_params = { chat_id: chat_id, media: media.to_json }
      temp_files.each_with_index { |tf, i| send_params[:"photo#{i}"] = Faraday::UploadIO.new(tf.path, 'image/png', "cover_#{i}.png") }
      api.sendMediaGroup(**send_params)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendMediaGroup retry #{retries}: #{e.class}: #{e.message}"
      if retries <= 3
        sleep 3
        retry
      end
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendMediaGroup gave up after #{retries} retries"
      nil
    ensure
      temp_files.each { |tf| tf.close; tf.unlink rescue nil }
    end

    return false unless result

    persist_bot_media_rows(chat_id, result, caption)
    true
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_images failed: #{e.class}: #{e.message}"
    false
  end

  def persist_bot_media_rows(chat_id, result, caption)
    messages = result.is_a?(Hash) ? result['result'] : result
    return unless messages.is_a?(Array)
    messages.each do |msg|
      mid = msg.respond_to?(:message_id) ? msg.message_id : msg['message_id']
      tid = msg.respond_to?(:message_thread_id) ? msg.message_thread_id : msg['message_thread_id']
      next unless mid
      ActiveRecord::Base.connection_pool.with_connection do
        Message.create(role: 'bot', chat_id: chat_id, body: "[#{caption}]", message_id: mid, message_thread_id: tid)
      end
    end
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} persist_bot_media_rows failed: #{e.class}: #{e.message}"
  end

  def mark_failed_and_notify(task, api, reason)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: cover-art #{reason} for #{task.external_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }

    # User-facing chat notification — same two-channel pattern as
    # SunoTaskHandler so the user always hears something even if the agent
    # event hits the 10/hour cap or the agent picks (skip).
    text = 'Не удалось нарисовать обложку'
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text)
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
    end

    p = task.params_hash
    summary = "Обложка для «#{p['source_title']}» (source #{p['source_task_id']}): #{reason}"
    emit_agent_event(task, 'cover_art_failed', summary: summary)
  end
end

TaskRunner.register('suno_cover_art', SunoCoverArtHandler)

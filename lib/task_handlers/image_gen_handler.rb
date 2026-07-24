require_relative 'agent_event_emitter'
require_relative '../telegram_file'

class ImageGenTaskHandler
  include ChatContext
  include AgentEventEmitter

  MAX_PROMPT_FAILURES  = 3
  MAX_SUBMIT_FAILURES  = 3

  def call(task, api)
    task.external_id.nil? ? compose_and_submit(task, api) : poll_and_deliver(task, api)
  end

  private

  def compose_and_submit(task, api)
    p = task.params_hash
    request = p['request'].to_s
    model_key = p['model']   # nil for legacy/award tasks (no per-request model)
    # Did the user ask to edit/combine? (inline image, history message_ids, or a
    # legacy single-image task enqueued before this deploy.)
    edit_intended = !p['input_image'].to_s.empty? ||
                    Array(p['input_images']).any? ||
                    Array(p['source_message_ids']).any?
    begin
      if model_key
        prov = ImageGen::Catalog.provider_for(model_key)
        unless ImageGen::ADAPTERS.key?(prov)   # typo'd/unknown provider in catalog entry
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: model #{model_key.inspect} → unknown provider #{prov.inspect}; falling back to default_model"
          model_key = ImageGen::Catalog.default_key   # re-resolve key so model id matches the adapter
          prov      = ImageGen::Catalog.provider_for(model_key)
        end
        adapter = ImageGen.adapter_for(prov)   # build the entry's provider's adapter
      else
        adapter = ImageGen.current_adapter     # legacy / no catalog → today's behavior
      end
    rescue => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: adapter resolution failed: #{e.class}: #{e.message}"
      mark_failed_and_notify(task, api, 'adapter_config_error')
      return :failed
    end

    # Resolve edit source image(s): inline (current/reply, already base64) plus
    # any chat-history photos the agent referenced by message_id — downloaded
    # HERE because the handler runs in TaskRunner, not the bot's listen loop.
    images  = resolve_input_images(task, api, p)
    editing = images.any?
    # Edit requested but nothing usable resolved (e.g. every referenced photo
    # predates photo-capture) — fail loudly instead of silently regenerating
    # from scratch (the exact silent-degradation this change exists to kill).
    if edit_intended && images.empty?
      mark_failed_and_notify(task, api, 'edit_sources_unavailable',
        user_text: "Не нашёл картинок для редактирования — возможно, они слишком старые. Пришли картинку заново.")
      return :failed
    end

    # Generate prompt via LLM with chat context (+ vision of the source images when editing)
    unless p['prompt']
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{request}' (edit=#{editing}, provider=#{adapter.name})"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)
      template = adapter.prompt_template(editing ? :edit : :text_to_image)
      # model_name is passed on EVERY path (incl. award/legacy tasks with no
      # model key) because the Atlas template references %{model_name} and
      # Ruby's String#% raises KeyError on a missing referenced key.
      llm_prompt = template % { request: request, context: context, knowledge: knowledge,
                               model_name: (model_key || 'AI image generator') }

      messages = if editing
        image_blocks = images.map do |img|
          { type: 'image', source: { type: 'base64', media_type: img[:media_type], data: img[:data] } }
        end
        [{ role: 'user', content: image_blocks + [{ type: 'text', text: llm_prompt }] }]
      else
        [{ role: 'user', content: llm_prompt }]
      end

      # Image-edit prompt enrichment needs vision (the LLM has to see the source
      # image to write a useful edit instruction). Route to `agent_vision`
      # (grok-4-fast-reasoning today) — DeepSeek rejects vision blocks.
      # The Anthropic-shape vision block we build below is auto-translated to
      # OpenAI shape in GptMaster#convert_vision_blocks_for_openai when the
      # provider isn't anthropic. Text-to-image enrichment stays on the cheaper
      # `agent` setting (no vision needed).
      enrich_setting = editing ? 'agent_vision' : 'agent'
      begin
        p['prompt'] = GptMaster.new(messages, setting: enrich_setting,
                                    chat_id: task.chat_id, user_uid: p['user_uid'],
                                    purpose: 'image_prompt').call
        raise "GPT prompt failed" unless p['prompt'] && p['prompt'] != 'жпт не жпт'
      rescue => e
        return bail_or_retry(task, api, p, 'prompt_failures', MAX_PROMPT_FAILURES, "prompt: #{e.message}", raise_on_retry: e)
      end
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt → '#{p['prompt'][0..100]}...'"
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    # Provider-specific model id for this mode; nil ⇒ adapter uses its
    # configured default (legacy tasks, or an edit:false catalog entry).
    mode = editing ? :edit : :text_to_image
    resolved_model_id = model_key ? ImageGen::Catalog.model_id_for(model_key, mode) : nil
    begin
      submit_result = adapter.submit(prompt: p['prompt'],
                                     input_images: editing ? images : nil,
                                     model: resolved_model_id)
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit: #{e.message}", raise_on_retry: e)
    end
    p['provider'] = adapter.name
    p['model']    = model_key if model_key   # forensics snapshot (poll dispatches on provider)

    # Synchronous adapters (e.g. CloseRouter Nano Banana Pro) return a
    # terminal result Hash from #submit and skip the poll cycle entirely.
    # Async adapters (Flux, Atlas) return a String external_id.
    if adapter.synchronous?
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: synchronous submit complete via #{adapter.name}"
      # Persist params snapshot (provider, prompt, retry counters) BEFORE
      # marking the task done. provider snapshot is informational only for
      # sync tasks (poll never runs, no adapter_for dispatch), but it lets
      # `бот задачи` + log forensics see which backend served the request.
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      return deliver_sync_result(task, api, submit_result)
    end

    task_id = submit_result
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{task_id} via #{adapter.name}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: task_id, params: p.to_json) }
    :pending
  end

  # Synchronous-path delivery. Mirrors the `when Hash` arm of poll_and_deliver
  # without the retry/agent-event-after-retries plumbing.
  #
  # `generation_retries` accounting is intentionally skipped here: it counts
  # poll-time `:retry` returns (transient backend hiccups during async
  # generation), which sync adapters can NEVER produce by definition. The
  # other retry axis — `submit_failures` — runs upstream in `bail_or_retry`
  # and either ultimately succeeds (we reach this method) or fails the task,
  # so it never reaches the success branch either. No agent_event needed.
  def deliver_sync_result(task, api, result)
    LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:url]}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
    send_photo(api, task.chat_id, result[:url], caption_for(task.params_hash))
    :done
  end

  # Shared by BOTH delivery paths (sync deliver_sync_result + async
  # poll_and_deliver) — awards must get 🏆 on every backend.
  def caption_for(p)
    prefix = p['award'] ? '🏆' : '🎨'
    "#{prefix} #{p['prompt'].to_s.empty? ? p['request'] : p['prompt']}"
  end

  # Increment a step-failure counter; if cap reached, fail+notify; otherwise re-raise so
  # TaskRunner retries on the next poll cycle.
  def bail_or_retry(task, api, params, counter, max, reason, raise_on_retry:)
    params[counter] = (params[counter] || 0) + 1
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: params.to_json) }
    if params[counter] >= max
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]} (max #{max}), giving up: #{reason}"
      mark_failed_and_notify(task, api, "#{counter}_after_retries")
      return :failed
    end
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]}/#{max} — will retry: #{reason}"
    raise raise_on_retry
  end

  MAX_GENERATION_RETRIES = 3
  # Consecutive status-endpoint (poll) errors tolerated before failing the task.
  # ~5 polls ≈ 75s — long enough to ride out a transient Atlas blip, far short of
  # the 60-attempt (~15min) timeout that would otherwise fire with a wrong message.
  MAX_POLL_ERRORS = 5

  def poll_and_deliver(task, api)
    provider = task.params_hash['provider']
    begin
      adapter = ImageGen.adapter_for(provider)
    rescue => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll adapter resolution failed: #{e.class}: #{e.message}"
      mark_failed_and_notify(task, api, 'adapter_config_error')
      return :failed
    end
    result = adapter.poll_once(task.external_id)

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} via #{adapter.name} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      # Reset is deliberately :pending-only — Atlas never returns :retry, and
      # Hash/:failed are terminal. A future :retry-returning model would carry a
      # prior error streak forward (harmless; revisit if such a model is added).
      reset_poll_errors(task) # a healthy 200 poll clears the consecutive-error streak
      :pending
    when :poll_error
      # The status endpoint failed (e.g. Atlas 500). Tolerate a few CONSECUTIVE
      # errors (transient blip) but fail fast on a persistent outage instead of
      # spinning to the 60-attempt timeout with a misleading "timeout" message.
      p    = task.params_hash
      errs = (p['poll_errors'] || 0) + 1
      p['poll_errors'] = errs
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{adapter.name} poll unavailable for #{task.external_id} (#{errs}/#{MAX_POLL_ERRORS})"
      if errs >= MAX_POLL_ERRORS
        mark_failed_and_notify(task, api, 'poll_unavailable')
        return :failed
      end
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      :pending
    when :retry
      p = task.params_hash
      retries = (p['generation_retries'] || 0) + 1
      p['generation_retries'] = retries
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{adapter.name} transient failure for #{task.external_id} (retry #{retries}/#{MAX_GENERATION_RETRIES})"
      if retries <= MAX_GENERATION_RETRIES
        # Clear external_id so next handler call re-submits with cached prompt.
        ActiveRecord::Base.connection_pool.with_connection do
          task.update!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'image_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'image_failed')
      :failed
    when Hash
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:url]}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      p = task.params_hash
      send_photo(api, task.chat_id, result[:url], caption_for(p))
      if (p['generation_retries'] || 0) >= 1
        emit_agent_event(task, 'image_succeeded_after_retries',
          summary: "Запрос: #{p['request'].to_s[0..200]} | Получилось с #{p['generation_retries']}-й попытки.")
      end
      :done
    end
  end

  # Resolve the ordered edit-source image list:
  #   1. inline images (current/replied photo) — already base64 in params
  #   2. legacy singular input_image (tasks enqueued before this deploy)
  #   3. chat-history photos referenced by message_id — same resolution as the
  #      view_image tool, downloaded here (TaskRunner, not the bot loop)
  # Missing/old message_ids (no stored file_id) and failed downloads are skipped
  # with a warning. Returns up to MAX_EDIT_IMAGES of { data:, media_type: }.
  def resolve_input_images(task, api, p)
    images = []
    Array(p['input_images']).each do |img|
      data = img['data'] || img[:data]
      next if data.to_s.empty?
      images << { data: data, media_type: img['media_type'] || img[:media_type] || 'image/jpeg' }
    end
    if images.empty? && !p['input_image'].to_s.empty?   # legacy single-image task
      images << { data: p['input_image'], media_type: p['input_media_type'] || 'image/jpeg' }
    end
    Array(p['source_message_ids']).each do |mid|
      file_id = ActiveRecord::Base.connection_pool.with_connection do
        Message.where(chat_id: task.chat_id, message_id: mid.to_i).pick(:attachment_photo_file_id)
      end
      unless file_id
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: source message #{mid} has no stored photo — skipping"
        next
      end
      img = TelegramFile.download_image(api, file_id, chat_id: task.chat_id)
      unless img
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to download photo from message #{mid} — skipping"
        next
      end
      images << { data: img[:data], media_type: img[:media_type] || 'image/jpeg' }
    end
    # Post-resolution backstop. The tool pre-caps source_message_ids before
    # enqueue, but this also bounds legacy/in-flight tasks (and any future
    # enqueuer) regardless of how they were created.
    images.first(ImageGen::MAX_EDIT_IMAGES)
  end

  # Clear the consecutive poll-error counter after a healthy poll so a later
  # transient blip starts fresh. Only writes when the counter is non-zero.
  def reset_poll_errors(task)
    p = task.params_hash
    return unless (p['poll_errors'] || 0) > 0
    p['poll_errors'] = 0
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
  end

  def mark_failed_and_notify(task, api, reason, user_text: "Не удалось сгенерировать картинку")
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation #{reason} for #{task.external_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }
    text = user_text
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text)
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
    end
    event_type = reason.to_s.include?('after_retries') ? 'image_failed_after_retries' : 'image_failed'
    summary = "Запрос: #{task.params_hash['request'].to_s[0..200]} | Промпт: #{task.params_hash['prompt'].to_s[0..200]} | Причина: #{reason}"
    emit_agent_event(task, event_type, summary: summary)
  end

  def send_photo(api, chat_id, url, caption)
    caption = caption[0..1020] + "..." if caption.length > 1024
    tmp = download_to_tempfile(url)
    response = if tmp
      retries = 0
      begin
        api.sendPhoto(chat_id: chat_id, photo: Faraday::UploadIO.new(tmp.path, 'image/jpeg', 'image.jpg'), caption: caption)
      rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed, Faraday::TimeoutError => e
        retries += 1
        LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto retry #{retries}: #{e.class}"
        if retries <= 3
          sleep 3
          retry
        end
        nil
      ensure
        tmp.close
        tmp.unlink rescue nil
      end
    else
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: download failed, falling back to URL"
      api.sendPhoto(chat_id: chat_id, photo: url, caption: caption)
    end

    persist_bot_media_row(chat_id, response, caption) if response
  end

  # Save the sent photo as a bot Message row so user replies pointing at the
  # photo's Telegram message_id can resolve to a known row, and so the agent
  # can re-view its own generated image via the view_image tool (the photo
  # file_id is captured by Message.persist_bot_reply — the centralized
  # bot-side persistence path).
  def persist_bot_media_row(chat_id, response, caption)
    Message.persist_bot_reply(chat_id: chat_id, body: caption, response: response)
  end

  def download_to_tempfile(url)
    response = HTTParty.get(url, timeout: 60)
    return nil unless response.code == 200
    tmp = Tempfile.new(['flux_', '.jpg'], '/tmp')
    tmp.binmode
    tmp.write(response.body)
    tmp.rewind
    tmp
  rescue => e
    LOGGER.warn "#{self.class.name} download failed: #{e.class}: #{e.message}"
    nil
  end
end

TaskRunner.register('image_generate', ImageGenTaskHandler)

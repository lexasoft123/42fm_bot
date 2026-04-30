require_relative 'agent_event_emitter'

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
    input_image = p['input_image']
    editing = !input_image.to_s.empty?
    begin
      adapter = ImageGen.current_adapter
    rescue => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: adapter resolution failed: #{e.class}: #{e.message}"
      mark_failed_and_notify(task, api, 'adapter_config_error')
      return :failed
    end

    # Generate prompt via LLM with chat context (+ vision of the source image when editing)
    unless p['prompt']
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{request}' (edit=#{editing}, provider=#{adapter.name})"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)
      template = adapter.prompt_template(editing ? :edit : :text_to_image)
      llm_prompt = template % { request: request, context: context, knowledge: knowledge }

      messages = if editing
        media_type = p['input_media_type'] || 'image/jpeg'
        [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: media_type, data: input_image } },
          { type: 'text',  text: llm_prompt }
        ] }]
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

    begin
      task_id = adapter.submit(prompt: p['prompt'],
                               input_image: input_image.to_s.empty? ? nil : input_image,
                               input_media_type: p['input_media_type'])
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit: #{e.message}", raise_on_retry: e)
    end
    p['provider'] = adapter.name
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{task_id} via #{adapter.name}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: task_id, params: p.to_json) }
    :pending
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
      caption = "🎨 #{p['prompt'].to_s.empty? ? p['request'] : p['prompt']}"
      send_photo(api, task.chat_id, result[:url], caption)
      if (p['generation_retries'] || 0) >= 1
        emit_agent_event(task, 'image_succeeded_after_retries',
          summary: "Запрос: #{p['request'].to_s[0..200]} | Получилось с #{p['generation_retries']}-й попытки.")
      end
      :done
    end
  end

  def mark_failed_and_notify(task, api, reason)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation #{reason} for #{task.external_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }
    text = "Не удалось сгенерировать картинку"
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
      rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
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
  # photo's Telegram message_id can resolve to a known row (fixes "reply_to
  # points at an id we never indexed" context gaps).
  def persist_bot_media_row(chat_id, response, caption)
    msg_id = extract_message_id(response)
    return unless msg_id
    thread_id = extract_message_thread_id(response)
    ActiveRecord::Base.connection_pool.with_connection do
      Message.create(
        role: 'bot', chat_id: chat_id, body: caption,
        message_id: msg_id, message_thread_id: thread_id
      )
    end
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} persist_bot_media_row failed: #{e.class}: #{e.message}"
  end

  def extract_message_id(resp)
    return resp.message_id if resp.respond_to?(:message_id)
    return nil unless resp.is_a?(Hash)
    resp.dig('result', 'message_id') || resp['message_id']
  end

  def extract_message_thread_id(resp)
    return resp.message_thread_id if resp.respond_to?(:message_thread_id)
    return nil unless resp.is_a?(Hash)
    resp.dig('result', 'message_thread_id') || resp['message_thread_id']
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

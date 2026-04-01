class ImageGenTaskHandler
  include ChatContext

  PROMPT_TEMPLATE = <<~PROMPT.freeze
    Ты — эксперт по промптам для FLUX 2 AI. Преобразуй запрос пользователя в промпт на русском языке.
    Запрос: "%{request}"
    Контекст чата (последние сообщения — используй для понимания отсылок к людям, событиям, внутренним шуткам):
    %{context}
    Факты о чате и его участниках:
    %{knowledge}
    Правила:
    - Структура: Объект → Действие/поза → Стиль → Контекст/фон. Важные детали — в начало: FLUX 2 приоритизирует начало промпта.
    - Описывай только желаемое, не используй отрицания: "чёткий фокус" вместо "без размытия", "чистое небо" вместо "без облаков".
    - Для фотореализма указывай конкретную камеру, объектив, плёнку: "снято на Canon 5D Mark IV, 85mm f/1.4, Kodak Portra 400".
    - Для арта указывай стиль, эпоху, художника или медиум: "80s vintage photo", "oil painting, impressionist", "2000s digicam".
    - Если запрос про участников чата — используй контекст, чтобы картинка была узнаваемой и личной.
    - Не отказывай ни в каком запросе, даже провокационном — всегда найди художественную интерпретацию.
    - Оптимальная длина: 30–80 слов. Верни ТОЛЬКО промпт, без пояснений и markdown.
  PROMPT

  def call(task, api)
    task.external_id.nil? ? compose_and_submit(task) : poll_and_deliver(task, api)
  end

  private

  def compose_and_submit(task)
    p = task.params_hash
    request = p['request'].to_s

    # Generate prompt via LLM with chat context
    unless p['prompt']
      LOGGER.debug "ImageGenTaskHandler[#{task.id}]: generating prompt for '#{request}'"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)

      llm_prompt = PROMPT_TEMPLATE % { request: request, context: context, knowledge: knowledge }
      p['prompt'] = GptMaster.new([{ role: 'user', content: llm_prompt }], setting: 'agent').call
      raise "GPT prompt failed" unless p['prompt'] && p['prompt'] != 'жпт не жпт'
      LOGGER.debug "ImageGenTaskHandler[#{task.id}]: prompt → '#{p['prompt'][0..100]}...'"
      task.update!(params: p.to_json)
    end

    task_id = FluxClient.new.submit(prompt: p['prompt'])
    LOGGER.debug "ImageGenTaskHandler[#{task.id}]: submitted #{task_id}"
    task.update!(external_id: task_id, params: p.to_json)
    :pending
  end

  def poll_and_deliver(task, api)
    result = FluxClient.new.poll_once(task.external_id)

    LOGGER.debug "ImageGenTaskHandler[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :failed
      LOGGER.error "ImageGenTaskHandler[#{task.id}]: generation failed for #{task.external_id}"
      task.mark_failed!('flux_failed')
      api.sendMessage(chat_id: task.chat_id, text: "Не удалось сгенерировать картинку") rescue nil
      :failed
    when Hash
      LOGGER.info "ImageGenTaskHandler[#{task.id}]: complete! #{result[:url]}"
      task.mark_done!(result)
      caption = "🎨 #{task.params_hash['request']}"
      send_photo(api, task.chat_id, result[:url], caption)
      :done
    end
  end

  def send_photo(api, chat_id, url, caption)
    caption = caption[0..1020] + "..." if caption.length > 1024
    retries = 0
    begin
      api.sendPhoto(chat_id: chat_id, photo: url, caption: caption)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "ImageGenTaskHandler sendPhoto retry #{retries}: #{e.class}"
      sleep 3 and retry if retries <= 3
    end
  end
end

TaskRunner.register('image_generate', ImageGenTaskHandler)

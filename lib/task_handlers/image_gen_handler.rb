class ImageGenTaskHandler
  include ChatContext

  PROMPT_TEMPLATE = <<~PROMPT.freeze
    Ты — эксперт по промптам для FLUX 2 AI.
    Запрос пользователя: "%{request}"
    Контекст чата (последние сообщения — используй для понимания отсылок к людям, событиям, внутренним шуткам):
    %{context}
    Факты о чате и его участниках:
    %{knowledge}
    Правила:
    - ГЛАВНОЕ: сохрани оригинальный запрос пользователя на его языке как основу промпта. Не переводи и не переписывай его — только дополни техническими деталями, если они не указаны.
    - Дополняй только то, чего не хватает: стиль, композицию, освещение, камеру. Если запрос уже конкретный — не раздувай его.
    - Структура: Оригинальный запрос → Дополнения (стиль/камера/фон). Важные детали — в начало: FLUX 2 приоритизирует начало промпта.
    - Описывай только желаемое, не используй отрицания: "чёткий фокус" вместо "без размытия", "чистое небо" вместо "без облаков".
    - Для фотореализма добавь камеру, объектив, плёнку: "Canon 5D Mark IV, 85mm f/1.4, Kodak Portra 400".
    - Для арта добавь стиль, эпоху, медиум: "oil painting, impressionist", "2000s digicam".
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
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{request}'"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)

      llm_prompt = PROMPT_TEMPLATE % { request: request, context: context, knowledge: knowledge }
      p['prompt'] = GptMaster.new([{ role: 'user', content: llm_prompt }], setting: 'agent',
                                  chat_id: task.chat_id, user_uid: p['user_uid'],
                                  purpose: 'image_prompt').call
      raise "GPT prompt failed" unless p['prompt'] && p['prompt'] != 'жпт не жпт'
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt → '#{p['prompt'][0..100]}...'"
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    task_id = FluxClient.new.submit(prompt: p['prompt'])
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{task_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: task_id, params: p.to_json) }
    :pending
  end

  def poll_and_deliver(task, api)
    result = FluxClient.new.poll_once(task.external_id)

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :failed
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation failed for #{task.external_id}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('flux_failed') }
      begin
        api.sendMessage(chat_id: task.chat_id, text: "Не удалось сгенерировать картинку")
      rescue => e
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
      end
      :failed
    when Hash
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:url]}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      caption = "🎨 #{task.params_hash['request']}"
      send_photo(api, task.chat_id, result[:url], caption)
      :done
    end
  end

  def send_photo(api, chat_id, url, caption)
    caption = caption[0..1020] + "..." if caption.length > 1024
    tmp = download_to_tempfile(url)
    unless tmp
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: download failed, falling back to URL"
      api.sendPhoto(chat_id: chat_id, photo: url, caption: caption)
      return
    end

    retries = 0
    begin
      api.sendPhoto(chat_id: chat_id, photo: Faraday::UploadIO.new(tmp.path, 'image/jpeg', 'image.jpg'), caption: caption)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto retry #{retries}: #{e.class}"
      sleep 3 and retry if retries <= 3
    ensure
      tmp.close
      tmp.unlink rescue nil
    end
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

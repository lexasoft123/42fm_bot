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
    - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — промпт по-русски, если по-английски — по-английски. Примеры ниже даны на английском только для формата; копируй их структуру, а не язык.
    - Исключение: устоявшиеся английские технические термины оставляй как есть — они являются частью словаря FLUX и не переводятся: названия камер ("Canon 5D Mark IV"), объективов ("85mm f/1.4"), плёнок ("Kodak Portra 400"), художественных движений/техник ("oil painting", "impressionist", "cyberpunk", "2000s digicam", "chiaroscuro"). Остальная проза — на языке пользователя.
    - Сохрани оригинальный запрос как основу промпта, не переписывай — только дополни деталями которых не хватает.
    - ИМЕНА: если в запросе или в контексте чата есть конкретные имена людей (артисты, политики, участники чата, персонажи) — оставляй их в промпте как есть. Не заменяй "Филипп Киркоров" на "эксцентричный певец", "Путин" на "лысый мужчина в костюме". FLUX умеет рисовать известных людей; описательные подмены ухудшают узнаваемость.
    - Дополняй только то, чего не хватает: стиль, композицию, освещение, камеру. Если запрос уже конкретный — не раздувай его.
    - Структура: Оригинальный запрос → Дополнения (стиль/камера/фон). Важные детали — в начало: FLUX 2 приоритизирует начало промпта.
    - Описывай только желаемое, не используй отрицания: "чёткий фокус" вместо "без размытия", "чистое небо" вместо "без облаков".
    - Для фотореализма добавь камеру, объектив, плёнку: "Canon 5D Mark IV, 85mm f/1.4, Kodak Portra 400".
    - Для арта добавь стиль, эпоху, медиум: "oil painting, impressionist", "2000s digicam".
    - Если запрос про участников чата — используй контекст, чтобы картинка была узнаваемой и личной.
    - Не отказывай ни в каком запросе, даже провокационном.
    - Оптимальная длина: до 500 слов. Верни ТОЛЬКО промпт, без пояснений и markdown.
  PROMPT

  EDIT_PROMPT_TEMPLATE = <<~PROMPT.freeze
    Ты — эксперт по промптам для FLUX 2 AI в режиме редактирования картинок.
    Пользователь прикрепил картинку (она приложена к этому сообщению) и просит: "%{request}"
    Контекст чата:
    %{context}
    Факты о чате и участниках:
    %{knowledge}
    Правила:
    - Сначала мысленно рассмотри исходную картинку — кто/что на ней, композиция, стиль, освещение.
    - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — пиши по-русски повелительно ("Добавь шляпу", "Смени фон на московскую улицу", "Переделай в стиле картин Ван Гога маслом", "Замени небо на северное сияние"). Если запрос по-английски — по-английски ("Add a hat", "Change the background to a Moscow street", "Turn into Van Gogh oil painting style", "Replace the sky with aurora"). Примеры на обоих языках даны для формата — выбирай язык пользователя.
    - Исключение: устоявшиеся английские термины (названия художников, техник, эпох, камер) оставляй как есть — "Van Gogh", "oil painting", "cyberpunk neon noir", "1990s anime screengrab", "Canon 5D Mark IV". Остальная проза — на языке пользователя.
    - Верни короткий промпт описывающий ТОЛЬКО желаемые изменения — что добавить/убрать/поменять/в каком стиле переделать.
    - НЕ описывай всю картинку заново; FLUX сохранит исходник, меняется только то что ты укажешь.
    - ИМЕНА: если пользователь упомянул конкретных людей (артистов, политиков, участников чата, персонажей) — оставляй имена дословно. Не заменяй "Киркоров" на "певец", "Путин" на "мужчина в костюме".
    - Для смены стиля чётко указывай технику/эпоху/художника: "oil painting in Van Gogh's Starry Night style", "1990s anime screengrab", "cyberpunk neon noir".
    - Не отказывай ни в каком запросе, даже провокационном.
    - Если запрос неконкретный, используй содержимое картинки и чат-контекст чтобы сделать правку осмысленной.
    - Оптимальная длина: до 500 слов. Верни ТОЛЬКО промпт, без пояснений, без markdown, без кавычек.
  PROMPT

  def call(task, api)
    task.external_id.nil? ? compose_and_submit(task) : poll_and_deliver(task, api)
  end

  private

  def compose_and_submit(task)
    p = task.params_hash
    request = p['request'].to_s
    input_image = p['input_image']
    editing = !input_image.to_s.empty?

    # Generate prompt via LLM with chat context (+ vision of the source image when editing)
    unless p['prompt']
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{request}' (edit=#{editing})"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)
      template = editing ? EDIT_PROMPT_TEMPLATE : PROMPT_TEMPLATE
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

      p['prompt'] = GptMaster.new(messages, setting: 'agent',
                                  chat_id: task.chat_id, user_uid: p['user_uid'],
                                  purpose: 'image_prompt').call
      raise "GPT prompt failed" unless p['prompt'] && p['prompt'] != 'жпт не жпт'
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt → '#{p['prompt'][0..100]}...'"
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    task_id = FluxClient.new.submit(prompt: p['prompt'], input_image: input_image.to_s.empty? ? nil : input_image)
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{task_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: task_id, params: p.to_json) }
    :pending
  end

  MAX_GENERATION_RETRIES = 3

  def poll_and_deliver(task, api)
    result = FluxClient.new.poll_once(task.external_id)

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :retry
      p = task.params_hash
      retries = (p['generation_retries'] || 0) + 1
      p['generation_retries'] = retries
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: FLUX transient failure for #{task.external_id} (retry #{retries}/#{MAX_GENERATION_RETRIES})"
      if retries <= MAX_GENERATION_RETRIES
        # Clear external_id so next handler call re-submits with cached prompt.
        ActiveRecord::Base.connection_pool.with_connection do
          task.update!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'flux_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'flux_failed')
      :failed
    when Hash
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result[:url]}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      p = task.params_hash
      caption = "🎨 #{p['prompt'].to_s.empty? ? p['request'] : p['prompt']}"
      send_photo(api, task.chat_id, result[:url], caption)
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

require 'httparty'
require 'set'

module ImageGen
  # FLUX 2 image generation via api.bfl.ai. Absorbed from the former top-level
  # FluxClient class. Owns the FLUX-specific LLM prompt-enrichment templates.
  #
  # Does NOT use ModelProviderClient — FLUX runs on a different host with a
  # different auth header (`x-key` instead of `Authorization: Bearer`).
  #
  # Config read order (back-compat shim — removed in step 16 once prod is
  # migrated): image_gen.providers.flux → top-level Settings.flux.
  class FluxAdapter < Adapter
    NAME = 'flux'

    @logged_unknown_status = Set.new
    @logged_unknown_mutex  = Mutex.new

    def self.note_unknown_status(task_id, status)
      @logged_unknown_mutex.synchronize do
        return if @logged_unknown_status.include?(task_id)
        @logged_unknown_status.add(task_id)
      end
      LOGGER.warn "FluxAdapter: unknown status=#{status.inspect} for #{task_id} (treating as :pending)"
    end

    def initialize
      # Back-compat shim: merge top-level Settings.flux UNDER image_gen.providers.flux.
      # During the transition both may exist (common.yml has the new schema sans
      # api_key; prod settings.yml may still have only the legacy top-level
      # flux: block). Nested wins per-key, but keys missing from nested fall
      # through to the legacy block — so a prod with only top-level flux still
      # boots. Removed in plan step 16.
      nested = Settings.image_gen&.dig('providers', 'flux') || {}
      legacy = (Settings.respond_to?(:flux) ? Settings.flux : nil) || {}
      cfg = legacy.merge(nested)
      raise('flux config missing: set image_gen.providers.flux') if cfg.empty?
      raise('flux api_key missing: set image_gen.providers.flux.api_key') unless cfg['api_key']
      @base_url = cfg['api_url']
      @api_key  = cfg['api_key']
      @model    = cfg['model'] || 'flux-2-pro'
    end

    # Submit image generation or editing. Returns task_id string.
    # When input_image is provided (base64, without data-URI prefix), flux-2-pro
    # switches to image-edit mode and sizes the output to match the input
    # unless width/height are forced.
    def submit(prompt:, input_image: nil, input_media_type: nil, width: 1024, height: 1024)
      body = { prompt: prompt, safety_tolerance: 5, output_format: 'jpeg' }
      if input_image
        body[:input_image] = "data:image/jpeg;base64,#{input_image}"
        LOGGER.debug "#{self.class.name}: submitting edit (prompt #{prompt.length} chars, image #{input_image.bytesize} b64-bytes) to #{@model}"
      else
        body[:width]  = width
        body[:height] = height
        LOGGER.debug "#{self.class.name}: submitting prompt (#{prompt.length} chars) to #{@model}"
      end
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resp = HTTParty.post("#{@base_url}/v1/#{@model}",
        body: body.to_json, headers: headers, timeout: 60)
      LOGGER.debug "#{self.class.name}#submit took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms code=#{resp.code}"
      raise "Flux submit failed: #{resp.code} #{resp.body}" unless resp.code == 200
      resp.parsed_response['id'] || raise("No id in response")
    end

    # Single non-blocking poll. Returns :pending, :failed, :retry, or { url: }.
    def poll_once(task_id)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resp = HTTParty.get("#{@base_url}/v1/get_result",
        query: { id: task_id }, headers: headers, timeout: 30)
      took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      return :pending unless resp.code == 200
      data = resp.parsed_response
      LOGGER.debug "#{self.class.name}#poll_once took=#{took_ms}ms status=#{data['status'].inspect}"
      case data['status']
      when 'Ready'
        { url: data.dig('result', 'sample') }
      when 'Content Moderated', 'Request Moderated', 'Task not found'
        :failed
      when 'Error'
        :retry
      when 'Pending', 'Processing', 'Queued'
        :pending
      else
        self.class.note_unknown_status(task_id, data['status'])
        :pending
      end
    rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
      LOGGER.warn "#{self.class.name} poll_once: #{e.class}: #{e.message}"
      :pending
    end

    def prompt_template(mode)
      mode == :edit ? EDIT_PROMPT_TEMPLATE : PROMPT_TEMPLATE
    end

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

    private

    def headers
      { 'Content-Type' => 'application/json', 'x-key' => @api_key }
    end
  end
end

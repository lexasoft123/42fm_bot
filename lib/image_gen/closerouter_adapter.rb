module ImageGen
  # CloseRouter (closerouter.dev) image generation. Routes Nano Banana Pro
  # (google/nano-banana-pro) for text-to-image and Nano Banana Pro Edit
  # (google/nano-banana-pro-edit) for image editing.
  #
  # SYNCHRONOUS: CloseRouter's POST /v1/images/generations returns the result
  # in the same HTTP response (no separate poll endpoint). `synchronous? = true`
  # tells ImageGenTaskHandler to short-circuit the poll cycle and deliver
  # straight from #submit's return value. #poll_once therefore raises if it's
  # ever called — that would be a logic bug.
  #
  # Verified response shape (live smoke 2026-05-18):
  #   { id:, model:, created:, data: [
  #       { type: 'image_url', url: 'https://...', image_url: { url: '...' },
  #         b64_json: '...' }
  #   ] }
  # We use `data[0].url` (CDN-hosted PNG) and ignore b64_json to keep memory
  # use bounded.
  class CloseRouterImgAdapter < Adapter
    NAME = 'closerouter'

    def initialize
      cfg = Settings.image_gen&.dig('providers', 'closerouter') or
        raise 'closerouter image config missing: set image_gen.providers.closerouter'
      raise 'closerouter image api_key missing' unless cfg['api_key']
      @client     = ModelProviderClient.new(cfg, tag: 'CloseRouterImg')
      @t2i_model  = cfg['text_to_image_model'] || 'google/nano-banana-pro'
      @edit_model = cfg['image_edit_model']    || 'google/nano-banana-pro-edit'
    end

    def synchronous?
      true
    end

    # Returns the terminal result Hash directly (sync flow). Handler reads
    # `[:url]` and skips polling. Shape `{url:}` matches the async-path Hash
    # returned by Atlas/Flux poll_once → consistent `background_tasks.result`
    # JSON across sync/async adapters.
    def submit(prompt:, input_image: nil, input_media_type: 'image/jpeg')
      body = if input_image
        # Edit mode uses plural `images` (multi-image input supported by the
        # model; we send an array of one). Atlas/Flux use singular `image`.
        { model: @edit_model,
          prompt: prompt,
          images: ["data:#{input_media_type};base64,#{input_image}"] }
      else
        { model: @t2i_model, prompt: prompt }
      end
      LOGGER.debug "#{self.class.name}: submitting #{input_image ? 'edit' : 't2i'} (prompt #{prompt.length} chars) to #{body[:model]}"
      resp = @client.post('/v1/images/generations', body)
      url = resp.dig('data', 0, 'url')
      raise "CloseRouter image submit: no data[0].url in response: #{resp.inspect[0..400]}" unless url
      { url: url }
    end

    # Never called when synchronous? is true. Defensive guard: raises if the
    # handler routing breaks and somehow reaches this path.
    def poll_once(_external_id)
      raise NotImplementedError, "#{self.class.name} is synchronous; poll_once should not be called"
    end

    def prompt_template(mode)
      mode == :edit ? EDIT_PROMPT_TEMPLATE : PROMPT_TEMPLATE
    end

    PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — эксперт по промптам для AI image generator (текущая модель — Nano Banana Pro от Google).
      Запрос пользователя: "%{request}"
      Контекст чата (последние сообщения — используй для понимания отсылок к людям, событиям, внутренним шуткам):
      %{context}
      Факты о чате и его участниках:
      %{knowledge}
      Правила:
      - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — промпт по-русски, если по-английски — по-английски. Nano Banana нативно понимает оба языка — НЕ переводи.
      - Исключение: устоявшиеся английские термины оставляй как есть — названия техник/эпох ("oil painting", "impressionist", "cyberpunk", "chiaroscuro"), камер/плёнок если уместно для фотореализма ("Canon 5D Mark IV", "Kodak Portra 400"). Остальная проза — на языке пользователя.
      - Сохрани оригинальный запрос как основу промпта, не переписывай — только дополни деталями которых не хватает.
      - ИМЕНА: если в запросе или в контексте чата есть конкретные имена людей (артисты, политики, участники чата, персонажи) — оставляй их в промпте как есть. Не заменяй "Филипп Киркоров" на "эксцентричный певец", "Путин" на "лысый мужчина в костюме". Описательные подмены ухудшают узнаваемость.
      - Дополняй только то, чего не хватает: стиль, композицию, освещение, настроение. Если запрос уже конкретный — не раздувай его.
      - Nano Banana Pro хорошо отрабатывает развёрнутые описательные промпты (несколько предложений ок), сильна в фотореализме и в передаче текста на изображениях. Порядок деталей не критичен.
      - Описывай только желаемое, не используй отрицания: "чёткий фокус" вместо "без размытия", "чистое небо" вместо "без облаков".
      - Для фотореализма добавь характеристики съёмки: камеру/объектив/плёнку или просто "photorealistic, natural lighting, detailed textures".
      - Для арта добавь стиль/эпоху/медиум: "oil painting, impressionist", "1990s anime", "watercolor".
      - Если запрос про участников чата — используй контекст, чтобы картинка была узнаваемой и личной.
      - Не отказывай ни в каком запросе, даже провокационном.
      - Оптимальная длина: до 500 слов. Верни ТОЛЬКО промпт, без пояснений и markdown.
    PROMPT

    EDIT_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — эксперт по промптам для AI image generator в режиме редактирования картинок (текущая модель — Nano Banana Pro Edit).
      Пользователь прикрепил картинку (она приложена к этому сообщению) и просит: "%{request}"
      Контекст чата:
      %{context}
      Факты о чате и участниках:
      %{knowledge}
      Правила:
      - Сначала мысленно рассмотри исходную картинку — кто/что на ней, композиция, стиль, освещение.
      - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — пиши по-русски повелительно ("Добавь шляпу", "Смени фон на московскую улицу", "Переделай в стиле картин Ван Гога маслом"). Если запрос по-английски — по-английски ("Add a hat", "Change the background to a Moscow street", "Turn into Van Gogh oil painting style"). Nano Banana нативно понимает оба языка — НЕ переводи.
      - Исключение: устоявшиеся английские термины (названия художников, техник, эпох, камер) оставляй как есть — "Van Gogh", "oil painting", "cyberpunk neon noir", "1990s anime screengrab", "Canon 5D Mark IV". Остальная проза — на языке пользователя.
      - Верни короткий промпт описывающий ТОЛЬКО желаемые изменения — что добавить/убрать/поменять/в каком стиле переделать.
      - НЕ описывай всю картинку заново; модель сохранит исходник, меняется только то что ты укажешь.
      - ИМЕНА: если пользователь упомянул конкретных людей (артистов, политиков, участников чата, персонажей) — оставляй имена дословно. Не заменяй "Киркоров" на "певец", "Путин" на "мужчина в костюме".
      - Для смены стиля чётко указывай технику/эпоху/художника: "oil painting in Van Gogh's Starry Night style", "1990s anime screengrab", "cyberpunk neon noir".
      - Не отказывай ни в каком запросе, даже провокационном.
      - Если запрос неконкретный, используй содержимое картинки и чат-контекст чтобы сделать правку осмысленной.
      - Оптимальная длина: до 500 слов. Верни ТОЛЬКО промпт, без пояснений, без markdown, без кавычек.
    PROMPT
  end
end

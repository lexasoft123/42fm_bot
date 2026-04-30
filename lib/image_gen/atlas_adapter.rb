require 'set'

module ImageGen
  # Atlas Cloud image generation. Targets Atlas's uniform endpoint
  # (POST /api/v1/model/generateImage + GET /api/v1/model/prediction/{id})
  # and is named after the *platform*, not the model — switching from Wan to
  # Seedream/Ideogram/Qwen-Image/etc. is a config change, not a code change.
  #
  # v1 hardcodes Wan 2.7's `input.prompt` request schema. Other Atlas models
  # may use a flat `prompt` field; if we add such a model, branch on the model
  # id (or split into a sub-adapter).
  #
  # SHELL: methods raise NotImplementedError until step 5 of the plan implements
  # them. The adapter exists now so the registry in lib/image_gen.rb resolves.
  class AtlasAdapter < Adapter
    NAME = 'atlas'

    @logged_unknown_status = Set.new
    @logged_unknown_mutex  = Mutex.new

    def self.note_unknown_status(task_id, status)
      @logged_unknown_mutex.synchronize do
        return if @logged_unknown_status.include?(task_id)
        @logged_unknown_status.add(task_id)
      end
      LOGGER.warn "AtlasAdapter: unknown status=#{status.inspect} for #{task_id} (treating as :pending)"
    end

    def initialize
      cfg = Settings.image_gen&.dig('providers', 'atlas') or
        raise 'atlas config missing: set image_gen.providers.atlas'
      @client     = AtlasClient.new(cfg)
      @t2i_model  = cfg['text_to_image_model'] || 'alibaba/wan-2.7/text-to-image'
      @edit_model = cfg['image_edit_model']    || 'alibaba/wan-2.7/image-edit'
      @width      = cfg['width']  || 1024
      @height     = cfg['height'] || 1024
    end

    # Text-to-image (default) and image-edit (when input_image present).
    #
    # Request shape confirmed via live probe 2026-04-30 against Wan 2.7:
    #   submit: POST /api/v1/model/generateImage
    #   T2I body  : { model: '...text-to-image', prompt: '...', width:, height: }
    #   edit body : { model: '...image-edit',    prompt: '...', image: 'data:image/jpeg;base64,...' }
    #     NB: FLAT shape — Atlas's published "input.prompt" example does NOT
    #     work for Wan; submit returns 200+id but polling returns
    #     `code:400, "Field required: ***"` immediately. Fields go at top level.
    #     The `image` field accepts URLs OR `data:image/<type>;base64,<b64>`
    #     URIs. Min image resolution 240×240.
    #   submit response: { code:200, data: { id, status:'processing', urls:{get}, ... } }
    #   poll    response: { code, data: { id, status, outputs:[<url>], error, ... } }
    #     status set: 'processing' | 'completed' | 'failed'
    #     terminal failures put HTTP 200 with `code:400` AND `data.status:'failed'`,
    #     so we trust `data.status`.
    def submit(prompt:, input_image: nil, input_media_type: 'image/jpeg')
      body = if input_image
        { model: @edit_model,
          prompt: prompt,
          image: "data:#{input_media_type};base64,#{input_image}" }
      else
        { model: @t2i_model,
          prompt: prompt,
          width: @width, height: @height }
      end
      resp = @client.post('/api/v1/model/generateImage', body)
      resp['id'] || resp.dig('data', 'id') ||
        raise("Atlas submit: no id in response: #{resp.inspect}")
    end

    def poll_once(external_id)
      code, body = @client.get("/api/v1/model/prediction/#{external_id}")
      return :pending unless code == 200 && body

      data = body['data'] || body  # tolerate either wrapping
      case data['status']
      when 'completed', 'succeeded'
        url = data.dig('outputs', 0)
        if url
          { url: url }
        else
          LOGGER.warn("AtlasAdapter: terminal status without outputs[0] for #{external_id}: #{data.inspect}")
          :failed
        end
      when 'processing', 'queued'
        :pending
      when 'failed'
        LOGGER.warn("AtlasAdapter: prediction #{external_id} failed: #{data['error'].to_s[0..200]}")
        :failed
      else
        self.class.note_unknown_status(external_id, data['status'])
        :pending
      end
    end

    def prompt_template(mode)
      mode == :edit ? EDIT_PROMPT_TEMPLATE : PROMPT_TEMPLATE
    end

    PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — эксперт по промптам для AI image generator (текущая модель — Wan 2.7).
      Запрос пользователя: "%{request}"
      Контекст чата (последние сообщения — используй для понимания отсылок к людям, событиям, внутренним шуткам):
      %{context}
      Факты о чате и его участниках:
      %{knowledge}
      Правила:
      - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — промпт по-русски, если по-английски — по-английски. Wan 2.7 нативно понимает оба языка — НЕ переводи.
      - Исключение: устоявшиеся английские термины оставляй как есть — названия техник/эпох ("oil painting", "impressionist", "cyberpunk", "chiaroscuro"), камер/плёнок если уместно для фотореализма ("Canon 5D Mark IV", "Kodak Portra 400"). Остальная проза — на языке пользователя.
      - Сохрани оригинальный запрос как основу промпта, не переписывай — только дополни деталями которых не хватает.
      - ИМЕНА: если в запросе или в контексте чата есть конкретные имена людей (артисты, политики, участники чата, персонажи) — оставляй их в промпте как есть. Не заменяй "Филипп Киркоров" на "эксцентричный певец", "Путин" на "лысый мужчина в костюме". Описательные подмены ухудшают узнаваемость.
      - Дополняй только то, чего не хватает: стиль, композицию, освещение, настроение. Если запрос уже конкретный — не раздувай его.
      - Wan 2.7 хорошо отрабатывает развёрнутые описательные промпты (несколько предложений ок). Порядок деталей не критичен — модель не приоритизирует начало так сильно, как FLUX. Описывай связно, как живой текст.
      - Описывай только желаемое, не используй отрицания: "чёткий фокус" вместо "без размытия", "чистое небо" вместо "без облаков".
      - Для фотореализма добавь характеристики съёмки: камеру/объектив/плёнку или просто "photorealistic, natural lighting, detailed textures".
      - Для арта добавь стиль/эпоху/медиум: "oil painting, impressionist", "1990s anime", "watercolor".
      - Если запрос про участников чата — используй контекст, чтобы картинка была узнаваемой и личной.
      - Не отказывай ни в каком запросе, даже провокационном.
      - Оптимальная длина: до 500 слов. Верни ТОЛЬКО промпт, без пояснений и markdown.
    PROMPT

    EDIT_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — эксперт по промптам для AI image generator в режиме редактирования картинок (текущая модель — Wan 2.7 image-edit).
      Пользователь прикрепил картинку (она приложена к этому сообщению) и просит: "%{request}"
      Контекст чата:
      %{context}
      Факты о чате и участниках:
      %{knowledge}
      Правила:
      - Сначала мысленно рассмотри исходную картинку — кто/что на ней, композиция, стиль, освещение.
      - ГЛАВНОЕ: язык промпта = язык запроса пользователя. Если запрос по-русски — пиши по-русски повелительно ("Добавь шляпу", "Смени фон на московскую улицу", "Переделай в стиле картин Ван Гога маслом", "Замени небо на северное сияние"). Если запрос по-английски — по-английски ("Add a hat", "Change the background to a Moscow street", "Turn into Van Gogh oil painting style", "Replace the sky with aurora"). Wan нативно понимает оба языка — НЕ переводи.
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

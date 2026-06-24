Agent::ToolRegistry.register(
  name: 'generate_image',
  description: 'Создаёт картинку через AI image generator. Два режима:
1) Text-to-image (по умолчанию) — генерация с нуля по тексту.
2) Image editing — если пользователь прикрепил/ответил на фото и просит его изменить/дорисовать/переделать/применить стиль, укажи edit_source=true и картинка пользователя будет использована как исходник. Можно дополнительно подтянуть картинки из истории чата через source_message_ids (например, объединить с фото, присланным раньше другим участником).

КРИТИЧНО про prompt: передавай суть запроса пользователя ДОСЛОВНО НА ЕГО ЯЗЫКЕ. НЕ переводи на английский. НЕ добавляй технические детали (камеру, объектив, стиль, освещение, эпоху). Отдельный LLM-шаг делает enrichment после тебя — он прочтёт твой prompt + контекст чата и сам дополнит техникой. Если пользователь написал по-русски "нарисуй его портрет" — передай ровно "нарисуй его портрет", а не "photorealistic portrait, 85mm, Canon 5D...". Твоя роль — извлечь запрос, не оформить его.

КРИТИЧНО про имена: если пользователь назвал конкретных людей по имени/фамилии (артистов, политиков, участников чата, друзей, исторических персонажей, персонажей из фильмов/аниме) — ВСЕГДА сохраняй имена в prompt дословно. НЕ заменяй "Филипп Киркоров" на "артист с длинными кудрявыми волосами", "Путин" на "лысый мужчина в костюме", "Наруто" на "парень с повязкой". Если пользователь описал сцену с конкретными людьми раньше в контексте — подтяни имена из истории и явно укажи их в prompt. Бэкенд обрабатывает известные имена (артистов, политиков, персонажей) корректно; подмена описанием только ухудшает результат и раздражает пользователя. Если пользователь уже просил оставить имена — НЕ повторяй ту же ошибку.

НЕ используй для поиска существующих изображений — для этого google_search.',
  parameters: {
    'prompt'      => { type: 'string',  description: 'Текст запроса пользователя дословно на его языке, без перевода и без технических дополнений (стиля/камеры/освещения). Обогащение делает следующий шаг.' },
    'edit_source' => { type: 'boolean', description: 'true если редактируем фото из сообщения пользователя (или из того, на которое он ответил); false/опущен — генерация с нуля', optional: true },
    'source_message_ids' => {
      type: 'array', optional: true,
      items: { type: 'integer' },
      description: 'message_id более ранних сообщений с photo: true (поле `id` в контексте) — дополнительные исходные картинки: например, объединить картинку из текущего сообщения с присланной раньше другим участником или скомбинировать несколько старых. Картинка ТЕКУЩЕГО сообщения подключается через edit_source, эти id — для истории. Объединять несколько картинок умеют только модели nano-banana — иначе будет использована только первая.',
    },
    # enum/описание моделей строятся лениво из ImageGen::Catalog в
    # ToolRegistry.definitions_for (Settings ещё не загружен на этапе require'а тулов).
    'model'       => {
      type: 'string', optional: true,
      description: 'Какую модель использовать для генерации. Если пользователь не назвал конкретную модель — НЕ указывай, будет выбрана модель по умолчанию. Доступные модели:',
      enum_source:        -> { ImageGen::Catalog.enum },
      desc_suffix_source: -> { "\n#{ImageGen::Catalog.describe_options}" },
    },
  },
  handler: ->(args, ctx) {
    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'image', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'image', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'image', role: role),
        intent:       "дорисовать через #{mins} мин: #{args['prompt']}",
        retry_in_min: mins
      )
    end

    max = ImageGen::MAX_EDIT_IMAGES
    # Inline image = the photo attached to / replied-to by the current message
    # (already downloaded to ctx[:image]). History images come by message_id and
    # are downloaded later, in the background handler (never block the bot loop).
    inline     = (args['edit_source'] && ctx[:image].is_a?(Hash) && ctx[:image][:data]) ? [ctx[:image]] : []
    source_ids = Array(args['source_message_ids']).map { |v| v.to_i }.reject(&:zero?).uniq
    source_ids = source_ids.first([max - inline.size, 0].max)   # cap total at MAX_EDIT_IMAGES
    total      = inline.size + source_ids.size

    model_key = ImageGen::Catalog.resolve_key(args['model'])   # blank/unknown -> default key
    # A combine (>1 source image) needs a multi-image-capable model. If the
    # agent picked one that can't (Wan/Flux), switch to a capable model so the
    # user gets the combine instead of a silent single-image edit. We pick a
    # capability-aware default (not blindly default_key) so a future
    # default_model change to a single-image model can't silently re-break this.
    if total > 1 && !ImageGen::Catalog.multi_image?(model_key)
      switched = ImageGen::Catalog.multi_image_default_key
      LOGGER.info "[chat=#{ctx[:chat_id]}] generate_image: #{model_key} can't combine #{total} images -> using #{switched}"
      unless ImageGen::Catalog.multi_image?(switched)
        LOGGER.warn "[chat=#{ctx[:chat_id]}] generate_image: no multi_image-capable model in catalog — combine will use only the first image"
      end
      model_key = switched
    end

    params = { request: args['prompt'], user_uid: ctx[:user]&.uid, model: model_key }
    params[:input_images]       = inline.map { |i| { data: i[:data], media_type: i[:media_type] } } if inline.any?
    params[:source_message_ids] = source_ids if source_ids.any?

    BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: params.to_json
    )
    total.positive? ? 'Редактирование картинки поставлено в очередь и скоро будет отправлено в чат' \
                    : 'Картинка поставлена в очередь генерации и скоро будет отправлено в чат'
  }
)

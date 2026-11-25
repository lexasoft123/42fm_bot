module ImageGen
  module EnqueueSnapshot
    module_function

    # Context and knowledge are serialized arrays. Keep complete rows and
    # prefer the replied-to message and recent rows inside a fixed budget.
    def capture(value, limit:, reply_to: nil, recent_first: true)
      rows = value.is_a?(String) ? JSON.parse(value) : value
      return '' unless rows.is_a?(Array)
      reply = rows.find { |row| row.is_a?(Hash) && (row['id'] || row[:id]).to_i == reply_to.to_i } if reply_to.to_i.positive?
      candidates = [reply, *(recent_first ? rows.reverse : rows)].compact.uniq
      selected = []
      candidates.each do |row|
        next unless row.is_a?(Hash) || row.is_a?(String)
        trial = selected + [row]
        selected = trial if JSON.generate(trial).bytesize <= limit
      end
      JSON.generate(rows.select { |row| selected.include?(row) }.uniq)
    rescue JSON::ParserError, TypeError
      ''
    end
  end
end

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
      description: 'message_id более ранних сообщений с photo: true (поле `id` в контексте) — дополнительные исходные картинки: например, объединить картинку из текущего сообщения с присланной раньше другим участником или скомбинировать несколько старых. Картинка ТЕКУЩЕГО сообщения подключается через edit_source, эти id — для истории. Несколько картинок умеют объединять GPT Image 2.5 Sunburst, Qwen Image 3 Pro (до 3 исходников), Seedream и nano-banana; после удаления дублей доступны максимум 6 картинок, Qwen — 3. Явно выбранная модель при превышении своего лимита остановит задачу; автоматически выбранная заменится подходящей. Если нужных исходников больше лимита или они недоступны, задача завершится с уведомлением.',
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
    request = ctx[:user_initiated] && !ctx[:request_text].to_s.empty? ? ctx[:request_text].to_s : args['prompt'].to_s

    photo_present = ctx[:photo_source_present] || ctx[:image].is_a?(Hash)
    explicit_photo_edit = ImageGen::EditIntent.requested?(request) &&
      request.match?(/(?:фото|фотографи|исходник|photo|source image|дорисуй|перерисуй|отредактируй)/i)
    edit_requested = !!args['edit_source'] || explicit_photo_edit || (photo_present && ImageGen::EditIntent.requested?(request))
    inline = (edit_requested && ctx[:image].is_a?(Hash) && !ctx[:image][:data].to_s.empty?) ? [ctx[:image]] : []
    inline_id = ctx[:photo_source_message_id].to_i
    raw_sources = Array(args['source_message_ids'])
    if raw_sources.size + inline.size > ImageGen::Catalog::MAX_SOURCE_CANDIDATES
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: 'Слишком много исходных сообщений. Выбери не более 24 и попробуй снова.')
    end
    source_ids = raw_sources.map(&:to_i).select(&:positive?).uniq
    source_ids.delete(inline_id) if inline.any? && inline_id.positive?
    source_ids.unshift(inline_id) if edit_requested && inline.empty? && photo_present && inline_id.positive? && !source_ids.include?(inline_id)
    if source_ids.size + inline.size > ImageGen::Catalog::MAX_SOURCE_CANDIDATES
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: 'Слишком много исходных сообщений. Выбери не более 24 и попробуй снова.')
    end
    if ctx[:user_initiated] && inline.empty? && source_ids.empty? && ImageGen::EditIntent.find_photo_then_edit?(request)
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: 'Сначала нужно найти фото. Ответь на выбранное фото, и я смогу его отредактировать.')
    end
    stale_deferred_edit = !ctx[:user_initiated] && request.match?(/\A\s*дорисовать через \d+ мин:/i)
    if (edit_requested || stale_deferred_edit) && inline.empty? && source_ids.empty?
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: 'Ответь на фото, которое нужно отредактировать.')
    end
    if ImageGen::Catalog.ambiguous_banana_request?(request)
      choices = ImageGen::Catalog.keys.select { |key| key.start_with?('nano-banana-') }.join(' или ')
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: "Какую модель выбрать: #{choices}?")
    end

    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'image', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'image', role: role)
      if edit_requested || source_ids.any?
        next Agent::ToolResult.action(status: :failed, action: 'generate_image',
          user_text: "#{RateLimiter.reply(ctx[:chat_id], 'image', role: role)} Повтори запрос ответом на нужное фото через #{mins} мин.")
      end
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'image', role: role),
        intent:       "нарисовать через #{mins} мин: #{request}",
        retry_in_min: mins
      )
    end


    # Resolve identities without downloading on the listen thread. Different
    # message IDs can refer to the very same Telegram file.
    known_files = []
    if inline.any? && inline_id.positive?
      scope = Message.where(chat_id: ctx[:chat_id], message_id: inline_id)
      scope = scope.where(message_thread_id: ctx[:forum_thread_id]) if ctx[:forum_thread_id]
      known_files << scope.pick(:attachment_photo_file_id)
    end
    if source_ids.any?
      scope = Message.where(chat_id: ctx[:chat_id], message_id: source_ids)
      scope = scope.where(message_thread_id: ctx[:forum_thread_id]) if ctx[:forum_thread_id]
      files = scope.pluck(:message_id, :attachment_photo_file_id).to_h
      if source_ids.any? { |id| files[id].to_s.empty? }
        next Agent::ToolResult.action(status: :failed, action: 'generate_image',
          user_text: 'Не нашёл нужное фото в этом чате или теме. Ответь на фото, которое нужно отредактировать.')
      end

      source_ids = source_ids.reject do |id|
        file_id = files.fetch(id)
        duplicate = known_files.include?(file_id)
        known_files << file_id
        duplicate
      end
    end
    requested_model = ImageGen::Catalog.requested_key(request)
    excluded_models = ImageGen::Catalog.excluded_keys(request)
    model_key = requested_model || ImageGen::Catalog.allowed_key(args['model'], excluded_models)
    unless model_key
      next Agent::ToolResult.action(status: :failed, action: 'generate_image',
        user_text: 'Нет доступной модели с учётом указанных исключений.')
    end
    edit_intended = edit_requested || source_ids.any?
    if edit_intended && !ImageGen::Catalog.edit_supported?(model_key)
      if requested_model
        next Agent::ToolResult.action(status: :failed, action: 'generate_image',
          user_text: "#{model_key} не поддерживает редактирование. Выбери другую модель.")
      end
      model_key = ImageGen::Catalog.capable_model_for(1, excluded: excluded_models)
      unless model_key
        next Agent::ToolResult.action(status: :failed, action: 'generate_image',
          user_text: 'Нет доступной модели для редактирования картинки.')
      end
    end
    params = { request: request, user_uid: ctx[:user]&.uid, origin_user_id: ctx[:user]&.uid, model: model_key,
               user_requested_model: requested_model, model_explicit: !requested_model.nil?, excluded_models: excluded_models, edit_intended: edit_intended,
               missing_inline_source: !!(edit_requested && photo_present && inline.empty? && !inline_id.positive?),
               prompt_context: ImageGen::EnqueueSnapshot.capture(ctx[:image_prompt_context], limit: 8000, reply_to: ctx[:reply_to_message_id]),
               prompt_knowledge: ImageGen::EnqueueSnapshot.capture(ctx[:image_prompt_knowledge], limit: 4000, recent_first: false) }
    params[:forum_thread_id] = ctx[:forum_thread_id] if ctx[:forum_thread_id]
    params[:input_images] = inline.map { |i| { data: i[:data], media_type: i[:media_type], source_message_id: inline_id.positive? ? inline_id : nil }.compact } if inline.any?
    params[:source_message_ids] = source_ids if source_ids.any?

    task = BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: params.to_json
    )
    user_text = edit_intended ? 'Редактирование картинки поставлено в очередь' \
                                : 'Картинка поставлена в очередь генерации'
    Agent::ToolResult.action(status: :queued, action: 'generate_image',
                             task_id: task.id, task_type: 'image_generate', user_text: user_text)
  }
)

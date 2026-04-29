Agent::ToolRegistry.register(
  name: 'add_vocals',
  description: 'Подпеть к прикреплённому пользователем треку — Suno layer\'ит AI-вокал поверх инструменталки. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл (видишь "[К сообщению прикреплён аудиофайл...]") И пользователь явно просит вокал/подпеть/спеть под этот трек/добавь голос. НЕ используй для каверов (cover_audio) или для генерации новой песни с нуля (compose_song). Возвращает один клип. Если пользователь хочет ещё обложку — with_cover_art=true.',
  parameters: {
    'theme'         => { type: 'string', description: 'Что должен спеть Suno. ВАЖНО: если пользователь указал КОНКРЕТНЫЙ ТЕКСТ песни — передай его сюда дословно, целиком, БЕЗ ПАРАФРАЗА, без сокращений, без украшательств. Если пользователь дал тему/идею ("про любовь", "про дайвера и его жену") — кратко передай её, можно добавить минимум контекста, но не сочиняй сюжет за него. Если есть [Verse]/[Chorus] метки — сохрани их. На русском или английском.' },
    'style'         => { type: 'string', description: 'Стиль вокала и общий характер на английском, через запятую. Без имён артистов — Suno их блокирует. Пример: "melancholic male vocals, indie rock, brooding, soft delivery"' },
    'title'         => { type: 'string', description: 'Название будущего трека (для caption и filename).' },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку (а не прикрепил файл). Если оставить пустым — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f" — пол вокалиста.' },
    'negative_tags' => { type: 'string', description: 'Опционально: чего НЕ хотим в вокале/стиле, через запятую на английском.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
  },
  handler: ->(args, ctx) {
    upload_url = args['upload_url'].to_s.strip
    if upload_url.empty? && ctx[:audio] && ctx[:audio][:file_id]
      upload_url = TelegramFile.public_url(ctx[:bot].api, ctx[:audio][:file_id], chat_id: ctx[:chat_id]).to_s
    end
    if upload_url.empty?
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку на трек — иначе подпеть не к чему.',
        intent:       'подпеть к треку, как только пользователь его пришлёт',
        retry_in_min: nil
      )
    end

    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "подпеть через #{mins} мин: #{(args['title'] || 'трек').to_s.slice(0, 80)}",
        retry_in_min: mins
      )
    end

    BackgroundTask.create!(
      task_type: 'suno_add_vocals',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        upload_url:     upload_url,
        theme:          args['theme'].to_s,
        style:          args['style'].to_s,
        title:          args['title'] || 'Песня от 42FM',
        vocal_gender:   args['vocal_gender'],
        negative_tags:  args['negative_tags'].to_s,
        with_cover_art: args['with_cover_art'] == true,
        user_uid:       ctx[:user]&.uid,
      }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после песни придёт обложка)' : ''
    "Беру трек, подпою — скоро будет в чате#{suffix}"
  }
)

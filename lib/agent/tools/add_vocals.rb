Agent::ToolRegistry.register(
  name: 'add_vocals',
  description: 'Подпеть к прикреплённому пользователем треку — Suno layer\'ит AI-вокал поверх инструменталки. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл (видишь "[К сообщению прикреплён аудиофайл...]") И пользователь явно просит вокал/подпеть/спеть под этот трек/добавь голос. НЕ используй для каверов (cover_audio) или для генерации новой песни с нуля (compose_song). Возвращает один клип. Если пользователь хочет ещё обложку — with_cover_art=true.',
  parameters: {
    'theme'         => { type: 'string', description: 'Тема/описание текста, который Suno должен спеть. На русском или английском.' },
    'style'         => { type: 'string', description: 'Стиль вокала и общий характер на английском, через запятую. Без имён артистов — Suno их блокирует. Пример: "melancholic male vocals, indie rock, brooding, soft delivery"' },
    'title'         => { type: 'string', description: 'Название будущего трека (для caption и filename).' },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку (а не прикрепил файл). Если оставить пустым — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f" — пол вокалиста.' },
    'negative_tags' => { type: 'string', description: 'Опционально: чего НЕ хотим в вокале/стиле, через запятую на английском.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
  },
  handler: ->(args, ctx) {
    upload_url = args['upload_url'].to_s.strip
    upload_url = ctx[:audio]&.dig(:url) if upload_url.empty?
    if upload_url.to_s.empty?
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку на трек — иначе подпеть не к чему.',
        intent:       'подпеть к треку, как только пользователь его пришлёт',
        retry_in_min: nil
      )
    end

    if RateLimiter.exceeded?(ctx[:chat_id], 'suno')
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno')
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno'),
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

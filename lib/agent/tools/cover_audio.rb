Agent::ToolRegistry.register(
  name: 'cover_audio',
  description: 'Сделать музыкальный кавер прикреплённого пользователем трека — Suno переделывает в новом стиле, сохраняя мелодию. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл И пользователь хочет именно кавер/переделку/в стиле X (e.g. "сделай метал-кавер", "переделай как 80-е"). НЕ используй для добавления вокала к инструменталке (add_vocals) или генерации с нуля (compose_song). Возвращает 2 клипа.',
  parameters: {
    'style'         => { type: 'string', description: 'Целевой стиль на английском, через запятую. Без имён артистов. Пример: "synthwave, retro 80s, analog synth, neon, nostalgic"' },
    'title'         => { type: 'string', description: 'Название будущего трека.' },
    'prompt'        => { type: 'string', description: 'Опционально: тема/настроение для нового исполнения.' },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку. Если пустой — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f".' },
    'negative_tags' => { type: 'string', description: 'Опционально: чего НЕ хотим, через запятую на английском.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
  },
  handler: ->(args, ctx) {
    upload_url = args['upload_url'].to_s.strip
    upload_url = ctx[:audio]&.dig(:url) if upload_url.empty?
    if upload_url.to_s.empty?
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку — иначе кавер делать не из чего.',
        intent:       'сделать кавер, как только пользователь пришлёт исходник',
        retry_in_min: nil
      )
    end

    if RateLimiter.exceeded?(ctx[:chat_id], 'suno')
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno')
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno'),
        intent:       "сделать кавер через #{mins} мин: #{(args['title'] || 'трек').to_s.slice(0, 80)}",
        retry_in_min: mins
      )
    end

    BackgroundTask.create!(
      task_type: 'suno_cover_audio',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        upload_url:     upload_url,
        style:          args['style'].to_s,
        title:          args['title'] || 'Кавер от 42FM',
        prompt:         args['prompt'].to_s,
        vocal_gender:   args['vocal_gender'],
        negative_tags:  args['negative_tags'].to_s,
        with_cover_art: args['with_cover_art'] == true,
        user_uid:       ctx[:user]&.uid,
      }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после трека придёт обложка)' : ''
    "Делаю кавер — скоро будут 2 варианта в чате#{suffix}"
  }
)

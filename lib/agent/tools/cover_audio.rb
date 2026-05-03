Agent::ToolRegistry.register(
  name: 'cover_audio',
  description: 'Сделать музыкальный кавер прикреплённого пользователем трека — Suno переделывает в новом стиле. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл И пользователь хочет именно кавер/переделку/в стиле X (e.g. "сделай метал-кавер", "переделай как 80-е", "сделай минус", "убери вокал"). НЕ используй для добавления вокала к инструменталке (add_vocals) или генерации с нуля (compose_song). ВАЖНО: Suno НЕ умеет сохранять оригинальный текст исходного mp3 — он либо поёт твои `lyrics` дословно, либо сам генерит новый текст из `topic`. Возвращает 2 клипа.',
  parameters: {
    'style'         => { type: 'string', description: 'Целевой стиль на английском, через запятую. Без имён артистов. Пример: "synthwave, retro 80s, analog synth, neon, nostalgic". НЕ дублируй сюда стиль из lyrics/topic — стиль идёт ТОЛЬКО в этот параметр.' },
    'title'         => { type: 'string', description: 'Название будущего трека.' },
    'lyrics'        => { type: 'string', description: 'ЛИТЕРАЛЬНЫЕ стихи, которые Suno будет петь дословно (custom mode). Указывай ТОЛЬКО если: (а) пользователь дал явный текст песни в этом сообщении, ИЛИ (б) пользователь просит переделать ранее СГЕНЕРИРОВАННЫЙ ботом трек (видишь в контексте "[песня: ...]" + ответ бота с полным текстом) с изменениями в музыке/стиле/части слов — тогда СКОПИРУЙ исходный текст из контекста (с правками если просят), чтобы Suno спел тот же текст в новом стиле. НИКОГДА не пихай сюда описание стиля/жанра — это будет спето как лирика. Если ничего из этого нет — оставь пустым и заполни `topic`.' },
    'topic'         => { type: 'string', description: 'Короткая русская тема/идея (≤500 символов) для авто-генерации НОВОГО текста песни. Используй когда пользователь сказал "сделай кавер про X" или попросил кавер постороннего трека без явных стихов и без видимого исходного текста. Примеры: "про любовь и фронт", "про усталого программиста", "пятница, бар, отвал". НИКОГДА не описывай здесь стиль/жанр/инструменты (это идёт в `style`). Если оставлен пустым и `lyrics` тоже пуст — будет использован `title`.' },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку. Если пустой — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f". Игнорируется если instrumental=true.' },
    'negative_tags' => { type: 'string', description: 'Опционально: чего НЕ хотим, через запятую на английском.' },
    'instrumental'  => { type: 'boolean', description: 'true если кавер должен быть БЕЗ вокала (минус, инструментал). Ставь true когда пользователь говорит "минус", "инструментал", "без вокала", "без слов", или когда исходный трек инструментальный и пользователь не просит добавить вокал. По умолчанию false (с вокалом). При instrumental=true `lyrics`/`topic` игнорируются.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
  },
  handler: ->(args, ctx) {
    upload_url = args['upload_url'].to_s.strip
    if upload_url.empty? && ctx[:audio] && ctx[:audio][:file_id]
      upload_url = TelegramFile.public_url(ctx[:bot].api, ctx[:audio][:file_id], chat_id: ctx[:chat_id]).to_s
    end
    if upload_url.empty?
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку — иначе кавер делать не из чего.',
        intent:       'сделать кавер, как только пользователь пришлёт исходник',
        retry_in_min: nil
      )
    end

    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
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
        lyrics:         args['lyrics'].to_s,
        topic:          args['topic'].to_s,
        vocal_gender:   args['vocal_gender'],
        negative_tags:  args['negative_tags'].to_s,
        instrumental:   args['instrumental'] == true,
        with_cover_art: args['with_cover_art'] == true,
        user_uid:       ctx[:user]&.uid,
      }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после трека придёт обложка)' : ''
    "Делаю кавер — скоро будут 2 варианта в чате#{suffix}"
  }
)

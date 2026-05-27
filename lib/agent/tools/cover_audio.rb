require_relative '_suno_language_rule'

Agent::ToolRegistry.register(
  name: 'cover_audio',
  description: 'Сделать музыкальный кавер прикреплённого пользователем трека — Suno переделывает в новом стиле. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл И пользователь хочет именно кавер/переделку/в стиле X (e.g. "сделай метал-кавер", "переделай как 80-е", "сделай минус", "убери вокал"). НЕ используй для добавления вокала к инструменталке (add_vocals) или генерации с нуля (compose_song). ВАЖНО: Suno НЕ умеет сохранять оригинальный текст исходного mp3 — он либо поёт твои `lyrics` дословно, либо сам генерит новый текст из `topic`. Возвращает 2 клипа.',
  parameters: {
    'style'         => { type: 'string', description: 'Целевой стиль на английском, через запятую. Без имён артистов. Пример: "synthwave, retro 80s, analog synth, neon, nostalgic". НЕ дублируй сюда стиль из lyrics/topic — стиль идёт ТОЛЬКО в этот параметр.' },
    'title'         => { type: 'string', description: 'Название будущего трека.' },
    'lyrics'        => { type: 'string', description: 'ЛИТЕРАЛЬНЫЕ стихи, которые Suno будет петь дословно (custom mode). Указывай когда: (а) пользователь дал явный текст песни в этом сообщении, ИЛИ (б) хочешь изменить часть слов ранее сгенерированной ботом песни — тогда СКОПИРУЙ исходный текст с правками. Если пользователь просит ТОЛЬКО изменить музыку/стиль ранее сгенерированной песни и отвечает реплаем на её аудио — оставь `lyrics` пустым: хендлер сам подтянет оригинальный текст из исходной задачи. НИКОГДА не пихай сюда описание стиля/жанра — это будет спето как лирика. Если ничего из этого нет (новый трек постороннего источника) — оставь пустым и заполни `topic`. ' + SUNO_LANGUAGE_RULE_RU },
    'topic'         => { type: 'string', description: 'Короткая тема/идея (≤500 символов) для авто-генерации НОВОГО текста песни. Используй когда пользователь сказал "сделай кавер про X" или попросил кавер постороннего трека без явных стихов и без видимого исходного текста. Примеры: "про любовь и фронт", "про усталого программиста", "about a tired developer", "love and friday night". НИКОГДА не описывай здесь стиль/жанр/инструменты (это идёт в `style`). Если оставлен пустым и `lyrics` тоже пуст — будет использован `title`. ' + SUNO_LANGUAGE_RULE_RU },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку. Если пустой — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f". Игнорируется если instrumental=true.' },
    'negative_tags' => { type: 'string', description: SUNO_NEGATIVE_TAGS_DESC },
    'instrumental'  => { type: 'boolean', description: 'true если кавер должен быть БЕЗ вокала (минус, инструментал). Ставь true когда пользователь говорит "минус", "инструментал", "без вокала", "без слов", или когда исходный трек инструментальный и пользователь не просит добавить вокал. По умолчанию false (с вокалом). При instrumental=true `lyrics`/`topic` игнорируются.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
  },
  handler: ->(args, ctx) {
    upload_url = args['upload_url'].to_s.strip
    if upload_url.empty? && ctx[:audio] && ctx[:audio][:file_id]
      upload_url = TelegramFile.public_url(ctx[:api], ctx[:audio][:file_id], chat_id: ctx[:chat_id]).to_s
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

    # Source-lyrics fallback: when user replied to a previously-generated
    # bot Suno song and didn't provide explicit `lyrics`, copy them from
    # the source task. Mirrors `cover_art`'s reply-target resolution. Lets
    # "ответь на песню → бот, сделай этот трек в стиле джаза" reuse the
    # original lyrics even when they've scrolled past the chat-context
    # window. Source priority: source.params['lyrics'] (compose_song's
    # locally-composed text) → first clip's :lyrics in source.result
    # (add_vocals/cover_audio paths, mapped from Suno's response).
    resolved_lyrics = args['lyrics'].to_s
    if resolved_lyrics.strip.empty? && ctx[:reply_to_message_id]
      bot_msg = Message.find_by(chat_id: ctx[:chat_id], role: 'bot',
                                message_id: ctx[:reply_to_message_id])
      if bot_msg && bot_msg.bg_task_external_id
        source = BackgroundTask.where(chat_id: ctx[:chat_id],
                                      task_type: SONG_TASK_TYPES, status: 'done')
                               .where(external_id: bot_msg.bg_task_external_id).first
        if source
          src_lyrics = source.params_hash['lyrics'].to_s
          if src_lyrics.strip.empty?
            clips = (JSON.parse(source.result || '[]') rescue nil)
            if clips.is_a?(Array) && clips.first.is_a?(Hash)
              src_lyrics = clips.first['lyrics'].to_s
            end
          end
          resolved_lyrics = src_lyrics unless src_lyrics.strip.empty?
        end
      end
    end

    BackgroundTask.create!(
      task_type: 'suno_cover_audio',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        upload_url:     upload_url,
        style:          args['style'].to_s,
        title:          args['title'] || 'Кавер от 42FM',
        lyrics:         resolved_lyrics,
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

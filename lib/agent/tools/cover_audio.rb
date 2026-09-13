require_relative '_suno_language_rule'
require_relative '../../pending_audio_request'

Agent::ToolRegistry.register(
  name: 'cover_audio',
  description: 'Сделать музыкальный кавер прикреплённого пользователем трека — Suno переделывает в новом стиле. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл И пользователь хочет именно кавер/переделку/в стиле X (e.g. "сделай метал-кавер", "переделай как 80-е"). НЕ используй для добавления вокала к инструменталке (add_vocals), генерации с нуля (compose_song) и для "убери вокал" / "сделай минус" / "караоке" ИЗ ОРИГИНАЛЬНОЙ записи — это separate_vocals (cover_audio перегенерирует музыку заново). ВАЖНО: Suno НЕ умеет сохранять оригинальный текст исходного mp3 — он либо поёт твои `lyrics` дословно, либо сам генерит новый текст из `topic`. Возвращает 2 клипа.',
  parameters: {
    'style'         => { type: 'string', description: 'Целевой стиль на английском, через запятую. Без имён артистов. Пример: "synthwave, retro 80s, analog synth, neon, nostalgic". НЕ дублируй сюда стиль из lyrics/topic — стиль идёт ТОЛЬКО в этот параметр.' },
    'title'         => { type: 'string', description: 'Название будущего трека.' },
    'lyrics'        => { type: 'string', description: 'ЛИТЕРАЛЬНЫЕ стихи, которые Suno будет петь дословно (custom mode). Указывай когда: (а) пользователь дал явный текст песни в этом сообщении, ИЛИ (б) хочешь изменить часть слов ранее сгенерированной ботом песни — тогда СКОПИРУЙ исходный текст с правками. Если пользователь просит ТОЛЬКО изменить музыку/стиль ранее сгенерированной песни и отвечает реплаем на её аудио — оставь `lyrics` пустым: хендлер сам подтянет оригинальный текст из исходной задачи. НИКОГДА не пихай сюда описание стиля/жанра — это будет спето как лирика. Если ничего из этого нет (новый трек постороннего источника) — оставь пустым и заполни `topic`. ' + SUNO_LANGUAGE_RULE_RU },
    'topic'         => { type: 'string', description: 'Короткая тема/идея (≤500 символов) для авто-генерации НОВОГО текста песни. Используй когда пользователь сказал "сделай кавер про X" или попросил кавер постороннего трека без явных стихов и без видимого исходного текста. Примеры: "про любовь и фронт", "про усталого программиста", "about a tired developer", "love and friday night". НИКОГДА не описывай здесь стиль/жанр/инструменты (это идёт в `style`). Если оставлен пустым и `lyrics` тоже пуст — будет использован `title`. ' + SUNO_LANGUAGE_RULE_RU },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку. Если пустой — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f". Игнорируется если instrumental=true.' },
    'negative_tags' => { type: 'string', description: SUNO_NEGATIVE_TAGS_DESC },
    'instrumental'  => { type: 'boolean', description: 'true если нужен инструментальный кавер в НОВОМ стиле (без вокала), e.g. "сделай инструментальную джаз-версию", или исходный трек инструментальный и пользователь не просит добавить вокал. По умолчанию false (с вокалом). При instrumental=true `lyrics`/`topic` игнорируются. Если нужен минус/караоке САМОЙ записи (оригинальная музыка без голоса) — это не сюда, а separate_vocals.' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
    'retry_of_task_id' => { type: 'integer', optional: true, description: 'Только для ПОВТОРА неудавшегося кавера: номер task из служебного события cover_failed ("task #N"). Берёт исходник и параметры той задачи (пустые аргументы заполнятся из неё), так что повтор работает и без прикреплённого файла.' },
  },
  handler: ->(args, ctx) {
    retry_src = nil
    if (retry_id = args['retry_of_task_id'].to_s[/\A\d+\z/])
      retry_src = BackgroundTask.where(id: retry_id.to_i, chat_id: ctx[:chat_id],
                                       task_type: 'suno_cover_audio', status: 'failed').first
      next "Неудавшегося кавера task ##{retry_id} в этом чате нет — повторять нечего. Попроси пользователя прислать трек заново." unless retry_src
      # A failed task stays 'failed' forever, so without this the same source
      # could be retried twice — e.g. the user says "повтори" after a
      # rate-limited retry already left a due intention for cron — and Suno
      # bills both. Same dedup shape as SunoTaskHandler#maybe_chain_cover_art.
      prior = BackgroundTask.where(chat_id: ctx[:chat_id], task_type: 'suno_cover_audio', status: %w[pending done])
                            .where("json_extract(params, '$.retry_of_task_id') = ?", retry_src.id).order(id: :desc).first
      if prior
        next prior.status == 'done' ?
          "Повтор task ##{retry_src.id} уже сделан (task ##{prior.id}) — второй раз не запускаю." :
          "Повтор task ##{retry_src.id} уже в работе (task ##{prior.id}) — дождись результата, второй раз не запускаю."
      end
    end
    rp = retry_src ? retry_src.params_hash : {}
    arg = ->(key) { v = args[key].to_s; v.strip.empty? ? rp[key].to_s : v }

    upload_url = args['upload_url'].to_s.strip
    upload_file_id = nil
    if upload_url.empty? && retry_src
      upload_url     = rp['upload_url'].to_s
      upload_file_id = rp['upload_file_id']
    end
    if upload_url.empty? && ctx[:audio] && ctx[:audio][:file_id]
      upload_file_id = ctx[:audio][:file_id]
      upload_url = TelegramFile.public_url(ctx[:api], upload_file_id, chat_id: ctx[:chat_id]).to_s
      next 'Не получилось забрать этот файл из Telegram (бот может скачивать файлы только до 20 МБ). Пришли файл поменьше или прямую ссылку.' if upload_url.empty?
    end

    role = ctx[:user]&.role
    if upload_url.empty?
      unless RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
        offer = PendingAudioRequest.offer(ctx, tool: 'cover_audio')
        next offer if offer
      end
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку — иначе кавер делать не из чего.',
        intent:       'сделать кавер, как только пользователь пришлёт исходник',
        retry_in_min: nil
      )
    end

    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "сделать кавер через #{mins} мин: #{(args['title'] || 'трек').to_s.slice(0, 80)}#{retry_src ? " (cover_audio с retry_of_task_id=#{retry_src.id})" : ''}",
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
    resolved_lyrics = arg.call('lyrics')
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

    PendingAudioRequest.clear_for(ctx) # a task is being created — the follow-up is moot
    BackgroundTask.create!(
      task_type: 'suno_cover_audio',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        upload_url:       upload_url,
        # Lets the handler resolve a fresh Telegram link at submit time
        # (getFile links expire; a retry may run much later).
        upload_file_id:   upload_file_id,
        style:            arg.call('style'),
        title:            arg.call('title').strip.empty? ? 'Кавер от 42FM' : arg.call('title'),
        lyrics:           resolved_lyrics,
        topic:            arg.call('topic'),
        vocal_gender:     args['vocal_gender'].to_s.strip.empty? ? rp['vocal_gender'] : args['vocal_gender'],
        negative_tags:    arg.call('negative_tags'),
        instrumental:     args['instrumental'] == true || rp['instrumental'] == true,
        with_cover_art:   args['with_cover_art'] == true,
        retry_of_task_id: retry_src&.id,
        user_uid:         ctx[:user]&.uid,
      }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после трека придёт обложка)' : ''
    "Делаю кавер — скоро будут 2 варианта в чате#{suffix}"
  }
)

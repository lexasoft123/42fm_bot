require_relative '_suno_language_rule'
require_relative '../../pending_audio_request'

Agent::ToolRegistry.register(
  name: 'add_vocals',
  description: 'Подпеть к прикреплённому пользователем треку — Suno layer\'ит AI-вокал поверх инструменталки. Используй когда: к сообщению ПРИКРЕПЛЁН аудиофайл (видишь "[К сообщению прикреплён аудиофайл...]") И пользователь явно просит вокал/подпеть/спеть под этот трек/добавь голос. НЕ используй для каверов (cover_audio) или для генерации новой песни с нуля (compose_song). Возвращает один клип. Если пользователь хочет ещё обложку — with_cover_art=true.',
  parameters: {
    'theme'         => { type: 'string', description: 'Что должен спеть Suno. ВАЖНО: если пользователь указал КОНКРЕТНЫЙ ТЕКСТ песни — передай его сюда дословно, целиком, БЕЗ ПАРАФРАЗА, без сокращений, без украшательств. Если пользователь дал тему/идею ("про любовь", "про дайвера и его жену") — кратко передай её, можно добавить минимум контекста, но не сочиняй сюжет за него. Если есть [Verse]/[Chorus] метки — сохрани их. ' + SUNO_LANGUAGE_RULE_RU },
    'style'         => { type: 'string', description: 'Стиль вокала и общий характер на английском, через запятую. Без имён артистов — Suno их блокирует. Пример: "melancholic male vocals, indie rock, brooding, soft delivery"' },
    'title'         => { type: 'string', description: 'Название будущего трека (для caption и filename).' },
    'upload_url'    => { type: 'string', description: 'Опциональный URL аудио, если пользователь дал ссылку (а не прикрепил файл). Если оставить пустым — берётся URL прикреплённого файла.' },
    'vocal_gender'  => { type: 'string', description: 'Опционально: "m" или "f" — пол вокалиста.' },
    'negative_tags' => { type: 'string', description: SUNO_NEGATIVE_TAGS_DESC },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. См. compose_song.' },
    'model'         => SUNO_MODEL_PARAM,
    'retry_of_task_id' => { type: 'integer', optional: true, description: 'Только для ПОВТОРА неудавшейся задачи: номер task из служебного события add_vocals_failed ("task #N"). Берёт исходник и параметры той задачи (пустые аргументы заполнятся из неё).' },
  },
  handler: ->(args, ctx) {
    retry_src = nil
    if (retry_id = args['retry_of_task_id'].to_s[/\A\d+\z/])
      retry_src = BackgroundTask.where(id: retry_id.to_i, chat_id: ctx[:chat_id],
                                       task_type: 'suno_add_vocals', status: 'failed').first
      next "Неудавшейся задачи add_vocals task ##{retry_id} в этом чате нет — повторять нечего. Попроси пользователя прислать трек заново." unless retry_src
      # A failed task stays 'failed' forever, so without this the same source
      # could be retried twice — e.g. the user says "повтори" after a
      # rate-limited retry already left a due intention for cron — and Suno
      # bills both. Same dedup shape as SunoTaskHandler#maybe_chain_cover_art.
      prior = BackgroundTask.where(chat_id: ctx[:chat_id], task_type: 'suno_add_vocals', status: %w[pending done])
                            .where("json_extract(params, '$.retry_of_task_id') = ?", retry_src.id).order(id: :desc).first
      if prior
        next prior.status == 'done' ?
          "Повтор task ##{retry_src.id} уже сделан (task ##{prior.id}) — второй раз не запускаю." :
          "Повтор task ##{retry_src.id} уже в работе (task ##{prior.id}) — дождись результата, второй раз не запускаю."
      end
    end
    rp = retry_src ? retry_src.params_hash : {}
    arg = ->(key) { v = args[key].to_s; v.strip.empty? ? rp[key].to_s : v }
    model, model_error = SunoToolModel.resolve(args['model'], inherited: rp['model'])
    next model_error if model_error

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
        offer = PendingAudioRequest.offer(ctx, tool: 'add_vocals')
        next offer if offer
      end
      next Agent::ToolResult.deferred(
        user_text:    'Прикрепи аудиофайл или дай прямую ссылку на трек — иначе подпеть не к чему.',
        intent:       'подпеть к треку, как только пользователь его пришлёт',
        retry_in_min: nil
      )
    end

    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "подпеть через #{mins} мин: #{(args['title'] || 'трек').to_s.slice(0, 80)}#{retry_src ? " (add_vocals с retry_of_task_id=#{retry_src.id})" : ''}#{SunoToolModel.intent_suffix(model)}",
        retry_in_min: mins
      )
    end

    PendingAudioRequest.clear_for(ctx) # a task is being created — the follow-up is moot
    BackgroundTask.create!(
      task_type: 'suno_add_vocals',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        upload_url:       upload_url,
        upload_file_id:   upload_file_id, # fresh Telegram link at submit time
        theme:            arg.call('theme'),
        style:            arg.call('style'),
        title:            arg.call('title').strip.empty? ? 'Песня от 42FM' : arg.call('title'),
        vocal_gender:     args['vocal_gender'].to_s.strip.empty? ? rp['vocal_gender'] : args['vocal_gender'],
        negative_tags:    arg.call('negative_tags'),
        with_cover_art:   args['with_cover_art'] == true,
        model:            model, # validated; a retry keeps the failed task's model unless overridden
        retry_of_task_id: retry_src&.id,
        user_uid:         ctx[:user]&.uid,
      }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после песни придёт обложка)' : ''
    "Беру трек, подпою — скоро будет в чате#{suffix}"
  }
)

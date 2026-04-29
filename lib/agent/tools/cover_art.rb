SONG_TASK_TYPES = %w[suno_generate suno_add_vocals suno_cover_audio].freeze

Agent::ToolRegistry.register(
  name: 'cover_art',
  description: 'Сгенерировать обложку (2 PNG-картинки) для песни, которую бот уже сгенерировал в этом чате. Используй когда пользователь просит обложку для прошлой/последней песни. Если пользователь ОТВЕЧАЕТ (replies) на конкретное аудио-сообщение бота — берётся именно та песня (через bg_task_external_id из messages.). Иначе — последняя успешная песня в чате (любого типа: compose_song / add_vocals / cover_audio). Если хочешь конкретную — передай suno_task_id явно.',
  parameters: {
    'suno_task_id' => { type: 'string', description: 'Опциональный Suno taskId (external_id из background_tasks) конкретной песни. Если пусто — будет резолв через reply_to (если есть) или последняя готовая песня в чате.' },
  },
  handler: ->(args, ctx) {
    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "сделать обложку через #{mins} мин",
        retry_in_min: mins
      )
    end

    suno_task_id = args['suno_task_id'].to_s.strip
    source = nil

    # Resolution chain: explicit arg → reply target → most recent.
    if suno_task_id.empty? && ctx[:reply_to_message_id]
      bot_msg = Message.find_by(chat_id: ctx[:chat_id], role: 'bot',
                                message_id: ctx[:reply_to_message_id])
      if bot_msg && bot_msg.bg_task_external_id
        source = BackgroundTask.where(chat_id: ctx[:chat_id],
                                      task_type: SONG_TASK_TYPES, status: 'done')
                               .where(external_id: bot_msg.bg_task_external_id).first
        suno_task_id = bot_msg.bg_task_external_id
      end
    end

    if suno_task_id.empty?
      source = BackgroundTask.where(chat_id: ctx[:chat_id],
                                    task_type: SONG_TASK_TYPES, status: 'done')
                             .where.not(external_id: nil).order(id: :desc).first
      unless source
        next Agent::ToolResult.deferred(
          user_text:    'В этом чате я ещё не пела — попроси сначала песню, потом смогу нарисовать к ней обложку.',
          intent:       'нарисовать обложку, как только в чате появится песня',
          retry_in_min: nil
        )
      end
      suno_task_id = source.external_id
    end

    source_title = source&.params_hash&.dig('title')
    BackgroundTask.create!(
      task_type: 'suno_cover_art',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        source_task_id: suno_task_id,
        source_title:   source_title,
        user_uid:       ctx[:user]&.uid,
      }.to_json
    )
    "Рисую обложку для «#{source_title || suno_task_id}» — скоро будет в чате"
  }
)

CONVERT_TO_WAV_SOURCE_TASK_TYPES = %w[suno_generate suno_add_vocals suno_cover_audio].freeze

Agent::ToolRegistry.register(
  name: 'convert_to_wav',
  description: 'Сконвертировать готовый mp3-трек, который бот сгенерил в этом чате, в высококачественный WAV (44.1kHz, 16-bit stereo). Используй когда пользователь просит wav / wave / "качество получше" / "несжатый" / "для микса". Если пользователь ОТВЕЧАЕТ (replies) на конкретное аудио бота — берётся именно тот трек (через bg_task_external_id из messages). Иначе — последняя успешная песня в чате (любого типа). Suno даёт 2 клипа на песню; clip_index выбирает который (1 или 2, по умолчанию 1).',
  parameters: {
    'suno_task_id' => { type: 'string', description: 'Опциональный Suno taskId конкретной песни. Если пусто — резолв через reply_to → последняя готовая песня.' },
    'clip_index'   => { type: 'integer', description: 'Какой из двух клипов конвертировать: 1 (по умолчанию) или 2.' },
  },
  handler: ->(args, ctx) {
    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "конвертнуть в WAV через #{mins} мин",
        retry_in_min: mins
      )
    end

    suno_task_id = args['suno_task_id'].to_s.strip
    source = nil

    # Resolution chain: explicit arg → reply target → most recent.
    # Mirrors `cover_art` exactly so the same UX rules apply.
    if suno_task_id.empty? && ctx[:reply_to_message_id]
      bot_msg = Message.find_by(chat_id: ctx[:chat_id], role: 'bot',
                                message_id: ctx[:reply_to_message_id])
      if bot_msg && bot_msg.bg_task_external_id
        source = BackgroundTask.where(chat_id: ctx[:chat_id],
                                      task_type: CONVERT_TO_WAV_SOURCE_TASK_TYPES,
                                      status: 'done')
                               .where(external_id: bot_msg.bg_task_external_id).first
        suno_task_id = bot_msg.bg_task_external_id
      end
    end

    if suno_task_id.empty?
      source = BackgroundTask.where(chat_id: ctx[:chat_id],
                                    task_type: CONVERT_TO_WAV_SOURCE_TASK_TYPES,
                                    status: 'done')
                             .where.not(external_id: nil).order(id: :desc).first
      unless source
        next Agent::ToolResult.deferred(
          user_text:    'В этом чате я ещё не пела — не из чего делать WAV. Сначала попроси песню.',
          intent:       'сконвертировать в WAV, как только в чате появится песня',
          retry_in_min: nil
        )
      end
      suno_task_id = source.external_id
    end

    clip_index = (args['clip_index'] || 1).to_i
    clip_index = 1 unless [1, 2].include?(clip_index)

    source_title = source&.params_hash&.dig('title')
    source_performer = source&.params_hash&.dig('artist').to_s

    BackgroundTask.create!(
      task_type: 'suno_wav_convert',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: {
        source_task_id:    suno_task_id,
        source_title:      source_title,
        source_performer:  source_performer,
        clip_index:        clip_index,
        user_uid:          ctx[:user]&.uid,
      }.to_json
    )
    "Делаю WAV для «#{source_title || suno_task_id}» (клип #{clip_index}) — скоро придёт в чат"
  }
)

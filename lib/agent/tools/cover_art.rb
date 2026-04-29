Agent::ToolRegistry.register(
  name: 'cover_art',
  description: 'Сгенерировать обложку (2 PNG-картинки) для песни, которую бот уже сгенерировал в этом чате. Используй когда пользователь просит обложку для прошлой/последней песни. По умолчанию берётся последняя успешная suno_generate-задача в чате. Если хочешь конкретную — передай suno_task_id.',
  parameters: {
    'suno_task_id' => { type: 'string', description: 'Опциональный Suno taskId (external_id из background_tasks) конкретной песни. Если пусто — берётся последняя готовая песня в чате.' },
  },
  handler: ->(args, ctx) {
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno')
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno')
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno'),
        intent:       "сделать обложку через #{mins} мин",
        retry_in_min: mins
      )
    end

    suno_task_id = args['suno_task_id'].to_s.strip
    source = nil
    if suno_task_id.empty?
      source = BackgroundTask.where(chat_id: ctx[:chat_id], task_type: 'suno_generate', status: 'done')
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

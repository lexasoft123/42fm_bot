require_relative '_suno_language_rule'

Agent::ToolRegistry.register(
  name: 'compose_song',
  description: 'Генерирует песню через Suno AI. Песня будет отправлена в чат как аудио. ВАЖНО ПРО ТЕКСТ: по умолчанию ОСТАВЬ `lyrics` пустым и заполни `theme` — наш отдельный композитор (Sonnet) сочинит лучше тебя, со знанием контекста чата и фактов о юзерах. Заполняй `lyrics` ТОЛЬКО когда пользователь явно дал текст песни дословно или ты редактируешь ранее сгенерированный текст. Если пользователь просит "с обложкой" / "и обложку" — установи with_cover_art=true, после песни автоматически придёт арт. ' + SUNO_LANGUAGE_RULE_RU,
  parameters: {
    'theme'  => { type: 'string', description: 'Тема/идея песни — короткое описание того, ПРО ЧТО песня (не путать с `tags`, который про музыкальный стиль). На русском или английском. Примеры: "про усталого программиста и его кота", "love and friday night", "про шефа, который продал всех". Используется отдельным композитором (Sonnet) для генерации текста с учётом контекста чата и знаний о юзерах. Заполняй ВСЕГДА (если только не передаёшь `lyrics` дословно).' },
    'lyrics' => { type: 'string', description: 'ОПЦИОНАЛЬНО — оставляй пустым по умолчанию. Заполни ТОЛЬКО когда пользователь дал явный текст песни дословно или ты редактируешь ранее сгенерированный текст. Если заполнен — приоритет над `theme` (отдельный композитор не запускается). Тэги [Verse]/[Chorus]/[Outro]. ' + SUNO_LANGUAGE_RULE_RU },
    'tags'   => { type: 'string', description: 'Стиль музыки на английском для Suno AI. Опиши жанр, настроение, инструменты, вокал. НИКОГДА не включай имена артистов — Suno их блокирует! Вместо имени опиши звучание (e.g. "industrial metal, Neue Deutsche Härte, heavy distorted riffs, deep German male vocals, aggressive, martial drums, stomping rhythm")' },
    'title'  => { type: 'string', description: 'Название песни' },
    'artist' => { type: 'string', description: 'Исполнитель/группа, если песня в их стиле (e.g. "Rammstein", "Цой"). Пустая строка если не указан.' },
    'genre'  => { type: 'string', description: 'Жанр на русском (e.g. "рок", "метал", "рэп")' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. После доставки песни автоматически создастся задача на cover_art (отдельный rate-limit не тратится сверх «suno», но если бакет уже исчерпан в момент чейна — обложка тихо пропустится).' },
  },
  handler: ->(args, ctx) {
    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins  = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      title = (args['title'] || args['lyrics'] || 'песню').to_s.slice(0, 80)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "спеть через #{mins} мин: #{title}",
        retry_in_min: mins
      )
    end
    # `theme` from the agent maps onto the existing `topic` slot the handler
    # already reads (see SunoTaskHandler#compose_and_submit_generate). Leaving
    # `lyrics` empty/nil routes composition through the dedicated Sonnet
    # composer (`unless p['lyrics']` branch); non-empty short-circuits to
    # Suno submission. `.strip.presence` on both makes whitespace == nil,
    # so failure telemetry's `p['topic'] || p['request']` fallback in
    # mark_failed_and_notify works for legacy direct-command tasks too.
    inline_lyrics = args['lyrics'].to_s.strip.presence
    inline_topic  = args['theme'].to_s.strip.presence
    BackgroundTask.create!(
      task_type: 'suno_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: { tags: args['tags'] || 'rock',
                title: args['title'] || 'Песня от 42FM',
                lyrics: inline_lyrics,
                topic: inline_topic,
                artist: args['artist'].to_s,
                genre: args['genre'].to_s.presence || 'рок',
                with_cover_art: args['with_cover_art'] == true,
                user_uid: ctx[:user]&.uid }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после песни придёт обложка)' : ''
    "Песня «#{args['title']}» поставлена в очередь генерации и скоро будет отправлена в чат#{suffix}"
  }
)

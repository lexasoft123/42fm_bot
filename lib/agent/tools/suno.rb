Agent::ToolRegistry.register(
  name: 'compose_song',
  description: 'Генерирует песню через Suno AI. Сочини текст песни с тегами [Verse], [Chorus] и укажи стиль на английском. Песня будет отправлена в чат как аудио. Если пользователь просит "с обложкой" / "и обложку" — установи with_cover_art=true, после песни автоматически придёт арт.',
  parameters: {
    'lyrics' => { type: 'string', description: 'Текст песни с тегами [Verse], [Chorus], [Outro]' },
    'tags'   => { type: 'string', description: 'Стиль музыки на английском для Suno AI. Опиши жанр, настроение, инструменты, вокал. НИКОГДА не включай имена артистов — Suno их блокирует! Вместо имени опиши звучание (e.g. "industrial metal, Neue Deutsche Härte, heavy distorted riffs, deep German male vocals, aggressive, martial drums, stomping rhythm")' },
    'title'  => { type: 'string', description: 'Название песни' },
    'artist' => { type: 'string', description: 'Исполнитель/группа, если песня в их стиле (e.g. "Rammstein", "Цой"). Пустая строка если не указан.' },
    'genre'  => { type: 'string', description: 'Жанр на русском (e.g. "рок", "метал", "рэп")' },
    'with_cover_art' => { type: 'boolean', description: 'true если пользователь хочет ещё и обложку. После доставки песни автоматически создастся задача на cover_art (отдельный rate-limit не тратится сверх «suno», но если бакет уже исчерпан в момент чейна — обложка тихо пропустится).' },
  },
  handler: ->(args, ctx) {
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno')
      mins  = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno')
      title = (args['title'] || args['lyrics'] || 'песню').to_s.slice(0, 80)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno'),
        intent:       "спеть через #{mins} мин: #{title}",
        retry_in_min: mins
      )
    end
    BackgroundTask.create!(
      task_type: 'suno_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: { tags: args['tags'] || 'rock',
                title: args['title'] || 'Песня от 42FM',
                lyrics: args['lyrics'],
                artist: args['artist'].to_s,
                genre: args['genre'].to_s.presence || 'рок',
                with_cover_art: args['with_cover_art'] == true,
                user_uid: ctx[:user]&.uid }.to_json
    )
    suffix = args['with_cover_art'] == true ? ' (после песни придёт обложка)' : ''
    "Песня «#{args['title']}» поставлена в очередь генерации и скоро будет отправлена в чат#{suffix}"
  }
)

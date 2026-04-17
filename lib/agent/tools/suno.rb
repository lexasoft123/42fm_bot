Agent::ToolRegistry.register(
  name: 'compose_song',
  description: 'Генерирует песню через Suno AI. Сочини текст песни с тегами [Verse], [Chorus] и укажи стиль на английском. Песня будет отправлена в чат как аудио.',
  parameters: {
    'lyrics' => { type: 'string', description: 'Текст песни с тегами [Verse], [Chorus], [Outro]' },
    'tags'   => { type: 'string', description: 'Стиль музыки на английском для Suno AI. Опиши жанр, настроение, инструменты, вокал. НИКОГДА не включай имена артистов — Suno их блокирует! Вместо имени опиши звучание (e.g. "industrial metal, Neue Deutsche Härte, heavy distorted riffs, deep German male vocals, aggressive, martial drums, stomping rhythm")' },
    'title'  => { type: 'string', description: 'Название песни' },
    'artist' => { type: 'string', description: 'Исполнитель/группа, если песня в их стиле (e.g. "Rammstein", "Цой"). Пустая строка если не указан.' },
    'genre'  => { type: 'string', description: 'Жанр на русском (e.g. "рок", "метал", "рэп")' },
  },
  handler: ->(args, ctx) {
    if RateLimiter.exceeded?(ctx[:chat_id], 'suno')
      next RateLimiter.reply(ctx[:chat_id], 'suno')
    end
    BackgroundTask.create!(
      task_type: 'suno_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 30,
      params: { tags: args['tags'] || 'rock',
                title: args['title'] || 'Песня от 42FM',
                lyrics: args['lyrics'],
                artist: args['artist'].to_s,
                genre: args['genre'].to_s.presence || 'рок',
                user_uid: ctx[:user]&.uid }.to_json
    )
    "Песня «#{args['title']}» поставлена в очередь генерации и скоро будет отправлена в чат"
  }
)

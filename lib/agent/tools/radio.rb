Agent::ToolRegistry.register(
  name: 'radio_current_track',
  description: 'Показывает текущий трек на радио и оставшееся время воспроизведения',
  handler: ->(args, ctx) { ctx[:radio].track }
)

Agent::ToolRegistry.register(
  name: 'radio_queue',
  description: 'Показывает очередь заказанных треков на радио',
  handler: ->(args, ctx) { ctx[:radio].queue || 'Очередь пуста' }
)

Agent::ToolRegistry.register(
  name: 'radio_search',
  description: 'Ищет треки в базе радиостанции по запросу. Поиск по исполнителю, названию, альбому, жанру',
  parameters: { 'query' => { type: 'string', description: 'Поисковый запрос (исполнитель, название трека, альбом, жанр)' } },
  handler: ->(args, ctx) {
    songs = Song.search(args['query'], limit: 10)
    if songs.empty?
      'Ничего не найдено'
    else
      songs.map { |s|
        line = s.display_name
        line += " [#{s.genre}]" if s.genre.to_s != ''
        line += " — #{s.album}" if s.album.to_s != ''
        line
      }.join("\n")
    end
  }
)

Agent::ToolRegistry.register(
  name: 'radio_request',
  description: 'Заказывает трек на радио по запросу. Возвращает название поставленного трека или nil если не найден',
  parameters: { 'query' => { type: 'string', description: 'Поисковый запрос (исполнитель, название трека)' } },
  handler: ->(args, ctx) {
    result = ctx[:radio].request(args['query'])
    result ? result[:name] : 'Трек не найден'
  }
)

Agent::ToolRegistry.register(
  name: 'radio_listeners',
  description: 'Показывает текущее количество слушателей радиостанции',
  handler: ->(args, ctx) { "Слушателей: #{ctx[:radio].listeners}" }
)

Agent::ToolRegistry.register(
  name: 'radio_history',
  description: 'Показывает историю последних проигранных треков на радио',
  handler: ->(args, ctx) { ctx[:radio].history }
)

Agent::ToolRegistry.register(
  name: 'radio_meta',
  description: 'Показывает подробные метаданные текущего трека (исполнитель, альбом, год, жанр)',
  handler: ->(args, ctx) { ctx[:radio].meta }
)

Agent::ToolRegistry.register(
  name: 'radio_remove',
  description: 'Удаляет треки из очереди по их ID. Только для администраторов',
  parameters: { 'ids' => { type: 'array', items: { type: 'integer' }, description: 'Массив ID треков для удаления' } },
  handler: ->(args, ctx) { ctx[:radio].remove(args['ids']) ? 'Удалено' : 'Ошибка удаления' },
  admin_only: true
)

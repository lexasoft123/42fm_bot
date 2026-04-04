Agent::ToolRegistry.register(
  name: 'knowledge_search',
  description: 'Ищет факты в базе знаний чата по семантической близости. Результаты отсортированы по релевантности. Используй count для управления количеством результатов (по умолчанию 5, максимум 20) и offset для постраничной загрузки — если первой порции недостаточно, запроси следующую с offset равным количеству уже полученных.',
  parameters: {
    'query'  => { type: 'string',  description: 'Поисковый запрос' },
    'count'  => { type: 'integer', description: 'Количество результатов (1–20, по умолчанию 5)', optional: true },
    'offset' => { type: 'integer', description: 'Смещение для пагинации (по умолчанию 0)', optional: true },
  },
  handler: ->(args, ctx) {
    count  = args['count'].to_i
    count  = count < 1 ? 5 : [count, 20].min
    offset = [args['offset'].to_i, 0].max
    facts  = KnowledgeBase.search(args['query'], chat_id: ctx[:chat_id], top_k: count, offset: offset)
    facts.empty? ? 'Ничего не найдено' : facts.map { |k| "[#{k.topic}] #{k.content}" }.join("\n")
  }
)

Agent::ToolRegistry.register(
  name: 'knowledge_add',
  description: 'Добавляет факт в базу знаний чата. Только для администраторов',
  parameters: {
    'topic'   => { type: 'string', description: 'Краткая тема факта' },
    'content' => { type: 'string', description: 'Текст факта' },
  },
  handler: ->(args, ctx) {
    k = KnowledgeBase.add(topic: args['topic'], content: args['content'], chat_id: ctx[:chat_id], source: 'manual')
    "Добавлен факт ##{k.id}: #{k.content}"
  },
  admin_only: true
)

Agent::ToolRegistry.register(
  name: 'knowledge_delete',
  description: 'Удаляет факт из базы знаний по ID. Только для администраторов',
  parameters: { 'id' => { type: 'integer', description: 'ID факта для удаления' } },
  handler: ->(args, ctx) {
    k = Knowledge.find_by(id: args['id'], chat_id: ctx[:chat_id])
    return "Факт ##{args['id']} не найден" unless k
    k.destroy
    "Удалён факт ##{args['id']}"
  },
  admin_only: true
)

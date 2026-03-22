Agent::ToolRegistry.register(
  name: 'knowledge_search',
  description: 'Ищет факты в базе знаний чата по семантической близости',
  parameters: { 'query' => { type: 'string', description: 'Поисковый запрос' } },
  handler: ->(args, ctx) {
    facts = KnowledgeBase.search(args['query'], chat_id: ctx[:chat_id], top_k: 5)
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

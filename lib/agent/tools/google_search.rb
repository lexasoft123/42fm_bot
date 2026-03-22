Agent::ToolRegistry.register(
  name: 'google_search',
  description: 'Ищет в Google по запросу. Возвращает ссылку на результат',
  parameters: { 'query' => { type: 'string', description: 'Поисковый запрос' } },
  handler: ->(args, ctx) { Gogolmogol.new(args['query']).search! }
)

Agent::ToolRegistry.register(
  name: 'weather',
  description: 'Показывает текущую погоду в указанном городе',
  parameters: { 'city' => { type: 'string', description: 'Название города' } },
  handler: ->(args, ctx) { Weather.new(args['city']).search! }
)

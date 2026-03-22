Agent::ToolRegistry.register(
  name: 'horoscope',
  description: 'Генерирует гороскоп для указанного пользователя',
  parameters: { 'username' => { type: 'string', description: 'Имя пользователя для гороскопа' } },
  handler: ->(args, ctx) { Horoscope.new(args['username']).predict! }
)

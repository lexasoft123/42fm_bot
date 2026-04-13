Agent::ToolRegistry.register(
  name: 'generate_image',
  description: 'Создаёт оригинальную картинку через FLUX AI (нейросетевая генерация с нуля). Используй только когда пользователь просит нарисовать/создать что-то новое. НЕ используй для поиска существующих фото, мемов или картинок — для этого есть google_search.',
  parameters: {
    'prompt' => { type: 'string', description: 'Запрос пользователя на его ОРИГИНАЛЬНОМ языке — не переводи, передай как есть. Если пользователь написал по-русски — передай по-русски.' },
  },
  handler: ->(args, ctx) {
    if RateLimiter.exceeded?(ctx[:chat_id], 'image')
      next RateLimiter.reply(ctx[:chat_id], 'image')
    end
    BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 20,
      params: { request: args['prompt'] }.to_json
    )
    "Картинка поставлена в очередь генерации и скоро будет отправлена в чат"
  }
)

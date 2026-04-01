Agent::ToolRegistry.register(
  name: 'generate_image',
  description: 'Генерирует картинку через FLUX AI. Опиши что нарисовать — можно на русском или английском. Максимально дословно передай контекст и смысл запроса, добавь что нужно для улучшения генерации. Картинка будет отправлена в чат.',
  parameters: {
    'prompt' => { type: 'string', description: 'Описание картинки: что изобразить, стиль, настроение, детали. Можно на русском.' },
  },
  handler: ->(args, ctx) {
    BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 20,
      params: { request: args['prompt'] }.to_json
    )
    "Картинка поставлена в очередь генерации и скоро будет отправлена в чат"
  }
)

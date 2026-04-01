Agent::ToolRegistry.register(
  name: 'generate_image',
  description: 'Генерирует картинку через FLUX AI. Передай запрос пользователя дословно — без изменений и добавлений. Промпт будет оптимизирован автоматически с учётом контекста чата. Картинка будет отправлена в чат.',
  parameters: {
    'prompt' => { type: 'string', description: 'Точная формулировка запроса пользователя — что нарисовать.' },
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

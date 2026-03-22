Agent::ToolRegistry.register(
  name: 'generate_image',
  description: 'Генерирует картинку через FLUX AI. Опиши что нарисовать подробно на английском. Картинка будет отправлена в чат.',
  parameters: {
    'prompt' => { type: 'string', description: 'Detailed image description in English: subject, art style, lighting, composition, mood, colors, textures. Be vivid and specific.' },
  },
  handler: ->(args, ctx) {
    BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 20,
      params: { prompt: args['prompt'], request: args['prompt'] }.to_json
    )
    "Картинка поставлена в очередь генерации и скоро будет отправлена в чат"
  }
)

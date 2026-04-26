Agent::ToolRegistry.register(
  name: 'remember',
  description: 'Сохраняет запись в твой scratchpad — рабочую память между сообщениями. Используй для своих планов, ожиданий, заметок о настроении пользователей, незавершённых дел. НЕ для фактов о мире — для них есть knowledge_add. Категории: "intentions" (что собираюсь сделать), "notes" (наблюдения), "expectations" (что жду от пользователей).',
  parameters: {
    'category' => { type: 'string', description: 'intentions | notes | expectations' },
    'content'  => { type: 'string', description: 'Текст записи, одно предложение' },
  },
  handler: ->(args, ctx) {
    category = args['category'].to_s
    unless Agent::Scratchpad::CATEGORIES.include?(category)
      next "Неизвестная категория '#{category}'. Допустимые: #{Agent::Scratchpad::CATEGORIES.join(', ')}"
    end
    id = Agent::Scratchpad.add(ctx[:chat_id], category: category, content: args['content'])
    "Запомнил [#{id}] в #{category}: #{args['content']}"
  }
)

Agent::ToolRegistry.register(
  name: 'forget',
  description: 'Удаляет запись из scratchpad по id (формат "sp-NNN", который ты видишь в блоке scratchpad).',
  parameters: { 'id' => { type: 'string', description: 'ID записи, например "sp-001"' } },
  handler: ->(args, ctx) {
    Agent::Scratchpad.remove(ctx[:chat_id], args['id'].to_s) ? "Забыл #{args['id']}" : "Запись #{args['id']} не найдена"
  }
)

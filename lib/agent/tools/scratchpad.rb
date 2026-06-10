Agent::ToolRegistry.register(
  name: 'remember',
  description: 'Сохраняет запись в scratchpad — твою рабочую память между сообщениями. НЕ для фактов о мире (knowledge_add) и не для одноразовых ответов на текущий вопрос (он уже в чате).
Используй когда:
- пообещал пользователю что-то на будущее («вернусь к этому», «после X сделаю Y») → intentions
- ждёшь от пользователя ответа/действия («отпишу как дойду») → expectations
- заметил настроение или паттерн, который стоит учитывать дальше → notes
Откладываемые тулзы (rate-limited и т.п.) сохраняются в scratchpad автоматически — повторно вызывать remember для них не нужно.',
  parameters: {
    'category' => { type: 'string', description: 'intentions | notes | expectations' },
    'content'  => { type: 'string', description: 'Текст записи, одно предложение' },
  },
  handler: ->(args, ctx) {
    category = args['category'].to_s
    unless Agent::Scratchpad::EVICTABLE_CATEGORIES.include?(category)
      next "Неизвестная категория '#{category}'. Допустимые: #{Agent::Scratchpad::EVICTABLE_CATEGORIES.join(', ')} (правила игры — через set_rule)"
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

Agent::ToolRegistry.register(
  name: 'remember',
  description: 'Сохраняет запись в твой scratchpad — рабочую память между сообщениями. НЕ для фактов о мире — для них есть knowledge_add. Категории: "intentions" (что собираюсь сделать), "notes" (наблюдения), "expectations" (что жду от пользователей).
КОГДА вызывать (важно — это твоя память на потом):
1. Тулза вернула «попробуй позже / через N мин / rate limit / retry later» — обязательно сохрани в intentions что именно надо доделать и когда. Иначе ты забудешь и пользователь не получит обещанное.
2. Пообещал пользователю что-то на будущее («напомню завтра», «вернусь к этому когда X», «после Y сделаю Z») — клади в intentions.
3. Пользователь обещал тебе follow-up («отпишу как дойду», «расскажу как закончу») — клади в expectations.
4. Заметил повторяющийся паттерн или настроение участника, на которое стоит реагировать иначе — клади в notes.
НЕ вызывай для одноразовых ответов на текущий вопрос — твой ответ уже в чате, помнить его не надо.',
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

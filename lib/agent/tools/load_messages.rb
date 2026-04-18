Agent::ToolRegistry.register(
  name: 'load_messages',
  description: 'Загружает окно сообщений из истории чата относительно message_id (поле id или reply_to в контексте). direction: "before" — раньше анкера, "after" — позже, "around" — вокруг. Используй чтобы восстановить ветку при ссылке на сообщение вне окна контекста. Результат фильтруется по тому же треду, что и анкер.',
  parameters: {
    'anchor_id' => { type: 'integer', description: 'Telegram message_id, относительно которого загрузить историю' },
    'direction' => { type: 'string',  description: 'before | after | around (по умолчанию before)', optional: true },
    'count'     => { type: 'integer', description: 'Сколько сообщений вернуть (1–50, по умолчанию 10)', optional: true },
  },
  handler: ->(args, ctx) {
    anchor_id = args['anchor_id'].to_i
    direction = %w[before after around].include?(args['direction']) ? args['direction'] : 'before'
    count     = args['count'].to_i
    count     = count < 1 ? 10 : [count, 50].min

    anchor_min = Message.where(chat_id: ctx[:chat_id], message_id: anchor_id)
      .pluck(:created_at, :message_thread_id).first
    next "Сообщение с id=#{anchor_id} не найдено" unless anchor_min
    anchor_ts, anchor_thread = anchor_min

    scope = Message.left_outer_joins(:user)
      .select(ChatContext::SELECT_COLS + ', messages.created_at')
      .where(chat_id: ctx[:chat_id])
    scope = scope.where(message_thread_id: anchor_thread) if anchor_thread

    rows = case direction
    when 'before'
      scope.where('messages.created_at < ?', anchor_ts).order('messages.created_at DESC').limit(count).reverse
    when 'after'
      scope.where('messages.created_at > ?', anchor_ts).order('messages.created_at ASC').limit(count).to_a
    when 'around'
      half = count / 2
      anchor_row = scope.where(message_id: anchor_id).first
      before = scope.where('messages.created_at < ?', anchor_ts).order('messages.created_at DESC').limit(half).reverse
      after  = scope.where('messages.created_at > ?', anchor_ts).order('messages.created_at ASC').limit(count - half - 1).to_a
      [*before, anchor_row, *after].compact
    end

    next 'Нет сообщений в выбранном диапазоне' if rows.empty?
    rows.map { |r| ChatContext.serialize_msg(r) }.to_json
  }
)

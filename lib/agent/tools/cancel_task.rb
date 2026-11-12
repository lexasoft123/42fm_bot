require_relative '../../task_cancellation'

module Agent::CancelTaskAuthorization
  module_function

  def authorized?(ctx, task_id)
    return false unless ctx[:user_initiated] && task_id.is_a?(Integer) && task_id.positive?
    text = (ctx[:original_request_text] || ctx[:request_text]).to_s.strip
    return false if text.match?(/[?？]|```|`|[«»“”"]|(?:^|[[:space:],])(?:если|когда|возможно|вдруг|услови\S*|например|пример|как|ли|if|when|whether|example)(?=$|[[:space:],])/i)
    return false unless text.match?(/\A\s*(?:бот\s*,?\s+)?(?:(?:пожалуйста|please)\s*[, ]\s*)?(?:отмени(?:те)?|отменяй(?:те)?|cancel)(?=$|[[:space:],!])/i)
    prefix = '(?:бот\s*,?\s+)?(?:(?:пожалуйста|please)\s*[, ]\s*)?(?:отмени(?:те)?|отменяй(?:те)?|cancel)'
    explicit = text.match(/\A\s*#{prefix}\s+(?:(?:задачу|задача|task)\s*#?|#)(\d+)\s*[!.]*\s*\z/i)
    return explicit[1].to_i == task_id if explicit
    # Bot prose is not durable task provenance. Until acknowledgements carry
    # an authenticated task correlation, a reply must include the task ID.
    false
  end
end

Agent::ToolRegistry.register(
  name: 'cancel_task',
  description: 'Отменяет только свою задачу генерации картинки, пока она ещё не начала выполняться. Используй, когда пользователь явно просит отменить конкретную задачу. Нужен номер задачи; не угадывай его.',
  parameters: {
    'task_id' => { type: 'integer', description: 'Положительный номер задачи из подтверждённого сообщения о запуске' },
  },
  handler: ->(args, ctx) {
    raw_id = args['task_id']
    task_id = raw_id.is_a?(Integer) ? raw_id : nil
    unless Agent::CancelTaskAuthorization.authorized?(ctx, task_id)
      next 'Для отмены явно укажи номер задачи.'
    end
    outcome = TaskCancellation.cancel(
      task_id: task_id,
      chat_id: ctx[:chat_id],
      user_id: ctx[:user]&.uid,
      forum_thread_id: ctx[:forum_thread_id]
    )

    status, text = case outcome[:status]
    when :cancelled
      [:cancelled, "Задача ##{task_id} отменена до начала работы."]
    when :started
      [:failed, "Задача ##{task_id} уже начала выполняться; отменить её сейчас нельзя."]
    when :not_found
      [:failed, 'Не нашёл такую задачу в этом чате.']
    when :invalid
      [:failed, 'Нужен положительный номер задачи.']
    else
      [:failed, 'Не могу отменить эту задачу: она создана другим пользователем или в другой теме.']
    end

    next text unless status == :cancelled
    Agent::ToolResult.action(
      status: status, action: 'generate_image', task_id: task_id,
      task_type: (task_id ? 'image_generate' : nil),
      phase: :cancelled,
      delivery: :unknown, user_text: text
    )
  }
)

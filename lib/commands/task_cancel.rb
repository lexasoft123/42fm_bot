require_relative '../task_cancellation'
require_relative '../audio_attachment'

module Commands
  class TaskCancel < Base
    PATTERN = /\Aбо[тй][,]?[ \t]+отмени[ \t]+задачу[ \t]+#?(\d+)[ \t]*\z/i

    def match?
      original_text.to_s.match?(PATTERN)
    end

    def execute
      match = original_text.to_s.match(PATTERN)
      return CommandResult.text('Укажи номер задачи для отмены.') unless match
      task_id = match[1].to_i
      forum_thread_id = message.message_thread_id if AudioAttachment.forum?(message)
      outcome = TaskCancellation.cancel(
        task_id: task_id, chat_id: chat_id, user_id: user.uid,
        forum_thread_id: forum_thread_id
      )

      text = case outcome[:status]
      when :cancelled
        "Задача ##{task_id} отменена до начала работы."
      when :started
        "Задача ##{task_id} уже начала выполняться; отменить её сейчас нельзя."
      when :not_found
        'Не нашёл такую задачу в этом чате.'
      when :invalid
        'Укажи положительный номер задачи.'
      else
        'Не могу отменить эту задачу: она создана другим пользователем или в другой теме.'
      end
      CommandResult.text(text)
    end

    private

    def original_text
      message.text || message.caption
    end
  end
end

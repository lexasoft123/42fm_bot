class TaskRunner
  POLL_INTERVAL = 30

  @handlers = {}

  class << self
    def register(task_type, handler_class)
      @handlers[task_type] = handler_class
    end

    def handler_for(task_type)
      @handlers[task_type]
    end

    def start(bot_api)
      Thread.new do
        runner = new(bot_api)
        loop do
          ActiveRecord::Base.connection_pool.with_connection do
            runner.process_pending
          end
          sleep POLL_INTERVAL
        rescue => e
          LOGGER.error "TaskRunner: #{e.class}: #{e.message}"
          sleep POLL_INTERVAL
        end
      end
    end
  end

  def initialize(bot_api)
    @api = bot_api
  end

  def process_pending
    BackgroundTask.pending.find_each do |task|
      handler_class = self.class.handler_for(task.task_type)
      unless handler_class
        LOGGER.error "TaskRunner: unknown task_type '#{task.task_type}'"
        task.mark_failed!("unknown task_type")
        next
      end

      result = handler_class.new.call(task, @api)

      case result
      when :pending
        task.increment_attempts!
        if task.timed_out?
          LOGGER.error "TaskRunner: task #{task.id} (#{task.task_type}) timed out after #{task.attempts} attempts"
          task.mark_failed!('timeout')
          @api.sendMessage(chat_id: task.chat_id, text: "Задача не выполнена (таймаут)") rescue nil
        end
      when :done
        nil # handler already called mark_done! and sent result
      when :failed
        nil # handler already called mark_failed! and sent error
      end
    rescue => e
      LOGGER.error "TaskRunner task #{task.id}: #{e.class}: #{e.message}"
      task.increment_attempts!
      task.mark_failed!(e.message) if task.reload.timed_out?
    end
  end
end

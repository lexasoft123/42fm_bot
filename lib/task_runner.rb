class TaskRunner
  POLL_INTERVAL = 30

  @handlers = {}
  @thread = nil
  @mutex = Mutex.new

  class << self
    def register(task_type, handler_class)
      @handlers[task_type] = handler_class
    end

    def handler_for(task_type)
      @handlers[task_type]
    end

    def start(bot_api)
      @mutex.synchronize do
        if @thread&.alive?
          LOGGER.info "#{name}: already running, updating bot_api"
          @runner&.update_api(bot_api)
          return @thread
        end
        @runner = new(bot_api)
        @thread = Thread.new do
          loop do
            @runner.process_pending
            sleep POLL_INTERVAL
          rescue => e
            LOGGER.error "#{name}: #{e.class}: #{e.message}"
            sleep POLL_INTERVAL
          end
        end
      end
    end
  end

  def initialize(bot_api)
    @api = bot_api
  end

  def update_api(bot_api)
    @api = bot_api
  end

  def process_pending
    tasks = ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.pending.to_a
    end

    tasks.each do |task|
      handler_class = self.class.handler_for(task.task_type)
      unless handler_class
        LOGGER.error "#{self.class.name}: unknown task_type '#{task.task_type}'"
        ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!("unknown task_type") }
        next
      end

      result = handler_class.new.call(task, @api)

      case result
      when :pending
        ActiveRecord::Base.connection_pool.with_connection do
          task.increment_attempts!
          if task.reload.timed_out?
            LOGGER.error "#{self.class.name}: task #{task.id} (#{task.task_type}) timed out after #{task.attempts} attempts"
            task.mark_failed!('timeout')
            begin
              @api.sendMessage(chat_id: task.chat_id, text: "Задача не выполнена (таймаут)")
            rescue => e
              LOGGER.warn "#{self.class.name}: failed to notify chat #{task.chat_id}: #{e.class}: #{e.message}"
            end
          end
        end
      when :done
        nil # handler already called mark_done! and sent result
      when :failed
        nil # handler already called mark_failed! and sent error
      end
    rescue => e
      LOGGER.error "#{self.class.name} task #{task.id}: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
      ActiveRecord::Base.connection_pool.with_connection do
        task.increment_attempts!
        permanent = e.message.match?(/\s4\d{2}[\s{]/)
        if task.reload.timed_out? || permanent
          task.mark_failed!(e.message)
          begin
            @api.sendMessage(chat_id: task.chat_id, text: "Ошибка: #{e.message.truncate(200)}")
          rescue => notify_err
            LOGGER.warn "#{self.class.name}: failed to notify chat #{task.chat_id}: #{notify_err.class}: #{notify_err.message}"
          end
        end
      end
    end
  end
end

require 'concurrent-ruby'
require 'set'

class TaskRunner
  POLL_INTERVAL = 15
  MAX_WORKERS   = 2

  @handlers = {}
  @thread = nil
  @mutex = Mutex.new
  @processing = Set.new
  @processing_mutex = Mutex.new
  @pool = nil

  class << self
    def register(task_type, handler_class)
      @handlers[task_type] = handler_class
    end

    def handler_for(task_type)
      @handlers[task_type]
    end

    def claim(id)
      @processing_mutex.synchronize do
        return false if @processing.include?(id)
        @processing.add(id)
        true
      end
    end

    def release(id)
      @processing_mutex.synchronize { @processing.delete(id) }
    end

    def pool
      @pool ||= Concurrent::ThreadPoolExecutor.new(
        min_threads: 0, max_threads: MAX_WORKERS,
        max_queue: 100, fallback_policy: :discard
      )
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
            @runner.dispatch_pending
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

  def dispatch_pending
    tasks = ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.pending.to_a
    end

    tasks.each do |task|
      next unless self.class.claim(task.id)
      self.class.pool.post do
        ActiveRecord::Base.connection_pool.with_connection { process_one(task) }
      ensure
        self.class.release(task.id)
      end
    end
  end

  def process_one(task)
    handler_class = self.class.handler_for(task.task_type)
    unless handler_class
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}: unknown task_type '#{task.task_type}'"
      task.mark_failed!("unknown task_type")
      return
    end

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = handler_class.new.call(task, @api)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}: handler #{task.task_type}[#{task.id}] took=#{took_ms}ms result=#{result.is_a?(Hash) ? :hash : result.inspect}"

    case result
    when :pending
      task.increment_attempts!
      if task.reload.timed_out?
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}: task #{task.id} (#{task.task_type}) timed out after #{task.attempts} attempts"
        task.mark_failed!('timeout')
        begin
          @api.sendMessage(chat_id: task.chat_id, text: "Задача не выполнена (таймаут)")
        rescue => e
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: failed to notify chat: #{e.class}: #{e.message}"
        end
      end
    when :done, :failed
      nil # handler already updated state
    end
  rescue => e
    transient = e.message.match?(/\s5\d{2}[\s{]/) ||
                e.is_a?(Net::OpenTimeout) || e.is_a?(Net::ReadTimeout) ||
                e.is_a?(Errno::ECONNRESET) || e.is_a?(Errno::ECONNREFUSED) ||
                e.is_a?(OpenSSL::SSL::SSLError) || e.is_a?(SocketError)
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name} task #{task.id} transient: #{e.class}: #{e.message}" if transient
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name} task #{task.id}: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}" unless transient
    task.increment_attempts! unless transient
    permanent = e.message.match?(/\s4\d{2}[\s{]/)
    if task.reload.timed_out? || permanent
      task.mark_failed!(e.message)
      begin
        @api.sendMessage(chat_id: task.chat_id, text: "Ошибка: #{e.message.truncate(200)}")
      rescue => notify_err
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}: failed to notify chat: #{notify_err.class}: #{notify_err.message}"
      end
    end
  end
end

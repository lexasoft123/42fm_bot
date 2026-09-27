require 'concurrent-ruby'
require 'set'
require_relative 'agent/error_reporter'

class TaskRunner
  POLL_INTERVAL = 15
  MAX_WORKERS   = 2

  # Classification of an exception raised out of a handler (#process_one):
  # transient → retried without spending an attempt; permanent → task failed
  # now with a raw "Ошибка: …" chat notice. Handlers that would rather fail a
  # permanent error themselves (own notice + agent_event) check
  # `TaskRunner.permanent_error?` before re-raising; SunoClient#submit_error
  # renders HTTP/body codes so these match.
  TRANSIENT_ERROR_RE = /\s5\d{2}[\s{]/
  PERMANENT_ERROR_RE = /\s4\d{2}[\s{]/

  def self.permanent_error?(error)
    error.message.to_s.match?(PERMANENT_ERROR_RE)
  end

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

    # Read-only runtime snapshot for diagnostics. Keep mutable internals behind
    # the processing mutex and return copies so callers cannot affect dispatch.
    def state_snapshot
      processing_ids = @processing_mutex.synchronize { @processing.to_a.sort }
      {
        running: !!@thread&.alive?,
        poll_interval_seconds: POLL_INTERVAL,
        max_workers: MAX_WORKERS,
        processing_task_ids: processing_ids,
        registered_task_types: @handlers.keys.sort,
      }
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
            @runner.poll_cycle
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

  # One isolated poll iteration. Keeping the boundary outside the forever-loop
  # makes the global error bridge directly testable and ensures the next cycle
  # still runs after a DB/dispatcher failure.
  def poll_cycle
    dispatch_pending
  rescue => e
    LOGGER.error "#{self.class.name}: #{e.class}: #{e.message}"
    Agent::ErrorReporter.report_global(source: 'task_runner.poller', error: e)
    nil
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
      Agent::ErrorReporter.report_task_failure(task, source: 'task_runner.unknown_task')
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
        notify_chat(task.chat_id, "Задача не выполнена (таймаут)")
        Agent::ErrorReporter.report_task_failure(task, source: 'task_runner.timeout')
      end
    when :failed
      # Feature handlers may already have emitted a richer event. The reporter
      # detects it by parent_task_id and only supplies a generic fallback.
      Agent::ErrorReporter.report_task_failure(task, source: "task_handler.#{task.task_type}")
    when :done
      nil
    end
  rescue => e
    transient = e.message.match?(TRANSIENT_ERROR_RE) ||
                e.is_a?(Net::OpenTimeout) || e.is_a?(Net::ReadTimeout) ||
                e.is_a?(Errno::ECONNRESET) || e.is_a?(Errno::ECONNREFUSED) ||
                e.is_a?(OpenSSL::SSL::SSLError) || e.is_a?(SocketError)
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name} task #{task.id} transient: #{e.class}: #{e.message}" if transient
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name} task #{task.id}: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}" unless transient
    task.increment_attempts! unless transient
    permanent = e.message.match?(PERMANENT_ERROR_RE)
    if task.reload.timed_out? || permanent
      task.mark_failed!(e.message)
      notify_chat(task.chat_id, "Ошибка: #{e.message.truncate(200)}")
      Agent::ErrorReporter.report_task_failure(task, source: "task_handler.#{task.task_type}")
    end
  end

  def notify_chat(chat_id, text)
    resp = @api.sendMessage(chat_id: chat_id, text: text)
    Message.persist_bot_reply(chat_id: chat_id, body: text, response: resp)
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: failed to notify chat: #{e.class}: #{e.message}"
  end
end

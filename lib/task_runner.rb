require 'concurrent-ruby'
require 'net/http'
require 'openssl'
require 'socket'
require 'set'
require_relative 'agent/error_reporter'
require_relative 'task_handlers/task_delivery_errors'

class TaskRunner
  POLL_INTERVAL = 15
  MAX_WORKERS   = 2

  # Classification of an exception raised out of a handler (#process_one):
  # every raised handler cycle spends one bounded attempt; transient failures
  # remain pending until that budget is exhausted, while permanent ones fail
  # immediately with a raw "Ошибка: …" notice. Feature handlers that own a
  # typed notice handle their own budget; NotificationTransitionPending is
  # reserved for replaying an atomic image terminal+notice transition.
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
        ActiveRecord::Base.connection_pool.with_connection { process_one(task.id) }
      ensure
        self.class.release(task.id)
      end
    end
  end

  def process_one(task_or_id)
    dispatch_id = task_or_id.is_a?(BackgroundTask) ? task_or_id.id : task_or_id
    task = nil
    task = BackgroundTask.find_by(id: dispatch_id)
    return unless task && task.status == 'pending'

    # Queued work gets one atomic first-start claim. Later poll/delivery cycles
    # remain dispatchable, but their phase is owned by the handler and must not
    # be rewritten to processing on every poll.
    if task.lifecycle_phase.to_s == 'queued'
      return unless task.claim_start!
      task.reload
    end

    handler_class = self.class.handler_for(task.task_type)
    unless handler_class
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}: unknown task_type '#{task.task_type}'"
      task.mark_failed!("unknown task_type")
      Agent::ErrorReporter.report_task_failure(task, source: 'task_runner.unknown_task')
      return
    end

    # `attempts` counts handler/poll cycles. Lifecycle phase is separate and
    # only explicit failures increment retry_count. Existing non-queued phases
    # are preserved for the handler's own retry/delivery/persistence logic.
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = handler_class.new.call(task, @api)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}: handler #{task.task_type}[#{task.id}] took=#{took_ms}ms result=#{result.is_a?(Hash) ? :hash : result.inspect}"

    case result
    when :pending
      task.increment_attempts!
      if task.reload.timed_out?
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}: task #{task.id} (#{task.task_type}) timed out after #{task.attempts} attempts"
        if deterministic_image_failure_event?(task)
          # A timeout cannot prove whether Telegram accepted a request whose
          # response was lost. Preserve the receipt when present; otherwise
          # leave delivery unknown instead of claiming it failed.
          delivery = task.params_hash['reply_receipt'] ? 'delivered' : 'unknown'
          task.mark_failed!('failure notice delivery exhausted', delivery_status: delivery)
        else
          task.mark_failed!('timeout')
          notify_chat(task.chat_id, "Задача не выполнена (таймаут)")
          Agent::ErrorReporter.report_task_failure(task, source: 'task_runner.timeout')
        end
      end
    when :failed
      # Feature handlers may already have emitted a richer event. The reporter
      # detects it by parent_task_id and only supplies a generic fallback.
      Agent::ErrorReporter.report_task_failure(task, source: "task_handler.#{task.task_type}")
    when :done
      nil
    end
  rescue => e
    if e.is_a?(BackgroundTask::NotificationTransitionPending) &&
       (durable_task = durable_notification_checkpoint(dispatch_id))
      LOGGER.warn "[chat=#{durable_task.chat_id}] #{self.class.name} task #{dispatch_id}: notification transition pending: #{Agent::ErrorReporter.sanitize(e.message)}"
      durable_task.mark_retrying! if durable_task.status == 'pending' && durable_task.lifecycle_phase != 'retrying'
      return
    end

    unless task
      LOGGER.error "#{self.class.name} task #{dispatch_id}: failed before task row could be loaded: #{e.class}: #{Agent::ErrorReporter.sanitize(e.message)}"
      return
    end

    structured_telegram = TaskDeliveryErrors.structured_telegram_response?(e)
    transient = TaskDeliveryErrors.retryable?(e) ||
                (!structured_telegram && e.message.match?(TRANSIENT_ERROR_RE))
    safe_message = Agent::ErrorReporter.sanitize(e.message)
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name} task #{task.id} transient: #{e.class}: #{safe_message}" if transient
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name} task #{task.id}: #{e.class}: #{safe_message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}" unless transient
    task.increment_attempts!
    permanent = TaskDeliveryErrors.definitive_telegram_rejection?(e) ||
                (!structured_telegram && e.message.match?(PERMANENT_ERROR_RE))
    if task.reload.timed_out? || permanent
      task.mark_failed!(safe_message)
      notify_chat(task.chat_id, "Ошибка: #{safe_message.truncate(200)}")
      Agent::ErrorReporter.report_task_failure(task, source: "task_handler.#{task.task_type}")
    elsif task.status == 'pending' && task.lifecycle_phase != 'retrying'
      task.mark_retrying!
    end
  end

  def deterministic_image_failure_event?(task)
    return false unless task.task_type == 'agent_event' && defined?(ImageFailureNotice)
    ImageFailureNotice::EVENT_TEXT.key?(task.params_hash['event_type'].to_s)
  rescue JSON::ParserError
    false
  end

  # The no-attempt transition retry is safe only when a fresh DB read proves
  # the handler's terminal outcome checkpoint was committed.
  def durable_notification_checkpoint(task_id)
    candidate = BackgroundTask.find_by(id: task_id)
    return unless candidate&.status == 'pending'
    return unless candidate.params_hash['terminal_failure_transition'].is_a?(Hash)

    candidate
  rescue
    nil
  end

  def notify_chat(chat_id, text)
    resp = @api.sendMessage(chat_id: chat_id, text: text)
    Message.persist_bot_reply(chat_id: chat_id, body: text, response: resp)
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: failed to notify chat: #{e.class}: #{e.message}"
  end
end

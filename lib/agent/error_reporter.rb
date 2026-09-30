require 'json'
require 'digest'

module Agent
  # Single bridge from runtime failures back into the agent. Synchronous tool
  # failures become tool-result JSON in the current loop; asynchronous/runtime
  # failures become agent_event tasks for the affected chat.
  module ErrorReporter
    AGENT_EVENT_HOUR_CAP = 10
    PARENTLESS_DEDUPE_WINDOW = 300
    MAX_SUMMARY_CHARS = 900

    URL_RE = %r{https?://[^\s"'<>]+}i
    DATA_URI_RE = %r{data:[^;,\s]+;base64,[A-Za-z0-9+/=]+}i
    AUTH_HEADER_RE = /((?:["']?)(?:authorization|proxy-authorization)(?:["']?)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|(?:bearer|basic|token)?\s*[^\s,;}]+)/i
    SECRET_ASSIGNMENT_RE = /((?:["']?)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|client[_-]?secret|secret|password|passwd|cookie|session)(?:["']?)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/i
    JWT_RE = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/
    PROVIDER_KEY_RE = /\b(?:sk|pk|key|token|secret)-[A-Za-z0-9+\/_=.\-]{8,}\b/i
    TOKEN_RE = /\b[A-Za-z0-9+\/_=.\-]{24,}\b/

    module_function

    def tool_result(source:, error:)
      JSON.generate(
        status: 'error',
        source: sanitize(source),
        error_class: error_class(error),
        message: sanitize(error_message(error))
      )
    end

    def report(chat_id:, source:, error:, parent_task: nil, context: nil)
      return nil if chat_id.nil?
      return nil if parent_task&.task_type == 'agent_event'

      summary = [
        "Источник: #{sanitize(source)}",
        "Ошибка: #{error_class(error)}: #{sanitize(error_message(error))}",
        ("Контекст: #{sanitize(context)}" if context && !context.to_s.empty?),
      ].compact.join(' | ')

      fingerprint = error_fingerprint(source, error)
      if parent_task.nil? && existing_parentless_event(chat_id, fingerprint)
        LOGGER.warn "[chat=#{chat_id}] Agent::ErrorReporter: coalesced repeated #{sanitize(source)}" if defined?(LOGGER)
        return nil
      end

      emit(
        chat_id: chat_id,
        event_type: 'runtime_error',
        summary: summary,
        parent_task: parent_task,
        rate_limited: parent_task.nil?,
        fingerprint: fingerprint
      )
    rescue => reporter_error
      LOGGER.warn "[chat=#{chat_id}] Agent::ErrorReporter: failed to report #{sanitize(source)}: " \
                  "#{reporter_error.class}: #{sanitize(reporter_error.message)}" if defined?(LOGGER)
      nil
    end

    def report_global(source:, error:)
      ids = if defined?(Settings) && Settings.respond_to?(:auth)
        Settings.auth['super_admin_uids'].to_a
      else
        []
      end
      ids.uniq.filter_map { |chat_id| report(chat_id: chat_id, source: source, error: error) }
    rescue => reporter_error
      LOGGER.warn "Agent::ErrorReporter: failed global report #{sanitize(source)}: #{reporter_error.class}: #{sanitize(reporter_error.message)}" if defined?(LOGGER)
      []
    end

    def report_task_failure(task, source: 'background_task')
      return nil unless task
      return nil if task.task_type == 'agent_event'
      existing = existing_event_for(task)
      return existing if existing

      fresh = BackgroundTask.find_by(id: task.id) || task
      error = fresh.result_hash['error']
      context = "task ##{fresh.id}, type=#{fresh.task_type}, attempts=#{fresh.attempts}/#{fresh.max_attempts}"
      report(chat_id: fresh.chat_id, source: source, error: error, parent_task: fresh, context: context)
    end

    # Shared event creation primitive. Feature handlers keep their tailored
    # event types/prompts; generic failures use #report above.
    def emit(chat_id:, event_type:, summary:, parent_task: nil, rate_limited: true, fingerprint: nil,
             user_notified: false, forum_thread_id: nil)
      return nil if chat_id.nil?
      return nil if parent_task&.task_type == 'agent_event'

      if rate_limited && recent_event_count(chat_id) >= AGENT_EVENT_HOUR_CAP
        LOGGER.warn "[chat=#{chat_id}] agent_event rate limit (#{AGENT_EVENT_HOUR_CAP}/hour) — suppressing #{sanitize(event_type)}" if defined?(LOGGER)
        return nil
      end

      BackgroundTask.transaction do
        delivery_failure = %w[song_delivery_failed separation_delivery_failed].include?(event_type.to_s)
        event = BackgroundTask.create!(
          task_type: 'agent_event',
          chat_id: chat_id,
          parent_task_id: parent_task&.id,
          max_attempts: 5,
          delivery_status: delivery_failure ? 'failed' : 'unknown',
          params: {
            event_type: event_type,
            parent_task_id: parent_task&.id,
            parent_task_type: parent_task&.task_type,
            error_fingerprint: fingerprint,
            summary: sanitize(summary),
            user_notified: (true if user_notified),
            forum_thread_id: forum_thread_id,
          }.compact.to_json
        )
        parent_task&.update!(delivery_status: 'failed') if delivery_failure
        event
      end
    end

    def existing_parentless_event(chat_id, fingerprint)
      BackgroundTask.where(chat_id: chat_id, task_type: 'agent_event')
        .where('created_at > ?', Time.now - PARENTLESS_DEDUPE_WINDOW)
        .order(id: :desc).limit(AGENT_EVENT_HOUR_CAP).any? do |event|
          event.params_hash['event_type'] == 'runtime_error' &&
            event.params_hash['error_fingerprint'] == fingerprint
        end
    end

    def existing_event_for(task)
      BackgroundTask.where(chat_id: task.chat_id, task_type: 'agent_event')
        .where(parent_task_id: task.id)
        .where('created_at >= ?', task.created_at || Time.at(0))
        .order(id: :desc).first
    end

    def recent_event_count(chat_id)
      BackgroundTask.where(chat_id: chat_id, task_type: 'agent_event')
        .where('created_at > ?', Time.now - 3600).count
    end

    def sanitize(value)
      value.to_s
        .gsub(DATA_URI_RE, '[data]')
        .gsub(URL_RE, '[url]')
        .gsub(AUTH_HEADER_RE) { "#{$1}[redacted]" }
        .gsub(SECRET_ASSIGNMENT_RE) { "#{$1}[redacted]" }
        .gsub(JWT_RE, '[redacted]')
        .gsub(PROVIDER_KEY_RE, '[redacted]')
        .gsub(TOKEN_RE, '[redacted]')
        .slice(0, MAX_SUMMARY_CHARS)
    end

    def tool_error_result?(value)
      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Hash) && parsed['status'] == 'error'
    rescue JSON::ParserError
      false
    end

    def error_fingerprint(source, error)
      Digest::SHA256.hexdigest("#{sanitize(source)}\0#{error_class(error)}\0#{sanitize(error_message(error))}")[0, 20]
    end

    def error_message(error)
      error.respond_to?(:message) ? error.message : error.to_s
    end

    def error_class(error)
      error.is_a?(Exception) ? error.class.name : 'RuntimeError'
    end
  end
end

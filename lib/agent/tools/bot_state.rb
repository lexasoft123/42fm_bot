require 'json'
require 'time'
require_relative '../error_reporter'

module Agent
  module BotState
    DEFAULT_LIMIT = 5
    MAX_LIMIT = 5
    TOOL_RESULT_BUDGET = 1_900
    SUMMARY_KEYS = %w[request title topic genre artist].freeze
    MODEL_ROLES = %w[agent agent_vision image_prompt lyrics knowledge knowledge_review].freeze

    module_function

    def snapshot(chat_id:, limit: DEFAULT_LIMIT, task_id: nil, view: 'overview')
      limit = [[limit.to_i, 1].max, MAX_LIMIT].min
      runner = runner_snapshot
      processing_ids = runner[:processing_task_ids] || []
      chat_scope = BackgroundTask.where(chat_id: chat_id)
      base = {
        generated_at: Time.now.utc.iso8601,
        uptime_seconds: uptime_seconds,
        runner: runner,
        queue: {
          global_by_status: BackgroundTask.group(:status).count,
          global_pending_by_type: BackgroundTask.where(status: 'pending').group(:task_type).count,
          current_chat_by_status: chat_scope.group(:status).count,
          current_chat_pending_by_type: chat_scope.where(status: 'pending').group(:task_type).count,
        },
      }.compact

      id = task_id.to_i
      if id.positive? || view == 'tasks'
        tasks, task_error = selected_tasks(chat_scope, limit: limit, task_id: task_id)
        base[:task_error] = task_error if task_error
        base[:current_chat_tasks] = tasks.map { |task| serialize_task(task, processing_ids) }
      else
        base[:models] = model_snapshot
      end
      base
    end

    def selected_tasks(scope, limit:, task_id:)
      id = task_id.to_i
      return [scope.order(created_at: :desc).limit(limit).to_a, nil] unless id.positive?

      task = scope.find_by(id: id)
      task ? [[task], nil] : [[], "Task ##{id} is not present in this chat"]
    end

    def render(snapshot)
      json = JSON.generate(snapshot)
      return json if json.length <= TOOL_RESULT_BUDGET

      snapshot[:truncated] = true
      tasks = snapshot[:current_chat_tasks]
      while tasks&.length.to_i > 1 && JSON.generate(snapshot).length > TOOL_RESULT_BUDGET
        tasks.pop
      end
      snapshot[:runner]&.delete(:registered_task_types) if JSON.generate(snapshot).length > TOOL_RESULT_BUDGET
      snapshot[:queue]&.delete(:global_pending_by_type) if JSON.generate(snapshot).length > TOOL_RESULT_BUDGET
      json = JSON.generate(snapshot)
      return json if json.length <= TOOL_RESULT_BUDGET

      JSON.generate(error: 'Bot state exceeded the diagnostic output budget', truncated: true)
    end

    def serialize_task(task, processing_ids)
      params = parse_json(task.params)
      result = parse_json(task.result)
      summary = SUMMARY_KEYS.filter_map do |key|
        value = params[key].to_s.strip
        value unless value.empty?
      end.join(' / ')
      summary = task.task_type if summary.empty?

      {
        id: task.id,
        type: task.task_type,
        status: task.status,
        in_flight: processing_ids.include?(task.id),
        attempts: task.attempts,
        max_attempts: task.max_attempts,
        created_at: task.created_at&.utc&.iso8601,
        updated_at: task.updated_at&.utc&.iso8601,
        age_seconds: [(Time.now - task.created_at).to_i, 0].max,
        idle_seconds: [(Time.now - task.updated_at).to_i, 0].max,
        summary: safe_text(summary, 120),
        provider: params['provider'],
        model: params['model'],
        external_id_present: !task.external_id.to_s.empty?,
        error: result['error'] ? safe_text(result['error'], 160) : nil,
      }.compact
    end

    def parse_json(value)
      parsed = JSON.parse(value.to_s.empty? ? '{}' : value)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def safe_text(value, limit)
      Agent::ErrorReporter.sanitize(value)
        .gsub(/\s+/, ' ')
        .strip[0, limit]
    end

    def runner_snapshot
      return { running: false, unavailable: true } unless defined?(TaskRunner)
      TaskRunner.state_snapshot
    end

    def model_snapshot
      return {} unless defined?(Settings) && Settings.respond_to?(:chat_gpt)
      settings = Settings.chat_gpt['settings'] || {}
      MODEL_ROLES.each_with_object({}) do |role, out|
        config = settings[role]
        next unless config
        out[role] = {
          provider: config['provider'],
          model: config['model'],
          max_tokens: config['max_tokens'],
          thinking: config.dig('thinking', 'type'),
        }.compact
      end
    end

    def uptime_seconds
      return unless defined?(MessageResponder::PROCESS_START)
      [(Time.now - MessageResponder::PROCESS_START).to_i, 0].max
    end
  end
end

Agent::ToolRegistry.register(
  name: 'inspect_bot_state',
  description: 'Read-only диагностика внутреннего состояния бота. Используй по просьбе администратора проверить очередь, активную/зависшую задачу, состояние TaskRunner или фактически настроенные модели. view=overview показывает рантайм/модели/агрегаты; view=tasks — до 5 последних задач текущего чата; task_id — одну задачу. Секреты и внешние URL редактируются.',
  parameters: {
    'task_id' => { type: 'integer', description: 'Необязательный ID задачи для подробной проверки; задача должна принадлежать текущему чату', optional: true },
    'view' => { type: 'string', description: 'overview | tasks; по умолчанию overview', enum: %w[overview tasks], optional: true },
    'limit' => { type: 'integer', description: 'Число последних задач текущего чата, 1–5; по умолчанию 5', optional: true },
  },
  admin_only: true,
  handler: ->(args, ctx) {
    begin
      Agent::BotState.render(
        Agent::BotState.snapshot(
          chat_id: ctx[:chat_id],
          task_id: args['task_id'],
          view: args['view'] == 'tasks' ? 'tasks' : 'overview',
          limit: args['limit'] || Agent::BotState::DEFAULT_LIMIT,
        )
      )
    rescue => e
      LOGGER.warn "[chat=#{ctx[:chat_id]}] inspect_bot_state failed: #{e.class}: #{e.message}"
      JSON.generate(error: 'Bot state is temporarily unavailable')
    end
  }
)

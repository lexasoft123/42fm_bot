require 'json'
require 'time'
require_relative '../tool_result'

module Agent
  module TaskStatus
    DEFAULT_LIMIT = 5
    MAX_LIMIT = 5
    OMITTED = Object.new.freeze

    USER_FACING_TASK_TYPES = %w[
      image_generate suno_generate suno_add_vocals suno_cover_audio
      suno_cover_art suno_wav_convert suno_separate_vocals
    ].freeze

    ACTION_BY_TASK_TYPE = {
      'image_generate' => 'generate_image',
      'suno_generate' => 'compose_song',
      'suno_add_vocals' => 'add_vocals',
      'suno_cover_audio' => 'cover_audio',
      'suno_cover_art' => 'cover_art',
      'suno_wav_convert' => 'convert_to_wav',
      'suno_separate_vocals' => 'separate_vocals',
    }.freeze

    SAFE_COLUMNS = %i[
      id task_type status lifecycle_phase delivery_status retry_count
      attempts max_attempts updated_at
    ].freeze

    module_function

    def snapshot(chat_id:, task_id: OMITTED, limit: OMITTED)
      id_result = validate_task_id(task_id)
      return error_snapshot('invalid_task_id', 'task_id должен быть положительным целым числом') unless id_result[:valid]

      limit_result = validate_limit(limit)
      return error_snapshot('invalid_limit', 'limit должен быть целым числом') unless limit_result[:valid]

      scope = BackgroundTask.where(chat_id: chat_id).select(*SAFE_COLUMNS)
      tasks = if id_result[:provided]
        task = scope.find_by(id: id_result[:value])
        task ? [task] : []
      else
        scope.where(task_type: USER_FACING_TASK_TYPES)
             .order(created_at: :desc, id: :desc)
             .limit(limit_result[:value]).to_a
      end

      {
        status: 'ok',
        requested_task_id: id_result[:provided] ? id_result[:value] : nil,
        found: !tasks.empty?,
        tasks: tasks.map { |task| serialize(task) },
      }.compact
    end

    # Deliberately excludes params/results, provider/model identifiers, URLs,
    # prompts, external IDs and parent/internal event metadata. Every field is
    # a compact indexed/typed lifecycle column; no JSON payload is parsed.
    def serialize(task)
      phase = normalized_phase(task)
      {
        id: task.id,
        type: task.task_type,
        status: task.status,
        phase: phase,
        processing_cycles: task.attempts,
        max_processing_cycles: task.max_attempts,
        retry_count: task.retry_count.to_i,
        retrying: phase == 'retrying',
        delivery: normalized_delivery(task, phase: phase),
        updated_at: task.updated_at&.utc&.iso8601,
      }
    end

    def normalized_phase(task)
      # Coarse terminal state is authoritative. Conversely, a still-pending
      # row must never expose a stale terminal phase while a bounded retry is
      # still eligible to run.
      return 'failed' if task.status == 'failed'
      return 'completed' if task.status == 'done'

      phase = task.lifecycle_phase.to_s
      active_phases = Agent::ToolResult::ACTION_PHASES - %w[completed failed deferred]
      return phase if active_phases.include?(phase)

      'queued'
    end

    def normalized_delivery(task, phase: normalized_phase(task))
      value = task.delivery_status.to_s
      # `failed` is terminal delivery evidence. During an active retry the
      # complete task contract is still pending even when an earlier attempt
      # (or an earlier batch) failed.
      return 'pending' if task.status == 'pending' && phase != 'failed' && value == 'failed'
      Agent::ToolResult::ACTION_DELIVERIES.include?(value) ? value : 'unknown'
    end

    def validate_task_id(value)
      return { valid: true, provided: false } if value.equal?(OMITTED)
      return { valid: false, provided: true } unless value.is_a?(Integer) && value.positive?

      { valid: true, provided: true, value: value }
    end

    def validate_limit(value)
      return { valid: true, value: DEFAULT_LIMIT } if value.equal?(OMITTED)
      return { valid: false } unless value.is_a?(Integer)

      { valid: true, value: [[value, 1].max, MAX_LIMIT].min }
    end

    def error_snapshot(code, message)
      { status: 'error', code: code, message: message, found: false, tasks: [] }
    end

    def action_for(task)
      ACTION_BY_TASK_TYPE.fetch(task[:type], 'task_status')
    end

    def action_status_for(task)
      return 'failed' if task[:phase] == 'failed'
      return 'sent' if task[:phase] == 'completed' && task[:delivery] == 'delivered'
      return 'failed' if task[:phase] == 'completed' && task[:delivery] == 'failed'
      return 'deferred' if task[:phase] == 'completed'

      'queued'
    end

    def action_item(task)
      {
        action: action_for(task),
        task_id: task[:id],
        task_type: task[:type],
        status: action_status_for(task),
        phase: task[:phase],
        delivery: task[:delivery],
      }
    end

    def action_result(snapshot)
      unless snapshot[:status] == 'ok' && snapshot[:found]
        return Agent::ToolResult.action(
          status: :deferred, action: 'task_status', phase: :deferred,
          delivery: :unknown, task_id: snapshot[:requested_task_id],
          user_text: JSON.generate(snapshot)
        )
      end

      tasks = snapshot.fetch(:tasks)
      if tasks.length > 1
        all_delivered = tasks.all? { |task| task[:phase] == 'completed' && task[:delivery] == 'delivered' }
        return Agent::ToolResult.action(
          status: all_delivered ? :sent : :deferred,
          action: 'task_status',
          phase: all_delivered ? :completed : :deferred,
          delivery: all_delivered ? :delivered : :unknown,
          items: tasks.map { |task| action_item(task) },
          user_text: JSON.generate(
            status: 'ok', found: true, count: tasks.length,
            task_ids: tasks.map { |task| task[:id] },
            note: 'Подробные статусы находятся в структурированном поле items.'
          )
        )
      end

      task = tasks.first
      Agent::ToolResult.action(
        status: action_status_for(task),
        action: action_for(task),
        task_id: task[:id],
        task_type: task[:type],
        phase: task[:phase],
        delivery: task[:delivery],
        user_text: JSON.generate(snapshot)
      )
    end
  end
end

Agent::ToolRegistry.register(
  name: 'task_status',
  description: 'Проверяет фактический статус фоновой задачи только в текущем чате. Используй перед утверждениями, что картинка/трек/другая задача всё ещё в очереди, выполняется, завершилась или упала. Передай task_id из результата запуска задачи; без task_id вернутся до 5 последних пользовательских задач этого чата.',
  parameters: {
    'task_id' => { type: 'integer', description: 'ID задачи из результата инструмента запуска', optional: true },
    'limit' => { type: 'integer', description: 'Количество последних задач, 1–5; по умолчанию 5', optional: true },
  },
  handler: ->(args, ctx) {
    begin
      task_id = args.key?('task_id') ? args['task_id'] : Agent::TaskStatus::OMITTED
      limit = args.key?('limit') ? args['limit'] : Agent::TaskStatus::OMITTED
      snapshot = Agent::TaskStatus.snapshot(chat_id: ctx[:chat_id], task_id: task_id, limit: limit)
      Agent::TaskStatus.action_result(snapshot)
    rescue => e
      LOGGER.warn "[chat=#{ctx[:chat_id]}] task_status failed: #{e.class}: #{Agent::ErrorReporter.sanitize(e.message)}"
      Agent::TaskStatus.action_result(
        Agent::TaskStatus.error_snapshot('unavailable', 'Статус задач временно недоступен')
      )
    end
  }
)

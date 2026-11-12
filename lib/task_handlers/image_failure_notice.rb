# Deterministic user-facing wording for image task failures. Only closed enums
# cross from provider diagnostics into user-visible text.
module ImageFailureNotice
  EVENT_TEXT = {
    'image_failed' => 'Картинку не удалось сгенерировать',
    'image_failed_after_retries' => 'Картинку не удалось сгенерировать после повторных попыток',
    'image_delivery_failed' => 'Картинка создана, но Telegram не подтвердил доставку',
    'image_persistence_failed' => 'Telegram принял картинку, но бот не смог сохранить подтверждение доставки',
  }.freeze

  STAGES = {
    'submit' => 'при отправке запроса',
    'poll' => 'во время ожидания результата',
    'delivery' => 'при отправке в чат',
    'persistence' => 'при сохранении подтверждения',
  }.freeze

  REASONS = {
    'moderation' => 'провайдер сообщил об ограничении содержимого',
    'provider_rejected' => 'провайдер отклонил запрос',
    'submit_outcome_unknown' => 'не удалось подтвердить, принял ли провайдер запрос',
    'timeout' => 'истекло время ожидания',
    'provider_unavailable' => 'сервис генерации временно недоступен',
    'telegram_failed' => 'Telegram не подтвердил отправку',
    'persistence_failed' => 'не удалось сохранить подтверждение',
    'model_source_conflict' => 'выбранная модель не принимает несколько исходных изображений',
    'edit_sources_unavailable' => 'не удалось получить исходное изображение для редактирования',
    'model_unavailable' => 'запрошенная модель сейчас недоступна',
    'unknown' => nil,
  }.freeze

  NEXT_STEPS = {
    'image_delivery_failed' => 'Можно попросить повторить запрос; это запустит новую генерацию.',
    'image_persistence_failed' => 'Проверьте чат: Telegram подтвердил отправку; если картинки не видно, попросите начать новый запрос.',
  }.freeze

  REASON_NEXT_STEPS = {
    'model_source_conflict' => 'Выберите модель для нескольких изображений или оставьте один исходник.',
    'edit_sources_unavailable' => 'Пришлите изображение ещё раз или ответьте на сообщение с исходником.',
    'model_unavailable' => 'Выберите модель, которая сейчас доступна.',
    'submit_outcome_unknown' => 'Запрос мог быть принят, и повтор может создать ещё одну генерацию или списать оплату повторно. Явно попросите повторить только если согласны с этим риском.',
  }.freeze

  module_function

  def render(event_type:, parent_task_id:, stage: nil, reason: nil)
    event = EVENT_TEXT.key?(event_type.to_s) ? event_type.to_s : 'image_failed'
    task_id = Integer(parent_task_id, exception: false)
    task_part = task_id&.positive? ? " Задача ##{task_id}." : ''
    stage_text = STAGES[stage.to_s]
    reason_text = REASONS.fetch(reason.to_s, nil)
    detail = [stage_text, reason_text].compact.join(': ')
    detail = " (#{detail})" unless detail.empty?
    next_step = REASON_NEXT_STEPS[reason.to_s] || NEXT_STEPS[event] ||
      'Можно попросить попробовать ещё раз позже или уточнить запрос.'
    "#{EVENT_TEXT.fetch(event)}#{detail}.#{task_part} #{next_step}"
  end
end

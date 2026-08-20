# The only path that deletes knowledge facts. Builds candidate clusters, hands
# each to the LLM judge, applies whatever survives validation and the daily
# budget, then re-enqueues itself while candidates remain.
class KnowledgeReviewHandler
  def call(task, api)
    chat_id = task.chat_id
    params  = task.params_hash
    stats   = KnowledgeBase.review!(chat_id: chat_id, dry_run: params['dry_run'] == true)
    task.mark_done!(stats)
    LOGGER.info "[chat=#{chat_id}] #{self.class.name} task #{task.id}: #{stats}"
    notify(api, chat_id, stats) if params['notify']
    :done
  rescue => e
    # Rescue and mark_failed! here rather than raising: TaskRunner's failure
    # path posts "Ошибка: ..." into the chat, and nobody should see an error
    # about maintenance they didn't ask for.
    task.mark_failed!(e.message)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name} task #{task.id}: #{e.class}: #{e.message}"
    :failed
  end

  private

  def notify(api, chat_id, stats)
    text = if stats[:merged].zero? && stats[:deleted].zero?
      "Проверил базу знаний: дублей не нашёл (кластеров разобрано: #{stats[:chunks]})."
    else
      "Ревизия базы знаний: объединил #{stats[:merged]}, удалил #{stats[:deleted]}, " \
      "всего убрано #{stats[:removed]} фактов."
    end
    resp = api.sendMessage(chat_id: chat_id, text: text)
    Message.persist_bot_reply(chat_id: chat_id, body: text, response: resp)
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: failed to notify: #{e.class}: #{e.message}"
  end
end

TaskRunner.register('knowledge_review', KnowledgeReviewHandler)
# Legacy task type: drains any `knowledge_compact` rows still pending from
# before the two pipelines were collapsed into one.
TaskRunner.register('knowledge_compact', KnowledgeReviewHandler)

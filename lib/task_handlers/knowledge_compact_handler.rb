class KnowledgeCompactHandler
  def call(task, _api)
    threshold = task.params.fetch('threshold', 0.85)
    stats = KnowledgeBase.compact!(chat_id: task.chat_id, threshold: threshold)
    task.mark_done!(stats)
    LOGGER.info "KnowledgeCompact task #{task.id}: #{stats}"
    :done
  rescue => e
    task.mark_failed!(e.message)
    :failed
  end
end

TaskRunner.register('knowledge_compact', KnowledgeCompactHandler)

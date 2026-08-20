module Commands
  class KnowledgeReview < Base
    PATTERN = /^бот[,]?\s+(?:ревизия знаний|сожми знания)$/im

    def match?
      cmd =~ PATTERN
    end

    # Always enqueues. The sweep makes one LLM call per candidate cluster; doing
    # that inline would freeze bot.listen for every chat for the whole run.
    def execute
      return admin_denied unless admin?
      if BackgroundTask.where(task_type: 'knowledge_review', chat_id: chat_id, status: 'pending').exists?
        return CommandResult.text('Ревизия уже в очереди.')
      end
      BackgroundTask.create!(
        task_type: 'knowledge_review', chat_id: chat_id,
        params: { 'notify' => true }.to_json
      )
      CommandResult.text('Поставил ревизию базы знаний в очередь.')
    end
  end
end

module Commands
  class KnowledgeList < Base
    PATTERN = /^бот[,]?\s+знания/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      facts = Knowledge.live.where(chat_id: chat_id).order(created_at: :desc).limit(10).reverse
      return CommandResult.text('База знаний пуста.') if facts.empty?

      lines = facts.map { |k|
        safe = k.content.gsub(/([_*`\[\]])/, '\\\\\1')
        "**[#{k.id}]** [#{k.source}] #{safe}"
      }
      scope = Knowledge.live.where(chat_id: chat_id)
      total = scope.count
      manual = scope.where(source: 'manual').count
      auto = total - manual
      gone = Knowledge.deleted.where(chat_id: chat_id).count
      header = "**База знаний (последние #{facts.size} из #{total} | ручных: #{manual}, авто: #{auto}#{gone.positive? ? ", удалённых: #{gone}" : ''}):**"
      CommandResult.text("#{header}\n#{lines.join("\n")}")
    end
  end
end

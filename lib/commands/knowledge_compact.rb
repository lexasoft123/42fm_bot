module Commands
  class KnowledgeCompact < Base
    PATTERN = /^бот[,]?\s+сожми знания$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?
      threshold = Settings.knowledge['compact_threshold'] || 0.85
      stats = KnowledgeBase.compact!(chat_id: chat_id, threshold: threshold)
      CommandResult.text(
        "Сжал базу знаний: объединил #{stats[:merged]} кластеров, удалил #{stats[:removed]} дублей (осталось #{stats[:kept]})."
      )
    end
  end
end

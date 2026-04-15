module Commands
  class KnowledgeAdd < Base
    PATTERN = /^бот[,]?\s+запомни\s+(?<content>.+)$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?

      content = cmd.match(PATTERN)[:content].strip
      topic   = content.split(/\s+/).first(4).join(' ')

      KnowledgeBase.add(topic: topic, content: content, chat_id: chat_id, source: 'manual')
      CommandResult.text("Запомнил: _#{content}_")
    end
  end
end

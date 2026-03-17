module Commands
  class KnowledgeAdd < Base
    PATTERN = /^бот[,]?\s+запомни\s+(?<content>.+)$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      unless user.role == 'admin'
        return CommandResult.text('Только администратор может добавлять знания.')
      end

      content = cmd.match(PATTERN)[:content].strip
      topic   = content.split(/\s+/).first(4).join(' ')

      KnowledgeBase.add(topic: topic, content: content, source: 'manual')
      CommandResult.text("Запомнил: _#{content}_")
    end
  end
end

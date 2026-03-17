module Commands
  class KnowledgeList < Base
    PATTERN = /^бот[,]?\s+знания/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      facts = Knowledge.where(chat_id: chat_id).order(:created_at)
      return CommandResult.text('База знаний пуста.') if facts.empty?

      lines = facts.map { |k| "*[#{k.id}]* [#{k.source}] #{k.content}" }
      CommandResult.text("*База знаний (#{facts.size}):*\n#{lines.join("\n")}")
    end
  end
end

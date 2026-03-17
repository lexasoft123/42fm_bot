module Commands
  class KnowledgeList < Base
    PATTERN = /^бот[,]?\s+знания/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      facts = Knowledge.order(:created_at).all
      return CommandResult.text('База знаний пуста.') if facts.empty?

      lines = facts.map { |k| "*[#{k.id}]* [#{k.source}] *#{k.topic}*: #{k.content}" }
      CommandResult.text("*База знаний (#{facts.size}):*\n#{lines.join("\n")}")
    end
  end
end

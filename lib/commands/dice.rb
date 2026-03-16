module Commands
  class Dice < Base
    PATTERN = /^(!|(бот[,]?.*\s))кости$/i

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(::Dice.new(user.name).play!)
    end
  end
end

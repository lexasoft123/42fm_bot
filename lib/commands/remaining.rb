module Commands
  class Remaining < Base
    PATTERN = /^!(remaining|осталось|терпеть)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(radio.remaining)
    end
  end
end

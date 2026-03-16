module Commands
  class History < Base
    PATTERN = /^!(history|история)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(radio.history)
    end
  end
end

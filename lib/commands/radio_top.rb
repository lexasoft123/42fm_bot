module Commands
  class RadioTop < Base
    PATTERN = /^!(top|топ)\s+(\d+)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      id = cmd.match(PATTERN)[2]
      CommandResult.text(radio.top(id))
    end
  end
end

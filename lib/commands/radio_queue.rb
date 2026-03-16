module Commands
  class RadioQueue < Base
    PATTERN = /^!(queue|очередь|куеуе)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      q = radio.queue
      CommandResult.text(q || "нихуя нет")
    end
  end
end

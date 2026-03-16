module Commands
  class Listeners < Base
    PATTERN = /^!(слушатели|listeners|слухачі)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      q = radio.listeners
      CommandResult.text(q ? "Сейчас нас слушают: #{q}" : "все куда-то съебли")
    end
  end
end

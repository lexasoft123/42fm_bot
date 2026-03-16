module Commands
  class Markov < Base
    PATTERN = /^(бот|жзяцля)\s+(пиши|пейши)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(::Markov.gen_text)
    end
  end
end

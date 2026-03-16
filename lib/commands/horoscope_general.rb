module Commands
  class HoroscopeGeneral < Base
    PATTERN = /^(бот|жзяцля)\s+(вещай|гороскоп)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(Horoscope.new(user.name).predict!)
    end
  end
end

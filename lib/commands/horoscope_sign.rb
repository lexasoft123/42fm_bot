module Commands
  class HoroscopeSign < Base
    PATTERN = /^(бот|жзяцля)\s+(вещай|гороскоп)\s+(?<sign>(овен|телец|близнецы|рак|лев|дева|весы|скорпион|стрелец|козерог|водолей|рыбы))$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      sign = cmd.match(PATTERN)[:sign]
      CommandResult.text(Horoscope.new(user.name).get_sexy(sign))
    end
  end
end

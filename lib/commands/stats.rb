module Commands
  class Stats < Base
    PATTERNS = {
      day:   /^!(статистика|стата)\s+(сегодня|день)$/,
      month: /^!(статистика|стата)\s+месяц$/,
      week:  /^!(статистика|стата)(\s+неделя)?$/,
    }
    URLS = {
      day:   "http://stats.42fm.ru/ru/42fm.ru/icecast-day.png",
      month: "http://stats.42fm.ru/ru/42fm.ru/icecast-month.png",
      week:  "http://stats.42fm.ru/ru/42fm.ru/icecast-week.png",
    }

    def match?
      !!period
    end

    def execute
      CommandResult.image(URLS[period])
    end

    private

    def period
      # day/month must be checked before week (week pattern is a subset)
      @period ||= [:day, :month, :week].find { |p| cmd =~ PATTERNS[p] }
    end
  end
end

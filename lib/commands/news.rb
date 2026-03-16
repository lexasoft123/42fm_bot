module Commands
  class News < Base
    PATTERN = /^((бот|жзяцля)[,]?\s+((чо\s+(там|нового).*)|(новости))|!новости|!news)$/i

    def match?
      cmd =~ PATTERN
    end

    def execute
      rss = RSS::Parser.parse('https://lenta.ru/rss', false)
      text = rss.items.sample.description.gsub(/^\s+/, '')

      if cmd =~ /голос|расскажи/i
        phrase = text.split.join(' ').truncate(350)
        url = TtsService.speak(phrase)
        CommandResult.voice(url)
      else
        CommandResult.text(text)
      end
    end
  end
end

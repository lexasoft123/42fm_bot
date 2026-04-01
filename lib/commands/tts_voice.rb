module Commands
  class TtsVoice < Base
    PATTERN = /^\s*(ублюдки\s+|бот[,]?\s*(скажи|зачитай)\s+)(?<voice>ганс)?\s*(минус)?\s*(?<track>\d+)?\s*((?<horoscope>гороскоп.*)|(?<text>.*))/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      m = PATTERN.match(cmd)
      voice_id = m[:voice]&.downcase == 'ганс' ? "Hans" : "Maxim"
      horoscope = m[:horoscope]
      text = m[:text].to_s.truncate(Settings.voice_messages["max_letters"])
      track = m[:track]
      minus = !!(cmd =~ /зачитай/i)
      track_id = (minus && track) ? track.to_i : nil

      text = Horoscope.new(user.name).predict! if horoscope && !horoscope.empty?

      path = TtsService.speak(text, voice: voice_id, minus: minus, track_id: track_id)
      CommandResult.voice(path)
    rescue => e
      LOGGER.error "TtsVoice failed: #{e.message}"
      CommandResult.text('Не смог зачитать :(')
    end
  end
end

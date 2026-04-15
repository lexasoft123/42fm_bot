module Commands
  class BoberVoice < Base
    PATTERN = /боб(е|ё)р\s*(минус)?\s*(?<track>\d+)?/i
    BOBER = YAML.load(File.read('config/bober.yml'))

    def match?
      cmd =~ PATTERN
    end

    def execute
      m = PATTERN.match(cmd)
      phrase = BOBER['phrase'].sample.truncate(Settings.voice_messages["max_letters"])
      track = m[:track]
      minus = !!track
      track_id = track ? track.to_i : nil

      path = TtsService.speak(phrase, speed: 0.8, minus: minus, track_id: track_id)
      CommandResult.voice(path)
    rescue => e
      LOGGER.error "#{self.class.name} failed: #{e.message}"
      CommandResult.text('Не смог зачитать :(')
    end
  end
end

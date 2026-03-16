module Commands
  class RadioTrack < Base
    PATTERN = /^!(трек|track)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(radio.track)
    end
  end
end

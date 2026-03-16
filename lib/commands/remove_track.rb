module Commands
  class RemoveTrack < Base
    PATTERN = /^!(убрать|нахуй|remove|попячь|убери)[,]?\s+(пожалуйста\s+)?(?<tracks>(\d+\s*)+)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      if user.role != "new"
        tracks = cmd.match(PATTERN)[:tracks].split(/\s/)
        tr = radio.remove(tracks)
        CommandResult.text(tr ? "Попячено!" : "Внезапно Джигурда")
      else
        CommandResult.text("ложись спать, тебе завтра рано в школу")
      end
    end
  end
end

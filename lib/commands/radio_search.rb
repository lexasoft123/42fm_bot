module Commands
  class RadioSearch < Base
    PATTERN = /^!(search|поиск|пошукай)\s+(.*)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      query = cmd.match(PATTERN)[2]
      return CommandResult.none if query.size < 4

      songs = Song.search(query, limit: 20)
      if songs.empty?
        CommandResult.text("Нихуя нет...")
      else
        CommandResult.text(songs.map(&:display_name).join("\n"))
      end
    end
  end
end

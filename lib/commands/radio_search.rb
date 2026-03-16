module Commands
  class RadioSearch < Base
    PATTERN = /^!(search|поиск|пошукай)\s+(.*)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      query = cmd.match(PATTERN)[2]
      return CommandResult.none if query.size < 4

      tr = radio.search(query)
      if tr.empty?
        CommandResult.text("Нихуя нет...")
      else
        formatted = tr.map do |t|
          tp = t.split("/").map { |p| p.gsub("_", " ") }
          "#{tp[-2]} — #{tp[-1].gsub(/.mp3/i, "")}"
        end
        CommandResult.text(formatted.join("\n"))
      end
    end
  end
end

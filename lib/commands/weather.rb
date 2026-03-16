module Commands
  class Weather < Base
    PATTERN = /!погода\s+(?<city>.*)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      city = cmd.match(PATTERN)[:city]
      CommandResult.text(::Weather.new(city).search!)
    end
  end
end

module Commands
  class GoogleSearch < Base
    PATTERN = /^(бот|жзяцля|тугосеря|уважаемый\sбот)/i

    def match?
      cmd =~ PATTERN
    end

    def execute
      if user.role == 'new' && !(cmd =~ /^уважаемый/i) && rand(100) < 10
        return CommandResult.text("Уважаемый бот.")
      end

      query = cmd.gsub(/(бот|уважаемый\sбот|жзяцля|.*гугли|найди|ищи|искать)\s*/, '')
      res = Gogolmogol.new(query).search!
      if res && res =~ /[.](jpg|jpeg|gif|png|tif|bmp)/
        LOGGER.debug "found picture: #{res}"
        CommandResult.image(res)
      else
        CommandResult.text(res)
      end
    end
  end
end

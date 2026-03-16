module Commands
  class GifSearch < Base
    PATTERN = /^(бот|жзяцля|тугосеря|уважаемый\sбот)\sгиф\s+(.*)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      # GiphyMaster disabled
      CommandResult.none
    end
  end
end

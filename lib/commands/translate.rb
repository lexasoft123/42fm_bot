module Commands
  class Translate < Base
    def pattern
      /^(бот|жзяцля|тугосеря)[,]?\s+(?<lang>#{Translator::ALIASES.keys.join("|")})\s+(?<text>.*)$/mi
    end

    def match?
      cmd =~ pattern
    end

    def execute
      m = cmd.match(pattern)
      CommandResult.text(Translator.new(m[:text]).translate_alias!(m[:lang]))
    end
  end
end

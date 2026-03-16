module Commands
  class Translate < Base
    ALIASES = {
      'пиздани'      => 'украинский',
      'бульба(ни)?'  => 'белорусский',
      'шпрех(ни)?'   => 'немецкий',
      'пше(кни)?'    => 'польский',
      'блгр(ни)?'    => 'болгарский',
      'татар(ни)?'   => 'татарский',
      'казах(ни)?'   => 'казахский',
      'грек(ни)?'    => 'греческий',
      'серб(ни)?'    => 'сербский',
    }.freeze

    PROMPT = 'Переведи следующий текст на {LANG}. Верни только перевод без пояснений: {REQUEST}'.freeze

    def pattern
      /^(бот|жзяцля|тугосеря)[,]?\s+(?<lang>#{ALIASES.keys.join('|')})\s+(?<text>.*)$/mi
    end

    def match?
      cmd =~ pattern
    end

    def execute
      m        = cmd.match(pattern)
      lang     = find_lang(m[:lang])
      prompt   = PROMPT.gsub('{LANG}', lang)
      CommandResult.text(GptMaster.ask(m[:text], prompt: prompt))
    end

    private

    def find_lang(alias_str)
      ALIASES.each { |k, v| return v if /#{k}/i =~ alias_str }
    end
  end
end

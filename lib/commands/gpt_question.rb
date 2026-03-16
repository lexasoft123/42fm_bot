module Commands
  class GptQuestion < Base
    include GptHelpers

    PATTERN = /^(бот[,]?\s+)(?<text>((почему|зачем|как|когда|что|где|сколько|какой|расскажи|ответь)\s.*)|(.*[?]$))/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text = cmd.match(PATTERN)[:text]
      CommandResult.text("@#{user.name} #{GptMaster.call(text, context: get_chat_context)}")
    end
  end
end

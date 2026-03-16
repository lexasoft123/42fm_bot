module Commands
  class GptChat4 < Base
    include GptHelpers

    PATTERN = /^(бот[,]?\s+)?(жпт4)\s+(?<text>.*)/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text = cmd.match(PATTERN)[:text]
      CommandResult.text("@#{user.name} #{GptMaster.call(text, context: get_chat_context, model: 'chatgpt-4o-latest')}")
    end
  end
end

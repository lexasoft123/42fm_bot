module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text  = cmd.match(PATTERN)[:text]
      reply = GptMaster.chat(text, context: get_chat_context)
      save_bot_reply(reply)
      CommandResult.text("@#{user.name} #{reply}")
    end
  end
end

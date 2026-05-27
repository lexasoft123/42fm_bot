module Commands
  class GptQuestion < Base
    include GptHelpers

    PATTERN = /^(бот[,]?\s+)(?<text>((почему|зачем|как|когда|что|где|сколько|какой|расскажи|ответь)\s.*)|(.*[?]$))/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text  = cmd.match(PATTERN)[:text]
      reply = Agent::Runner.new(
        text: text, context: get_chat_context,
        knowledge: get_relevant_knowledge(text),
        radio: radio, chat_id: chat_id, user: user, api: bot&.api,
        message_id: message.message_id
      ).run
      CommandResult.text("@#{user.name} #{reply}", persist_as_bot_reply: true)
    end
  end
end

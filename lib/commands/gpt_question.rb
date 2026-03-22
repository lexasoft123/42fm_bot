module Commands
  class GptQuestion < Base
    include GptHelpers

    PATTERN = /^(бот[,]?\s+)(?<text>((почему|зачем|как|когда|что|где|сколько|какой|расскажи|ответь)\s.*)|(.*[?]$))/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text  = cmd.match(PATTERN)[:text]
      reply = if Settings.chat_gpt['agent_mode']
        Agent::Runner.new(
          text: text, context: get_chat_context,
          knowledge: get_relevant_knowledge(text),
          radio: radio, chat_id: chat_id, user: user
        ).run
      else
        GptMaster.chat(text, context: get_chat_context, knowledge: get_relevant_knowledge(text))
      end
      save_bot_reply(reply)
      CommandResult.text("@#{user.name} #{reply}")
    end
  end
end

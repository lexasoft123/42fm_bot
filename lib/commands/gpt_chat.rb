module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      text  = cmd.match(PATTERN)[:text]

      quick = reply_master.reply_pattern_only(text)
      return CommandResult.text(quick) if quick

      reply = if Settings.chat_gpt['agent_mode']
        Agent::Runner.new(
          text: text, context: get_chat_context,
          knowledge: get_relevant_knowledge(text),
          radio: radio, chat_id: chat_id, user: user, bot: bot
        ).run
      else
        GptMaster.chat(text, context: get_chat_context, knowledge: get_relevant_knowledge(text))
      end
      save_bot_reply(reply)
      CommandResult.text("@#{user.name} #{reply}")
    end
  end
end

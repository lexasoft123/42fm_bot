module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    def match?
      cmd =~ PATTERN || reply_to_bot?
    end

    def execute
      text = if (m = cmd&.match(PATTERN))
        m[:text]
      else
        cmd
      end

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

    private

    def reply_to_bot?
      return false unless cmd && message.reply_to_message
      bot_id = Settings.telegram['token'].split(':').first.to_i
      message.reply_to_message.from&.id == bot_id
    end
  end
end

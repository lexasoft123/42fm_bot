module Commands
  class ReplyYou < Base
    PATTERN = /^(бот|жзяцля|тугосеря|уважаемый\sбот)[,]?\s(((т|в)ы\s)|(гей|пидор|мудак)).*/i

    def match?
      return false if Settings.chat_gpt['agent_mode']
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(reply_master.reply_you(user, message.from, cmd))
    end
  end
end

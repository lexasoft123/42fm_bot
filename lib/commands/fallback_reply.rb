module Commands
  class FallbackReply < Base
    def match?
      true  # always matches — must be last in registry
    end

    def execute
      result = reply_master.reply(user, message.from, cmd)
      result ? CommandResult.text(result) : CommandResult.none
    end
  end
end

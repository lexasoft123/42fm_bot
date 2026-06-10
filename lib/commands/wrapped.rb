module Commands
  # «бот итоги» — on-demand Chat Wrapped. Deterministic, read-only: never
  # rolls the «Революция» event (that's exclusive to the weekly auto-post
  # in WrappedDigestHandler).
  class Wrapped < Base
    PATTERN = /\A(бот|жзяцля)[,]?\s+итоги\s*\z/i

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(ChatWrapped.generate(chat_id))
    end
  end
end

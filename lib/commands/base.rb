module Commands
  class Base
    def initialize(ctx)
      @ctx = ctx
    end

    def match?
      raise NotImplementedError
    end

    def execute
      raise NotImplementedError
    end

    private

    def bot          = @ctx.bot
    def message      = @ctx.message
    def user         = @ctx.user
    def chat_id      = @ctx.chat_id
    def radio        = @ctx.radio
    def reply_master = @ctx.reply_master
    def cmd          = @ctx.cmd
  end
end

module Commands
  class KnowledgeDelete < Base
    PATTERN = /^бот[,]?\s+забудь\s+(?<id>\d+)$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?

      id = cmd.match(PATTERN)[:id].to_i
      k  = Knowledge.live.find_by(id: id, chat_id: chat_id)
      return CommandResult.text("Факт ##{id} не найден.") unless k

      k.soft_delete!('admin')
      CommandResult.text("Забыл факт ##{id}: _#{k.content}_\n(вернуть: `бот верни #{id}`)")
    end
  end
end

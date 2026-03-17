module Commands
  class KnowledgeDelete < Base
    PATTERN = /^бот[,]?\s+забудь\s+(?<id>\d+)$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      unless user.role == 'admin'
        return CommandResult.text('Только администратор может удалять знания.')
      end

      id = cmd.match(PATTERN)[:id].to_i
      k  = Knowledge.find_by(id: id)
      return CommandResult.text("Факт ##{id} не найден.") unless k

      k.destroy
      CommandResult.text("Забыл факт ##{id}: _#{k.content}_")
    end
  end
end

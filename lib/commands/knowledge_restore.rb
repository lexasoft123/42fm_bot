module Commands
  class KnowledgeRestore < Base
    PATTERN = /^бот[,]?\s+верни\s+(?<id>\d+)(?<force>\s+точно)?$/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?
      m  = cmd.match(PATTERN)
      id = m[:id].to_i
      k  = Knowledge.deleted.find_by(id: id, chat_id: chat_id)
      return CommandResult.text("Удалённый факт ##{id} не найден.") unless k

      # Restoring a merge source resurrects a duplicate right next to the merged
      # fact that superseded it -- the exact state the sweep removed.
      if k.deleted_reason == 'merged' && m[:force].nil?
        return CommandResult.text(
          "Факт ##{id} был объединён с другими — вернуть его значит снова создать дубль.\n" \
          "Если точно надо: `бот верни #{id} точно`"
        )
      end

      k.restore!
      CommandResult.text("Вернул факт ##{id}: _#{k.content}_")
    end
  end
end

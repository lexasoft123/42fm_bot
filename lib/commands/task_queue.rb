module Commands
  class TaskQueue < Base
    PATTERN = /^бо[тй][,]?\s+(?:задачи|очередь|таски|tasks)/i

    STATUS_EMOJI = { 'pending' => '⏳', 'done' => '✅', 'failed' => '❌' }.freeze

    def match?
      cmd =~ PATTERN
    end

    def execute
      tasks = BackgroundTask.where(chat_id: chat_id)
        .order(created_at: :desc)
        .limit(10)

      return CommandResult.text("Задач нет") if tasks.empty?

      lines = tasks.map { |t| format_task(t) }
      pending = BackgroundTask.where(chat_id: chat_id, status: 'pending').count

      header = pending > 0 ? "📋 **Очередь задач** (активных: #{pending})" : "📋 **Последние задачи**"
      CommandResult.text("#{header}\n\n#{lines.join("\n")}")
    end

    private

    def format_task(t)
      emoji = STATUS_EMOJI[t.status] || '❓'
      p = t.params_hash
      desc = p['request'].to_s
      desc = [p['genre'], p['artist'], p['topic']].compact.reject(&:empty?).join(' / ') if desc.empty?
      desc = t.task_type if desc.empty?
      desc = desc[0..60] + '…' if desc.length > 60
      age = time_ago(t.created_at)

      line = "#{emoji} `##{t.id}` #{desc} — #{age}"
      line += " (#{t.attempts}/#{t.max_attempts})" if t.status == 'pending'
      line
    end

    def time_ago(time)
      diff = (Time.now - time).to_i
      return "#{diff}с" if diff < 60
      return "#{diff / 60}м" if diff < 3600
      return "#{diff / 3600}ч" if diff < 86400
      "#{diff / 86400}д"
    end
  end
end

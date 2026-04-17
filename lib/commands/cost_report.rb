module Commands
  class CostReport < Base
    PATTERN = /^бо[тй][,]?\s+(?:затраты|расходы|cost)\b/i

    WINDOWS = [
      ['сегодня', 86_400],
      ['7д',      7  * 86_400],
      ['30д',     30 * 86_400],
    ].freeze

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?

      lines = ["💰 *Расходы API*"]
      lines << ''
      lines << "*Этот чат (`#{chat_id}`):*"
      WINDOWS.each { |label, sec| lines << format_window(label, sec, chat_id: chat_id) }
      lines << ''
      lines << '*Все чаты:*'
      WINDOWS.each { |label, sec| lines << format_window(label, sec, chat_id: nil) }

      CommandResult.text(lines.join("\n"))
    end

    private

    def format_window(label, seconds, chat_id:)
      scope = ApiUsage.where('created_at > ?', Time.now - seconds)
      scope = scope.where(chat_id: chat_id) if chat_id
      total_cents = scope.sum(:cost_cents)
      count       = scope.count
      by_purpose  = scope.group(:purpose).pluck(:purpose, Arel.sql('SUM(cost_cents)'), Arel.sql('COUNT(*)'))

      header = "• *#{label}*: #{fmt_cost(total_cents)} (#{count} вызовов)"
      return header if by_purpose.empty?

      rows = by_purpose.sort_by { |_, c, _| -c.to_f }.map do |purpose, cents, n|
        "    #{purpose}: #{fmt_cost(cents)} (#{n})"
      end
      ([header] + rows).join("\n")
    end

    def fmt_cost(cents)
      c = cents.to_f
      c < 100 ? format('%.2f¢', c) : format('$%.2f', c / 100.0)
    end
  end
end

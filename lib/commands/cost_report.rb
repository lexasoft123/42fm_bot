module Commands
  class CostReport < Base
    PATTERN = /^бо[тй][,]?\s+(?:затраты|расходы|cost)\b/i

    WINDOWS = [
      ['сегодня', 86_400],
      ['7д',      7  * 86_400],
      ['30д',     30 * 86_400],
    ].freeze

    TOP_USERS_LIMIT = 5

    def match?
      cmd =~ PATTERN
    end

    def execute
      return admin_denied unless admin?

      lines = ["💰 **Расходы API**"]
      lines << ''
      lines << "**Этот чат (#{chat_label}):**"
      WINDOWS.each { |label, sec| lines << format_window(label, sec, chat_id: chat_id) }

      lines << ''
      lines << '**Топ юзеров в этом чате:**'
      WINDOWS.each { |label, sec| lines << format_top_users(label, sec, chat_id: chat_id) }

      lines << ''
      lines << '**Все чаты:**'
      WINDOWS.each { |label, sec| lines << format_window(label, sec, chat_id: nil) }

      CommandResult.text(lines.join("\n"))
    end

    private

    def format_window(label, seconds, chat_id:)
      scope = ApiUsage.where('created_at > ?', Time.now - seconds)
      scope = scope.where(chat_id: chat_id) if chat_id
      total_cents = scope.sum(:cost_cents)
      count       = scope.count
      saved_cents = ApiUsage.cache_savings_cents(scope)
      by_purpose  = scope.group(:purpose).pluck(:purpose, Arel.sql('SUM(cost_cents)'), Arel.sql('COUNT(*)'))

      header = "• **#{label}**: #{fmt_cost(total_cents)} (#{count} вызовов, сэкономлено кэшем #{fmt_cost(saved_cents)})"
      return header if by_purpose.empty?

      rows = by_purpose.sort_by { |_, c, _| -c.to_f }.map do |purpose, cents, n|
        "    #{purpose}: #{fmt_cost(cents)} (#{n})"
      end
      ([header] + rows).join("\n")
    end

    def format_top_users(label, seconds, chat_id:)
      rows = ApiUsage
        .where(chat_id: chat_id)
        .where('created_at > ?', Time.now - seconds)
        .where.not(user_uid: nil)
        .group(:user_uid)
        .pluck(:user_uid, Arel.sql('SUM(cost_cents)'), Arel.sql('COUNT(*)'))
        .sort_by { |_, cents, _| -cents.to_f }
        .first(TOP_USERS_LIMIT)

      return "• **#{label}**: нет данных" if rows.empty?

      names = User.where(uid: rows.map(&:first)).pluck(:uid, :name, :first_name).to_h { |u, n, f| [u, n || f || u.to_s] }
      body = rows.map do |uid, cents, n|
        "    #{names[uid] || uid}: #{fmt_cost(cents)} (#{n})"
      end.join("\n")

      "• **#{label}**:\n#{body}"
    end

    def fmt_cost(cents)
      c = cents.to_f
      c < 100 ? format('%.2f¢', c) : format('$%.2f', c / 100.0)
    end

    # Prefer the Telegram chat title; fall back to a user-facing label for DMs
    # and ultimately to the numeric id.
    def chat_label
      chat = message&.chat
      title = chat&.title
      return title if title && !title.empty?
      name = [chat&.first_name, chat&.last_name].compact.join(' ').strip
      return name unless name.empty?
      "`#{chat_id}`"
    end
  end
end

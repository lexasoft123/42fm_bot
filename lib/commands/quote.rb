module Commands
  # «бот цитата» — quote of the day: a random pick from the most-reacted
  # human messages of the last 30 days (reactions captured by S1).
  # Deterministic, no LLM.
  class Quote < Base
    PATTERN = /\A(бот|жзяцля)[,]?\s+цитат[аыу]\s*\z/i
    WINDOW_SECONDS = 30 * 86_400

    def match?
      cmd =~ PATTERN
    end

    def execute
      candidates = Message.top_reacted(chat_id, since: WINDOW_SECONDS, limit: 10, scope: :user).to_a
      if candidates.empty?
        return CommandResult.text('Цитатник пуст — никто ещё не сказал ничего достойного реакции. Ставьте 👍 на гениальное.')
      end
      m = candidates.sample
      CommandResult.text(format_quote(m))
    end

    private

    def format_quote(m)
      body = m.body.to_s.strip
      "📜 Цитата дня:\n«#{body}»\n— #{author_mention(m)}, #{m.created_at.strftime('%d.%m.%Y')} (#{m.reactions_count} 🔥)"
    end

    def author_mention(m)
      u = m.user
      return 'неизвестный классик' unless u
      label = [u.first_name, u.last_name].compact.map(&:to_s).map(&:strip).reject(&:empty?).join(' ')
      label = u.name.to_s.strip if label.empty?
      label = "uid#{u.uid}" if label.empty?
      "[#{label}](tg://user?id=#{u.uid})"
    end
  end
end

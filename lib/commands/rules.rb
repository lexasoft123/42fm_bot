module Commands
  # Deterministic «бот правила» lister — constitution-style render of the
  # rules-war store, no LLM cost. Setting/repealing/challenging rules goes
  # through the agent (set_rule / repeal_rule / challenge_rule tools).
  class Rules < Base
    PATTERN = /\A(бот|жзяцля)[,]?\s+правила\s*\z/i

    def match?
      cmd =~ PATTERN
    end

    def execute
      rules = Agent::Scratchpad.rules(chat_id)
      if rules.empty?
        return CommandResult.text("📜 УСТАВ ЧАТА пуст. Анархия.\nПервое правило: «бот поставь правило …»")
      end
      lines = ['📜 УСТАВ ЧАТА', '']
      rules.each { |r| lines << article_line(r) }
      lines << ''
      lines << 'Апелляции: «бот оспорь r-NNN» — суд бросает кость 🎲'
      CommandResult.text(lines.join("\n"))
    end

    private

    def article_line(r)
      author = r['court'] ? 'судом' : "гр. #{r['set_by_name'] || 'неизвестным'}"
      target = r['target'].to_s.strip.empty? ? 'на всех' : "на #{r['target']}"
      line = "ст. #{r['id']} (введена #{author}, действие: #{target}): #{r['content']}."
      line += " Выстояла апелляций: #{r['challenges_survived']}." if r['challenges_survived'].to_i > 0
      line + " Истекает: через #{Agent::Scratchpad.hours_left(r['expires_at'])}"
    end
  end
end

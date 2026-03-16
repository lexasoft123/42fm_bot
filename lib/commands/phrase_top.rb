module Commands
  class PhraseTop < Base
    PATTERN = /^(бот)\s+(топ)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      stats = Phrase.joins(:user)
        .select('users.name as username, COUNT(phrases.id) as p_count')
        .group('users.id').order('p_count desc').limit(15)
      count = Phrase.count
      text = stats.map { |s| "#{s.p_count} — @#{s.username}" }.join("\n")
      text += "\nВсего: #{count}"
      CommandResult.text(text)
    end
  end
end

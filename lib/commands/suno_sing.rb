module Commands
  class SunoSing < Base
    PATTERN = /^бо[тй][,]?\s+(?:спой|сочини|запиши|сыграй)\s*(?:песню|песенку|трек|song)?\s*(?<rest>.*)/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      rest = cmd.match(PATTERN)[:rest].to_s.strip

      BackgroundTask.create!(
        task_type: 'suno_generate',
        chat_id: chat_id,
        max_attempts: 30,
        params: { request: rest }.to_json
      )

      CommandResult.text("🎵 Сочиняю песню: #{rest.empty? ? 'что-нибудь' : rest}...")
    end
  end
end

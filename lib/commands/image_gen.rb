module Commands
  class ImageGen < Base
    PATTERN = /^бо[тй][,]?\s+(?:нарисуй|рисуй|картинк[уа]|нарисуйте|изобрази)\s*(?<rest>.*)/im

    def match?
      cmd =~ PATTERN
    end

    def execute
      rest = cmd.match(PATTERN)[:rest].to_s.strip
      return CommandResult.text("Что нарисовать?") if rest.empty?

      if RateLimiter.exceeded?(chat_id, 'image')
        return CommandResult.text(RateLimiter.reply(chat_id, 'image'))
      end

      BackgroundTask.create!(
        task_type: 'image_generate',
        chat_id: chat_id,
        max_attempts: 20,
        params: { request: rest }.to_json
      )

      CommandResult.text("🎨 Рисую: #{rest}...")
    end
  end
end

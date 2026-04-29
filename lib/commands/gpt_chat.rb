require 'base64'

module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    def match?
      cmd =~ PATTERN || reply_to_bot?
    end

    def execute
      text = if (m = cmd&.match(PATTERN))
        m[:text]
      else
        cmd
      end

      phrase = maybe_save_phrase(text)
      replied_image = extract_image || extract_replied_image
      audio = attached_audio

      reply = Agent::Runner.new(
        text: text, context: get_chat_context,
        knowledge: get_relevant_knowledge(text),
        radio: radio, chat_id: chat_id, user: user, bot: bot,
        image: replied_image, phrase: phrase, audio: audio
      ).run
      CommandResult.text(reply, reply_to_message_id: message.message_id, persist_as_bot_reply: true)
    end

    private

    def reply_to_bot?
      return false unless cmd && message.reply_to_message
      bot_id = Settings.telegram['token'].split(':').first.to_i
      message.reply_to_message.from&.id == bot_id
    end

    def maybe_save_phrase(text)
      return nil unless text =~ /^(а\s+)?(т|в)ы\s+(?<phrase>.+)/i
      content = Regexp.last_match(:phrase)
      Phrase.create(user: user, content: content)
      random = Phrase.order("random()").first
      random&.content
    end

    def extract_image
      photos = message.photo
      return nil unless photos.is_a?(Array) && !photos.empty?
      download_photo(photos.last.file_id)
    end

    def extract_replied_image
      return nil unless message.reply_to_message
      photos = message.reply_to_message.photo
      return nil unless photos.is_a?(Array) && !photos.empty?
      download_photo(photos.last.file_id)
    end

    # Pull a public Telegram URL for an attached audio file. Allowlists:
    # message.audio (any audio), message.voice (OGG), message.document only
    # when mime_type starts with audio/. Skips video / video_note / animation.
    # Returns { url:, mime_type:, duration:, title:, performer: } or nil.
    def attached_audio
      src = message.audio
      src ||= message.voice
      src ||= (message.document if message.document&.mime_type&.start_with?('audio/'))
      return nil unless src

      file = bot.api.getFile(file_id: src.file_id)
      file_path = file.respond_to?(:file_path) ? file.file_path : file.dig('result', 'file_path')
      return nil unless file_path

      token = Settings.telegram['token']
      {
        url:        "https://api.telegram.org/file/bot#{token}/#{file_path}",
        mime_type:  src.respond_to?(:mime_type) ? src.mime_type : nil,
        duration:   src.respond_to?(:duration)  ? src.duration  : nil,
        title:      src.respond_to?(:title)     ? src.title     : nil,
        performer:  src.respond_to?(:performer) ? src.performer : nil,
      }
    rescue => e
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}#attached_audio failed: #{e.class}: #{e.message}"
      nil
    end

    def download_photo(file_id)
      file = bot.api.getFile(file_id: file_id)
      file_path = file.file_path
      return nil unless file_path

      token = Settings.telegram['token']
      url = "https://api.telegram.org/file/bot#{token}/#{file_path}"
      response = HTTParty.get(url, timeout: 30)
      return nil unless response.code == 200

      LOGGER.debug "[chat=#{chat_id}] #{self.class.name}#download_photo: downloaded #{response.body.bytesize} bytes"
      { data: Base64.strict_encode64(response.body), media_type: 'image/jpeg' }
    rescue => e
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}#download_photo failed: #{e.class}: #{e.message}"
      nil
    end
  end
end

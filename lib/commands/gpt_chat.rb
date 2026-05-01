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
        image: replied_image, phrase: phrase, audio: audio,
        reply_to_message_id: message.reply_to_message&.message_id,
        message_id: message.message_id
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

    # Pull metadata for an attached audio file. Allowlists:
    # message.audio (any audio), message.voice (OGG), message.document only
    # when mime_type starts with audio/. Skips video / video_note / animation.
    # Returns { file_id:, mime_type:, duration:, title:, performer: } or nil.
    #
    # Also checks message.reply_to_message — when a user quotes a previous
    # audio with a text prompt ("бот спой это под джаз" replying to an mp3),
    # the audio lives on the reply target, not the current message. Mirrors
    # extract_replied_image.
    #
    # The Telegram file URL is resolved lazily inside Suno tool handlers via
    # `TelegramFile.public_url(ctx[:bot].api, ctx[:audio][:file_id])` — only
    # when a tool actually needs it. Calling getFile here unconditionally
    # would burn a Telegram round-trip for every audio-bearing message
    # regardless of whether the agent decides to use the audio.
    def attached_audio
      audio_metadata_from(message) ||
        (message.reply_to_message && audio_metadata_from(message.reply_to_message)) ||
        recent_chat_audio
    end

    # Walk back through the last 20 messages in this chat for a stored
    # attachment (saved by MessageResponder#save_message when an incoming
    # message had audio / voice / audio-MIME document). Lets the agent
    # reach an earlier upload when the user asks for a cover in a fresh
    # message without using Telegram's reply feature to point at it.
    # Bounded at 20 (not unlimited) so a long-stale audio from yesterday
    # doesn't get matched to a today's "сделай кавер" with no real link.
    # Filters: `role: 'user'` (avoid future bot-row matches if we ever
    # store attachments on bot rows) and same-thread (forum topics —
    # don't surface an audio uploaded in topic A as a match for "сделай
    # кавер" asked in topic B).
    AUDIO_LOOKBACK = 20
    def recent_chat_audio
      row = Message.where(chat_id: chat_id, role: 'user',
                          message_thread_id: message.message_thread_id)
                   .order(id: :desc)
                   .limit(AUDIO_LOOKBACK)
                   .find { |m| m.attachment_file_id }
      return nil unless row
      { file_id:   row.attachment_file_id,
        mime_type: row.attachment_mime_type,
        duration:  row.attachment_duration,
        title:     row.attachment_title,
        performer: row.attachment_performer }
    end

    def audio_metadata_from(msg)
      src = msg.audio
      src ||= msg.voice
      src ||= (msg.document if msg.document&.mime_type&.start_with?('audio/'))
      return nil unless src

      # Title fallback chain: Audio.title (ID3) → Document.file_name minus
      # extension. The agent uses this to name the output cover/vocals
      # track; without a title hint it falls back to inferring the name
      # from prior chat context, which gets wrong when the user uploads
      # a fresh track unrelated to earlier conversation.
      title = (src.respond_to?(:title) ? src.title : nil)
      title = File.basename(src.file_name.to_s, '.*').strip if (title.nil? || title.empty?) && src.respond_to?(:file_name) && !src.file_name.to_s.empty?
      {
        file_id:   src.file_id,
        mime_type: src.respond_to?(:mime_type) ? src.mime_type : nil,
        duration:  src.respond_to?(:duration)  ? src.duration  : nil,
        title:     title.to_s.empty? ? nil : title,
        performer: src.respond_to?(:performer) ? src.performer : nil,
      }
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

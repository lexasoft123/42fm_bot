require 'base64'
require 'unicode_utils'
require_relative '../telegram_file'
require_relative '../audio_attachment'
require_relative '../pending_audio_request'

module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    # Is this message addressed to the bot (prefix, DM, or reply to a bot
    # message)? Same rules as #match?, usable without a CommandContext —
    # MessageResponder asks it when an error fires before dispatch.
    def self.addressed?(message)
      text = message.text || message.caption
      addressed_cmd?(message, text && UnicodeUtils.downcase(text))
    end

    # Single source of the addressing rule — #match? calls it with the
    # context's cmd, addressed? with one derived from the message.
    def self.addressed_cmd?(message, cmd)
      (cmd && cmd.match?(PATTERN)) || private_no_prefix?(message, cmd) || reply_to_bot?(message, cmd)
    end

    # In a 1-on-1 chat every plain text is addressed to the bot — no prefix
    # needed. Slash commands are excluded: an unknown /command should fall
    # through to FallbackReply, not burn an LLM call.
    def self.private_no_prefix?(message, cmd)
      message.chat.type == 'private' && !cmd.to_s.start_with?('/')
    end

    def self.reply_to_bot?(message, cmd)
      return false unless cmd && message.reply_to_message
      bot_id = Settings.telegram['token'].split(':').first.to_i
      message.reply_to_message.from&.id == bot_id
    end

    def match?
      self.class.addressed_cmd?(message, cmd)
    end

    def execute
      m = cmd&.match(PATTERN)
      original = message.text || message.caption || cmd
      original_match = original&.match(PATTERN)
      text = original_match ? original_match[:text] : original

      # Any new request cancels a pending "send the audio next" follow-up —
      # a track shared after "бот погода" must not replay an old cover request.
      PendingAudioRequest.clear(chat_id, user.uid) if user

      # Phrase harvesting stays gated on explicit addressing (prefix or
      # reply-to-bot) — bare DM small talk («ты молодец») must not feed
      # the Phrase collection.
      explicitly_addressed = !m.nil? || reply_to_bot?
      phrase = explicitly_addressed ? maybe_save_phrase(text) : nil
      thread_id = message.message_thread_id if AudioAttachment.forum?(message)
      photo_message, file_id = photo_source(thread_id)
      replied_image = download_photo(file_id) if file_id
      audio = attached_audio

      reply = Agent::Runner.new(
        text: text, original_request_text: original, context: get_chat_context,
        knowledge: get_relevant_knowledge(text),
        radio: radio, chat_id: chat_id, user: user, api: bot&.api,
        image: replied_image, phrase: phrase, audio: audio,
        photo_source_present: !photo_message.nil?, photo_source_message_id: photo_message&.message_id,
        reply_to_message_id: message.reply_to_message&.message_id,
        message_id: message.message_id,
        forum_thread_id: thread_id,
        private_chat: message.chat&.type == 'private'
      ).run
      CommandResult.text(reply, reply_to_message_id: message.message_id)
    end

    private

    def photo_source(thread_id)
      [message, message.reply_to_message].compact.each do |candidate|
        photos = candidate.photo
        return [candidate, photos.last.file_id] if photos.is_a?(Array) && !photos.empty?
      end

      reply = message.reply_to_message
      return unless reply&.respond_to?(:document) && reply.document && reply_to_bot?

      scope = Message.where(chat_id: chat_id, message_id: reply.message_id, role: 'bot')
      scope = scope.where(message_thread_id: thread_id) if thread_id
      file_id = scope.pick(:attachment_photo_file_id)
      [reply, file_id] if file_id && file_id == reply.document.file_id
    end

    def private_no_prefix?
      self.class.private_no_prefix?(message, cmd)
    end

    def reply_to_bot?
      self.class.reply_to_bot?(message, cmd)
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

    # Which audio (if any) this request refers to — current message, reply
    # target, or a fresh (≤30 min) lookback row. See AudioAttachment.
    def attached_audio
      AudioAttachment.resolve(message, chat_id: chat_id)
    end

    # Thin wrapper around the shared helper so extract_image /
    # extract_replied_image stay unchanged. The view_image agent tool calls
    # TelegramFile.download_image directly for historical photos.
    def download_photo(file_id)
      TelegramFile.download_image(bot.api, file_id, chat_id: chat_id)
    end
  end
end

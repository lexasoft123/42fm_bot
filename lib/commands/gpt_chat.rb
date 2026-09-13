require 'base64'
require_relative '../telegram_file'
require_relative '../audio_attachment'

module Commands
  class GptChat < Base
    include GptHelpers

    PATTERN = /^(?:бот[,]?\s+|[.]\s+|(?:балаболь|жпт)\s+)(?<text>.+)/im

    def match?
      cmd =~ PATTERN || private_no_prefix? || reply_to_bot?
    end

    def execute
      m = cmd&.match(PATTERN)
      text = m ? m[:text] : cmd

      # Phrase harvesting stays gated on explicit addressing (prefix or
      # reply-to-bot) — bare DM small talk («ты молодец») must not feed
      # the Phrase collection.
      explicitly_addressed = !m.nil? || reply_to_bot?
      phrase = explicitly_addressed ? maybe_save_phrase(text) : nil
      replied_image = extract_image || extract_replied_image
      audio = attached_audio

      reply = Agent::Runner.new(
        text: text, context: get_chat_context,
        knowledge: get_relevant_knowledge(text),
        radio: radio, chat_id: chat_id, user: user, api: bot&.api,
        image: replied_image, phrase: phrase, audio: audio,
        reply_to_message_id: message.reply_to_message&.message_id,
        message_id: message.message_id,
        forum_thread_id: (message.message_thread_id if AudioAttachment.forum?(message))
      ).run
      CommandResult.text(reply, reply_to_message_id: message.message_id)
    end

    private

    # In a 1-on-1 chat every plain text is addressed to the bot — no prefix
    # needed. Slash commands are excluded: an unknown /command should fall
    # through to FallbackReply, not burn an LLM call.
    def private_no_prefix?
      message.chat.type == 'private' && !cmd.to_s.start_with?('/')
    end

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

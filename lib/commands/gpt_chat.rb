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

      quick = reply_master.reply_pattern_only(text)
      return CommandResult.text(quick) if quick

      replied_to = extract_replied_text
      replied_image = extract_replied_image

      reply = if Settings.chat_gpt['agent_mode']
        Agent::Runner.new(
          text: text, context: get_chat_context,
          knowledge: get_relevant_knowledge(text),
          radio: radio, chat_id: chat_id, user: user, bot: bot,
          replied_to: replied_to, image: replied_image
        ).run
      else
        GptMaster.chat(text, context: get_chat_context, knowledge: get_relevant_knowledge(text))
      end
      save_bot_reply(reply)
      CommandResult.text(reply, reply_to_message_id: message.message_id)
    end

    private

    def reply_to_bot?
      return false unless cmd && message.reply_to_message
      bot_id = Settings.telegram['token'].split(':').first.to_i
      message.reply_to_message.from&.id == bot_id
    end

    def extract_replied_text
      return nil unless message.reply_to_message
      message.reply_to_message.text || message.reply_to_message.caption
    end

    def extract_replied_image
      return nil unless message.reply_to_message
      photos = message.reply_to_message.photo
      return nil unless photos.is_a?(Array) && !photos.empty?

      file_id = photos.last.file_id
      file = bot.api.getFile(file_id: file_id)
      file_path = file['result']['file_path']
      return nil unless file_path

      token = Settings.telegram['token']
      url = "https://api.telegram.org/file/bot#{token}/#{file_path}"
      response = HTTParty.get(url, timeout: 30)
      return nil unless response.code == 200

      LOGGER.debug "extract_replied_image: downloaded #{response.body.bytesize} bytes"
      { data: Base64.strict_encode64(response.body), media_type: 'image/jpeg' }
    rescue => e
      LOGGER.warn "extract_replied_image failed: #{e.class}: #{e.message}"
      nil
    end
  end
end

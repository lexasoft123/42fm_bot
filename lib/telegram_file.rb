require 'httparty'
require 'base64'

module TelegramFile
  # Resolve a Telegram file_id to a publicly-fetchable URL via getFile.
  # Returns nil on failure.
  #
  # **Security:** the returned URL contains the bot token in its path
  # (`https://api.telegram.org/file/bot<TOKEN>/<file_path>`). Forwarding
  # this URL to a third party (e.g. Suno) exposes the bot token to that
  # third party's logs / analytics. Same risk profile as the chat-visible
  # URL produced by Commands::GptChat#process_voice_message — rotate via
  # @BotFather if you suspect leakage.
  def self.public_url(api, file_id, chat_id: nil)
    file = api.getFile(file_id: file_id)
    file_path = file.respond_to?(:file_path) ? file.file_path : file.dig('result', 'file_path')
    return nil unless file_path

    token = Settings.telegram['token']
    "https://api.telegram.org/file/bot#{token}/#{file_path}"
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] TelegramFile.public_url failed: #{e.class}: #{e.message}" if defined?(LOGGER)
    nil
  end

  # Download an image file_id and return the vision-block payload shape used
  # by Agent::Runner / GptMaster: { data: <base64>, media_type: 'image/jpeg' }.
  # Telegram serves `photo`-type files as JPEG. Returns nil on any failure.
  # Shared by Commands::GptChat (current-message vision) and the view_image
  # agent tool (historical images). Same bot-token-in-URL caveat as
  # public_url — the URL never leaves this process here.
  def self.download_image(api, file_id, chat_id: nil)
    url = public_url(api, file_id, chat_id: chat_id)
    return nil unless url

    response = HTTParty.get(url, timeout: 30)
    return nil unless response.code == 200

    LOGGER.debug "[chat=#{chat_id}] TelegramFile.download_image: downloaded #{response.body.bytesize} bytes" if defined?(LOGGER)
    { data: Base64.strict_encode64(response.body), media_type: 'image/jpeg' }
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] TelegramFile.download_image failed: #{e.class}: #{e.message}" if defined?(LOGGER)
    nil
  end
end

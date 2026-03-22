require 'logger'
require 'fileutils'

FALLBACK_LOG = 'log/bot.log'

begin
  require_relative '../config/boot'

  config = AppConfigurator.new
  config.configure

  token = Settings.telegram['token']
  LOGGER = config.logger
  logger = LOGGER

  logger.debug 'Starting telegram bot'

  @radio = Radio.new

  begin
    Telegram::Bot::Client.run(token, logger: logger) do |bot|
      TaskRunner.start(bot.api)
      logger.info "TaskRunner started"

      bot.listen do |message|
        next unless message.is_a? Telegram::Bot::Types::Message
        next unless message.from
        options = { bot: bot, message: message, radio: @radio }
        logger.debug "@#{message.from.username}: #{message.text if message.respond_to?(:text)} chat: #{message.chat.id}"
        if Settings.auth['chat_ids'].include?(message.chat.id)
          MessageResponder.new(options).respond
        else
          logger.error "unauthorized chat id: #{message.chat.id}"
        end
      end
    end
  rescue => e
    logger.debug e.message + "\n\t" + e.backtrace.first(20).join("\n\t")
    sleep 5
    retry
  end
rescue => e
  FileUtils.mkdir_p(File.dirname(FALLBACK_LOG))
  fallback = Logger.new(FALLBACK_LOG)
  fallback.fatal "STARTUP CRASH: #{e.class}: #{e.message}\n\t#{e.backtrace.first(20).join("\n\t")}"
  raise
end

require 'logger'
require 'fileutils'

FALLBACK_LOG = 'log/bot.log'

begin
  require_relative '../config/boot'

  config = AppConfigurator.new
  config.configure

  token = Settings.telegram['token']
  LOGGER         = config.logger
  COMPACT_LOGGER = config.compact_logger
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
        msg_text = message.text || message.caption
        chat_id = message.chat.id
        logger.debug "[chat=#{chat_id}] @#{message.from.username}: #{msg_text}"
        logger.debug "[chat=#{chat_id}] chat_seen: title=#{message.chat.title.inspect} type=#{message.chat.type}"
        if Settings.auth['chats'].any? { |c| c['id'] == chat_id }
          MessageResponder.new(options).respond
        else
          logger.warn "[chat=#{chat_id}] unauthorized chat"
        end
      end
    end
  rescue => e
    logger.error "Bot crash (retrying in 5s): #{e.class}: #{e.message}\n\t#{e.backtrace.first(20).join("\n\t")}"
    sleep 5
    retry
  end
rescue => e
  FileUtils.mkdir_p(File.dirname(FALLBACK_LOG))
  fallback = Logger.new(FALLBACK_LOG)
  fallback.fatal "STARTUP CRASH: #{e.class}: #{e.message}\n\t#{e.backtrace.first(20).join("\n\t")}"
  raise
end

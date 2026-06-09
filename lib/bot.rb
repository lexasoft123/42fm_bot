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
  GPT_LOGGER     = config.gpt_logger
  logger = LOGGER

  logger.debug 'Starting telegram bot'

  @radio = Radio.new

  begin
    Telegram::Bot::Client.run(token, logger: logger) do |bot|
      TaskRunner.start(bot.api)
      logger.info "TaskRunner started"

      CronScheduler.start
      logger.info "CronScheduler started"

      @radio.start_keepalive
      logger.info "Radio keepalive started"

      synced = Chat.sync_from_config! rescue 0
      logger.info "Chat.sync_from_config!: synced #{synced} chats"

      AdminMenu.register_commands(bot.api)
      logger.info "AdminMenu.register_commands done"

      bot.listen do |update|
        BotDispatcher.dispatch(bot, update, radio: @radio)
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

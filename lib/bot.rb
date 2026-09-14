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

  # allowed_updates REPLACES Telegram's server default (which excludes
  # message_reaction/message_reaction_count), so the list must enumerate
  # every update type we consume. It only takes effect here on Client.run —
  # the options hash is threaded through Client#initialize into getUpdates;
  # passing it to bot.listen would be a no-op.
  ALLOWED_UPDATES = %w[message edited_message channel_post callback_query
                       message_reaction message_reaction_count].freeze

  # Crash-retry lives in ListenSupervisor: it rebuilds the client after a
  # Telegram 5xx/SSL error and resumes from the last getUpdates offset.
  ListenSupervisor.new(token, logger: logger, client_options: { allowed_updates: ALLOWED_UPDATES }).run do |bot|
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
  FileUtils.mkdir_p(File.dirname(FALLBACK_LOG))
  fallback = Logger.new(FALLBACK_LOG)
  fallback.fatal "STARTUP CRASH: #{e.class}: #{e.message}\n\t#{e.backtrace.first(20).join("\n\t")}"
  raise
end

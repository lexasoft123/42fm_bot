require_relative '../config/boot'

config = AppConfigurator.new
config.configure

token = Settings.telegram['token']
logger = AppConfigurator::LOGGER
LOGGER = logger

logger.debug 'Starting telegram bot'

@radio = Radio.new

begin
   Telegram::Bot::Client.run(token, logger: logger) do |bot|
     bot.listen do |message|
       next unless message.is_a? Telegram::Bot::Types::Message
       next unless message.from
       options = {bot: bot, message: message, radio: @radio}
       logger.debug "@#{message.from.username}: #{message.text if message.respond_to?(:text)} chat: #{message.chat.id}"
       if Settings.auth['chat_ids'].include? message.chat.id
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

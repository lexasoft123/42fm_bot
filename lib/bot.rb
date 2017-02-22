require_relative '../config/boot'

config = AppConfigurator.new
config.configure

token = Settings.telegram['token']
logger = config.get_logger

logger.debug 'Starting telegram bot'

@radio = Radio.new

begin
   Telegram::Bot::Client.run(token) do |bot|
     bot.listen do |message|
       options = {bot: bot, message: message, radio: @radio}

       logger.debug "@#{message.from.username}: #{message.text} chat: #{message.chat.id}"
       begin
	 if AUTHORIZED_CHAT_IDS.include? message.chat.id
	   MessageResponder.new(options).respond
	 end
       rescue => exception
	 logger.debug "ACHTUNG!! TOOGOSERYA DETECTED!"
	 logger.debug exception.message + "\n\t" + exception.backtrace.first(20).join("\n\t")
       end
     end
   end

rescue
  sleep 5
  retry
end

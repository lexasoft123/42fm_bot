require_relative '../config/boot'

config = AppConfigurator.new
config.configure

token = Settings.telegram['token']
logger = AppConfigurator::LOGGER
LOGGER = logger

logger.debug 'Starting telegram bot'

if Settings.proxy['enabled']
  require 'socksify'
  proxy = Settings.proxy
  TCPSocket.socks_server = proxy['host']
  TCPSocket.socks_port   = proxy['port']
  TCPSocket.socks_username = proxy['user'] if proxy['user'] && !proxy['user'].empty?
  TCPSocket.socks_password = proxy['password'] if proxy['password'] && !proxy['password'].empty?
  logger.debug "SOCKS proxy enabled: #{proxy['host']}:#{proxy['port']}"
end

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

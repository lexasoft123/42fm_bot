require 'logger'
require 'active_support'
require 'active_record'
require './lib/database_connector'
require './lib/settings'
require 'ostruct'

Dir["./config/initializers/*.rb"].each { |file| require file }
Dir["./models/*.rb"].each { |file| require file }

class AppConfigurator
  LOGGER = Logger.new(STDOUT, Logger::DEBUG)

  def configure
    setup_i18n
    setup_database
    setup_proxy
  end

  private

  def setup_i18n
    I18n.load_path = Dir['config/locales.yml']
    I18n.locale = :en
    I18n.backend.load_translations
  end

  def setup_database
    DatabaseConnector.establish_connection
  end

  def setup_proxy
    return unless Settings.proxy['enabled']
    require 'socksify'
    proxy = Settings.proxy
    TCPSocket.socks_server   = proxy['host']
    TCPSocket.socks_port     = proxy['port']
    TCPSocket.socks_username = proxy['user']     if proxy['user'] && !proxy['user'].empty?
    TCPSocket.socks_password = proxy['password'] if proxy['password'] && !proxy['password'].empty?
    AppConfigurator::LOGGER.debug "SOCKS proxy enabled: #{proxy['host']}:#{proxy['port']}"
  end
end

require 'logger'
require 'active_support'
require 'active_record'
require './lib/database_connector'
require './lib/settings'
require 'ostruct'

Dir["./config/initializers/*.rb"].each {|file| require file }
Dir["./models/*.rb"].each {|file| require file }

class AppConfigurator
  LOGGER = Logger.new(STDOUT, Logger::DEBUG)

  def configure
    setup_i18n
    setup_database
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
end

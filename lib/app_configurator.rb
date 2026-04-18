require 'logger'
require 'fileutils'
require 'active_support'
require 'active_record'
require './lib/database_connector'
require './lib/settings'
require 'ostruct'

Dir["./config/initializers/*.rb"].each { |file| require file }
Dir["./models/*.rb"].each { |file| require file }

class AppConfigurator
  def configure
    setup_logging
    setup_i18n
    setup_database
    setup_proxy
  end

  def logger
    @logger
  end

  def compact_logger
    @compact_logger
  end

  def gpt_logger
    @gpt_logger
  end

  private

  def setup_logging
    cfg        = Settings.logging
    path       = cfg['path']
    level      = Logger.const_get(cfg['level'].upcase)
    max_size   = cfg['max_size_mb'] * 1024 * 1024
    keep_files = cfg['keep_files']
    log_dir    = File.dirname(path)
    FileUtils.mkdir_p(log_dir)

    @logger         = make_logger(path, keep_files, max_size, level)
    @compact_logger = make_logger(File.join(log_dir, 'knowledge_compact.log'), keep_files, max_size, Logger::DEBUG)
    @gpt_logger     = make_gpt_logger(File.join(log_dir, 'gpt.log'))
  end

  def make_logger(path, keep_files, max_size, level)
    l = Logger.new(path, keep_files, max_size)
    l.level = level
    l
  end

  # NDJSON dump of every LLM request+response (GptMaster writes here).
  # One JSON object per line, no logger metadata (timestamp is in the payload).
  # Rotation: 5 files × 50MB = 250MB cap. Toggle via Settings.chat_gpt['debug_log'].
  def make_gpt_logger(path)
    l = Logger.new(path, 5, 50 * 1024 * 1024)
    l.level = Logger::INFO
    l.formatter = ->(_sev, _ts, _prog, msg) { "#{msg}\n" }
    l
  end

  def setup_i18n
    I18n.load_path = Dir['config/locales.yml']
    I18n.locale = :en
    I18n.backend.load_translations
  end

  def setup_database
    DatabaseConnector.establish_connection(logger: @logger)
  end

  def setup_proxy
    return unless Settings.proxy['enabled']
    require 'socksify'
    proxy = Settings.proxy
    TCPSocket.socks_server   = proxy['host']
    TCPSocket.socks_port     = proxy['port']
    TCPSocket.socks_username = proxy['user']     if proxy['user'] && !proxy['user'].empty?
    TCPSocket.socks_password = proxy['password'] if proxy['password'] && !proxy['password'].empty?
    @logger.debug "SOCKS proxy enabled: #{proxy['host']}:#{proxy['port']}"
  end
end

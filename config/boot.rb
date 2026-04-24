require 'pathname'
APP_PATH = Pathname.new File.expand_path('../../',  __FILE__)
Dir.chdir APP_PATH

require './lib/settings'
require './lib/log_timing'
require 'telegram/bot'
require './lib/radio'
require './lib/message_responder'
require './models/background_task'
require './models/api_usage'
require './lib/chat_context'
require './lib/task_runner'
Dir['./lib/task_handlers/*.rb'].each { |f| require f }
require './lib/music_scanner'
require './lib/app_configurator'

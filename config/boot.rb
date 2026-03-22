require 'pathname'
APP_PATH = Pathname.new File.expand_path('../../',  __FILE__)
Dir.chdir APP_PATH

require './lib/settings'
require 'telegram/bot'
require './lib/radio'
require './lib/message_responder'
require './models/background_task'
require './lib/task_runner'
Dir['./lib/task_handlers/*.rb'].each { |f| require f }
require './lib/app_configurator'

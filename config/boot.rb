require 'pathname'
APP_PATH = Pathname.new File.expand_path('../../',  __FILE__)
Dir.chdir APP_PATH

require './lib/settings'
require 'telegram/bot'
require './lib/radio'
require './lib/message_responder'
require './lib/app_configurator'

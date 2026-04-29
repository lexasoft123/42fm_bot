require 'pathname'
APP_PATH = Pathname.new File.expand_path('../../',  __FILE__)
Dir.chdir APP_PATH

require './lib/settings'
require './lib/log_timing'
require 'telegram/bot'
require './lib/radio'
require './lib/admin_menu'
require './lib/message_responder'
require './lib/bot_dispatcher'
require './models/background_task'
require './models/api_usage'
require './models/chat'
require './models/chat_state'
require './lib/agent/scratchpad'
require './lib/agent/tool_result'
require './lib/chat_context'
require './lib/telegram_file'
require './lib/task_runner'
require './lib/cron_scheduler'
Dir['./lib/task_handlers/*.rb'].each { |f| require f }
require './lib/music_scanner'
require './lib/app_configurator'

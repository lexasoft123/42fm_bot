require 'rss'
require 'yaml'
require 'unicode_utils'

require './lib/message_sender'
require './lib/reply_master'
require './lib/gogolmogol'
require './lib/weather'
require './lib/translator'
require './lib/dice'
require './lib/horoscope'
require './lib/markov'
require './lib/gpt_master'
require './lib/polly'
require './lib/tts_service'
require './lib/command_context'
require './lib/command_result'
require './lib/commands/base'
require './lib/commands/gpt_helpers'
require './lib/commands/tts_voice'
require './lib/commands/bober_voice'
require './lib/commands/order_block'
require './lib/commands/order_request'
require './lib/commands/radio_search'
require './lib/commands/radio_track'
require './lib/commands/stats'
require './lib/commands/radio_queue'
require './lib/commands/weather'
require './lib/commands/listeners'
require './lib/commands/remove_track'
require './lib/commands/remaining'
require './lib/commands/history'
require './lib/commands/radio_top'
require './lib/commands/meta'
require './lib/commands/help'
require './lib/commands/gpt_question'
require './lib/commands/gpt_chat4'
require './lib/commands/gpt_chat'
require './lib/commands/horoscope_sign'
require './lib/commands/horoscope_general'
require './lib/commands/news'
require './lib/commands/markov'
require './lib/commands/translate'
require './lib/commands/dice'
require './lib/commands/reply_you'
require './lib/commands/phrase_top'
require './lib/commands/gif_search'
require './lib/commands/google_search'
require './lib/commands/fallback_reply'
require './lib/commands/registry'

class MessageResponder
  attr_reader :message, :bot, :user, :reply_master, :radio

  def initialize(options)
    @bot = options[:bot]
    @message = options[:message]
    @chat_id = @message.chat.id
    @user = User.create_with(
      name: message.from.username,
      first_name: message.from.first_name,
      last_name: message.from.last_name,
      role: 'new'
    ).find_or_create_by(uid: message.from.id)
    update_user_data
    @reply_master = ReplyMaster.new
    @radio = options[:radio]
  end

  def respond
    save_message
    p message

    return if message.date + 30 < Time.now.to_i
    process_voice_message if message.voice

    cmd = UnicodeUtils.downcase(message.text) if message.text

    ctx = CommandContext.new(
      bot: @bot,
      message: @message,
      user: @user,
      chat_id: @chat_id,
      radio: @radio,
      reply_master: @reply_master,
      cmd: cmd
    )

    LOGGER.debug "respond: dispatching cmd=#{cmd.inspect}"
    result = dispatch(ctx)
    LOGGER.debug "respond: delivering #{result&.type}"
    deliver(result)
  end

  private

  def dispatch(ctx)
    Commands::REGISTRY.each do |klass|
      command = klass.new(ctx)
      if command.match?
        LOGGER.debug "dispatch matched: #{klass.name}"
        return command.execute
      end
    end
    nil
  end

  def deliver(result)
    return unless result
    case result.type
    when :text    then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload).send if result.payload
    when :sticker then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload).send_sticker
    when :image   then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload).send_image
    when :voice   then @bot.api.sendVoice(chat_id: @chat_id, voice: result.payload)
    when :none    then nil
    end
  end

  def save_message
    Message.create(user_uid: @user.uid, chat_id: @chat_id, body: message.text) if message.text
  end

  def update_user_data
    if user.name != message.from.username || user.first_name != message.from.first_name
      user.name = message.from.username
      user.first_name = message.from.first_name
      user.last_name = message.from.last_name
      user.save
    end
  end

  def process_voice_message
    return unless Settings.auth['audio_chat_ids'].include?(@chat_id)

    file_id = message.voice.file_id
    file = bot.api.getFile(file_id: file_id)
    file_path = file['result']['file_path']
    p file

    return unless message.voice.mime_type == "audio/ogg"

    token = Settings.telegram['token']
    link = "https://api.telegram.org/file/bot#{token}/#{file_path}"
    MessageSender.new(bot: @bot, chat: message.chat, text: link).send
  end
end

require 'rss'
require 'yaml'
require 'fileutils'
require 'unicode_utils'

require './lib/message_sender'
require './lib/reply_master'
require './lib/gogolmogol'
require './lib/weather'
require './lib/dice'
require './lib/horoscope'
require './lib/gpt_master'
require './lib/embedding_service'
require './lib/knowledge_base'
require './lib/agent/tool_registry'
require './lib/agent/runner'
Dir['./lib/agent/tools/*.rb'].each { |f| require f }
require './lib/suno_client'
require './lib/flux_client'
require './lib/polly'
require './lib/tts_service'
require './lib/rate_limiter'
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
require './lib/commands/task_queue'
require './lib/commands/gpt_question'
require './lib/commands/gpt_chat'
require './lib/commands/horoscope_sign'
require './lib/commands/horoscope_general'
require './lib/commands/news'
require './lib/commands/translate'
require './lib/commands/dice'
require './lib/commands/reply_you'
require './lib/commands/phrase_top'
require './lib/commands/gif_search'
require './lib/commands/google_search'
require './lib/commands/knowledge_add'
require './lib/commands/knowledge_list'
require './lib/commands/knowledge_delete'
require './lib/commands/knowledge_compact'
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

    return if message.date + 30 < Time.now.to_i
    process_voice_message if message.voice
    return unless message.text

    cmd = UnicodeUtils.downcase(message.text)

    ctx = CommandContext.new(
      bot: @bot,
      message: @message,
      user: @user,
      chat_id: @chat_id,
      radio: @radio,
      reply_master: @reply_master,
      cmd: cmd
    )

    result = dispatch(ctx)
    LOGGER.debug "respond: delivering #{result&.type}"
    deliver(result)
  rescue => e
    LOGGER.error "respond failed: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
    begin
      MessageSender.new(bot: @bot, chat: message.chat, text: "Мозги перегрелись, попробуй позже 🤖").send
    rescue => notify_err
      LOGGER.warn "respond: failed to send error notification: #{notify_err.class}: #{notify_err.message}"
    end
  end

  private

  def dispatch(ctx)
    Commands::REGISTRY.each do |klass|
      command = klass.new(ctx)
      if command.match?
        LOGGER.info "dispatch matched: #{klass.name}"
        return command.execute
      end
    end
    nil
  end

  def deliver(result)
    return unless result
    case result.type
    when :text    then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload, reply_to_message_id: result.meta[:reply_to_message_id]).send if result.payload
    when :sticker then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload).send_sticker
    when :image   then MessageSender.new(bot: @bot, chat: message.chat, text: result.payload).send_image
    when :voice
      path = result.payload
      @bot.api.sendVoice(chat_id: @chat_id, voice: Faraday::UploadIO.new(path, 'audio/ogg'))
      FileUtils.rm_f(path)
    when :audio   then @bot.api.sendAudio(
      chat_id: @chat_id, audio: result.payload,
      title: result.meta[:title], performer: result.meta[:performer])
    when :none    then nil
    end
  rescue => e
    LOGGER.error "deliver failed (#{result.type}): #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
  end

  def save_message
    return unless message.text
    Message.create(user_uid: @user.uid, chat_id: @chat_id, body: message.text)
    maybe_extract_knowledge
  end

  def maybe_extract_knowledge
    return unless Settings._settings.respond_to?(:knowledge) && Settings.knowledge
    extract_every = Settings.knowledge['extract_every']
    count = Message.where(chat_id: @chat_id, role: 'user').count
    return unless count % extract_every == 0

    chat_id = @chat_id
    Thread.new do
      recent = ActiveRecord::Base.connection_pool.with_connection do
        Message.left_outer_joins(:user)
          .select('users.name, messages.body')
          .where(chat_id: chat_id, role: 'user')
          .order('messages.created_at DESC')
          .limit(extract_every)
          .reverse
          .to_a
      end
      KnowledgeBase.extract_and_store(recent, chat_id: chat_id)
    rescue => e
      LOGGER.error "maybe_extract_knowledge thread error: #{e.message}"
    end
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
    audio_ids = Settings.auth['chats'].select { |c| c['audio'] }.map { |c| c['id'] }
    return unless audio_ids.include?(@chat_id)

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

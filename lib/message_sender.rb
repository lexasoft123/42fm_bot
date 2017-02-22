require './lib/reply_markup_formatter'
require './lib/app_configurator'
require './lib/file_uploader'

class MessageSender
  attr_reader :bot
  attr_reader :text
  attr_reader :chat
  attr_reader :answers
  attr_reader :logger

  def initialize(options)
    @bot = options[:bot]
    @api = @bot.api
    @text = options[:text]
    @chat = options[:chat]
    @answers = options[:answers]
    @logger = AppConfigurator.new.get_logger
  end

  def send
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')

    if reply_markup
      bot.api.sendMessage(chat_id: chat.id, text: text, reply_markup: reply_markup)
    else
      bot.api.sendMessage(chat_id: chat.id, text: text)
    end

    logger.debug "sending '#{text}' to #{chat.title}"
  end

  def send_sticker
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')
    bot.api.sendSticker(chat_id: chat.id, sticker: text)
  end

  def send_image
    @api.sendChatAction(chat_id: chat.id, action: 'upload_photo')

    f = FileUploader.new(text).upload!

    logger.debug "sending image '#{f.path}' to #{chat.title}"

    @api.sendChatAction(chat_id: chat.id, action: 'upload_photo')
    if text =~ /[.]gif/
      @api.sendDocument(chat_id: chat.id, document: f)
    else
      @api.sendPhoto(chat_id: chat.id, photo: f)
    end

    File.delete(f)

  rescue Exception => e
    @api.sendChatAction(chat_id: chat.id, action: 'typing')
    logger.error e.message + "\n\t" + e.backtrace.first(10).join("\n\t")
    @api.sendMessage(chat_id: chat.id, text: 'ебучий гугл!!11')
  end

  private

  def reply_markup
    if answers
      ReplyMarkupFormatter.new(answers).get_markup
    end
  end
end

require './lib/reply_markup_formatter'
require './lib/app_configurator'

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
    @logger = LOGGER
  end

  def send
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')

    params = { chat_id: chat.id, text: sanitize_markdown(text), parse_mode: 'Markdown' }
    params[:reply_markup] = reply_markup if reply_markup

    begin
      bot.api.sendMessage(params)
    rescue => e
      logger.warn "Markdown parse failed, retrying as plain text: #{e.message}"
      params[:text] = text
      params.delete(:parse_mode)
      bot.api.sendMessage(params)
    end

    logger.debug "sending '#{text}' to #{chat.title}"
  end

  def send_sticker
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')
    bot.api.sendSticker(chat_id: chat.id, sticker: text)
  end

  def send_image

    if text =~ /[.]gif/
      logger.debug "chat: #{chat.id} - send document: #{text}"
      @api.sendDocument chat_id: chat.id, document: text
    else
      logger.debug "chat: #{chat.id} - send photo: #{text}"
      @api.sendPhoto(chat_id: chat.id, photo: text)
    end

  rescue Exception => e
    logger.error e.message + "\n\t" + e.backtrace.first(10).join("\n\t")
    @api.sendMessage(chat_id: chat.id, text: 'ебучий гугл!!11')
  end

  private

  def sanitize_markdown(text)
    # Replace **bold** with *bold* (Telegram Markdown uses single *)
    result = text.gsub(/\*\*(.+?)\*\*/, '*\1*')
    # Escape underscores inside words to prevent broken italic
    # But preserve _italic_ (underscore at word boundaries)
    result = result.gsub(/(?<=\w)_(?=\w)/, '\\_')
    # Strip unbalanced backticks (odd count outside code blocks)
    # Remove triple backtick blocks and replace with content only if unbalanced
    result
  end

  def reply_markup
    if answers
      ReplyMarkupFormatter.new(answers).get_markup
    end
  end
end

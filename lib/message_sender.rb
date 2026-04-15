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
    @reply_to_message_id = options[:reply_to_message_id]
    @logger = LOGGER
  end

  def send
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')

    split_text(text).each do |chunk|
      send_chunk(chunk)
    end

    logger.debug "#{self.class.name}#send: '#{text.slice(0, 80)}' to #{chat.title}"
  end

  def send_sticker
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')
    bot.api.sendSticker(chat_id: chat.id, sticker: text)
  end

  def send_image

    if text =~ /[.]gif/
      logger.debug "#{self.class.name}#send_image: document #{text}"
      @api.sendDocument chat_id: chat.id, document: text
    else
      logger.debug "#{self.class.name}#send_image: photo #{text}"
      @api.sendPhoto(chat_id: chat.id, photo: text)
    end

  rescue => e
    logger.error e.message + "\n\t" + e.backtrace.first(10).join("\n\t")
    @api.sendMessage(chat_id: chat.id, text: 'ебучий гугл!!11')
  end

  private

  def sanitize_markdown(text)
    # Replace **bold** with *bold* (Telegram Markdown uses single *)
    result = text.gsub(/\*\*(.+?)\*\*/, '*\1*')
    # Wrap markdown tables in code blocks (Telegram doesn't render tables)
    result = result.gsub(/(?:^[ \t]*\|.+\|[ \t]*\n){2,}/m) { |table| "```\n#{table.gsub(/[*_`]/, '')}```\n" }
    # Escape underscores inside words to prevent broken italic,
    # but skip code blocks (```...```) and inline code (`...`)
    result = result.gsub(/```.*?```|`[^`]+`/m) { |m| m.gsub('_', "\x00") }
    result = result.gsub(/(?<=\w)_(?=\w)/, '\\_')
    result = result.gsub("\x00", '_')
    result
  end

  MAX_MESSAGE_LENGTH = 4096

  def send_chunk(chunk)
    params = { chat_id: chat.id, text: sanitize_markdown(chunk), parse_mode: 'Markdown' }
    params[:reply_to_message_id] = @reply_to_message_id if @reply_to_message_id
    params[:reply_markup] = reply_markup if reply_markup

    begin
      bot.api.sendMessage(params)
    rescue => e
      logger.warn "#{self.class.name}#send_chunk: Markdown parse failed, retrying as plain text: #{e.message}"
      params[:text] = chunk
      params.delete(:parse_mode)
      bot.api.sendMessage(params)
    end
  end

  def split_text(text)
    return [text] if text.length <= MAX_MESSAGE_LENGTH

    chunks = []
    lines = text.lines
    current = +''

    lines.each do |line|
      if current.length + line.length > MAX_MESSAGE_LENGTH && !current.empty?
        chunks << current
        current = +''
      end
      current << line
    end
    chunks << current unless current.empty?
    chunks
  end

  def reply_markup
    if answers
      ReplyMarkupFormatter.new(answers).get_markup
    end
  end
end

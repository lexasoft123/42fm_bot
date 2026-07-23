require './lib/reply_markup_formatter'
require './lib/app_configurator'
require './lib/telegram_rich_client'

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
    @message_thread_id = options[:message_thread_id]
    @rich_client = options[:rich_client]   # injectable for tests
    @logger = LOGGER
  end

  # Sends `text`, preferring Telegram Rich Messages (Bot API 10.1) — the LLM
  # already emits GitHub-Flavored Markdown, which is exactly Rich Markdown. On
  # ANY rich failure (feature off, over-length, HTTP/timeout, ok:false) we fall
  # back to the classic sendMessage path below, so behaviour degrades safely.
  # Returns the first message_id either way (persistence contract unchanged).
  def send
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')

    if rich_enabled?
      # outcome: Integer message_id (sent), :sent (delivered but no usable id /
      # ambiguous → suppress classic to avoid a duplicate), or nil (rejected →
      # fall through to the classic path below).
      outcome = try_rich_send
      return outcome.is_a?(Integer) ? outcome : nil unless outcome.nil?
    end

    first_id = nil
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    split_text(text).each do |chunk|
      resp = send_chunk(chunk)
      first_id ||= extract_message_id(resp)
    end
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

    logger.debug "#{self.class.name}#send: '#{text.slice(0, 80)}' to #{chat.title} took=#{took_ms}ms"
    first_id
  end

  def send_sticker
    bot.api.sendChatAction(chat_id: chat.id, action: 'typing')
    bot.api.sendSticker(**media_params(sticker: text))
  end

  # Returns the raw Telegram response on success, or nil when the send
  # failed (the rescue path sends a fallback text, not an image — callers
  # must not persist that as a `[картинка]` row).
  def send_image
    if text =~ /[.]gif/
      logger.debug "#{self.class.name}#send_image: document #{text}"
      @api.sendDocument(**media_params(document: text))
    else
      logger.debug "#{self.class.name}#send_image: photo #{text}"
      @api.sendPhoto(**media_params(photo: text))
    end

  rescue => e
    logger.error e.message + "\n\t" + e.backtrace.first(10).join("\n\t")
    @api.sendMessage(chat_id: chat.id, text: 'ебучий гугл!!11')
    nil
  end

  private

  # Rich Messages are attempted only when the feature flag is on, a token is
  # configured, and the message carries no reply keyboard (rich reply_markup is
  # a dead path here — no caller passes `answers:` — so classic handles it).
  # The respond_to? guard tolerates minimal Settings stubs (bare OpenStruct/{}
  # with no `telegram` key) that some tests leave in place — falls back cleanly.
  def rich_enabled?
    return false if @answers
    return false unless Settings._settings.respond_to?(:telegram)
    tg = Settings.telegram
    !!(tg && tg['rich_messages'] && !tg['token'].to_s.empty?)
  rescue StandardError
    false
  end

  # Returns an Integer message_id (sent, id known), :sent (delivered but no
  # usable id, OR ambiguous transport state — caller must NOT fall back, to
  # avoid a duplicate), or nil (rejected/not-sent → caller falls back to
  # classic). `text` is sent RAW: Rich Markdown natively handles **bold**,
  # tables and snake_case, so sanitize_markdown (a legacy workaround) is skipped.
  def try_rich_send
    result = rich_client.send_rich(
      chat_id: chat.id,
      markdown: text,
      message_thread_id: @message_thread_id,
      reply_to_message_id: @reply_to_message_id
    )
    id = result.is_a?(Hash) ? result['message_id'] : nil
    logger.debug "#{self.class.name}#send: rich=ok id=#{id} to #{chat.title}"
    id.is_a?(Integer) ? id : :sent   # ok:true but no id → delivered; don't re-send
  rescue TelegramRichClient::Rejected => e
    logger.warn "#{self.class.name}#send: rich=fallback reason=#{e.message}"
    nil
  rescue TelegramRichClient::Ambiguous => e
    # Maybe delivered — suppress the classic fallback so we don't duplicate.
    logger.warn "#{self.class.name}#send: rich=ambiguous no-fallback reason=#{e.message}"
    :sent
  rescue StandardError => e
    # Unexpected (likely pre-send bug) → fall back so the user still gets a reply.
    logger.warn "#{self.class.name}#send: rich=fallback reason=#{e.class}: #{e.message}"
    nil
  end

  def rich_client
    @rich_client ||= TelegramRichClient.new(token: Settings.telegram['token'])
  end

  # Common chat_id (+ optional forum thread) params for media sends, merged
  # with the type-specific payload. Splatted as keywords at the call site.
  def media_params(extra)
    p = { chat_id: chat.id }
    p[:message_thread_id] = @message_thread_id if @message_thread_id
    p.merge(extra)
  end

  def sanitize_markdown(text)
    # Replace **bold** with *bold* (Telegram legacy Markdown uses single *)
    result = text.gsub(/\*\*(.+?)\*\*/, '*\1*')
    # Wrap markdown tables in code blocks (Telegram doesn't render tables)
    result = result.gsub(/(?:^[ \t]*\|.+\|[ \t]*\n){2,}/m) { |table| "```\n#{table.gsub(/[*_`]/, '')}```\n" }
    # Neutralize GFM-only constructs legacy Markdown can't render, so a
    # rich→classic fallback (and the rich-off kill-switch state) isn't littered
    # with literal ||…|| / ~~…~~ / # markup — and a spoiler doesn't reveal as
    # bare bars. Done outside code spans so `a || b` / `#comment` in code survive.
    result = strip_gfm_only(result)
    # Escape underscores inside words to prevent broken italic,
    # but skip code blocks (```...```) and inline code (`...`)
    result = result.gsub(/```.*?```|`[^`]+`/m) { |m| m.gsub('_', "\x00") }
    result = result.gsub(/(?<=\w)_(?=\w)/, '\\_')
    result = result.gsub("\x00", '_')
    result
  end

  # Remove GFM-only markers legacy Markdown ignores, preserving code spans
  # verbatim (split keeps the delimiters at odd indices).
  def strip_gfm_only(text)
    text.split(/(```.*?```|`[^`]+`)/m).each_with_index.map { |seg, i|
      i.odd? ? seg : seg
        .gsub(/\|\|(.+?)\|\|/m, '\1')     # ||spoiler|| → spoiler
        .gsub(/~~(.+?)~~/m, '\1')         # ~~strike~~ → strike
        .gsub(/^ {0,3}#+[ \t]+/, '')      # leading "# " heading marker → drop
    }.join
  end

  MAX_MESSAGE_LENGTH = 4096

  def send_chunk(chunk)
    params = { chat_id: chat.id, text: sanitize_markdown(chunk), parse_mode: 'Markdown' }
    params[:reply_to_message_id] = @reply_to_message_id if @reply_to_message_id
    params[:message_thread_id]   = @message_thread_id   if @message_thread_id
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

  def extract_message_id(resp)
    return nil unless resp
    return resp.message_id if resp.respond_to?(:message_id)
    return nil unless resp.is_a?(Hash)
    resp.dig('result', 'message_id') || resp['message_id']
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

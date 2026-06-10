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
require './lib/image_gen'
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
require './lib/commands/cost_report'
require './lib/commands/gpt_chat'
require './lib/commands/news'
require './lib/commands/rules'
require './lib/commands/quote'
require './lib/commands/wrapped'
require './lib/commands/dice'
require './lib/commands/phrase_top'
require './lib/commands/knowledge_add'
require './lib/commands/knowledge_list'
require './lib/commands/knowledge_delete'
require './lib/commands/knowledge_compact'
require './lib/commands/admin_menu_open'
require './lib/commands/fallback_reply'
require './lib/commands/registry'

class MessageResponder
  attr_reader :message, :bot, :user, :reply_master, :radio

  # Anchor for the "skip stale message" check below. Set once at class load
  # so each new responder compares against the process-startup time, not a
  # rolling now()-30s window.
  PROCESS_START          = Time.now
  STALE_GUARD_WINDOW_SEC = 60   # filter only fires during this initial window
  STALE_THRESHOLD_SEC    = 30   # drop messages older than this when filtering

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

    return if message.edit_date
    return if stale_after_restart?
    return if maybe_handle_admin_input
    process_voice_message if message.voice && !super_admin_awaiting_input?

    text = message.text || message.caption
    return unless text

    cmd = UnicodeUtils.downcase(text)

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
    LOGGER.debug "[chat=#{@chat_id}] #{self.class.name}#respond: delivering #{result&.type}"
    deliver(result)
  rescue => e
    LOGGER.error "[chat=#{@chat_id}] #{self.class.name}#respond: #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
    begin
      MessageSender.new(bot: @bot, chat: message.chat, text: "Мозги перегрелись, попробуй позже 🤖").send
    rescue => notify_err
      LOGGER.warn "[chat=#{@chat_id}] #{self.class.name}#respond: failed to send error notification: #{notify_err.class}: #{notify_err.message}"
    end
  end

  private

  def dispatch(ctx)
    Commands::REGISTRY.each do |klass|
      command = klass.new(ctx)
      if command.match?
        LOGGER.info "[chat=#{@chat_id}] #{self.class.name}#dispatch: matched #{klass.name}"
        return command.execute
      end
    end
    nil
  end

  # Every successfully-sent bot output is persisted as a `role: 'bot'`
  # messages row so (a) it appears in chat history/context and (b) a later
  # user reply can resolve its message_id back to a known row. Text uses a
  # direct create (MessageSender#send returns the bare message_id); media
  # types reuse Message.persist_bot_reply, which extracts id + thread_id
  # from the raw Telegram response.
  def deliver(result)
    return unless result
    case result.type
    when :text
      return if result.payload.to_s.strip.empty?
      sent_id = MessageSender.new(
        bot: @bot, chat: message.chat, text: result.payload,
        reply_to_message_id: result.meta[:reply_to_message_id],
        message_thread_id: @message.message_thread_id
      ).send
      if sent_id
        Message.create(
          role: 'bot', chat_id: @chat_id, body: result.payload,
          message_id: sent_id,
          reply_to_message_id: result.meta[:reply_to_message_id],
          message_thread_id: @message.message_thread_id
        )
      end
    when :sticker
      resp = MessageSender.new(
        bot: @bot, chat: message.chat, text: result.payload,
        message_thread_id: @message.message_thread_id
      ).send_sticker
      Message.persist_bot_reply(chat_id: @chat_id, body: '[стикер]', response: resp)
    when :image
      resp = MessageSender.new(
        bot: @bot, chat: message.chat, text: result.payload,
        message_thread_id: @message.message_thread_id
      ).send_image
      # send_image returns nil when the send failed and a fallback text was
      # sent instead — don't mislabel that as an image row.
      Message.persist_bot_reply(chat_id: @chat_id, body: '[картинка]', response: resp) if resp
    when :voice
      path = result.payload
      voice_params = { chat_id: @chat_id, voice: Faraday::UploadIO.new(path, 'audio/ogg') }
      voice_params[:message_thread_id] = @message.message_thread_id if @message.message_thread_id
      resp = @bot.api.sendVoice(**voice_params)
      Message.persist_bot_reply(chat_id: @chat_id, body: '[голос]', response: resp)
      FileUtils.rm_f(path)
    when :audio
      # No command currently produces CommandResult.audio (dead path); a
      # future :audio producer should add a persist_bot_reply call here for
      # parity with the other media types.
      @bot.api.sendAudio(
        chat_id: @chat_id, audio: result.payload,
        title: result.meta[:title], performer: result.meta[:performer])
    when :none    then nil
    end
  rescue => e
    LOGGER.error "[chat=#{@chat_id}] #{self.class.name}#deliver(#{result.type}): #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
  end

  def save_message
    body = message.text || message.caption
    audio_src = message.audio || message.voice ||
                (message.document if message.document&.mime_type&.start_with?('audio/'))
    photo_file_id = photo_attachment_file_id
    # Persist media-only messages too (no caption) so `Commands::GptChat`
    # can walk back through recent rows to find an earlier audio upload, and
    # the agent's `view_image` tool can fetch an earlier photo. Body for a
    # media-only row uses a stable marker so the agent's chat context shows
    # "[аудио]" / "[фото]" rather than empty.
    return unless body || audio_src || photo_file_id
    body ||= audio_src ? '[аудио]' : '[фото]'

    if message.edit_date
      existing = Message.find_by(chat_id: @chat_id, message_id: message.message_id)
      if existing
        existing.update(body: body, edited_at: Time.at(message.edit_date))
        return
      end
    end

    media_only = !message.text && !message.caption  # nothing to extract from
    Message.create(
      user_uid: @user.uid, chat_id: @chat_id, body: body,
      message_id: message.message_id,
      reply_to_message_id: message.reply_to_message&.message_id,
      message_thread_id: message.message_thread_id,
      forwarded: !message.forward_origin.nil?,
      edited_at: (message.edit_date ? Time.at(message.edit_date) : nil),
      attachment_file_id:   audio_src&.file_id,
      attachment_mime_type: (audio_src.respond_to?(:mime_type) ? audio_src.mime_type : nil),
      attachment_title:     attachment_title_from(audio_src),
      attachment_performer: (audio_src.respond_to?(:performer) ? audio_src.performer : nil),
      attachment_duration:  (audio_src.respond_to?(:duration)  ? audio_src.duration  : nil),
      attachment_photo_file_id: photo_file_id
    )
    # Media-only rows have a `[аудио]`/`[фото]` placeholder body — feeding
    # them to the knowledge extractor adds noise AND bumps
    # `count % extract_every` cadence so real-text extraction fires on the
    # wrong message. Skip.
    maybe_extract_knowledge unless message.edit_date || media_only
  end

  # Pick the photo size whose file_id we persist for later `view_image`
  # fetches — see Message.pick_photo_file_id (shared with the bot-side
  # sendPhoto/sendMediaGroup persistence paths).
  def photo_attachment_file_id
    Message.pick_photo_file_id(message.photo)
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
          .select(ChatContext::SELECT_COLS)
          .where(chat_id: chat_id, role: 'user')
          .order('messages.created_at DESC')
          .limit(extract_every)
          .reverse
          .to_a
      end
      KnowledgeBase.extract_and_store(recent, chat_id: chat_id)
    rescue => e
      LOGGER.error "[chat=#{chat_id}] #{self.class.name}#maybe_extract_knowledge: #{e.message}"
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

  # Title fallback chain for the persisted column: Audio.title (ID3) →
  # Document.file_name minus extension. Mirrors the in-memory computation
  # in Commands::GptChat#audio_metadata_from so chat context and runtime
  # decision-making see the same value.
  def attachment_title_from(src)
    return nil unless src
    title = (src.respond_to?(:title) ? src.title : nil).to_s
    return title unless title.empty?
    return nil unless src.respond_to?(:file_name) && !src.file_name.to_s.empty?
    File.basename(src.file_name.to_s, '.*').strip.then { |s| s.empty? ? nil : s }
  end

  # On restart Telegram replays the last few hours of unread updates via
  # getUpdates — replying to all of them would spam the chat with stale
  # context. Filter messages older than STALE_THRESHOLD_SEC, but ONLY
  # during the first STALE_GUARD_WINDOW_SEC seconds after process start.
  # After the initial replay window, process all messages regardless of
  # age — under sustained load (slow agent turns queueing up), legitimate
  # user messages can routinely exceed 30s before we get to them, and
  # silently dropping them is worse than a delayed reply.
  def stale_after_restart?
    return false if (Time.now - PROCESS_START) > STALE_GUARD_WINDOW_SEC
    stale = message.date + STALE_THRESHOLD_SEC < Time.now.to_i
    LOGGER.debug "[chat=#{@chat_id}] stale_after_restart? skipping replay-window message.date=#{message.date} now=#{Time.now.to_i}" if stale
    stale
  end

  # Admin-menu free-text input intercept. Returns true when the message is
  # consumed by AdminMenu::TextInputHandler; false otherwise (so normal
  # dispatch continues). Only fires for super-admins in private chats with an
  # active awaiting_input session — TextInputHandler itself enforces TTL,
  # /cancel, and slash-/бот-prefix bypasses.
  def maybe_handle_admin_input
    return false unless message.text
    return false unless message.chat.type == 'private'
    return false unless @user.super_admin?
    return false unless AdminMenu::Session.awaiting_input?(@user.uid)
    AdminMenu::TextInputHandler.handle(@bot, @message, @user)
  end

  # If a super-admin is in awaiting_input mode, skip voice-message handling so
  # the file URL (which contains the bot token) isn't echoed back into the
  # private chat as a side effect of the audio passthrough.
  def super_admin_awaiting_input?
    message.chat.type == 'private' && @user.super_admin? && AdminMenu::Session.awaiting_input?(@user.uid)
  end

  def process_voice_message
    return unless Chat.find_by(chat_id: @chat_id)&.audio

    file_id = message.voice.file_id
    file = bot.api.getFile(file_id: file_id)
    file_path = file['result']['file_path']
    LOGGER.debug "[chat=#{@chat_id}] #{self.class.name}#process_voice_message: #{file_path}"

    return unless message.voice.mime_type == "audio/ogg"

    token = Settings.telegram['token']
    link = "https://api.telegram.org/file/bot#{token}/#{file_path}"
    MessageSender.new(bot: @bot, chat: message.chat, text: link).send
  end
end

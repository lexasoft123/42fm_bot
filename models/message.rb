class Message < ActiveRecord::Base
  belongs_to :user, foreign_key: 'user_uid', primary_key: 'uid', optional: true

  # Cap for which Telegram PhotoSize gets persisted (see pick_photo_file_id).
  # Vision doesn't need full resolution, and the base64 payload of a
  # view_image fetch rides every subsequent agent iteration.
  PHOTO_MAX_DIMENSION = 1280

  # Persist a bot-sent message as a Message row so user replies can resolve
  # the bot's message_id back to context. The SINGLE write path for all
  # bot-side persistence: MessageResponder#deliver media types AND the
  # background-task handlers (image_gen / suno / cover_art / wav) route
  # through here. response can be a Telegram::Bot OpenStruct/typed object,
  # a raw Hash, or a 'result'-enveloped Hash (Net::HTTP-style) — and for
  # media groups, one element of the response array per call.
  # When the sent message was a photo (sendPhoto / media-group photo), its
  # file_id is captured too so the agent can re-view the bot's own image
  # output via the view_image tool.
  def self.persist_bot_reply(chat_id:, body:, response:, reply_to: nil, bg_task_external_id: nil)
    return unless response
    mid = response.respond_to?(:message_id) ? response.message_id :
          (response.is_a?(Hash) ? (response.dig('result', 'message_id') || response['message_id']) : nil)
    tid = response.respond_to?(:message_thread_id) ? response.message_thread_id :
          (response.is_a?(Hash) ? (response.dig('result', 'message_thread_id') || response['message_thread_id']) : nil)
    return unless mid
    ActiveRecord::Base.connection_pool.with_connection do
      create(role: 'bot', chat_id: chat_id, body: body, message_id: mid,
             message_thread_id: tid, reply_to_message_id: reply_to,
             bg_task_external_id: bg_task_external_id,
             attachment_photo_file_id: photo_file_id_from(response))
    end
  rescue => e
    LOGGER.warn "Message.persist_bot_reply failed: #{e.class}: #{e.message}" if defined?(LOGGER)
  end

  # Extract the persistable photo file_id from a Telegram Message (incoming
  # or a send* response) — OpenStruct/typed object or raw Hash, with or
  # without the 'result' envelope. nil for non-photo messages.
  def self.photo_file_id_from(msg)
    return nil unless msg
    photos = msg.respond_to?(:photo) ? msg.photo :
             (msg.is_a?(Hash) ? (msg.dig('result', 'photo') || msg['photo']) : nil)
    pick_photo_file_id(photos)
  end

  # Pick which PhotoSize's file_id to persist: the largest ≤1280px
  # (Telegram sizes ascend, typically 90/320/800/1280). Falls back to the
  # smallest size when nothing fits the cap — either no width info is
  # available, or every size exceeds it. Shared by
  # MessageResponder#save_message (incoming photos) and the bot-side
  # persistence paths (sendPhoto/sendMediaGroup responses).
  def self.pick_photo_file_id(photos)
    return nil unless photos.is_a?(Array) && !photos.empty?
    capped = photos.select { |p| (w = photo_size_width(p)) && w <= PHOTO_MAX_DIMENSION }
    photo_size_file_id(capped.last || photos.first)
  end

  def self.photo_size_width(p)
    if p.is_a?(Hash)
      (p['width'] || p[:width])&.to_i
    elsif p.respond_to?(:width)
      p.width.to_i
    end
  end
  private_class_method :photo_size_width

  def self.photo_size_file_id(p)
    if p.is_a?(Hash)
      p['file_id'] || p[:file_id]
    elsif p.respond_to?(:file_id)
      p.file_id
    end
  end
  private_class_method :photo_size_file_id
end

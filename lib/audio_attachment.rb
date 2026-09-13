# Resolves which audio a user's request refers to, for the Suno tools
# (cover_audio / add_vocals / separate_vocals). Extracted from
# Commands::GptChat so the priority chain is tested as real code rather
# than through a copied harness.
#
# Priority: (1) the current message's own attachment; (2) the reply
# target's attachment; (3) a lookback over recent stored rows.
#
# Allowlist: message.audio (any audio), message.voice (OGG),
# message.document only when mime_type starts with audio/. Video /
# video_note / animation are skipped.
#
# Returns { file_id:, mime_type:, duration:, title:, performer:, source:,
# message_id: } or nil. `message_id` is the Telegram id of the message
# carrying the audio, so a deferred tool call can point back at it. `source`
# is :message / :reply / :lookback; lookback results also carry `age_min` and
# `uploader_uid` so the agent (and tools) can tell a fresh attachment from
# something someone posted a while ago.
#
# The Telegram file URL is resolved lazily inside the Suno tool handlers via
# `TelegramFile.public_url(ctx[:api], ctx[:audio][:file_id])` — only when a
# tool actually needs it. Calling getFile here unconditionally would burn a
# Telegram round-trip for every audio-bearing message.
module AudioAttachment
  LOOKBACK_ROWS        = 20
  # Prod 2026-08-24: in a quiet DM the 20-row window reached back 12 days and
  # fed a stale upload to cover_audio (the wrong song got covered); 2026-09-04
  # a 7-hour-old upload in a busy group turned "спой движуха песню" into a
  # cover. Rows alone don't bound staleness — time does.
  LOOKBACK_MAX_AGE_MIN = 30

  module_function

  def resolve(message, chat_id:, now: Time.now)
    from_message(message, source: :message) ||
      (message.reply_to_message && from_message(message.reply_to_message, source: :reply)) ||
      recent(message, chat_id: chat_id, now: now)
  end

  def from_message(msg, source:)
    meta = metadata_from(msg)
    meta && meta.merge(source: source, message_id: (msg.message_id if msg.respond_to?(:message_id)))
  end

  def metadata_from(msg)
    src = msg.audio
    src ||= msg.voice
    src ||= (msg.document if msg.document&.mime_type&.start_with?('audio/'))
    return nil unless src

    # Title fallback chain: Audio.title (ID3) → Document.file_name minus
    # extension. The agent uses this to name the output track; without a
    # title hint it infers the name from prior chat context, which goes
    # wrong when the user uploads a fresh track unrelated to earlier talk.
    title = (src.respond_to?(:title) ? src.title : nil)
    title = File.basename(src.file_name.to_s, '.*').strip if (title.nil? || title.empty?) && src.respond_to?(:file_name) && !src.file_name.to_s.empty?
    {
      file_id:   src.file_id,
      mime_type: src.respond_to?(:mime_type) ? src.mime_type : nil,
      duration:  src.respond_to?(:duration)  ? src.duration  : nil,
      title:     title.to_s.empty? ? nil : title,
      performer: src.respond_to?(:performer) ? src.performer : nil,
    }
  end

  # Walk back through recent stored rows (saved by
  # MessageResponder#save_message) for an attachment. Covers "uploaded an
  # audio, then asked for a cover in a fresh message without Telegram-reply".
  # Filters: `role: 'user'` (bot media must not become a user source);
  # same-thread only in real forum chats — in non-forum supergroups
  # `message_thread_id` is just the root of a reply chain (commit 54e0499),
  # so filtering on it there hides audio posted outside that chain.
  def recent(message, chat_id:, now:)
    return nil unless chat_id
    scope = Message.where(chat_id: chat_id, role: 'user')
                   .where('created_at >= ?', now - LOOKBACK_MAX_AGE_MIN * 60)
    scope = scope.where(message_thread_id: message.message_thread_id) if forum?(message)
    row = scope.order(id: :desc).limit(LOOKBACK_ROWS).find { |m| m.attachment_file_id }
    return nil unless row
    { file_id:      row.attachment_file_id,
      mime_type:    row.attachment_mime_type,
      duration:     row.attachment_duration,
      title:        row.attachment_title,
      performer:    row.attachment_performer,
      source:       :lookback,
      message_id:   row.message_id,
      age_min:      ((now - row.created_at) / 60).floor,
      uploader_uid: row.user_uid }
  end

  def forum?(message)
    chat = message.respond_to?(:chat) ? message.chat : nil
    !!(chat && chat.respond_to?(:is_forum) && chat.is_forum)
  end
end

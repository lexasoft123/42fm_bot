# DM-only "send me the audio" follow-up for the Suno source tools
# (cover_audio / add_vocals / separate_vocals).
#
# Prod 2026-08-24: a user typed "сделай аранжировку этой песни" and sent the
# file a minute later. Captionless audio never reaches the agent
# (MessageResponder#respond returns without text, by design — see the
# no-audio-auto-trigger rule), so the only way through was to re-send the
# request as a reply. Now, when a tool can't find a source on a REAL user
# turn in a PRIVATE chat, it registers the request here; the user's next
# captionless audio / audio-document in that DM (within TTL) replays the
# request with that file attached.
#
# Guards (why each exists):
#   - private chats only — in a group, an unrelated track shared minutes
#     later must not spend Suno credits;
#   - user-initiated turns only — agent_event / cron turns carry a synthetic
#     prompt, not something to replay;
#   - voice notes never fire it — process_voice_message owns those;
#   - any later GptChat turn by the same user clears the entry, so "бот
#     погода" after the request cancels the pending cover; so does any Suno
#     task being created (clear_for), including later in the same turn;
#   - tools return a plain string (not ToolResult.deferred), so no scratchpad
#     intention is left behind to be re-done by a later turn.
#
# In-memory and per-process: a restart forgets pending requests, which only
# means the user has to ask again.
module PendingAudioRequest
  TTL_SECONDS = 10 * 60

  TOOL_LABELS = {
    'cover_audio'     => 'для кавера',
    'add_vocals'      => 'чтобы подпеть',
    'separate_vocals' => 'чтобы разделить на дорожки',
  }.freeze

  @entries = {}
  @mutex = Mutex.new

  class << self
    # Registers the current request when the turn qualifies and returns the
    # text the tool should hand back to the agent; nil when not eligible.
    def offer(ctx, tool:, now: Time.now)
      return nil unless eligible?(ctx)
      register(chat_id: ctx[:chat_id], uid: ctx[:user].uid, text: ctx[:request_text],
               message_id: ctx[:message_id], tool: tool, now: now)
      "Аудио к запросу не нашлось. Попроси пользователя прислать файл следующим сообщением (подпись не нужна) " \
        "— бот сам выполнит этот же запрос с ним #{TOOL_LABELS.fetch(tool, '')} в течение #{TTL_SECONDS / 60} мин."
    end

    def eligible?(ctx)
      ctx[:private_chat] == true && ctx[:user_initiated] != false &&
        !ctx[:user]&.uid.nil? && !ctx[:request_text].to_s.strip.empty?
    end

    def register(chat_id:, uid:, text:, message_id:, tool:, now: Time.now)
      @mutex.synchronize do
        purge_expired(now)
        @entries[[chat_id, uid]] = { text: text.to_s, message_id: message_id, tool: tool,
                                     expires_at: now + TTL_SECONDS }
      end
    end

    # Removes and returns the live entry, or nil.
    def take(chat_id, uid, now: Time.now)
      @mutex.synchronize do
        entry = @entries.delete([chat_id, uid])
        entry && entry[:expires_at] > now ? entry : nil
      end
    end

    def clear(chat_id, uid)
      @mutex.synchronize { @entries.delete([chat_id, uid]) }
    end

    # Called by every Suno tool right before it creates a task. An agent turn
    # can offer the follow-up and then still create a task (a later tool call
    # in the same turn found a source); a live entry would make the user's next
    # unrelated captionless audio bill a second job.
    def clear_for(ctx)
      uid = ctx[:user]&.uid
      clear(ctx[:chat_id], uid) unless uid.nil?
    end

    def reset!
      @mutex.synchronize { @entries.clear }
    end

    private

    def purge_expired(now)
      @entries.delete_if { |_k, e| e[:expires_at] <= now }
    end
  end
end

require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# attached_audio now returns metadata only (no URL, no getFile call) — the
# Telegram URL is resolved lazily inside Suno tool handlers via TelegramFile.
# We still test via a small harness because Commands::GptChat's full
# constructor pulls the whole bot stack; the harness body must stay
# byte-identical to the real method (track via a single source: see
# `attached_audio_method_source` constant if you ever want to assert
# string-equality between the two).
class AttachedAudioHarness
  attr_accessor :message, :chat_id

  # Mirror of Commands::GptChat::AUDIO_LOOKBACK. Keep in sync (intentional
  # duplication: harness avoids requiring the full GptChat dep tree).
  AUDIO_LOOKBACK = 20

  def initialize(message:, chat_id: nil); @message = message; @chat_id = chat_id; end

  def attached_audio
    audio_metadata_from(message) ||
      (message.reply_to_message && audio_metadata_from(message.reply_to_message)) ||
      recent_chat_audio
  end

  def audio_metadata_from(msg)
    src = msg.audio
    src ||= msg.voice
    src ||= (msg.document if msg.document&.mime_type&.start_with?('audio/'))
    return nil unless src

    {
      file_id:   src.file_id,
      mime_type: src.respond_to?(:mime_type) ? src.mime_type : nil,
      duration:  src.respond_to?(:duration)  ? src.duration  : nil,
      title:     src.respond_to?(:title)     ? src.title     : nil,
      performer: src.respond_to?(:performer) ? src.performer : nil,
    }
  end

  def recent_chat_audio
    return nil unless chat_id
    row = Message.where(chat_id: chat_id, role: 'user',
                        message_thread_id: message.message_thread_id)
                 .order(id: :desc)
                 .limit(AUDIO_LOOKBACK)
                 .find { |m| m.attachment_file_id }
    return nil unless row
    { file_id:   row.attachment_file_id,
      mime_type: row.attachment_mime_type,
      duration:  nil, title: nil, performer: nil }
  end
end

class AttachedAudioTest < Minitest::Test
  AudioStub    = Struct.new(:file_id, :mime_type, :duration, :title, :performer, keyword_init: true)
  VoiceStub    = Struct.new(:file_id, :mime_type, :duration,        keyword_init: true)
  DocumentStub = Struct.new(:file_id, :mime_type,                   keyword_init: true)

  def msg(audio: nil, voice: nil, document: nil, video: nil, video_note: nil, animation: nil, reply_to_message: nil)
    Struct.new(:audio, :voice, :document, :video, :video_note, :animation, :reply_to_message)
      .new(audio, voice, document, video, video_note, animation, reply_to_message)
  end

  def test_audio_attachment_returns_metadata_only
    a = AudioStub.new(file_id: 'AUD123', mime_type: 'audio/mpeg',
                      duration: 137, title: 'Song', performer: 'Artist')
    result = AttachedAudioHarness.new(message: msg(audio: a)).attached_audio
    refute_nil result
    assert_equal 'AUD123', result[:file_id]
    assert_equal 'audio/mpeg', result[:mime_type]
    assert_equal 137, result[:duration]
    assert_equal 'Song', result[:title]
    assert_equal 'Artist', result[:performer]
    refute result.key?(:url), 'attached_audio must NOT pre-resolve URL — that is lazy'
  end

  def test_voice_attachment_works_even_without_title_performer
    v = VoiceStub.new(file_id: 'VOICE1', mime_type: 'audio/ogg', duration: 5)
    result = AttachedAudioHarness.new(message: msg(voice: v)).attached_audio
    refute_nil result
    assert_equal 'VOICE1', result[:file_id]
    assert_equal 'audio/ogg', result[:mime_type]
    assert_nil result[:title]
    assert_nil result[:performer]
  end

  def test_document_with_audio_mime_works
    d = DocumentStub.new(file_id: 'DOC1', mime_type: 'audio/wav')
    result = AttachedAudioHarness.new(message: msg(document: d)).attached_audio
    refute_nil result
    assert_equal 'audio/wav', result[:mime_type]
  end

  def test_document_with_non_audio_mime_returns_nil
    d = DocumentStub.new(file_id: 'DOC1', mime_type: 'application/pdf')
    assert_nil AttachedAudioHarness.new(message: msg(document: d)).attached_audio
  end

  def test_document_with_nil_mime_returns_nil
    d = DocumentStub.new(file_id: 'DOC1', mime_type: nil)
    assert_nil AttachedAudioHarness.new(message: msg(document: d)).attached_audio
  end

  def test_video_video_note_animation_skipped
    [
      msg(video: DocumentStub.new(file_id: 'VID', mime_type: 'video/mp4')),
      msg(video_note: DocumentStub.new(file_id: 'VN', mime_type: 'video/mp4')),
      msg(animation: DocumentStub.new(file_id: 'GIF', mime_type: 'image/gif')),
    ].each do |m|
      assert_nil AttachedAudioHarness.new(message: m).attached_audio,
                 "expected nil for #{m.inspect}"
    end
  end

  def test_no_attachment_returns_nil
    assert_nil AttachedAudioHarness.new(message: msg).attached_audio
  end

  def test_audio_on_reply_target_is_picked_up
    # User replies to a previous audio message with a text prompt — the
    # audio is on reply_to_message, not the current message.
    quoted = msg(audio: AudioStub.new(file_id: 'OLD-AUD', mime_type: 'audio/mpeg',
                                      duration: 200, title: 'Old', performer: 'Band'))
    current = msg(reply_to_message: quoted)
    result = AttachedAudioHarness.new(message: current).attached_audio
    refute_nil result
    assert_equal 'OLD-AUD', result[:file_id]
    assert_equal 'Old', result[:title]
  end

  def test_current_message_audio_takes_precedence_over_reply_target
    a_now = AudioStub.new(file_id: 'NEW', mime_type: 'audio/mpeg', duration: 1, title: 'N', performer: nil)
    quoted = msg(audio: AudioStub.new(file_id: 'OLD', mime_type: 'audio/mpeg', duration: 1, title: 'O', performer: nil))
    current = msg(audio: a_now, reply_to_message: quoted)
    result = AttachedAudioHarness.new(message: current).attached_audio
    assert_equal 'NEW', result[:file_id]
  end

  def test_reply_target_with_no_audio_returns_nil
    quoted = msg # plain text reply target
    current = msg(reply_to_message: quoted)
    assert_nil AttachedAudioHarness.new(message: current).attached_audio
  end
end

# Recent-chat audio lookback: when neither the current message nor its reply
# target carries an attachment, walk back through the last 20 messages in
# this chat for a stored attachment_file_id (saved by
# MessageResponder#save_message). Lets users say "сделай кавер" in a fresh
# message after an earlier audio upload, without relying on Telegram-reply.
class RecentChatAudioLookbackTest < BotTest
  CHAT = -77

  def msg(**attrs)
    defaults = { audio: nil, voice: nil, document: nil, video: nil,
                 video_note: nil, animation: nil, reply_to_message: nil,
                 message_thread_id: nil }
    Struct.new(*defaults.keys).new(*defaults.merge(attrs).values_at(*defaults.keys))
  end

  def make_msg_row(**attrs)
    Message.create!({ role: 'user', chat_id: CHAT, body: '[аудио]' }.merge(attrs))
  end

  def test_lookback_picks_most_recent_attachment_in_chat
    make_msg_row(message_id: 1, attachment_file_id: 'OLD_AUD',  attachment_mime_type: 'audio/mpeg')
    make_msg_row(message_id: 2, attachment_file_id: 'NEW_AUD',  attachment_mime_type: 'audio/wav')
    make_msg_row(message_id: 3, body: 'plain text')  # no attachment, but most recent overall
    result = AttachedAudioHarness.new(message: msg, chat_id: CHAT).attached_audio
    refute_nil result
    assert_equal 'NEW_AUD', result[:file_id], 'must return the most recent attachment, not the absolute most recent message'
    assert_equal 'audio/wav', result[:mime_type]
  end

  def test_lookback_returns_nil_when_no_recent_attachments
    20.times { |i| make_msg_row(message_id: i + 1, body: 'just text') }
    assert_nil AttachedAudioHarness.new(message: msg, chat_id: CHAT).attached_audio
  end

  def test_lookback_skips_attachments_in_other_chats
    Message.create!(role: 'user', chat_id: -999, body: '[аудио]', message_id: 1, attachment_file_id: 'OTHER')
    assert_nil AttachedAudioHarness.new(message: msg, chat_id: CHAT).attached_audio
  end

  def test_lookback_capped_at_20_messages
    # Create 25 plain-text messages followed by 1 message with attachment
    # that's older than the 20-row window — must NOT be returned.
    make_msg_row(message_id: 1, attachment_file_id: 'STALE', attachment_mime_type: 'audio/mpeg')
    25.times { |i| make_msg_row(message_id: i + 2, body: 'noise') }
    assert_nil AttachedAudioHarness.new(message: msg, chat_id: CHAT).attached_audio,
               'attachment beyond the 20-row lookback window must be ignored'
  end

  def test_lookback_skipped_when_current_message_has_audio
    make_msg_row(message_id: 1, attachment_file_id: 'OLD_AUD', attachment_mime_type: 'audio/mpeg')
    a_now = AttachedAudioTest::AudioStub.new(file_id: 'CURRENT', mime_type: 'audio/mpeg',
                                              duration: 5, title: 'Now', performer: nil)
    result = AttachedAudioHarness.new(message: msg(audio: a_now), chat_id: CHAT).attached_audio
    assert_equal 'CURRENT', result[:file_id], 'current-message audio takes precedence over lookback'
  end

  def test_lookback_skipped_when_reply_target_has_audio
    make_msg_row(message_id: 1, attachment_file_id: 'OLD_AUD', attachment_mime_type: 'audio/mpeg')
    quoted_audio = AttachedAudioTest::AudioStub.new(file_id: 'QUOTED', mime_type: 'audio/mpeg',
                                                     duration: 5, title: 'Q', performer: nil)
    quoted = msg(audio: quoted_audio)
    current = msg(reply_to_message: quoted)
    result = AttachedAudioHarness.new(message: current, chat_id: CHAT).attached_audio
    assert_equal 'QUOTED', result[:file_id], 'reply-target audio takes precedence over lookback'
  end

  # Forum-topic isolation: a "сделай кавер" asked in topic A must not
  # match an audio uploaded in topic B (or in the General/no-thread space).
  # Mirrors how get_chat_context already scopes the agent's context.
  def test_lookback_filters_by_message_thread_id
    make_msg_row(message_id: 1, attachment_file_id: 'TOPIC_B', attachment_mime_type: 'audio/mpeg',
                 message_thread_id: 999)
    # Asking in topic 100 — should NOT match the topic-999 audio.
    result = AttachedAudioHarness.new(message: msg(message_thread_id: 100), chat_id: CHAT).attached_audio
    assert_nil result, 'audio from a different topic must not be matched'
  end

  def test_lookback_finds_audio_in_same_thread
    make_msg_row(message_id: 1, attachment_file_id: 'TOPIC_100', attachment_mime_type: 'audio/mpeg',
                 message_thread_id: 100)
    result = AttachedAudioHarness.new(message: msg(message_thread_id: 100), chat_id: CHAT).attached_audio
    refute_nil result
    assert_equal 'TOPIC_100', result[:file_id]
  end

  # Latent-safety: the column is currently only written by save_message for
  # user messages, but harden the lookback so a future change persisting
  # bot media with attachment_file_id doesn't accidentally feed bot audio
  # back into Suno cover_audio (which expects a USER-supplied source).
  def test_lookback_skips_bot_role_attachments
    make_msg_row(message_id: 1, role: 'bot', attachment_file_id: 'BOT_AUD', attachment_mime_type: 'audio/mpeg')
    assert_nil AttachedAudioHarness.new(message: msg, chat_id: CHAT).attached_audio,
               'bot-role attachments must not be returned as a user upload source'
  end
end

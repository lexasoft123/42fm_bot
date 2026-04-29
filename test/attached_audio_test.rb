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
  attr_accessor :message

  def initialize(message:); @message = message; end

  def attached_audio
    audio_metadata_from(message) ||
      (message.reply_to_message && audio_metadata_from(message.reply_to_message))
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

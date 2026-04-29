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
    src = message.audio
    src ||= message.voice
    src ||= (message.document if message.document&.mime_type&.start_with?('audio/'))
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

  def msg(audio: nil, voice: nil, document: nil, video: nil, video_note: nil, animation: nil)
    Struct.new(:audio, :voice, :document, :video, :video_note, :animation)
      .new(audio, voice, document, video, video_note, animation)
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
end

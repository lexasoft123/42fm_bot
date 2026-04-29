require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Stubs for global Settings used by GptChat#attached_audio
unless Settings.respond_to?(:telegram)
  Settings.singleton_class.send(:define_method, :telegram) {
    { 'token' => '12345:ABCDEF' }
  }
end

# We test attached_audio in isolation by extracting the method into a tiny
# class — a full Commands::GptChat instance pulls in the whole bot stack.
# This mirrors the real implementation but skips the unrelated dependencies.
class AttachedAudioHarness
  attr_accessor :message, :bot

  def initialize(message:, bot:)
    @message = message
    @bot = bot
    @chat_id = message.respond_to?(:chat_id) ? message.chat_id : -1
  end

  # Identical body to lib/commands/gpt_chat.rb#attached_audio.
  def attached_audio
    src = message.audio
    src ||= message.voice
    src ||= (message.document if message.document&.mime_type&.start_with?('audio/'))
    return nil unless src

    file = bot.api.getFile(file_id: src.file_id)
    file_path = file.respond_to?(:file_path) ? file.file_path : file.dig('result', 'file_path')
    return nil unless file_path

    token = Settings.telegram['token']
    {
      url:        "https://api.telegram.org/file/bot#{token}/#{file_path}",
      mime_type:  src.respond_to?(:mime_type) ? src.mime_type : nil,
      duration:   src.respond_to?(:duration)  ? src.duration  : nil,
      title:      src.respond_to?(:title)     ? src.title     : nil,
      performer:  src.respond_to?(:performer) ? src.performer : nil,
    }
  rescue
    nil
  end
end

class AttachedAudioTest < Minitest::Test
  AudioStub    = Struct.new(:file_id, :mime_type, :duration, :title, :performer, keyword_init: true)
  VoiceStub    = Struct.new(:file_id, :mime_type, :duration,        keyword_init: true)
  DocumentStub = Struct.new(:file_id, :mime_type,                   keyword_init: true)
  FileStub     = Struct.new(:file_path)

  class FakeBot
    def initialize; @api = FakeApi.new; end
    attr_reader :api
  end

  class FakeApi
    def getFile(file_id:); FileStub.new("path/to/#{file_id}.dat"); end
  end

  def msg(audio: nil, voice: nil, document: nil, video: nil, video_note: nil, animation: nil)
    Struct.new(:audio, :voice, :document, :video, :video_note, :animation, :chat_id)
      .new(audio, voice, document, video, video_note, animation, -1)
  end

  def test_audio_attachment_returns_url_with_metadata
    a = AudioStub.new(file_id: 'AUD123', mime_type: 'audio/mpeg',
                      duration: 137, title: 'Song', performer: 'Artist')
    result = AttachedAudioHarness.new(message: msg(audio: a), bot: FakeBot.new).attached_audio
    refute_nil result
    assert_match %r{api\.telegram\.org/file/bot12345:ABCDEF/path/to/AUD123\.dat}, result[:url]
    assert_equal 'audio/mpeg', result[:mime_type]
    assert_equal 137, result[:duration]
    assert_equal 'Song', result[:title]
    assert_equal 'Artist', result[:performer]
  end

  def test_voice_attachment_works_even_without_title_performer
    v = VoiceStub.new(file_id: 'VOICE1', mime_type: 'audio/ogg', duration: 5)
    result = AttachedAudioHarness.new(message: msg(voice: v), bot: FakeBot.new).attached_audio
    refute_nil result
    assert_equal 'audio/ogg', result[:mime_type]
    assert_nil result[:title]
    assert_nil result[:performer]
  end

  def test_document_with_audio_mime_works
    d = DocumentStub.new(file_id: 'DOC1', mime_type: 'audio/wav')
    result = AttachedAudioHarness.new(message: msg(document: d), bot: FakeBot.new).attached_audio
    refute_nil result
    assert_equal 'audio/wav', result[:mime_type]
  end

  def test_document_with_non_audio_mime_returns_nil
    d = DocumentStub.new(file_id: 'DOC1', mime_type: 'application/pdf')
    assert_nil AttachedAudioHarness.new(message: msg(document: d), bot: FakeBot.new).attached_audio
  end

  def test_document_with_nil_mime_returns_nil
    d = DocumentStub.new(file_id: 'DOC1', mime_type: nil)
    assert_nil AttachedAudioHarness.new(message: msg(document: d), bot: FakeBot.new).attached_audio
  end

  def test_video_video_note_animation_skipped
    [
      msg(video: DocumentStub.new(file_id: 'VID', mime_type: 'video/mp4')),
      msg(video_note: DocumentStub.new(file_id: 'VN', mime_type: 'video/mp4')),
      msg(animation: DocumentStub.new(file_id: 'GIF', mime_type: 'image/gif')),
    ].each do |m|
      assert_nil AttachedAudioHarness.new(message: m, bot: FakeBot.new).attached_audio,
                 "expected nil for #{m.inspect}"
    end
  end

  def test_no_attachment_returns_nil
    assert_nil AttachedAudioHarness.new(message: msg, bot: FakeBot.new).attached_audio
  end
end

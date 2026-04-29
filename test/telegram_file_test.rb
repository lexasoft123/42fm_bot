require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:telegram)
  Settings.singleton_class.send(:define_method, :telegram) {
    { 'token' => '12345:ABCDEF' }
  }
end

require_relative '../lib/telegram_file'

class TelegramFileTest < Minitest::Test
  FileObj = Struct.new(:file_path)

  class FakeApi
    def initialize(behavior); @behavior = behavior; end
    def getFile(file_id:); @behavior.call(file_id); end
  end

  def test_public_url_resolves_via_getFile_object_response
    api = FakeApi.new(->(fid) { FileObj.new("voice/#{fid}.ogg") })
    url = TelegramFile.public_url(api, 'VOICE1')
    assert_equal 'https://api.telegram.org/file/bot12345:ABCDEF/voice/VOICE1.ogg', url
  end

  def test_public_url_resolves_via_getFile_hash_response
    api = FakeApi.new(->(fid) { { 'result' => { 'file_path' => "audio/#{fid}.mp3" } } })
    url = TelegramFile.public_url(api, 'AUD42')
    assert_equal 'https://api.telegram.org/file/bot12345:ABCDEF/audio/AUD42.mp3', url
  end

  def test_public_url_returns_nil_when_file_path_missing
    api = FakeApi.new(->(_) { FileObj.new(nil) })
    assert_nil TelegramFile.public_url(api, 'X')
  end

  def test_public_url_returns_nil_on_exception
    api = FakeApi.new(->(_) { raise 'telegram down' })
    assert_nil TelegramFile.public_url(api, 'X')
  end
end

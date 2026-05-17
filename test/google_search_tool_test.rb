require_relative 'test_helper'
require 'ostruct'
require 'tempfile'
require 'faraday'
require 'faraday/multipart'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:google)
  Settings.singleton_class.send(:define_method, :google) {
    [{ 'api_key' => 'k1', 'cx_key' => 'c1' }]
  }
end

require_relative '../lib/agent/tool_registry'
require_relative '../lib/gogolmogol'
require_relative '../lib/agent/tools/google_search'

class GoogleSearchToolTest < BotTest
  CHAT = -1234567893

  class FakeApi
    attr_reader :send_media_group, :send_animation
    def initialize(raise_on_send: nil)
      @send_media_group = []
      @send_animation   = []
      @raise_on_send    = raise_on_send
    end
    def sendMediaGroup(**kw)
      raise @raise_on_send if @raise_on_send
      @send_media_group << kw
      { 'ok' => true }
    end
    def sendAnimation(**kw)
      raise @raise_on_send if @raise_on_send
      @send_animation << kw
      { 'ok' => true }
    end
  end

  class FakeBot
    attr_reader :api
    def initialize(api); @api = api; end
  end

  def setup
    super
    @tool = Agent::ToolRegistry.find('google_search')
    @api  = FakeApi.new
    @bot  = FakeBot.new(@api)
  end

  def make_ctx
    { chat_id: CHAT, bot: @bot }
  end

  def make_tmp(content: 'X', suffix: '.jpg')
    t = Tempfile.new(['gs_test_', suffix]); t.binmode; t.write(content); t.flush; t
  end

  # Replace Gogolmogol with a one-shot fake that records construction args and
  # returns canned results. Restores the real class afterwards.
  def stub_gogolmogol(search: nil, download: nil)
    constructed = []
    fake_class = Class.new do
      define_singleton_method(:new) do |q, **kw|
        constructed << { query: q, **kw }
        instance = Object.new
        instance.define_singleton_method(:search_results)   { |limit: 3| (search.is_a?(Proc)   ? search.call(limit)   : search) || [] }
        instance.define_singleton_method(:download_results) { |limit: 4| (download.is_a?(Proc) ? download.call(limit) : download) || [] }
        instance
      end
    end
    original = Object.send(:remove_const, :Gogolmogol)
    Object.const_set(:Gogolmogol, fake_class)
    yield constructed
  ensure
    Object.send(:remove_const, :Gogolmogol)
    Object.const_set(:Gogolmogol, original)
  end

  def test_text_media_type_returns_formatted_text_no_telegram_call
    results = [
      { title: 'First',  link: 'http://example.com/1', snippet: 'snippet one' },
      { title: 'Second', link: 'http://example.com/2', snippet: '' }
    ]
    out = stub_gogolmogol(search: results) do |constructed|
      @tool.handler.call({ 'query' => 'news', 'media_type' => 'text' }, make_ctx)
    end
    assert_match(/1\. First/,  out)
    assert_match(/snippet one/, out)
    assert_match(/2\. Second/, out)
    assert_match(%r{http://example\.com/1}, out)
    assert_empty @api.send_media_group, 'text path must not call sendMediaGroup'
    assert_empty @api.send_animation,   'text path must not call sendAnimation'
  end

  def test_photo_media_type_calls_download_results_and_sends_media_group
    downloads = 3.times.map { |i| { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/#{i}.jpg" } }
    out = stub_gogolmogol(download: downloads) do |constructed|
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end
    assert_equal 'Отправил 3 картинок в чат', out
    assert_equal 1, @api.send_media_group.size, 'photo path must call sendMediaGroup exactly once'
    assert_empty @api.send_animation
    media_json = JSON.parse(@api.send_media_group.first[:media])
    assert_equal 3, media_json.size
    media_json.each { |m| assert_equal 'photo', m['type'] }
  end

  def test_gif_media_type_sends_each_as_separate_animation
    downloads = 2.times.map { |i| { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif', link: "http://example.com/#{i}.gif" } }
    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx)
    end
    assert_equal 'Отправил 2 гифок в чат', out
    assert_empty @api.send_media_group
    assert_equal 2, @api.send_animation.size
  end

  def test_empty_downloads_returns_not_downloaded_message_no_telegram_call
    out = stub_gogolmogol(download: []) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end
    assert_equal 'Не удалось скачать ни одной картинки', out
    assert_empty @api.send_media_group
    assert_empty @api.send_animation
  end

  def test_send_failure_falls_back_to_link_list
    @api = FakeApi.new(raise_on_send: RuntimeError.new('Bad Request: IMAGE_PROCESS_FAILED'))
    @bot = FakeBot.new(@api)
    downloads = [{ tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/a.jpg' },
                 { tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/b.jpg' }]
    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end
    assert_match(%r{http://example\.com/a\.jpg}, out)
    assert_match(%r{http://example\.com/b\.jpg}, out)
  end

  def test_empty_search_results_for_text_returns_not_found
    out = stub_gogolmogol(search: []) do
      @tool.handler.call({ 'query' => 'nothing-found', 'media_type' => 'text' }, make_ctx)
    end
    assert_equal 'Ничего не найдено', out
    assert_empty @api.send_media_group
    assert_empty @api.send_animation
  end

  def test_unknown_media_type_returns_error_message
    out = stub_gogolmogol do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'image' }, make_ctx)
    end
    assert_match(/Ошибка/, out)
    assert_match(/media_type="image"/, out)
    assert_match(/text\|photo\|gif/, out)
    assert_empty @api.send_media_group
    assert_empty @api.send_animation
  end
end

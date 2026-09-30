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
      count = JSON.parse(kw[:media]).size
      Array.new(count) do |i|
        OpenStruct.new(message_id: 100 + i, message_thread_id: kw[:message_thread_id],
                       photo: [OpenStruct.new(file_id: "photo-#{i}", width: 800)])
      end
    end
    def sendAnimation(**kw)
      raise @raise_on_send if @raise_on_send
      @send_animation << kw
      OpenStruct.new(message_id: 200 + @send_animation.size,
                     message_thread_id: kw[:message_thread_id])
    end
  end

  def setup
    super
    @tool = Agent::ToolRegistry.find('google_search')
    @api  = FakeApi.new
  end

  def make_ctx(forum_thread_id: nil)
    { chat_id: CHAT, api: @api, forum_thread_id: forum_thread_id }
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
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx(forum_thread_id: 77))
    end
    assert_match(/status=sent/, out)
    assert_match(/sent_count=3/, out)
    assert_match(/accepted_count=3/, out)
    assert_match(/persisted_count=3/, out)
    assert_equal 1, @api.send_media_group.size, 'photo path must call sendMediaGroup exactly once'
    assert_empty @api.send_animation
    assert_equal 77, @api.send_media_group.first[:message_thread_id]
    media_json = JSON.parse(@api.send_media_group.first[:media])
    assert_equal 3, media_json.size
    media_json.each { |m| assert_equal 'photo', m['type'] }

    rows = Message.where(chat_id: CHAT, role: 'bot').order(:message_id).to_a
    assert_equal 3, rows.size
    assert_equal [77, 77, 77], rows.map(&:message_thread_id)
    assert_equal %w[photo-0 photo-1 photo-2], rows.map(&:attachment_photo_file_id)
  end

  def test_gif_media_type_sends_each_as_separate_animation
    downloads = 2.times.map { |i| { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif', link: "http://example.com/#{i}.gif" } }
    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx(forum_thread_id: 88))
    end
    assert_match(/status=sent/, out)
    assert_match(/sent_count=2/, out)
    assert_match(/persisted_count=2/, out)
    assert_match(/rejected_count=0/, out)
    assert_match(/ambiguous_count=0/, out)
    assert_empty @api.send_media_group
    assert_equal 2, @api.send_animation.size
    assert @api.send_animation.all? { |params| params[:message_thread_id] == 88 }
    rows = Message.where(chat_id: CHAT, role: 'bot').order(:message_id).to_a
    assert_equal 2, rows.size
    assert_equal [88, 88], rows.map(&:message_thread_id)
  end

  def test_empty_downloads_returns_not_downloaded_message_no_telegram_call
    out = stub_gogolmogol(download: []) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end
    assert_match(/status=failed/, out)
    assert_match(/Медиа НЕ ОТПРАВЛЕНО/, out)
    assert_empty @api.send_media_group
    assert_empty @api.send_animation
  end

  def test_definite_image_process_rejection_falls_back_to_link_list
    @api = FakeApi.new(raise_on_send: RuntimeError.new('Bad Request: IMAGE_PROCESS_FAILED'))
    downloads = [{ tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/a.jpg' },
                 { tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/b.jpg' }]
    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end
    assert_match(/status=failed/, out)
    assert_match(/sent_count=0/, out)
    assert_match(/persisted_count=0/, out)
    assert_match(/Медиа НЕ ОТПРАВЛЕНО/, out)
    assert_match(/IMAGE_PROCESS_FAILED/, out)
    assert_match(/Резервные URL \(это ссылки на медиа, которые НЕ были отправлены в чат\)/, out)
    assert_match(%r{http://example\.com/a\.jpg}, out)
    assert_match(%r{http://example\.com/b\.jpg}, out)
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_ambiguous_media_group_transport_failures_expose_no_retryable_urls
    errors = [
      Faraday::TimeoutError.new('request timed out'),
      Net::ReadTimeout.new('read timed out'),
      EOFError.new('end of file reached'),
      Errno::ECONNRESET.new
    ]

    errors.each_with_index do |error, index|
      @api = FakeApi.new(raise_on_send: error)
      downloads = 2.times.map do |item|
        { tmp: make_tmp, mime: 'image/jpeg',
          link: "http://example.com/ambiguous-#{index}-#{item}.jpg" }
      end

      out = stub_gogolmogol(download: downloads) do
        @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
      end

      assert_match(/status=sent_untracked/, out)
      assert_match(/accepted_count=0/, out)
      assert_match(/доставка неизвестна/, out)
      assert_match(/не отправляй.*повторно/i, out)
      refute_match(/Резервные URL/, out)
      downloads.each { |download| refute_includes out, download[:link] }
      assert_empty Message.where(chat_id: CHAT, role: 'bot')
    end
  end

  def test_gif_partial_delivery_reports_and_persists_only_successes
    attempts = 0
    @api.define_singleton_method(:sendAnimation) do |**kw|
      @send_animation << kw
      attempts += 1
      raise RuntimeError, 'Bad Request: IMAGE_PROCESS_FAILED' if attempts == 2
      OpenStruct.new(message_id: 300 + attempts, message_thread_id: kw[:message_thread_id])
    end
    downloads = 3.times.map do |i|
      { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif', link: "http://example.com/#{i}.gif" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx(forum_thread_id: 99))
    end

    assert_match(/status=partial/, out)
    assert_match(/sent_count=2/, out)
    assert_match(/accepted_count=2/, out)
    assert_match(/persisted_count=2/, out)
    assert_match(/rejected_count=1/, out)
    assert_match(/ambiguous_count=0/, out)
    assert_match(/requested_count=3/, out)
    assert_match(/IMAGE_PROCESS_FAILED/, out)
    assert_match(%r{http://example\.com/1\.gif}, out)
    refute_match(%r{http://example\.com/0\.gif}, out)
    refute_match(%r{http://example\.com/2\.gif}, out)
    assert_equal 3, @api.send_animation.size
    rows = Message.where(chat_id: CHAT, role: 'bot').order(:message_id).to_a
    assert_equal [301, 303], rows.map(&:message_id)
    assert_equal [99, 99], rows.map(&:message_thread_id)
  end

  def test_photo_persistence_failure_reports_sent_untracked_without_resending
    persist_calls = 0
    downloads = 2.times.map do |i|
      { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/#{i}.jpg" }
    end

    out = Message.stub(:persist_bot_reply, ->(**) { persist_calls += 1; nil }) do
      stub_gogolmogol(download: downloads) do
        @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx(forum_thread_id: 44))
      end
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=2/, out)
    assert_match(/persisted_count=0/, out)
    assert_match(/не отправляй их повторно/, out)
    refute_match(/Резервные URL/, out, 'accepted media must not be offered as unsent fallback links')
    assert_equal 1, @api.send_media_group.size, 'persistence reconciliation must not resend Telegram media'
    assert_equal 4, persist_calls, 'each accepted response gets one bounded persistence retry'
  end

  def test_gif_persistence_failure_reports_sent_untracked_without_resending
    persist_calls = 0
    downloads = [{ tmp: make_tmp(suffix: '.gif'), mime: 'image/gif',
                   link: 'http://example.com/a.gif' }]

    out = Message.stub(:persist_bot_reply, ->(**) { persist_calls += 1; nil }) do
      stub_gogolmogol(download: downloads) do
        @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx)
      end
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=1/, out)
    assert_match(/persisted_count=0/, out)
    assert_equal 1, @api.send_animation.size
    assert_equal 2, persist_calls
  end

  def test_sparse_photo_group_response_is_ambiguous_and_exposes_no_retryable_urls
    @api.define_singleton_method(:sendMediaGroup) do |**kw|
      @send_media_group << kw
      [OpenStruct.new(message_id: 401, message_thread_id: kw[:message_thread_id]),
       { 'ok' => false },
       OpenStruct.new(message_id: 403, message_thread_id: kw[:message_thread_id])]
    end
    downloads = 3.times.map do |i|
      { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/#{i}.jpg" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx(forum_thread_id: 55))
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=0/, out)
    assert_match(/persisted_count=0/, out)
    assert_match(/неоднозначно/, out)
    downloads.each { |download| refute_includes out, download[:link] }
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_photo_persistence_uses_originating_topic_when_response_omits_thread
    @api.define_singleton_method(:sendMediaGroup) do |**kw|
      @send_media_group << kw
      [OpenStruct.new(message_id: 451, message_thread_id: nil,
                      photo: [OpenStruct.new(file_id: 'topic-photo', width: 800)])]
    end
    downloads = [{ tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/topic.jpg' }]

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx(forum_thread_id: 73))
    end

    assert_match(/status=sent/, out)
    row = Message.find_by(chat_id: CHAT, message_id: 451)
    refute_nil row
    assert_equal 73, row.message_thread_id
  end

  def test_photo_group_malformed_ack_is_ambiguous_as_a_whole
    @api.define_singleton_method(:sendMediaGroup) do |**kw|
      @send_media_group << kw
      [OpenStruct.new(message_id: 0, message_thread_id: kw[:message_thread_id]),
       { 'message_id' => '402' },
       { 'ok' => true },
       { 'message_id' => 404, 'message_thread_id' => kw[:message_thread_id] }]
    end
    downloads = 4.times.map do |i|
      { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/#{i}.jpg" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx(forum_thread_id: 56))
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=0/, out)
    assert_match(/persisted_count=0/, out)
    refute_match(/Резервные URL/, out)
    downloads.each { |download| refute_includes out, download[:link] }
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_photo_group_short_ack_is_ambiguous_and_not_partially_persisted
    @api.define_singleton_method(:sendMediaGroup) do |**kw|
      @send_media_group << kw
      [OpenStruct.new(message_id: 601, message_thread_id: kw[:message_thread_id])]
    end
    downloads = 2.times.map do |i|
      { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/short-#{i}.jpg" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=0/, out)
    downloads.each { |download| refute_includes out, download[:link] }
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_photo_group_duplicate_message_ids_are_ambiguous
    @api.define_singleton_method(:sendMediaGroup) do |**kw|
      @send_media_group << kw
      [OpenStruct.new(message_id: 701, message_thread_id: kw[:message_thread_id]),
       OpenStruct.new(message_id: 701, message_thread_id: kw[:message_thread_id])]
    end
    downloads = 2.times.map do |i|
      { tmp: make_tmp, mime: 'image/jpeg', link: "http://example.com/duplicate-#{i}.jpg" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=0/, out)
    downloads.each { |download| refute_includes out, download[:link] }
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_gif_malformed_acknowledgements_are_ambiguous_not_rejected
    responses = [
      OpenStruct.new(message_id: 0, message_thread_id: nil),
      { 'message_id' => '502' },
      { 'ok' => true },
      { 'result' => { 'message_id' => 504 } }
    ]
    @api.define_singleton_method(:sendAnimation) do |**kw|
      @send_animation << kw
      responses.shift
    end
    downloads = 4.times.map do |i|
      { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif', link: "http://example.com/#{i}.gif" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx(forum_thread_id: 57))
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=1/, out)
    assert_match(/persisted_count=1/, out)
    assert_match(/rejected_count=0/, out)
    assert_match(/ambiguous_count=3/, out)
    downloads.each { |download| refute_includes out, download[:link] }
    assert_equal 4, @api.send_animation.size
    row = Message.find_by(chat_id: CHAT, message_id: 504)
    refute_nil row
    assert_equal 57, row.message_thread_id
  end

  def test_gif_transport_failures_are_ambiguous_and_expose_no_urls
    errors = [
      Faraday::TimeoutError.new('request timed out'),
      Net::ReadTimeout.new('read timed out'),
      EOFError.new('end of file reached'),
      Errno::ECONNRESET.new
    ]

    errors.each_with_index do |error, index|
      @api = FakeApi.new(raise_on_send: error)
      download = { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif',
                   link: "http://example.com/ambiguous-#{index}.gif" }

      out = stub_gogolmogol(download: [download]) do
        @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx)
      end

      assert_match(/status=sent_untracked/, out)
      assert_match(/accepted_count=0/, out)
      assert_match(/rejected_count=0/, out)
      assert_match(/ambiguous_count=1/, out)
      refute_includes out, download[:link]
      assert_empty Message.where(chat_id: CHAT, role: 'bot')
    end
  end

  def test_gif_definite_rejection_exposes_only_rejected_url
    @api = FakeApi.new(raise_on_send: RuntimeError.new('Bad Request: IMAGE_PROCESS_FAILED'))
    download = { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif',
                 link: 'http://example.com/rejected.gif' }

    out = stub_gogolmogol(download: [download]) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx)
    end

    assert_match(/status=failed/, out)
    assert_match(/rejected_count=1/, out)
    assert_match(/ambiguous_count=0/, out)
    assert_includes out, download[:link]
    assert_empty Message.where(chat_id: CHAT, role: 'bot')
  end

  def test_gif_mixed_batch_keeps_confirmed_rejected_and_ambiguous_counts_separate
    outcomes = [
      OpenStruct.new(message_id: 801, message_thread_id: nil),
      RuntimeError.new('Bad Request: IMAGE_PROCESS_FAILED'),
      EOFError.new('end of file reached')
    ]
    @api.define_singleton_method(:sendAnimation) do |**kw|
      @send_animation << kw
      outcome = outcomes.shift
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
    downloads = 3.times.map do |i|
      { tmp: make_tmp(suffix: '.gif'), mime: 'image/gif', link: "http://example.com/mixed-#{i}.gif" }
    end

    out = stub_gogolmogol(download: downloads) do
      @tool.handler.call({ 'query' => 'dance', 'media_type' => 'gif' }, make_ctx)
    end

    assert_match(/status=sent_untracked/, out)
    assert_match(/accepted_count=1/, out)
    assert_match(/persisted_count=1/, out)
    assert_match(/rejected_count=1/, out)
    assert_match(/ambiguous_count=1/, out)
    refute_includes out, downloads[0][:link]
    assert_includes out, downloads[1][:link]
    refute_includes out, downloads[2][:link]
    assert Message.exists?(chat_id: CHAT, role: 'bot', message_id: 801)
  end

  def test_message_id_validation_accepts_positive_integer_for_all_response_shapes
    tool = Agent::Tools::GoogleSearch

    assert_equal 1, tool.telegram_message_id(OpenStruct.new(message_id: 1))
    assert_equal 2, tool.telegram_message_id({ 'message_id' => 2 })
    assert_equal 3, tool.telegram_message_id({ 'result' => { 'message_id' => 3 } })
    [nil, 0, -1, '4', 4.0, false].each do |value|
      assert_nil tool.telegram_message_id({ 'message_id' => value }), "must reject #{value.inspect}"
    end
  end

  def test_telegram_exception_url_is_sanitized_in_result_and_log
    token = '123456789:AAExampleTelegramBotTokenSecret'
    error = RuntimeError.new("POST https://api.telegram.org/bot#{token}/sendPhoto failed")
    @api = FakeApi.new(raise_on_send: error)
    downloads = [{ tmp: make_tmp, mime: 'image/jpeg', link: 'http://example.com/a.jpg' }]
    logged = nil

    out = LOGGER.stub(:public_send, ->(_level, message) { logged = message }) do
      stub_gogolmogol(download: downloads) do
        @tool.handler.call({ 'query' => 'cat', 'media_type' => 'photo' }, make_ctx)
      end
    end

    assert_match(/status=sent_untracked/, out)
    assert_includes out, '[url]'
    refute_includes out, token
    refute_includes out, 'http://example.com/a.jpg'
    refute_nil logged
    assert_includes logged, '[url]'
    refute_includes logged, token
  end

  def test_tempfile_cleanup_attempts_unlink_even_when_close_raises
    calls = []
    tmp = Object.new
    tmp.define_singleton_method(:close) { calls << :close; raise 'close failed' }
    tmp.define_singleton_method(:unlink) { calls << :unlink; raise 'unlink failed' }

    Agent::Tools::GoogleSearch.cleanup_downloads([{ tmp: tmp }])

    assert_equal %i[close unlink], calls
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

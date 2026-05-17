require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:google)
  Settings.singleton_class.send(:define_method, :google) {
    [{ 'api_key' => 'k1', 'cx_key' => 'c1' }]
  }
end

require_relative '../lib/gogolmogol'

class GogolmogolTest < BotTest
  # Capture opts that get_search forwards into the gem.
  def with_captured_opts
    captured = nil
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :__search, :search)
    GoogleCustomSearchApi.singleton_class.send(:define_method, :search) { |q, o|
      captured = { query: q, opts: o }
      OpenStruct.new('error' => nil, 'items' => [], :items => [])
    }
    yield
    captured
  ensure
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :search, :__search)
    GoogleCustomSearchApi.singleton_class.send(:remove_method, :__search)
  end

  def test_media_type_photo_sets_searchType_image_no_fileType
    captured = with_captured_opts do
      Gogolmogol.new('cat', media_type: 'photo').search_results(limit: 1)
    end
    assert_equal 'image', captured[:opts]['searchType']
    assert_equal 'large', captured[:opts]['imgSize']
    assert_nil captured[:opts]['fileType']
  end

  def test_media_type_gif_sets_fileType_gif_and_no_query_rewrite
    captured = with_captured_opts do
      Gogolmogol.new('найди гиф котика', media_type: 'gif').search_results(limit: 1)
    end
    assert_equal 'image', captured[:opts]['searchType']
    assert_equal 'gif',   captured[:opts]['fileType']
    assert_equal 'large', captured[:opts]['imgSize']
    assert_equal 'найди гиф котика', captured[:query],
                 'query must reach gem verbatim — the гиф→gif animated gsub was removed'
  end

  def test_media_type_text_sets_no_image_opts
    captured = with_captured_opts do
      Gogolmogol.new('news today', media_type: 'text').search_results(limit: 1)
    end
    refute captured[:opts].key?('searchType'), 'text search must not set searchType'
    refute captured[:opts].key?('fileType'),   'text search must not set fileType'
    refute captured[:opts].key?('imgSize'),    'text search must not set imgSize'
  end

  def test_safe_search_is_disabled_for_all_media_types
    %w[text photo gif].each do |mt|
      captured = with_captured_opts do
        Gogolmogol.new('q', media_type: mt).search_results(limit: 1)
      end
      assert_equal 'off', captured[:opts]['safe'], "safe=off must be set for media_type=#{mt}"
    end
  end

  def test_download_results_returns_tempfiles_for_successful_links
    items = [
      OpenStruct.new(title: 'a', link: 'http://example.com/a.jpg', snippet: ''),
      OpenStruct.new(title: 'b', link: 'http://example.com/b.jpg', snippet: ''),
      OpenStruct.new(title: 'c', link: 'http://example.com/c.jpg', snippet: '')
    ]
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :__search, :search)
    GoogleCustomSearchApi.singleton_class.send(:define_method, :search) { |_q, _o|
      OpenStruct.new('error' => nil, 'items' => items, :items => items)
    }
    RestClient::Request.singleton_class.send(:alias_method, :__execute, :execute)
    RestClient::Request.singleton_class.send(:define_method, :execute) { |_opts|
      OpenStruct.new(headers: { content_type: 'image/jpeg' }, body: 'FAKE_JPEG_BYTES')
    }

    results = Gogolmogol.new('cat', media_type: 'photo').download_results(limit: 3)

    assert_equal 3, results.size
    results.each do |r|
      assert_kind_of Tempfile, r[:tmp]
      assert_equal 'image/jpeg', r[:mime]
      assert_match %r{example\.com/[abc]\.jpg}, r[:link]
      assert File.exist?(r[:tmp].path)
      r[:tmp].close; r[:tmp].unlink
    end
  ensure
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :search, :__search)
    GoogleCustomSearchApi.singleton_class.send(:remove_method, :__search)
    RestClient::Request.singleton_class.send(:alias_method, :execute, :__execute)
    RestClient::Request.singleton_class.send(:remove_method, :__execute)
  end

  # Pre-fetch SSRF guard: blocked URLs are dropped before RestClient ever fires.
  # Recorded fetches must be empty for every blocked scheme/host.
  def test_download_results_blocks_unsafe_schemes_and_private_hosts
    items = [
      OpenStruct.new(title: 'ok',          link: 'https://example.com/ok.jpg',                snippet: ''),
      OpenStruct.new(title: 'file',        link: 'file:///etc/passwd',                        snippet: ''),
      OpenStruct.new(title: 'localhost',   link: 'http://localhost/admin',                    snippet: ''),
      OpenStruct.new(title: 'loopback',    link: 'http://127.0.0.1/x.jpg',                    snippet: ''),
      OpenStruct.new(title: 'private',     link: 'http://10.0.0.5/x.jpg',                     snippet: ''),
      OpenStruct.new(title: 'linklocal',   link: 'http://169.254.169.254/latest/meta-data',   snippet: '')
    ]
    fetched_urls = []
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :__search, :search)
    GoogleCustomSearchApi.singleton_class.send(:define_method, :search) { |_q, _o|
      OpenStruct.new('error' => nil, 'items' => items, :items => items)
    }
    RestClient::Request.singleton_class.send(:alias_method, :__execute, :execute)
    RestClient::Request.singleton_class.send(:define_method, :execute) { |opts|
      fetched_urls << opts[:url]
      OpenStruct.new(headers: { content_type: 'image/jpeg' }, body: 'OK')
    }

    results = Gogolmogol.new('cat', media_type: 'photo').download_results(limit: 6)

    assert_equal ['https://example.com/ok.jpg'], fetched_urls,
                 'only the public https URL must reach RestClient'
    assert_equal 1, results.size
    results.each { |r| r[:tmp].close; r[:tmp].unlink }
  ensure
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :search, :__search)
    GoogleCustomSearchApi.singleton_class.send(:remove_method, :__search)
    RestClient::Request.singleton_class.send(:alias_method, :execute, :__execute)
    RestClient::Request.singleton_class.send(:remove_method, :__execute)
  end

  def test_download_results_drops_failed_links
    items = [
      OpenStruct.new(title: 'ok',    link: 'http://example.com/ok.jpg',    snippet: ''),
      OpenStruct.new(title: 'fail',  link: 'http://example.com/fail.jpg',  snippet: ''),
      OpenStruct.new(title: 'ok2',   link: 'http://example.com/ok2.jpg',   snippet: '')
    ]
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :__search, :search)
    GoogleCustomSearchApi.singleton_class.send(:define_method, :search) { |_q, _o|
      OpenStruct.new('error' => nil, 'items' => items, :items => items)
    }
    RestClient::Request.singleton_class.send(:alias_method, :__execute, :execute)
    RestClient::Request.singleton_class.send(:define_method, :execute) { |opts|
      raise 'boom 403' if opts[:url] == 'http://example.com/fail.jpg'
      OpenStruct.new(headers: { content_type: 'image/jpeg' }, body: 'OK')
    }

    results = Gogolmogol.new('cat', media_type: 'photo').download_results(limit: 3)
    assert_equal 2, results.size, 'failed link must be filtered out'
    refute results.any? { |r| r[:link] == 'http://example.com/fail.jpg' }
    results.each { |r| r[:tmp].close; r[:tmp].unlink }
  ensure
    GoogleCustomSearchApi.singleton_class.send(:alias_method, :search, :__search)
    GoogleCustomSearchApi.singleton_class.send(:remove_method, :__search)
    RestClient::Request.singleton_class.send(:alias_method, :execute, :__execute)
    RestClient::Request.singleton_class.send(:remove_method, :__execute)
  end
end

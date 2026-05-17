require 'google_custom_search_api'
require 'rest-client'
require 'tempfile'
require 'uri'
require 'ipaddr'

class Gogolmogol
  EXT_BY_MIME    = { 'image/gif' => 'gif', 'image/png' => 'png', 'image/webp' => 'webp' }.freeze
  DEFAULT_EXT    = 'jpg'
  SCRAPE_HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
  }.freeze

  @@access_rights = Settings.google

  def initialize(query, media_type: 'text')
    @query      = query
    @media_type = media_type
    @access_idx = (0...@@access_rights.count).to_a.shuffle
  end

  def search_results(limit: 3)
    @@access_rights.size.times do |attempt|
      search = search_attempt(attempt)
      next if search.dig('error', 'errors', 0, 'reason') == 'dailyLimitExceeded'
      return search.items.first(limit).map { |item|
        { title: item.title, link: item.link, snippet: item.respond_to?(:snippet) ? item.snippet : '' }
      }
    rescue => e
      LOGGER.warn "#{self.class.name}#search_results attempt=#{attempt}: #{e.message}"
      next
    end
    []
  end

  # Caller owns Tempfile lifecycle (close + unlink).
  def download_results(limit: 4)
    search_results(limit: limit).filter_map do |r|
      tmp, mime = download(r[:link])
      { tmp: tmp, mime: mime, link: r[:link] } if tmp
    end
  end

  private

  def search_attempt(number)
    creds = @@access_rights[@access_idx[number]]
    get_search(@query, api_key: creds['api_key'], cx_key: creds['cx_key'])
  end

  def get_search(query, opts = {})
    opts['safe'] = 'off'
    case @media_type
    when 'photo'
      opts['searchType'] = 'image'
      opts['imgSize']    = 'large'
    when 'gif'
      opts['searchType'] = 'image'
      opts['fileType']   = 'gif'
      opts['imgSize']    = 'large'
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = GoogleCustomSearchApi.search(query, opts)
    LOGGER.debug "#{self.class.name}#get_search media=#{@media_type} took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms results=#{result['items']&.size || 0}"
    result
  end

  # SSRF guard for Google-returned URLs: allow only http(s) + reject literal-IP
  # hosts in loopback/private/link-local ranges. Residual risks not handled
  # here: (1) hostname → private-IP via DNS; (2) public→private redirects
  # (RestClient follows up to max_redirects without re-validating each hop).
  def safe_url?(url)
    uri = URI.parse(url)
    return false unless %w[http https].include?(uri.scheme)
    host = uri.host&.downcase
    return false if host.nil? || host.empty? || host == 'localhost'
    if (ip = (IPAddr.new(host) rescue nil))
      return false if ip.loopback? || ip.private? || ip.link_local?
    end
    true
  rescue URI::InvalidURIError
    false
  end

  def download(url)
    unless safe_url?(url)
      LOGGER.warn "#{self.class.name}#download: blocked unsafe URL: #{url.to_s[0, 80]}"
      return [nil, nil]
    end
    data = RestClient::Request.execute(
      method: :get, url: url, headers: SCRAPE_HEADERS,
      timeout: 10, max_redirects: 3
    )
    mime = data.headers[:content_type]&.split(';')&.first || 'image/jpeg'
    ext  = EXT_BY_MIME.fetch(mime, DEFAULT_EXT)
    tmp  = Tempfile.new(['gsearch_', ".#{ext}"])
    tmp.binmode; tmp.write(data.body); tmp.flush
    [tmp, mime]
  rescue => e
    LOGGER.warn "#{self.class.name}#download: skipping #{url}: #{e.message}"
    [nil, nil]
  end
end

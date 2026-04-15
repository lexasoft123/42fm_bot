require 'socket'
require 'timeout'
require 'unicode_utils'
require 'rest-client'

class Radio
  CONNECT_TIMEOUT = 5
  READ_TIMEOUT    = 10

  def initialize
    @sock  = nil
    @mutex = Mutex.new
  end

  def track
    res    = command("#{Settings.radio['source']}.metadata", raw: true)
    tracks = parse_metadata(res)
    remain = remaining
    "#{format_track_name(tracks.last)}, осталось #{remain}"
  end

  def request(track)
    res = search_track(track)
    return nil if res.empty?

    tr     = res.sample
    req_id = command("request.push #{tr}")
    meta   = get_track_metadata(req_id)
    name   = format_track_name(meta, request_id: req_id)
    { name: name, id: req_id }
  end

  def remove(tracks)
    tracks.all? { |tr| command("request.remove #{tr}") == "OK" }
  end

  def queue
    queue_tracks = command("request.queue").split(/\s/)
    return nil if queue_tracks.empty?
    queue_tracks.map { |tr| format_track_name(get_track_metadata(tr), request_id: tr) }.join("\n")
  end

  def top(track)
    command("request.move #{track} 0")
  end

  def meta
    res   = command("#{Settings.radio['source']}.metadata", raw: true)
    track = parse_metadata(res).last
    return "(нет данных)" unless track
    [
      "band:     #{track[:artist]}",
      "title:       #{track[:title]}",
      "album:   #{track[:album]}",
      "year:      #{track[:year]}",
      "genre:    #{track[:genre]}"
    ].join("\n")
  end

  def listeners
    rd = RestClient::Request.execute(method: :get, url: "http://listen.42fm.ru:8000/status-json.xsl", timeout: 10)
    h  = JSON.parse(rd)
    h['icestats']['source'].sum { |s| s['listeners'] }
  end

  def remaining
    seconds = command("#{Settings.radio['source']}.remaining").to_i
    Time.at(seconds).utc.strftime("%M:%S")
  end

  def history
    res = command("#{Settings.radio['source']}.metadata", raw: true)
    parse_metadata(res).map { |t| format_track_name(t) }.join("\n")
  end

  def search(track)
    search_track(track)
  end

  def search_songs(query, limit: 20)
    Song.search(query, limit: limit)
  end

  private

  def connect
    Timeout::timeout(CONNECT_TIMEOUT) { @sock = TCPSocket.open("localhost", 1234) }
  end

  def command(cmd, raw: false)
    @mutex.synchronize do
      retried = false
      begin
        connect if @sock.nil?
        @sock.puts cmd
        res = Timeout::timeout(READ_TIMEOUT) { @sock.gets("END") }
        raise IOError, "connection closed" unless res
        res.force_encoding('UTF-8')
        raw ? res : res.gsub(/[\r\n]+/, "").gsub("END", "").gsub(/\\"/, '"')
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
        unless retried
          LOGGER.warn "Radio: #{e.class}: #{e.message} — reconnecting" if defined?(LOGGER)
          @sock&.close rescue nil
          @sock = nil
          retried = true
          retry
        end
        raise
      end
    end
  end

  def parse_metadata(text)
    text.split(/--- \d{1,} ---[\r\n]+/)
        .map  { |tr| parse_single_metadata(tr) }
        .compact
  end

  def parse_single_metadata(tr)
    data = tr.scan(/\s*\"{0,}(\w*)\"{0,}\s*=\s*\"?(.*?)\"?\s*[\r\n]+/)
    return nil if data.empty?
    data.each_with_object({}) { |arr, h| h[arr[0].to_sym] = arr[1] }
  end

  def format_track_name(track, request_id: nil)
    return "(нет данных)" unless track
    name  = "#{track[:artist].to_s} — #{track[:title].to_s}"
    name += " (#{track[:year]})" if track[:year]
    name += " [#{request_id.to_i}]" if request_id
    name
  end

  def search_track(query)
    songs = Song.search(query, limit: 50)
    songs.map(&:absolute_path)
  end

  def get_track_metadata(req_id)
    parse_single_metadata(command("request.metadata #{req_id.to_i}", raw: true))
  end
end

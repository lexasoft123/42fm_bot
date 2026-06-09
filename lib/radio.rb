require 'socket'
require 'timeout'
require 'unicode_utils'
require 'rest-client'

class Radio
  CONNECT_TIMEOUT = 5
  READ_TIMEOUT    = 10
  # Keep the lazy persistent socket warm. Liquidsoap closes idle telnet
  # connections, and the next reuse of a stale socket loses its first
  # response — which is why `!track` returned "(нет данных)" while a track
  # was actually playing. A periodic lightweight ping pays that
  # reconnect-on-idle penalty here instead of on a user's command, so real
  # commands always hit a warm socket. Interval must stay well under
  # Liquidsoap's idle-close timeout.
  KEEPALIVE_INTERVAL = 20
  KEEPALIVE_CMD      = "request.queue" # harmless, source-independent status ping

  def initialize
    @sock      = nil
    @mutex     = Mutex.new
    @keepalive = nil
  end

  # Start the background keepalive pinger. Idempotent — safe to call on every
  # bot (re)start. Returns the keepalive Thread.
  def start_keepalive(interval: KEEPALIVE_INTERVAL)
    @keepalive ||= Thread.new do
      loop do
        sleep interval
        begin
          command(KEEPALIVE_CMD)
        rescue => e
          LOGGER.warn "#{self.class.name} keepalive: #{e.class}: #{e.message}" if defined?(LOGGER)
        end
      end
    end
  end

  def track
    res     = command("#{Settings.radio['source']}.metadata", raw: true)
    current = parse_metadata(res).last
    # Liquidsoap occasionally returns no metadata for the playing source —
    # don't surface a bare "(нет данных), осталось …" placeholder.
    return "сейчас ничего не играет" unless current
    "#{format_track_name(current)}, осталось #{remaining}"
  end

  def request(track)
    songs = Song.search(track, limit: 50)
    return nil if songs.empty?

    song   = songs.sample
    req_id = command("request.push #{song.absolute_path}")
    meta   = get_track_metadata(req_id)
    name   = meta ? format_track_name(meta, request_id: req_id)
                  : "#{song.display_name} [#{req_id.to_i}]"
    { name: name, id: req_id }
  end

  def remove(tracks)
    tracks.all? { |tr| command("request.remove #{tr}") == "OK" }
  end

  def queue
    queue_tracks = command("request.queue").split(/\s/)
    return nil if queue_tracks.empty?
    # Skip slots whose metadata Liquidsoap can't resolve rather than
    # rendering a column of "(нет данных)" lines. All blank → nil → the
    # command renders "нихуя нет".
    names = queue_tracks.filter_map do |tr|
      meta = get_track_metadata(tr)
      format_track_name(meta, request_id: tr) if meta
    end
    names.empty? ? nil : names.join("\n")
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
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        connect if @sock.nil?
        @sock.puts cmd
        res = Timeout::timeout(READ_TIMEOUT) { @sock.gets("END") }
        raise IOError, "connection closed" unless res
        res.force_encoding('UTF-8')
        result = raw ? res : res.gsub(/[\r\n]+/, "").gsub("END", "").gsub(/\\"/, '"')
        LOGGER.debug "#{self.class.name}#command(#{cmd.split.first}) took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms" if defined?(LOGGER)
        result
      # Timeout::Error included so a *hung* (half-open) socket also resets
      # @sock and reconnects — otherwise a hang would reuse the dead socket
      # and time out on every subsequent command indefinitely.
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError, Timeout::Error => e
        unless retried
          LOGGER.warn "#{self.class.name}: #{e.class}: #{e.message} — reconnecting" if defined?(LOGGER)
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

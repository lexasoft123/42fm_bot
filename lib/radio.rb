require 'socket'
require 'translit'
require 'unicode_utils'
require 'rest-client'
require 'yaml'

CONFIG = YAML.load(File.read('config/radio.yml'))

class Radio
  attr_accessor :sock

  def initialize
    @sock = TCPSocket.open("localhost", 1234)
  end

  def send cmd, raw: false
    @sock.puts cmd
    res = @sock.gets "END"
    res.force_encoding('UTF-8')
    res = res.gsub(/[\r\n]+/, "").gsub("END", "").gsub(/\\"/, '"') if not raw
    res
  end

  def track
    res = send "stealkill.metadata", raw: true
    tracks = parse_metadata res
    remain = remaining
    name = format_track_name tracks.last
    "#{name}, осталось #{remain}"
  end

  def request track
    res = search_track track
    if not res.empty?
      tr = res.sample
      req_id = send "request.push #{tr}"

      track = get_track_metadata req_id
      name = format_track_name track, request_id: req_id
      return {name: name, id: req_id}
    end
    nil
  end

  def remove tracks
    res = true
    tracks.each do |tr|
      cmd = send("request.remove #{tr}")
      res = (res and (cmd == "OK"))
    end
    res
  end

  def queue
    queue_tracks = send("request.queue").split(/\s/)

    return nil if queue_tracks.empty?

    queue = []

    queue_tracks.each do |tr|
      meta = get_track_metadata tr
      queue << format_track_name(meta, request_id: tr)
    end

    queue.join("\n")
  end

  def top track
    send("request.move #{track} 0")
  end

  def meta
    res = send "stealkill.metadata", raw: true
    track = parse_metadata(res).last
    track.slice! :artist, :title, :album, :year, :genre
    out = []

    out << "band:     #{track[:artist]}"
    out << "title:       #{track[:title]}"
    out << "album:   #{track[:album]}"
    out << "year:      #{track[:year]}"
    out << "genre:    #{track[:genre]}"

    out.join("\n")
  end

  def listeners
    rd = RestClient.get "http://listen.42fm.ru:8000/status-json.xsl"
    h = JSON.parse rd
    return h['icestats']['source'].collect { |s| s['listeners'] }.inject(:+)
  end

  def remaining
    seconds = send("stealkill.remaining").to_i
    Time.at(seconds).utc.strftime("%M:%S")
  end

  def history
    res = send "stealkill.metadata", raw: true
    tracks = parse_metadata res
    tracks.collect { |track| format_track_name track }.join("\n")
  end

  def search track
    search_track track
  end

  private

  def parse_metadata text
    track_data = text.split /--- \d{1,} ---[\r\n]+/
    tracks = track_data.collect { |tr| parse_single_metadata tr }
    tracks.compact
  end

  def parse_single_metadata tr
    data = tr.scan /\s*\"{0,}(\w*)\"{0,}\s*=\s*\"?(.*?)\"?\s*[\r\n]+/
    return nil if data.empty?
    hash = {}
    data.each {|arr| hash[arr[0].to_sym] = arr[1]}
    hash
  end

  def format_track_name track, request_id: nil
    res = "%{artist} — %{title}" % {artist: track[:artist].to_s, title: track[:title].to_s}
    res += " (%{year})" % track if track[:year]
    res += " [#{request_id.to_i}]" if request_id
    res
  end

  def search_track track
    music = File.read(CONFIG['db']).split(/[\r\n]+/)

    Translit.convert! track if /\p{Cyrillic}/.match track

    req = UnicodeUtils.downcase track
    q = req.split(/\s/) # Mega important optimization
    result = music.select { |tr| r = q.select{ |w| tr.downcase.gsub(".", "").index w }; r.size == q.size }
    result
  end

  def get_track_metadata req_id
    track_data = send "request.metadata #{req_id.to_i}", raw: true
    parse_single_metadata track_data
  end

end


#r = Radio.new;
#puts r.track

#req = r.request "jozin bazin"
#p req

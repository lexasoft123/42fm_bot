require 'wahwah'

class MusicScanner
  AUDIO_EXTENSIONS = %w[.mp3 .ogg .m4a .flac .wav].freeze
  BATCH_SIZE = 500

  def initialize(music_path: nil, logger: nil)
    @music_path = music_path || Settings.radio['path']
    @logger = logger || (defined?(LOGGER) ? LOGGER : Logger.new($stdout))
  end

  def scan
    @logger.info "MusicScanner: scanning #{@music_path}"

    files = collect_audio_files
    @logger.info "MusicScanner: found #{files.size} audio files"

    stats = { scanned: 0, created: 0, updated: 0, errors: 0 }
    scan_start = Time.now

    files.each_slice(BATCH_SIZE) do |batch|
      ActiveRecord::Base.transaction do
        batch.each { |f| process_file(f, stats, scan_start) }
      end
      @logger.info "MusicScanner: progress #{stats[:scanned]}/#{files.size} (#{stats[:created]} new, #{stats[:updated]} updated, #{stats[:errors]} errors)"
    end

    removed = Song.where('updated_at < ?', scan_start).delete_all
    stats[:removed] = removed
    @logger.info "MusicScanner: removed #{removed} orphaned records" if removed > 0

    @logger.info "MusicScanner: done. #{stats}"
    stats
  end

  private

  def collect_audio_files
    Dir.glob(File.join(@music_path, '**', '*'))
       .select { |f| File.file?(f) && AUDIO_EXTENSIONS.include?(File.extname(f).downcase) }
  end

  def process_file(abs_path, stats, scan_start)
    stats[:scanned] += 1
    rel_path = abs_path.sub("#{@music_path}/", '')
    category = rel_path.split('/').first

    tags = read_tags(abs_path)
    tags[:artist] = parse_artist_from_path(rel_path) if tags[:artist].to_s.strip.empty?
    tags[:title]  = parse_title_from_path(rel_path)  if tags[:title].to_s.strip.empty?

    song = Song.find_by(filepath: rel_path)
    attrs = {
      title: tags[:title], artist: tags[:artist], album: tags[:album],
      genre: tags[:genre], year: tags[:year], duration: tags[:duration],
      category: category, updated_at: scan_start
    }

    if song
      song.update!(attrs)
      stats[:updated] += 1
    else
      Song.create!(attrs.merge(filepath: rel_path))
      stats[:created] += 1
    end
  rescue => e
    stats[:errors] += 1
    @logger.warn "MusicScanner: error on #{abs_path}: #{e.message}"
  end

  def read_tags(path)
    tag = WahWah.open(path)
    tags = {}
    tags[:title]    = tag.title.to_s.strip
    tags[:artist]   = tag.artist.to_s.strip
    tags[:album]    = tag.album.to_s.strip
    tags[:genre]    = tag.genre.to_s.strip
    tags[:year]     = tag.year.to_i if tag.year.to_i > 0
    tags[:duration] = tag.duration.to_i if tag.duration.to_i > 0
    tags
  rescue => e
    @logger.warn "MusicScanner: tag read error on #{path}: #{e.message}"
    {}
  end

  def parse_artist_from_path(rel_path)
    parts = rel_path.split('/')
    return '' if parts.size < 2
    parts[-2].gsub('_', ' ')
  end

  def parse_title_from_path(rel_path)
    File.basename(rel_path, '.*').gsub('_', ' ')
  end
end

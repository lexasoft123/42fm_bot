require 'translit'

class Song < ActiveRecord::Base
  # FTS4 search: returns Song records matching query.
  # If the query contains Cyrillic and returns no results, retries with a
  # transliterated (Latin) version of the query so that e.g. "металлика"
  # can match "Metallica" in the index.
  def self.search(query, limit: 20)
    return [] if query.nil? || query.strip.empty?

    results = fts_search(query, limit: limit)

    if results.empty? && query.match?(/\p{Cyrillic}/)
      latin = Translit.convert(query)
      unless latin == query
        # Stage 1: k/c, ts/c, kh/h spelling variants (handles "металлика"→"metallica")
        latin_variants(latin).each do |variant|
          results = fts_search(variant, limit: limit)
          break unless results.empty?
        end

        # Stage 2: prefix truncation on original + variants
        # e.g. "metalliku" → k→c → "metallicu" → truncate → "metallic*" → matches "Metallica"
        if results.empty?
          ([latin] + latin_variants(latin)).each do |v|
            results = fts_search_truncated(v, limit: limit)
            break unless results.empty?
          end
        end

        # Stage 3: LIKE fallback on original + variants
        if results.empty?
          ([latin] + latin_variants(latin)).each do |variant|
            results = fallback_search(variant, limit: limit)
            break unless results.empty?
          end
        end

        # Stage 4: edit-distance fuzzy match (catches e.g. "rammshtajn"→"rammstein")
        results = editdist_search(latin, limit: limit) if results.empty?
      end
    end

    results
  end

  private_class_method def self.latin_variants(query)
    variants = []
    v = query.gsub(/k(?=[aeiou]|\b)/i, 'c')
    variants << v unless v == query
    v = query.gsub(/ts(?=[aeiou])/i, 'c')
    variants << v unless v == query
    v = query.gsub(/kh/i, 'h')
    variants << v unless v == query
    # Cyrillic "в" transliterates to "w" but English proper nouns use "v"
    # e.g. "нирвана" → "nirwana" → "nirvana"
    v = query.gsub(/w/i, 'v')
    variants << v unless v == query
    variants.uniq
  end

  private_class_method def self.fts_search_truncated(query, limit:, min_prefix: 6)
    words = query.gsub(/[^\p{L}\p{N}\s]/, '').split.reject(&:empty?)
    prefixes = words.map { |w| w.length > min_prefix ? "#{w[0, w.length - 2]}*" : "#{w}*" }
    return [] if prefixes.empty?
    find_by_sql([
      "SELECT songs.* FROM songs " \
      "JOIN songs_fts ON songs.id = songs_fts.rowid " \
      "WHERE songs_fts MATCH ? LIMIT ?",
      prefixes.join(' '), limit
    ])
  rescue ActiveRecord::StatementInvalid
    []
  end

  EDITDIST_MIN_WORD = 6  # skip short words to avoid false positives
  EDITDIST_MAX      = 4  # absolute cap on allowed distance

  private_class_method def self.editdist_search(query, limit:)
    words = query.gsub(/[^\p{L}\p{N}\s]/, '').split.reject { |w| w.length < EDITDIST_MIN_WORD }
    return [] if words.empty?

    scope = all
    words.each do |w|
      threshold = [(w.length / 3.0).ceil, EDITDIST_MAX].min
      scope = scope.where(
        "editdist(LOWER(artist), ?) <= ? OR editdist(LOWER(title), ?) <= ? OR editdist(LOWER(album), ?) <= ?",
        w, threshold, w, threshold, w, threshold
      )
    end
    scope.limit(limit).to_a
  rescue ActiveRecord::StatementInvalid
    []
  end

  private_class_method def self.fts_search(query, limit:)
    sanitized = sanitize_fts_query(query)
    return fallback_search(query, limit: limit) if sanitized.empty?

    find_by_sql([
      "SELECT songs.* FROM songs " \
      "JOIN songs_fts ON songs.id = songs_fts.rowid " \
      "WHERE songs_fts MATCH ? " \
      "LIMIT ?",
      sanitized, limit
    ])
  rescue ActiveRecord::StatementInvalid
    fallback_search(query, limit: limit)
  end

  # Full absolute path for Liquidsoap request.push.
  # Uses radio.host_path if set (Liquidsoap's view of the music dir),
  # falling back to radio.path (container's view, used by MusicScanner).
  def absolute_path
    base = Settings.radio['host_path'] || Settings.radio['path']
    File.join(base, filepath)
  end

  def display_name
    parts = [artist, title].map(&:to_s).reject(&:empty?)
    name = parts.any? ? parts.join(' — ') : File.basename(filepath, '.*').gsub('_', ' ')
    name += " (#{year})" if year && year > 0
    name
  end

  private

  def self.sanitize_fts_query(query)
    words = query.gsub(/[^\p{L}\p{N}\s]/, '').split.reject(&:empty?)
    words.map { |w| "#{w}*" }.join(' ')
  end

  def self.fallback_search(query, limit: 20)
    words = query.downcase.split
    scope = all
    words.each do |w|
      pattern = "%#{w}%"
      scope = scope.where(
        "LOWER(title) LIKE ? OR LOWER(artist) LIKE ? OR LOWER(album) LIKE ? OR LOWER(filepath) LIKE ?",
        pattern, pattern, pattern, pattern
      )
    end
    scope.limit(limit)
  end
end

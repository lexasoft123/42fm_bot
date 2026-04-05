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
      latin = Translit.convert(query, :russian)
      results = fts_search(latin, limit: limit) unless latin == query
    end

    results
  end

  private_class_method def self.fts_search(query, limit:)
    sanitized = sanitize_fts_query(query)
    return fallback_search(query, limit: limit) if sanitized.empty?

    find_by_sql([
      "SELECT songs.* FROM songs " \
      "JOIN songs_fts ON songs.id = songs_fts.docid " \
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

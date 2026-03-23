class Song < ActiveRecord::Base
  # FTS4 search: returns Song records matching query
  def self.search(query, limit: 20)
    return [] if query.nil? || query.strip.empty?

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

  # Full absolute path for Liquidsoap request.push
  def absolute_path
    File.join(Settings.radio['path'], filepath)
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

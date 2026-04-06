require_relative 'test_helper'

class SongSearchTest < BotTest
  include Fixtures::Songs

  def setup
    super
    @metallica     = metallica
    @nirvana       = nirvana
    @floyd         = pink_floyd
    @acdc          = acdc
    @celine        = celine_dion
    @harrison      = george_harrison
    @cash          = johnny_cash
    @iron_maiden   = iron_maiden
    @gazmanov      = gazmanov
    @uratsakidogi  = uratsakidogi
    @stalker       = stalker_guitar
  end

  # ---------------------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------------------

  def test_nil_returns_empty
    assert_equal [], Song.search(nil)
  end

  def test_empty_string_returns_empty
    assert_equal [], Song.search("")
  end

  def test_whitespace_returns_empty
    assert_equal [], Song.search("   ")
  end

  # ---------------------------------------------------------------------------
  # Direct FTS — Latin
  # ---------------------------------------------------------------------------

  def test_exact_artist_match
    ids = Song.search("Metallica").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_case_insensitive_fts
    ids = Song.search("metallica").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_fts_prefix_match
    ids = Song.search("Metall").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_match_by_title
    ids = Song.search("Master of Puppets").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_match_by_album
    song = Song.create!(artist: "Pink Floyd", title: "Another Brick", album: "The Wall", filepath: "floyd/brick.mp3")
    ids = Song.search("Wall").map(&:id)
    assert_includes ids, song.id
  end

  def test_match_by_genre
    song = Song.create!(artist: "B.B. King", title: "The Thrill is Gone", genre: "Blues", filepath: "bb/thrill.mp3")
    ids = Song.search("Blues").map(&:id)
    assert_includes ids, song.id
  end

  def test_no_match_returns_empty
    assert_equal [], Song.search("ZZZunknown999")
  end

  def test_limit_respected
    assert Song.search("a", limit: 1).size <= 1
  end

  def test_multiple_results_returned
    # "Back" appears in both AC/DC title and some other query — use "iron" to find Iron Maiden
    Song.create!(artist: "Iron Butterfly", title: "In-A-Gadda-Da-Vida", filepath: "butterfly/gadda.mp3")
    results = Song.search("iron")
    assert results.size >= 2
  end

  def test_multiword_latin_narrows_results
    # "fear of the dark" — all 4 words must appear in the same song
    ids = Song.search("fear of the dark").map(&:id)
    assert_includes ids, @iron_maiden.id
    refute_includes ids, @metallica.id
  end

  def test_single_rare_word_latin
    ids = Song.search("uratsakidogi").map(&:id)
    assert_includes ids, @uratsakidogi.id
  end

  def test_multiword_latin_both_words_in_different_fields
    # "stalker guitar" — "Stalker" in artist, "Guitar" in title — FTS indexes all columns together
    ids = Song.search("stalker guitar").map(&:id)
    assert_includes ids, @stalker.id
  end

  def test_latin_with_hyphen_stripped
    # "Johnny Cash - Solitary Man" — hyphen stripped by sanitize_fts_query
    ids = Song.search("Johnny Cash - Solitary Man").map(&:id)
    assert_includes ids, @cash.id
  end

  def test_em_dash_stripped
    # em dash also stripped
    ids = Song.search("Johnny Cash \u2014 Solitary Man").map(&:id)
    assert_includes ids, @cash.id
  end

  def test_numeric_year_search_returns_empty
    # Year is an integer column, not in FTS index; no text fields contain bare "2013"
    assert_equal [], Song.search("2013")
  end

  # ---------------------------------------------------------------------------
  # Cyrillic fallback — prod queries
  # ---------------------------------------------------------------------------

  def test_cyrillic_metallika_nominative
    # "металлика" → translit "metallika" → k→c variant "metallica" → FTS match
    ids = Song.search("металлика").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_cyrillic_metalliku_accusative
    # "металлику" → translit "metalliku" → k→c → "metallicu" → truncate variant → "metallic*" → match
    ids = Song.search("металлику").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_cyrillic_metalliCu_accusative
    # "металлицу" → translit "metallicu" (ц→c) → truncation "metallic*" → prefix of "metallica" → match
    ids = Song.search("металлицу").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_cyrillic_harrison
    # "харрисон" → translit "harrison" (х→h directly) → FTS "harrison*" → match
    ids = Song.search("харрисон").map(&:id)
    assert_includes ids, @harrison.id
  end

  def test_cyrillic_celine_dion
    # "целин дион" → translit "celin dion" → direct FTS "celin* dion*" → match
    ids = Song.search("целин дион").map(&:id)
    assert_includes ids, @celine.id
  end

  def test_cyrillic_gazmanov
    # "Газманов" → translit "gazmanov" → direct FTS "gazmanov*" → match
    ids = Song.search("Газманов").map(&:id)
    assert_includes ids, @gazmanov.id
  end

  def test_cyrillic_multiword_narrows
    # "металлика мастер" — both words must match → finds Master of Puppets only
    ids = Song.search("металлика мастер").map(&:id)
    assert_includes ids, @metallica.id
  end

  def test_cyrillic_nonsense_returns_empty
    # "рыба пылесос" — no plausible transliteration match in the DB
    assert_equal [], Song.search("рыба пылесос")
  end

  def test_cyrillic_hyphenated_no_crash
    # "Бу-Ра-То" — hyphen stripped, each word searched; at minimum no exception
    assert_respond_to Song.search("Бу-Ра-То"), :each
  end

  def test_cyrillic_nirvana
    # "нирвана" → translit "nirwana" → w→v variant "nirvana" → FTS5 match via Stage 1
    ids = Song.search("нирвана").map(&:id)
    assert_includes ids, @nirvana.id
  end

  def test_cyrillic_rammstein
    # "раммштайн" → translit "rammshtajn" — editdist("rammstein", "rammshtajn") = 3 → match via Stage 4
    rammstein = Song.create!(artist: "Rammstein", title: "Amerika", filepath: "rammstein/amerika.mp3")
    ids = Song.search("раммштайн").map(&:id)
    assert_includes ids, rammstein.id
  end

  # ---------------------------------------------------------------------------
  # FTS error fallback (StatementInvalid → LIKE)
  # ---------------------------------------------------------------------------

  def test_fts_syntax_error_falls_back_gracefully
    # Unbalanced quotes produce an FTS syntax error; fallback_search should handle it
    # The song filepath contains "master" which LIKE can match
    result = Song.search('"unbalanced')
    assert_kind_of Array, result
  end

  # ---------------------------------------------------------------------------
  # display_name
  # ---------------------------------------------------------------------------

  def test_display_name_artist_and_title
    assert_equal "Metallica \u2014 Master of Puppets", @metallica.display_name
  end

  def test_display_name_with_year
    assert_equal "Pink Floyd \u2014 Comfortably Numb (1979)", @floyd.display_name
  end

  def test_display_name_year_zero_not_shown
    song = Song.create!(artist: "Test", title: "Track", filepath: "t/t.mp3", year: 0)
    assert_equal "Test \u2014 Track", song.display_name
  end

  def test_display_name_nil_year_not_shown
    song = Song.create!(artist: "Test", title: "Track", filepath: "t/t2.mp3")
    assert_equal "Test \u2014 Track", song.display_name
  end

  def test_display_name_fallback_to_filepath
    song = Song.create!(filepath: "misc/some_track_file.mp3")
    assert_equal "some track file", song.display_name
  end

  def test_display_name_filepath_with_underscores
    song = Song.create!(filepath: "misc/cool_song_name.mp3")
    assert_equal "cool song name", song.display_name
  end

  # ---------------------------------------------------------------------------
  # absolute_path
  # ---------------------------------------------------------------------------

  def test_absolute_path_uses_path_setting
    assert_equal "/music/metallica/master.mp3", @metallica.absolute_path
  end

  def test_absolute_path_prefers_host_path
    Settings.radio = Settings.radio.merge('host_path' => '/content/music')
    assert_equal "/content/music/metallica/master.mp3", @metallica.absolute_path
  ensure
    Settings.radio = { 'path' => '/music', 'host_path' => nil }
  end
end

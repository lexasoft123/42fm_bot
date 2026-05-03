require_relative 'test_helper'
require 'yaml'
require_relative '../lib/agent/tools/_suno_language_rule'

# Regression guards for two coordinated changes:
#
# 1. The `lyrics` chat_gpt setting points at Anthropic's claude-sonnet-4-6.
#    DeepSeek was producing weaker rhyme/meter on creative songwriting in
#    our testing; flipping to Sonnet trades cost (this path is rare —
#    only fires when params['lyrics'] is empty, see suno_handler.rb's
#    `unless p['lyrics']` branch) for materially better lyric quality.
#
# 2. The Suno-bound "genre-language rule" — the language of the SUNG text
#    follows the GENRE'S native language, not the user's request language.
#    Russian-origin genres (chastushka, шансон, бардовская, советский
#    рок/панк/эстрада) → Russian. Anglo/global genres (rock, metal, pop,
#    surf rock, blues, jazz, hip-hop, country, electronic) → English by
#    default, even if the user asked in Russian. Section markers
#    ([Verse], [Chorus]) and parenthetical stage directions are always
#    English regardless. User can override explicitly. Catalysing case:
#    prod task 977 ("Сёрф против Картелей") composed Russian-language
#    stage directions for a surf-rock instrumental — the genre-language
#    rule disallows that.
#
# The rule lives word-for-word as the SUNO_LANGUAGE_RULE_RU constant in
# lib/agent/tools/_suno_language_rule.rb, interpolated into all three
# Suno-bound tool descriptions (compose_song, add_vocals, cover_audio)
# AND duplicated into the YAML lyrics_prompt template. The duplication
# in YAML is unavoidable (no Ruby interpolation in YAML), so this test
# pins both copies.
class SunoLanguagePolicyTest < BotTest
  ROOT = File.expand_path('..', __dir__)

  # Stable phrases drawn from SUNO_LANGUAGE_RULE_RU. Picked to be
  # robust to minor punctuation/formatting tweaks but tight enough that
  # accidentally dropping the rule from a site would fail the test.
  RULE_TOKENS = [
    /русско-говорящ/i,                 # Russian-genres branch
    /частушк/i,                         # Russian-genre exemplar
    /surf rock|rock, metal, pop/i,     # non-Russian-genre exemplar
    /английск.{0,40}по умолчанию/i,    # English-by-default branch
    /section markers/i,                 # stage-directions sub-rule
    /override/i,                        # user-override escape hatch
  ].freeze

  def setup
    super
    @settings = YAML.load_file(File.join(ROOT, 'config/settings.common.yml'))
  end

  # --- 1. lyrics setting → Sonnet ---

  def test_lyrics_setting_uses_anthropic_sonnet_4_6
    lyrics = @settings.dig('chat_gpt', 'settings', 'lyrics')
    refute_nil lyrics, 'chat_gpt.settings.lyrics block must exist'
    assert_equal 'anthropic',          lyrics['provider']
    assert_equal 'claude-sonnet-4-6',  lyrics['model']
  end

  def test_lyrics_setting_has_pricing_entry
    pricing = @settings.dig('chat_gpt', 'pricing', 'claude-sonnet-4-6')
    refute_nil pricing, 'claude-sonnet-4-6 pricing must be wired'
    %w[input output cache_read].each { |k| assert pricing[k], "pricing.#{k} missing" }
  end

  # --- 2. Genre-language rule baked into prompts/descriptions ---

  def assert_rule_present(haystack, site_label)
    RULE_TOKENS.each do |re|
      assert_match re, haystack, "[#{site_label}] missing rule fragment matching #{re.inspect}"
    end
  end

  def test_canonical_rule_constant_carries_all_required_tokens
    # Pins the constant itself — if a refactor narrows the rule, this
    # test fails before we accidentally narrow it everywhere via the
    # downstream interpolations.
    assert_rule_present(SUNO_LANGUAGE_RULE_RU, 'SUNO_LANGUAGE_RULE_RU constant')
  end

  def test_lyrics_prompt_template_states_genre_language_rule
    template = @settings.dig('suno', 'lyrics_prompt').to_s
    refute_empty template, 'suno.lyrics_prompt must exist'
    assert_rule_present(template, 'config/settings.common.yml suno.lyrics_prompt')
  end

  # The Ruby tool files reference the canonical constant by name —
  # interpolation happens at load time, so the rule text doesn't appear
  # verbatim in the source. We pin the constant's content separately
  # (test_canonical_rule_constant_carries_all_required_tokens above);
  # here we just verify the file imports + references the constant.
  def test_compose_song_tool_carries_rule_in_description_and_lyrics_param
    src = File.read(File.join(ROOT, 'lib/agent/tools/suno.rb'))
    assert_match(/require_relative\s+['"]_suno_language_rule['"]/, src,
                 'compose_song must require the canonical rule file')
    matches = src.scan(/SUNO_LANGUAGE_RULE_RU/).size
    assert_operator matches, :>=, 2,
                    "compose_song must apply the rule to both `description` and `lyrics` param (saw #{matches})"
  end

  def test_add_vocals_tool_carries_rule_via_canonical_constant
    src = File.read(File.join(ROOT, 'lib/agent/tools/add_vocals.rb'))
    assert_match(/SUNO_LANGUAGE_RULE_RU/, src,
                 'add_vocals must reuse the canonical constant')
  end

  def test_cover_audio_tool_carries_rule_via_canonical_constant
    src = File.read(File.join(ROOT, 'lib/agent/tools/cover_audio.rb'))
    assert_match(/SUNO_LANGUAGE_RULE_RU/, src,
                 'cover_audio must reuse the canonical constant')
    # cover_audio has both `lyrics` and `topic` params — both feed Suno's
    # prompt field. Two interpolations expected, not just one.
    matches = src.scan(/SUNO_LANGUAGE_RULE_RU/).size
    assert_operator matches, :>=, 2,
                    "cover_audio must apply the rule to both `lyrics` and `topic` (saw #{matches} interpolation(s))"
  end
end

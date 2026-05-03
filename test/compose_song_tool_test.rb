require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    { 'rate_limits' => { 'suno' => { 'max' => 100, 'window_minutes' => 60 } } }
  }
end
unless Settings.respond_to?(:replies)
  Settings.singleton_class.send(:define_method, :replies) { {} }
end

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/agent/tools/suno'

# Tests for compose_song's `theme`-vs-`lyrics` split.
#
# Pre-split, compose_song's primary content arg was `lyrics` and the
# agent (running on the `agent` setting = DeepSeek) inline-composed lyrics
# every time. That bypassed the dedicated `lyrics` setting (Sonnet) — so
# the Sonnet upgrade was effectively dead code.
#
# Post-split: the agent fills `theme` (a short topic phrase) and leaves
# `lyrics` empty by default. SunoTaskHandler#compose_and_submit_generate
# sees nil/empty lyrics and routes through the Sonnet composer
# (`unless p['lyrics']` branch). The agent only fills `lyrics` when the
# user gave verbatim text or is editing a previously-generated song.
#
# These tests pin the params persisted to the BackgroundTask — the
# downstream handler path is exercised in suno_handler_chain_test.
class ComposeSongToolTest < BotTest
  CHAT = -1234567895

  def setup
    super
    @tool = Agent::ToolRegistry.find('compose_song')
    @user = OpenStruct.new(uid: 999, role: 'member')
  end

  def call_tool(args)
    ctx = { chat_id: CHAT, user: @user }
    @tool.handler.call(args, ctx)
  end

  def last_song_params
    BackgroundTask.where(chat_id: CHAT, task_type: 'suno_generate').last.params_hash
  end

  # --- theme → topic mapping (the route that triggers Sonnet composition) ---

  def test_theme_arg_persists_as_topic_in_task_params
    call_tool('theme' => 'про усталого программиста и его кота',
              'tags'  => 'indie folk', 'title' => 'Программист',
              'genre' => 'фолк')
    p = last_song_params
    assert_equal 'про усталого программиста и его кота', p['topic']
  end

  def test_empty_lyrics_arg_persists_as_nil_so_handler_routes_through_sonnet
    call_tool('theme' => 'про любовь', 'lyrics' => '',
              'tags' => 'pop', 'title' => 'Love', 'genre' => 'поп')
    p = last_song_params
    # Handler's guard is `unless p['lyrics']`. `""` is truthy in Ruby, so
    # an unnormalised empty-string would skip Sonnet entirely — the agent
    # tool must persist nil for the guard to fire.
    assert_nil p['lyrics'], 'empty `lyrics` arg must persist as nil to trigger Sonnet composition'
    assert_equal 'про любовь', p['topic']
  end

  def test_whitespace_only_lyrics_arg_persists_as_nil
    call_tool('theme' => 'про осень', 'lyrics' => "   \n\t  ",
              'tags' => 'jazz', 'title' => 'Autumn', 'genre' => 'джаз')
    assert_nil last_song_params['lyrics'],
               'whitespace-only `lyrics` must be normalised to nil — Sonnet should still compose'
  end

  def test_omitted_lyrics_arg_persists_as_nil
    call_tool('theme' => 'про море', 'tags' => 'surf rock', 'title' => 'Sea',
              'genre' => 'рок')
    assert_nil last_song_params['lyrics']
  end

  # --- verbatim lyrics path (user-supplied text) ---

  def test_explicit_lyrics_arg_passes_through_unchanged
    call_tool('theme'  => 'про шефа',
              'lyrics' => "[Verse 1]\nLine one\nLine two\n[Chorus]\nHey hey",
              'tags'   => 'pop', 'title' => 'Chief', 'genre' => 'поп')
    p = last_song_params
    assert_match(/\[Verse 1\]/, p['lyrics'].to_s)
    assert_match(/\[Chorus\]/,  p['lyrics'].to_s)
    # Theme is still persisted in topic — handler will prefer params['lyrics']
    # over Sonnet composition (the `unless p['lyrics']` short-circuit), but
    # we still keep topic for downstream telemetry / agent_event summaries.
    assert_equal 'про шефа', p['topic']
  end

  # --- schema/registration ---

  def test_tool_schema_advertises_theme_parameter
    schema = @tool.parameters
    assert schema.key?('theme'), '`theme` parameter must be registered'
    assert_match(/тема\/идея|theme/i, schema['theme'][:description].to_s,
                 'theme description must explain its purpose')
  end

  def test_lyrics_param_documents_leave_empty_by_default
    desc = @tool.parameters['lyrics'][:description].to_s
    assert_match(/оставляй пустым|по умолчанию|optional/i, desc,
                 'lyrics description must instruct agent to leave empty by default')
  end
end

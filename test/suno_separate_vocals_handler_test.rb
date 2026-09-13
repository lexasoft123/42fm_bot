require_relative 'test_helper'
require 'tempfile'
require 'telegram/bot' # Faraday + Faraday::UploadIO for the delivery path
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

unless Settings.respond_to?(:suno)
  Settings.singleton_class.send(:define_method, :suno) {
    { 'api_url' => 'https://api.sunoapi.org', 'api_key' => 'k', 'model' => 'V5' }
  }
end

require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/media_download'
require_relative '../lib/task_runner'
require_relative '../lib/suno_client'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/task_handlers/suno_separate_vocals_handler'

# Pins SunoSeparateVocalsHandler: submit (audio_url vs Suno clip, permanent
# vs transient submit errors), poll failure → agent_event, mark_done! BEFORE
# delivery, ≤10-per-group chunking, and delivery failures that must never
# flip a :done task back to :failed.
class SunoSeparateVocalsHandlerTest < BotTest
  CHAT = -1234567898

  class FakeApi
    attr_reader :sent_messages, :media_groups
    attr_accessor :on_media_group

    def initialize; @sent_messages = []; @media_groups = []; end

    def sendMessage(**kw)
      @sent_messages << kw
      { 'ok' => true, 'result' => { 'message_id' => 1 } }
    end

    def sendMediaGroup(**kw)
      on_media_group&.call(kw)
      media = JSON.parse(kw[:media])
      @media_groups << media
      { 'ok' => true, 'result' => media.each_index.map { |i| { 'message_id' => 1000 + @media_groups.size * 20 + i } } }
    end
  end

  def setup
    super
    @handler = SunoSeparateVocalsHandler.new
    @api = FakeApi.new
    @handler.define_singleton_method(:download_to_tempfile) do |url, _name, chat_id: nil, suffix: '.mp3'|
      next nil if url.include?('broken')
      tmp = Tempfile.new(['stem_', suffix]); tmp.write('x'); tmp.rewind; tmp
    end
  end

  def make_task(external_id: nil, **params)
    defaults = { type: 'separate_vocal', mode: 'vocals', source_title: 'Демо', source_performer: 'Катя', user_uid: 1 }
    BackgroundTask.create!(task_type: 'suno_separate_vocals', chat_id: CHAT, max_attempts: 60,
                           external_id: external_id, params: defaults.merge(params).to_json)
  end

  # Replace SunoClient.new with a stub exposing the given singleton methods.
  def with_client(**methods)
    SunoClient.singleton_class.send(:alias_method, :__new_sep_test, :new)
    SunoClient.singleton_class.send(:define_method, :new) do
      stub = Object.new
      methods.each { |name, impl| stub.define_singleton_method(name, &impl) }
      stub
    end
    yield
  ensure
    SunoClient.singleton_class.send(:alias_method, :new, :__new_sep_test) rescue nil
    SunoClient.singleton_class.send(:remove_method, :__new_sep_test) rescue nil
  end

  def events
    BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').map(&:params_hash)
  end

  # --- submit ---

  def test_submit_with_audio_url_sends_url_and_stores_external_id
    task = make_task(audio_url: 'https://example.com/a.mp3')
    captured = nil
    with_client(separate_vocals: ->(**kw) { captured = kw; 'sep-1' }) do
      assert_equal :pending, @handler.call(task, @api)
    end
    assert_equal 'sep-1', fresh(task).external_id
    assert_equal 'https://example.com/a.mp3', captured[:audio_url]
    assert_nil captured[:task_id]
    assert_equal 'separate_vocal', captured[:type]
  end

  # Assertions read a FRESH row: BackgroundTask#params_hash is memoized and
  # `reload` doesn't clear it, so `task.reload.params_hash` would see the
  # handler's in-memory mutation even if the write never happened.
  def fresh(task) = BackgroundTask.find(task.id)

  def test_submit_with_suno_source_resolves_audio_id_for_clip
    task = make_task(source_task_id: 'song-1', clip_index: 2)
    captured = nil
    with_client(fetch_audio_ids: ->(_id) { %w[aud-1 aud-2] },
                separate_vocals: ->(**kw) { captured = kw; 'sep-2' }) do
      @handler.call(fresh(task), @api)
    end
    assert_equal 'song-1', captured[:task_id]
    assert_equal 'aud-2',  captured[:audio_id]
    assert_nil captured[:audio_url]
    assert_equal 'aud-2', fresh(task).params_hash['audio_id'], 'resolved audio_id is persisted for resubmits'
  end

  def test_permanent_submit_error_fails_now_with_agent_event
    task = make_task(audio_url: 'https://example.com/a.mp3')
    with_client(separate_vocals: ->(**_) { raise 'Suno /api/v1/vocal-removal/generate failed: 429 insufficient credits' }) do
      assert_equal :failed, @handler.call(task, @api)
    end
    assert_equal 'failed', fresh(task).status
    ev = events.last
    assert_equal 'separation_failed', ev['event_type']
    assert_match(/insufficient credits/, ev['summary'])
    assert_equal 'Не удалось разделить трек на дорожки', @api.sent_messages.last[:text]
  end

  # Each attempt loads a fresh row, like TaskRunner does per poll — the
  # submit_failures counter must survive in the DB, not in a shared object.
  def test_transient_submit_error_reraises_then_gives_up_at_cap
    task = make_task(audio_url: 'https://example.com/a.mp3')
    with_client(separate_vocals: ->(**_) { raise 'Suno /api/v1/vocal-removal/generate failed: code=455 maintenance' }) do
      (SunoSeparateVocalsHandler::MAX_SUBMIT_FAILURES - 1).times do |i|
        assert_raises(RuntimeError) { @handler.call(fresh(task), @api) }
        assert_equal i + 1, fresh(task).params_hash['submit_failures']
      end
      assert_equal :failed, @handler.call(fresh(task), @api)
    end
    assert_equal 'failed', fresh(task).status
    assert_match(/after_retries/, fresh(task).result_hash['error'])
  end

  # --- poll ---

  def test_poll_failure_emits_separation_failed_with_detail
    task = make_task(external_id: 'sep-1', audio_url: 'https://example.com/a.mp3')
    with_client(poll_separation_once: ->(_id) { { failed: true, error: 'Suno [500]: separation engine error' } }) do
      assert_equal :failed, @handler.call(task, @api)
    end
    ev = events.last
    assert_equal 'separation_failed', ev['event_type']
    assert_match(/separation engine error/, ev['summary'])
  end

  def test_poll_pending_stays_pending
    task = make_task(external_id: 'sep-1', audio_url: 'https://example.com/a.mp3')
    with_client(poll_separation_once: ->(_id) { :pending }) do
      assert_equal :pending, @handler.call(task, @api)
    end
  end

  # --- delivery ---

  def stems(n)
    n.times.map { |i| { name: "Stem#{i + 1}", url: "https://cdn/stem#{i + 1}.mp3" } }
  end

  def test_success_marks_done_before_delivery_and_sends_group
    task = make_task(external_id: 'sep-1', audio_url: 'https://example.com/a.mp3')
    status_at_send = nil
    @api.on_media_group = ->(_kw) { status_at_send = BackgroundTask.find(task.id).status }
    result = { stems: [{ name: 'Vocals', url: 'https://cdn/v.mp3' }, { name: 'Instrumental', url: 'https://cdn/i.mp3' }] }
    with_client(poll_separation_once: ->(_id) { result }) do
      assert_equal :done, @handler.call(task, @api)
    end
    assert_equal 'done', status_at_send, 'stem URLs must be in result before the Telegram send'
    assert_equal 1, @api.media_groups.size
    group = @api.media_groups.first
    assert_equal ['Демо (Vocals)', 'Демо (Instrumental)'], group.map { |m| m['title'] }
    assert_match(/вокал и минус/, group.first['caption'])
    bodies = Message.where(chat_id: CHAT, role: 'bot').pluck(:body)
    assert_includes bodies, '[стем: Демо — Vocals]'
    assert_includes bodies, '[стем: Демо — Instrumental]'
    assert_empty events, 'full delivery emits no event'
  end

  def test_twelve_stems_are_split_into_groups_of_at_most_ten
    task = make_task(external_id: 'sep-1', type: 'split_stem', mode: 'stems', audio_url: 'https://example.com/a.mp3')
    result = { stems: stems(12) } # built here: stub lambdas run with the stub as self
    with_client(poll_separation_once: ->(_id) { result }) do
      @handler.call(task, @api)
    end
    assert_equal [10, 2], @api.media_groups.map(&:size)
    assert @api.media_groups[0].first.key?('caption'), 'caption on the first stem of the first group'
    refute @api.media_groups[1].first.key?('caption'), 'no repeated caption on later groups'
  end

  def test_send_failure_after_done_keeps_task_done_and_reports
    task = make_task(external_id: 'sep-1', audio_url: 'https://example.com/a.mp3')
    @api.on_media_group = ->(_kw) { raise 'Telegram exploded' }
    result = { stems: stems(2) }
    with_client(poll_separation_once: ->(_id) { result }) do
      assert_equal :done, @handler.call(task, @api)
    end
    assert_equal 'done', fresh(task).status, 'a delivery failure must not flip :done to :failed'
    ev = events.last
    assert_equal 'separation_delivery_failed', ev['event_type']
    assert_match(/Stem1, Stem2/, ev['summary'])
    assert_match(/отправить их в чат не вышло/, @api.sent_messages.last[:text])
  end

  def test_partial_delivery_reports_only_missing_stems
    task = make_task(external_id: 'sep-1', audio_url: 'https://example.com/a.mp3')
    result = { stems: [{ name: 'Vocals', url: 'https://cdn/v.mp3' }, { name: 'Instrumental', url: 'https://cdn/broken.mp3' }] }
    with_client(poll_separation_once: ->(_id) { result }) do
      @handler.call(task, @api)
    end
    assert_equal 1, @api.media_groups.first.size
    ev = events.last
    assert_equal 'separation_delivery_failed', ev['event_type']
    assert_match(/не доставлены дорожки Instrumental/, ev['summary'])
    assert_match(/доставлены: Vocals/, ev['summary'])
    assert_empty @api.sent_messages, 'no "nothing arrived" chat notice when some stems were delivered'
  end
end

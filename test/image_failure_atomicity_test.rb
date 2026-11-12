require_relative 'test_helper'
require_relative '../lib/agent/error_reporter'
require_relative '../lib/chat_context'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/task_handlers/image_gen_handler'
require_relative '../lib/task_handlers/agent_event_handler'
require_relative '../lib/task_handlers/failure_notice_handler'
require 'tmpdir'
require 'fileutils'
require 'ostruct'
require 'telegram/bot'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

class ImageFailureAtomicityTest < BotTest
  CHAT = -78_901

  def setup
    super
    @task = BackgroundTask.create!(
      task_type: 'image_generate', chat_id: CHAT, max_attempts: 60,
      lifecycle_phase: 'processing',
      params: { request: 'draw a test image', forum_thread_id: 24 }.to_json
    )
    @handler = ImageGenTaskHandler.new
  end

  def fail_parent(**options)
    @handler.send(:mark_failed_and_notify, @task, nil, 'submit_rejected', **options)
  end

  def test_parent_failure_and_agent_event_commit_together_and_are_duplicate_safe
    fail_parent(provider_reason: 'provider refused the request')

    parent = BackgroundTask.find(@task.id)
    event = BackgroundTask.find_by(task_type: 'agent_event', parent_task_id: @task.id)
    assert_equal 'failed', parent.status
    assert_equal 'failed', parent.lifecycle_phase
    assert_equal({ 'error' => 'submit_rejected', 'failure_stage' => 'submit',
                   'failure_reason' => 'provider_rejected' }, parent.result_hash)
    refute_nil event
    assert_equal 'submit', event.params_hash['failure_stage']
    assert_equal 'provider_rejected', event.params_hash['failure_reason']
    assert_equal 24, event.params_hash['forum_thread_id']

    # Simulate a worker restart/re-entry after the commit: the parent-keyed
    # event is the durable idempotency record, even after it has completed.
    fail_parent(provider_reason: 'provider refused the request')
    assert_equal 1, BackgroundTask.where(task_type: 'agent_event', parent_task_id: @task.id).count
    assert_equal 0, BackgroundTask.where(task_type: 'failure_notice', parent_task_id: @task.id).count
  end

  def test_event_insert_failure_falls_back_to_one_parent_keyed_notice_atomically
    @handler.define_singleton_method(:emit_agent_event) { |*_, **_| raise 'event table unavailable' }
    fail_parent(provider_reason: 'provider refused the request')

    parent = BackgroundTask.find(@task.id)
    notice = BackgroundTask.find_by(task_type: 'failure_notice', parent_task_id: @task.id)
    assert_equal 'failed', parent.status
    refute_nil notice
    assert_equal 'image_failed', notice.params_hash['event_type']
    assert_equal 'submit', notice.params_hash['failure_stage']
    assert_equal 'provider_rejected', notice.params_hash['failure_reason']
    assert_equal 24, notice.params_hash['forum_thread_id']

    # Any notice state is the idempotency key: a completed/failed notice must
    # not be replaced with a second user-facing message on task re-entry.
    notice.update!(status: 'done', lifecycle_phase: 'completed')
    fail_parent(provider_reason: 'provider refused the request')
    assert_equal 1, BackgroundTask.where(task_type: 'failure_notice', parent_task_id: @task.id).count
    assert_equal 'done', BackgroundTask.find(notice.id).status
  end

  def test_parent_failure_rolls_back_if_neither_notification_record_can_be_created
    @handler.define_singleton_method(:emit_agent_event) { |*_, **_| raise 'event insert unavailable' }
    @handler.define_singleton_method(:enqueue_failure_notice) { |*_, **_| raise 'notice insert unavailable' }

    assert_raises(BackgroundTask::NotificationTransitionPending) do
      fail_parent(provider_reason: 'provider refused the request')
    end
    parent = BackgroundTask.find(@task.id)
    assert_equal 'pending', parent.status
    assert_equal 'processing', parent.lifecycle_phase
    assert_empty BackgroundTask.where(parent_task_id: @task.id, task_type: %w[agent_event failure_notice])

    # After the store recovers, the same durable task can replay the terminal
    # transition and persist exactly one user notification record.
    ImageGenTaskHandler.new.send(:mark_failed_and_notify, parent, nil, 'submit_rejected',
                                provider_reason: 'provider refused the request')
    assert_equal 'failed', BackgroundTask.find(parent.id).status
    assert_equal 1, BackgroundTask.where(task_type: 'agent_event', parent_task_id: parent.id).count
  end
end

class ImageFailureTaskRunnerDeliveryTest < BotTest
  CHAT = -78_903

  class SequencedTelegram
    attr_reader :calls

    def initialize(outcomes)
      @outcomes = outcomes.dup
      @calls = []
    end

    def sendMessage(**params)
      @calls << params
      outcome = @outcomes.shift
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
  end

  def setup
    super
    @parent = BackgroundTask.create!(task_type: 'image_generate', status: 'failed',
                                    lifecycle_phase: 'failed', chat_id: CHAT,
                                    max_attempts: 60, params: '{}')
  end

  def event(max_attempts: 5, forum_thread_id: 73)
    BackgroundTask.create!(
      task_type: 'agent_event', chat_id: CHAT, parent_task_id: @parent.id,
      max_attempts: max_attempts,
      params: {
        event_type: 'image_failed', parent_task_id: @parent.id,
        parent_task_type: 'image_generate', failure_stage: 'submit',
        failure_reason: 'provider_rejected', forum_thread_id: forum_thread_id,
      }.to_json
    )
  end

  def wrapped_exception(error, cause)
    begin
      raise cause
    rescue
      begin
        raise error
      rescue StandardError => wrapped
        wrapped
      end
    end
  end

  def telegram_response_error(code)
    response = OpenStruct.new(
      body: { error_code: code, description: 'simulated error' }.to_json,
      status: code,
      env: OpenStruct.new(url: 'https://api.telegram.org/botTOKEN/sendMessage')
    )
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  def test_read_timeout_and_429_retry_the_cached_notice_then_persist_once
    [Net::ReadTimeout.new('Telegram read timeout'),
     RuntimeError.new('Telegram 429 Too Many Requests: retry later')].each do |transient|
      task = event
      messages_before = Message.where(chat_id: CHAT, role: 'bot').count
      api = SequencedTelegram.new([transient, OpenStruct.new(message_id: task.id + 1000,
                                                             message_thread_id: 73)])
      runner = TaskRunner.new(api)

      runner.process_one(task.id)
      pending = BackgroundTask.find(task.id)
      assert_equal 'pending', pending.status, "after #{transient.class}: #{transient.message}; phase=#{pending.lifecycle_phase} result=#{pending.result}"
      assert_equal 'retrying', pending.lifecycle_phase
      assert_equal 1, pending.attempts
      assert_equal 1, pending.retry_count
      cached = pending.params_hash['reply_text']
      assert_equal ImageFailureNotice.render(
        event_type: 'image_failed', parent_task_id: @parent.id,
        stage: 'submit', reason: 'provider_rejected'
      ), cached

      runner.process_one(task.id)
      complete = BackgroundTask.find(task.id)
      assert_equal 'done', complete.status
      assert_equal 'delivered', complete.delivery_status
      assert_equal 2, api.calls.length
      assert api.calls.all? { |call| call[:text] == cached && call[:message_thread_id] == 73 }
      assert_equal messages_before + 1,
                   Message.where(chat_id: CHAT, role: 'bot', body: cached).count
    end
  end

  def test_real_faraday_and_telegram_errors_retry_through_task_runner
    errors = [Faraday::TimeoutError.new('read timed out'),
              Faraday::ConnectionFailed.new('connection reset'),
              Faraday::SSLError.new('TLS handshake failed'),
              wrapped_exception(RuntimeError.new('telegram wrapper'),
                                Faraday::SSLError.new(Net::WriteTimeout.new('write timed out'))),
              begin
                JSON.parse('{"ok":true,"result":')
              rescue JSON::ParserError => e
                e
              end,
              telegram_response_error(429), telegram_response_error(503)]

    errors.each do |error|
      task = event
      api = SequencedTelegram.new([error, OpenStruct.new(message_id: task.id + 2000,
                                                         message_thread_id: 73)])
      runner = TaskRunner.new(api)

      runner.process_one(task.id)
      retrying = BackgroundTask.find(task.id)
      assert_equal 'pending', retrying.status, error.class.name
      assert_equal 'retrying', retrying.lifecycle_phase, error.class.name
      assert_equal 1, retrying.attempts, error.class.name

      runner.process_one(task.id)
      assert_equal 'done', BackgroundTask.find(task.id).status, error.class.name
      assert_equal 2, api.calls.length, error.class.name
    end
  end

  def test_truncated_telegram_json_exhaustion_is_bounded_and_keeps_delivery_unknown
    task = event(max_attempts: 2)
    parser_error = begin
      JSON.parse('{"ok":true,"result":')
    rescue JSON::ParserError => e
      e
    end
    api = SequencedTelegram.new([parser_error, parser_error])
    runner = TaskRunner.new(api)

    runner.process_one(task.id)
    pending = BackgroundTask.find(task.id)
    assert_equal 'pending', pending.status
    assert_equal 'unknown', pending.delivery_status
    assert_equal 'retrying', pending.lifecycle_phase

    runner.process_one(task.id)
    exhausted = BackgroundTask.find(task.id)
    assert_equal 'failed', exhausted.status
    assert_equal 'unknown', exhausted.delivery_status,
                 'a truncated response cannot prove Telegram rejected the send'
    assert_equal 2, exhausted.attempts
    assert_equal 2, api.calls.length
    assert_equal 1, BackgroundTask.where(task_type: 'agent_event', parent_task_id: @parent.id).count
  end

  def test_ambiguous_agent_event_attempt_then_403_preserves_unknown_delivery
    task = event
    api = SequencedTelegram.new([Faraday::TimeoutError.new('read timeout'),
                                 telegram_response_error(403)])
    runner = TaskRunner.new(api)

    runner.process_one(task.id)
    ambiguous = BackgroundTask.find(task.id)
    assert_equal true, ambiguous.params_hash['delivery_ambiguous']
    assert_equal 'unknown', ambiguous.delivery_status

    runner.process_one(task.id)
    failed = BackgroundTask.find(task.id)
    assert_equal 'failed', failed.status
    assert_equal 'unknown', failed.delivery_status
    assert_equal true, failed.params_hash['delivery_ambiguous']
    assert_equal 2, api.calls.length
    assert_equal 1, BackgroundTask.where(task_type: 'agent_event', parent_task_id: @parent.id).count
  end

  def test_classifier_follows_nested_network_failure_causes
    [EOFError.new('eof'), Errno::EPIPE.new('pipe'), Errno::ETIMEDOUT.new('timed out'),
     Net::WriteTimeout.new('write timed out')].each do |deepest|
      error = wrapped_exception(RuntimeError.new('outer wrapper'),
                                Faraday::ConnectionFailed.new(deepest))
      assert TaskDeliveryErrors.retryable?(error), deepest.class.name
    end
  end

  def test_task_runner_classifies_real_transport_and_telegram_exceptions
    old_handler = TaskRunner.handler_for('delivery_error_fixture')
    errors = [Faraday::TimeoutError.new('read timed out'),
              Faraday::ConnectionFailed.new('connection reset'),
              Faraday::SSLError.new('TLS handshake failed'),
              telegram_response_error(429), telegram_response_error(503)]

    errors.each do |error|
      calls = 0
      handler = Object.new
      handler.define_singleton_method(:call) do |task, _api|
        calls += 1
        raise error if calls == 1
        task.mark_done!
        :done
      end
      handler_class = Object.new
      handler_class.define_singleton_method(:new) { handler }
      TaskRunner.register('delivery_error_fixture', handler_class)
      task = BackgroundTask.create!(task_type: 'delivery_error_fixture', chat_id: CHAT,
                                    max_attempts: 3, params: '{}')
      runner = TaskRunner.new(nil)

      runner.process_one(task.id)
      retrying = BackgroundTask.find(task.id)
      assert_equal 'pending', retrying.status, error.class.name
      assert_equal 'retrying', retrying.lifecycle_phase, error.class.name
      assert_equal 1, retrying.attempts, error.class.name
      assert_equal 1, retrying.retry_count, error.class.name

      runner.process_one(task.id)
      assert_equal 'done', BackgroundTask.find(task.id).status, error.class.name
    end

    handler = Object.new
    rejection = telegram_response_error(400)
    handler.define_singleton_method(:call) { |*_| raise rejection }
    handler_class = Object.new
    handler_class.define_singleton_method(:new) { handler }
    TaskRunner.register('delivery_error_fixture', handler_class)
    rejected = BackgroundTask.create!(task_type: 'delivery_error_fixture', chat_id: CHAT,
                                      max_attempts: 3, params: '{}')
    TaskRunner.new(nil).process_one(rejected.id)
    assert_equal 'failed', BackgroundTask.find(rejected.id).status
    assert_equal 1, BackgroundTask.find(rejected.id).attempts
  ensure
    TaskRunner.register('delivery_error_fixture', old_handler)
  end

  def test_failure_notice_transport_exhaustion_keeps_delivery_unknown
    task = BackgroundTask.create!(task_type: 'failure_notice', chat_id: CHAT,
                                  parent_task_id: @parent.id, max_attempts: 3,
                                  params: { text: 'A deterministic notice',
                                            parent_task_id: @parent.id }.to_json)
    api = SequencedTelegram.new(Array.new(3) do
      wrapped_exception(RuntimeError.new('Telegram wrapper'),
                        Faraday::ConnectionFailed.new(Errno::EPIPE.new('connection reset')))
    end)
    runner = TaskRunner.new(api)

    3.times { runner.process_one(task.id) }

    failed = BackgroundTask.find(task.id)
    assert_equal 'failed', failed.status
    assert_equal 'unknown', failed.delivery_status
    assert_equal 3, failed.attempts
    assert_equal 3, api.calls.length
    refute Message.exists?(chat_id: CHAT, role: 'bot')
  end

  def test_failure_notice_uses_telegram_error_code_for_retry_and_definitive_rejection
    retry_task = BackgroundTask.create!(task_type: 'failure_notice', chat_id: CHAT,
                                        parent_task_id: @parent.id, max_attempts: 3,
                                        params: { text: 'A deterministic notice',
                                                  parent_task_id: @parent.id }.to_json)
    api = SequencedTelegram.new([telegram_response_error(429),
                                 OpenStruct.new(message_id: retry_task.id + 3000)])
    runner = TaskRunner.new(api)
    runner.process_one(retry_task.id)
    assert_equal 'pending', BackgroundTask.find(retry_task.id).status
    runner.process_one(retry_task.id)
    assert_equal 'done', BackgroundTask.find(retry_task.id).status
    assert_equal 2, api.calls.length

    rejected = BackgroundTask.create!(task_type: 'failure_notice', chat_id: CHAT,
                                      parent_task_id: @parent.id, max_attempts: 3,
                                      params: { text: 'A deterministic notice',
                                                parent_task_id: @parent.id }.to_json)
    bad_api = SequencedTelegram.new([telegram_response_error(400)])
    TaskRunner.new(bad_api).process_one(rejected.id)
    failed = BackgroundTask.find(rejected.id)
    assert_equal 'failed', failed.status
    assert_equal 'failed', failed.delivery_status
    assert_equal 1, failed.attempts
    assert_equal 1, bad_api.calls.length
  end

  def test_permanent_telegram_rejection_fails_without_raw_timeout_or_runtime_event
    task = event
    api = SequencedTelegram.new([telegram_response_error(400)])

    TaskRunner.new(api).process_one(task.id)

    failed = BackgroundTask.find(task.id)
    assert_equal 'failed', failed.status
    assert_equal 'failed', failed.delivery_status
    assert failed.params_hash['reply_fallback']
    assert_equal ImageFailureNotice.render(
      event_type: 'image_failed', parent_task_id: @parent.id,
      stage: 'submit', reason: 'provider_rejected'
    ), failed.params_hash['reply_text']
    assert_equal 1, api.calls.length
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event',
                                         parent_task_id: task.id).count
    refute Message.exists?(chat_id: CHAT, role: 'bot')
  end

  def test_transient_image_notice_exhaustion_never_uses_task_runner_generic_notice
    task = event(max_attempts: 2)
    api = SequencedTelegram.new([Net::ReadTimeout.new('Telegram timed out'),
                                 Net::ReadTimeout.new('Telegram timed out')])
    runner = TaskRunner.new(api)

    2.times { runner.process_one(task.id) }

    failed = BackgroundTask.find(task.id)
    assert_equal 'failed', failed.status
    assert_equal 'unknown', failed.delivery_status
    assert_equal 2, failed.attempts
    assert_equal 2, api.calls.length
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, task_type: 'agent_event').count
    refute Message.exists?(chat_id: CHAT, role: 'bot')
  end

  def test_notification_insert_failure_at_attempt_59_or_60_stays_recoverable
    old_handler = TaskRunner.handler_for('image_generate')
    [59, 60].each do |attempts|
      parent = BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT,
                                      status: 'pending', lifecycle_phase: 'processing',
                                      attempts: attempts, max_attempts: 60,
                                      params: { request: 'failed draw' }.to_json)
      broken = ImageGenTaskHandler.new
      provider_calls = 0
      broken.define_singleton_method(:compose_and_submit) do |*_|
        provider_calls += 1
        :pending
      end
      broken.define_singleton_method(:emit_agent_event) { |*_, **_| raise 'event insert unavailable' }
      broken.define_singleton_method(:enqueue_failure_notice) { |*_, **_| raise 'notice insert unavailable' }
      broken_class = Object.new
      broken_class.define_singleton_method(:new) { broken }
      TaskRunner.register('image_generate', broken_class)

      TaskRunner.new(nil).process_one(parent.id)
      pending = BackgroundTask.find(parent.id)
      assert_equal 'pending', pending.status
      assert_equal attempts, pending.attempts
      assert_equal 'retrying', pending.lifecycle_phase
      assert_equal 1, provider_calls
      assert_equal 'submit_timeout', pending.params_hash.dig('terminal_failure_transition', 'reason')
      assert_empty BackgroundTask.where(parent_task_id: parent.id,
                                        task_type: %w[agent_event failure_notice])

      recovered = ImageGenTaskHandler.new
      recovered_class = Object.new
      recovered_class.define_singleton_method(:new) { recovered }
      TaskRunner.register('image_generate', recovered_class)
      TaskRunner.new(nil).process_one(parent.id)

      assert_equal 'failed', BackgroundTask.find(parent.id).status
      assert_equal 1, provider_calls, 'recovery must resume only the parent+notice transition'
      assert_equal 1, BackgroundTask.where(parent_task_id: parent.id,
                                           task_type: 'agent_event').count
      assert_equal 0, BackgroundTask.where(parent_task_id: parent.id,
                                           task_type: 'failure_notice').count
    end
  ensure
    TaskRunner.register('image_generate', old_handler) if old_handler
  end
end

class ImageFailureConcurrentAtomicityTest < Minitest::Test
  CHAT = -78_902

  def setup
    @tmpdir = Dir.mktmpdir('image-failure')
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: File.join(@tmpdir, 'tasks.sqlite3'),
                                            pool: 5, timeout: 5_000)
    ActiveRecord::MigrationContext.new(File.expand_path('../db/migrate', __dir__)).migrate
    @task = BackgroundTask.create!(
      task_type: 'image_generate', chat_id: CHAT, max_attempts: 60,
      lifecycle_phase: 'processing',
      params: { request: 'concurrent failure', forum_thread_id: 25 }.to_json
    )
  end

  def teardown
    ActiveRecord::Base.connection_pool.disconnect!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::MigrationContext.new(File.expand_path('../db/migrate', __dir__)).migrate
  end

  def test_competing_terminal_failure_paths_create_exactly_one_parent_notice
    ready = Queue.new
    go = Queue.new
    outcomes = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          task = BackgroundTask.find(@task.id)
          ready << true
          go.pop
          ImageGenTaskHandler.new.send(:mark_failed_and_notify, task, nil, 'submit_rejected',
                                      provider_reason: 'provider refused the request')
          outcomes << :ok
        end
      rescue => e
        outcomes << e
      end
    end
    2.times { ready.pop }
    2.times { go << true }
    workers.each(&:join)

    assert_equal %i[ok ok], 2.times.map { outcomes.pop }.sort_by(&:to_s)
    assert_equal 'failed', BackgroundTask.find(@task.id).status
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: %w[agent_event failure_notice]).count
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: 'agent_event').count
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: 'failure_notice').count
  end

  def test_stale_failure_workers_preserve_winning_checkpoint_and_scrubbed_provider_result
    private_url = 'https://provider.example/result?token=SIGNED_PROVIDER_SECRET_123456'
    @task.update!(params: { request: 'stale worker race', prompt: 'race prompt',
                            delivery_result: { url: private_url } }.to_json)
    ready = Queue.new
    start_first = Queue.new
    start_second = Queue.new
    checkpoint_saved = Queue.new
    resume_first = Queue.new
    outcomes = Queue.new
    first_handler = ImageGenTaskHandler.new
    original_checkpoint = ImageGenTaskHandler.instance_method(:persist_or_read_terminal_failure_transition)
    first_handler.define_singleton_method(:persist_or_read_terminal_failure_transition) do |*args, **kwargs|
      winner = original_checkpoint.bind(self).call(*args, **kwargs)
      checkpoint_saved << winner
      resume_first.pop
      winner
    end
    workers = [
      ['submit_rejected', 'first worker provider rejection', first_handler, start_first],
      ['poll_timeout', 'stale worker timeout', ImageGenTaskHandler.new, start_second],
    ].map do |reason, detail, handler, gate|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          stale_task = BackgroundTask.find(@task.id)
          ready << true
          gate.pop
          handler.send(:mark_failed_and_notify, stale_task, nil, reason, provider_reason: detail)
          outcomes << :ok
        end
      rescue => error
        outcomes << error
      end
    end
    2.times { ready.pop }
    start_first << true
    checkpoint = checkpoint_saved.pop
    assert_equal 'submit_rejected', checkpoint['reason']
    start_second << true
    workers.last.join
    resume_first << true
    workers.each(&:join)

    assert_equal %i[ok ok], 2.times.map { outcomes.pop }.sort_by(&:to_s)
    parent = BackgroundTask.find(@task.id)
    transition = parent.params_hash.fetch('terminal_failure_transition')
    event = BackgroundTask.find_by(task_type: 'agent_event', parent_task_id: @task.id)
    assert_equal 'failed', parent.status
    assert_equal 'submit_rejected', transition['reason']
    assert_equal transition['reason'], parent.result_hash['error']
    assert_equal transition['failure_stage'], event.params_hash['failure_stage']
    assert_equal transition['failure_reason'], event.params_hash['failure_reason']
    assert_equal '[url]', parent.params_hash.dig('delivery_result', 'url')
    refute_includes parent.params, 'SIGNED_PROVIDER_SECRET_123456'
    assert_equal 1, BackgroundTask.where(parent_task_id: @task.id,
                                         task_type: %w[agent_event failure_notice]).count
  end

  def test_competing_suppressed_event_paths_create_exactly_one_fallback_notice
    ready = Queue.new
    go = Queue.new
    outcomes = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          task = BackgroundTask.find(@task.id)
          handler = ImageGenTaskHandler.new
          handler.define_singleton_method(:emit_agent_event) { |*_, **_| nil }
          ready << true
          go.pop
          handler.send(:mark_failed_and_notify, task, nil, 'submit_rejected',
                       provider_reason: 'provider refused the request')
          outcomes << :ok
        end
      rescue => e
        outcomes << e
      end
    end
    2.times { ready.pop }
    2.times { go << true }
    workers.each(&:join)

    assert_equal %i[ok ok], 2.times.map { outcomes.pop }.sort_by(&:to_s)
    assert_equal 'failed', BackgroundTask.find(@task.id).status
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: %w[agent_event failure_notice]).count
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: 'agent_event').count
    assert_equal 1, BackgroundTask.where(chat_id: CHAT, parent_task_id: @task.id,
                                         task_type: 'failure_notice').count
  end

  def test_attempt_59_restart_replays_failure_transition_without_resubmitting
    @task.update!(status: 'pending', lifecycle_phase: 'processing', attempts: 59,
                  max_attempts: 60, params: { request: 'restart recovery' }.to_json)
    old_handler = TaskRunner.handler_for('image_generate')
    provider_calls = 0
    broken = ImageGenTaskHandler.new
    broken.define_singleton_method(:compose_and_submit) do |*_|
      provider_calls += 1
      :pending
    end
    broken.define_singleton_method(:emit_agent_event) { |*_, **_| raise 'event insert unavailable' }
    broken.define_singleton_method(:enqueue_failure_notice) { |*_, **_| raise 'notice insert unavailable' }
    broken_class = Object.new
    broken_class.define_singleton_method(:new) { broken }
    TaskRunner.register('image_generate', broken_class)

    TaskRunner.new(nil).process_one(@task.id)
    pending = BackgroundTask.find(@task.id)
    assert_equal 'pending', pending.status
    assert_equal 59, pending.attempts
    assert_equal 'submit_timeout', pending.params_hash.dig('terminal_failure_transition', 'reason')
    assert_equal 1, provider_calls

    # Reconnect to the file-backed DB and use a fresh handler/runner, as after
    # a process restart. The durable terminal checkpoint must win before the
    # compose/submit path even at the attempt boundary.
    ActiveRecord::Base.connection_pool.disconnect!
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3',
                                            database: File.join(@tmpdir, 'tasks.sqlite3'),
                                            pool: 5, timeout: 5_000)
    TaskRunner.register('image_generate', ImageGenTaskHandler)
    TaskRunner.new(nil).process_one(@task.id)

    assert_equal 'failed', BackgroundTask.find(@task.id).status
    assert_equal 1, provider_calls
    assert_equal 1, BackgroundTask.where(parent_task_id: @task.id,
                                         task_type: 'agent_event').count
    assert_equal 0, BackgroundTask.where(parent_task_id: @task.id,
                                         task_type: 'failure_notice').count
  ensure
    TaskRunner.register('image_generate', old_handler) if old_handler
  end

  def test_attempt_59_checkpoint_write_failure_is_bounded_and_not_misclassified_as_pending_transition
    @task.update!(status: 'pending', lifecycle_phase: 'processing', attempts: 59,
                  max_attempts: 60, params: { request: 'checkpoint write failure' }.to_json)
    old_handler = TaskRunner.handler_for('image_generate')
    calls = 0
    handler = ImageGenTaskHandler.new
    handler.define_singleton_method(:persist_or_read_terminal_failure_transition) do |*_args, **_kwargs|
      raise ActiveRecord::StatementInvalid, 'terminal checkpoint write rejected'
    end
    handler.define_singleton_method(:call) do |task, api|
      calls += 1
      send(:mark_failed_and_notify, task, api, 'submit_timeout')
    end
    handler_class = Object.new
    handler_class.define_singleton_method(:new) { handler }
    TaskRunner.register('image_generate', handler_class)

    runner = TaskRunner.new(nil)
    runner.process_one(@task.id)
    failed = BackgroundTask.find(@task.id)
    assert_equal 60, failed.attempts
    assert_equal 'failed', failed.status
    assert_equal 'terminal checkpoint write rejected', failed.result_hash['error']
    assert_equal 1, calls

    runner.process_one(@task.id)
    assert_equal 1, calls, 'a failed task is not redispatched after its bounded attempt is spent'
  ensure
    TaskRunner.register('image_generate', old_handler) if old_handler
  end
end

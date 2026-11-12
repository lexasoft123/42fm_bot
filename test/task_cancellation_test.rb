require_relative 'test_helper'
require_relative '../lib/task_cancellation'
require_relative '../lib/task_runner'
require_relative '../lib/agent/tool_result'
require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tools/task_status'
require_relative '../lib/agent/tools/cancel_task'
require_relative '../lib/task_handlers/image_failure_notice'
require 'tmpdir'
require 'fileutils'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

class TaskCancellationTest < BotTest
  CHAT = -77_001
  USER = 77_002

  def setup
    super
  end

  def create_image(phase: 'queued', user_id: USER, chat_id: CHAT, topic: 12)
    BackgroundTask.create!(
      task_type: 'image_generate', chat_id: chat_id,
      lifecycle_phase: phase, params: { origin_user_id: user_id, forum_thread_id: topic }.to_json
    )
  end

  def test_cancel_is_owned_scoped_idempotent_and_pre_start_only
    task = create_image
    args = { task_id: task.id, chat_id: CHAT, user_id: USER, forum_thread_id: 12 }
    assert_equal :cancelled, TaskCancellation.cancel(**args)[:status]
    assert_equal :cancelled, TaskCancellation.cancel(**args)[:status]
    stored = BackgroundTask.find(task.id)
    assert_equal 'cancelled', stored.status
    assert_equal 'cancelled', stored.lifecycle_phase

    assert_equal :unauthorized, TaskCancellation.cancel(**args.merge(user_id: USER + 1))[:status]
    assert_equal :unauthorized, TaskCancellation.cancel(**args.merge(forum_thread_id: 13))[:status]
    assert_equal :not_found, TaskCancellation.cancel(**args.merge(chat_id: CHAT - 1))[:status]

    started = create_image(phase: 'processing')
    assert_equal :started, TaskCancellation.cancel(**args.merge(task_id: started.id))[:status]
  end

  def test_legacy_task_without_owner_is_not_cancellable
    legacy = BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, params: '{}')
    result = TaskCancellation.cancel(task_id: legacy.id, chat_id: CHAT,
                                     user_id: USER, forum_thread_id: nil)
    assert_equal :unauthorized, result[:status]
  end

  def test_task_runner_skips_stale_row_after_cancellation_wins
    task = create_image
    stale = BackgroundTask.find(task.id)
    called = false
    callback = -> { called = true }
    handler_class = Object.new
    handler_class.define_singleton_method(:new) do
      Object.new.tap { |instance| instance.define_singleton_method(:call) { |*_args| callback.call; :done } }
    end
    old_handler = TaskRunner.handler_for('image_generate')
    TaskRunner.register('image_generate', handler_class)
    TaskCancellation.cancel(task_id: task.id, chat_id: CHAT, user_id: USER, forum_thread_id: 12)

    TaskRunner.new(nil).process_one(stale)

    refute called
    assert_equal 'cancelled', BackgroundTask.find(task.id).status
  ensure
    TaskRunner.register('image_generate', old_handler) if old_handler
  end

  def test_task_runner_preserves_dispatchable_lifecycle_phases_across_poll_cycles
    %w[processing retrying delivering persisting_delivery].each do |phase|
      task = create_image(phase: phase)
      observed = []
      handler_class = Class.new do
        define_method(:initialize) { |seen| @seen = seen }
        define_method(:call) do |row, _api|
          @seen << row.lifecycle_phase
          :pending
        end
      end
      callback_handler = Object.new
      callback_handler.define_singleton_method(:new) { handler_class.new(observed) }
      old_handler = TaskRunner.handler_for('image_generate')
      TaskRunner.register('image_generate', callback_handler)

      TaskRunner.new(nil).process_one(task)

      assert_equal [phase], observed
      assert_equal phase, BackgroundTask.find(task.id).lifecycle_phase
    ensure
      TaskRunner.register('image_generate', old_handler) if old_handler
    end
  end

  def test_cancelled_status_is_rendered_as_terminal_typed_state
    task = create_image
    TaskCancellation.cancel(task_id: task.id, chat_id: CHAT, user_id: USER, forum_thread_id: 12)
    snapshot = Agent::TaskStatus.snapshot(chat_id: CHAT, task_id: task.id)
    assert_equal 'cancelled', snapshot.dig(:tasks, 0, :phase)
    result = Agent::TaskStatus.action_result(snapshot)
    assert_equal 'cancelled', result.action_status
    assert_equal 'cancelled', result.phase
    assert_equal "Задача ##{task.id}: отменена до начала работы.", result.display_text
    assert_equal result.display_text, result.action_payload[:message]
  end

  def test_status_result_has_deterministic_correlated_display_text
    task = create_image
    task.claim_start!
    snapshot = Agent::TaskStatus.snapshot(chat_id: CHAT, task_id: task.id)
    result = Agent::TaskStatus.action_result(snapshot)

    assert_equal "Задача ##{task.id}: выполняется.", result.display_text
    assert_equal result.display_text, result.action_payload[:message]
    assert_equal 'processing', result.phase
    assert_equal task.id, result.task_id

    missing = Agent::TaskStatus.action_result(
      Agent::TaskStatus.snapshot(chat_id: CHAT, task_id: task.id + 100)
    )
    assert_equal "Задачу ##{task.id + 100} в этом чате не нашёл.", missing.display_text
  end

  def test_recent_status_batch_display_names_each_task_and_keeps_unknown_outer_evidence
    first = create_image
    second = create_image(phase: 'processing')
    snapshot = Agent::TaskStatus.snapshot(chat_id: CHAT)
    result = Agent::TaskStatus.action_result(snapshot)

    assert_includes result.display_text, "Задача ##{first.id}: стоит в очереди."
    assert_includes result.display_text, "Задача ##{second.id}: выполняется."
    assert_equal 'deferred', result.action_status
    assert_equal 'unknown', result.delivery
    assert_equal 2, result.items.length
  end

  def test_image_failure_text_uses_only_allowlisted_fields_and_includes_task_and_next_step
    text = ImageFailureNotice.render(
      event_type: 'image_failed', parent_task_id: 5134,
      stage: 'submit', reason: 'model_source_conflict'
    )
    assert_includes text, '#5134'
    assert_includes text, 'модель не принимает несколько исходных изображений'
    assert_includes text, 'Выберите модель для нескольких изображений или оставьте один исходник.'
    refute_includes text, 'submit'

    unavailable = ImageFailureNotice.render(
      event_type: 'image_failed', parent_task_id: 9,
      stage: 'poll', reason: 'edit_sources_unavailable'
    )
    assert_includes unavailable, 'Пришлите изображение ещё раз'

    delivery = ImageFailureNotice.render(
      event_type: 'image_delivery_failed', parent_task_id: 10,
      stage: 'delivery', reason: 'telegram_failed'
    )
    assert_includes delivery, 'запустит новую генерацию'
    refute_match(/отправить уже созданную картинку ещё раз/, delivery)
  end

  def test_agent_cancel_tool_uses_same_owned_scoped_cancellation
    task = create_image
    user = Struct.new(:uid).new(USER)
    result = Agent::ToolRegistry.find('cancel_task').handler.call(
      { 'task_id' => task.id },
      { chat_id: CHAT, user: user, forum_thread_id: 12, user_initiated: true,
        request_text: "бот отмени задачу ##{task.id}" }
    )

    assert_equal 'cancelled', result.action_status
    assert_equal 'cancelled', result.phase
    assert_equal task.id, result.task_id
    assert_equal 'cancelled', BackgroundTask.find(task.id).status
  end

  def test_cancel_tool_rejects_fabricated_mismatched_and_negated_calls_without_task_evidence
    task = create_image
    tool = Agent::ToolRegistry.find('cancel_task')
    user = Struct.new(:uid).new(USER)
    attempts = [
      { user_initiated: true, request_text: "бот, каков статус задачи ##{task.id}?" },
      { user_initiated: true, request_text: "бот отмени задачу ##{task.id + 1}" },
      { user_initiated: true, request_text: "бот не отменяй задачу ##{task.id}" },
      { user_initiated: false, request_text: "бот отмени задачу ##{task.id}" },
    ]

    attempts.each do |turn|
      result = tool.handler.call(
        { 'task_id' => task.id },
        { chat_id: CHAT, user: user, forum_thread_id: 12 }.merge(turn)
      )
      assert_instance_of String, result
      refute_equal true, result.respond_to?(:action?) && result.action?
      assert_equal 'pending', BackgroundTask.find(task.id).status
      assert_equal 'queued', BackgroundTask.find(task.id).lifecycle_phase
    end
  end

  def test_cancel_tool_rejects_reply_without_explicit_task_id_even_for_bot_ack_text
    task = create_image
    Message.create!(chat_id: CHAT, role: 'bot', body: "Задача ##{task.id} поставлена в очередь.",
                    message_id: 509, message_thread_id: 12)
    user = Struct.new(:uid).new(USER)
    result = Agent::ToolRegistry.find('cancel_task').handler.call(
      { 'task_id' => task.id },
      { chat_id: CHAT, user: user, forum_thread_id: 12, user_initiated: true,
        request_text: 'бот отмени', reply_to_message_id: 509 }
    )
    assert_instance_of String, result
    refute result.respond_to?(:action?)
    assert_equal 'pending', BackgroundTask.find(task.id).status
    assert_equal 'queued', BackgroundTask.find(task.id).lifecycle_phase
  end

  def test_cancel_tool_reply_requires_bare_imperative
    task = create_image
    Message.create!(chat_id: CHAT, role: 'bot', body: "Задача ##{task.id} поставлена в очередь.",
                    message_id: 510, message_thread_id: 12)
    tool = Agent::ToolRegistry.find('cancel_task')
    user = Struct.new(:uid).new(USER)

    ['отмени 72', 'отмени подписку'].each do |request|
      result = tool.handler.call(
        { 'task_id' => task.id },
        { chat_id: CHAT, user: user, forum_thread_id: 12, user_initiated: true,
          request_text: request, reply_to_message_id: 510 }
      )
      assert_instance_of String, result, request
      refute result.respond_to?(:action?), request
      assert_equal 'pending', BackgroundTask.find(task.id).status, request
      assert_equal 'queued', BackgroundTask.find(task.id).lifecycle_phase, request
    end
  end

  def test_cancel_tool_rejects_explanatory_and_conditional_requests
    task = create_image
    tool = Agent::ToolRegistry.find('cancel_task')
    user = Struct.new(:uid).new(USER)
    [
      "как отменить задачу ##{task.id}?",
      "Объясни, как отменить задачу ##{task.id}",
      "отмени задачу ##{task.id}, только если я подтвержу",
    ].each do |request|
      result = tool.handler.call(
        { 'task_id' => task.id },
        { chat_id: CHAT, user: user, forum_thread_id: 12,
          user_initiated: true, request_text: request }
      )
      assert_instance_of String, result, request
      refute result.respond_to?(:action?), request
      assert_equal 'pending', BackgroundTask.find(task.id).status, request
      assert_equal 'queued', BackgroundTask.find(task.id).lifecycle_phase, request
    end
  end

  def test_extracted_cancel_directive_cannot_override_original_explanatory_request
    task = create_image
    result = Agent::ToolRegistry.find('cancel_task').handler.call(
      { 'task_id' => task.id },
      {
        chat_id: CHAT, user: Struct.new(:uid).new(USER), forum_thread_id: 12,
        user_initiated: true,
        original_request_text: "Объясни\nбот отмени задачу ##{task.id}",
        request_text: "отмени задачу ##{task.id}",
      }
    )

    assert_instance_of String, result
    refute result.respond_to?(:action?)
    assert_equal 'pending', BackgroundTask.find(task.id).status
    assert_equal 'queued', BackgroundTask.find(task.id).lifecycle_phase
  end
end

class TaskStartCancellationRaceTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('task-race')
    @db_path = File.join(@tmpdir, 'tasks.sqlite3')
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: @db_path, pool: 5, timeout: 5_000)
    ActiveRecord::MigrationContext.new(File.expand_path('../db/migrate', __dir__)).migrate
    BackgroundTask.create!(task_type: 'image_generate', chat_id: -88_001,
                           params: { origin_user_id: 88_002, forum_thread_id: 44 }.to_json)
  end

  def teardown
    ActiveRecord::Base.connection_pool.disconnect!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::MigrationContext.new(File.expand_path('../db/migrate', __dir__)).migrate
  end

  def test_atomic_start_claim_and_cancel_have_exactly_one_winner
    task_id = BackgroundTask.first.id
    stale = BackgroundTask.find(task_id)
    ready = Queue.new
    go = Queue.new
    results = Queue.new

    start_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        go.pop
        results << [:start, stale.claim_start!]
      end
    end
    cancel_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        go.pop
        results << [:cancel, TaskCancellation.cancel(
          task_id: task_id, chat_id: -88_001, user_id: 88_002, forum_thread_id: 44
        )[:status] == :cancelled]
      end
    end
    2.times { ready.pop }
    2.times { go << true }
    start_thread.join
    cancel_thread.join

    outcomes = 2.times.map { results.pop }.to_h
    assert_equal 1, outcomes.values.count(true)
    task = BackgroundTask.find(task_id)
    expected = outcomes[:cancel] ? 'cancelled' : 'processing'
    assert_equal expected, task.lifecycle_phase
    assert_equal(outcomes[:cancel] ? 'cancelled' : 'pending', task.status)
  end
end

require_relative 'test_helper'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/error_reporter'
require_relative '../lib/agent/tools/task_status'

class TaskStatusToolTest < BotTest
  CHAT = -42_001
  OTHER_CHAT = -42_002

  def setup
    super
    @tool = Agent::ToolRegistry.find('task_status')
  end

  def create_task(chat_id: CHAT, task_type: 'image_generate', status: 'pending', params: {},
                  result: {}, attempts: 0, external_id: nil, lifecycle_phase: nil,
                  delivery_status: 'unknown', retry_count: 0, parent_task_id: nil)
    lifecycle_phase ||= status == 'done' ? 'completed' : (status == 'failed' ? 'failed' : 'queued')
    BackgroundTask.create!(
      task_type: task_type, chat_id: chat_id, status: status,
      attempts: attempts, max_attempts: 60, external_id: external_id,
      lifecycle_phase: lifecycle_phase, delivery_status: delivery_status,
      retry_count: retry_count, parent_task_id: parent_task_id,
      params: params.to_json, result: result.to_json
    )
  end

  def call_result(args = {}, chat_id: CHAT)
    result = @tool.handler.call(args, { chat_id: chat_id })
    assert_instance_of Agent::ToolResult, result
    assert result.action?
    result
  end

  def call_tool(args = {}, chat_id: CHAT)
    JSON.parse(call_result(args, chat_id: chat_id).user_text)
  end

  def test_is_available_to_non_admin_users
    defs = Agent::ToolRegistry.definitions_for(user_role: 'member', api_type: 'openai')
    assert_includes defs.map { |d| d[:function][:name] }, 'task_status'
  end

  def test_task_id_is_strictly_scoped_to_current_chat
    own = create_task
    foreign = create_task(chat_id: OTHER_CHAT, params: { request: 'secret', delivery_result: { url: 'secret' } })

    own_result = call_result({ 'task_id' => own.id })
    own_payload = JSON.parse(own_result.user_text)
    assert_equal true, own_payload['found']
    assert_equal [own.id], own_payload['tasks'].map { |t| t['id'] }
    assert_equal own.id, own_result.task_id
    assert_equal 'image_generate', own_result.task_type
    assert_equal 'generate_image', own_result.action
    assert_equal 'queued', own_result.action_status
    assert_equal 'queued', own_result.phase

    foreign_result = call_result({ 'task_id' => foreign.id })
    foreign_payload = JSON.parse(foreign_result.user_text)
    assert_equal false, foreign_payload['found']
    assert_empty foreign_payload['tasks']
    assert_equal 'deferred', foreign_result.action_status
    assert_equal 'deferred', foreign_result.phase
    assert_equal 'unknown', foreign_result.delivery
    refute_includes foreign_payload.to_json, 'secret'
  end

  def test_explicit_task_id_requires_an_actual_positive_integer
    [nil, 'junk', '123', 0, -1, 1.5].each do |invalid|
      create_task
      result = call_result({ 'task_id' => invalid })
      payload = JSON.parse(result.user_text)
      assert_equal 'error', payload['status'], "task_id=#{invalid.inspect}"
      assert_equal 'invalid_task_id', payload['code']
      assert_equal false, payload['found']
      assert_empty payload['tasks'], 'invalid explicit id must never fall back to recent tasks'
      assert_equal 'deferred', result.action_status
      assert_equal 'deferred', result.phase
      assert_equal 'unknown', result.delivery
    end
  end

  def test_limit_requires_integer_and_clamps_to_safe_range
    7.times { create_task }

    assert_equal 1, call_tool({ 'limit' => -10 })['tasks'].size
    assert_equal Agent::TaskStatus::MAX_LIMIT, call_result({ 'limit' => 999 }).items.size

    ['2', 'abc', 1.5, nil].each do |invalid|
      payload = call_tool({ 'limit' => invalid })
      assert_equal 'error', payload['status'], "limit=#{invalid.inspect}"
      assert_equal 'invalid_limit', payload['code']
      assert_empty payload['tasks']
    end
  end

  def test_exposes_only_safe_lifecycle_metadata_and_explicit_retry_state
    task = create_task(
      params: {
        request: 'private prompt', delivery_receipt: { message_id: 99 },
        persistence_failures: 2, url: 'https://secret'
      },
      result: { error: 'private provider body' }, attempts: 3, external_id: 'provider-secret',
      lifecycle_phase: 'persisting_delivery', delivery_status: 'delivered', retry_count: 2
    )

    payload = call_tool({ 'task_id' => task.id })
    serialized = payload['tasks'].first
    assert_equal 'persisting_delivery', serialized['phase']
    assert_equal false, serialized['retrying']
    assert_equal 3, serialized['processing_cycles']
    assert_equal 'delivered', serialized['delivery']
    assert_equal 2, serialized['retry_count']
    assert_equal %w[delivery id max_processing_cycles phase processing_cycles retry_count retrying status type updated_at], serialized.keys.sort
    refute_match(/private prompt|provider-secret|secret|url|result|params/, payload.to_json)
  end

  def test_normal_provider_poll_cycles_are_processing_not_retrying
    task = create_task(attempts: 7, external_id: 'provider-job', lifecycle_phase: 'processing')

    serialized = call_tool({ 'task_id' => task.id })['tasks'].first
    assert_equal 'processing', serialized['phase']
    assert_equal false, serialized['retrying']
    assert_equal 7, serialized['processing_cycles']
  end

  def test_explicit_failure_counter_marks_pending_task_as_retrying
    task = create_task(attempts: 1, params: { generation_retries: 99 },
                       lifecycle_phase: 'retrying', retry_count: 1)

    serialized = call_tool({ 'task_id' => task.id })['tasks'].first
    assert_equal 'retrying', serialized['phase']
    assert_equal true, serialized['retrying']
    assert_equal 1, serialized['retry_count'], 'params counters are not parsed or trusted'
  end

  def test_pending_retry_never_projects_terminal_failed_delivery_or_action
    task = create_task(lifecycle_phase: 'retrying', delivery_status: 'failed', retry_count: 2)

    result = call_result({ 'task_id' => task.id })
    serialized = JSON.parse(result.user_text)['tasks'].first
    assert_equal 'pending', serialized['status']
    assert_equal 'retrying', serialized['phase']
    assert_equal true, serialized['retrying']
    assert_equal 'pending', serialized['delivery']
    assert_equal 'queued', result.action_status
    assert_equal 'retrying', result.phase
    assert_equal 'pending', result.delivery
  end

  def test_coarse_terminal_status_overrides_stale_lifecycle_phase
    task = create_task(status: 'failed', lifecycle_phase: 'retrying',
                       delivery_status: 'failed', retry_count: 3)

    result = call_result({ 'task_id' => task.id })
    serialized = JSON.parse(result.user_text)['tasks'].first
    assert_equal 'failed', serialized['phase']
    assert_equal false, serialized['retrying']
    assert_equal 'failed', serialized['delivery']
    assert_equal 'failed', result.action_status
  end

  def test_award_image_task_has_normal_image_provenance
    task = create_task(task_type: 'image_generate', params: { award: true },
                       lifecycle_phase: 'queued', delivery_status: 'pending')

    result = call_result({ 'task_id' => task.id })
    assert_equal 'generate_image', result.action
    assert_equal task.id, result.task_id
    assert_equal 'image_generate', result.task_type
    assert_equal 'queued', result.action_status
    assert_equal 'queued', result.phase
    assert_equal 'pending', result.delivery
  end

  def test_terminal_phases_do_not_generically_claim_delivery
    image = create_task(status: 'done', delivery_status: 'delivered')
    generic = create_task(task_type: 'agent_event', status: 'done')
    suno = create_task(task_type: 'suno_generate', status: 'done', external_id: 'suno-unknown')
    failed = create_task(status: 'failed')

    image_status = call_tool({ 'task_id' => image.id })['tasks'].first
    assert_equal 'completed', image_status['phase']
    assert_equal 'delivered', image_status['delivery']

    [generic, suno].each do |task|
      serialized = call_tool({ 'task_id' => task.id })['tasks'].first
      assert_equal 'completed', serialized['phase']
      assert_equal 'unknown', serialized['delivery']
    end

    assert_equal 'failed', call_tool({ 'task_id' => failed.id })['tasks'].first['phase']
  end

  def test_suno_done_reports_delivery_failed_when_linked_event_exists
    suno = create_task(task_type: 'suno_generate', status: 'done', external_id: 'sun-2011')
    Agent::ErrorReporter.emit(
      chat_id: CHAT, event_type: 'song_delivery_failed', parent_task: suno,
      summary: 'private failure detail', rate_limited: false
    )

    result = call_result({ 'task_id' => suno.id })
    serialized = JSON.parse(result.user_text)['tasks'].first
    assert_equal 'completed', serialized['phase']
    assert_equal 'failed', serialized['delivery']
    assert_equal 'failed', result.action_status
    assert_equal 'completed', result.phase
    refute_includes result.user_text, 'private failure detail'
  end

  def test_suno_done_reports_delivered_only_with_linked_message_evidence
    suno = create_task(task_type: 'suno_generate', status: 'done', external_id: 'sun-delivered',
                       delivery_status: 'delivered')
    Message.create!(chat_id: CHAT, role: 'bot', body: '[песня]', bg_task_external_id: 'sun-delivered')

    serialized = call_tool({ 'task_id' => suno.id })['tasks'].first
    assert_equal 'completed', serialized['phase']
    assert_equal 'delivered', serialized['delivery']
  end

  def test_large_inline_image_is_not_materialized_or_parsed_in_ruby
    task = create_task(params: { input_image: 'x' * (3 * 1024 * 1024), generation_retries: 99 },
                       lifecycle_phase: 'retrying', retry_count: 1)

    BackgroundTask.class_eval do
      alias_method :task_status_original_params_hash, :params_hash
      define_method(:params_hash) { raise 'task_status must not parse the full params blob' }
    end
    payload = call_tool({ 'task_id' => task.id })
    assert_equal 'retrying', payload['tasks'].first['phase']
    refute_includes payload.to_json, 'xxxx'
    projected = Agent::TaskStatus.snapshot(chat_id: CHAT, task_id: task.id)
    assert_equal 1, projected[:tasks].first[:retry_count]
  ensure
    if BackgroundTask.method_defined?(:task_status_original_params_hash)
      BackgroundTask.class_eval do
        alias_method :params_hash, :task_status_original_params_hash
        remove_method :task_status_original_params_hash
      end
    end
  end


  def test_recent_lookup_excludes_later_agent_events_and_internal_tasks
    image = create_task
    create_task(task_type: 'agent_event', parent_task_id: image.id,
                params: { event_type: 'runtime_error', parent_task_id: image.id })
    create_task(task_type: 'knowledge_review')

    result = call_result
    payload = JSON.parse(result.user_text)
    assert_equal [image.id], payload['tasks'].map { |task| task['id'] }
    assert_nil result.items, 'single recent task keeps the single-action evidence shape'
    assert_equal 'generate_image', result.action
  end

  def test_recent_lookup_returns_structured_evidence_for_each_user_task
    image = create_task
    song = create_task(task_type: 'suno_generate', lifecycle_phase: 'processing')

    result = call_result
    assert_equal 'task_status', result.action
    assert_equal [song.id, image.id], result.items.map { |item| item[:task_id] }
    assert_equal %w[compose_song generate_image], result.items.map { |item| item[:action] }
    assert_equal %w[suno_generate image_generate], result.items.map { |item| item[:task_type] }
    assert_equal %w[queued queued], result.items.map { |item| item[:status] }
  end

  def test_five_task_result_keeps_authoritative_items_under_runner_boundary
    5.times { |i| create_task(task_type: i.even? ? 'image_generate' : 'suno_generate') }
    result = call_result
    encoded = JSON.generate(result.action_payload)
    assert_equal 5, result.items.size
    assert_operator encoded.bytesize, :<, 2_000 # Agent::Runner::MAX_TOOL_RESULT_LENGTH
    refute_includes JSON.parse(result.user_text).keys, 'tasks'
    assert_equal 'deferred', result.action_status
    assert_equal 'deferred', result.phase
  end

  def test_persisting_receipt_is_not_reported_as_sent_before_completion
    task = create_task(lifecycle_phase: 'persisting_delivery', delivery_status: 'delivered')

    result = call_result({ 'task_id' => task.id })

    assert_equal 'queued', result.action_status
    assert_equal 'persisting_delivery', result.phase
    assert_equal 'delivered', result.delivery
  end

  def test_every_suno_task_type_maps_to_its_originating_action
    expected = {
      'suno_generate' => 'compose_song',
      'suno_add_vocals' => 'add_vocals',
      'suno_cover_audio' => 'cover_audio',
      'suno_cover_art' => 'cover_art',
      'suno_wav_convert' => 'convert_to_wav',
      'suno_separate_vocals' => 'separate_vocals',
    }

    expected.each do |task_type, action|
      task = create_task(task_type: task_type, delivery_status: 'pending')
      result = call_result({ 'task_id' => task.id })
      assert_equal action, result.action
      assert_equal task.id, result.task_id
      assert_equal task_type, result.task_type
      assert_equal 'pending', result.delivery
    end
  end

  def test_schema_has_compact_lifecycle_columns_and_lookup_indexes
    columns = BackgroundTask.column_names
    %w[lifecycle_phase delivery_status retry_count parent_task_id].each do |column|
      assert_includes columns, column
    end

    task_indexes = ActiveRecord::Base.connection.indexes(:background_tasks).map(&:name)
    message_indexes = ActiveRecord::Base.connection.indexes(:messages).map(&:name)
    %w[idx_tasks_chat_created idx_tasks_chat_parent idx_tasks_chat_type_created idx_tasks_chat_phase_created].each do |name|
      assert_includes task_indexes, name
    end
    assert_includes message_indexes, 'idx_messages_chat_bg_task'
  end

  def test_migration_backfills_legacy_event_parent_column
    parent = create_task(task_type: 'suno_generate', status: 'done')
    event = create_task(task_type: 'agent_event', parent_task_id: nil,
                        params: { event_type: 'song_delivery_failed', parent_task_id: parent.id })

    AddTaskLifecycleMetadata.new.backfill_lifecycle_columns

    assert_equal parent.id, event.reload.parent_task_id
    assert_equal 'failed', parent.reload.delivery_status
  end

  def test_migration_does_not_infer_multi_output_delivery_from_one_message
    song = create_task(task_type: 'suno_generate', status: 'done', external_id: 'multi-song')
    Message.create!(chat_id: CHAT, role: 'bot', body: '[песня 1/2]', bg_task_external_id: 'multi-song')

    AddTaskLifecycleMetadata.new.backfill_lifecycle_columns

    assert_equal 'unknown', song.reload.delivery_status
  end
end

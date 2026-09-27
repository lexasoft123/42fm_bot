require_relative 'test_helper'
require 'ostruct'

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/agent/tool_registry'
require_relative '../lib/task_runner'
require_relative '../lib/agent/tools/bot_state'

class BotStateToolTest < BotTest
  CHAT = -100_123
  OTHER_CHAT = -100_456

  def setup
    super
    @tool = Agent::ToolRegistry.find('inspect_bot_state')
    @claimed_ids = []
  end

  def teardown
    @claimed_ids.each { |id| TaskRunner.release(id) }
    super
  end

  def test_tool_is_admin_only
    admin_names = tool_names('admin')
    member_names = tool_names('member')

    assert_includes admin_names, 'inspect_bot_state'
    refute_includes member_names, 'inspect_bot_state'
  end

  def test_snapshot_reports_runner_queue_and_only_current_chat_details
    active = create_task(chat_id: CHAT, type: 'image_generate', status: 'pending',
                         params: { request: 'нарисуй кота', model: 'qwen-image-3-pro' })
    create_task(chat_id: CHAT, type: 'suno_generate', status: 'failed',
                result: { error: 'request failed https://secret.example/job/abc APIKEYABCDEFGHIJKLMNOPQRSTUVWXYZ123456' })
    other = create_task(chat_id: OTHER_CHAT, type: 'image_generate', status: 'pending',
                        params: { request: 'private request from another chat' })
    TaskRunner.claim(active.id)
    @claimed_ids << active.id

    payload = call_tool('view' => 'tasks')

    assert_equal 2, payload.dig('queue', 'global_by_status', 'pending')
    assert_equal 1, payload.dig('queue', 'current_chat_by_status', 'pending')
    assert_equal 1, payload.dig('queue', 'current_chat_by_status', 'failed')
    assert_includes payload.dig('runner', 'processing_task_ids'), active.id
    assert_equal [active.id], payload['current_chat_tasks'].select { |t| t['in_flight'] }.map { |t| t['id'] }
    refute_includes payload['current_chat_tasks'].map { |t| t['id'] }, other.id

    failed = payload['current_chat_tasks'].find { |t| t['status'] == 'failed' }
    assert_includes failed['error'], '[url]'
    refute_includes failed['error'], 'secret.example'
    refute_includes failed['error'], 'APIKEYABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
  end

  def test_task_id_cannot_read_another_chat
    other = create_task(chat_id: OTHER_CHAT, type: 'suno_generate', status: 'done')
    payload = call_tool('task_id' => other.id)

    assert_empty payload['current_chat_tasks']
    assert_match(/not present in this chat/, payload['task_error'])
  end

  def test_limit_is_capped
    25.times do |i|
      create_task(chat_id: CHAT, type: "task_#{i}", status: 'failed',
                  params: { request: "длинное описание #{'я' * 300}" },
                  result: { error: "ошибка #{'x' * 300}" })
    end
    raw = call_tool_raw('view' => 'tasks', 'limit' => 100)
    payload = JSON.parse(raw)

    assert_operator payload['current_chat_tasks'].length, :<=, Agent::BotState::MAX_LIMIT
    assert_operator raw.length, :<=, Agent::BotState::TOOL_RESULT_BUDGET
  end

  def test_task_errors_redact_json_and_authorization_secrets
    create_task(
      chat_id: CHAT, type: 'secret_failure', status: 'failed',
      result: { error: %({"api_key":"sk-live+abc/123","password":"hunter2"} Authorization: Basic dXNlcjpwYXNz) }
    )

    payload = call_tool('view' => 'tasks')
    error = payload['current_chat_tasks'].first['error']
    assert_includes error, '[redacted]'
    refute_includes error, 'sk-live'
    refute_includes error, 'hunter2'
    refute_includes error, 'dXNlcjpwYXNz'
  end

  def test_overview_returns_models_without_task_details
    payload = call_tool

    assert payload.key?('models')
    refute payload.key?('current_chat_tasks')
  end

  private

  def create_task(chat_id:, type:, status:, params: {}, result: {})
    BackgroundTask.create!(
      task_type: type,
      chat_id: chat_id,
      status: status,
      params: params.to_json,
      result: result.to_json,
      attempts: 0,
      max_attempts: 30,
    )
  end

  def call_tool(args = {})
    JSON.parse(call_tool_raw(args))
  end

  def call_tool_raw(args = {})
    @tool.handler.call(args, chat_id: CHAT, user: OpenStruct.new(role: 'admin'))
  end

  def tool_names(role)
    Agent::ToolRegistry.definitions_for(user_role: role, api_type: 'openai')
      .map { |definition| definition.dig(:function, :name) }
  end
end

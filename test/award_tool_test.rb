require_relative 'test_helper'
require 'ostruct'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Mirrors bot_dispatcher_test's stub shape (incl. the writer) — this file
# loads alphabetically first, and other tests assign Settings.auth=.
unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    @auth ||= { 'super_admin_uids' => [],
                'rate_limits' => { 'image' => { 'max' => 100, 'window_minutes' => 20 } } }
  }
  Settings.singleton_class.send(:define_method, :auth=) { |v| @auth = v }
end

require_relative '../lib/agent/tool_registry'
require_relative '../lib/agent/tool_result'
require_relative '../lib/rate_limiter'
require_relative '../lib/agent/tools/award'

class AwardToolTest < BotTest
  CHAT = -1003333

  def setup
    super
    @tool = Agent::ToolRegistry.find('make_award')
    @user = OpenStruct.new(uid: 7, role: 'member')
  end

  def call_tool(args = nil, forum_thread_id: nil, **keyword_args)
    args ||= keyword_args
    ctx = { chat_id: CHAT, user: @user }
    ctx[:forum_thread_id] = forum_thread_id if forum_thread_id
    @tool.handler.call(args, ctx)
  end

  def test_enqueues_image_generate_with_award_params
    out = call_tool('recipient' => '@kat', 'reason' => 'провал апелляции')
    assert_instance_of Agent::ToolResult, out
    assert out.action?
    assert_equal 'queued', out.action_status
    assert_equal 'generate_image', out.action
    assert_equal 'image_generate', out.task_type
    assert_equal 'queued', out.phase
    assert_equal 'pending', out.delivery
    assert_includes out.user_text, '@kat'
    task = BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').last
    assert_equal task.id, out.task_id
    p = task.params_hash
    assert_equal true, p['award']
    assert_equal '@kat', p['recipient']
    assert_includes p['request'], '@kat — за провал апелляции'
    assert_equal 7, p['user_uid']
    refute p.key?('forum_thread_id')
  end

  def test_forum_thread_is_propagated_to_award_image_task
    result = call_tool({ 'recipient' => '@kat', 'reason' => 'победу' }, forum_thread_id: 77)

    task = BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').last
    assert_equal 77, task.params_hash['forum_thread_id']
    assert_equal task.id, result.task_id
  end

  def test_rides_image_rate_limit_bucket_with_deferred_result
    # Exhaust the shared image bucket (max 100 in the stub) cheaply by
    # overriding to a zero-cap chat limit via Chat.rate_limits.
    Chat.create!(chat_id: CHAT, title: 'c', chat_type: 'supergroup', authorized: true,
                 audio: false, rate_limits: { 'image' => { 'max' => 0, 'window_minutes' => 20 } }.to_json)
    res = call_tool('recipient' => '@kat', 'reason' => 'спам')
    assert_kind_of Agent::ToolResult, res
    assert res.deferred?, 'rate-limited award must defer like generate_image'
    assert_equal 0, BackgroundTask.where(chat_id: CHAT, task_type: 'image_generate').count
  end
end

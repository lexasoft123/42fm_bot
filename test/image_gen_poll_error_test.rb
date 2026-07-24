require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../lib/chat_context'
require_relative '../lib/telegram_file'
require_relative '../lib/image_gen'
require_relative '../lib/task_runner'
require_relative '../lib/task_handlers/agent_event_emitter'
require_relative '../lib/task_handlers/image_gen_handler'

# ImageGenTaskHandler poll-error handling: a persistently-erroring status
# endpoint (Atlas 500) must fail the task fast (+ notify) after a few CONSECUTIVE
# errors instead of masking it as :pending until the 60-attempt timeout, while a
# single transient blip is tolerated.
class ImageGenPollErrorTest < BotTest
  CHAT = -1002000

  class FakeApi
    attr_reader :sent
    def initialize; @sent = []; end
    def sendMessage(**kw); @sent << kw; { 'ok' => true, 'result' => { 'message_id' => 1 } }; end
  end

  class FakeAdapter
    def initialize(result); @result = result; end
    def name; 'atlas'; end
    def poll_once(_id); @result; end
  end

  def setup
    super
    @handler = ImageGenTaskHandler.new
    @api = FakeApi.new
  end

  def make_task(poll_errors: nil)
    p = { 'provider' => 'atlas', 'request' => 'нарисуй кота' }
    p['poll_errors'] = poll_errors if poll_errors
    BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, max_attempts: 60,
                           external_id: 'pred-x', params: p.to_json)
  end

  # Swap ImageGen.adapter_for for one returning our fake adapter.
  def with_adapter(result)
    sc = ImageGen.singleton_class
    sc.send(:alias_method, :__adapter_for, :adapter_for)
    ImageGen.define_singleton_method(:adapter_for) { |_p| FakeAdapter.new(result) }
    yield
  ensure
    sc.send(:alias_method, :adapter_for, :__adapter_for)
    sc.send(:remove_method, :__adapter_for)
  end

  def test_poll_error_increments_and_stays_pending_under_threshold
    task = make_task
    out = with_adapter(:poll_error) { @handler.call(task, @api) }
    assert_equal :pending, out
    # Fresh load (params_hash memoizes; reload doesn't clear the ivar) so this
    # asserts the DB persistence, not just the in-memory mutation.
    assert_equal 1, BackgroundTask.find(task.id).params_hash['poll_errors']
    assert_empty @api.sent, 'no failure notice below threshold'
  end

  def test_poll_error_fails_and_notifies_at_threshold
    # Already at (MAX-1) consecutive errors; this one trips the threshold.
    task = make_task(poll_errors: ImageGenTaskHandler::MAX_POLL_ERRORS - 1)
    out = with_adapter(:poll_error) { @handler.call(task, @api) }
    assert_equal :failed, out
    assert_equal 'failed', task.reload.status
    assert_equal 1, @api.sent.size, 'user notified once'
    assert_match(/картинку/i, @api.sent.first[:text])
  end

  def test_healthy_poll_resets_error_streak
    task = make_task(poll_errors: 3)
    out = with_adapter(:pending) { @handler.call(task, @api) } # a real 200 "processing" poll
    assert_equal :pending, out
    assert_equal 0, BackgroundTask.find(task.id).params_hash['poll_errors'], 'streak reset on healthy poll'
  end
end

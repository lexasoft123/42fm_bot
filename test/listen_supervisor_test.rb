require_relative 'test_helper'
require 'ostruct'
require_relative '../lib/listen_supervisor'

# A Telegram 502 / SSL EOF escapes bot.listen. The retry used to build a new
# Client starting at offset 0, so Telegram re-sent the last batch and it was
# handled twice. The supervisor must carry the last offset forward.
class ListenSupervisorTest < Minitest::Test
  FakeClient = Struct.new(:options)

  # Each scripted step receives the Client.run options and the block; it
  # either yields a client (the block may raise) or raises before yielding.
  def client_class(steps)
    calls = []
    Class.new do
      define_singleton_method(:calls) { calls }
      define_singleton_method(:run) do |_token, **opts, &blk|
        calls << opts
        steps.shift.call(opts, blk)
      end
    end
  end

  def supervisor(klass)
    ListenSupervisor.new('t', logger: Logger.new(IO::NULL), client_options: { allowed_updates: %w[message] },
                              client_class: klass, retry_delay: 0)
  end

  def test_retry_resumes_from_last_offset
    klass = client_class([
      ->(opts, blk) { blk.call(FakeClient.new(opts.merge(offset: 101))) },
      ->(opts, blk) { blk.call(FakeClient.new(opts)) }
    ])
    attempts = 0
    supervisor(klass).run do |_bot|
      attempts += 1
      raise 'Telegram API has returned the error. (error_code: 502)' if attempts == 1
    end

    first, second = klass.calls
    refute first.key?(:offset), 'first connection starts from Telegram default'
    assert_equal 101, second[:offset]
    assert_equal %w[message], second[:allowed_updates]
  end

  def test_crash_before_any_client_yields_keeps_default_offset
    klass = client_class([
      ->(_opts, _blk) { raise 'SSL_connect failed' },
      ->(opts, blk) { blk.call(FakeClient.new(opts)) }
    ])
    supervisor(klass).run { |_bot| nil }
    refute klass.calls.last.key?(:offset)
  end

  # Exercises the real gem: Client#handle_update must advance options[:offset]
  # before yielding, and Client.run must pass it on to getUpdates.
  def test_real_gem_client_resumes_offset_after_getupdates_error
    require 'telegram/bot'
    offsets = []
    current = nil
    Telegram::Bot::Api.send(:define_method, :getUpdates) do |options|
      offsets << options[:offset]
      case offsets.size
      when 1 then [OpenStruct.new(update_id: 100, current_message: OpenStruct.new(text: 'hi', from: nil))]
      when 2 then raise 'Telegram API has returned the error. (error_code: 502)'
      else current.stop; []
      end
    end
    handled = []
    supervisor(Telegram::Bot::Client).run do |bot|
      current = bot
      bot.listen { |message| handled << message.text }
    end
    assert_equal [0, 101, 101], offsets
    assert_equal ['hi'], handled, 'update 100 must be handled exactly once'
  ensure
    Telegram::Bot::Api.send(:remove_method, :getUpdates) rescue nil
  end

  def test_resume_offset_never_moves_backwards
    assert_equal 120, ListenSupervisor.resume_offset(FakeClient.new({ offset: 110 }), 120)
    assert_equal 130, ListenSupervisor.resume_offset(FakeClient.new({ offset: 130 }), 120)
    assert_equal 120, ListenSupervisor.resume_offset(nil, 120)
    assert_nil ListenSupervisor.resume_offset(FakeClient.new({ offset: 0 }), nil)
  end

  def test_tls_and_socks_errors_resume_polling_without_rerunning_connection_setup
    require 'telegram/bot'
    require 'socksify'
    offsets = []
    active_bot = nil
    Telegram::Bot::Api.send(:define_method, :getUpdates) do |options|
      offsets << options[:offset]
      case offsets.size
      when 1 then [OpenStruct.new(update_id: 100, current_message: OpenStruct.new(text: 'hi', from: nil))]
      when 2 then raise Faraday::SSLError, 'SSL unexpected EOF'
      when 3 then raise SOCKSError::ConnectionRefused.new
      else active_bot.stop; []
      end
    end
    runner = supervisor(Telegram::Bot::Client)
    setups = 0
    handled = []
    runner.run do |bot|
      setups += 1
      active_bot = bot
      runner.listen(bot) { |message| handled << message.text }
    end
    assert_equal 1, setups
    assert_equal [0, 101, 101, 101], offsets
    assert_equal ['hi'], handled
  ensure
    Telegram::Bot::Api.send(:remove_method, :getUpdates) rescue nil
  end

  def test_rate_limit_observes_server_retry_after_on_same_client
    require 'telegram/bot'
    response = OpenStruct.new(body: '{"ok":false,"error_code":429,"parameters":{"retry_after":12}}')
    error = Telegram::Bot::Exceptions::ResponseError.new(response: response)
    bot = FakeClient.new({ offset: 42 })
    attempts = 0
    bot.define_singleton_method(:listen) do |&block|
      attempts += 1
      raise error if attempts == 1
      block.call(:update)
    end
    runner = supervisor(nil)
    sleeps = []
    runner.stub(:sleep, ->(delay) { sleeps << delay }) do
      runner.listen(bot) { |update| assert_equal :update, update }
    end
    assert_equal [12], sleeps
    assert_equal 2, attempts
  end

  def test_dispatch_exception_is_left_to_outer_supervisor
    bot = FakeClient.new({ offset: 42 })
    bot.define_singleton_method(:listen) { |&block| block.call(:update) }
    assert_raises(Faraday::SSLError) do
      supervisor(nil).listen(bot) { raise Faraday::SSLError, 'dispatch failed' }
    end
  end
end

require_relative 'task_handlers/task_delivery_errors'

# Keeps the Telegram long-poll loop alive across failures without replaying
# updates.
#
# telegram-bot-ruby only rescues Faraday timeouts/connection failures inside
# getUpdates; a Telegram 502/429 (ResponseError) or an SSL EOF escapes
# `bot.listen`. The old `rescue; sleep 5; retry` around `Client.run` built a
# fresh Client whose getUpdates offset starts at 0, so Telegram re-sent every
# update it hadn't seen acknowledged — the last batch got handled twice
# (prod: 19 such retries in three weeks, a duplicate Ч24 history row).
#
# The gem advances `options[:offset]` BEFORE yielding each update, so carrying
# that offset into the next Client both prevents the replay and skips an
# update whose handler crashed the loop (no crash-loop on a poison update).
class ListenSupervisor
  RETRY_DELAY_SEC = 5

  def initialize(token, logger:, client_options: {}, client_class: Telegram::Bot::Client,
                 retry_delay: RETRY_DELAY_SEC)
    @token          = token
    @logger         = logger
    @client_options = client_options
    @client_class   = client_class
    @retry_delay    = retry_delay
  end

  # Yields the connected client; the block does the per-connection setup and
  # runs `bot.listen`. Returns only when the block returns normally.
  def run
    offset = nil
    client = nil
    begin
      @client_class.run(@token, **client_options(offset)) do |bot|
        client = bot
        yield bot
      end
    rescue => e
      offset = self.class.resume_offset(client, offset)
      @logger.error "Bot crash (retrying in #{@retry_delay}s, resuming offset=#{offset || 0}): " \
                    "#{e.class}: #{e.message}\n\t#{e.backtrace&.first(20)&.join("\n\t")}"
      sleep @retry_delay
      retry
    end
  end

  def client_options(offset)
    opts = { logger: @logger }.merge(@client_options)
    opts[:offset] = offset if offset
    opts
  end

  # Transport and Telegram gateway failures can be retried with the same
  # client. Its current offset and the completed startup work survive.
  def listen(bot)
    dispatching = false
    bot.listen do |update|
      dispatching = true
      yield update
      dispatching = false
    end
  rescue StandardError => e
    raise if dispatching || !poll_retryable?(e)

    delay = polling_delay(e)
    @logger.warn "Telegram polling interrupted (#{e.class}); resuming offset=#{bot.options[:offset]} in #{delay}s"
    sleep delay
    retry
  end

  private def poll_retryable?(error)
    TaskDeliveryErrors.retryable?(error) || TaskDeliveryErrors.exception_chain(error).any? do |cause|
      defined?(SOCKSError) && cause.is_a?(SOCKSError)
    end
  end

  private def polling_delay(error)
    response = TaskDeliveryErrors.exception_chain(error).find { |cause| TaskDeliveryErrors.telegram_error_code(cause) == 429 }
    params = response&.data&.fetch('parameters', nil)
    retry_after = params.is_a?(Hash) && params['retry_after']
    retry_after.is_a?(Integer) && retry_after.positive? ? [retry_after, @retry_delay].max : @retry_delay
  end

  # The newest offset seen so far. `client` is the last Client that got as far
  # as yielding (nil if none did); `previous` covers a retry whose Client.run
  # failed before yielding.
  def self.resume_offset(client, previous)
    current = client&.options&.[](:offset).to_i
    best = [current, previous.to_i].max
    best.positive? ? best : nil
  end
end

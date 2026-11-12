require 'faraday'
require 'json'
require 'net/http'
require 'openssl'
require 'socket'

# Classifies failures from the real Telegram and Faraday clients. Keep this
# separate from message matching: response error codes are structured fields,
# and wrapper exceptions need their original cause preserved for delivery state.
module TaskDeliveryErrors
  module_function

  def retryable?(error)
    chain = exception_chain(error)
    response_error = chain.find { |candidate| telegram_response_error?(candidate) }
    if response_error
      code = telegram_error_code(response_error)
      return code == 429 || code&.between?(500, 599)
    end

    chain.any? do |candidate|
      candidate.is_a?(Faraday::TimeoutError) ||
        candidate.is_a?(Faraday::ConnectionFailed) ||
        candidate.is_a?(Faraday::SSLError) ||
        # A malformed/truncated HTTP 200 body from Telegram does not prove
        # that the send was rejected; the server may have accepted it before
        # the response was cut off. Retry with delivery_status=unknown unless
        # a structured Telegram response code gives definitive evidence.
        candidate.is_a?(JSON::ParserError) ||
        candidate.is_a?(Net::OpenTimeout) || candidate.is_a?(Net::ReadTimeout) ||
        (defined?(Net::WriteTimeout) && candidate.is_a?(Net::WriteTimeout)) ||
        candidate.is_a?(Errno::ECONNRESET) || candidate.is_a?(Errno::ECONNREFUSED) ||
        candidate.is_a?(Errno::EPIPE) || candidate.is_a?(Errno::ETIMEDOUT) ||
        candidate.is_a?(OpenSSL::SSL::SSLError) || candidate.is_a?(SocketError) ||
        candidate.is_a?(EOFError)
    end
  end

  def definitive_telegram_rejection?(error)
    response_error = exception_chain(error).find { |candidate| telegram_response_error?(candidate) }
    return false unless response_error

    code = telegram_error_code(response_error)
    code&.between?(400, 499) && code != 429
  end

  def structured_telegram_response?(error)
    exception_chain(error).any? { |candidate| telegram_response_error?(candidate) }
  end

  def terminal_delivery_status(error, receipt: false)
    return 'delivered' if receipt
    return 'failed' if definitive_telegram_rejection?(error)

    'unknown'
  end

  def exception_chain(error)
    chain = []
    seen = {}
    pending = [error]
    until pending.empty?
      candidate = pending.shift
      next unless candidate.is_a?(Exception) && !seen[candidate.object_id]

      seen[candidate.object_id] = true
      chain << candidate
      pending << candidate.cause if candidate.cause
      if candidate.respond_to?(:wrapped_exception) && candidate.wrapped_exception
        pending << candidate.wrapped_exception
      end
    end
    chain
  end

  def telegram_response_error?(error)
    defined?(Telegram::Bot::Exceptions::ResponseError) &&
      error.is_a?(Telegram::Bot::Exceptions::ResponseError)
  end

  def telegram_error_code(error)
    return unless telegram_response_error?(error)

    Integer(error.error_code, exception: false)
  end
end

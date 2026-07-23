require_relative 'test_helper'
require 'json'
require_relative '../lib/telegram_rich_client'

# Unit tests for the Rich Messages HTTP client. The HTTP layer is injected
# (`http_post`) so nothing hits the network.
class TelegramRichClientTest < Minitest::Test
  def ok_body(message_id: 555)
    { ok: true, result: { message_id: message_id, text: 'x' } }.to_json
  end

  def test_builds_request_and_returns_result
    cap = {}
    c = TelegramRichClient.new(token: 'TOK',
      http_post: ->(url, json) { cap[:url] = url; cap[:json] = json; ok_body(message_id: 42) })
    result = c.send_rich(chat_id: -100, markdown: '**hi**', message_thread_id: 7, reply_to_message_id: 9)

    assert_equal 42, result['message_id']
    assert_equal 'https://api.telegram.org/botTOK/sendRichMessage', cap[:url]
    body = JSON.parse(cap[:json])
    assert_equal(-100, body['chat_id'])
    assert_equal '**hi**', body.dig('rich_message', 'markdown')
    assert_equal 7, body['message_thread_id']
    assert_equal 9, body.dig('reply_parameters', 'message_id')
    refute body['rich_message'].key?('skip_entity_detection')
  end

  def test_omits_optional_fields
    cap = {}
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, j) { cap[:json] = j; ok_body })
    c.send_rich(chat_id: 1, markdown: 'hi')
    body = JSON.parse(cap[:json])
    refute body.key?('message_thread_id')
    refute body.key?('reply_parameters')
  end

  def test_skip_entity_detection_flag
    cap = {}
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, j) { cap[:json] = j; ok_body })
    c.send_rich(chat_id: 1, markdown: 'hi', skip_entity_detection: true)
    assert_equal true, JSON.parse(cap[:json]).dig('rich_message', 'skip_entity_detection')
  end

  # ok:false ⇒ Telegram validated and did NOT create the message ⇒ Rejected (safe fallback).
  def test_not_ok_is_rejected
    c = TelegramRichClient.new(token: 'T',
      http_post: ->(_u, _j) { { ok: false, description: 'Bad Request: nope' }.to_json })
    e = assert_raises(TelegramRichClient::Rejected) { c.send_rich(chat_id: 1, markdown: 'x') }
    assert_includes e.message, 'nope'
  end

  def test_overlength_is_rejected_before_http
    called = false
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { called = true; ok_body })
    e = assert_raises(TelegramRichClient::Rejected) { c.send_rich(chat_id: 1, markdown: 'a' * 32_769) }
    assert_includes e.message, 'too long'
    refute called, 'over-length must be rejected before any HTTP call'
  end

  # Length is counted in CHARACTERS: 20k Cyrillic chars = 40k bytes, still under
  # the 32768-CHAR rich limit, so the rich path must be attempted (finding #2).
  def test_overlength_counts_chars_not_bytes
    called = false
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { called = true; ok_body })
    c.send_rich(chat_id: 1, markdown: 'я' * 20_000)
    assert called, '20k Cyrillic chars (40k bytes) is under the 32768-char limit'
  end

  # A read timeout means the request WENT OUT — Telegram may have posted it —
  # so it's Ambiguous (the caller must NOT fall back / duplicate). An open
  # timeout means it never connected ⇒ Rejected (safe fallback). (finding #1)
  def test_read_timeout_is_ambiguous
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { raise Net::ReadTimeout })
    assert_raises(TelegramRichClient::Ambiguous) { c.send_rich(chat_id: 1, markdown: 'x') }
  end

  def test_open_timeout_is_rejected
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { raise Net::OpenTimeout })
    assert_raises(TelegramRichClient::Rejected) { c.send_rich(chat_id: 1, markdown: 'x') }
  end

  def test_unknown_transport_error_is_ambiguous
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { raise 'boom' })
    e = assert_raises(TelegramRichClient::Ambiguous) { c.send_rich(chat_id: 1, markdown: 'x') }
    assert_includes e.message, 'boom'
  end

  # Non-JSON body ⇒ never reached Telegram's API ⇒ Rejected (safe fallback).
  def test_invalid_json_response_is_rejected
    c = TelegramRichClient.new(token: 'T', http_post: ->(_u, _j) { '<html>502</html>' })
    assert_raises(TelegramRichClient::Rejected) { c.send_rich(chat_id: 1, markdown: 'x') }
  end

  def test_missing_token_raises
    assert_raises(TelegramRichClient::Error) { TelegramRichClient.new(token: '') }
  end
end

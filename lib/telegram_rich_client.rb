require 'net/http'
require 'json'
require 'uri'

# Minimal client for Telegram's Rich Messages API (Bot API 10.1, June 2026):
# sends a message via `sendRichMessage` using the Rich Markdown field (GitHub
# Flavored Markdown — which our LLM already emits).
#
# Why not the gem? `Telegram::Bot::Api#method_missing` has an ENDPOINTS
# whitelist (`return super unless ENDPOINTS.key?(endpoint)`), so
# `bot.api.sendRichMessage` raises NoMethodError. The gem's public `Api#call`
# WOULD work, but it uses the gem's global 20s connection timeout — far too
# long for the single-threaded `bot.listen` loop. This client exists solely to
# pin a SHORT per-call timeout so a stalled rich call can't freeze every chat.
# It's a plain Net::HTTP POST, so on prod it rides the socksify-patched proxy
# automatically, same as every other outbound request.
class TelegramRichClient
  class Error < StandardError; end
  # Definitely NOT delivered (over-length, ok:false, connect/write failure) —
  # the caller may safely fall back to a classic sendMessage.
  class Rejected < Error; end
  # Possibly delivered: the request went out but the response never arrived
  # (read timeout / unknown transport state). The caller must NOT fall back, or
  # it risks a DUPLICATE message in the chat.
  class Ambiguous < Error; end

  API_BASE        = 'https://api.telegram.org'
  MAX_CHARS       = 32_768            # Rich message text limit (UTF-8 characters)
  DEFAULT_TIMEOUT = 4                 # seconds — keep short; runs on the single-threaded loop

  def initialize(token:, timeout: DEFAULT_TIMEOUT, base_url: API_BASE, http_post: nil)
    @token    = token.to_s
    @timeout  = timeout
    @base_url = base_url
    @http_post = http_post           # injectable for tests: ->(url, json_body) { response_body_string }
    raise Error, 'missing telegram token' if @token.empty?
  end

  # Sends a Rich Message and returns the parsed `result` (a Message Hash) on
  # success (`ok:true`). Raises Rejected (safe to fall back) or Ambiguous (do
  # NOT fall back — may already be delivered) on failure. Length is counted in
  # CHARACTERS, not bytes: this is a Cyrillic bot (~2 bytes/char), so a byte
  # limit would sideline ~16k-char messages that are well under Telegram's
  # 32768-*char* rich limit.
  def send_rich(chat_id:, markdown:, message_thread_id: nil, reply_to_message_id: nil,
                skip_entity_detection: false)
    md = markdown.to_s
    raise Rejected, "rich markdown too long (#{md.length} > #{MAX_CHARS} chars)" if md.length > MAX_CHARS

    rich = { markdown: md }
    rich[:skip_entity_detection] = true if skip_entity_detection
    body = { chat_id: chat_id, rich_message: rich }
    body[:message_thread_id] = message_thread_id if message_thread_id
    body[:reply_parameters]  = { message_id: reply_to_message_id } if reply_to_message_id

    raw = request('sendRichMessage', body) # raises Rejected/Ambiguous on transport failure
    parsed =
      begin
        JSON.parse(raw)
      rescue JSON::ParserError => e
        # A non-JSON body means the request never reached Telegram's API layer
        # (proxy/gateway error) → the message was not created → safe to fall back.
        raise Rejected, "non-JSON response: #{e.message}"
      end
    raise Rejected, "not ok: #{parsed['description']}" unless parsed['ok']
    parsed['result']
  end

  private

  # Returns the raw response body string. Telegram replies 400 with a JSON
  # {ok:false,description} body on bad requests, so 4xx isn't a transport error
  # here — send_rich parses the body and checks `ok`. Transport failures are
  # classified: a read timeout AFTER the request was sent is Ambiguous (Telegram
  # may have created the message → no classic fallback); a connect/write failure
  # means it never went out → Rejected (safe to fall back).
  def request(method, body)
    url  = "#{@base_url}/bot#{@token}/#{method}"
    json = body.to_json
    return @http_post.call(url, json) if @http_post

    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl       = uri.scheme == 'https'
    http.open_timeout  = @timeout
    http.write_timeout = @timeout
    http.read_timeout  = @timeout
    req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = json
    http.request(req).body
  rescue Net::ReadTimeout => e
    raise Ambiguous, "read timeout after send: #{e.class}"
  rescue Net::OpenTimeout, Net::WriteTimeout, SocketError, SystemCallError => e
    raise Rejected, "connect/write failed: #{e.class}: #{e.message}"
  rescue Rejected, Ambiguous
    raise
  rescue => e
    # Unknown transport state → conservatively treat as maybe-sent.
    raise Ambiguous, "transport error: #{e.class}: #{e.message}"
  end
end

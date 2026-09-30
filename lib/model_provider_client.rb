require 'httparty'
require_relative 'agent/error_reporter'

# Generic Bearer+JSON HTTP client for model-provider APIs. Stateless except
# for config; thin wrapper over HTTParty with shared auth + logging.
# In-codebase consumers: AtlasAdapter (image gen), CloseRouterImgAdapter
# (Nano Banana Pro). Reusable by any future Bearer-token, JSON-body model
# provider — just pass a different cfg + tag.
#
# Asymmetry between #post (raises on non-2xx) and #get (returns [code, body],
# swallows transient SSL/timeout) is intentional: submit failures should
# surface to handler bail/retry; poll failures should degrade gracefully so a
# transient blip doesn't fail an in-flight task. Mirrors FluxClient semantics.
#
# #post does NOT rescue OpenSSL::SSL::SSLError / Net::OpenTimeout /
# Errno::ECONNRESET — a TLS error during submit raises the raw exception, not
# the formatted "<tag> POST ..." string. Matches existing FluxClient behavior.
class ModelProviderClient
  def initialize(cfg, tag: 'ModelProvider')
    @base_url = cfg.fetch('api_url')
    @api_key  = cfg.fetch('api_key')
    @tag      = tag
  end

  def post(path, body, timeout: 60)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.post("#{@base_url}#{path}",
      body: body.to_json, headers: headers, timeout: timeout)
    log("POST #{path}", t0, resp.code)
    raise "#{safe(@tag)} POST #{safe(path)}: #{resp.code} #{redact_body(resp.body)}" unless resp.code.between?(200, 299)
    resp.parsed_response
  end

  def get(path, query: nil, timeout: 30)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.get("#{@base_url}#{path}",
      query: query, headers: headers, timeout: timeout)
    log("GET #{path}", t0, resp.code)
    [resp.code, resp.parsed_response]
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{safe(@tag)} GET #{safe(path)}: #{e.class}: #{safe(e.message)}"
    [nil, nil]
  end

  private

  def headers
    { 'Content-Type'  => 'application/json',
      'Authorization' => "Bearer #{@api_key}",
      'Accept'        => 'application/json' }
  end

  def log(label, t0, code)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    LOGGER.debug "#{safe(@tag)} #{safe(label)} took=#{ms}ms code=#{safe(code)}"
  end

  def safe(value)
    Agent::ErrorReporter.sanitize(value)
  end

  # Redact + truncate a response body for safe inclusion in a raised exception
  # message. Upstreams sometimes echo the request body back inside their 4xx
  # response (especially gateways like CloseRouter). For image-edit requests
  # that body contains `data:image/...;base64,<userImageBase64>` blobs which
  # would otherwise propagate to bot.log + the DB + a user-facing chat reply
  # via TaskRunner's notify_chat. Same defensive pattern as
  # SunoClient#format_suno_error.
  def redact_body(body)
    s = body.to_s.gsub(%r{data:[^,]+;base64,[A-Za-z0-9+/=]+}, '<base64-redacted>')
    s = safe(s)
    s.length > 400 ? "#{s[0..400]}...(truncated)" : s
  end
end

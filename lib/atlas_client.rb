require 'httparty'

# Generic HTTP client for Atlas Cloud's API surface (api.atlascloud.ai).
# Stateless except for config; thin wrapper over HTTParty with shared auth +
# logging. Reusable by any Atlas-backed service — image gen today, LLMs /
# embeddings / video tomorrow — by passing a different config dict.
#
# Asymmetry between #post (raises on non-2xx) and #get (returns [code, body],
# swallows transient SSL/timeout) is intentional: submit failures should
# surface to handler bail/retry; poll failures should degrade gracefully so a
# transient blip doesn't fail an in-flight task. Mirrors FluxClient semantics.
#
# #post does NOT rescue OpenSSL::SSL::SSLError / Net::OpenTimeout /
# Errno::ECONNRESET — a TLS error during submit raises the raw exception, not
# the formatted "<tag> POST ..." string. Matches existing FluxClient behavior.
class AtlasClient
  def initialize(cfg, tag: 'AtlasClient')
    @base_url = cfg.fetch('api_url')
    @api_key  = cfg.fetch('api_key')
    @tag      = tag
  end

  def post(path, body, timeout: 60)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.post("#{@base_url}#{path}",
      body: body.to_json, headers: headers, timeout: timeout)
    log("POST #{path}", t0, resp.code)
    raise "#{@tag} POST #{path}: #{resp.code} #{resp.body}" unless resp.code.between?(200, 299)
    resp.parsed_response
  end

  def get(path, query: nil, timeout: 30)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.get("#{@base_url}#{path}",
      query: query, headers: headers, timeout: timeout)
    log("GET #{path}", t0, resp.code)
    [resp.code, resp.parsed_response]
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{@tag} GET #{path}: #{e.class}: #{e.message}"
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
    LOGGER.debug "#{@tag} #{label} took=#{ms}ms code=#{code}"
  end
end

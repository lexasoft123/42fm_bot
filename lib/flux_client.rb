require 'httparty'

class FluxClient
  def initialize
    @base_url = Settings.flux['api_url']
    @api_key  = Settings.flux['api_key']
    @model    = Settings.flux['model'] || 'flux-2-pro'
  end

  # Submit image generation. Returns task_id string.
  def submit(prompt:, width: 1024, height: 1024)
    LOGGER.debug "FluxClient: submitting prompt (#{prompt.length} chars) to #{@model}"
    resp = HTTParty.post("#{@base_url}/v1/#{@model}",
      body: { prompt: prompt, width: width, height: height,
              safety_tolerance: 5, output_format: 'jpeg' }.to_json,
      headers: headers, timeout: 30)
    raise "Flux submit failed: #{resp.code} #{resp.body}" unless resp.code == 200
    resp.parsed_response['id'] || raise("No id in response")
  end

  # Single non-blocking poll. Returns :pending, :failed, or { url: "..." }
  def poll_once(task_id)
    resp = HTTParty.get("#{@base_url}/v1/get_result",
      query: { id: task_id }, headers: headers, timeout: 30)
    return :pending unless resp.code == 200
    data = resp.parsed_response
    case data['status']
    when 'Ready'
      { url: data.dig('result', 'sample') }
    when 'Error', 'Content Moderated'
      :failed
    else
      :pending
    end
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "FluxClient poll_once: #{e.class}: #{e.message}"
    :pending
  end

  private

  def headers
    { 'Content-Type' => 'application/json', 'x-key' => @api_key }
  end
end

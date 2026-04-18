require 'httparty'

class FluxClient
  def initialize
    @base_url = Settings.flux['api_url']
    @api_key  = Settings.flux['api_key']
    @model    = Settings.flux['model'] || 'flux-2-pro'
  end

  # Submit image generation or editing. Returns task_id string.
  # When input_image is provided (base64, without data-URI prefix), flux-2-pro switches
  # to image-edit mode and will size the output to match the input unless width/height forced.
  def submit(prompt:, input_image: nil, width: 1024, height: 1024)
    body = { prompt: prompt, safety_tolerance: 5, output_format: 'jpeg' }
    if input_image
      body[:input_image] = "data:image/jpeg;base64,#{input_image}"
      # Omit explicit width/height — let FLUX keep the input dimensions.
      LOGGER.debug "#{self.class.name}: submitting edit (prompt #{prompt.length} chars, image #{input_image.bytesize} b64-bytes) to #{@model}"
    else
      body[:width] = width
      body[:height] = height
      LOGGER.debug "#{self.class.name}: submitting prompt (#{prompt.length} chars) to #{@model}"
    end
    resp = HTTParty.post("#{@base_url}/v1/#{@model}",
      body: body.to_json, headers: headers, timeout: 60)
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
    LOGGER.warn "#{self.class.name} poll_once: #{e.class}: #{e.message}"
    :pending
  end

  private

  def headers
    { 'Content-Type' => 'application/json', 'x-key' => @api_key }
  end
end

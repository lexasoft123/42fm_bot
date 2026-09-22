require 'httparty'
require 'set'

module ImageGen
  # FLUX 2 image generation via api.bfl.ai. Absorbed from the former top-level
  # FluxClient class. Prompt enrichment is inherited from the shared template.
  #
  # Does NOT use ModelProviderClient — FLUX runs on a different host with a
  # different auth header (`x-key` instead of `Authorization: Bearer`).
  #
  # Config read order (back-compat shim — removed in step 16 once prod is
  # migrated): image_gen.providers.flux → top-level Settings.flux.
  class FluxAdapter < Adapter
    NAME = 'flux'

    @logged_unknown_status = Set.new
    @logged_unknown_mutex  = Mutex.new

    def self.note_unknown_status(task_id, status)
      @logged_unknown_mutex.synchronize do
        return if @logged_unknown_status.include?(task_id)
        @logged_unknown_status.add(task_id)
      end
      LOGGER.warn "FluxAdapter: unknown status=#{status.inspect} for #{task_id} (treating as :pending)"
    end

    def initialize
      # Back-compat shim: merge top-level Settings.flux UNDER image_gen.providers.flux.
      # During the transition both may exist (common.yml has the new schema sans
      # api_key; prod settings.yml may still have only the legacy top-level
      # flux: block). Nested wins per-key, but keys missing from nested fall
      # through to the legacy block — so a prod with only top-level flux still
      # boots. Removed in plan step 16.
      nested = Settings.image_gen&.dig('providers', 'flux') || {}
      legacy = (Settings.respond_to?(:flux) ? Settings.flux : nil) || {}
      cfg = legacy.merge(nested)
      raise('flux config missing: set image_gen.providers.flux') if cfg.empty?
      raise('flux api_key missing: set image_gen.providers.flux.api_key') unless cfg['api_key']
      @base_url = cfg['api_url']
      @api_key  = cfg['api_key']
      @model    = cfg['model'] || 'flux-2-pro'
    end

    # Submit image generation or editing. Returns task_id string.
    # When input_images is provided, flux-2-pro switches to image-edit mode and
    # sizes the output to match the input unless width/height are forced. FLUX
    # edits a SINGLE source image — if several are passed (a combine the agent
    # should have routed to a nano-banana model), use the first and warn.
    def submit(prompt:, input_images: nil, width: 1024, height: 1024, model: nil)
      effective_model = model || @model
      imgs = Array(input_images)
      body = { prompt: prompt, safety_tolerance: 5, output_format: 'jpeg' }
      if imgs.any?
        LOGGER.warn "#{self.class.name}: #{imgs.size} input images given but FLUX edits one — using the first" if imgs.size > 1
        first = imgs.first
        body[:input_image] = "data:#{first[:media_type] || 'image/jpeg'};base64,#{first[:data]}"
        LOGGER.debug "#{self.class.name}: submitting edit (prompt #{prompt.length} chars, #{imgs.size} image(s)) to #{effective_model}"
      else
        body[:width]  = width
        body[:height] = height
        LOGGER.debug "#{self.class.name}: submitting prompt (#{prompt.length} chars) to #{effective_model}"
      end
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resp = HTTParty.post("#{@base_url}/v1/#{effective_model}",
        body: body.to_json, headers: headers, timeout: 60)
      LOGGER.debug "#{self.class.name}#submit took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms code=#{resp.code}"
      raise "Flux submit failed: #{resp.code} #{resp.body}" unless resp.code == 200
      resp.parsed_response['id'] || raise("No id in response")
    end

    # Single non-blocking poll. Returns :pending, :failed, :retry, or { url: }.
    def poll_once(task_id)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resp = HTTParty.get("#{@base_url}/v1/get_result",
        query: { id: task_id }, headers: headers, timeout: 30)
      took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      return :pending unless resp.code == 200
      data = resp.parsed_response
      LOGGER.debug "#{self.class.name}#poll_once took=#{took_ms}ms status=#{data['status'].inspect}"
      case data['status']
      when 'Ready'
        { url: data.dig('result', 'sample') }
      when 'Content Moderated', 'Request Moderated', 'Task not found'
        :failed
      when 'Error'
        :retry
      when 'Pending', 'Processing', 'Queued'
        :pending
      else
        self.class.note_unknown_status(task_id, data['status'])
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
end

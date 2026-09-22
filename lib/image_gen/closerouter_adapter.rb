module ImageGen
  # CloseRouter (closerouter.dev) image generation. Routes Nano Banana Pro
  # (google/nano-banana-pro) for text-to-image and Nano Banana Pro Edit
  # (google/nano-banana-pro-edit) for image editing.
  #
  # SYNCHRONOUS: CloseRouter's POST /v1/images/generations returns the result
  # in the same HTTP response (no separate poll endpoint). `synchronous? = true`
  # tells ImageGenTaskHandler to short-circuit the poll cycle and deliver
  # straight from #submit's return value. #poll_once therefore raises if it's
  # ever called — that would be a logic bug.
  #
  # Verified response shape (live smoke 2026-05-18):
  #   { id:, model:, created:, data: [
  #       { type: 'image_url', url: 'https://...', image_url: { url: '...' },
  #         b64_json: '...' }
  #   ] }
  # We use `data[0].url` (CDN-hosted PNG) and ignore b64_json to keep memory
  # use bounded.
  class CloseRouterImgAdapter < Adapter
    NAME = 'closerouter'

    def initialize
      cfg = Settings.image_gen&.dig('providers', 'closerouter') or
        raise 'closerouter image config missing: set image_gen.providers.closerouter'
      raise 'closerouter image api_key missing' unless cfg['api_key']
      @client     = ModelProviderClient.new(cfg, tag: 'CloseRouterImg')
      @t2i_model  = cfg['text_to_image_model'] || 'google/nano-banana-pro'
      @edit_model = cfg['image_edit_model']    || 'google/nano-banana-pro-edit'
    end

    def synchronous?
      true
    end

    # Returns the terminal result Hash directly (sync flow). Handler reads
    # `[:url]` and skips polling. Shape `{url:}` matches the async-path Hash
    # returned by Atlas/Flux poll_once → consistent `background_tasks.result`
    # JSON across sync/async adapters.
    def submit(prompt:, input_images: nil, model: nil)
      imgs = Array(input_images)
      body = if imgs.any?
        # Edit mode uses plural `images` (Nano Banana Pro combines multiple
        # input images). Atlas-Wan/Flux use singular `image`.
        { model: (model || @edit_model),
          prompt: prompt,
          images: imgs.map { |i| "data:#{i[:media_type] || 'image/jpeg'};base64,#{i[:data]}" } }
      else
        { model: (model || @t2i_model), prompt: prompt }
      end
      LOGGER.debug "#{self.class.name}: submitting #{imgs.any? ? "edit (#{imgs.size} img)" : 't2i'} (prompt #{prompt.length} chars) to #{body[:model]}"
      # Synchronous: server holds the connection open for the entire generation
      # (typically 30-120s for Nano Banana Pro on real prompts), so the POST
      # timeout has to cover end-to-end generation, not just the request RTT.
      # `ModelProviderClient`'s default 60s is fine for async-submit adapters
      # like Atlas/Flux that return a task_id immediately; sync needs more.
      resp = @client.post('/v1/images/generations', body, timeout: 180)
      url = resp.dig('data', 0, 'url')
      raise "CloseRouter image submit: no data[0].url in response: #{resp.inspect[0..400]}" unless url
      { url: url }
    end

    # Never called when synchronous? is true. Defensive guard: raises if the
    # handler routing breaks and somehow reaches this path.
    def poll_once(_external_id)
      raise NotImplementedError, "#{self.class.name} is synchronous; poll_once should not be called"
    end

 end
end

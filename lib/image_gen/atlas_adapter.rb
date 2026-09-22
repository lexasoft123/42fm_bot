require 'set'

module ImageGen
  # Atlas Cloud image generation. Targets Atlas's uniform endpoint
  # (POST /api/v1/model/generateImage + GET /api/v1/model/prediction/{id})
  # and is named after the *platform*, not the model — switching from Wan to
  # Seedream/Ideogram/Qwen-Image/etc. is a config change, not a code change.
  #
  # v1 hardcodes Wan 2.7's `input.prompt` request schema. Other Atlas models
  # may use a flat `prompt` field; if we add such a model, branch on the model
  # id (or split into a sub-adapter).
  #
  # SHELL: methods raise NotImplementedError until step 5 of the plan implements
  # them. The adapter exists now so the registry in lib/image_gen.rb resolves.
  class AtlasAdapter < Adapter
    NAME = 'atlas'

    @logged_unknown_status = Set.new
    @logged_unknown_mutex  = Mutex.new

    def self.note_unknown_status(task_id, status)
      @logged_unknown_mutex.synchronize do
        return if @logged_unknown_status.include?(task_id)
        @logged_unknown_status.add(task_id)
      end
      LOGGER.warn "AtlasAdapter: unknown status=#{status.inspect} for #{task_id} (treating as :pending)"
    end

    def initialize
      cfg = Settings.image_gen&.dig('providers', 'atlas') or
        raise 'atlas config missing: set image_gen.providers.atlas'
      @client     = ModelProviderClient.new(cfg, tag: 'AtlasImg')
      @t2i_model  = cfg['text_to_image_model'] || 'alibaba/wan-2.7/text-to-image'
      @edit_model = cfg['image_edit_model']    || 'alibaba/wan-2.7/image-edit'
      @width      = cfg['width']  || 1024
      @height     = cfg['height'] || 1024
    end

    # Text-to-image (default) and image-edit (when input_images present).
    #
    # Request shape (flat — Atlas's published "input.prompt" example does NOT
    # work; submit returns 200+id but polling returns `code:400, "Field
    # required: ***"` immediately, so fields go at top level):
    #   submit: POST /api/v1/model/generateImage
    #   T2I body  : { model: '...text-to-image', prompt: '...', <size field> }
    #   edit body : { model: '...image-edit',    prompt: '...', <image field> }
    #
    # T2I SIZING IS PER-MODEL: Wan/nano-banana take width+height integers;
    # Seedream and Qwen Image 3.0 take a single `size: "WIDTH*HEIGHT"` string;
    # GPT Image 2.5 Sunburst takes `size: "WIDTHxHEIGHT"` (letter x).
    #
    # THE EDIT IMAGE FIELD IS PER-MODEL (this differs by model family — getting
    # it wrong makes the model silently ignore the source and regenerate from
    # scratch, with a successful-looking task):
    #   - Wan 2.7          → singular  `image:  'data:...;base64,...'`  (confirmed live 2026-04-30)
    #   - nano-banana/*    → plural    `images: ['data:...;base64,...', ...]`  (confirmed live 2026-06-24)
    #   - seedream-v5.0/*  → plural    `images: ['data:...;base64,...', ...]`  (Atlas docs: up to 10 refs)
    #   - gpt-image-2.5/*  → plural    `images: ['data:...;base64,...', ...]`  (Atlas docs: up to 16 refs)
    #   - qwen-image-3.0/* → plural    `reference_image_urls: [...]`          (Atlas docs: up to 3 refs)
    # All accept base64 data URIs (no public-URL/upload step). nano-banana &
    # Seedream accept up to ~10 images (combine); Qwen 3.0 accepts 3; Wan reads
    # a single image. Min res varies by model.
    #   submit response: { code:200, data: { id, status:'processing', urls:{get}, ... } }
    #   poll    response: { code, data: { id, status, outputs:[<url>], error, ... } }
    #     status set: 'processing' | 'completed' | 'failed'
    #     terminal failures put HTTP 200 with `code:400` AND `data.status:'failed'`,
    #     so we trust `data.status`.
    def submit(prompt:, input_images: nil, model: nil)
      imgs = Array(input_images)
      body = if imgs.any?
        edit_model = (model || @edit_model)
        data_uris  = imgs.map { |i| "data:#{i[:media_type] || 'image/jpeg'};base64,#{i[:data]}" }
        base = { model: edit_model, prompt: prompt }
        # Per-model field: Qwen 3.0 reads `reference_image_urls`; nano-banana,
        # Seedream and GPT Image read `images`; Wan reads singular `image`. Wrong one can
        # silently regenerate from scratch. Atlas documents a 3-reference cap
        # for Qwen 3.0, below the tool-wide MAX_EDIT_IMAGES cap.
        if edit_model.to_s.include?('qwen-image-3.0')
          LOGGER.warn "AtlasAdapter: Qwen Image 3.0 accepts at most 3 references; ignoring #{data_uris.length - 3}" if data_uris.length > 3
          base.merge(reference_image_urls: data_uris.first(3))
        elsif edit_model.to_s.match?(/nano-banana|seedream|gpt-image/)
          base.merge(images: data_uris)
        else
          base.merge(image: data_uris.first)
        end
      else
        t2i_model = (model || @t2i_model)
        base = { model: t2i_model, prompt: prompt }
        # Per-model sizing: GPT Image uses letter `x`; Seedream and Qwen Image
        # 3.0 use `*`; Wan/nano-banana take width/height integers.
        if t2i_model.to_s.include?('gpt-image')
          base.merge(size: "#{@width}x#{@height}")
        elsif t2i_model.to_s.match?(/seedream|qwen-image-3\.0/)
          base.merge(size: "#{@width}*#{@height}")
        else
          base.merge(width: @width, height: @height)
        end
      end
      resp = @client.post('/api/v1/model/generateImage', body)
      resp['id'] || resp.dig('data', 'id') ||
        raise("Atlas submit: no id in response: #{resp.inspect}")
    end

    def poll_once(external_id)
      code, body = @client.get("/api/v1/model/prediction/#{external_id}")
      unless code == 200 && body
        # A non-200 is NOT "still processing" — Atlas's status endpoint returns
        # HTTP 500 persistently for some failed predictions (Atlas web shows them
        # failed while we'd otherwise poll `:pending` until the 60-attempt
        # timeout). Signal :poll_error so the handler fails fast after a few
        # CONSECUTIVE errors; single transient blips are still tolerated there.
        LOGGER.warn "AtlasAdapter: poll HTTP #{code.inspect} for #{external_id}"
        return :poll_error
      end

      data = body['data'] || body  # tolerate either wrapping
      case data['status']
      when 'completed', 'succeeded'
        url = data.dig('outputs', 0)
        if url
          { url: url }
        else
          LOGGER.warn("AtlasAdapter: terminal status without outputs[0] for #{external_id}: #{data.inspect}")
          :failed
        end
      when 'processing', 'queued'
        :pending
      when 'failed'
        LOGGER.warn("AtlasAdapter: prediction #{external_id} failed: #{data['error'].to_s[0..200]}")
        :failed
      else
        self.class.note_unknown_status(external_id, data['status'])
        :pending
      end
    end

 end
end

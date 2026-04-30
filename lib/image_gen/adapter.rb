module ImageGen
  # Base class for image-generation backends. Each concrete adapter owns its
  # API client logic AND its prompt-enrichment templates so the handler stays
  # provider-agnostic.
  class Adapter
    # Submit a generation/edit job. Returns external task_id String.
    # input_image: base64 string (no data-URI prefix), or nil for text-to-image.
    def submit(prompt:, input_image: nil, input_media_type: nil)
      raise NotImplementedError
    end

    # Single non-blocking poll. Returns :pending | :failed | :retry | { url: }.
    # :retry signals a transient backend failure; handler will re-submit by
    # clearing external_id.
    def poll_once(external_id)
      raise NotImplementedError
    end

    # LLM template for prompt enrichment. mode ∈ [:text_to_image, :edit].
    # Returns a String with %{request} %{context} %{knowledge} placeholders.
    def prompt_template(mode)
      raise NotImplementedError
    end

    # Short identifier ('flux' | 'atlas'). Snapshotted into task.params at
    # submit time so poll-side dispatch stays stable across config flips.
    def name
      self.class::NAME
    end
  end
end

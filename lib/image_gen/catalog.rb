module ImageGen
  # Single source of truth for the agent-selectable image-model catalog.
  #
  # The catalog lives in config (`image_gen.models` in settings.common.yml) so
  # adding/changing a model is a config-only change, consistent with how every
  # other model id in this repo is configured. Each entry:
  #   <key>:                      # stable enum value the agent picks in generate_image(model:)
  #     provider: atlas|flux|closerouter   # which ImageGen::ADAPTERS adapter serves it
  #     t2i:  'provider/model-id'          # text-to-image model id passed to adapter.submit(model:)
  #     edit: 'provider/model-id' | false  # image-edit model id, or false if edit unsupported
  #     desc: '...'                        # shown to the agent in the tool param description
  #
  # Read lazily + memoized: Settings is NOT loaded at tool-require time (boot.rb
  # requires the tools before app_configurator runs Settings.load!), so the
  # catalog can't be read inside a tool's static `parameters:` hash. The
  # generate_image tool defers the read via enum_source/desc_suffix_source
  # lambdas resolved in ToolRegistry.definitions_for (per-turn, at runtime).
  module Catalog
    module_function

    def all
      @all ||= (Settings.image_gen&.dig('models') || {}).freeze
    end

    def keys
      all.keys
    end

    # Configured default catalog key, used when the agent omits or sends an
    # unknown model. Falls back to the first catalogued key if unset.
    def default_key
      Settings.image_gen&.dig('default_model') || keys.first
    end

    # Catalog entry hash for a key, or nil for blank/unknown keys.
    def entry(key)
      k = key.to_s
      k.empty? ? nil : all[k]
    end

    # Map any input to a valid catalog key: the given key if known, else default.
    def resolve_key(key)
      entry(key) ? key.to_s : default_key
    end

    def provider_for(key)
      (entry(resolve_key(key)) || {})['provider']
    end

    # Provider-specific model id for the mode (:text_to_image | :edit).
    # Returns nil when edit is unsupported (entry['edit'] == false) so the
    # caller passes model: nil and the adapter uses its configured default.
    def model_id_for(key, mode)
      e = entry(resolve_key(key)) || {}
      mode == :edit ? (e['edit'] || nil) : e['t2i']
    end

    def edit_supported?(key)
      e = entry(resolve_key(key)) || {}
      e['edit'] != false && !e['edit'].nil?
    end

    # True when the model can edit/combine MORE than one input image at once
    # (nano-banana family, flagged `multi_image: true` in config). Models
    # without the flag (Wan/Flux) take a single source image. The generate_image
    # tool uses this to auto-switch a combine request to a capable model.
    def multi_image?(key)
      !!((entry(resolve_key(key)) || {})['multi_image'])
    end

    # The model key a combine (>1 image) request auto-switches to: the configured
    # default if it's multi_image-capable, else the first catalogued multi_image
    # model. Falls back to default_key if the catalog has none capable (caller
    # logs in that case — the combine would degrade to first-image-only).
    def multi_image_default_key
      d = default_key
      return d if multi_image?(d)
      keys.find { |k| multi_image?(k) } || d
    end

    # --- tool-schema derivation (called from ToolRegistry.definitions_for) ---

    def enum
      keys
    end

    def describe_options
      all.map { |k, e| "#{k} — #{e['desc']}" }.join("\n")
    end

    # Test seam: drop the memoized catalog (tests mutate Settings.image_gen).
    def reset!
      @all = nil
    end
  end
end

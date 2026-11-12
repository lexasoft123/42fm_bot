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
  # Shared by the agent boundary and image tool when a photo is present.
  module EditIntent
    module_function

    VERB = /(?:измени(?:те)?|изменьте|меняй(?:те)?|передела(?:й|йте)|отредактиру(?:й|йте)|дорису(?:й|йте)|исправь(?:те)?|обработа(?:й|йте)|перерису(?:й|йте)|замени(?:те)?|заменьте|убери(?:те)?|добавь(?:те)?|сними(?:те)?|раздень(?:те)?|переодень(?:те)?|поменя(?:й|йте)|объедини(?:те)?|соедини(?:те)?|совмести(?:те)?|смеша(?:й|йте)|edit|modify|change|replace|remove|add|combine|merge)/i

    def requested?(text)
      prose = text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      prose = prose.gsub(/(?<![[:alpha:]])(?:не|без|don't|do not)\s+(?:#{VERB})(?![[:alpha:]])/i, ' ')
      prose.match?(/(?<![[:alpha:]])(?:#{VERB})(?![[:alpha:]])/i)
    end

    def find_photo_then_edit?(text)
      prose = text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      prose = prose.gsub(/(?<![[:alpha:]])(?:не|без|don't|do not)\s+(?:найди|поищи|погугли|ищи|find|search|google)(?![[:alpha:]])/i, ' ')
      return false unless requested?(prose)
      return false if prose.match?(/(?<![[:alpha:]])(?:нарису(?:й|йте)|сгенериру(?:й|йте)|draw|generate)(?![[:alpha:]])/i) &&
                      !prose.match?(/(?:на\s+(?:н[её]м|фото|картинк)|(?:дорису|отредактиру|измени)(?:й|йте)\s+(?:его|е[её]|фото))/i)
      prose.match?(/(?<![[:alpha:]])(?:найди|поищи|погугли|ищи|find|search|google)(?![[:alpha:]]).{0,100}(?:фото|фотограф|картинк|изображени|photo|image|picture)/im)
    end
  end

  module Catalog
    MAX_SOURCE_CANDIDATES = 24
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
    # worker uses this along with image_capacity after deduplicating sources.
    def multi_image?(key)
      !!((entry(resolve_key(key)) || {})['multi_image'])
    end

    # The model key a combine (>1 image) request auto-switches to: the configured
    # default if it's multi_image-capable, else the first catalogued multi_image
    # model. Falls back to default_key when no multi-image model exists; callers
    # must validate capability before submitting.
    def multi_image_default_key
      d = default_key
      return d if multi_image?(d)
      keys.find { |k| multi_image?(k) } || d
    end

    # Maximum sources the actual backend accepts, within the shared limit.
    def image_capacity(key)
      return 1 unless multi_image?(key)
      key.to_s.start_with?('qwen-') ? 3 : ImageGen::MAX_EDIT_IMAGES
    end

    def capable_model_for(count, excluded: [])
      ([default_key] + keys).uniq.find { |key| !excluded.include?(key) && edit_supported?(key) && image_capacity(key) >= count && ImageGen::ADAPTERS.key?(provider_for(key)) }
    end

    # Model names can be selections or exclusions. Match complete names and
    # unambiguous aliases with token boundaries, then classify the surrounding
    # clause so an excluded name cannot win merely because it is longer.
    def model_mentions(text)
      normalized = text.to_s.downcase.gsub(/[-_]+/, ' ').gsub(/\s+/, ' ')
      aliases = keys.flat_map do |key|
        name = key.downcase.tr('-_', ' ').gsub(/\s+/, ' ')
        [[name, key, name.length]]
      end
      aliases += keys.filter_map do |key|
        family = key.downcase.split('-').first
        next if family.length < 3 || keys.count { |k| k.downcase.split('-').first == family } != 1
        [family, key, family.length]
      end
      sunburst = keys.find { |key| key.include?('sunburst') }
      aliases << ['sunburst', sunburst, 8] if sunburst
      occurrences = aliases.flat_map do |name, key, specificity|
        pattern = /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/
        normalized.to_enum(:scan, pattern).map do
          match = Regexp.last_match
          { key: key, start: match.begin(0), finish: match.end(0), specificity: specificity }
        end
      end
      # Exact long names take precedence over family and alias matches inside them.
      selected = []
      occurrences.sort_by { |m| [-m[:specificity], m[:start]] }.each do |match|
        next if selected.any? { |other| match[:start] < other[:finish] && other[:start] < match[:finish] }
        selected << match
      end
      previous = nil
      selected.sort_by { |match| match[:start] }.map do |match|
        prefix = normalized[0...match[:start]]
        separator = previous && normalized[previous[:finish]...match[:start]]
        # A bare comma/conjunction continues a coordinated exclusion list.
        # A new instruction, contrast, or sentence ends that scope.
        list_continuation = previous && previous[:excluded] &&
          separator.match?(/\A\s*(?:,\s*[a-z0-9.+]+\s*)*(?:,|\/|&|и|and)\s*\z/i) &&
          !separator.match?(/(?<![[:alpha:]])(?:use|choose|select|generate|draw|but|instead)(?![[:alpha:]])/i)
        # An exclusion governs the model only when the text immediately
        # before the name is an exclusion phrase, not arbitrary scene nouns.
        governed = prefix.match?(/(?<![[:alpha:]])(?:не|без|кроме|исключая|избегай|not|without|avoid|exclude|don't|do not)\s+(?:(?:используй(?:те)?|использовать|используя|выбирай(?:те)?|выбирать|бери(?:те)?|применяй(?:те)?|применять|через|use|choose|select|using|the|модель|модели)\s+)*\z/i)
        excluded = list_continuation || governed
        previous = match.merge(excluded: !!excluded)
      end

    end

    def excluded_keys(text)
      model_mentions(text).select { |match| match[:excluded] }.map { |match| match[:key] }.uniq
    end

    def requested_key(text)
      mentions = model_mentions(text)
      excluded = mentions.select { |match| match[:excluded] }.map { |match| match[:key] }
      positive = mentions.reject { |match| match[:excluded] || excluded.include?(match[:key]) }
      positive.max_by { |match| match[:specificity] }&.fetch(:key)
    end

    def allowed_key(suggested, excluded = [])
      ([suggested, default_key] + keys).compact.uniq.find { |key| entry(key) && !excluded.include?(key) }
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

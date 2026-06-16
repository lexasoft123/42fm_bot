module Agent
  class ToolRegistry
    ToolDef = Struct.new(:name, :description, :parameters, :handler, :admin_only, keyword_init: true)

    class << self
      def tools
        @tools ||= []
      end

      def register(name:, description:, parameters: {}, handler:, admin_only: false)
        tools << ToolDef.new(
          name: name, description: description,
          parameters: parameters, handler: handler,
          admin_only: admin_only
        )
      end

      def definitions_for(user_role:, api_type:)
        available = tools.reject { |t| t.admin_only && user_role != 'admin' }
        available.map do |t|
          props    = build_properties(t.parameters)
          required = t.parameters.reject { |_k, v| v.is_a?(Hash) && v[:optional] }.keys
          if api_type == 'anthropic'
            { name: t.name, description: t.description,
              input_schema: { type: 'object', properties: props, required: required } }
          else
            { type: 'function',
              function: { name: t.name, description: t.description,
                          parameters: { type: 'object', properties: props, required: required } } }
          end
        end
      end

      def find(name)
        tools.find { |t| t.name == name }
      end

      private

      # Materialize a tool's parameter specs into JSON-schema properties:
      # strip internal-only keys (optional, enum_source, desc_suffix_source) and
      # resolve dynamic enum/description lambdas NOW — definitions_for runs
      # per-turn at runtime, after Settings is loaded, so lambdas that read
      # config (e.g. the generate_image `model` enum from ImageGen::Catalog)
      # are safe here even though they aren't at tool-require time.
      INTERNAL_PARAM_KEYS = %i[optional enum_source desc_suffix_source].freeze

      def build_properties(parameters)
        parameters.each_with_object({}) do |(name, spec), out|
          unless spec.is_a?(Hash)
            out[name] = spec
            next
          end
          p = spec.reject { |k, _| INTERNAL_PARAM_KEYS.include?(k) }
          if (es = spec[:enum_source])
            vals = es.call
            p = p.merge(enum: vals) unless vals.nil? || vals.empty?
          end
          if (ds = spec[:desc_suffix_source])
            suffix = ds.call
            p[:description] = "#{p[:description]}#{suffix}" if suffix && !suffix.empty?
          end
          out[name] = p
        end
      end
    end
  end
end

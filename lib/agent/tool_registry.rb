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
        if api_type == 'anthropic'
          available.map do |t|
            { name: t.name, description: t.description, input_schema: { type: 'object', properties: t.parameters, required: t.parameters.keys } }
          end
        else
          available.map do |t|
            { type: 'function', function: { name: t.name, description: t.description, parameters: { type: 'object', properties: t.parameters, required: t.parameters.keys } } }
          end
        end
      end

      def find(name)
        tools.find { |t| t.name == name }
      end
    end
  end
end

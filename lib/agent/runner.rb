module Agent
  class Runner
    MAX_ITERATIONS = 5
    MAX_TOOL_RESULT_LENGTH = 2000

    def initialize(text:, context:, knowledge:, radio:, chat_id:, user:, bot: nil)
      @text      = text
      @context   = context
      @knowledge = knowledge
      @radio     = radio
      @chat_id   = chat_id
      @user      = user
      @setting   = 'agent'
      @api_type  = GptMaster.resolve_setting(@setting)[:api_type]
      @tool_ctx  = { radio: radio, chat_id: chat_id, user: user, bot: bot }
    end

    def run
      messages = build_initial_messages
      tools    = ToolRegistry.definitions_for(user_role: @user.role, api_type: @api_type)

      MAX_ITERATIONS.times do |i|
        raw = GptMaster.new(messages, setting: @setting).call_raw(tools: tools)
        return 'жпт не жпт' unless raw

        tool_calls = extract_tool_calls(raw)

        if tool_calls.empty?
          return extract_text(raw) || 'жпт не жпт'
        end

        messages << build_assistant_message(raw)

        tool_calls.each do |tc|
          result = execute_tool(tc[:name], tc[:input])
          messages << build_tool_result_message(tc[:id], result)
        end

        LOGGER.debug "Agent iteration #{i + 1}: #{tool_calls.map { |t| t[:name] }.join(', ')}"
      end

      # Safety: final call without tools to force a text response
      GptMaster.new(messages, setting: @setting).call || 'жпт не жпт'
    end

    private

    def build_initial_messages
      prompt_template = Settings.chat_gpt['agent_prompt'] || Settings.chat_gpt['prompt']
      content = prompt_template
        .gsub('{REQUEST}', @text)
        .gsub('{CONTEXT}', @context)
        .gsub('{KNOWLEDGE}', @knowledge)
      [{ role: 'user', content: content }]
    end

    def execute_tool(name, input)
      tool = ToolRegistry.find(name)
      unless tool
        LOGGER.warn "Agent: unknown tool #{name}"
        return "Ошибка: неизвестный инструмент #{name}"
      end

      if tool.admin_only && @user.role != 'admin'
        return "Ошибка: недостаточно прав для #{name}"
      end

      result = tool.handler.call(input, @tool_ctx)
      truncate(result.to_s)
    rescue => e
      LOGGER.error "Agent tool #{name} error: #{e.class}: #{e.message}"
      "идите нахуй"
    end

    def truncate(str)
      str.length > MAX_TOOL_RESULT_LENGTH ? str[0...MAX_TOOL_RESULT_LENGTH] + '...' : str
    end

    # --- Provider-specific methods ---

    def anthropic?
      @api_type == 'anthropic'
    end

    def extract_tool_calls(raw)
      if anthropic?
        (raw['content'] || []).select { |b| b['type'] == 'tool_use' }.map do |b|
          { id: b['id'], name: b['name'], input: b['input'] || {} }
        end
      else
        (raw.dig('choices', 0, 'message', 'tool_calls') || []).map do |tc|
          args = begin; JSON.parse(tc['function']['arguments']); rescue; {}; end
          { id: tc['id'], name: tc['function']['name'], input: args }
        end
      end
    end

    def extract_text(raw)
      if anthropic?
        text_block = (raw['content'] || []).find { |b| b['type'] == 'text' }
        text_block&.dig('text')
      else
        raw.dig('choices', 0, 'message', 'content')
      end
    end

    def build_assistant_message(raw)
      if anthropic?
        { role: 'assistant', content: raw['content'] }
      else
        raw.dig('choices', 0, 'message')
      end
    end

    def build_tool_result_message(tool_call_id, result)
      if anthropic?
        { role: 'user', content: [{ type: 'tool_result', tool_use_id: tool_call_id, content: result }] }
      else
        { role: 'tool', tool_call_id: tool_call_id, content: result }
      end
    end
  end
end

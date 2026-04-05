require 'erb'

module Agent
  class Runner
    MAX_ITERATIONS = 5
    MAX_TOOL_RESULT_LENGTH = 2000

    def initialize(text:, context:, knowledge:, radio:, chat_id:, user:, bot: nil, replied_to: nil)
      @text      = text
      @context   = context
      @knowledge = knowledge
      @replied_to = replied_to
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

      AGENT_LOGGER.info "START chat=#{@chat_id} user=#{@user.name} (#{@user.role})\nREQUEST: #{@text}"

      MAX_ITERATIONS.times do |i|
        raw = GptMaster.new(messages, setting: @setting).call_raw(tools: tools)
        return 'жпт не жпт' unless raw

        tool_calls = extract_tool_calls(raw)

        if tool_calls.empty?
          text = extract_text(raw) || 'жпт не жпт'
          AGENT_LOGGER.info "DONE (#{i + 1} iteration#{i > 0 ? 's' : ''}, no tools)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
          return text
        end

        AGENT_LOGGER.info "iteration #{i + 1}: #{tool_calls.map { |t| "#{t[:name]}(#{t[:input].to_json})" }.join(', ')}"
        messages << build_assistant_message(raw)

        tool_calls.each do |tc|
          LOGGER.debug "agent tool: #{tc[:name]}(#{tc[:input].to_json})"
          result = execute_tool(tc[:name], tc[:input])
          AGENT_LOGGER.info "  #{tc[:name]} → #{result[0..300]}#{result.length > 300 ? '...' : ''}"
          LOGGER.debug "agent result: #{result[0..300]}#{result.length > 300 ? '...' : ''}"
          messages << build_tool_result_message(tc[:id], result)
        end
      end

      # Safety: final call without tools to force a text response
      text = GptMaster.new(messages, setting: @setting).call || 'жпт не жпт'
      AGENT_LOGGER.info "DONE (#{MAX_ITERATIONS} iterations, forced final)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
      text
    end

    private

    def build_initial_messages
      prompt_template = Settings.chat_gpt['agent_prompt'] || Settings.chat_gpt['prompt']
      # gsub main placeholders first, then ERB for conditional blocks
      replied_to = @replied_to
      content = prompt_template
        .gsub('{REQUEST}', @text)
        .gsub('{CONTEXT}', @context)
        .gsub('{KNOWLEDGE}', @knowledge)
      content = ERB.new(content, trim_mode: '-').result(binding)
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
      AGENT_LOGGER.error "  #{name} ERROR: #{e.class}: #{e.message}"
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

require 'erb'
require_relative 'scratchpad'
require_relative 'tool_result'

module Agent
  class Runner
    MAX_ITERATIONS = 5
    MAX_TOOL_RESULT_LENGTH = 2000
    TOOL_RESULT_PREVIEW_CHARS = 600

    def initialize(text:, context:, knowledge:, radio:, chat_id:, user:, bot: nil, image: nil, phrase: nil, audio: nil, reply_to_message_id: nil, message_id: nil)
      @text       = text
      @context    = context
      @knowledge  = knowledge
      @image      = image
      @phrase     = phrase
      @audio      = audio
      @radio      = radio
      @chat_id    = chat_id
      @user       = user
      @message_id = message_id
      # When the user attached/replied with an image, route through `agent_vision`
      # (typically Anthropic with vision) so the model can actually see it. The
      # text-only `agent` setting (typically DeepSeek for cheaper tool-loop runs)
      # doesn't accept image content blocks. Falls back to `agent` if the chosen
      # setting isn't configured — preserves backward compat for envs / tests
      # that haven't defined an `agent_vision` setting.
      @setting   = pick_setting
      @api_type  = GptMaster.resolve_setting(@setting)[:api_type]
      @tool_ctx  = { radio: radio, chat_id: chat_id, user: user, bot: bot,
                     image: image, audio: audio,
                     reply_to_message_id: reply_to_message_id }
    end

    def pick_setting
      return 'agent' unless @image
      has_vision = Settings.chat_gpt&.dig('settings')&.key?('agent_vision')
      has_vision ? 'agent_vision' : 'agent'
    end

    def run
      system_prompt, user_content = build_initial_content
      messages = build_initial_messages(user_content)
      tools    = ToolRegistry.definitions_for(user_role: @user.role, api_type: @api_type)

      alog :info, "START user=#{@user.name} (#{@user.role})\nREQUEST: #{@text}"

      generate_image_called = false
      watchdog_fired        = false

      MAX_ITERATIONS.times do |i|
        iter_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raw = new_gpt(messages, system_prompt).call_raw(tools: tools)
        return 'жпт не жпт' unless raw

        stop       = extract_stop_reason(raw)
        tool_calls = extract_tool_calls(raw)
        iter_ms    = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - iter_t0) * 1000).round

        if tool_calls.empty?
          text = extract_text(raw) || 'жпт не жпт'

          # Image-hallucination watchdog: Grok occasionally imitates the
          # `🎨 <caption>` format used by image-gen replies in chat history
          # instead of calling generate_image. If the agent ends the turn
          # with that pattern but never actually invoked generate_image,
          # nudge it once and re-loop.
          if !generate_image_called && !watchdog_fired && hallucinated_image_caption?(text)
            watchdog_fired = true
            alog :warn, "watchdog: 🎨 caption in text but no generate_image call — nudging"
            messages << build_assistant_message(raw)
            messages << build_image_call_nudge
            next
          end

          alog :info, "DONE (#{i + 1} iteration#{i > 0 ? 's' : ''}, stop=#{stop}, no tools, took=#{iter_ms}ms)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
          return text
        end

        alog :info, "iteration #{i + 1} [stop=#{stop} took=#{iter_ms}ms]: #{tool_calls.map { |t| "#{t[:name]}(#{t[:input].to_json})" }.join(', ')}"
        messages << build_assistant_message(raw)

        tool_calls.each do |tc|
          generate_image_called = true if tc[:name] == 'generate_image'
          tool_t0  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result   = execute_tool(tc[:name], tc[:input])
          tool_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - tool_t0) * 1000).round
          alog :info, "  #{tc[:name]} took=#{tool_ms}ms → #{result[0..TOOL_RESULT_PREVIEW_CHARS]}#{result.length > TOOL_RESULT_PREVIEW_CHARS ? '...' : ''}"
          messages << build_tool_result_message(tc[:id], result)
        end
      end

      # Safety: MAX_ITERATIONS hit without the agent producing a final text response.
      # Append an explicit instruction, then call without tools so the model must
      # commit to text using whatever information it has already gathered.
      alog :warn, "MAX_ITERATIONS (#{MAX_ITERATIONS}) reached, forcing no-tool finalizer"
      messages << build_tool_budget_instruction
      text = new_gpt(messages, system_prompt).call
      if text.nil? || text.strip.empty?
        alog :warn, "forced-final produced empty reply even with explicit instruction — falling back to stub"
        text = 'жпт не жпт'
      end
      alog :info, "DONE (#{MAX_ITERATIONS} iterations, forced final)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
      text
    end

    # Synthetic user turn appended before the forced-final call so the model
    # stops fishing for more tools and commits to a text reply with whatever
    # it has already gathered.
    def build_tool_budget_instruction
      msg = 'Лимит вызова инструментов исчерпан. Дай пользователю текстовый ответ ' \
            'по-русски прямо сейчас, используя только уже собранную информацию. ' \
            'Не вызывай больше инструменты. Если данных мало — ответь честно по ' \
            'тому, что есть, добавив свою оценку или шутку.'
      if anthropic?
        { role: 'user', content: [{ type: 'text', text: msg }] }
      else
        { role: 'user', content: msg }
      end
    end

    # Heuristic for the "described an image as text instead of calling
    # generate_image" failure mode (mostly Grok). Triggers only when 🎨
    # starts a paragraph (line start, possibly indented) and is followed by
    # ≥80 chars on the same paragraph — short inline uses
    # ("я нарисовал 🎨 кошку"), even with long trailing text on the same
    # line, don't match because they aren't paragraph-anchored.
    HALLUCINATED_IMAGE_CAPTION = /(?:\A|\n)\s*🎨.{80,}/m
    def hallucinated_image_caption?(text)
      return false if text.nil? || text.empty?
      text.match?(HALLUCINATED_IMAGE_CAPTION)
    end

    def build_image_call_nudge
      msg = 'Ты описал картинку текстом, но не вызвал инструмент generate_image. ' \
            'Сейчас вызови generate_image с подходящим request — без описания в тексте, ' \
            'без 🎨-префикса, картинку отрисует сам инструмент.'
      if anthropic?
        { role: 'user', content: [{ type: 'text', text: msg }] }
      else
        { role: 'user', content: msg }
      end
    end

    private

    def alog(level, msg)
      LOGGER.send(level, "[chat=#{@chat_id}] [AGENT] #{msg}")
    end

    def new_gpt(messages, system_prompt)
      GptMaster.new(messages, setting: @setting,
                    chat_id: @chat_id, user_uid: @user&.uid, purpose: 'agent',
                    system_prompt: system_prompt)
    end

    # Render prompt template, split on CACHE_BREAK_MARKER, return [system_prompt, user_content].
    # ERB is rendered on the pristine template; user-controlled strings (request/context/knowledge)
    # are substituted *after* ERB evaluation so they can't be interpreted as template tags.
    def build_initial_content
      image      = @image
      phrase     = @phrase
      scratchpad = Agent::Scratchpad.render(@chat_id)
      rendered = ERB.new(Settings.chat_gpt['agent_prompt'], trim_mode: '-').result(binding)
      content = rendered
        .gsub('{USER}')       { trigger_user_display }
        .gsub('{MESSAGE_ID}') { @message_id.to_s }
        .gsub('{REQUEST}')    { @text.to_s }
        .gsub('{CONTEXT}')    { @context.to_s }
        .gsub('{KNOWLEDGE}')  { @knowledge.to_s }
        .gsub('{SCRATCHPAD}') { scratchpad }
      content += "\n\n#{audio_hint}" if @audio
      GptMaster.split_cache_break(content)
    end

    # Display name for the user who triggered this turn — same `name (Full Name)`
    # format used by ChatContext.serialize_msg's `who` field, so the agent sees
    # one consistent identity across context entries and the trigger line.
    # Pre-fix the trigger line was just `Запрос из чата: [...]` with no
    # attribution, and the agent occasionally addressed the wrong user when
    # multiple participants had recent messages in the context window.
    def trigger_user_display
      return 'неизвестный' unless @user
      full_name = [@user.first_name, @user.last_name].compact.reject(&:empty?).join(' ')
      full_name.empty? ? @user.name.to_s : "#{@user.name} (#{full_name})"
    end

    # When the user attaches audio, hint the model so it picks add_vocals /
    # cover_audio when the caption is ambiguous. Includes title/duration when
    # Telegram provided them so the agent has something to caption with.
    def audio_hint
      bits = []
      bits << "title=#{@audio[:title].inspect}" if @audio[:title]
      bits << "performer=#{@audio[:performer].inspect}" if @audio[:performer]
      bits << "duration=#{@audio[:duration]}s" if @audio[:duration]
      bits << "mime=#{@audio[:mime_type]}" if @audio[:mime_type]
      desc = bits.empty? ? '' : " (#{bits.join(', ')})"
      "[К сообщению прикреплён аудиофайл#{desc}. Если непонятно, что с ним делать — спроси: подпеть (add_vocals), сделать кавер (cover_audio), или другое.]"
    end

    def build_initial_messages(user_content)
      if @image
        # Always build the Anthropic-shape vision block. GptMaster.build_body
        # converts to OpenAI shape ({type: 'image_url', image_url: {url: data-uri}})
        # at the wire boundary for openai-compat providers (Grok, OpenAI, etc).
        # Routing decides which model sees it via pick_setting → agent_vision.
        [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: @image[:media_type], data: @image[:data] } },
          { type: 'text', text: user_content }
        ] }]
      else
        [{ role: 'user', content: user_content }]
      end
    end

    def execute_tool(name, input)
      tool = ToolRegistry.find(name)
      unless tool
        alog :warn, "unknown tool #{name}"
        return "Ошибка: неизвестный инструмент #{name}"
      end

      if tool.admin_only && @user.role != 'admin'
        messages = Settings.replies&.dig('admin_denied') rescue nil
        return messages&.sample || "Ошибка: недостаточно прав для #{name}"
      end

      result = tool.handler.call(input, @tool_ctx)
      truncate(materialize_result(result))
    rescue => e
      alog :error, "tool #{name} error: #{e.class}: #{e.message}"
      "идите нахуй"
    end

    # Tools may return Agent::ToolResult for structured outcomes. For deferred
    # results, persist the intent to scratchpad here and surface a structured
    # prefix to the LLM. Plain String returns pass through unchanged.
    def materialize_result(result)
      return result.to_s unless result.is_a?(Agent::ToolResult)
      return result.user_text unless result.deferred?

      due_at = result.retry_in_min ? (Time.now + result.retry_in_min * 60) : nil
      Agent::Scratchpad.add(@chat_id, category: 'intentions',
                            content: result.deferred_intent, due_at: due_at)
      alog :info, "auto-remember (deferred): #{result.deferred_intent[0..120]}"
      retry_part = result.retry_in_min ? " retry_in=#{result.retry_in_min}min" : ''
      "[deferred#{retry_part}, intent saved to scratchpad] #{result.user_text}"
    rescue => e
      alog :warn, "scratchpad add failed: #{e.class}: #{e.message}"
      result.user_text
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

    def extract_stop_reason(raw)
      if anthropic?
        raw['stop_reason']
      else
        raw.dig('choices', 0, 'finish_reason')
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

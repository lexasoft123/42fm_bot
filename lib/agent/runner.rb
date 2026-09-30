require 'erb'
require_relative 'scratchpad'
require_relative 'tool_result'
require_relative 'error_reporter'

module Agent
  class Runner
    MAX_ITERATIONS = 5
    MAX_TOOL_RESULT_LENGTH = 2000
    TOOL_RESULT_PREVIEW_CHARS = 600
    # Per-iteration latency above this threshold gets a WARN-level log so
    # slow API calls show up in `grep WARN log/bot.log` without having to
    # parse every iteration line. Pile-up of slow iterations is what
    # backs up `bot.listen`'s single-threaded queue.
    SLOW_ITERATION_MS = 5_000
    # finish/stop reasons meaning the output budget ran out (reasoning counts
    # toward it on DeepSeek) — retrying the same context would just repeat it.
    OUTPUT_BUDGET_STOPS = %w[length max_tokens].freeze
    EMPTY_REPLY_NUDGE = 'Ответ на запрос пользователя не дошёл — текста не было. Ответь сейчас: ' \
                        'если нужен инструмент, вызови его; иначе дай текстовый ответ по-русски.'.freeze
    SAFE_FAILURE_REPLY = 'Не смог нормально оформить ответ — попробуй ещё раз.'.freeze
    UNKNOWN_STATUS_REPLY = 'Не могу подтвердить текущий статус задачи — сначала нужно проверить его через task_status.'.freeze
    INTEGRITY_NUDGE = 'Предыдущий текст содержит внутренний синтаксис агента или вызова инструмента. ' \
                      'Перепиши только пользовательский ответ обычным русским текстом. Не показывай ' \
                      'рассуждения, JSON, имена функций, служебные поля и не вызывай инструменты. ' \
                      'Не утверждай статус очереди, генерации или доставки, если он не подтверждён ' \
                      'результатом уже выполненного инструмента.'.freeze

    def initialize(text:, context:, knowledge:, radio:, chat_id:, user:, api: nil, image: nil, phrase: nil, audio: nil, reply_to_message_id: nil, message_id: nil, user_initiated: true, forum_thread_id: nil, private_chat: false, tools_enabled: true, report_errors: true)
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
      # True only for real user turns (gpt_chat/gpt_question). The agent-event
      # loop reuses Runner with a synthetic prompt that echoes the original
      # request, so the draw-directive watchdog must stay OFF there — otherwise
      # it would re-trigger image-gen on the very loop built to prevent that.
      @user_initiated = user_initiated
      @tools_enabled = tools_enabled
      @report_errors = report_errors
      # Only payloads produced by ToolResult.action inside this Runner are
      # authoritative. Provider-written JSON must never manufacture state.
      @trusted_action_payloads = {}
      @latest_evidence = {}
      @latest_evidence_batch = []
      @evidence_sequence = 0
      # When the user attached/replied with an image, route through `agent_vision`
      # (typically Anthropic with vision) so the model can actually see it. The
      # text-only `agent` setting (typically DeepSeek for cheaper tool-loop runs)
      # doesn't accept image content blocks. Falls back to `agent` if the chosen
      # setting isn't configured — preserves backward compat for envs / tests
      # that haven't defined an `agent_vision` setting.
      @setting   = pick_setting
      @api_type  = GptMaster.resolve_setting(@setting)[:api_type]
      # Images fetched mid-loop by tools (view_image) — queued here by
      # materialize_result, injected into `messages` after the iteration's
      # tool results, then the setting upgrades to agent_vision.
      @pending_images = []
      LOGGER.warn "[chat=#{chat_id}] Agent::Runner initialized without Telegram api — tools that send media will fail" unless api
      @tool_ctx  = { radio: radio, chat_id: chat_id, user: user, api: api,
                     image: image, audio: audio,
                     audio_source: audio && audio[:source],
                     # Tools that pick an IMPLIED source (no reply/attachment)
                     # must not do so on synthetic agent_event/cron turns, and
                     # must stay inside the forum topic the request came from.
                     user_initiated: user_initiated,
                     forum_thread_id: forum_thread_id,
                     # For PendingAudioRequest: replay this request when the
                     # user's next DM message is the missing audio file.
                     private_chat: private_chat,
                     request_text: text,
                     message_id: message_id,
                     reply_to_message_id: reply_to_message_id,
                     can_view_image: can_view_image? }
    end

    def pick_setting
      return 'agent' unless @image
      has_vision = Settings.chat_gpt&.dig('settings')&.key?('agent_vision')
      has_vision ? 'agent_vision' : 'agent'
    end

    # Whether the view_image tool can actually get an image in front of the
    # model this turn. True when we're already on agent_vision, or when
    # agent_vision exists AND shares api_type with the active setting — the
    # mid-loop switch replays accumulated assistant/tool messages, which are
    # provider-shaped; switching across api_types (anthropic ↔ openai)
    # would corrupt the request, so the tool degrades gracefully instead.
    def can_view_image?
      return true if @setting == 'agent_vision'
      return false unless Settings.chat_gpt&.dig('settings')&.key?('agent_vision')
      GptMaster.resolve_setting('agent_vision')[:api_type] == @api_type
    rescue => e
      LOGGER.warn "[chat=#{@chat_id}] [AGENT] can_view_image?: #{e.class}: #{e.message}" if defined?(LOGGER)
      false
    end

    attr_reader :last_turn_metrics

    def run
      reset_turn_metrics
      result = run_inner
      @turn_status = classify_turn_status(result)
      result
    rescue => e
      @turn_status = 'exception'
      raise
    ensure
      emit_turn_metrics
    end

    def run_inner
      system_prompt, user_content = build_initial_content
      messages = build_initial_messages(user_content)
      tools    = @tools_enabled ? ToolRegistry.definitions_for(user_role: @user.role, api_type: @api_type) : []

      alog :info, "START user=#{@user.name} (#{@user.role})\nREQUEST: #{@text}"

      generate_image_called = false
      watchdog_fired        = false
      blank_retried         = false
      task_status_called    = false
      status_watchdog_fired = false

      MAX_ITERATIONS.times do |i|
        @turn_iterations = i + 1
        iter_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raw = new_gpt(messages, system_prompt).call_raw(tools: tools)
        return @user_initiated ? SAFE_FAILURE_REPLY : '' unless raw

        stop       = extract_stop_reason(raw)
        tool_calls = extract_tool_calls(raw)
        iter_ms    = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - iter_t0) * 1000).round
        alog :warn, "slow iteration #{i + 1}: took=#{iter_ms}ms (threshold #{SLOW_ITERATION_MS}ms)" if iter_ms > SLOW_ITERATION_MS

        if tool_calls.empty?
          text = extract_text(raw)
          if text.nil? || text.strip.empty?
            # Synthetic agent_event/cron turn: blank means the agent chose
            # silence (AgentEventHandler) — not a failure.
            return '' unless @user_initiated

            # User turn: a blank reply used to reach deliver as "" and be
            # dropped silently. Budget exhaustion won't improve on a retry of
            # the same context (and would block the loop again) → visible stub.
            if OUTPUT_BUDGET_STOPS.include?(stop.to_s) || blank_retried
              alog :warn, "empty reply (iteration #{i + 1}, stop=#{stop}#{blank_retried ? ', after retry' : ''}) — returning stub"
              return SAFE_FAILURE_REPLY
            end
            # A photo is already in hand and the user explicitly asked to edit
            # it. Do not make the vision model act as a policy gate: enqueue the
            # raw request directly and let the image backend decide what it can
            # render.
            if direct_image_edit_request?
              generate_image_called = true
              direct_result = dispatch_direct_image_edit
              return finalize_output(direct_result, messages: messages, system_prompt: system_prompt,
                                     tools: tools, iteration: i + 1) unless Agent::ErrorReporter.tool_error_result?(direct_result)
              append_user_nudge(messages, direct_image_error_nudge(direct_result))
              next
            end

            # One more pass WITH tools. The blank assistant turn is not
            # replayed; a draw directive gets the image nudge (watchdog)
            # instead of the generic one.
            blank_retried = true
            draw = !generate_image_called && !watchdog_fired && image_request_unanswered?
            watchdog_fired ||= draw
            alog :warn, "empty reply (iteration #{i + 1}, stop=#{stop}) — #{draw ? 'draw directive, nudging generate_image' : 'retrying with tools'}"
            append_user_nudge(messages, draw ? image_call_nudge_text : EMPTY_REPLY_NUDGE)
            next
          end

          # A status answer without task_status is necessarily a guess. For a
          # narrow, explicit current-user status question, perform the missing
          # read-only lookup once and feed its trusted result back to the model.
          status_args = task_status_request_args unless task_status_called || status_watchdog_fired
          if status_args
            status_watchdog_fired = true
            alog :warn, "watchdog: explicit task-status request without task_status call — checking#{status_args['task_id'] ? " ##{status_args['task_id']}" : ' recent tasks'}"
            call_id = "task_status_watchdog_#{i + 1}"
            messages << build_task_status_watchdog_call(call_id, status_args)
            result = execute_tool('task_status', status_args)
            messages << build_tool_result_message(call_id, result)
            next
          end

          # Image watchdog: the agent sometimes promises/describes an image but
          # never calls generate_image — either imitating the `🎨 <caption>`
          # format from chat history, or answering an explicit draw directive
          # ("дорисуй…") with a bare promise ("ща сделаю"). If the turn ends
          # with no generate_image call in either case, nudge once and re-loop.
          hallucinated = hallucinated_image_caption?(text)
          if !generate_image_called && !watchdog_fired && (hallucinated || image_request_unanswered?)
            if direct_image_edit_request?
              generate_image_called = true
              direct_result = dispatch_direct_image_edit
              return finalize_output(direct_result, messages: messages, system_prompt: system_prompt,
                                     tools: tools, iteration: i + 1) unless Agent::ErrorReporter.tool_error_result?(direct_result)
              messages << build_assistant_message(raw)
              append_user_nudge(messages, direct_image_error_nudge(direct_result))
              next
            end

            watchdog_fired = true
            reason = hallucinated ? '🎨 caption in text' : 'draw directive in request'
            alog :warn, "watchdog: #{reason} but no generate_image call — nudging"
            messages << build_assistant_message(raw)
            messages << build_image_call_nudge
            next
          end

          alog :info, "DONE (#{i + 1} iteration#{i > 0 ? 's' : ''}, stop=#{stop}, no tools, took=#{iter_ms}ms)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
          return finalize_output(text, messages: messages, system_prompt: system_prompt,
                                 tools: tools, iteration: i + 1, raw: raw)
        end


        task_status_called ||= tool_calls.any? { |tc| tc[:name] == 'task_status' }

        # `tools: []` is advisory at the provider boundary: a malformed or
        # prompt-injected response can still contain fabricated tool calls.
        # Runtime-error turns require a hard execution boundary, so answer each
        # call with a disabled result and let the model produce plain text.
        unless @tools_enabled
          alog :warn, "blocked #{tool_calls.length} provider-supplied tool call(s) while tools are disabled"
          messages << build_assistant_message(raw)
          tool_calls.each do |tc|
            result = JSON.generate(status: 'error', source: "tool.#{tc[:name]}",
                                   message: 'tools are disabled for this turn')
            messages << build_tool_result_message(tc[:id], result)
          end
          append_user_nudge(messages, 'Инструменты недоступны в этом служебном ходе. Ответь только текстом или (skip).')
          next
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

        # MUST stay strictly after the tool_calls.each block: openai requires
        # every tool_call answered by a `tool` message before any other role
        # appears, and the anthropic merge targets the last tool_result turn.
        inject_pending_images(messages) unless @pending_images.empty?
      end

      # Safety: MAX_ITERATIONS hit without the agent producing a final text response.
      # Append an explicit instruction, then call without tools so the model must
      # commit to text using whatever information it has already gathered.
      alog :warn, "MAX_ITERATIONS (#{MAX_ITERATIONS}) reached, forcing no-tool finalizer"
      messages << build_tool_budget_instruction
      text = new_gpt(messages, system_prompt).call
      if text.nil? || text.strip.empty?
        alog :warn, "forced-final produced empty reply even with explicit instruction — falling back to stub"
        text = SAFE_FAILURE_REPLY
      end
      alog :info, "DONE (#{MAX_ITERATIONS} iterations, forced final)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
      finalize_output(text, messages: messages, system_prompt: system_prompt,
                      tools: tools, iteration: MAX_ITERATIONS)
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

    # The user gave an explicit imperative draw/edit directive but the turn
    # ended without ever calling generate_image — i.e. the agent promised in
    # text ("ща нарисую/сделаю") instead of acting (prod silent-failure mode).
    # Cyrillic-stem match (Ruby \b is ASCII-only, so match stems directly):
    # на/до/от/пере/под/за/с + рисуй(те), or bare рисуй(те). Deliberately NOT
    # сгенерируй — too generic ("сгенерируй пароль/текст/идею" isn't an image).
    # Gated to real user turns (@user_initiated): the agent-event path echoes
    # the original request into @text and must not re-trigger image-gen.
    DRAW_DIRECTIVE = /(?:на|до|от|пере|под|за|с)?рису(?:й|йте)/i
    # Deliberately broad only when a source image is attached/replied to.
    # These verbs are ambiguous in plain text ("сними ролик", "убери комнату"),
    # but unambiguously request an image edit when @image exists.
    IMAGE_EDIT_DIRECTIVE = /(?:измени(?:те)?|изменьте|передела(?:й|йте)|отредактиру(?:й|йте)|замени(?:те)?|заменьте|убери(?:те)?|добавь(?:те)?|сними(?:те)?|раздень(?:те)?|переодень(?:те)?|поменя(?:й|йте))/i
    IMAGE_MODEL_MENTIONS = [
      [/nano[\s_-]*banana[\s_-]*pro/i, 'nano-banana-pro'],
      [/nano[\s_-]*banana/i, 'nano-banana-2'],
      [/sunburst|gpt[\s_-]*image/i, 'gpt-image-2.5-sunburst'],
      [/qwen/i, 'qwen-image-3-pro'],
      [/seedream/i, 'seedream-5-pro'],
      [/wan/i, 'wan-2.7'],
      [/flux/i, 'flux-2-pro'],
    ].freeze

    def image_request_unanswered?
      return false unless @user_initiated
      return false if @text.nil? || @text.empty?
      @text.match?(DRAW_DIRECTIVE) || direct_image_edit_request?
    end

    def direct_image_edit_request?
      @user_initiated && @image.is_a?(Hash) && @image[:data] &&
        !@text.to_s.empty? && @text.match?(IMAGE_EDIT_DIRECTIVE)
    end

    def dispatch_direct_image_edit
      args = { 'prompt' => @text, 'edit_source' => true }
      model = IMAGE_MODEL_MENTIONS.find { |pattern, _key| @text.match?(pattern) }&.last
      args['model'] = model if model
      alog :warn, "direct image-edit fallback: vision model returned no tool call; " \
                  "dispatching generate_image#{model ? " model=#{model}" : ''}"
      execute_tool('generate_image', args)
    end

    def direct_image_error_nudge(result)
      "Прямая попытка вызвать generate_image завершилась ошибкой: #{result}. " \
        'Учти эту ошибку и дай пользователю нормальный ответ или выбери другой доступный подход.'
    end

    def image_call_nudge_text
      'Похоже, надо нарисовать/дорисовать картинку, но ты не вызвал инструмент ' \
      'generate_image (только описал словами или пообещал). Сейчас вызови generate_image ' \
      'с подходящим request — без описания в тексте и без 🎨-префикса; если правишь ' \
      'присланное фото, добавь edit_source. Картинку отрисует сам инструмент.'
    end

    def build_image_call_nudge
      msg = image_call_nudge_text
      if anthropic?
        { role: 'user', content: [{ type: 'text', text: msg }] }
      else
        { role: 'user', content: msg }
      end
    end

    # Returns task_status arguments only for an explicit lifecycle question in
    # the current request. Quoted/code/example/history fragments are excluded;
    # ordinary uses of "status" or "готово" without a background-task subject
    # do not qualify. Multiple IDs are ambiguous and deliberately do nothing.
    def task_status_request_args
      return unless @user_initiated && @tools_enabled && Agent::ToolRegistry.find('task_status')

      value = status_request_prose(@text)
      return if value.empty?
      return if value.match?(/(?:\b(?:example|quote|quoted|translate|git|http)\b|пример|цитат|перевед|что\s+значит|объясни|в\s+истори|из\s+истори|history\s+(?:says|said)|previous\s+message)/i)

      subject = /(?:задач|генераци|картинк|изображени|песн|трек|кавер|аудио)\w*|\b(?:task|job|generation|image|song|track|cover|audio)\b/i
      explicit_status = /(?:статус|состоян|прогресс|очеред|выполня|обрабаты|достав|что\s+(?:там\s+)?с|(?:как|где)\s+(?:там\s+)?(?:задач|генераци|картинк|изображени|песн|трек|кавер|аудио)|\b(?:status|state|progress|queued|running|processing|delivered)\b|\b(?:how|where)\s+is\b|\bwhat(?:'s|\s+is)\s+happening\s+with\b)/i
      completion = /(?:готов|заверш|сделан|закончен|упал|ошибк)\w*|\b(?:done|ready|finished|complete|failed)\b/i
      request_frame = /\?|(?:^|\s)(?:проверь|скажи|покажи|узнай|что|как|где|есть\s+ли|готова?\s+ли)\b|\b(?:check|show|tell|is|are|was|were|what|how|where)\b/i
      return unless value.match?(subject)
      return unless value.match?(explicit_status) || (value.match?(completion) && value.match?(request_frame))

      ids = value.scan(/(?:задач\w*|task)\s*#?\s*(\d+)|#\s*(\d+)/i)
                 .flatten.compact.map(&:to_i).select(&:positive?).uniq
      return if ids.length > 1
      ids.empty? ? {} : { 'task_id' => ids.first }
    end

    def status_request_prose(text)
      text.to_s
          .gsub(/```.*?```/m, ' ')
          .gsub(/`[^`]*`/, ' ')
          .gsub(/«[^»]*»|“[^”]*”|"[^"]*"|'[^']*'/m, ' ')
          .lines.reject { |line| line.match?(/^\s*>/) }.join(' ').strip
    end

    def build_task_status_watchdog_call(call_id, args)
      if anthropic?
        { role: 'assistant', content: [{ type: 'tool_use', id: call_id, name: 'task_status', input: args }] }
      else
        { role: 'assistant', content: nil, tool_calls: [{ id: call_id, type: 'function',
          function: { name: 'task_status', arguments: JSON.generate(args) } }] }
      end
    end

    # Add a synthetic user instruction without an assistant turn in between.
    # Anthropic forbids two consecutive user turns, so there the text is
    # merged into the last user message (initial request or tool_result turn);
    # openai-compat accepts a fresh user turn after user/tool messages.
    def append_user_nudge(messages, text)
      last = messages.last
      if anthropic? && last && (last[:role] || last['role']) == 'user'
        content = last[:content]
        blocks = content.is_a?(String) ? [{ type: 'text', text: content }] : Array(content)
        last[:content] = blocks + [{ type: 'text', text: text }]
      elsif anthropic?
        messages << { role: 'user', content: [{ type: 'text', text: text }] }
      else
        messages << { role: 'user', content: text }
      end
    end

    private

    def alog(level, msg)
      LOGGER.send(level, "[chat=#{@chat_id}] [AGENT] #{msg}")
    end

    def new_gpt(messages, system_prompt)
      @turn_llm_calls += 1 if @turn_metrics_active
      GptMaster.new(messages, setting: @setting,
                    chat_id: @chat_id, user_uid: @user&.uid, purpose: 'agent',
                    system_prompt: system_prompt, report_errors: @report_errors)
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

    # Flat label for the trigger line (single source of truth: shared with
    # ChatContext.serialize_msg's `who` field via ChatContext.display_name,
    # so trigger and history rows agree on every edge case).
    def trigger_user_display
      return 'unknown' unless @user
      ChatContext.display_name(name: @user.name, first_name: @user.first_name, last_name: @user.last_name)
    end

    # When the user attaches audio, hint the model so it picks add_vocals /
    # cover_audio / separate_vocals when the caption is ambiguous. Includes
    # title/duration when Telegram provided them so the agent has something
    # to caption with. When a title is present, also tell the agent
    # EXPLICITLY to use it — otherwise it tends to invent one from prior chat
    # context (e.g. yesterday's cover) and the user gets a track named after
    # the wrong song.
    #
    # A :lookback match (AudioAttachment — an earlier upload, not on this
    # message) is worded as "someone posted this N min ago": prod 2026-08-24
    # a stale lookback file was treated as "the attached song" and the wrong
    # song got covered.
    def audio_hint
      bits = []
      bits << "title=#{@audio[:title].inspect}" if @audio[:title]
      bits << "performer=#{@audio[:performer].inspect}" if @audio[:performer]
      bits << "duration=#{@audio[:duration]}s" if @audio[:duration]
      bits << "mime=#{@audio[:mime_type]}" if @audio[:mime_type]
      desc = bits.empty? ? '' : " (#{bits.join(', ')})"
      options = 'подпеть (add_vocals), сделать кавер (cover_audio), убрать вокал/разделить на дорожки (separate_vocals), или другое'
      if @audio[:source] == :lookback
        who = audio_uploader_display
        return "[К этому сообщению аудио НЕ прикреплено. В чате #{@audio[:age_min]} мин назад #{who} прислал(а) аудиофайл#{desc}. " \
               "Используй его, только если запрос явно про этот трек; если запрос не про него или непонятно — спроси, о каком треке речь. " \
               "Варианты: #{options}.]"
      end
      use_title = @audio[:title] ? " Используй title (и performer если есть) как основу для названия выходного трека — НЕ выдумывай имя из контекста чата." : ''
      "[К сообщению прикреплён аудиофайл#{desc}.#{use_title} Если непонятно, что с ним делать — спроси: #{options}.]"
    end

    def audio_uploader_display
      u = @audio[:uploader_uid] && User.find_by(uid: @audio[:uploader_uid])
      return 'кто-то' unless u
      ChatContext.display_name(name: u.name, first_name: u.first_name, last_name: u.last_name)
    rescue => e
      alog :warn, "audio_uploader_display failed: #{e.class}: #{e.message}"
      'кто-то'
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
      @turn_tool_calls += 1 if @turn_metrics_active
      unless @tools_enabled
        alog :warn, "blocked tool #{name} while tools are disabled"
        return JSON.generate(status: 'error', source: "tool.#{name}",
                             message: 'tools are disabled for this turn')
      end

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
      materialized = materialize_result(result)
      record_task_status_evidence(materialized) if name == 'task_status'
      truncate(materialized)
    rescue => e
      alog :error, "tool #{name} error: #{e.class}: #{e.message}"
      Agent::ErrorReporter.tool_result(source: "tool.#{name}", error: e)
    end

    # Inject tool-fetched images (view_image) into the conversation so the
    # model can actually see them, then upgrade to the vision setting.
    # Image blocks use the Anthropic shape everywhere; GptMaster rewrites
    # them to OpenAI `image_url` at the wire for openai-compat providers.
    def inject_pending_images(messages)
      blocks = @pending_images.map do |img|
        { type: 'image', source: { type: 'base64', media_type: img[:media_type], data: img[:data] } }
      end
      if anthropic?
        # Anthropic forbids two consecutive user turns — merge the image
        # blocks into the last tool_result user message instead (a user turn
        # may carry tool_result + image blocks together). Array() guards the
        # implicit invariant that messages.last is the array-content
        # tool_result turn the each-loop just appended — a string-content
        # message would otherwise raise on `+`.
        last = messages.last
        last[:content] = Array(last[:content]) + blocks
      else
        # openai: a fresh user turn after all tool messages is valid.
        messages << { role: 'user', content: blocks + [
          { type: 'text', text: 'Выше — картинк(и), загруженные через view_image. Рассмотри их и используй для ответа.' }
        ] }
      end
      upgrade_to_vision!(messages)
      @pending_images = []
    end

    # Switch the remaining iterations of this turn to the vision setting.
    # Only reachable when can_view_image? was true, which guarantees
    # agent_vision exists and shares api_type with the current setting —
    # so the accumulated messages stay wire-compatible and `tools` need no
    # rebuild. Provider-specific extension fields still differ within one
    # api_type: DeepSeek assistant messages carry `reasoning_content`,
    # which another openai-compat endpoint (grok) may reject on replay —
    # strip it.
    def upgrade_to_vision!(messages)
      return if @setting == 'agent_vision'
      messages.each { |m| m.delete('reasoning_content') if m.is_a?(Hash) }
      alog :info, "view_image: upgrading setting #{@setting} → agent_vision for the rest of the turn"
      @setting  = 'agent_vision'
      # No-op under can_view_image?'s same-api_type invariant, but keeps
      # @setting/@api_type from ever drifting if that invariant changes.
      @api_type = GptMaster.resolve_setting(@setting)[:api_type]
    end

    # Tools may return Agent::ToolResult for structured outcomes. Image
    # results queue their payload for inject_pending_images (checked FIRST —
    # an image result is never deferred, and falling through to the deferred
    # guard would silently drop the image). For deferred results, persist
    # the intent to scratchpad here and surface a structured prefix to the
    # LLM. Plain String returns pass through unchanged.
    def materialize_result(result)
      return result.to_s unless result.is_a?(Agent::ToolResult)
      if result.image?
        @pending_images << result.image
        return result.user_text
      end
      if result.action?
        payload = result.action_payload
        register_trusted_action(payload)
        return JSON.generate(payload)
      end
      return result.user_text unless result.deferred?

      due_at = result.retry_in_min ? (Time.now + result.retry_in_min * 60) : nil
      Agent::Scratchpad.add(@chat_id, category: 'intentions',
                            content: result.deferred_intent, due_at: due_at)
      alog :info, "auto-remember (deferred): #{result.deferred_intent[0..120]}"
      payload = {
        status: 'deferred', action: 'retry_later', retry_in_min: result.retry_in_min,
        intent_saved: true, message: result.user_text
      }.compact
      register_trusted_action(payload)
      JSON.generate(payload)
    rescue => e
      alog :warn, "scratchpad add failed: #{e.class}: #{e.message}"
      result.user_text
    end

    # Final user-visible text is a trust boundary. Providers occasionally emit
    # their private scratchpad syntax or serialize a tool call as prose. Give a
    # real user turn one bounded rewrite attempt, but never execute tool calls
    # from that attempt. Synthetic agent_event/cron turns stay silent.
    def finalize_output(text, messages:, system_prompt:, tools:, iteration:, raw: nil, correction_allowed: true)
      text = text.to_s
      action_text = action_outcome_message(text)
      return append_trusted_task_ids(action_text) if action_text
      return append_trusted_task_ids(text) unless integrity_violation?(text)

      alog :warn, "final-output integrity violation (iteration #{iteration})"
      return '' unless @user_initiated

      if correction_allowed && raw && iteration < MAX_ITERATIONS
        @turn_corrections += 1 if @turn_metrics_active
        correction_messages = messages.dup
        correction_messages << build_assistant_message(raw)
        append_user_nudge(correction_messages, INTEGRITY_NUDGE)
        corrected_raw = new_gpt(correction_messages, system_prompt).call_raw(tools: tools)
        if corrected_raw && extract_tool_calls(corrected_raw).empty?
          corrected = extract_text(corrected_raw).to_s
          return finalize_output(corrected, messages: correction_messages, system_prompt: system_prompt,
                                 tools: tools, iteration: iteration + 1, raw: corrected_raw,
                                 correction_allowed: false)
        else
          alog :warn, 'integrity correction returned a tool call or no response; tool call not executed'
        end
      end

      append_trusted_task_ids(deterministic_safe_output(text))
    rescue => e
      alog :warn, "final-output integrity gate failed: #{e.class}: #{e.message}"
      @user_initiated ? SAFE_FAILURE_REPLY : ''
    end

    def reset_turn_metrics
      @turn_metrics_active = true
      @turn_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @turn_iterations = 0
      @turn_llm_calls = 0
      @turn_tool_calls = 0
      @turn_corrections = 0
      @turn_status = 'unknown'
      @last_turn_metrics = nil
    end

    def classify_turn_status(result)
      return 'silence' if result.to_s.empty?
      return 'fallback' if result == SAFE_FAILURE_REPLY
      return 'unknown_status' if result == UNKNOWN_STATUS_REPLY
      'ok'
    end

    def emit_turn_metrics
      return unless @turn_metrics_active && @turn_started_at
      @turn_metrics_active = false
      @last_turn_metrics = {
        event: 'agent_turn',
        setting: @setting,
        took_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @turn_started_at) * 1000).round,
        iterations: @turn_iterations,
        llm_calls: @turn_llm_calls,
        tool_calls: @turn_tool_calls,
        corrections: @turn_corrections,
        status: @turn_status
      }
      alog :info, "METRIC #{JSON.generate(@last_turn_metrics)}"
    rescue => e
      LOGGER.warn "[chat=#{@chat_id}] [AGENT] metric emission failed: #{e.class}: #{e.message}" if defined?(LOGGER)
    end

    def integrity_violation?(text)
      value = text.to_s
      return true if value.strip.empty?
      return true if value.match?(/жпт\s+не\s+жпт/i)
      return true if value.match?(/(?:internal[\s_-]*monologue|внутренн(?:ий|ее)\s+(?:монолог|рассуждени\w*))\s*:?/i)
      return true if value.match?(/\.fullname\b/i)
      return true if value.match?(/\[deferred(?:\s|\]|,)/i)
      return true if value.match?(/<\/?(?:tool_call|think)(?:\s|>)/i)
      return true if value.match?(/\banalysis\s*:|assistant(?:\s+to|[-_]to)\s*[=:]/i)
      return true if value.match?(/\b(?:remember|forget)\s*\(/i)
      return true if tool_payload_json?(value)
      return true if operational_claim_unverified?(value)

      prose = value
      tool_names = Agent::ToolRegistry.tools.map(&:name).reject { |name| name.to_s.empty? }
      return false if tool_names.empty?

      prose.match?(/(?:\A|[\s`'"*:;,>\-])(?:#{tool_names.map { |name| Regexp.escape(name) }.join('|')})\s*\(/i)
    end

    def tool_payload_json?(text)
      json_candidates(text).any? do |candidate|
        parsed = JSON.parse(candidate)
        tool_payload_node?(parsed)
      rescue JSON::ParserError
        false
      end
    end

    def action_outcome_message(text)
      parsed = JSON.parse(text)
      return unless parsed.is_a?(Hash)
      return unless Agent::ToolResult::ACTION_STATUSES.include?(parsed['status'].to_s)
      return unless parsed['action'].is_a?(String)
      canonical = canonical_json(parsed)
      identities = @trusted_action_payloads[canonical]
      return unless identities && identities.all? { |identity| @latest_evidence[identity]&.dig(:canonical) == canonical }

      message = parsed['message'].to_s.strip
      return if message.empty? || integrity_violation?(message)
      message
    rescue JSON::ParserError
      nil
    end

    def deterministic_safe_output(text)
      stripped = text.to_s.sub(/\A\s*\[deferred[^\]]*\]\s*/i, '').strip
      return stripped unless stripped.empty? || integrity_violation?(stripped)

      operational_claims(text).empty? ? SAFE_FAILURE_REPLY : UNKNOWN_STATUS_REPLY
    end

    def register_trusted_action(payload)
      normalized = JSON.parse(JSON.generate(payload))
      canonical = canonical_json(normalized)
      @evidence_sequence += 1
      records = evidence_records(normalized, canonical: canonical, sequence: @evidence_sequence)
      identities = records.map { |record| record[:identity] }
      @trusted_action_payloads[canonical] = identities
      records.each { |record| @latest_evidence[record[:identity]] = record }
      @latest_evidence_batch = records
    end

    def record_task_status_evidence(text)
      payload = JSON.parse(text)
      return unless payload.is_a?(Hash) && payload['status'] == 'ok' && payload['tasks'].is_a?(Array)

      states = payload['tasks'].flat_map do |task|
        next [] unless task.is_a?(Hash)
        states_from_task(task['status'], task['phase'])
      end
      @latest_evidence_batch = [] if states.empty?
    rescue JSON::ParserError
      nil
    end

    def evidence_records(payload, canonical:, sequence:)
      items = Array(payload['items'])
      sources = if items.empty?
        [{
          'action' => payload['action'], 'task_id' => payload['task_id'],
          'task_type' => payload['task_type'], 'status' => payload['status'],
          'phase' => payload['phase'], 'delivery' => payload['delivery'],
        }]
      else
        items
      end

      sources.filter_map do |item|
        action = item['action'].to_s
        task_id = item['task_id']
        task_type = item['task_type']&.to_s
        next unless task_id.is_a?(Integer) && task_id.positive?

        identity = [action, task_id, task_type]
        {
          identity: identity, action: action, task_id: task_id, task_type: task_type,
          states: states_from_evidence(item), canonical: canonical, sequence: sequence,
        }
      end.tap do |records|
        # Non-task deferred/error outcomes can still be trusted for exact
        # unwrapping, but never authorize a task-state claim.
        if records.empty?
          records << {
            identity: [payload['action'].to_s, nil, payload['task_type']&.to_s],
            action: payload['action'].to_s, task_id: nil, task_type: payload['task_type']&.to_s,
            states: states_from_evidence(payload), canonical: canonical, sequence: sequence,
          }
        end
      end
    end

    # Specific phase/delivery always outranks coarse action status. In
    # particular processing is not queued, and completed+unknown is not sent.
    def states_from_evidence(payload)
      phase = payload['phase'].to_s
      delivery = payload['delivery'].to_s
      states = case phase
      when 'queued' then [:queued]
      when 'processing', 'delivering', 'persisting_delivery' then [:running]
      when 'retrying' then %i[running retrying]
      when 'completed' then [:completed]
      when 'failed' then [:failed]
      when 'deferred' then [:deferred]
      else
        case payload['status'].to_s
        when 'pending', 'queued' then [:queued]
        when 'done', 'sent' then [:completed]
        when 'failed' then [:failed]
        when 'deferred' then [:deferred]
        else []
        end
      end
      states << :sent if delivery == 'delivered'
      states << :failed if delivery == 'failed'
      states << :running if delivery == 'pending' && !states.include?(:completed)
      states.uniq
    end

    def states_from_task(status, phase)
      values = [status, phase].compact.map(&:to_s)
      states = []
      states << :queued if values.include?('queued')
      states << :running if (values & %w[processing delivering persisting_delivery]).any?
      states << :retrying if values.include?('retrying')
      states << :completed if (values & %w[done completed]).any?
      states << :failed if values.include?('failed')
      states
    end

    def operational_claim_unverified?(text)
      claims = operational_claims(text)
      return false if claims.empty?

      allowed = {
        queued: [:queued], running: %i[running retrying], retrying: [:retrying],
        completed: %i[completed sent], delivered: [:sent], failed: [:failed]
      }
      claims.any? do |claim|
        evidence = evidence_for_claim(claim)
        evidence.nil? || (allowed.fetch(claim[:kind]) & evidence[:states]).empty?
      end
    end

    def operational_claims(text)
      value = text.to_s
      segments = value.split(/(?<=[.!?])\s+|[;\n]+/).reject(&:empty?)
      claims = segments.flat_map do |segment|
        operational_claim_kinds(segment).map do |kind|
          {
            kind: kind,
            task_id: explicit_task_id(segment),
            task_type: claim_task_type(segment) || claim_task_type(@text.to_s),
          }
        end
      end

      if operational_followup_request?
        claims << { kind: :completed, task_id: explicit_task_id(value),
                    task_type: claim_task_type(value) || claim_task_type(@text.to_s) } if value.match?(/\A\s*(?:готов[оа]?|сделано)[!?.\s]*\z/i)
        claims << { kind: :delivered, task_id: explicit_task_id(value),
                    task_type: claim_task_type(value) || claim_task_type(@text.to_s) } if value.match?(/(?:смотри\s+выше|я\s+уже\s+отправил|она\s+пришла|вс[её]\s+есть|уже\s+в\s+чате|в\s+чате)[!?.\s]*\z/i)
      end

      (claims + structured_operational_claims(value)).uniq
    end

    def operational_claim_kinds(value)
      kinds = []
      subject = '(?:картинк|изображени|задач|трек|генераци)\\w*'
      en_subject = '(?:image|task|track|generation)'
      kinds << :queued if value.match?(/#{en_subject}.{0,40}\b(?:queued|enqueued)\b|#{subject}.{0,50}(?:в\s+очеред|поставлен\w*\s+в\s+очеред)|поставил\w*\s+в\s+очеред/i)
      kinds << :retrying if value.match?(/#{en_subject}.{0,40}\bretrying\b|#{subject}.{0,50}(?:повторн\w*\s+попыт|перезапущ)/i)
      kinds << :running if value.match?(/#{en_subject}.{0,40}\b(?:running|processing|still\s+in\s+(?:the\s+)?oven)\b|#{subject}.{0,60}(?:в\s+работ|обрабаты|генериру(?:ется|ю|ем)|рису(?:ется|ю|ем)|в\s+печ)|(?:ещ[её]|вс[её])\s+(?:в\s+)?печ/i)
      completion_link = '(?:\\s+|\\s*[,—:-]\\s*)' \
                        '(?:(?:задача\\s*)?#?\\d+\\s*[,—:-]?\\s*)?' \
                        '(?:(?:уже|успешно|полностью|наконец|теперь)\\s+){0,2}'
      completed_ru = '(?:' \
                     "картинка\\b#{completion_link}(?<!будет\\s)(?:готова|сгенерирована|завершена)|" \
                     "изображение\\b#{completion_link}(?<!будет\\s)(?:готово|сгенерировано|завершено)|" \
                     "задача\\b#{completion_link}(?<!будет\\s)(?:готова|завершена)|" \
                     "трек\\b#{completion_link}(?<!будет\\s)(?:готов|сгенерирован|заверш[её]н)|" \
                     "генерация\\b#{completion_link}(?<!будет\\s)(?:готова|завершена)" \
                     ')\\b'
      kinds << :completed if value.match?(/#{en_subject}.{0,40}\b(?:completed|generated|done)\b|#{completed_ru}/i)
      kinds << :delivered if value.match?(/#{en_subject}.{0,40}\b(?:delivered|sent)\b|#{subject}.{0,60}(?<!будет\s)(?:отправлен|доставлен|уже.{0,20}(?:выше|в\s+чат))/i)
      kinds << :failed if value.match?(/#{en_subject}.{0,40}\bfailed\b|#{subject}.{0,50}(?:упал|не\s+удал|ошибк)/i)
      kinds.uniq
    end

    # JSON examples are allowed as syntax examples, but a literal that carries
    # a task identity plus lifecycle fields is still an operational claim. Parse
    # those fields instead of exempting the whole code/JSON block by context.
    def structured_operational_claims(text)
      json_candidates(text).flat_map do |candidate|
        structured_claim_nodes(JSON.parse(candidate))
      rescue JSON::ParserError
        []
      end.uniq
    end

    def structured_claim_nodes(node)
      case node
      when Array
        node.flat_map { |item| structured_claim_nodes(item) }
      when Hash
        hash = node.transform_keys(&:to_s)
        nested = hash.values.select { |value| value.is_a?(Hash) || value.is_a?(Array) }
                     .flat_map { |value| structured_claim_nodes(value) }
        task_id = hash['task_id'] || hash['id']
        action = hash['action'].to_s
        task_type = hash['task_type'].to_s.empty? ? hash['type'].to_s : hash['task_type'].to_s
        identified = task_id.is_a?(Integer) && task_id.positive?
        identified ||= action.match?(/\A(?:generate_image|compose_song|add_vocals|cover_audio|cover_art|convert_to_wav|separate_vocals)\z/)
        identified ||= task_type.match?(/\A(?:image_generate|suno_[a-z0-9_]+)\z/)
        return nested unless identified

        phase = hash['phase'].to_s
        status = hash['status'].to_s
        delivery = hash['delivery'].to_s
        kinds = case phase
        when 'queued' then [:queued]
        when 'processing', 'delivering', 'persisting_delivery' then [:running]
        when 'retrying' then [:retrying]
        when 'completed' then [:completed]
        when 'failed' then [:failed]
        else
          case status
          when 'queued', 'pending' then [:queued]
          when 'sent', 'done', 'completed' then [:completed]
          when 'failed' then [:failed]
          else []
          end
        end
        kinds << :delivered if delivery == 'delivered'
        kinds << :failed if delivery == 'failed'
        inferred_type = if task_type == 'image_generate' || task_type == 'suno_cover_art' || action == 'generate_image' || action == 'cover_art'
          :image
        elsif task_type.start_with?('suno_') || %w[compose_song add_vocals cover_audio convert_to_wav separate_vocals].include?(action)
          :audio
        else
          claim_task_type(task_type) || claim_task_type(action)
        end
        own = kinds.uniq.map do |kind|
          { kind: kind, task_id: task_id.is_a?(Integer) && task_id.positive? ? task_id : nil,
            task_type: inferred_type }
        end
        own + nested
      else
        []
      end
    end

    def evidence_for_claim(claim)
      candidates = if claim[:task_id]
        @latest_evidence.values.select { |record| record[:task_id] == claim[:task_id] }
      else
        @latest_evidence_batch.select { |record| record[:task_id] }
      end
      candidates = candidates.select { |record| task_type_matches?(record[:task_type], claim[:task_type]) } if claim[:task_type]
      candidates.uniq { |record| record[:identity] }.one? ? candidates.first : nil
    end

    def explicit_task_id(text)
      match = text.to_s.match(/(?:задач[аи]?|task)\s*#?\s*(\d+)|#(\d+)/i)
      (match&.captures&.compact&.first || 0).to_i.then { |id| id.positive? ? id : nil }
    end

    def claim_task_type(text)
      value = text.to_s
      return :image if value.match?(/картинк|изображени|image|рисунк/i)
      return :audio if value.match?(/трек|песн|аудио|song|track|music/i)
      nil
    end

    def task_type_matches?(actual, requested)
      return true unless requested
      value = actual.to_s
      case requested
      when :image then value.include?('image') || value.include?('cover_art')
      when :audio
        return false if value == 'suno_cover_art' || value.include?('cover_art')
        value.include?('suno') || value.include?('audio') || value.include?('vocal') || value.include?('separation')
      else value == requested.to_s
      end
    end

    def operational_followup_request?
      @text.to_s.match?(/(?:где|готов|пришл|пришла|отправ|достав|статус|задач|картинк|изображени|трек|ещ[её]|what.*status|where.*(?:image|task|track))/i)
    end

    def append_trusted_task_ids(text)
      claims = operational_claims(text)
      matched = claims.filter_map { |claim| evidence_for_claim(claim) }
      records = claims.empty? || matched.empty? ? @latest_evidence_batch : matched
      ids = records.filter_map { |record| record[:task_id] }.uniq
      return text if ids.empty?
      missing = ids.reject { |id| text.match?(/(?:задач[аи]?\s*#?\s*|#)#{Regexp.escape(id.to_s)}\b/i) }
      return text if missing.empty?

      label = missing.length == 1 ? "задача ##{missing.first}" : "задачи: #{missing.map { |id| "##{id}" }.join(', ')}"
      "#{text.rstrip} (#{label})"
    end

    def tool_payload_node?(node)
      case node
      when Array
        node.any? { |item| tool_payload_node?(item) }
      when Hash
        keys = node.keys.map(&:to_s)
        return true if (keys & %w[tool_call tool_calls function_call tool_use tool_use_id]).any?
        return true if keys.include?('function') && node['function'].is_a?(Hash)
        return true if %w[tool_use tool_call function_call].include?((node['type'] || node[:type]).to_s)
        return true if keys.include?('name') && (keys & %w[arguments input]).any?
        name = node['name'] || node[:name] || node['action'] || node[:action]
        return true if name && Agent::ToolRegistry.find(name.to_s)
        node.values.any? { |value| value.is_a?(Hash) || value.is_a?(Array) ? tool_payload_node?(value) : false }
      else
        false
      end
    end

    def json_candidates(text)
      candidates = [text.to_s.strip]
      text.to_s.scan(/```(?:json)?\s*(.*?)```/mi) { |match| candidates << match.first.strip }
      candidates.concat(balanced_json_fragments(text.to_s))
      candidates.reject(&:empty?).uniq
    end

    def balanced_json_fragments(text)
      fragments = []
      stack = []
      start = nil
      quote = false
      escaped = false
      text.each_char.with_index do |char, index|
        if quote
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            quote = false
          end
          next
        end
        if char == '"'
          quote = true unless stack.empty?
        elsif char == '{' || char == '['
          start = index if stack.empty?
          stack << char
        elsif char == '}' || char == ']'
          next if stack.empty?
          expected = char == '}' ? '{' : '['
          if stack.last == expected
            stack.pop
            if stack.empty? && start
              fragments << text[start..index]
              start = nil
            end
          else
            stack.clear
            start = nil
          end
        end
      end
      fragments
    end

    def canonical_json(value)
      normalized = case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          out[key] = JSON.parse(canonical_json(value[original_key]))
        end
      when Array
        value.map { |item| JSON.parse(canonical_json(item)) }
      else
        value
      end
      JSON.generate(normalized)
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

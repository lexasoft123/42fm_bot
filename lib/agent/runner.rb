require 'erb'
require 'uri'
require 'digest'
require_relative 'scratchpad'
require_relative 'tool_result'
require_relative 'error_reporter'
require_relative '../image_gen/catalog'

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

    def initialize(text:, context:, knowledge:, radio:, chat_id:, user:, api: nil, image: nil, phrase: nil, audio: nil, reply_to_message_id: nil, message_id: nil, photo_source_present: false, photo_source_message_id: nil, original_request_text: nil, user_initiated: true, forum_thread_id: nil, private_chat: false, tools_enabled: true, excluded_tools: [], persist_deferred_intents: true, report_errors: true)
      @text       = text
      @context    = context
      @knowledge  = knowledge
      @photo_source_present = photo_source_present || !image.nil?
      @image      = image if image.is_a?(Hash) && image[:data].to_s != ''
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
      @excluded_tools = Array(excluded_tools).map(&:to_s).freeze
      @persist_deferred_intents = persist_deferred_intents
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
      @vision_image = @setting == 'agent_vision' ? @image : nil
      @pixels_available = !@vision_image.nil?
      @explicit_photo_ids = explicit_photo_message_ids
      @current_photo_required = referenced_attached_photo?
      @expected_photo_ids = @explicit_photo_ids.dup
      @expected_photo_ids << photo_source_message_id if photo_source_message_id && (@explicit_photo_ids.empty? || @current_photo_required)
      @expected_photo_ids.uniq!
      @pixel_source_ids = []
      @pixel_source_ids << photo_source_message_id if @vision_image && photo_source_message_id
      # Images fetched mid-loop by tools (view_image) — queued here by
      # materialize_result, injected into `messages` after the iteration's
      # tool results, then the setting upgrades to agent_vision.
      @pending_images = []
      @pending_image_source_ids = []
      @text_search_queries = []
      @text_search_evidence = false
      @text_search_covered = []
      @text_search_sources = []
      @weather_city_coverage = Hash.new { |hash, key| hash[key] = [] }
      @image_call_cache = {}
      @photo_search_attempted = false
      @photo_search_outcome = nil
      @route_rejected = false
      @photo_clarification = false
      @search_nudged = false
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
                     original_request_text: original_request_text || text,
                     image_prompt_context: context,
                     image_prompt_knowledge: knowledge,
                     record_text_search: method(:record_text_search),
                     message_id: message_id,
                     reply_to_message_id: reply_to_message_id,
                     photo_source_present: @photo_source_present,
                     photo_source_message_id: photo_source_message_id,
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
      if @last_status_display && !status_only_request? && !result.to_s.empty?
        status = sanitize_telegram_identity_links(@last_status_display)
        result = "#{status}\n#{result}" unless result.include?(status)
      end
      @turn_status = classify_turn_status(result)
      result
    rescue GptMaster::BalanceError
      @turn_status = 'provider_balance_error'
      deterministic_status_fallback || deterministic_action_fallback ||
        (@user_initiated ? 'Не могу ответить: у провайдера модели закончился баланс.' : '')
    rescue => e
      @turn_status = 'exception'
      raise
    ensure
      emit_turn_metrics
    end

    def run_inner
      if photo_lookup_requested? && !photo_lookup_subject
        @photo_clarification = true
        return 'Уточни, чьё или какое фото нужно найти.'
      end
      system_prompt, user_content = build_initial_content
      messages = build_initial_messages(user_content)
      tools    = if @tools_enabled
        ToolRegistry.definitions_for(user_role: @user.role, api_type: @api_type,
                                     exclude_names: @excluded_tools)
      else
        []
      end

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
        return (@user_initiated ? (deterministic_status_fallback || deterministic_action_fallback || SAFE_FAILURE_REPLY) : '') unless raw

        stop       = extract_stop_reason(raw)
        tool_calls = extract_tool_calls(raw)
        iter_ms    = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - iter_t0) * 1000).round
        alog :warn, "slow iteration #{i + 1}: took=#{iter_ms}ms (threshold #{SLOW_ITERATION_MS}ms)" if iter_ms > SLOW_ITERATION_MS

        if tool_calls.empty?
          text = extract_text(raw)
          return deterministic_status_fallback if text.to_s.strip.empty? && deterministic_status_fallback
          if text.to_s.strip.empty? && (acknowledgement = deterministic_action_fallback)
            return acknowledgement
          end
          if compound_photo_search_edit?
            perform_compound_photo_search unless @photo_search_attempted
            return compound_photo_search_reply
          end
          if factual_search_required? && !search_evidence_complete? && (!trusted_simple_acknowledgement || medical_factual_request?) && @text_search_queries.empty? && !@search_nudged && i < MAX_ITERATIONS - 1
            @search_nudged = true
            messages << build_assistant_message(raw)
            append_user_nudge(messages, 'Для этого ответа сначала выполни google_search с media_type text. Если результатов нет, сообщи о невозможности проверить.')
            next
          end
          if text.nil? || text.strip.empty?
            # Synthetic agent_event/cron turn: blank means the agent chose
            # silence (AgentEventHandler) — not a failure.
            return '' unless @user_initiated

            # User turn: a blank reply used to reach deliver as "" and be
            # dropped silently. Budget exhaustion won't improve on a retry of
            # the same context (and would block the loop again) → visible stub.
            if !generate_image_called &&
               (OUTPUT_BUDGET_STOPS.include?(stop.to_s) || blank_retried) &&
               watchdog_fired && image_request_unanswered?
              generate_image_called = true
              direct_result = dispatch_direct_image_request
              return finalize_output(direct_result, messages: messages, system_prompt: system_prompt,
                                     tools: tools, iteration: i + 1) unless Agent::ErrorReporter.tool_error_result?(direct_result)
              append_user_nudge(messages, direct_image_error_nudge(direct_result))
              next
            end
            if OUTPUT_BUDGET_STOPS.include?(stop.to_s) || blank_retried
              alog :warn, "empty reply (iteration #{i + 1}, stop=#{stop}#{blank_retried ? ', after retry' : ''}) — returning stub"
              return SAFE_FAILURE_REPLY
            end
            # A photo is already in hand and the user explicitly asked to edit
            # it. Do not make the vision model act as a policy gate: enqueue the
            # raw request directly and let the image backend decide what it can
            # render.
            if !generate_image_called && direct_image_edit_request?
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
            return sanitize_telegram_identity_links(@last_status_display) if @last_status_display && status_only_request?
            messages << build_tool_result_message(call_id, result)
            next
          end

          # A model refusal is a safety decision, not a failed tool call.
          if image_safety_refusal?(text) && image_request_unanswered?
            return finalize_output(text, messages: messages, system_prompt: system_prompt,
                                   tools: tools, iteration: i + 1, raw: raw)
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

          # A real draw request gets one model retry so it can choose the best
          # image model and arguments. If it still returns prose/refusal instead
          # of the tool call, the chat model is no longer allowed to become a
          # policy gate: enqueue the user's request verbatim and let the image
          # backend return its own authoritative result.
          if !generate_image_called && watchdog_fired && image_request_unanswered?
            generate_image_called = true
            direct_result = dispatch_direct_image_request
            return finalize_output(direct_result, messages: messages, system_prompt: system_prompt,
                                   tools: tools, iteration: i + 1) unless Agent::ErrorReporter.tool_error_result?(direct_result)
            messages << build_assistant_message(raw)
            append_user_nudge(messages, direct_image_error_nudge(direct_result))
            next
          end

          alog :info, "DONE (#{i + 1} iteration#{i > 0 ? 's' : ''}, stop=#{stop}, no tools, took=#{iter_ms}ms)\nRESPONSE: #{text[0..500]}#{text.length > 500 ? '...' : ''}"
          return finalize_output(text, messages: messages, system_prompt: system_prompt,
                                 tools: tools, iteration: i + 1, raw: raw)
        end


        expected_status = task_status_request_args
        if expected_status && expected_status['task_id']
          tool_calls.each do |tc|
            next unless tc[:name] == 'task_status' && tc[:input].is_a?(Hash) && !tc[:input].key?('task_id')
            tc[:input] = tc[:input].merge('task_id' => expected_status['task_id'])
          end
        end
        task_status_called ||= tool_calls.any? do |tc|
          tc[:name] == 'task_status' && (!expected_status || !expected_status['task_id'] || (tc[:input].is_a?(Hash) && tc[:input]['task_id'] == expected_status['task_id']))
        end

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

        return compound_photo_search_reply if compound_photo_search_edit? && @photo_search_attempted

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
    def image_safety_refusal?(text)
      text.to_s.match?(/(?:не могу|не стану|не буду|отказываюсь|cannot|can't|won't|unable to).{0,120}(?:помочь|созда|генерир|нарис|рисов|измен|правк|выполн|help|create|generat|draw|edit|comply)/i)
    end

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
    def image_request_unanswered?
      return false unless @user_initiated
      return false if existing_photo_lookup?
      return false if @text.nil? || @text.empty?
      draw_requested? || direct_image_edit_request?
    end

    def direct_image_edit_request?
      @user_initiated && !existing_photo_lookup? && ((@image.is_a?(Hash) && @image[:data]) || @explicit_photo_ids.any?) &&
        ImageGen::EditIntent.requested?(@text)
    end

    def draw_requested?
      prose = @text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      prose = prose.gsub(/(?:не|без|don't|do not)\s+(?:#{DRAW_DIRECTIVE})/i, ' ')
      prose.match?(DRAW_DIRECTIVE)
    end

    def dispatch_direct_image_edit
      dispatch_direct_image_request(force_edit: true)
    end

    def dispatch_direct_image_request(force_edit: false)
      if @photo_source_present && !source_image_available? && !@tool_ctx[:photo_source_message_id] && !photo_lookup_requested?
        @route_rejected = true
        return 'Не удалось загрузить исходное фото. Пришли его ещё раз.'
      end
      args = { 'prompt' => @text, 'edit_source' => true }
      args.delete('edit_source') unless force_edit || source_image_available? || @photo_source_present
      model = ImageGen::Catalog.requested_key(@text)
      args['model'] = model if model
      mode = args['edit_source'] ? 'image-edit' : 'image-generation'
      alog :warn, "direct #{mode} fallback: model returned no tool call; " \
                  "dispatching generate_image#{model ? " model=#{model}" : ''}"
      execute_tool('generate_image', args)
    end

    def source_image_available?
      @image.is_a?(Hash) && @image[:data]
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
      if value.strip.match?(/\A(?:готово|готова|уже готово|что там|ну что|статус|ready|done)\s*[?!]*\z/i)
        id = replied_task_id
        return { 'task_id' => id } if id
      end
      return if value.match?(/(?:\b(?:example|quote|quoted|translate|git|http)\b|пример|цитат|перевед|что\s+значит|объясни|в\s+истори|из\s+истори|history\s+(?:says|said)|previous\s+message)/i)

      subject = /(?:задач|генераци|картинк|изображени|песн|трек|кавер|аудио)\w*|\b(?:task|job|generation|image|song|track|cover|audio)\b/i
      explicit_status = /(?:статус|состоян|прогресс|очеред|выполня|обрабаты|достав|что\s+(?:там\s+)?с|(?:как|где)\s+(?:там\s+)?(?:задач|генераци|картинк|изображени|песн|трек|кавер|аудио)|\b(?:status|state|progress|queued|running|processing|delivered)\b|\b(?:how|where)\s+is\b|\bwhat(?:'s|\s+is)\s+happening\s+with\b)/i
      completion = /(?:готов|заверш|сделан|закончен|упал|ошибк)\w*|\b(?:done|ready|finished|complete|failed)\b/i
      request_frame = /\?|(?:^|\s)(?:проверь|скажи|покажи|узнай|что|как|где|есть\s+ли|готова?\s+ли)\b|\b(?:check|show|tell|is|are|was|were|what|how|where)\b/i
      return unless value.match?(subject)
      return unless value.match?(explicit_status) || (value.match?(completion) && value.match?(request_frame))

      ids = value.scan(/(?:задач[[:alpha:]]*|task)\s*#?\s*(\d+)|#\s*(\d+)/i)
                 .flatten.compact.map(&:to_i).select(&:positive?).uniq
      return if ids.length > 1
      ids.empty? ? {} : { 'task_id' => ids.first }
    end

    def replied_task_id
      reply_id = @tool_ctx[:reply_to_message_id]
      return unless reply_id
      scope = Message.where(chat_id: @chat_id, message_id: reply_id, role: 'bot')
      scope = scope.where(message_thread_id: @tool_ctx[:forum_thread_id]) if @tool_ctx[:forum_thread_id]
      bodies = scope.limit(2).pluck(:body)
      return unless bodies.one?
      ids = bodies.first.to_s.scan(/(?:задач[аеиу]?|task)\s*#\s*(\d+)/i).flatten.map(&:to_i).select(&:positive?).uniq
      ids.one? ? ids.first : nil
    rescue => e
      alog :warn, "reply task lookup failed: #{e.class}"
      nil
    end

    def status_request_prose(text)
      text.to_s
          .gsub(/```.*?```/m, ' ')
          .gsub(/`[^`]*`/, ' ')
          .gsub(/«[^»]*»|“[^”]*”|"[^"]*"|'[^']*'/m, ' ')
          .lines.reject { |line| line.match?(/^\s*>/) }.join(' ').strip
    end

    def status_only_request?
      task_status_request_args && request_clauses.size == 1 && !draw_requested? && !ImageGen::EditIntent.requested?(@text) &&
        !@text.to_s.match?(/(?:\s|\A)(?:и|затем|потом|также|and|then|пришли|поставь|включи)(?:\s|\z)/i)
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
      image      = @vision_image
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
      if @photo_source_present && !@pixels_available
        content += "\n\n[Фото присутствовало, но его пиксели недоступны модели. Не утверждай, что видишь его содержимое.]"
      end
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
      if @vision_image
        # Always build the Anthropic-shape vision block. GptMaster.build_body
        # converts to OpenAI shape ({type: 'image_url', image_url: {url: data-uri}})
        # at the wire boundary for openai-compat providers (Grok, OpenAI, etc).
        # Routing decides which model sees it via pick_setting → agent_vision.
        [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: @vision_image[:media_type], data: @vision_image[:data] } },
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

      if @excluded_tools.include?(name.to_s)
        alog :warn, "blocked excluded tool #{name}"
        return JSON.generate(status: 'error', source: "tool.#{name}",
                             message: 'tool is unavailable for this turn')
      end

      if name.to_s == 'generate_image' && image_source_overflow?(input)
        @route_rejected = true
        @source_overflow_error = 'Слишком много исходных сообщений. Выбери не более 24 и попробуй снова.'
        return (@image_overflow_response ||= JSON.generate(status: 'error', source: 'tool.generate_image', message: @source_overflow_error))
      end

      expected_status = task_status_request_args if name.to_s == 'task_status'
      if expected_status && expected_status['task_id'] && input.is_a?(Hash) && input['task_id'] != expected_status['task_id']
        return 'Номер задачи не соответствует запросу пользователя; проверь указанную задачу.'
      end

      if name.to_s == 'generate_image' && existing_photo_lookup?
        @route_rejected = true
        return JSON.generate(status: 'error', source: 'tool.generate_image',
                             message: 'Запрошен поиск существующего фото, а не создание изображения.')
      end

      if name.to_s == 'generate_image' && @user_initiated && (@photo_source_present || @explicit_photo_ids.any?) &&
         visual_inspection_request? && !draw_requested? && !ImageGen::EditIntent.requested?(@text)
        @route_rejected = true
        return 'Для просмотра фото используй view_image, а не генерацию.'
      end

      if name.to_s == 'generate_image' && compound_photo_search_edit?
        @route_rejected = true
        perform_compound_photo_search unless @photo_search_attempted
        return compound_photo_search_reply
      end

      if name.to_s == 'generate_image' && attachment_only_edit?
        input = input.is_a?(Hash) ? input.dup : {}
        input.delete('source_message_ids')
        input['edit_source'] = true
      end

      effective_ctx = @tool_ctx
      if name.to_s == 'generate_image' && @user_initiated && @explicit_photo_ids.any?
        unless ImageGen::EditIntent.requested?(@text) || draw_requested?
          @route_rejected = true
          return 'Для просмотра или сравнения фото используй view_image, а не генерацию.'
        end
        scope = Message.where(chat_id: @chat_id, message_id: @explicit_photo_ids)
        scope = scope.where(message_thread_id: @tool_ctx[:forum_thread_id]) if @tool_ctx[:forum_thread_id]
        available = scope.where.not(attachment_photo_file_id: [nil, '']).pluck(:message_id).uniq
        unless (@explicit_photo_ids - available).empty?
          @route_rejected = true
          @historical_edit_error = 'Не удалось найти исходное фото в указанных сообщениях. Пришли его ещё раз.'
          return @historical_edit_error
        end
        input = (input.is_a?(Hash) ? input.dup : {})
        input['source_message_ids'] = @explicit_photo_ids.dup
        input['edit_source'] = true
        if referenced_attached_photo?
          if !source_image_available? && !@tool_ctx[:photo_source_message_id].to_i.positive?
            @route_rejected = true
            @historical_edit_error = 'Не удалось загрузить прикреплённое фото. Пришли его ещё раз.'
            return @historical_edit_error
          end
        else
          # Do not silently add an unrelated current attachment.
          effective_ctx = @tool_ctx.merge(image: nil, photo_source_present: false, photo_source_message_id: nil)
        end
      end

      if name.to_s == 'google_search' && input.is_a?(Hash) && %w[photo gif].include?(input['media_type']) && photo_lookup_requested?
        if compound_photo_search_edit? && @photo_search_attempted
          return 'Фото уже искали; повторная отправка не выполняется.'
        end
        if compound_photo_search_edit? && input['media_type'] != 'photo'
          return 'Для этого запроса нужен поиск фото.'
        end
        subject = photo_lookup_subject
        unless subject && photo_query_matches_subject?(subject, input['query'])
          @route_rejected = true
          @photo_clarification = true
          return 'Уточни, чьё или какое фото нужно найти.'
        end
        @photo_search_attempted = true if compound_photo_search_edit? && input['media_type'] == 'photo'
      end

      if name.to_s == 'google_search' && input.is_a?(Hash) && input['media_type'] == 'text' && factual_search_required?
        query = input['query'].to_s.strip.downcase.gsub(/\s+/, ' ')
        if query.empty? || @text_search_queries.size >= 2 || @text_search_queries.include?(query)
          return 'Поисковый лимит исчерпан или запрос повторяется; сообщи, что проверить не удалось.'
        end
        @text_search_queries << query
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

      cache_key = image_effective_cache_key(input, effective_ctx) if name.to_s == 'generate_image'
      if cache_key && @image_call_cache.key?(cache_key)
        return @image_call_cache[cache_key]
      end
      result = tool.handler.call(input, effective_ctx)
      if name.to_s == 'google_search' && input.is_a?(Hash) && input['media_type'] == 'photo' && @photo_search_attempted && compound_photo_search_edit?
        @photo_search_outcome = result.to_s
      end
      record_weather_evidence(input, result) if name.to_s == 'weather'
      local_intent = case name.to_s
      when 'radio_current_track' then /(?:сейчас\s+игра|играет|в\s+эфир|что\s+звучит|playing\s+now|current\s+track)/i
      when 'radio_history' then /(?:истори\S*\s+(?:радио|эфир|трек|песен)|играло|звучало|radio\s+history|played\s+tracks)/i
      when 'radio_listeners' then /(?:слушател|сколько\s+слуша|listeners)/i
      when 'radio_search', 'radio_request' then /(?:трек|песн|музык|библиотек|track|song|music|library)/i
      end
      @local_radio_resolved = true if local_intent && @text.to_s.match?(local_intent)
      @last_action_tool = name if result.is_a?(Agent::ToolResult) && result.action?
      if name == 'task_status' && result.is_a?(Agent::ToolResult) && result.action?
        expected = task_status_request_args
        @last_status_display = expected && expected['task_id'] == input['task_id'] ? result.display_text : nil
      end
      if name == 'view_image'
        @current_view_id = input['message_id'].to_i if input.is_a?(Hash)
        @unavailable_view = true if !result.is_a?(Agent::ToolResult) || !result.image?
      end
      materialized = materialize_result(result)
      @current_view_id = nil
      record_task_status_evidence(materialized) if name == 'task_status'
      @last_status_result = materialized if name == 'task_status'
      output = truncate(materialized)
      @image_call_cache[cache_key] = output if cache_key
      output
    rescue => e
      alog :error, "tool #{name} error: #{e.class}: #{e.message}"
      failure = Agent::ErrorReporter.tool_result(source: "tool.#{name}", error: e)
      @image_call_cache[cache_key] = failure if cache_key
      if name.to_s == 'google_search' && input.is_a?(Hash) && input['media_type'] == 'photo' && @photo_search_attempted
        @photo_search_outcome = failure
      end
      failure
    end

    def image_source_overflow?(input)
      args = input.is_a?(Hash) ? input : {}
      raw = Array(args['source_message_ids'])
      max = ImageGen::Catalog::MAX_SOURCE_CANDIDATES
      return true if raw.size > max || @explicit_photo_ids.size > max
      photo_present = @tool_ctx[:photo_source_present] || @tool_ctx[:image].is_a?(Hash)
      edit = !!args['edit_source'] || (photo_present && ImageGen::EditIntent.requested?(@text)) || @explicit_photo_ids.any?
      inline = edit && @tool_ctx[:image].is_a?(Hash) && !@tool_ctx[:image][:data].to_s.empty?
      return true if raw.size + (inline ? 1 : 0) > max
      return true if @explicit_photo_ids.size + (inline && referenced_attached_photo? ? 1 : 0) > max
      inline_id = @tool_ctx[:photo_source_message_id].to_i
      if edit && !inline && photo_present && inline_id.positive? && (@explicit_photo_ids.empty? || referenced_attached_photo?)
        ids = @explicit_photo_ids.any? ? @explicit_photo_ids : raw.map(&:to_i).select(&:positive?).uniq
        return true if ids.size + (ids.include?(inline_id) ? 0 : 1) > max
      end
      false
    end

    # Match the image tool's effective request rather than model-authored
    # prompt prose. Keep source order and model distinctions: collapsing two
    # different jobs is worse than a conservative cache miss.
    def image_effective_cache_key(input, ctx)
      args = input.is_a?(Hash) ? input : {}
      request = ctx[:user_initiated] && !ctx[:request_text].to_s.empty? ? ctx[:request_text].to_s : args['prompt'].to_s
      photo_present = ctx[:photo_source_present] || ctx[:image].is_a?(Hash)
      edit_requested = !!args['edit_source'] || (photo_present && ImageGen::EditIntent.requested?(request))
      inline = edit_requested && ctx[:image].is_a?(Hash) && !ctx[:image][:data].to_s.empty? ? ctx[:image] : nil
      inline_id = ctx[:photo_source_message_id].to_i
      raw_sources = Array(args['source_message_ids'])
      ids = raw_sources.map(&:to_i).select(&:positive?).uniq
      ids.delete(inline_id) if inline && inline_id.positive?
      ids.unshift(inline_id) if edit_requested && !inline && photo_present && inline_id.positive? && !ids.include?(inline_id)
      known_files = []
      if inline && inline_id.positive?
        scope = Message.where(chat_id: ctx[:chat_id], message_id: inline_id)
        scope = scope.where(message_thread_id: ctx[:forum_thread_id]) if ctx[:forum_thread_id]
        inline_file = scope.pick(:attachment_photo_file_id)
        known_files << inline_file unless inline_file.to_s.empty?
      end
      source_identities = []
      ids = ids.reject do |id|
        scope = Message.where(chat_id: ctx[:chat_id], message_id: id)
        scope = scope.where(message_thread_id: ctx[:forum_thread_id]) if ctx[:forum_thread_id]
        file_id = scope.pick(:attachment_photo_file_id)
        file_id = nil if file_id.to_s.empty?
        duplicate = file_id && known_files.include?(file_id)
        known_files << file_id if file_id
        source_identities << (file_id ? ['file', file_id] : ['message', id]) unless duplicate
        duplicate
      end
      requested = ImageGen::Catalog.requested_key(request)
      excluded = ImageGen::Catalog.excluded_keys(request)
      model = requested || ImageGen::Catalog.allowed_key(args['model'], excluded)
      edit_intended = edit_requested || ids.any?
      if model && edit_intended && !ImageGen::Catalog.edit_supported?(model) && !requested
        model = ImageGen::Catalog.capable_model_for(1, excluded: excluded)
      end
      canonical_json(request: request, model: model, requested_model: requested, excluded_models: excluded,
                     edit_intended: edit_intended, raw_over_limit: raw_sources.size + (inline ? 1 : 0) > ImageGen::Catalog::MAX_SOURCE_CANDIDATES,
                     inline_source_id: inline && inline_id.positive? ? inline_id : nil,
                     inline_digest: inline && Digest::SHA256.hexdigest(inline[:data].to_s),
                     inline_media_type: inline && inline[:media_type], source_identities: source_identities,
                     missing_inline_source: edit_requested && photo_present && !inline && !inline_id.positive?)
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
      @pixels_available = !blocks.empty?
      @pixel_source_ids.concat(@pending_image_source_ids.compact).uniq!
      @pending_images = []
      @pending_image_source_ids = []
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
        unless result.image.is_a?(Hash) && !result.image[:data].to_s.empty?
          @unavailable_view = true
          return 'Не удалось загрузить изображение.'
        end
        @pending_images << result.image
        @pending_image_source_ids << @current_view_id
        return result.user_text
      end
      if result.action?
        payload = result.action_payload
        register_trusted_action(payload)
        @last_action_payload = payload
        return JSON.generate(payload)
      end
      return result.user_text unless result.deferred?

      intent_saved = false
      if @persist_deferred_intents
        due_at = result.retry_in_min ? (Time.now + result.retry_in_min * 60) : nil
        Agent::Scratchpad.add(@chat_id, category: 'intentions',
                              content: result.deferred_intent, due_at: due_at)
        intent_saved = true
        alog :info, "auto-remember (deferred): #{result.deferred_intent[0..120]}"
      else
        alog :info, 'auto-remember (deferred) suppressed for this turn'
      end
      payload = {
        status: 'deferred', action: 'retry_later', retry_in_min: result.retry_in_min,
        intent_saved: intent_saved, message: result.user_text
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
      text = sanitize_telegram_identity_links(text.to_s)
      if @last_action_tool.to_s == 'generate_image' && text.match?(/(?:переписал|изменил|скорректировал|адаптировал|смягчил|переформулировал|rewrite|rewrote|modified|revised|adjusted).{0,80}(?:промпт|запрос|описани|prompt|request)|(?:рисую|генерирую|передал).{0,20}\bбез\s/iu)
        acknowledgement = trusted_simple_acknowledgement
        return factual_search_required? && !search_evidence_complete? ? "#{acknowledgement}\n#{unverified_fact_notice}" : acknowledgement if acknowledgement
      end
      action_text = action_outcome_message(text)
      if action_text
        action_text = append_trusted_task_ids(action_text)
        return action_text + "\n#{unverified_fact_notice}" if factual_search_required? && !search_evidence_complete?
        return action_text
      end
      if (text == SAFE_FAILURE_REPLY || integrity_violation?(text)) && (acknowledgement = deterministic_action_fallback)
        return acknowledgement
      end
      if status_only_request? && @last_status_display
        return sanitize_telegram_identity_links(@last_status_display)
      end
      return @historical_edit_error if @historical_edit_error
      return @source_overflow_error if @source_overflow_error
      return 'Уточни, чьё или какое фото нужно найти.' if @photo_clarification
      target_missing = if @expected_photo_ids.any?
        @expected_photo_ids.any? { |id| !@pixel_source_ids.include?(id) }
      elsif @photo_source_present
        @vision_image.nil?
      else
        !@pixels_available
      end
      target_missing ||= @current_photo_required && @tool_ctx[:photo_source_message_id].nil? && @vision_image.nil?
      if target_missing && (@explicit_photo_ids.any? || @unavailable_view || (@photo_source_present && visual_inspection_request?))
        if @explicit_photo_ids.any? && ImageGen::EditIntent.requested?(@text) && (acknowledgement = trusted_simple_acknowledgement)
          return acknowledgement + "\n#{unverified_fact_notice}" if factual_search_required? && !search_evidence_complete?
          return acknowledgement
        end
        return 'Не удалось посмотреть фото: изображение недоступно модели. Попробуй отправить его ещё раз.'
      end
      if (exact_quote_request? || (attribution_request?(@text) && quoted_passages(text).any?)) && !verified_quote_in_sources?(text)
        acknowledgement = trusted_simple_acknowledgement
        return acknowledgement + "\n#{unverified_fact_notice}" if acknowledgement
        return 'Не удалось проверить точную цитату по найденным текстовым источникам.'
      end
      if factual_search_required? && !search_evidence_complete?
        acknowledgement = trusted_simple_acknowledgement
        return acknowledgement + "\n#{unverified_fact_notice}" if acknowledgement
        return 'Не удалось найти подходящие текстовые источники, поэтому я не могу надёжно проверить ответ.'
      end
      return append_trusted_task_ids(text) unless integrity_violation?(text)

      acknowledgement = trusted_simple_acknowledgement if operational_claims(text).any?
      return acknowledgement if acknowledgement

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
    rescue GptMaster::BalanceError
      raise
    rescue => e
      alog :warn, "final-output integrity gate failed: #{e.class}: #{e.message}"
      @user_initiated ? SAFE_FAILURE_REPLY : ''
    end

    def trusted_simple_acknowledgement
      payload = @last_action_payload
      return unless payload.is_a?(Hash)
      return unless %w[generate_image make_award compose_song add_vocals cover_audio cover_art convert_to_wav separate_vocals cancel_task].include?(@last_action_tool.to_s)
      status = (payload[:status] || payload['status']).to_s
      return unless %w[queued cancelled].include?(status)
      phase = (payload[:phase] || payload['phase']).to_s
      return if status == 'queued' && !['', 'queued'].include?(phase)
      task_id = payload[:task_id] || payload['task_id']
      return unless task_id.is_a?(Integer) && task_id.positive?
      status == 'cancelled' ? "Задача ##{task_id} отменена до начала работы." : "Задача ##{task_id} поставлена в очередь."
    end

    def deterministic_action_fallback
      acknowledgement = trusted_simple_acknowledgement
      if !acknowledgement && @last_action_tool.to_s != 'task_status' && @last_action_payload.is_a?(Hash)
        status = (@last_action_payload[:status] || @last_action_payload['status']).to_s
        if %w[queued sent cancelled].include?(status)
          acknowledgement = action_outcome_message(JSON.generate(@last_action_payload))
          acknowledgement = append_trusted_task_ids(acknowledgement) if acknowledgement
        end
      end
      return unless acknowledgement
      acknowledgement = sanitize_telegram_identity_links(acknowledgement)
      factual_search_required? && !search_evidence_complete? ? "#{acknowledgement}\n#{unverified_fact_notice}" : acknowledgement
    end

    def deterministic_status_fallback
      return unless @last_status_display && status_only_request?
      sanitize_telegram_identity_links(@last_status_display)
    end

    def factual_search_required?
      return false unless @user_initiated && @tools_enabled
      return true if medical_factual_request?
      factual_clauses_for_evidence.any?
    end

    def unverified_fact_notice
      medical_factual_request? ? 'Медицинскую информацию не удалось проверить по источникам.' : 'Фактическую информацию не удалось проверить по источникам.'
    end

    def exact_quote_request?
      @user_initiated && quote_request?(@text)
    end

    def quote_request?(text)
      text.to_s.match?(/(?:цитат|цитируй|дословн|точн\S*\s+(?:строк|текст)|\b(?:quote|quotation|verbatim)\b)/i)
    end

    def attribution_request?(text)
      text.to_s.match?(/(?:что\s+(?:писа[лн]|говори[лн]|сказа[лн])|what\s+did.{1,80}\b(?:write|say)\b)/i)
    end

    def quoted_passages(text)
      text.to_s.scan(/«([^»]+)»|“([^”]+)”|"([^"\n]+)"/).map { |parts| parts.compact.first.to_s.strip }.reject(&:empty?)
    end

    def verified_quote_in_sources?(text)
      quotes = quoted_passages(text)
      return false if quotes.empty? || !search_evidence_complete?
      excerpts = @text_search_sources.flat_map { |entry| entry[:sources].flat_map { |source| source.values_at(:title, :snippet) } }
      normalize = ->(value) { value.to_s.downcase.gsub(/[[:space:]]+/, ' ').strip }
      quotes.all? { |quote| excerpts.any? { |excerpt| normalize.call(excerpt).include?(normalize.call(quote)) } }
    end

    def factual_request_clauses
      request_clauses.select do |clause|
        next true if quote_request?(clause) || attribution_request?(clause)
        if photo_lookup_requested?
          question = /(?:кто|когда|где|сколько|почему|в\s+како[йем]|who|when|where|how)(?![[:alpha:]])/i
          next true if clause.match?(/(?:\A|\s(?:и|and)\s+)(?:(?:рас?скажи|скажи|ответь|tell\s+me)\s+)?#{question}/i)
        end
        next false if clause.match?(/(?:перевед|перевести|translate|рису(?:й|йте)|нарисовать|сгенерируй|создай|сочини|напиши\s+(?:стих|рассказ)|draw|generate|create)/i) && !clause.match?(/(?:проверь|проверить|новости|курс|билет|стоимост|сколько\s+стоит|search|verify)/i)
        next false if clause.match?(/(?:гиф|gif|фото|фотограф|картинк|изображени|photo|image|picture)/i) && clause.match?(/(?:найди|поищи|погугли|find|search|google)/i)
        clause.match?(/(?:найди|поищи|погугли|проверь|проверить|search|look up|verify)|(?:(?:курс|цен[аыу]|акци[яий]|валют|финанс|stock|price|exchange rate).*(?:сейчас|сегодня|текущ|current|today|now))|(?:погод|weather|новости|сегодня|на этой неделе|latest news|today)/i)
      end
    end

    def request_clauses
      prose = @text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      prose.split(/(?<=[.!?])\s+|\n+|\s+(?:и|а\s+потом|затем|then|and)\s+(?=(?:найди|поищи|погугли|проверь|скажи|расскажи|как|какой|какая|где|сколько|погод|нарис|дорис|перерис|созда|сгенерир|сочин|draw|generate|create|search|verify))/i)
    end

    def factual_clauses_for_evidence
      factual_request_clauses.reject do |clause|
        task_only = clause.match?(/(?:задач|очеред|task|job)/i) && !clause.match?(/(?:новости|курс|билет|погод|news|ticket|weather)/i)
        local_only = @local_radio_resolved && clause.match?(/(?:радио|эфир|трек|песн|музык|библиотек|слушател|radio|track|song|music|library|listeners)/i) &&
          !clause.match?(/(?:новости|симптом|леч(?:и|е|ат|ит|у)|диагноз|лекарств|дозиров|билет|стоимост|стоит|расписани|адрес|открыва|фестивал|погод|news|medical|symptom|treatment|ticket|festival|weather|opening hours|(?:курс|валют|stock|exchange rate).*(?:сейчас|сегодня|текущ|today|current))/i)
        task_only || local_only
      end
    end

    def medical_factual_request?
      prose = @text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      medical = prose.match?(/симптом|леч(?:и|е|ат|ит|у)|лекарств|диагноз|дозиров|болезн|препарат|medical|symptom|treatment/i)
      return false unless medical
      creative = prose.match?(/рису(?:й|йте)|нарисовать|создай|сгенерируй|сочини|draw|generate|create/i)
      return true unless creative
      prose.match?(/\?|(?:как|какие|какой|сколько|проверь|расскажи|объясни|симптом|диагноз|дозиров|how|what|symptom|diagnos)/i)
    end

    def record_text_search(query, results)
      # Provenance establishes that the tool returned real content matching
      # the submitted query; it does not certify the truth of any claim.
      stopwords = %w[найди поищи погугли проверь проверить пожалуйста сегодня сейчас узнать расскажи можно нужно делать новости новость курс цена цены стоит стоят стоимость вылечить rate price search verify about news today current what the про для как что какие какой какая какие сколько чем где когда кто есть это открывается открытие открывает часы часа работы рабочие приведи дай цитату цитаты цитата дословно дословную дословные точную точные quote quotation verbatim give exact писал писала говорил говорила сказал сказала did write say]
      normalize = ->(value) { value.to_s.downcase.scan(/[[:alnum:]]{2,}/).map { |word| word.match?(/\A(?:вы)?леч/) ? 'леч' : word }.uniq - stopwords }
      tokens = normalize.call(query)
      matches = ->(a, b) { entity_token_match?(a, b) }
      evidence_needs.each do |clause|
        request_tokens = normalize.call(clause)
        subject = request_tokens.select { |token| tokens.any? { |q| matches.call(token, q) } }
        broad_news = request_tokens.empty? && clause.match?(/новост|news/i) && query.to_s.match?(/новост|news/i)
        next if !broad_news && (subject.empty? || subject.size != request_tokens.size)
        need = information_need_pattern(clause)
        next if need && !query.to_s.match?(need)
        sources = Array(results).select do |r|
          begin
            uri = URI.parse(r[:link].to_s)
            next false unless %w[http https].include?(uri.scheme) && uri.host
          rescue URI::InvalidURIError
            next false
          end
          content = "#{r[:title]} #{r[:snippet]}"
          next false if need && !content.match?(need)
          words = normalize.call(content)
          broad_news ? content.match?(/новост|news/i) : subject.all? { |token| words.any? { |word| matches.call(token, word) } }
        end
        next if sources.empty?
        @text_search_covered << clause unless @text_search_covered.include?(clause)
        @text_search_sources << { query: query.to_s, sources: sources.map { |r| { title: r[:title], snippet: r[:snippet], link: r[:link] } } }
      end
      @text_search_evidence = search_evidence_complete?
    end

    def record_weather_evidence(input, result)
      return unless input.is_a?(Hash) && result.is_a?(String)
      return unless result.match?(/[+-]?\d+(?:[.,]\d+)?\s*°\s*[cс]/i)
      city = input['city'].to_s.downcase.scan(/[[:alpha:]]{3,}/)
      return if city.empty?
      result_words = result.downcase.scan(/[[:alpha:]]{3,}/)
      return unless result_words.each_cons(city.length).any? { |words| city.zip(words).all? { |token, word| entity_token_match?(token, word) } }
      evidence_needs.each do |clause|
        next unless clause.match?(/погод|weather/i)
        next if clause.match?(/(?:новост|курс|билет|стоимост|финанс|акци[яий]|лечен|диагноз|news|ticket|finance)/i)
        next unless current_weather_horizon?(clause)
        words = clause.downcase.scan(/[[:alpha:]]{3,}/)
        next unless city.all? { |token| words.any? { |word| entity_token_match?(token, word) } }
        requested = weather_requested_cities(clause)
        next if requested.empty?
        coverage = @weather_city_coverage[clause]
        coverage << city unless coverage.include?(city)
        all_cities = requested.all? do |name_tokens|
          coverage.any? do |tokens|
            tokens.length == name_tokens.length && name_tokens.zip(tokens).all? { |name, token| entity_token_match?(name, token) }
          end
        end
        @text_search_covered << clause if all_cities && !@text_search_covered.include?(clause)
      end
      @text_search_evidence = search_evidence_complete?
    end

    def weather_requested_cities(clause)
      match = clause.match(/(?:\A|[^[:alpha:]])(?:в|in)\s+([^?!;]+)/i)
      return [] unless match
      text = match[1].gsub(/(?<![[:alpha:]])(?:сегодня|сейчас|теперь|today|now)(?![[:alpha:]])/i, ' ')
      text.split(/\s*,\s*|\s+(?:и|and)\s+/i).map do |city|
        city.sub(/\A(?:(?:и|and)\s+)?(?:(?:в|in)\s+)?/i, '').downcase.scan(/[[:alpha:]]{3,}/)
      end.reject(&:empty?)
    end

    def current_weather_horizon?(clause)
      # The dedicated weather service returns current observations only.
      # Any explicit non-current modifier must be checked elsewhere.
      !clause.match?(/(?:завтр|послезавтр|вчера|позавчера|будущ|прошл|следующ|ближайш|ранее|раньше|через|позже|потом|после|перед|вечер|утр[оа]|ноч[ьюи]|дн[её]м|обед|полноч|недел|месяц|зимой|летом|осенью|весной|зимн|летн|осенн|весенн|понедельник|вторник|сред[ауе]|четверг|пятниц|суббот|воскресен|выходн|прогноз|(?<![[:alpha:]])(?:был(?:а|о|и)?|будет|будут|час[аов]*|дня|дней|суток|was|were|will)(?![[:alpha:]])|tomorrow|yesterday|later|tonight|morning|evening|afternoon|overnight|noon|midnight|forecast|next|before|after|weekend|spring|summer|autumn|winter|upcoming|historical|last\s+(?:week|month)|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\b\d{1,2}[:.\/-]\d{1,2}\b|\b\d{4}\b|\b\d{1,2}\s*(?:час|часа|часов|am|pm|январ|феврал|март|апрел|мая|июн|июл|август|сентябр|октябр|ноябр|декабр))/i)
    end

    def evidence_needs
      clauses = factual_clauses_for_evidence
      if medical_factual_request?
        medical_clauses = request_clauses.select { |clause| clause.match?(/симптом|леч(?:и|е|ат|ит|у)|лекарств|диагноз|дозиров|болезн|препарат|medical|symptom|treatment/i) }
        clauses |= medical_clauses
      end
      clauses
    end

    def search_evidence_complete?
      needs = evidence_needs
      needs.any? && (needs - @text_search_covered).empty?
    end

    def information_need_pattern(clause)
      return /(?:погод|температур|weather|forecast)/i if clause.match?(/(?:погод|weather)/i)
      return /(?:курс|обмен|exchange\s+rate|валютн\S*\s+цен|стоимост|цен[аыу]|rate)/i if clause.match?(/(?:курс|(?:доллар|валют|евро).*(?:стоит|стоимост|цен)|(?:стоит|стоимост|цен).*(?:доллар|валют|евро))/i)
      return /(?:открыва|открыти|часы|часов|расписани|время\s+работ|режим\s+работ|opening|hours|opens)/i if clause.match?(/(?:открыва|открыти|часы|часов|расписани|время\s+работ|режим\s+работ|opening|hours|opens)/i)
      return /(?:новост|news)/i if clause.match?(/(?:новост|news)/i)
      return /(?:леч(?:ени|и|ат|ит|у)|вылеч|treatment|treat)/i if clause.match?(/(?:леч(?:ени|и|ат|ит|у)|вылеч|treatment|treat)/i)
      nil
    end

    # Only remove known grammatical endings, never compare arbitrary short
    # prefixes: Иванов and Иваненко are different entities.
    def entity_token_match?(a, b)
      return true if a == b
      stem = lambda do |word|
        values = [word]
        if word.length >= 4 && word.match?(/\A[а-яё]+\z/i)
          %w[ами ями ого ему ому ыми ими ах ях ом ем ой ей а я у ю ы и е й ь].each do |ending|
            base = word.delete_suffix(ending)
            values << base if base != word && base.length >= 3
          end
        end
        values
      end
      (stem.call(a) & stem.call(b)).any?
    end

    def visual_inspection_request?
      @text.to_s.match?(/(?:что|кто|какой|какая|опиши|рассмотри|сравни|видишь|изображено|написано|прочита|распозна|надпис|текст|букв|ocr|transcri|read|what|describe|compare|see).{0,45}(?:фото|картин|изображен|photo|image)|(?:фото|картин|изображен|photo|image).{0,45}(?:что|кто|какой|опиши|сравни|видишь|прочита|распозна|надпис|текст|read|ocr|what|describe|compare)/i) || @text.to_s.strip.match?(/\A(?:что это|что здесь|что тут|опиши|what is this)\??\z/i) || (@photo_source_present && @text.to_s.match?(/\?|прочита|распозна|определи|классифицир|расшифруй|перепиши|проанализируй|сравни|transcrib|classify|compare|read/i))
    end

    def explicit_photo_message_ids
      prose = @text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|“[^”]*”|"[^"]*"/m, ' ')
      return [] unless prose.match?(/фото|картин|изображен|photo|image/i)
      list = '#?\s*\d+(?:\s*(?:,|и|and)\s*#?\s*\d+)*'
      ids = prose.scan(/(?:сообщени[[:alpha:]]*|messages?)\s*(#{list})/i).flatten.flat_map { |group| group.scan(/\d+/) }
      ids += prose.scan(/(?:фотографи[[:alpha:]]*|фото|картинк[[:alpha:]]*|изображени[[:alpha:]]*|photo|image)\s*(\#\s*\d+(?:\s*(?:,|и|and)\s*#?\s*\d+)*)/i).flatten.flat_map { |group| group.scan(/\d+/) }
      ids.map(&:to_i).select(&:positive?).uniq
    end

    def photo_lookup_requested?
      return false if explicit_photo_message_ids.any?
      @user_initiated && @text.to_s.match?(/(?:найди|поищи|погугли|ищи|find|search|google).{0,80}(?:фото|фотограф|картинк|изображени|photo|image|picture)|\A\s*(?:фото|photo)\s+\S/i)
    end

    def compound_photo_search_edit?
      @user_initiated && photo_lookup_requested? && ImageGen::EditIntent.find_photo_then_edit?(@text)
    end

    def perform_compound_photo_search
      unless ToolRegistry.find('google_search')
        @photo_search_attempted = true
        @photo_search_outcome = nil
        return
      end
      execute_tool('google_search', { 'query' => Array(photo_lookup_subject).join(' '), 'media_type' => 'photo' })
      @photo_search_attempted = true
    end

    def compound_photo_search_reply
      outcome = @photo_search_outcome.to_s
      if outcome.match?(/\[media_delivery\s+status=(?:sent|partial)\b[^\]]*\baccepted_count=[1-9]\d*/i)
        'Фото найдено и отправлено. Ответь на нужное фото и попроси нужную правку.'
      elsif outcome.match?(/\[media_delivery\s+status=sent_untracked\b/i)
        'Не могу подтвердить доставку фото. Если оно пришло, ответь на нужное фото и попроси правку.'
      else
        'Не удалось подтвердить доставку найденного фото. Пришли нужное фото или ответь на него, чтобы я мог его изменить.'
      end
    end

    def referenced_attached_photo?
      @photo_source_present && @text.to_s.match?(/(?:эт(?:о|у|ом)|прикрепл[[:alpha:]]*|текущ[[:alpha:]]*|this|attached)(?:\s+[[:alpha:]]+){0,2}\s+(?:фото|фотограф|картинк|изображени|photo|image)/i)
    end

    def attachment_only_edit?
      return false unless @user_initiated && @photo_source_present && @explicit_photo_ids.empty? && ImageGen::EditIntent.requested?(@text)
      return false if @text.to_s.match?(/(?:объедин|соедин|совмест|смеша|вместе|друг[а-я]*\s+(?:фото|картин)|истори|раньше|ещ[её]\s+(?:фото|картин)|combine|merge|another\s+(?:photo|image))/i)
      true
    end

    def photo_lookup_subject
      source = @text.to_s
      subject = photo_subject_fragment(source)
      tokens = photo_subject_tokens(subject)
      if tokens.empty? && @tool_ctx[:reply_to_message_id]
        rows = @context.is_a?(String) ? JSON.parse(@context) : @context
        row = Array(rows).find { |r| r.is_a?(Hash) && (r['id'] || r[:id]) == @tool_ctx[:reply_to_message_id] }
        reply = row && (row['msg'] || row[:msg]).to_s
        subject = photo_subject_fragment(reply.to_s)
        tokens = photo_subject_tokens(subject)
      end
      tokens.empty? ? nil : tokens
    rescue JSON::ParserError
      nil
    end

    def photo_subject_fragment(source)
      media = /фотографи[юяиеий]*|фото|картинк[уиаие]*|изображени[еяй]*|\b(?:photo|image|picture)\b/i
      match = source.match(media)
      return '' unless match
      after = source[match.end(0)..].to_s.split(/\s*(?:[;.!?]|,\s*(?=(?:не\s+|don't\s+|do\s+not\s+|нарис|дорис|перерис|добав|убер|измен|передел|отредактир|замен|созда|сгенерир|draw|edit|add|change|generate|create))|\s+(?:(?:и|а\s+потом|затем|then|and)\s+(?=(?:нарис|дорис|перерис|добав|убер|измен|передел|отредактир|замен|созда|сгенерир|draw|edit|add|change))|не\s+))/i).first.to_s
      before = source[0...match.begin(0)].to_s.sub(/\A.*?(?:найди|поищи|погугли|ищи|find|search|google)\s+/i, '')
      photo_subject_tokens(after).empty? ? before : after
    end

    def photo_subject_tokens(value)
      value.to_s.downcase.scan(/[[:alnum:]]{2,}/) - %w[просто пожалуйста его её ее их этот этого этой это вот мне нам найди погугли фото фотоs картинку фотографию image photo the a an of and]
    end

    def photo_query_matches_subject?(subject, query)
      words = photo_subject_tokens(query)
      subject.all? { |token| words.any? { |word| entity_token_match?(token, word) } }
    end

    # Classify only the current directive, never neighboring chatter. Explicit
    # compound requests retain generation; quoted examples and negations do
    # not count as instructions to draw.
    def existing_photo_lookup?
      return false unless photo_lookup_requested?
      prose = @text.to_s.gsub(/```.*?```|`[^`]*`|«[^»]*»|"[^"]*"/m, ' ')
      prose = prose.gsub(/(?:не|без|don't|do not)\s+(?:на|до|от|пере|под|за|с)?рису(?:й|йте)|(?:не|без)\s+генериру\S*/i, ' ')
      prose = prose.gsub(/(?:don't|do not|never)\s+(?:generate|create|draw)\b/i, ' ')
      prose = prose.gsub(/(?:не|без|don't|do not)\s+(?:измени|переделай|отредактируй|замени|убери|добавь|сними|переодень|поменяй|edit|add|change)\S*/i, ' ')
      !draw_requested? && !ImageGen::EditIntent.requested?(@text) && !prose.match?(/(?:создай|сгенерируй|нарисовать|generate|draw|create).{0,60}(?:картинк|изображени|фото|image|picture)/i)
    end

    def sanitize_telegram_identity_links(text)
      trusted = []
      trusted << @user.uid.to_i if @user_initiated && @user&.uid.to_i.positive?
      begin
        rows = @context.is_a?(String) ? JSON.parse(@context) : @context
        Array(rows).each do |row|
          next unless row.is_a?(Hash)
          who = row['who'] || row[:who]
          uid = who.is_a?(Hash) && (who['uid'] || who[:uid])
          trusted << uid if uid.is_a?(Integer) && uid.positive?
        end
      rescue JSON::ParserError
        # An invalid context cannot authorize any additional identities.
      end
      text = text.gsub(/\[([^\]]+)\]\(<?tg:\/\/user\?id=([^)>\s]*)(?:>)?\)/i) do
        label, target = Regexp.last_match(1), Regexp.last_match(2)
        target.match?(/\A[1-9]\d*\z/) && trusted.include?(target.to_i) ? Regexp.last_match(0) : label
      end.gsub(/<a\s+href=["']tg:\/\/user\?id=([^"']*)["']\s*>(.*?)<\/a>/im) do
        target, label = Regexp.last_match(1), Regexp.last_match(2)
        target.match?(/\A[1-9]\d*\z/) && trusted.include?(target.to_i) ? Regexp.last_match(0) : label
      end
      text.gsub(/<?tg:\/\/user\?id=([^\s)>"']*)>?/i) do
        target = Regexp.last_match(1)
        whole = Regexp.last_match(0)
        target.match?(/\A[1-9]\d*\z/) && trusted.include?(target.to_i) ? whole : ''
      end
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
      return 'search_unverified' if result.to_s.start_with?('Не удалось найти подходящие текстовые источники')
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
        route: photo_lookup_requested? ? (existing_photo_lookup? ? 'photo_lookup' : 'compound_photo') : 'other',
        route_rejected: !!@route_rejected,
        search_outcome: !factual_search_required? ? 'not_required' : (search_evidence_complete? ? 'evidence' : 'unverified'),
        search_count: @text_search_queries.length,
        pixels: @pixels_available ? 'available' : (@photo_source_present || @unavailable_view ? 'unavailable' : 'none'),
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
      when 'cancelled' then [:cancelled]
      when 'deferred' then [:deferred]
      else
        case payload['status'].to_s
        when 'pending', 'queued' then [:queued]
        when 'done', 'sent' then [:completed]
        when 'failed' then [:failed]
        when 'cancelled' then [:cancelled]
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
      states << :cancelled if values.include?('cancelled')
      states
    end

    def operational_claim_unverified?(text)
      claims = operational_claims(text)
      return false if claims.empty?

      allowed = {
        queued: [:queued], running: %i[running retrying], retrying: [:retrying],
        completed: %i[completed sent], delivered: [:sent], failed: [:failed], cancelled: [:cancelled]
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
      kinds << :cancelled if value.match?(/#{en_subject}.{0,40}\b(?:cancelled|canceled)\b|#{subject}.{0,50}отмен(?:ена|ено|ён|ен|или)/i)
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
        when 'cancelled' then [:cancelled]
        else
          case status
          when 'queued', 'pending' then [:queued]
          when 'sent', 'done', 'completed' then [:completed]
          when 'failed' then [:failed]
          when 'cancelled' then [:cancelled]
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

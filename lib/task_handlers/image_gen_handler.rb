require_relative 'agent_event_emitter'
require_relative 'task_delivery_errors'
require_relative '../telegram_file'
require_relative '../model_provider_client'
require 'faraday'
require 'faraday/multipart'
require 'tempfile'
require 'uri'
require 'digest'
require 'base64'

class ImageGenTaskHandler
  include ChatContext
  include AgentEventEmitter

  MAX_DELIVERY_FAILURES = 3
  MAX_PERSISTENCE_FAILURES = 3
  MAX_IMAGE_DOCUMENT_BYTES = 20 * 1024 * 1024

  class DeliveryPersistenceError < StandardError; end

  def call(task, api)
    # A terminal provider outcome may have been reached immediately before
    # SQLite rolled back the parent+notice transaction. Replay only that
    # terminal transition after restart; never compose or submit the paid job
    # again while its notice is still pending.
    if task.status == 'pending' && (transition = task.params_hash['terminal_failure_transition'])
      mark_failed_and_notify(task, api, transition['reason'], terminal_transition: transition)
      return :failed
    end

    # A completed generation is cached in params before the first Telegram
    # delivery attempt. This branch must win over external_id dispatch so a
    # transient send failure retries delivery instead of paying to regenerate.
    receipt = task.params_hash['delivery_receipt']
    if receipt.is_a?(Hash)
      ActiveRecord::Base.connection_pool.with_connection { task.mark_persisting_delivery! }
      return persist_receipt_and_complete(task, api, receipt)
    end

    delivery_result = task.params_hash['delivery_result']
    if delivery_result.is_a?(Hash)
      ActiveRecord::Base.connection_pool.with_connection { task.mark_delivering! }
      return deliver_generated_result(task, api, delivery_result)
    end

    if task.external_id.nil? && task.params_hash['submit_in_flight']
      mark_failed_and_notify(task, api, 'submit_outcome_unknown')
      return :failed
    end

    result = task.external_id.nil? ? compose_and_submit(task, api) : poll_and_deliver(task, api)
    if result == :pending && task.attempts + 1 >= task.max_attempts
      mark_failed_and_notify(task, api, task.external_id ? 'poll_timeout' : 'submit_timeout')
      return :failed
    end
    result
  end

  private

  def mark_processing_unless_retrying(task)
    return if %w[retrying delivering persisting_delivery].include?(task.lifecycle_phase)
    ActiveRecord::Base.connection_pool.with_connection { task.mark_processing! }
  end

  def compose_and_submit(task, api)
    mark_processing_unless_retrying(task)
    p = task.params_hash
    request = p['request'].to_s
    model_key = p['model']   # nil for legacy/award tasks (no per-request model)
    explicit_model = p['model_explicit'] || !p['user_requested_model'].to_s.empty?
    if explicit_model && !ImageGen::Catalog.entry(model_key)
      mark_failed_and_notify(task, api, 'image_model_unavailable')
      return :failed
    end
    # Did the user ask to edit/combine? (inline image, history message_ids, or a
    # legacy single-image task enqueued before this deploy.)
    edit_intended = p['edit_intended'] || !p['input_image'].to_s.empty? ||
                    Array(p['input_images']).any? ||
                    Array(p['source_message_ids']).any?
    if explicit_model && edit_intended && !ImageGen::Catalog.edit_supported?(model_key)
      mark_failed_and_notify(task, api, 'image_model_unavailable')
      return :failed
    end
    if !explicit_model && edit_intended && model_key &&
       (!ImageGen::Catalog.entry(model_key) || !ImageGen::Catalog.edit_supported?(model_key))
      model_key = ImageGen::Catalog.capable_model_for(1, excluded: Array(p['excluded_models']))
      unless model_key
        mark_failed_and_notify(task, api, 'image_model_unavailable')
        return :failed
      end
    end
    begin
      if model_key
        prov = ImageGen::Catalog.provider_for(model_key)
        unless ImageGen::ADAPTERS.key?(prov)   # typo'd/unknown provider in catalog entry
          if explicit_model
            mark_failed_and_notify(task, api, 'adapter_config_error')
            return :failed
          end
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: model #{safe_external(model_key).inspect} → unknown provider #{safe_external(prov).inspect}; falling back to default_model"
          model_key = if edit_intended
            ImageGen::Catalog.capable_model_for(1, excluded: Array(p['excluded_models']))
          else
            ImageGen::Catalog.allowed_key(nil, Array(p['excluded_models']))
          end
          unless model_key
            mark_failed_and_notify(task, api, 'adapter_config_error')
            return :failed
          end
          prov = ImageGen::Catalog.provider_for(model_key)
        end
        adapter = ImageGen.adapter_for(prov)   # build the entry's provider's adapter
      else
        adapter = ImageGen.current_adapter     # legacy / no catalog → today's behavior
      end
    rescue => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: adapter resolution failed: #{e.class}: #{sanitized_error_message(e)}"
      mark_failed_and_notify(task, api, 'adapter_config_error')
      return :failed
    end

    # Resolve edit source image(s): inline (current/reply, already base64) plus
    # any chat-history photos the agent referenced by message_id — downloaded
    # HERE because the handler runs in TaskRunner, not the bot's listen loop.
    if Array(p['source_message_ids']).size + Array(p['input_images']).size > ImageGen::Catalog::MAX_SOURCE_CANDIDATES
      mark_failed_and_notify(task, api, 'image_model_source_conflict')
      return :failed
    end
    images  = resolve_input_images(task, api, p)
    editing = images.any?
    # Edit requested but nothing usable resolved (e.g. every referenced photo
    # predates photo-capture) — fail loudly instead of silently regenerating
    # from scratch (the exact silent-degradation this change exists to kill).
    if edit_intended && (images.empty? || (p.key?('edit_intended') && @missing_image_source))
      mark_failed_and_notify(task, api, 'edit_sources_unavailable',
        user_text: "Не нашёл картинок для редактирования — возможно, они слишком старые. Пришли картинку заново.")
      return :failed
    end

    effective_key = model_key || ImageGen::Catalog.default_key
    if images.size > ImageGen::MAX_EDIT_IMAGES || (effective_key && images.size > ImageGen::Catalog.image_capacity(effective_key))
      if explicit_model || images.size > ImageGen::MAX_EDIT_IMAGES
        mark_failed_and_notify(task, api, 'image_model_source_conflict')
        return :failed
      end
      model_key = ImageGen::Catalog.capable_model_for(images.size, excluded: Array(p['excluded_models']))
      unless model_key
        mark_failed_and_notify(task, api, 'image_model_source_conflict')
        return :failed
      end
      adapter = ImageGen.adapter_for(ImageGen::Catalog.provider_for(model_key))
    end

    # Generate prompt via LLM with chat context (+ vision of the source images when editing)
    unless p['prompt']
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{safe_external(request)}' (edit=#{editing}, provider=#{safe_external(adapter.name)})"

      context = p.key?('prompt_context') ? p['prompt_context'].to_s : get_chat_context(task.chat_id, thread_id: p['forum_thread_id'])
      knowledge = p.key?('prompt_knowledge') ? p['prompt_knowledge'].to_s : get_relevant_knowledge(request, task.chat_id)
      template = adapter.prompt_template(editing ? :edit : :text_to_image)
      # model_name is passed on EVERY path (incl. award/legacy tasks with no
      # model key) because the Atlas template references %{model_name} and
      # Ruby's String#% raises KeyError on a missing referenced key.
      llm_prompt = template % { request: request, context: context, knowledge: knowledge,
                               model_name: (model_key || 'AI image generator') }

      messages = if editing
        image_blocks = images.map do |img|
          { type: 'image', source: { type: 'base64', media_type: img[:media_type], data: img[:data] } }
        end
        [{ role: 'user', content: image_blocks + [{ type: 'text', text: llm_prompt }] }]
      else
        [{ role: 'user', content: llm_prompt }]
      end

      # Prompt composition is a bounded creative rewrite, not an agent turn.
      # Keep it on its own low-latency setting with thinking disabled so it
      # cannot spend thousands of reasoning tokens turning a joke into a
      # literal checklist. DeepSeek Flash is multimodal, so one setting handles
      # both text-to-image and edits. GptMaster converts these Anthropic-shape
      # image blocks to OpenAI image_url blocks at the wire boundary.
      enrich_setting = 'image_prompt'
      begin
        composed_prompt = GptMaster.new(messages, setting: enrich_setting,
                                        chat_id: task.chat_id, user_uid: p['user_uid'],
                                        purpose: 'image_prompt', report_errors: false).call
        # Prompt enrichment is optional polish. Provider failures are surfaced
        # by GptMaster as this sentinel; do not retry/fail the image task just
        # because the rewrite model is unavailable or rejects its parameters.
        if composed_prompt == 'жпт не жпт'
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt composer failed; using raw request"
          p['prompt'] = request
        # Some OpenAI-compatible providers can consume the whole output budget
        # in hidden/reasoning content and return an empty visible reply with
        # stop=length. Never submit that empty prompt to the image backend.
        elsif composed_prompt.to_s.strip.empty?
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt composer returned blank output; using raw request"
          p['prompt'] = request
        else
          p['prompt'] = composed_prompt.to_s.strip
        end

        if prompt_refusal?(p['prompt']) || unsafe_composed_prompt?(p['prompt'], request, p)
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt composer refused; using raw request"
          p['prompt'] = request
        end
      rescue => e
        # Unexpected composer errors are equally non-fatal. Submission and
        # polling keep their own retry budgets; prompt polish must never consume
        # those attempts or prevent a valid raw request reaching the backend.
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt composer error #{e.class}; using raw request"
        p['prompt'] = request
      end
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: prompt → '#{safe_external(p['prompt'])[0..100]}...'"
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    # Provider-specific model id for this mode; nil ⇒ adapter uses its
    # configured default (legacy tasks, or an edit:false catalog entry).
    mode = editing ? :edit : :text_to_image
    resolved_model_id = model_key ? ImageGen::Catalog.model_id_for(model_key, mode) : nil
    if editing && model_key && resolved_model_id.nil?
      mark_failed_and_notify(task, api, 'image_model_unavailable')
      return :failed
    end
    # Durable before POST: a crash or transport exception cannot safely tell us
    # whether the provider accepted a paid request. No adapter has idempotency.
    p['submit_in_flight'] = true
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    begin
      submit_result = adapter.submit(prompt: p['prompt'],
                                     input_images: editing ? images : nil,
                                     model: resolved_model_id)
    rescue => e
      if e.is_a?(ModelProviderClient::HttpError) && e.status.is_a?(Integer) && e.status.between?(400, 499)
        mark_failed_and_notify(task, api, 'submit_rejected', provider_reason: e.message)
      else
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit outcome unknown: #{e.class}: #{sanitized_error_message(e)}"
        mark_failed_and_notify(task, api, 'submit_outcome_unknown', provider_reason: e.message)
      end
      return :failed
    end
    valid_submit_result = if adapter.synchronous?
      submit_result.is_a?(Hash)
    else
      submit_result.is_a?(String) && !submit_result.strip.empty?
    end
    unless valid_submit_result
      mark_failed_and_notify(task, api, 'submit_outcome_unknown')
      return :failed
    end
    p['provider'] = adapter.name
    p['model']    = model_key if model_key   # forensics snapshot (poll dispatches on provider)

    # Synchronous adapters (e.g. CloseRouter Nano Banana Pro) return a
    # terminal result Hash from #submit and skip the poll cycle entirely.
    # Async adapters (Flux, Atlas) return a String external_id.
    if adapter.synchronous?
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: synchronous submit complete via #{safe_external(adapter.name)}"
      # Persist params snapshot (provider, prompt, retry counters) BEFORE
      # marking the task done. provider snapshot is informational only for
      # sync tasks (poll never runs, no adapter_for dispatch), but it lets
      # `бот задачи` + log forensics see which backend served the request.
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      return deliver_sync_result(task, api, submit_result)
    end

    p.delete('submit_in_flight')
    task_id = submit_result
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{safe_external(task_id)} via #{safe_external(adapter.name)}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: task_id, params: p.to_json) }
    :pending
  end

  # Prompt enrichment is optional polish, never an authorization layer. If the
  # composer returns a stock refusal, sending that refusal to the image backend
  # makes an otherwise valid provider request fail silently or draw the refusal
  # itself. Preserve the user's raw wording instead.
  PROMPT_REFUSAL = /(?:i\s+(?:can(?:not|'t)|won't)\s+(?:help|assist|comply|create)|я\s+не\s+могу\s+(?:помочь|выполнить|создать|сделать)|не\s+могу\s+(?:помочь|выполнить|создать|сделать)|отказываюсь)/i

  def prompt_refusal?(text)
    text.to_s.match?(PROMPT_REFUSAL)
  end

  # Reject invented operational labels and rewrites that omit the user's
  # literal directive. Preserve requested labels and numbers verbatim.
  def unsafe_composed_prompt?(composed, request, params)
    return false unless params.key?('prompt_context')
    return true unless composed.include?(request)
    pattern = /(?:#\s*\d+|\btask\s*#?\s*\d+|задач[аиуы]?\s*#?\s*\d+|в\s+очереди|поставлен[аоы]?\s+в\s+очередь|доставк[аиу]|queue(?:d)?|deliver(?:y|ed))/i
    composed.scan(pattern).any? { |token| !request.downcase.include?(token.downcase) }
  end

  # Synchronous-path delivery. Mirrors the `when Hash` arm of poll_and_deliver
  # without the retry/agent-event-after-retries plumbing.
  #
  # `generation_retries` accounting is intentionally skipped here: it counts
  # poll-time `:retry` returns (transient backend hiccups during async
  # generation), which sync adapters can NEVER produce by definition. The
  # submit errors end in a terminal notice; no retry is safe without
  # provider idempotency. No recovery event is needed on this path.
  def deliver_sync_result(task, api, result)
    LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: synchronous generation complete (URL redacted)"
    cache_delivery_result(task, result)
    deliver_generated_result(task, api, result)
  end

  # Shared by BOTH delivery paths (sync deliver_sync_result + async
  # poll_and_deliver) — awards must get 🏆 on every backend.
  def caption_for(p)
    prefix = p['award'] ? '🏆' : '🎨'
    "#{prefix} #{p['prompt'].to_s.empty? ? p['request'] : p['prompt']}"
  end

  MAX_GENERATION_RETRIES = 3
  # Consecutive status-endpoint (poll) errors tolerated before failing the task.
  # ~5 polls ≈ 75s — long enough to ride out a transient Atlas blip, far short of
  # the 60-attempt (~15min) timeout that would otherwise fire with a wrong message.
  MAX_POLL_ERRORS = 5

  def poll_and_deliver(task, api)
    mark_processing_unless_retrying(task)
    provider = task.params_hash['provider']
    begin
      adapter = ImageGen.adapter_for(provider)
    rescue => e
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll adapter resolution failed: #{e.class}: #{sanitized_error_message(e)}"
      mark_failed_and_notify(task, api, 'adapter_config_error')
      return :failed
    end
    begin
      result = adapter.poll_once(task.external_id)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: poll raised #{e.class}: #{sanitized_error_message(e)}"
      result = :poll_error
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{safe_external(task.external_id)} via #{safe_external(adapter.name)} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{safe_external(result.inspect)}"

    case result
    when :pending
      # Reset is deliberately :pending-only — Atlas never returns :retry, and
      # Hash/:failed are terminal. A future :retry-returning model would carry a
      # prior error streak forward (harmless; revisit if such a model is added).
      reset_poll_errors(task) # a healthy 200 poll clears the consecutive-error streak
      mark_processing_unless_retrying(task)
      :pending
    when :poll_error
      # The status endpoint failed (e.g. Atlas 500). Tolerate a few CONSECUTIVE
      # errors (transient blip) but fail fast on a persistent outage instead of
      # spinning to the 60-attempt timeout with a misleading "timeout" message.
      p    = task.params_hash
      errs = (p['poll_errors'] || 0) + 1
      p['poll_errors'] = errs
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{safe_external(adapter.name)} poll unavailable for #{safe_external(task.external_id)} (#{errs}/#{MAX_POLL_ERRORS})"
      if errs >= MAX_POLL_ERRORS
        mark_failed_and_notify(task, api, 'poll_unavailable')
        return :failed
      end
      ActiveRecord::Base.connection_pool.with_connection do
        task.mark_retrying!(params: p.to_json)
      end
      :pending
    when :retry
      p = task.params_hash
      retries = (p['generation_retries'] || 0) + 1
      p['generation_retries'] = retries
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{safe_external(adapter.name)} transient failure for #{safe_external(task.external_id)} (retry #{retries}/#{MAX_GENERATION_RETRIES})"
      if retries <= MAX_GENERATION_RETRIES
        # Clear external_id so next handler call re-submits with cached prompt.
        ActiveRecord::Base.connection_pool.with_connection do
          task.mark_retrying!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'image_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'image_failed')
      :failed
    when Hash
      if result[:failed] || result['failed']
        provider_reason = result[:error] || result['error']
        structured_reason = result[:failure_reason] || result['failure_reason']
        mark_failed_and_notify(task, api, 'image_failed', provider_reason: provider_reason, structured_reason: structured_reason)
        :failed
      else
        LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: asynchronous generation complete (URL redacted)"
        cache_delivery_result(task, result)
        deliver_generated_result(task, api, result)
      end
    end
  end

  # Persist the provider's terminal result while the task is still pending.
  # This is the hand-off between generation and delivery: subsequent TaskRunner
  # cycles see delivery_result first and never submit/poll the image again.
  def cache_delivery_result(task, result)
    p = task.params_hash
    p['delivery_result'] = JSON.parse(result.to_json)
    p.delete('submit_in_flight')
    ActiveRecord::Base.connection_pool.with_connection do
      # Provider polling and Telegram delivery have independent bounded
      # budgets. A successful paid generation near the poll cap must still get
      # its configured delivery retries. This reset happens only once, when
      # the terminal provider result is first cached; re-entry sees the cache
      # above and never resets/repeats provider work.
      task.update!(params: p.to_json, attempts: 0,
                   lifecycle_phase: 'delivering', delivery_status: 'pending')
    end
  end

  def deliver_generated_result(task, api, result)
    p = task.params_hash
    url = result['url'] || result[:url]
    unless url
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generated result has no URL: #{safe_external(result.inspect)}"
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но не удалось отправить её в чат',
        delivery_status: 'failed')
      return :failed
    end

    # If Telegram accepted the image and the bot row was persisted before a
    # process crash, reconcile from that durable row instead of sending again.
    # There remains an unavoidable ambiguity if the process dies after the
    # external send but before either receipt or Message row is committed:
    # Telegram offers no idempotency key for sendPhoto, so strict external
    # exactly-once delivery cannot be guaranteed across that narrow window.
    existing = existing_delivery_message(task)
    return complete_from_existing_message(task, result, p) if existing

    if p['image_document_in_flight']
      mark_failed_and_notify(task, api, 'image_delivery_failed', delivery_status: 'unknown')
      return :failed
    end

    send_result = send_photo(api, task.chat_id, url, caption_for(p),
                             forum_thread_id: p['forum_thread_id']) do
      next false if p['delivery_ambiguous']

      p['image_document_in_flight'] = true
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      true
    end
    case send_result[:status]
    when :accepted
      cache_delivery_receipt(task, send_result[:receipt])
      persist_receipt_and_complete(task, api, send_result[:receipt])
    when :retry
      failures = (p['delivery_failures'] || 0) + 1
      p['delivery_failures'] = failures
      p['delivery_ambiguous'] = true unless p['delivery_receipt']
      ActiveRecord::Base.connection_pool.with_connection do
        task.mark_retrying!(params: p.to_json, delivery_status: 'pending')
      end
      if failures < MAX_DELIVERY_FAILURES && task.attempts + 1 < task.max_attempts
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Telegram delivery transient failure #{failures}/#{MAX_DELIVERY_FAILURES}; retrying next task cycle"
        return :pending
      end
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но Telegram не смог её отправить',
        delivery_status: 'unknown')
      :failed
    else
      if send_result[:delivery_status] == 'unknown' && !p['delivery_receipt']
        p['delivery_ambiguous'] = true
        ActiveRecord::Base.connection_pool.with_connection do
          task.update!(params: p.to_json, delivery_status: 'unknown')
        end
      end
      delivery_status = if p['delivery_receipt']
        'delivered'
      elsif p['delivery_ambiguous']
        'unknown'
      else
        send_result[:delivery_status] || 'unknown'
      end
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но Telegram не смог её отправить',
        delivery_status: delivery_status)
      :failed
    end
  end

  def delivery_correlation_id(task)
    task.external_id.to_s.empty? ? "image-task:#{task.id}" : task.external_id
  end

  def existing_delivery_message(task)
    ActiveRecord::Base.connection_pool.with_connection do
      Message.find_by(chat_id: task.chat_id, role: 'bot',
                      bg_task_external_id: delivery_correlation_id(task))
    end
  end

  def complete_from_existing_message(task, result, params)
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction { mark_done_sanitized!(task, result) }
    end
    emit_generation_recovery_event(task, params)
    :done
  end

  # Telegram has acknowledged the send. Persist a compact, JSON-safe receipt
  # before attempting the local Message write so a DB retry never resends the
  # externally-visible photo.
  def cache_delivery_receipt(task, receipt)
    p = task.params_hash
    p['delivery_receipt'] = receipt
    p.delete('image_document_in_flight')
    # The provider URL is needed only until Telegram acknowledges sendPhoto.
    # From this point onward the compact Telegram receipt is the durable
    # re-entry key, so retaining the signed URL (or any other provider result)
    # only leaks a credential-bearing artifact into persistence retries.
    p.delete('delivery_result')
    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(params: p.to_json, lifecycle_phase: 'persisting_delivery', delivery_status: 'delivered')
    end
  end

  def persist_receipt_and_complete(task, api, receipt)
    p = task.params_hash
    result = p['delivery_result'] || {}
    correlation_id = delivery_correlation_id(task)
    caption = caption_for(p)

    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction do
        existing = Message.find_by(chat_id: task.chat_id, role: 'bot',
                                   bg_task_external_id: correlation_id)
        unless existing
          persisted = persist_bot_media_row(
            task.chat_id, receipt, caption,
            bg_task_external_id: correlation_id,
            forum_thread_id: p['forum_thread_id']
          )
          raise DeliveryPersistenceError, 'delivery receipt was not persisted' unless persisted
        end
        mark_done_sanitized!(task, result)
      end
    end

    emit_generation_recovery_event(task, p)
    :done
  rescue DeliveryPersistenceError, ActiveRecord::ActiveRecordError => e
    handle_persistence_failure(task, api, e)
  end

  def handle_persistence_failure(task, api, error)
    p = task.params_hash
    failures = (p['persistence_failures'] || 0) + 1
    p['persistence_failures'] = failures
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_retrying!(params: p.to_json, delivery_status: 'delivered')
    end
    if failures < MAX_PERSISTENCE_FAILURES && task.attempts + 1 < task.max_attempts
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: delivery receipt persistence failure #{failures}/#{MAX_PERSISTENCE_FAILURES}: #{error.class}: #{sanitized_error_message(error)}"
      return :pending
    end

    mark_failed_and_notify(task, api, 'image_persistence_failed',
      user_text: 'Картинка отправлена, но бот не смог сохранить подтверждение доставки')
    :failed
  end

  def emit_generation_recovery_event(task, params)
    return unless (params['generation_retries'] || 0) >= 1
    emit_agent_event(task, 'image_succeeded_after_retries',
      summary: "Запрос: #{params['request'].to_s[0..200]} | Получилось с #{params['generation_retries']}-й попытки.",
      forum_thread_id: params['forum_thread_id'])
  rescue => e
    # The image and its Message row are already durably complete. A secondary
    # informational event must never roll that success back into a retry or a
    # misleading delivery/persistence failure.
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: recovery event creation failed: #{e.class}: #{sanitized_error_message(e)}"
    nil
  end

  # Resolve the ordered edit-source image list:
  #   1. inline images (current/replied photo) — already base64 in params
  #   2. legacy singular input_image (tasks enqueued before this deploy)
  #   3. chat-history photos referenced by message_id — same resolution as the
  #      view_image tool, downloaded here (TaskRunner, not the bot loop)
  # Missing/old message_ids (no stored file_id) and failed downloads are skipped
  # with a warning. Returns up to MAX_EDIT_IMAGES of { data:, media_type: }.
  def resolve_input_images(task, api, p)
    images = []
    @missing_image_source = !!p['missing_inline_source']
    Array(p['input_images']).each do |img|
      data = img['data'] || img[:data]
      if data.to_s.empty?
        @missing_image_source = true
        next
      end
      images << { data: data, media_type: img['media_type'] || img[:media_type] || 'image/jpeg' }
    end
    if images.empty? && !p['input_image'].to_s.empty?
      images << { data: p['input_image'], media_type: p['input_media_type'] || 'image/jpeg' }
    end
    seen_files = []
    inline_ids = Array(p['input_images']).filter_map { |img| img['source_message_id'] || img[:source_message_id] }.map(&:to_i)
    Array(p['source_message_ids']).map(&:to_i).uniq.each do |mid|
      next if inline_ids.include?(mid)
      file_id = ActiveRecord::Base.connection_pool.with_connection do
        scope = Message.where(chat_id: task.chat_id, message_id: mid)
        scope = scope.where(message_thread_id: p['forum_thread_id']) if p['forum_thread_id']
        scope.pick(:attachment_photo_file_id)
      end
      unless file_id
        @missing_image_source = true
        next
      end
      next if seen_files.include?(file_id)
      seen_files << file_id
      img = TelegramFile.download_image(api, file_id, chat_id: task.chat_id)
      unless img && !img[:data].to_s.empty?
        @missing_image_source = true
        next
      end
      images << { data: img[:data], media_type: img[:media_type] || 'image/jpeg' }
    end
    images.uniq do |img|
      data = img[:data].to_s
      bytes = begin
        Base64.strict_decode64(data)
      rescue ArgumentError
        data
      end
      Digest::SHA256.digest(bytes)
    end
  end

  # Clear the consecutive poll-error counter after a healthy poll so a later
  # transient blip starts fresh. Only writes when the counter is non-zero.
  def reset_poll_errors(task)
    p = task.params_hash
    return unless (p['poll_errors'] || 0) > 0
    p['poll_errors'] = 0
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
  end

  def mark_failed_and_notify(task, api, reason, user_text: "Не удалось сгенерировать картинку",
                             provider_reason: nil, structured_reason: nil,
                             terminal_transition: nil, delivery_status: nil)
    unless terminal_transition
      terminal_transition = persist_or_read_terminal_failure_transition(
        task, reason, user_text: user_text, provider_reason: provider_reason,
        structured_reason: structured_reason, delivery_status: delivery_status
      )
      return unless terminal_transition
    end

    reason = terminal_transition['reason']
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation #{reason} for #{safe_external(task.external_id)}"
    failure_stage = terminal_transition['failure_stage']
    failure_reason = terminal_transition['failure_reason']
    event_type = terminal_transition['event_type']
    summary = terminal_transition['summary']
    user_text = terminal_transition['user_text']

    # Async failures belong to the agent loop: it has the chat context and can
    # explain the real outcome instead of leaving a context-free placeholder.
    # The deterministic text is used only if the event queue is unavailable
    # (for example, rate-limited or its insert fails). AgentEventHandler owns
    # the equivalent fallback when the queued agent turn itself cannot answer.
    begin
      ActiveRecord::Base.connection_pool.with_connection do
        BackgroundTask.transaction do
          # Acquire SQLite's write lock before inspecting the parent and notice,
          # serializing competing failure paths even when the parent is terminal.
          BackgroundTask.where(id: task.id).update_all('updated_at = updated_at')
          current_parent = BackgroundTask.find_by(id: task.id)
          next unless current_parent

          forum_thread_id = current_parent.params_hash['forum_thread_id']
          current_status = current_parent.status
          existing = BackgroundTask.where(chat_id: current_parent.chat_id, parent_task_id: current_parent.id,
                                          task_type: %w[agent_event failure_notice]).exists?
          mark_failed_sanitized!(current_parent, reason, failure_stage, failure_reason,
                                 terminal_transition['delivery_status']) if current_status == 'pending'
          if %w[pending failed].include?(current_status) && !existing
            event = begin
              BackgroundTask.transaction(requires_new: true) do
                emit_agent_event(current_parent, event_type, summary: summary, user_notified: false,
                                 forum_thread_id: forum_thread_id, failure_stage: failure_stage,
                                 failure_reason: failure_reason)
              end
            rescue => e
              LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: event insert failed: #{e.class}: #{sanitized_error_message(e)}"
              nil
            end
            enqueue_failure_notice(current_parent, user_text, forum_thread_id, event_type: event_type,
                                   failure_stage: failure_stage, failure_reason: failure_reason) unless event
          end
        end
      end
    rescue => e
      # This special no-attempt exception is allowed only after a separate
      # connection can read back the terminal outcome checkpoint. A rejected
      # checkpoint write must escape as an ordinary bounded handler failure.
      durable = ActiveRecord::Base.connection_pool.with_connection do
        BackgroundTask.find_by(id: task.id)&.params_hash&.[]('terminal_failure_transition')
      end
      if durable == terminal_transition
        raise BackgroundTask::NotificationTransitionPending, sanitized_error_message(e)
      end

      raise sanitized_exception(e)
    end
  end

  def persist_or_read_terminal_failure_transition(task, reason, user_text:, provider_reason:,
                                                 structured_reason:, delivery_status:)
    transition = nil
    ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.transaction do
        # Serialize checkpoint writers before reading the current params. A
        # stale handler must never replace a winner's transition or restore a
        # provider URL that the winner already scrubbed.
        BackgroundTask.where(id: task.id).update_all('updated_at = updated_at')
        current = BackgroundTask.find_by(id: task.id)
        if current
          params = current.params_hash
          transition = params['terminal_failure_transition']
          if transition.nil? && current.status == 'pending'
            candidate = build_terminal_failure_transition(
              current, reason, user_text: user_text, provider_reason: provider_reason,
              structured_reason: structured_reason, delivery_status: delivery_status
            )
            checkpoint_params = params.dup
            if checkpoint_params['delivery_result']
              checkpoint_params['delivery_result'] = sanitized_data(checkpoint_params['delivery_result'])
            end
            encoded_params = checkpoint_params.merge('terminal_failure_transition' => candidate).to_json
            updated = BackgroundTask.where(id: current.id, status: 'pending')
              .where("json_type(COALESCE(params, '{}'), '$.terminal_failure_transition') IS NULL")
              .update_all(params: encoded_params, updated_at: Time.now)
            if updated == 1
              transition = candidate
            else
              winner = BackgroundTask.find_by(id: current.id)
              transition = winner&.params_hash&.[]('terminal_failure_transition')
            end
          end
        end
      end
    end
    transition if transition.is_a?(Hash)
  end

  def build_terminal_failure_transition(task, reason, user_text:, provider_reason:,
                                        structured_reason:, delivery_status:)
    failure_stage, failure_reason = classify_failure(reason, provider_reason, structured_reason)
    event_type = if reason.to_s == 'image_delivery_failed'
      'image_delivery_failed'
    elsif reason.to_s == 'image_persistence_failed'
      'image_persistence_failed'
    elsif reason.to_s.include?('after_retries')
      'image_failed_after_retries'
    else
      'image_failed'
    end
    provider_detail = Agent::ErrorReporter.sanitize(provider_reason.to_s)[0, 400]
    readable_reason = reason.to_s.tr('_', ' ')
    readable_reason += ": #{provider_detail}" unless provider_detail.empty?
    summary = "Задача ##{task.id} | Запрос: #{task.params_hash['request'].to_s[0..200]} | " \
              "Промпт: #{task.params_hash['prompt'].to_s[0..200]} | Причина: #{readable_reason}"
    {
      'reason' => reason.to_s,
      'user_text' => safe_external(user_text),
      'provider_reason' => provider_detail,
      'failure_stage' => failure_stage,
      'failure_reason' => failure_reason,
      'event_type' => event_type,
      'summary' => Agent::ErrorReporter.sanitize(summary),
      'delivery_status' => (delivery_status if BackgroundTask::DELIVERY_STATUSES.include?(delivery_status.to_s)),
    }.compact
  end

  def classify_failure(reason, provider_reason, structured_reason = nil)
    reason = reason.to_s
    return ['poll', 'moderation'] if structured_reason.to_s == 'moderation'
    return ['delivery', 'telegram_failed'] if reason == 'image_delivery_failed'
    return ['persistence', 'persistence_failed'] if reason == 'image_persistence_failed'
    return ['submit', 'model_unavailable'] if reason == 'image_model_unavailable'
    return ['submit', 'model_source_conflict'] if reason == 'image_model_source_conflict'
    return ['submit', 'edit_sources_unavailable'] if reason == 'edit_sources_unavailable'
    return ['submit', 'provider_rejected'] if reason == 'submit_rejected'
    return ['submit', 'submit_outcome_unknown'] if reason == 'submit_outcome_unknown'
    return ['poll', 'timeout'] if reason == 'poll_timeout'
    return ['submit', 'timeout'] if reason == 'submit_timeout'
    return ['poll', 'provider_unavailable'] if reason == 'poll_unavailable'
    stage = %w[submit_failures_after_retries adapter_config_error].include?(reason) ? 'submit' : 'poll'
    detail = provider_reason.to_s.downcase
    cause = if detail.match?(/timed?\s*out|timeout/)
      'timeout'
    elsif detail.match?(/unavailable|connection|refused|5\d\d/)
      'provider_unavailable'
    else
      'unknown'
    end
    [stage, cause]
  end

  def enqueue_failure_notice(task, text, forum_thread_id, event_type: nil,
                             failure_stage: nil, failure_reason: nil)
    ActiveRecord::Base.connection_pool.with_connection do
      existing = BackgroundTask.where(task_type: 'failure_notice', chat_id: task.chat_id,
                                      parent_task_id: task.id).first
      return existing if existing

      BackgroundTask.create!(
        task_type: 'failure_notice', chat_id: task.chat_id, parent_task_id: task.id,
        max_attempts: 5,
        params: {
          text: text,
          forum_thread_id: forum_thread_id,
          parent_task_id: task.id,
          parent_task_type: task.task_type,
          event_type: event_type,
          failure_stage: failure_stage,
          failure_reason: failure_reason,
        }.compact.to_json
      )
    end
  end

  def send_photo(api, chat_id, url, caption, forum_thread_id: nil, &before_document)
    caption = caption[0..1020] + "..." if caption.length > 1024
    started = monotonic_now
    download = download_to_tempfile(url)
    tmp = download && download[:file]
    upload_started = monotonic_now
    send_params = { chat_id: chat_id, caption: caption }
    send_params[:message_thread_id] = forum_thread_id if forum_thread_id
    response = if download
      File.open(tmp.path, 'rb') do |file|
        api.sendPhoto(**send_params, photo: Faraday::UploadIO.new(file, download[:mime_type], download[:filename]))
      end
    else
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: download failed, falling back to URL"
      send_params[:photo] = url
      api.sendPhoto(**send_params)
    end

    delivery_from_response(response, forum_thread_id: forum_thread_id)
  rescue => e
    if upload_started
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto timing: download_ms=#{elapsed_ms(started, upload_started)} upload_ms=#{elapsed_ms(upload_started)} mode=#{tmp ? 'multipart' : 'url'}"
    end
    if before_document && tmp && image_processing_rejected?(e)
      fallback = deliver_as_image_document(api, send_params, tmp, &before_document)
      return fallback if fallback
    end
    if TaskDeliveryErrors.retryable?(e)
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto transient failure: #{e.class}: #{sanitized_error_message(e)}"
      { status: :retry, delivery_status: 'unknown' }
    elsif TaskDeliveryErrors.definitive_telegram_rejection?(e)
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendPhoto rejected by Telegram: #{sanitized_error_message(e)}"
      { status: :failed, delivery_status: 'failed' }
    else
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendPhoto failed: #{e.class}: #{sanitized_error_message(e)}"
      { status: :failed, delivery_status: 'unknown' }
    end
  ensure
    if tmp
      begin
        tmp.close unless tmp.closed?
      rescue => e
        LOGGER.warn "[chat=#{chat_id}] #{self.class.name} tempfile close failed: #{e.class}: #{sanitized_error_message(e)}"
      end
      begin
        tmp.unlink
      rescue Errno::ENOENT
        nil
      rescue => e
        LOGGER.warn "[chat=#{chat_id}] #{self.class.name} tempfile unlink failed: #{e.class}: #{sanitized_error_message(e)}"
      end
    end
  end

  def image_processing_rejected?(error)
    return false unless TaskDeliveryErrors.telegram_error_code(error) == 400

    description = error.data['description'] || error.data[:description]
    description.to_s.strip.match?(/\A(?:Bad Request:\s*)?IMAGE_PROCESS_FAILED\z/i)
  end

  def deliver_as_image_document(api, params, tmp)
    bytes = File.size(tmp.path)
    return if bytes.zero? || bytes > MAX_IMAGE_DOCUMENT_BYTES
    mime = TelegramFile.image_mime_type(File.binread(tmp.path, 12))
    return unless mime

    filename = "image.#{mime.delete_prefix('image/')}"
    response = File.open(tmp.path, 'rb') do |file|
      upload = Faraday::UploadIO.new(file, mime, filename)
      return unless yield

      LOGGER.info "[chat=#{params[:chat_id]}] #{self.class.name}: Telegram rejected photo processing; sending original image as a file (#{mime}, #{bytes} bytes)"
      api.sendDocument(**params, document: upload, disable_content_type_detection: true)
    end
    delivery_from_response(response, forum_thread_id: params[:message_thread_id], image_document: true)
  rescue StandardError => e
    LOGGER.warn "[chat=#{params[:chat_id]}] #{self.class.name} image document delivery: #{e.class}: #{sanitized_error_message(e)}"
    # Ruby may attach the preceding photo rejection as the cause of this
    # error. Only a response from sendDocument can prove document rejection.
    code = TaskDeliveryErrors.telegram_error_code(e)
    status = code&.between?(400, 499) && code != 429 ? 'failed' : 'unknown'
    { status: :failed, delivery_status: status }
  end

  def delivery_from_response(response, forum_thread_id:, image_document: false)
    receipt = serialize_delivery_receipt(response, forum_thread_id: forum_thread_id, image_document: image_document)
    return { status: :accepted, receipt: receipt } if valid_message_id?(receipt['message_id'])

    { status: :failed, delivery_status: 'unknown' }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started, finished = monotonic_now)
    ((finished - started) * 1000).round
  end

  def telegram_response_error?(error)
    TaskDeliveryErrors.telegram_response_error?(error)
  end

  def retryable_telegram_response?(error)
    TaskDeliveryErrors.retryable?(error)
  end

  def sanitized_error_message(error)
    Agent::ErrorReporter.sanitize(error.message)
  end

  def safe_external(value)
    Agent::ErrorReporter.sanitize(value)
  end

  def sanitized_exception(error)
    safe = error.exception(sanitized_error_message(error))
    safe.set_backtrace(error.backtrace)
    safe
  rescue
    RuntimeError.new(sanitized_error_message(error))
  end

  def sanitized_data(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), out| out[key] = sanitized_data(item) }
    when Array
      value.map { |item| sanitized_data(item) }
    when String
      safe_external(value)
    else
      value
    end
  end

  # Terminal tasks no longer need the provider's signed completion URL. Scrub
  # it from both params and result while committing the final state.
  def mark_done_sanitized!(task, result)
    p = task.params_hash
    p['delivery_result'] = sanitized_data(p['delivery_result']) if p['delivery_result']
    task.update!(status: 'done', lifecycle_phase: 'completed', delivery_status: 'delivered',
                 result: sanitized_data(result).to_json, params: p.to_json)
  end

  def mark_failed_sanitized!(task, reason, failure_stage, failure_reason, delivery_status = nil)
    p = task.params_hash
    p['delivery_result'] = sanitized_data(p['delivery_result']) if p['delivery_result']
    delivery = if BackgroundTask::DELIVERY_STATUSES.include?(delivery_status.to_s)
      delivery_status
    else
      case reason.to_s
      when 'image_delivery_failed' then 'failed'
      when 'image_persistence_failed' then 'delivered'
      else 'unknown'
      end
    end
    task.update!(status: 'failed', lifecycle_phase: 'failed', delivery_status: delivery,
                 result: { error: reason, failure_stage: failure_stage, failure_reason: failure_reason,
                           requested_model: (safe_external(p['model']) if reason.to_s == 'image_model_unavailable') }.compact.to_json, params: p.to_json)
  end

  def valid_message_id?(message_id)
    message_id.is_a?(Integer) && message_id.positive?
  end

  def serialize_delivery_receipt(response, forum_thread_id: nil, image_document: false)
    raw = response.is_a?(Hash) ? (response['result'] || response[:result] || response) : response
    message_id = if raw.respond_to?(:message_id)
      raw.message_id
    elsif raw.is_a?(Hash)
      raw['message_id'] || raw[:message_id]
    end
    thread_id = if raw.respond_to?(:message_thread_id)
      raw.message_thread_id
    elsif raw.is_a?(Hash)
      raw['message_thread_id'] || raw[:message_thread_id]
    end
    photos = if raw.respond_to?(:photo)
      raw.photo
    elsif raw.is_a?(Hash)
      raw['photo'] || raw[:photo]
    end
    receipt = {
      'message_id' => message_id,
      'message_thread_id' => thread_id || forum_thread_id,
      'photo' => Array(photos).map { |photo| serialize_photo_size(photo) },
    }
    if image_document
      document = raw.is_a?(Hash) ? (raw['document'] || raw[:document]) : (raw.document if raw.respond_to?(:document))
      file_id = document.is_a?(Hash) ? (document['file_id'] || document[:file_id]) : (document.file_id if document.respond_to?(:file_id))
      receipt['image_document_file_id'] = file_id unless file_id.to_s.empty?
    end
    receipt
  end

  def serialize_photo_size(photo)
    if photo.is_a?(Hash)
      {
        'file_id' => photo['file_id'] || photo[:file_id],
        'width' => photo['width'] || photo[:width],
        'height' => photo['height'] || photo[:height],
      }.compact
    else
      %i[file_id width height].each_with_object({}) do |key, serialized|
        serialized[key.to_s] = photo.public_send(key) if photo.respond_to?(key)
      end.compact
    end
  end

  # Save the sent photo as a bot Message row so user replies pointing at the
  # photo's Telegram message_id can resolve to a known row, and so the agent
  # can re-view its own generated image via the view_image tool (the photo
  # file_id is captured by Message.persist_bot_reply — the centralized
  # bot-side persistence path).
  def persist_bot_media_row(chat_id, response, caption, bg_task_external_id: nil,
                            forum_thread_id: nil)
    Message.persist_bot_reply(chat_id: chat_id, body: caption, response: response,
                              bg_task_external_id: bg_task_external_id,
                              message_thread_id: forum_thread_id,
                              image_document_file_id: (response['image_document_file_id'] if response.is_a?(Hash)))
  end

  def download_to_tempfile(url)
    response = HTTParty.get(url, timeout: 60)
    return nil unless response.code == 200
    mime_type, extension = image_type_for(response, url)
    tmp = Tempfile.new(['image_gen_', extension], '/tmp')
    tmp.binmode
    tmp.write(response.body)
    tmp.rewind
    { file: tmp, mime_type: mime_type, filename: "image#{extension}" }
  rescue => e
    LOGGER.warn "#{self.class.name} download failed: #{e.class}: #{sanitized_error_message(e)}"
    begin
      tmp&.close
      tmp&.unlink
    rescue => cleanup_error
      LOGGER.warn "#{self.class.name} download tempfile cleanup failed: #{cleanup_error.class}: #{sanitized_error_message(cleanup_error)}"
      nil
    end
    nil
  end

  def image_type_for(response, url)
    content_type = response.headers['content-type'].to_s.split(';').first.downcase
    by_mime = {
      'image/png' => ['image/png', '.png'],
      'image/webp' => ['image/webp', '.webp'],
      'image/gif' => ['image/gif', '.gif'],
      'image/jpeg' => ['image/jpeg', '.jpg'],
    }
    return by_mime[content_type] if by_mime.key?(content_type)

    extension = File.extname(URI.parse(url).path).downcase
    by_extension = {
      '.png' => ['image/png', '.png'], '.webp' => ['image/webp', '.webp'],
      '.gif' => ['image/gif', '.gif'], '.jpeg' => ['image/jpeg', '.jpg'],
      '.jpg' => ['image/jpeg', '.jpg'],
    }
    by_extension.fetch(extension, ['image/jpeg', '.jpg'])
  rescue URI::InvalidURIError
    ['image/jpeg', '.jpg']
  end
end

TaskRunner.register('image_generate', ImageGenTaskHandler)

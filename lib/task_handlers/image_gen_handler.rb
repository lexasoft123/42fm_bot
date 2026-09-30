require_relative 'agent_event_emitter'
require_relative '../telegram_file'
require 'faraday'
require 'faraday/multipart'
require 'tempfile'
require 'uri'

class ImageGenTaskHandler
  include ChatContext
  include AgentEventEmitter

  MAX_SUBMIT_FAILURES  = 3
  MAX_DELIVERY_FAILURES = 3
  MAX_PERSISTENCE_FAILURES = 3

  class DeliveryPersistenceError < StandardError; end

  def call(task, api)
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

    task.external_id.nil? ? compose_and_submit(task, api) : poll_and_deliver(task, api)
  end

  private

  def compose_and_submit(task, api)
    ActiveRecord::Base.connection_pool.with_connection { task.mark_processing! }
    p = task.params_hash
    request = p['request'].to_s
    model_key = p['model']   # nil for legacy/award tasks (no per-request model)
    # Did the user ask to edit/combine? (inline image, history message_ids, or a
    # legacy single-image task enqueued before this deploy.)
    edit_intended = !p['input_image'].to_s.empty? ||
                    Array(p['input_images']).any? ||
                    Array(p['source_message_ids']).any?
    begin
      if model_key
        prov = ImageGen::Catalog.provider_for(model_key)
        unless ImageGen::ADAPTERS.key?(prov)   # typo'd/unknown provider in catalog entry
          LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: model #{safe_external(model_key).inspect} → unknown provider #{safe_external(prov).inspect}; falling back to default_model"
          model_key = ImageGen::Catalog.default_key   # re-resolve key so model id matches the adapter
          prov      = ImageGen::Catalog.provider_for(model_key)
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
    images  = resolve_input_images(task, api, p)
    editing = images.any?
    # Edit requested but nothing usable resolved (e.g. every referenced photo
    # predates photo-capture) — fail loudly instead of silently regenerating
    # from scratch (the exact silent-degradation this change exists to kill).
    if edit_intended && images.empty?
      mark_failed_and_notify(task, api, 'edit_sources_unavailable',
        user_text: "Не нашёл картинок для редактирования — возможно, они слишком старые. Пришли картинку заново.")
      return :failed
    end

    # Generate prompt via LLM with chat context (+ vision of the source images when editing)
    unless p['prompt']
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generating prompt for '#{safe_external(request)}' (edit=#{editing}, provider=#{safe_external(adapter.name)})"

      context = get_chat_context(task.chat_id, thread_id: p['forum_thread_id'])
      knowledge = get_relevant_knowledge(request, task.chat_id)
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

        if prompt_refusal?(p['prompt'])
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
    begin
      resolved_model_id = model_key ? ImageGen::Catalog.model_id_for(model_key, mode) : nil
      submit_result = adapter.submit(prompt: p['prompt'],
                                     input_images: editing ? images : nil,
                                     model: resolved_model_id)
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit: #{e.message}", raise_on_retry: e)
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

  # Synchronous-path delivery. Mirrors the `when Hash` arm of poll_and_deliver
  # without the retry/agent-event-after-retries plumbing.
  #
  # `generation_retries` accounting is intentionally skipped here: it counts
  # poll-time `:retry` returns (transient backend hiccups during async
  # generation), which sync adapters can NEVER produce by definition. The
  # other retry axis — `submit_failures` — runs upstream in `bail_or_retry`
  # and either ultimately succeeds (we reach this method) or fails the task,
  # so it never reaches the success branch either. No agent_event needed.
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

  # Increment a step-failure counter; if cap reached, fail+notify; otherwise re-raise so
  # TaskRunner retries on the next poll cycle.
  def bail_or_retry(task, api, params, counter, max, reason, raise_on_retry:)
    reason = safe_external(reason)
    params[counter] = (params[counter] || 0) + 1
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_retrying!(params: params.to_json)
    end
    if params[counter] >= max
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]} (max #{max}), giving up: #{reason}"
      mark_failed_and_notify(task, api, "#{counter}_after_retries")
      return :failed
    end
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]}/#{max} — will retry: #{reason}"
    raise sanitized_exception(raise_on_retry)
  end

  MAX_GENERATION_RETRIES = 3
  # Consecutive status-endpoint (poll) errors tolerated before failing the task.
  # ~5 polls ≈ 75s — long enough to ride out a transient Atlas blip, far short of
  # the 60-attempt (~15min) timeout that would otherwise fire with a wrong message.
  MAX_POLL_ERRORS = 5

  def poll_and_deliver(task, api)
    ActiveRecord::Base.connection_pool.with_connection { task.mark_processing! }
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
      raise sanitized_exception(e)
    end

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{safe_external(task.external_id)} via #{safe_external(adapter.name)} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{safe_external(result.inspect)}"

    case result
    when :pending
      # Reset is deliberately :pending-only — Atlas never returns :retry, and
      # Hash/:failed are terminal. A future :retry-returning model would carry a
      # prior error streak forward (harmless; revisit if such a model is added).
      reset_poll_errors(task) # a healthy 200 poll clears the consecutive-error streak
      ActiveRecord::Base.connection_pool.with_connection { task.mark_processing! }
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
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: asynchronous generation complete (URL redacted)"
      cache_delivery_result(task, result)
      deliver_generated_result(task, api, result)
    end
  end

  # Persist the provider's terminal result while the task is still pending.
  # This is the hand-off between generation and delivery: subsequent TaskRunner
  # cycles see delivery_result first and never submit/poll the image again.
  def cache_delivery_result(task, result)
    p = task.params_hash
    p['delivery_result'] = JSON.parse(result.to_json)
    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(params: p.to_json, lifecycle_phase: 'delivering', delivery_status: 'pending')
    end
  end

  def deliver_generated_result(task, api, result)
    p = task.params_hash
    url = result['url'] || result[:url]
    unless url
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generated result has no URL: #{safe_external(result.inspect)}"
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но не удалось отправить её в чат')
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

    send_result = send_photo(api, task.chat_id, url, caption_for(p),
                             forum_thread_id: p['forum_thread_id'])
    case send_result[:status]
    when :accepted
      cache_delivery_receipt(task, send_result[:receipt])
      persist_receipt_and_complete(task, api, send_result[:receipt])
    when :retry
      failures = (p['delivery_failures'] || 0) + 1
      p['delivery_failures'] = failures
      ActiveRecord::Base.connection_pool.with_connection do
        task.mark_retrying!(params: p.to_json, delivery_status: 'pending')
      end
      if failures < MAX_DELIVERY_FAILURES && task.attempts + 1 < task.max_attempts
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Telegram delivery transient failure #{failures}/#{MAX_DELIVERY_FAILURES}; retrying next task cycle"
        return :pending
      end
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но Telegram не смог её отправить')
      :failed
    else
      mark_failed_and_notify(task, api, 'image_delivery_failed',
        user_text: 'Картинка сгенерирована, но Telegram не смог её отправить')
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
    Array(p['input_images']).each do |img|
      data = img['data'] || img[:data]
      next if data.to_s.empty?
      images << { data: data, media_type: img['media_type'] || img[:media_type] || 'image/jpeg' }
    end
    if images.empty? && !p['input_image'].to_s.empty?   # legacy single-image task
      images << { data: p['input_image'], media_type: p['input_media_type'] || 'image/jpeg' }
    end
    Array(p['source_message_ids']).each do |mid|
      file_id = ActiveRecord::Base.connection_pool.with_connection do
        Message.where(chat_id: task.chat_id, message_id: mid.to_i).pick(:attachment_photo_file_id)
      end
      unless file_id
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: source message #{mid} has no stored photo — skipping"
        next
      end
      img = TelegramFile.download_image(api, file_id, chat_id: task.chat_id)
      unless img
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to download photo from message #{mid} — skipping"
        next
      end
      images << { data: img[:data], media_type: img[:media_type] || 'image/jpeg' }
    end
    # Post-resolution backstop. The tool pre-caps source_message_ids before
    # enqueue, but this also bounds legacy/in-flight tasks (and any future
    # enqueuer) regardless of how they were created.
    images.first(ImageGen::MAX_EDIT_IMAGES)
  end

  # Clear the consecutive poll-error counter after a healthy poll so a later
  # transient blip starts fresh. Only writes when the counter is non-zero.
  def reset_poll_errors(task)
    p = task.params_hash
    return unless (p['poll_errors'] || 0) > 0
    p['poll_errors'] = 0
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
  end

  def mark_failed_and_notify(task, api, reason, user_text: "Не удалось сгенерировать картинку")
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: generation #{reason} for #{safe_external(task.external_id)}"
    ActiveRecord::Base.connection_pool.with_connection { mark_failed_sanitized!(task, reason) }
    text = user_text
    forum_thread_id = task.params_hash['forum_thread_id']
    user_notified = false
    begin
      send_params = { chat_id: task.chat_id, text: text }
      send_params[:message_thread_id] = forum_thread_id if forum_thread_id
      resp = api.sendMessage(**send_params)
      receipt = serialize_delivery_receipt(resp, forum_thread_id: forum_thread_id)
      user_notified = valid_message_id?(receipt['message_id'])
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp,
                                message_thread_id: forum_thread_id)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{sanitized_error_message(e)}"
    end
    event_type = if reason.to_s == 'image_delivery_failed'
      'image_delivery_failed'
    elsif reason.to_s == 'image_persistence_failed'
      'image_persistence_failed'
    elsif reason.to_s.include?('after_retries')
      'image_failed_after_retries'
    else
      'image_failed'
    end
    summary = "Запрос: #{task.params_hash['request'].to_s[0..200]} | Промпт: #{task.params_hash['prompt'].to_s[0..200]} | Причина: #{reason}"
    emit_agent_event(task, event_type, summary: summary, user_notified: user_notified,
                     forum_thread_id: forum_thread_id)
  end

  def send_photo(api, chat_id, url, caption, forum_thread_id: nil)
    caption = caption[0..1020] + "..." if caption.length > 1024
    download = download_to_tempfile(url)
    tmp = download && download[:file]
    send_params = { chat_id: chat_id, caption: caption }
    send_params[:message_thread_id] = forum_thread_id if forum_thread_id
    response = if download
      send_params[:photo] = Faraday::UploadIO.new(tmp.path, download[:mime_type], download[:filename])
      api.sendPhoto(**send_params)
    else
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name}: download failed, falling back to URL"
      send_params[:photo] = url
      api.sendPhoto(**send_params)
    end

    return { status: :failed } unless response
    receipt = serialize_delivery_receipt(response, forum_thread_id: forum_thread_id)
    unless valid_message_id?(receipt['message_id'])
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendPhoto returned no valid message_id; delivery unconfirmed"
      return { status: :failed }
    end
    { status: :accepted, receipt: receipt }
  rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed, Faraday::TimeoutError,
         Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
         SocketError => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto transient failure: #{e.class}: #{sanitized_error_message(e)}"
    { status: :retry }
  rescue => e
    if telegram_response_error?(e) && retryable_telegram_response?(e)
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendPhoto transient Telegram response: #{e.error_code}: #{sanitized_error_message(e)}"
      { status: :retry }
    else
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendPhoto failed: #{e.class}: #{sanitized_error_message(e)}"
      { status: :failed }
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

  def telegram_response_error?(error)
    defined?(Telegram::Bot::Exceptions::ResponseError) &&
      error.is_a?(Telegram::Bot::Exceptions::ResponseError)
  end

  def retryable_telegram_response?(error)
    code = error.error_code.to_i
    code == 429 || code.between?(500, 599)
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

  def mark_failed_sanitized!(task, reason)
    p = task.params_hash
    p['delivery_result'] = sanitized_data(p['delivery_result']) if p['delivery_result']
    delivery = case reason.to_s
               when 'image_delivery_failed' then 'failed'
               when 'image_persistence_failed' then 'delivered'
               else 'unknown'
               end
    task.update!(status: 'failed', lifecycle_phase: 'failed', delivery_status: delivery,
                 result: { error: reason }.to_json, params: p.to_json)
  end

  def valid_message_id?(message_id)
    message_id.is_a?(Integer) && message_id.positive?
  end

  def serialize_delivery_receipt(response, forum_thread_id: nil)
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
    {
      'message_id' => message_id,
      'message_thread_id' => thread_id || forum_thread_id,
      'photo' => Array(photos).map { |photo| serialize_photo_size(photo) },
    }
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
                              message_thread_id: forum_thread_id)
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

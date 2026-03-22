class ImageGenTaskHandler
  include ChatContext

  PROMPT_TEMPLATE = <<~PROMPT.freeze
    You are an expert image prompt engineer. Convert the user's request into a detailed English prompt for an AI image generator.
    The user requested: "%{request}"
    Chat context (recent messages, use for understanding references to people, events, inside jokes):
    %{context}
    Known facts about the chat and its members:
    %{knowledge}
    Rules:
    - Write a vivid, detailed description: subject, art style, lighting, composition, mood, colors, textures.
    - Be creative and artistic. Frame everything as art, illustration, painting, or photography.
    - If the request mentions chat members or references recent messages, use the context and knowledge to make the image personal and relevant.
    - For edgy or provocative requests: reframe as fine art, classical painting, satirical illustration, editorial cartoon, or cinematic still. Use artistic euphemisms and focus on composition and style rather than explicit content.
    - Never refuse a request. Always find a creative artistic interpretation.
    - Return ONLY the English prompt, nothing else. Max 500 characters.
  PROMPT

  def call(task, api)
    task.external_id.nil? ? compose_and_submit(task) : poll_and_deliver(task, api)
  end

  private

  def compose_and_submit(task)
    p = task.params_hash
    request = p['request'].to_s

    # Generate English prompt via LLM with chat context
    unless p['prompt']
      LOGGER.debug "ImageGenTaskHandler[#{task.id}]: generating prompt for '#{request}'"

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(request, task.chat_id)

      llm_prompt = PROMPT_TEMPLATE % { request: request, context: context, knowledge: knowledge }
      p['prompt'] = GptMaster.new([{ role: 'user', content: llm_prompt }], setting: 'agent').call
      raise "GPT prompt failed" unless p['prompt'] && p['prompt'] != 'жпт не жпт'
      LOGGER.debug "ImageGenTaskHandler[#{task.id}]: prompt → '#{p['prompt'][0..100]}...'"
      task.update!(params: p.to_json)
    end

    task_id = FluxClient.new.submit(prompt: p['prompt'])
    LOGGER.debug "ImageGenTaskHandler[#{task.id}]: submitted #{task_id}"
    task.update!(external_id: task_id, params: p.to_json)
    :pending
  end

  def poll_and_deliver(task, api)
    result = FluxClient.new.poll_once(task.external_id)

    LOGGER.debug "ImageGenTaskHandler[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts})"

    case result
    when :pending
      :pending
    when :failed
      LOGGER.error "ImageGenTaskHandler[#{task.id}]: generation failed for #{task.external_id}"
      task.mark_failed!('flux_failed')
      api.sendMessage(chat_id: task.chat_id, text: "Не удалось сгенерировать картинку") rescue nil
      :failed
    when Hash
      LOGGER.info "ImageGenTaskHandler[#{task.id}]: complete! #{result[:url]}"
      task.mark_done!(result)
      caption = "🎨 #{task.params_hash['request']}"
      send_photo(api, task.chat_id, result[:url], caption)
      :done
    end
  end

  def send_photo(api, chat_id, url, caption)
    caption = caption[0..1020] + "..." if caption.length > 1024
    retries = 0
    begin
      api.sendPhoto(chat_id: chat_id, photo: url, caption: caption)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "ImageGenTaskHandler sendPhoto retry #{retries}: #{e.class}"
      sleep 3 and retry if retries <= 3
    end
  end
end

TaskRunner.register('image_generate', ImageGenTaskHandler)

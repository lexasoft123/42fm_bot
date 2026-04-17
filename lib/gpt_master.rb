require 'httparty'

class GptMaster
  MAX_RETRIES = 3
  RETRY_DELAYS = [5, 10, 20].freeze
  CACHE_BREAK_MARKER = '{CACHE_BREAK}'.freeze

  # Default API URLs per api_type (used when provider has no explicit api_url)
  DEFAULT_URLS = {
    'anthropic' => 'https://api.anthropic.com/v1/messages',
    'openai'    => 'https://api.openai.com/v1/chat/completions',
  }.freeze

  def initialize(messages, setting: 'main', chat_id: nil, purpose: nil, system_prompt: nil)
    cfg      = self.class.resolve_setting(setting)
    @api_key  = cfg[:api_key]
    @api_url  = cfg[:api_url]
    @api_type = cfg[:api_type]
    @model    = cfg[:model]
    @max_tokens      = cfg[:max_tokens]
    @thinking_budget = cfg[:thinking_budget]
    @thinking        = cfg[:thinking]
    @output_config   = cfg[:output_config]
    @messages        = messages
    @chat_id         = chat_id
    @purpose         = purpose
    @system_prompt   = system_prompt
  end

  def call
    body = build_body
    LOGGER.debug("#{self.class.name}#call [#{@model}]: request #{@messages.map { |m| m[:content].to_s.length }.sum} chars")

    retries = 0
    loop do
      response = HTTParty.post(@api_url, body: body.to_json, headers: headers, timeout: 300)
      if response.code == 200
        record_usage(response)
        result = extract_content(response)
        LOGGER.debug("#{self.class.name}#call: reply #{result.to_s.length} chars")
        return result
      elsif response.code == 529 && retries < MAX_RETRIES
        retries += 1
        delay = RETRY_DELAYS[retries - 1]
        LOGGER.warn "#{self.class.name}#call: overloaded, retry #{retries}/#{MAX_RETRIES} in #{delay}s"
        sleep delay
      else
        LOGGER.error "#{self.class.name}#call: #{response.code} #{response.parsed_response&.dig('error', 'message') || response.body}"
        return 'жпт не жпт'
      end
    end
  end

  def call_raw(tools: [])
    body = build_body
    body[:tools] = attach_tool_cache_control(tools)
    LOGGER.debug("#{self.class.name}#call_raw [#{@model}]: #{tools.size} tools")

    retries = 0
    loop do
      response = HTTParty.post(@api_url, body: body.to_json, headers: headers, timeout: 300)
      if response.code == 200
        record_usage(response)
        LOGGER.debug("#{self.class.name}#call_raw: stop_reason=#{response['stop_reason'] || response.dig('choices', 0, 'finish_reason')}")
        return response.parsed_response
      elsif response.code == 529 && retries < MAX_RETRIES
        retries += 1
        delay = RETRY_DELAYS[retries - 1]
        LOGGER.warn "#{self.class.name}#call_raw: overloaded, retry #{retries}/#{MAX_RETRIES} in #{delay}s"
        sleep delay
      else
        LOGGER.error "#{self.class.name}#call_raw: #{response.code} #{response.parsed_response&.dig('error', 'message') || response.body}"
        return nil
      end
    end
  end

  class << self
    def chat(text, context: '', knowledge: '', setting: 'main', chat_id: nil, purpose: 'main_chat')
      content = Settings.chat_gpt['prompt']
        .gsub('{REQUEST}', text)
        .gsub('{CONTEXT}', context)
        .gsub('{KNOWLEDGE}', knowledge)
      system_prompt, user_content = split_cache_break(content)
      new([{ role: 'user', content: user_content }],
          setting: setting, chat_id: chat_id, purpose: purpose, system_prompt: system_prompt).call
    end

    def ask(text, prompt:, setting: 'main', chat_id: nil, purpose: 'ask')
      content = prompt.gsub('{REQUEST}', text)
      new([{ role: 'user', content: content }],
          setting: setting, chat_id: chat_id, purpose: purpose).call
    end

    # Split a rendered prompt on CACHE_BREAK_MARKER.
    # Returns [system_prompt, user_content]. If no marker, system_prompt is nil.
    def split_cache_break(content)
      return [nil, content] unless content.include?(CACHE_BREAK_MARKER)
      prefix, suffix = content.split(CACHE_BREAK_MARKER, 2)
      [prefix.strip, suffix.strip]
    end

    # Resolve a named setting into a flat config hash
    def resolve_setting(name)
      cfg = Settings.chat_gpt
      setting = cfg['settings'][name] || raise("Unknown chat_gpt setting: #{name}")
      provider_name = setting['provider']
      provider = cfg['providers'][provider_name] || raise("Unknown chat_gpt provider: #{provider_name}")

      {
        api_key:         provider['api_key'],
        api_type:        provider['api_type'] || provider_name,
        api_url:         provider['api_url'] || DEFAULT_URLS[provider['api_type'] || provider_name],
        model:           setting['model'],
        max_tokens:      setting['max_tokens'],
        thinking_budget: setting['thinking_budget'],
        thinking:        setting['thinking'],
        output_config:   setting['output_config'],
      }
    end
  end

  private

  def anthropic?
    @api_type == 'anthropic'
  end

  def headers
    if anthropic?
      {
        'Content-Type'      => 'application/json',
        'x-api-key'         => @api_key,
        'anthropic-version' => '2023-06-01',
      }
    else
      {
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer #{@api_key}",
      }
    end
  end

  def build_body
    if anthropic?
      body = {
        model:      @model,
        messages:   @messages,
        max_tokens: @max_tokens || 16000,
      }
      if @system_prompt && !@system_prompt.empty?
        body[:system] = [{ type: 'text', text: @system_prompt, cache_control: { type: 'ephemeral' } }]
      end
      # New-style: explicit `thinking:` hash from config (e.g. {type: 'adaptive'} for Opus 4.7).
      # Legacy: `thinking_budget:` maps to the enabled+budget_tokens shape.
      if @thinking
        body[:thinking] = symbolize(@thinking)
      elsif @thinking_budget
        body[:thinking] = { type: 'enabled', budget_tokens: @thinking_budget }
      end
      body[:output_config] = symbolize(@output_config) if @output_config
      body
    else
      messages = @messages
      if @system_prompt && !@system_prompt.empty?
        messages = [{ role: 'system', content: @system_prompt }] + @messages
      end
      {
        model:    @model,
        messages: messages,
      }
    end
  end

  def attach_tool_cache_control(tools)
    return tools unless anthropic? && tools.is_a?(Array) && !tools.empty?
    cached = tools.map { |t| t.is_a?(Hash) ? t.dup : t }
    last = cached.last
    cached[-1] = last.merge(cache_control: { type: 'ephemeral' }) if last.is_a?(Hash)
    cached
  end

  # YAML loads config hashes with string keys; Anthropic expects symbols via to_json either way,
  # but we normalize to symbols for consistency with the rest of the body hash.
  def symbolize(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = symbolize(v) }
    when Array then obj.map { |v| symbolize(v) }
    else obj
    end
  end

  def extract_content(response)
    if anthropic?
      text_block = response['content'].find { |b| b['type'] == 'text' }
      text_block&.dig('text')
    else
      response['choices'][0]['message']['content']
    end
  end

  def record_usage(response)
    usage = extract_usage(response)
    return unless usage
    cost = ApiUsage.compute_cost(@model, usage) rescue BigDecimal('0')
    LOGGER.info format(
      "%s usage [%s]: in=%d out=%d cache_r=%d cache_w=%d cost=$%.4f purpose=%s chat=%s",
      self.class.name, @model,
      usage[:input], usage[:output], usage[:cache_read], usage[:cache_write],
      (cost / 100.0).to_f, @purpose || '-', @chat_id || '-'
    )
    ApiUsage.record(model: @model, purpose: @purpose || 'unknown', usage: usage, chat_id: @chat_id)
  rescue => e
    LOGGER.warn "#{self.class.name}: telemetry failed: #{e.class}: #{e.message}"
  end

  def extract_usage(response)
    u = response['usage']
    return nil unless u.is_a?(Hash)
    if anthropic?
      {
        input:       u['input_tokens'].to_i,
        output:      u['output_tokens'].to_i,
        cache_read:  u['cache_read_input_tokens'].to_i,
        cache_write: u['cache_creation_input_tokens'].to_i,
      }
    else
      cached = u.dig('prompt_tokens_details', 'cached_tokens').to_i
      prompt = u['prompt_tokens'].to_i
      {
        input:       prompt - cached,
        output:      u['completion_tokens'].to_i,
        cache_read:  cached,
        cache_write: 0,
      }
    end
  end
end

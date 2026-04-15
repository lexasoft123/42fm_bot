require 'httparty'

class GptMaster
  MAX_RETRIES = 3
  RETRY_DELAYS = [5, 10, 20].freeze

  # Default API URLs per api_type (used when provider has no explicit api_url)
  DEFAULT_URLS = {
    'anthropic' => 'https://api.anthropic.com/v1/messages',
    'openai'    => 'https://api.openai.com/v1/chat/completions',
  }.freeze

  def initialize(messages, setting: 'main')
    cfg      = self.class.resolve_setting(setting)
    @api_key  = cfg[:api_key]
    @api_url  = cfg[:api_url]
    @api_type = cfg[:api_type]
    @model    = cfg[:model]
    @max_tokens      = cfg[:max_tokens]
    @thinking_budget = cfg[:thinking_budget]
    @messages = messages
  end

  def call
    body = build_body
    LOGGER.debug("GptMaster#call [#{@model}]: request #{@messages.map { |m| m[:content].to_s.length }.sum} chars")

    retries = 0
    loop do
      response = HTTParty.post(@api_url, body: body.to_json, headers: headers, timeout: 300)
      if response.code == 200
        result = extract_content(response)
        LOGGER.debug("GptMaster#call: reply #{result.to_s.length} chars")
        return result
      elsif response.code == 529 && retries < MAX_RETRIES
        retries += 1
        delay = RETRY_DELAYS[retries - 1]
        LOGGER.warn "GptMaster#call: overloaded, retry #{retries}/#{MAX_RETRIES} in #{delay}s"
        sleep delay
      else
        LOGGER.error "GptMaster#call: #{response.code} #{response.parsed_response&.dig('error', 'message') || response.body}"
        return 'жпт не жпт'
      end
    end
  end

  def call_raw(tools: [])
    body = build_body
    body[:tools] = tools
    LOGGER.debug("GptMaster#call_raw [#{@model}]: #{tools.size} tools")

    retries = 0
    loop do
      response = HTTParty.post(@api_url, body: body.to_json, headers: headers, timeout: 300)
      if response.code == 200
        LOGGER.debug("GptMaster#call_raw: stop_reason=#{response['stop_reason'] || response.dig('choices', 0, 'finish_reason')}")
        return response.parsed_response
      elsif response.code == 529 && retries < MAX_RETRIES
        retries += 1
        delay = RETRY_DELAYS[retries - 1]
        LOGGER.warn "GptMaster#call_raw: overloaded, retry #{retries}/#{MAX_RETRIES} in #{delay}s"
        sleep delay
      else
        LOGGER.error "GptMaster#call_raw: #{response.code} #{response.parsed_response&.dig('error', 'message') || response.body}"
        return nil
      end
    end
  end

  class << self
    def chat(text, context: '', knowledge: '', setting: 'main')
      content = Settings.chat_gpt['prompt']
        .gsub('{REQUEST}', text)
        .gsub('{CONTEXT}', context)
        .gsub('{KNOWLEDGE}', knowledge)
      new([{ role: 'user', content: content }], setting: setting).call
    end

    def ask(text, prompt:, setting: 'main')
      content = prompt.gsub('{REQUEST}', text)
      new([{ role: 'user', content: content }], setting: setting).call
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
      if @thinking_budget
        body[:thinking] = { type: 'enabled', budget_tokens: @thinking_budget }
      end
      body
    else
      {
        model:    @model,
        messages: @messages,
      }
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
end

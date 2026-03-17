require 'httparty'

class GptMaster
  def initialize(messages, model: Settings.chat_gpt['default_model'])
    @api_key  = Settings.chat_gpt['api_key']
    @api_url  = Settings.chat_gpt['api_url']
    @model    = model
    @messages = messages
  end

  def call
    body = build_body
    LOGGER.debug("GptMaster request: model=#{@model} content_length=#{@messages.sum { |m| m[:content].size }}")
    response = HTTParty.post(
      @api_url,
      body:    body.to_json,
      headers: headers,
      timeout: 300,
    )
    if response.code == 200
      extract_content(response)
    else
      LOGGER.error "GptMaster bad response: #{response.inspect}"
      'жпт не жпт'
    end
  end

  class << self
    def chat(text, context: '', knowledge: '', model: Settings.chat_gpt['default_model'])
      content = Settings.chat_gpt['prompt']
        .gsub('{REQUEST}', text)
        .gsub('{CONTEXT}', context)
        .gsub('{KNOWLEDGE}', knowledge)
      new([{ role: 'user', content: content }], model: model).call
    end

    def ask(text, prompt:, model: Settings.chat_gpt['default_model'])
      content = prompt.gsub('{REQUEST}', text)
      new([{ role: 'user', content: content }], model: model).call
    end
  end

  private

  def anthropic?
    Settings.chat_gpt['provider'] == 'anthropic'
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
    cfg = Settings.chat_gpt
    if anthropic?
      body = {
        model:      @model,
        messages:   @messages,
        max_tokens: cfg['max_tokens'] || 16000,
      }
      if cfg['thinking_budget']
        body[:thinking] = { type: 'enabled', budget_tokens: cfg['thinking_budget'] }
      end
      body
    else
      {
        model:    @model,
        messages: @messages,
        thinking: { type: 'enabled' },
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

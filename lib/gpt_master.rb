require 'httparty'

class GptMaster
  def initialize(messages, model: Settings.chat_gpt['default_model'])
    @api_key = Settings.chat_gpt['api_key']
    @api_url = Settings.chat_gpt['api_url']
    @model   = model
    @messages = messages
  end

  def call
    body = {
      model:    @model,
      messages: @messages,
      thinking: { type: 'enabled' },
    }
    LOGGER.debug("GptMaster request: model=#{@model} messages=#{@messages.inspect}")
    response = HTTParty.post(
      @api_url,
      body:    body.to_json,
      headers: headers,
      timeout: 300,
    )
    if response.code == 200
      response['choices'][0]['message']['content']
    else
      LOGGER.error "GptMaster bad response: #{response.inspect}"
      'жпт не жпт'
    end
  end

  class << self
    # Chat reply using the shared settings prompt; includes chat context
    def chat(text, context: '', model: Settings.chat_gpt['default_model'])
      content = Settings.chat_gpt['prompt']
        .gsub('{REQUEST}', text)
        .gsub('{CONTEXT}', context)
      new([{ role: 'user', content: content }], model: model).call
    end

    # One-off question with a caller-supplied prompt template ({REQUEST} placeholder)
    def ask(text, prompt:, model: Settings.chat_gpt['default_model'])
      content = prompt.gsub('{REQUEST}', text)
      new([{ role: 'user', content: content }], model: model).call
    end
  end

  private

  def headers
    {
      'Content-Type'  => 'application/json',
      'Authorization' => "Bearer #{@api_key}",
    }
  end
end

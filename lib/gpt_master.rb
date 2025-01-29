require 'httparty'

class GptMaster
    def initialize message, context: '', model: Settings.chat_gpt['default_model']
        @api_key = Settings.chat_gpt["api_key"]
        @prompt = Settings.chat_gpt["prompt"]
        @options = {
            headers: {
                'Content-Type' => 'application/json',
                'Authorization' => "Bearer #{@api_key}"
            }
        }
        #@api_url = 'https://api.openai.com/v1/chat/completions'
	@api_url = Settings.chat_gpt['api_url']
        @model = model
        @message = @prompt.gsub('{REQUEST}', message).gsub('{CONTEXT}', context)
        @logger = Logger.new(STDOUT, Logger::DEBUG)
    end

    def call
        body = {
            model: @model,
            messages: [{ role: 'user', content: @message }],
	    options: [{ num_ctx: 8192}]
        }
        @logger.debug("Sending request to GPT with body: #{body.to_json}")
        response = HTTParty.post(@api_url,
                body: body.to_json,
                headers: @options[:headers],
                timeout: 200,
                http_proxyaddr: Settings.chat_gpt['http_proxyaddr'],
                http_proxyport: Settings.chat_gpt['http_proxyport'],
                http_proxyuser: Settings.chat_gpt['http_proxyuser'],
                http_proxypass: Settings.chat_gpt['http_proxypass']
            )

        if response.code == 200
            return response['choices'][0]['message']['content']
        else
            @logger.error "bad response from gpt: #{response.inspect}"
            return "жпт не жпт"
        end
    end

    class << self
        def call(message, context: '', model: Settings.chat_gpt['default_model'])
            new(message, context: context, model: model).call
        end
    end
end

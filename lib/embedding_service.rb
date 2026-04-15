require 'httparty'

class EmbeddingService
  def self.embed(text)
    cfg = GptMaster.resolve_setting('embedder')
    base = cfg[:api_url].sub(%r{/v\d+/.*$}, '')
    api_url = "#{base}/v1/embeddings"

    headers = if cfg[:api_type] == 'anthropic'
      {
        'Content-Type'      => 'application/json',
        'x-api-key'         => cfg[:api_key],
        'anthropic-version' => '2023-06-01',
      }
    else
      {
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer #{cfg[:api_key]}",
      }
    end

    response = HTTParty.post(
      api_url,
      body:    { model: cfg[:model], input: text }.to_json,
      headers: headers,
      timeout: 30,
    )
    if response.code == 200
      response['data'][0]['embedding']
    else
      LOGGER.error "#{name}.embed [#{cfg[:model]}]: #{response.code} #{response.body}"
      nil
    end
  rescue => e
    LOGGER.error "#{name}.embed [#{cfg[:model] rescue '?'}]: #{e.message}"
    nil
  end
end

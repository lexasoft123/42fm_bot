require 'httparty'

class EmbeddingService
  def self.embed(text)
    cfg     = Settings.embeddings
    api_key = cfg['api_key']
    api_url = cfg['api_url']
    model   = cfg['model'] || 'text-embedding-3-small'

    headers = {
      'Content-Type'  => 'application/json',
      'Authorization' => "Bearer #{api_key}",
    }

    response = HTTParty.post(
      api_url,
      body:    { model: model, input: text }.to_json,
      headers: headers,
      timeout: 30,
    )
    if response.code == 200
      response['data'][0]['embedding']
    else
      LOGGER.error "EmbeddingService error: #{response.code} #{response.body}"
      nil
    end
  rescue => e
    LOGGER.error "EmbeddingService exception: #{e.message}"
    nil
  end
end

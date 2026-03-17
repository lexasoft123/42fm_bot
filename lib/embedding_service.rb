require 'httparty'

class EmbeddingService
  def self.embed(text)
    cfg = Settings.embeddings
    response = HTTParty.post(
      cfg['api_url'],
      body:    { model: cfg['model'], input: text }.to_json,
      headers: {
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer #{cfg['api_key']}",
      },
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

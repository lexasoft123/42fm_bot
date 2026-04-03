require 'nokogiri'
require 'rest-client'

Agent::ToolRegistry.register(
  name: 'fetch_page',
  description: 'Загружает страницу по URL и возвращает её текстовое содержимое. Используй для чтения конкретной страницы из результатов google_search.',
  parameters: {
    'url' => { type: 'string', description: 'URL страницы для загрузки' }
  },
  handler: ->(args, ctx) {
    begin
      response = RestClient.get(args['url'], {
        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        max_redirects: 5
      })
      doc = Nokogiri::HTML(response.body)
      doc.search('script, style, nav, header, footer, aside, [class*="cookie"], [class*="banner"]').remove
      text = doc.text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
      text[0..1900]
    rescue => e
      "Не удалось загрузить страницу: #{e.message}"
    end
  }
)

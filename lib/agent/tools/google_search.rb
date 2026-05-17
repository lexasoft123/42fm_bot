module Agent; module Tools; end; end
module Agent::Tools::GoogleSearch
  def self.format_text_results(results)
    results.each_with_index.map { |r, i|
      snippet = r[:snippet].to_s.gsub(/\s+/, ' ').strip
      [
        "#{i + 1}. #{r[:title]}",
        snippet.empty? ? nil : "   #{snippet}",
        "   #{r[:link]}"
      ].compact.join("\n")
    }.join("\n\n")
  end

  def self.send_media(downloads, kind:, ctx:)
    return 'Не удалось скачать ни одной картинки' if downloads.empty?

    api = ctx[:bot].api
    if kind == :gif
      downloads.each { |d| api.sendAnimation(chat_id: ctx[:chat_id], animation: Faraday::UploadIO.new(d[:tmp].path, d[:mime])) }
      "Отправил #{downloads.size} гифок в чат"
    else
      named  = downloads.each_with_index.map { |d, i| d.merge(name: "photo#{i}") }
      params = { chat_id: ctx[:chat_id],
                 media: named.map { |d| { type: 'photo', media: "attach://#{d[:name]}" } }.to_json }
      named.each { |d| params[d[:name].to_sym] = Faraday::UploadIO.new(d[:tmp].path, d[:mime]) }
      api.sendMediaGroup(**params)
      "Отправил #{downloads.size} картинок в чат"
    end
  rescue => e
    level = e.message.include?('IMAGE_PROCESS_FAILED') ? :warn : :error
    LOGGER.public_send(level, "[chat=#{ctx[:chat_id]}] google_search send failed: #{e.message}")
    downloads.map { |d| d[:link] }.join("\n")
  ensure
    downloads.each { |d| d[:tmp].close; d[:tmp].unlink rescue nil }
  end
end

Agent::ToolRegistry.register(
  name: 'google_search',
  description: 'Ищет в Google. Для текстовых запросов возвращает несколько результатов с заголовком, сниппетом и ссылкой. Для изображений — находит и отправляет их прямо в чат. Используй, когда нужно найти существующие изображения/мемы/фото — в отличие от generate_image, который создаёт новые картинки через ИИ.',
  parameters: {
    'query'      => { type: 'string', description: 'Поисковый запрос (без слов "найди", "картинка" — пиши только суть)' },
    'media_type' => { type: 'string', enum: %w[text photo gif],
                      description: 'text: текстовые результаты со ссылками. photo: найти и отправить картинки/мемы/фото в чат. gif: найти и отправить гифки/анимации в чат.' }
  },
  handler: ->(args, ctx) {
    query      = args['query']
    media_type = args['media_type']

    case media_type
    when 'text'
      results = Gogolmogol.new(query, media_type: 'text').search_results(limit: 3)
      next 'Ничего не найдено' if results.empty?
      Agent::Tools::GoogleSearch.format_text_results(results)
    when 'photo'
      downloads = Gogolmogol.new(query, media_type: 'photo').download_results(limit: 4)
      Agent::Tools::GoogleSearch.send_media(downloads, kind: :photo, ctx: ctx)
    when 'gif'
      downloads = Gogolmogol.new(query, media_type: 'gif').download_results(limit: 4)
      Agent::Tools::GoogleSearch.send_media(downloads, kind: :gif, ctx: ctx)
    else
      "Ошибка: неизвестный media_type=#{media_type.inspect}, допустимы text|photo|gif"
    end
  }
)

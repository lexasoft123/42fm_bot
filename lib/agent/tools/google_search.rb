require 'tempfile'

Agent::ToolRegistry.register(
  name: 'google_search',
  description: 'Ищет в Google. Для текстовых запросов возвращает несколько результатов с заголовком, сниппетом и ссылкой. Для запросов с картинками/фото/мемами/гифками — находит изображения и отправляет их прямо в чат. Используй, когда нужно найти существующие изображения, мемы, фото — в отличие от generate_image, который создаёт новые картинки через ИИ. Для получения полного содержимого страницы используй fetch_page.',
  parameters: {
    'query' => { type: 'string', description: 'Поисковый запрос' }
  },
  handler: ->(args, ctx) {
    query = args['query']
    image_search = query =~ /фото|картинк|мем|gif|гиф/i

    results = Gogolmogol.new(query).search_results(limit: image_search ? 4 : 3)
    next "Ничего не найдено" if results.empty?

    if image_search
      api = ctx[:bot].api
      gif_search = query =~ /gif|гиф/i
      media_type = gif_search ? 'document' : 'photo'
      temp_files = []
      media = []

      results.each_with_index do |r, i|
        begin
          data = RestClient::Request.execute(
            method: :get, url: r[:link],
            headers: { 'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' },
            timeout: 10, max_redirects: 3
          )
          content_type = data.headers[:content_type]&.split(';')&.first || 'image/jpeg'
          ext = { 'image/gif' => 'gif', 'image/png' => 'png', 'image/webp' => 'webp' }.fetch(content_type, 'jpg')
          tmp = Tempfile.new(["gsearch_#{i}", ".#{ext}"])
          tmp.binmode
          tmp.write(data.body)
          tmp.flush
          attach_name = "photo#{i}"
          media << { type: media_type, media: "attach://#{attach_name}" }
          temp_files << { file: tmp, name: attach_name, mime: content_type }
        rescue => e
          LOGGER.warn "[chat=#{ctx[:chat_id]}] google_search: skipping #{r[:link]}: #{e.message}"
        end
      end

      if temp_files.empty?
        next results.map { |r| r[:link] }.join("\n")
      end

      begin
        if gif_search
          temp_files.each do |tf|
            api.sendAnimation(chat_id: ctx[:chat_id], animation: Faraday::UploadIO.new(tf[:file].path, tf[:mime]))
          end
          "Отправил #{temp_files.size} гифок в чат"
        else
          params = { chat_id: ctx[:chat_id], media: media.to_json }
          temp_files.each { |tf| params[tf[:name].to_sym] = Faraday::UploadIO.new(tf[:file].path, tf[:mime]) }
          api.sendMediaGroup(**params)
          "Отправил #{media.size} картинок в чат"
        end
      rescue => e
        LOGGER.error "[chat=#{ctx[:chat_id]}] google_search send failed: #{e.message}"
        results.map { |r| r[:link] }.join("\n")
      ensure
        temp_files.each { |tf| tf[:file].close; tf[:file].unlink rescue nil }
      end
    else
      results.each_with_index.map { |r, i|
        lines = ["#{i + 1}. #{r[:title]}"]
        snippet = r[:snippet].to_s.gsub(/\s+/, ' ').strip
        lines << "   #{snippet}" unless snippet.empty?
        lines << "   #{r[:link]}"
        lines.join("\n")
      }.join("\n\n")
    end
  }
)

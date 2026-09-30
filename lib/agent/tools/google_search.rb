require_relative '../error_reporter'

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
    return delivery_result(status: 'failed', kind: kind, requested: 0, accepted: 0, persisted: 0,
                           rejected: 0, ambiguous: 0,
                           detail: 'Не удалось скачать ни одного медиафайла') if downloads.empty?

    api = ctx[:api]
    if kind == :gif
      send_animations(downloads, api: api, ctx: ctx)
    else
      send_photo_group(downloads, api: api, ctx: ctx)
    end
  ensure
    cleanup_downloads(downloads)
  end

  def self.send_photo_group(downloads, api:, ctx:)
    named  = downloads.each_with_index.map { |d, i| d.merge(name: "photo#{i}") }
    params = { chat_id: ctx[:chat_id],
               media: named.map { |d| { type: 'photo', media: "attach://#{d[:name]}" } }.to_json }
    params[:message_thread_id] = ctx[:forum_thread_id] if ctx[:forum_thread_id]
    named.each { |d| params[d[:name].to_sym] = Faraday::UploadIO.new(d[:tmp].path, d[:mime]) }

    response = api.sendMediaGroup(**params)
    entries = media_group_entries(response, expected_count: downloads.size)
    if entries.empty?
      return delivery_result(
        status: 'sent_untracked', kind: :photo, requested: downloads.size,
        accepted: 0, persisted: 0, rejected: 0, ambiguous: downloads.size,
        detail: 'Telegram вернул неоднозначное подтверждение группы; доставка неизвестна, не отправляй медиа повторно'
      )
    end
    persisted = entries.count do |index, message|
      persist_media_reply(chat_id: ctx[:chat_id], body: "[Google фото: #{downloads[index][:link]}]",
                          response: message, message_thread_id: ctx[:forum_thread_id])
    end
    accepted = entries.size
    status = delivery_status(requested: downloads.size, accepted: accepted, persisted: persisted)
    delivery_result(status: status, kind: :photo, requested: downloads.size, accepted: accepted,
                    persisted: persisted, rejected: 0, ambiguous: 0)
  rescue => e
    log_send_failure(e, ctx)
    if definite_telegram_rejection?(e)
      delivery_result(status: 'failed', kind: :photo, requested: downloads.size,
                      accepted: 0, persisted: 0,
                      rejected: downloads.size, ambiguous: 0,
                      detail: delivery_error_detail(e), links: downloads.map { |d| d[:link] })
    else
      delivery_result(
        status: 'sent_untracked', kind: :photo, requested: downloads.size,
        accepted: 0, persisted: 0, rejected: 0, ambiguous: downloads.size,
        detail: "Неоднозначная ошибка транспорта после отправки запроса: #{delivery_error_detail(e)}; " \
                'доставка неизвестна, не отправляй медиа повторно автоматически'
      )
    end
  end

  def self.send_animations(downloads, api:, ctx:)
    accepted = 0
    persisted = 0
    rejected = 0
    ambiguous = 0
    failed_links = []
    errors = []

    downloads.each do |download|
      params = { chat_id: ctx[:chat_id],
                 animation: Faraday::UploadIO.new(download[:tmp].path, download[:mime]) }
      params[:message_thread_id] = ctx[:forum_thread_id] if ctx[:forum_thread_id]
      begin
        response = api.sendAnimation(**params)
        if telegram_message?(response)
          accepted += 1
          persisted += 1 if persist_media_reply(chat_id: ctx[:chat_id],
                                                 body: "[Google GIF: #{download[:link]}]",
                                                 response: response,
                                                 message_thread_id: ctx[:forum_thread_id])
        else
          ambiguous += 1
          errors << 'Telegram вернул неоднозначное подтверждение GIF; не отправляй его повторно автоматически'
        end
      rescue => e
        log_send_failure(e, ctx)
        if definite_telegram_rejection?(e)
          rejected += 1
          failed_links << download[:link]
          errors << delivery_error_detail(e)
        else
          ambiguous += 1
          errors << "Неоднозначная ошибка транспорта GIF: #{delivery_error_detail(e)}; " \
                    'доставка неизвестна, не отправляй его повторно автоматически'
        end
      end
    end

    status = delivery_status(requested: downloads.size, accepted: accepted, persisted: persisted,
                             ambiguous: ambiguous)
    delivery_result(status: status, kind: :gif, requested: downloads.size, accepted: accepted,
                    persisted: persisted, rejected: rejected, ambiguous: ambiguous,
                    detail: errors.uniq.join('; '), links: failed_links)
  end

  # Telegram documents sendMediaGroup as an all-at-once operation. Treat its
  # acknowledgement as authoritative only when it contains exactly one valid,
  # distinct positive Integer message id per requested item. A short, sparse,
  # malformed, or duplicate response is ambiguous: persisting a subset or
  # exposing the remaining URLs as retryable could duplicate media that
  # Telegram actually accepted.
  def self.media_group_entries(response, expected_count:)
    result = if response.is_a?(Hash)
               response['result'] || response[:result]
             else
               response
             end
    messages = Array(result)
    return [] unless messages.size == expected_count

    ids = messages.map { |message| telegram_message_id(message) }
    return [] if ids.any?(&:nil?) || ids.uniq.size != expected_count

    messages.each_with_index.map { |message, index| [index, message] }
  end

  def self.telegram_message?(response)
    !telegram_message_id(response).nil?
  end

  def self.telegram_message_id(response)
    return nil unless response
    return positive_message_id(response.message_id) if response.respond_to?(:message_id)
    return nil unless response.is_a?(Hash)
    direct = response['message_id'] || response[:message_id]
    return positive_message_id(direct) unless direct.nil?

    nested = response['result'] || response[:result]
    return positive_message_id(nested.message_id) if nested.respond_to?(:message_id)
    return nil unless nested.is_a?(Hash)
    positive_message_id(nested['message_id'] || nested[:message_id])
  end

  def self.positive_message_id(value)
    value if value.is_a?(Integer) && value.positive?
  end

  # persist_bot_reply deliberately absorbs DB errors and returns nil. Reconcile
  # once by message id, then retry the DB write at most once. Telegram already
  # accepted the media, so this helper must never resend it.
  def self.persist_media_reply(chat_id:, body:, response:, message_thread_id: nil)
    persist_args = { chat_id: chat_id, body: body, response: response,
                     message_thread_id: message_thread_id }
    record = Message.persist_bot_reply(**persist_args)
    return true if record

    message_id = telegram_message_id(response)
    return false unless message_id
    return true if persisted_message?(chat_id, message_id)

    record = Message.persist_bot_reply(**persist_args)
    !!record || persisted_message?(chat_id, message_id)
  rescue => e
    safe = Agent::ErrorReporter.sanitize(e.message)
    LOGGER.warn "[chat=#{chat_id}] google_search persistence reconciliation failed: #{e.class}: #{safe}"
    false
  end

  def self.persisted_message?(chat_id, message_id)
    Message.where(chat_id: chat_id, role: 'bot', message_id: message_id).exists?
  end

  def self.delivery_status(requested:, accepted:, persisted:, ambiguous: 0)
    return 'sent_untracked' if ambiguous.positive?
    return 'failed' if accepted.zero?
    return 'sent_untracked' if persisted < accepted
    accepted == requested ? 'sent' : 'partial'
  end

  def self.delivery_result(status:, kind:, requested:, accepted:, persisted:, rejected: 0, ambiguous: 0,
                           detail: nil, links: [])
    label = kind == :gif ? 'GIF' : 'фото'
    summary = case status
              when 'sent' then "Доставлено и сохранено #{accepted} #{label}"
              when 'sent_untracked'
                if accepted.zero?
                  "Подтверждение Telegram неоднозначно для #{ambiguous} из #{requested} #{label}; доставка неизвестна, не отправляй их повторно"
                else
                  "Telegram подтвердил #{accepted}, локально сохранено #{persisted}, " \
                  "неоднозначно #{ambiguous}, отклонено #{rejected} из #{requested} #{label}; " \
                  'не отправляй их повторно, если они подтверждены или неоднозначны'
                end
              when 'partial' then "Частичная доставка: Telegram принял #{accepted} из #{requested} #{label}"
              else "Медиа НЕ ОТПРАВЛЕНО (0 из #{requested} #{label})"
              end
    parts = ["[media_delivery status=#{status} kind=#{kind} sent_count=#{accepted} accepted_count=#{accepted} " \
             "persisted_count=#{persisted} rejected_count=#{rejected} ambiguous_count=#{ambiguous} " \
             "requested_count=#{requested}]",
             summary]
    parts << detail unless detail.to_s.empty?
    unless links.empty?
      parts << 'Резервные URL (это ссылки на медиа, которые НЕ были отправлены в чат):'
      parts.concat(links)
    end
    parts.join("\n")
  end

  def self.cleanup_downloads(downloads)
    Array(downloads).each do |download|
      tmp = download[:tmp]
      begin
        tmp.close
      rescue => e
        LOGGER.warn "google_search tempfile close failed: #{e.class}: #{Agent::ErrorReporter.sanitize(e.message)}"
      end
      begin
        tmp.unlink
      rescue => e
        LOGGER.warn "google_search tempfile unlink failed: #{e.class}: #{Agent::ErrorReporter.sanitize(e.message)}"
      end
    end
  end

  def self.delivery_error_detail(error)
    if error.message.include?('IMAGE_PROCESS_FAILED')
      'Telegram отклонил медиа с ошибкой IMAGE_PROCESS_FAILED; оно не было отправлено'
    else
      "Ошибка доставки в Telegram: #{Agent::ErrorReporter.sanitize(error.message)}"
    end
  end

  # A media-group transport exception can happen after Telegram accepted the
  # request, so unknown/timeout/reset/EOF failures are ambiguous by default.
  # Only an explicit Telegram client rejection is safe to call not-delivered
  # and to accompany with retryable source URLs.
  def self.definite_telegram_rejection?(error)
    message = error.message.to_s
    return true if message.match?(/IMAGE_PROCESS_FAILED|\bBad Request\b/i)
    return false unless error.respond_to?(:error_code)

    code = error.error_code.to_i
    code.between?(400, 499) && ![408, 409, 425, 429].include?(code)
  end

  def self.log_send_failure(error, ctx)
    level = error.message.include?('IMAGE_PROCESS_FAILED') ? :warn : :error
    safe = Agent::ErrorReporter.sanitize(error.message)
    LOGGER.public_send(level, "[chat=#{ctx[:chat_id]}] google_search send failed: #{safe}")
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

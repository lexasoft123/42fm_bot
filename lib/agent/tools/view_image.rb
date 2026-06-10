require_relative '../../telegram_file'

# Fetch a photo from an earlier chat message so the agent can actually SEE
# it. Context rows with an attached photo carry `photo: true`; the agent
# passes that row's `id` here. The handler resolves the stored file_id
# (DB-internal, never surfaced to the LLM), downloads the image and returns
# Agent::ToolResult.image — Agent::Runner injects it into the conversation
# as a vision block and upgrades the turn to the agent_vision setting.
#
# Photos are persisted (messages.attachment_photo_file_id) only since this
# feature shipped — older messages have no stored file_id and the tool says
# so instead of failing.
Agent::ToolRegistry.register(
  name: 'view_image',
  description: 'Загружает картинку из сообщения в истории чата, чтобы ты мог её увидеть и проанализировать. Передай message_id сообщения с photo: true (поле id в контексте). Картинка из ТЕКУЩЕГО сообщения уже видна тебе напрямую — view_image нужен только для более старых сообщений.',
  parameters: {
    'message_id' => { type: 'integer', description: 'Telegram message_id сообщения с photo: true из контекста' },
  },
  handler: ->(args, ctx) {
    next 'Просмотр картинок недоступен в текущей конфигурации модели — ответь по текстовому описанию из контекста.' unless ctx[:can_view_image]
    next 'Ошибка: нет доступа к Telegram API' unless ctx[:api]

    mid = args['message_id'].to_i
    file_id = Message.where(chat_id: ctx[:chat_id], message_id: mid)
                     .pick(:attachment_photo_file_id)
    next "В сообщении #{mid} нет сохранённой картинки (либо сообщение не найдено, либо оно отправлено до того, как бот начал сохранять фото)." unless file_id

    img = TelegramFile.download_image(ctx[:api], file_id, chat_id: ctx[:chat_id])
    next "Не смог скачать картинку из сообщения #{mid} — попробуй позже." unless img

    Agent::ToolResult.image(
      user_text: "Картинка из сообщения #{mid} загружена — она придёт следующим сообщением, рассмотри её и используй для ответа.",
      image: img
    )
  }
)

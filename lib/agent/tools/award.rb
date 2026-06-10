# Auto-awards: a thin layer over the image_generate pipeline. The award
# style is composed handler-side (no optional `kind` param — the registry
# force-requires every declared param); the LLM enrichment step downstream
# turns the request into a full image prompt with chat context.
Agent::ToolRegistry.register(
  name: 'make_award',
  description: 'Рисует шуточную награду (медаль/диплом/грамоту) для участника чата и отправляет картинкой. Используй когда просят «награди X за Y», «вручи медаль», «дай орден», или по результатам суда (challenge_rule сам подскажет когда). Награда должна быть ехидной, в духе чата.',
  parameters: {
    'recipient' => { type: 'string', description: 'Кому награда (имя/username участника)' },
    'reason'    => { type: 'string', description: 'За что награда, дословно в духе запроса (можно ехидно переформулировать)' },
  },
  handler: ->(args, ctx) {
    role = ctx[:user]&.role
    if RateLimiter.exceeded?(ctx[:chat_id], 'image', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'image', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'image', role: role),
        intent:       "вручить через #{mins} мин награду для #{args['recipient']} за #{args['reason']}",
        retry_in_min: mins
      )
    end
    request = "Шуточная торжественная награда: богато украшенная медаль или " \
              "диплом с гравировкой «#{args['recipient']} — за #{args['reason']}». " \
              "Пафосная церемониальная стилистика, золото, ленты, герб чата 42FM."
    BackgroundTask.create!(
      task_type: 'image_generate',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: { request: request, user_uid: ctx[:user]&.uid,
                award: true, recipient: args['recipient'] }.to_json
    )
    "Награда для #{args['recipient']} поставлена в очередь и скоро приедет в чат картинкой 🏆"
  }
)

# Rules-war game tools. The store lives in the scratchpad's `rules`
# category (Agent::Scratchpad rules API) and renders into {SCRATCHPAD}
# every turn, so the agent sees and honours active rules with no extra
# plumbing. Schemas declare only mandatory params (the registry force-
# requires every declared param); optional ones default handler-side.

module Agent
  module RulesTools
    module_function

    def author_display(user)
      return 'кто-то' unless user
      name = user.name.to_s.strip
      name.empty? ? (user.first_name.to_s.strip.empty? ? "uid#{user.uid}" : user.first_name) : "@#{name}"
    end

    # Roll the public Telegram dice. Returns [value, public] where public
    # is false when sendDice failed and we fell back to internal rand.
    # NO sleep here: the handler runs synchronously inside bot.listen's
    # single-threaded loop (a delay would freeze the whole bot) and, on
    # the TaskRunner path, inside with_connection with 2 workers.
    def roll_dice(ctx)
      msg = ctx[:api].send_dice(chat_id: ctx[:chat_id])
      value = msg.respond_to?(:dice) ? msg.dice&.value : nil
      value ? [value, true] : [rand(1..6), false]
    rescue => e
      LOGGER.warn "[chat=#{ctx[:chat_id]}] roll_dice fallback: #{e.class}: #{e.message}" if defined?(LOGGER)
      [rand(1..6), false]
    end
  end
end

Agent::ToolRegistry.register(
  name: 'set_rule',
  description: 'Игра «правила чата»: устанавливает правило от имени текущего пользователя. Правило попадает в устав чата, ты ОБЯЗАН его соблюдать до истечения срока. У каждого гражданина может быть только ОДНО активное правило — новое автоматически отзывает старое (объяви это в чате). Используй когда пользователь говорит «поставь правило», «новое правило», «пусть теперь все …».',
  parameters: {
    'content' => { type: 'string', description: 'Текст правила, кратко (до 200 символов). Опционально в args: target (на кого действует, по умолчанию все), hours (срок в часах, по умолчанию 24).' },
  },
  handler: ->(args, ctx) {
    user = ctx[:user]
    next 'Не вижу автора правила' unless user
    res = Agent::Scratchpad.add_rule(
      ctx[:chat_id],
      content:     args['content'].to_s,
      set_by:      user.uid,
      set_by_name: Agent::RulesTools.author_display(user),
      target:      args['target'],
      hours:       (args['hours'] || 24).to_f
    )
    out = "Правило [#{res[:rule]['id']}] принято: #{res[:rule]['content']} (автор #{res[:rule]['set_by_name']}, истекает через #{(args['hours'] || 24).to_i}ч)."
    out += " Прежнее правило автора [#{res[:repealed]['id']}] «#{res[:repealed]['content']}» автоматически отозвано — объяви этот размен публично." if res[:repealed]
    out += " Устав переполнен: старейшее правило [#{res[:evicted]['id']}] выпало из него." if res[:evicted]
    out
  }
)

Agent::ToolRegistry.register(
  name: 'repeal_rule',
  description: 'Отменяет правило по id (r-NNN). Разрешено только автору правила или админу; судебные правила отменяет только админ. Остальным предложи апелляцию: challenge_rule (бросок кости).',
  parameters: { 'id' => { type: 'string', description: 'ID правила, например "r-003"' } },
  handler: ->(args, ctx) {
    rule = Agent::Scratchpad.find_rule(ctx[:chat_id], args['id'].to_s)
    next "Правило #{args['id']} не найдено в уставе" unless rule
    user  = ctx[:user]
    admin = user&.role == 'admin'
    allowed = admin || (!rule['court'] && user && rule['set_by'] == user.uid)
    unless allowed
      next "Отменить может только автор (#{rule['set_by_name'] || 'суд'}) или админ. Предложи апелляцию: «бот оспорь #{rule['id']}» — суд бросит кость."
    end
    removed = Agent::Scratchpad.repeal_rule_entry(ctx[:chat_id], rule['id'])
    removed ? "Правило [#{removed['id']}] «#{removed['content']}» отменено." : "Правило #{args['id']} не найдено"
  }
)

Agent::ToolRegistry.register(
  name: 'challenge_rule',
  description: 'Апелляция против правила: публичный суд с броском НАСТОЯЩЕЙ кости 🎲 в чат. 4–6 — правило отменено; 2–3 — правило выстояло и продлено на 6ч («за неуважение к суду»); 1 — критический провал: правило продлено И суд вводит встречное правило против заявителя (тебе скажут вызвать court_rule). Используй когда пользователь говорит «оспорь», «обжалуй», «апелляция». Результат озвучь театрально: суд, приговор, апелляция отклонена.',
  parameters: { 'id' => { type: 'string', description: 'ID оспариваемого правила, например "r-003"' } },
  handler: ->(args, ctx) {
    rule = Agent::Scratchpad.find_rule(ctx[:chat_id], args['id'].to_s)
    next "Правило #{args['id']} не найдено в уставе — оспаривать нечего" unless rule
    unless Agent::Scratchpad.register_challenge(ctx[:chat_id])
      next 'Суд перегружен (лимит 6 заседаний в час) — приходите через час.'
    end
    value, public_roll = Agent::RulesTools.roll_dice(ctx)
    roll_note = public_roll ? "Кость уже брошена в чат, выпало #{value}." :
                              "Кость сломалась, суд бросил монетку в уме: выпало #{value} (упомяни этот сбой)."
    challenger = Agent::RulesTools.author_display(ctx[:user])
    case value
    when 4..6
      removed = Agent::Scratchpad.repeal_rule_entry(ctx[:chat_id], rule['id'])
      "#{roll_note} АПЕЛЛЯЦИЯ УДОВЛЕТВОРЕНА: правило [#{removed&.dig('id') || rule['id']}] «#{rule['content']}» отменено судом."
    when 2..3
      updated = Agent::Scratchpad.extend_and_survive(ctx[:chat_id], rule['id'])
      "#{roll_note} Апелляция отклонена: правило [#{rule['id']}] выстояло (всего выстояло апелляций: #{updated&.dig('challenges_survived')}), срок продлён на 6ч за неуважение к суду." +
        (updated&.dig('challenges_survived').to_i >= 3 ? " Правило выстояло 3+ апелляции — его автор #{rule['set_by_name']} заслужил диплом «Конституционный статус», вручи через make_award." : '')
    else
      updated = Agent::Scratchpad.extend_and_survive(ctx[:chat_id], rule['id'])
      "#{roll_note} КРИТИЧЕСКИЙ ПРОВАЛ (1): правило [#{rule['id']}] выстояло (всего: #{updated&.dig('challenges_survived')}), срок продлён на 6ч. Суд постановил ввести встречное правило против заявителя #{challenger}: сочини его сам (ехидное, по ситуации) и вызови court_rule с target=#{challenger}. Можешь также вручить заявителю «Медаль за провал апелляции» через make_award."
    end
  }
)

Agent::ToolRegistry.register(
  name: 'court_rule',
  description: 'Вводит СУДЕБНОЕ правило от имени суда (автор «суд», не пользователь). Используй ТОЛЬКО сразу после критического провала апелляции (challenge_rule выпало 1), против заявителя. Не занимает слот гражданина; в чате может быть только одно судебное правило — новое заменяет старое. Срок 12ч.',
  parameters: {
    'content' => { type: 'string', description: 'Текст судебного правила (ехидный, по ситуации, до 200 символов)' },
    'target'  => { type: 'string', description: 'Против кого (имя/username заявителя)' },
  },
  handler: ->(args, ctx) {
    res = Agent::Scratchpad.add_rule(
      ctx[:chat_id],
      content:     args['content'].to_s,
      set_by:      0,
      set_by_name: 'суд',
      target:      args['target'],
      hours:       12,
      court:       true
    )
    out = "Судебное правило [#{res[:rule]['id']}] против #{args['target']} вступило в силу на 12ч: #{res[:rule]['content']}"
    out += " (прежнее судебное правило [#{res[:repealed]['id']}] утратило силу)" if res[:repealed]
    out
  }
)

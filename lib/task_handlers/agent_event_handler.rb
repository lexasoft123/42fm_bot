class AgentEventHandler
  include ChatContext

  def call(task, api)
    p = task.params_hash
    event_type = p['event_type'].to_s
    summary    = p['summary'].to_s

    LOGGER.info "[chat=#{task.chat_id}] AgentEventHandler[#{task.id}]: event=#{event_type} parent=#{p['parent_task_id']}"

    user_text = build_event_prompt(event_type, summary, parent_task_type: p['parent_task_type'])
    context   = get_chat_context(task.chat_id)
    knowledge = get_relevant_knowledge(summary, task.chat_id)
    user      = synthetic_event_user

    runner = Agent::Runner.new(
      text:      user_text,
      context:   context,
      knowledge: knowledge,
      radio:     nil, # tools that need a Radio socket will fail-soft
      chat_id:   task.chat_id,
      user:      user,
      bot:       nil
    )

    text = runner.run
    if text.nil? || text.strip.empty? || text == 'жпт не жпт' || text =~ /\A\s*\(skip\)\s*\z/i
      LOGGER.info "[chat=#{task.chat_id}] AgentEventHandler[#{task.id}]: agent chose silence"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!({ event_type: event_type, replied: false }) }
      return :done
    end

    resp = api.sendMessage(chat_id: task.chat_id, text: text)
    Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_done!({ event_type: event_type, replied: true, reply_chars: text.length })
    end
    :done
  rescue => e
    LOGGER.error "[chat=#{task.chat_id}] AgentEventHandler[#{task.id}]: #{e.class}: #{e.message}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(e.message) }
    :failed
  end

  private

  EVENT_DESCRIPTIONS = {
    'image_failed_after_retries' => 'Я только что попытался сгенерировать пользователю картинку через FLUX, но после всех ретраев не получилось.',
    'image_failed'               => 'Я попытался сгенерировать картинку через FLUX, но генерация провалилась (например, контент-модерация или таймаут).',
    'image_succeeded_after_retries' => 'Картинка сгенерирована, но не с первого раза — потребовалось несколько ретраев.',
    'song_failed_after_retries'  => 'Я попытался сгенерировать пользователю песню через Suno, но после всех ретраев не получилось.',
    'song_failed'                => 'Я попытался сгенерировать песню через Suno, но генерация провалилась.',
    'song_succeeded_after_retries' => 'Песня сгенерирована, но не с первого раза — потребовалось несколько ретраев.',
    'cover_art_failed'           => 'Я попытался нарисовать обложку для песни через Suno, но не получилось. Песня (если уже была доставлена) остаётся; обложка не пришла.',
    'cron_tick'                  => 'Будильник по scratchpad: одна или несколько твоих intentions достигли due_at и ждут действия. Список ниже. Реши сам — выполнить отложенное действие сейчас (например, повторить generate_image), прокомментировать в чате, или промолчать если ситуация уже не актуальна. Если выполнил — вызови forget(id) чтобы убрать запись.',
  }.freeze

  def build_event_prompt(event_type, summary, parent_task_type:)
    description = EVENT_DESCRIPTIONS[event_type] || "Произошло событие типа '#{event_type}'."
    <<~TEXT.strip
      [СЛУЖЕБНОЕ СОБЫТИЕ — это не сообщение от пользователя, это система уведомляет тебя о результате фоновой задачи]
      #{description}
      Подробности: #{summary[0..600]}

      Решение твоё: прокомментировать ситуацию (1-3 фразы со своей обычной харизмой), попробовать другой подход через инструменты (если уместно), или промолчать. Если решишь молчать — ответь ровно "(skip)". Не извиняйся формально, не пиши длинные эссе. Помни про scratchpad: можно сохранить в notes/intentions если ситуация повторится.
    TEXT
  end

  def synthetic_event_user
    User.new(uid: 0, name: 'system', role: 'admin')
  end
end

TaskRunner.register('agent_event', AgentEventHandler)

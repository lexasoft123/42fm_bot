# Weekly auto-posted Chat Wrapped (fired by CronScheduler#maybe_fire_digests).
# «Революция» (F7) lives ONLY here — the on-demand «бот итоги» command stays
# read-only. Retry-safe: the revolution roll happens once and is persisted
# into task params BEFORE any side effect; retries (handler raise →
# TaskRunner re-dispatch) re-read it instead of re-rolling.
class WrappedDigestHandler
  REVOLUTION_CHANCE = 0.1

  def call(task, api)
    p = task.params_hash
    unless p.key?('revolution')
      p['revolution'] = rand < REVOLUTION_CHANCE
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
    end

    text = ChatWrapped.generate(task.chat_id)
    if p['revolution']
      cleared = Agent::Scratchpad.clear_rules(task.chat_id) # idempotent on retry
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: revolution: #{cleared} rules cleared"
      text += "\n\n🚩 РЕВОЛЮЦИЯ! Все правила отменены. Конституция переписывается с нуля."
    end

    resp = api.sendMessage(chat_id: task.chat_id, text: text) # raise → TaskRunner retry
    Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    ActiveRecord::Base.connection_pool.with_connection do
      task.mark_done!(replied: true, revolution: p['revolution'])
    end
    :done
  end
end

TaskRunner.register('weekly_wrapped', WrappedDigestHandler)

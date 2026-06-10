# Posts a template obituary when rules-war rules expire (no LLM). The cron
# tick owns batching: one task per tick — single obituary or a combined
# «братская могила» whose params carry the full list. This handler only
# renders what the params say.
class RuleObituaryHandler
  def call(task, api)
    rules = Array(task.params_hash['rules'])
    if rules.empty?
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(replied: false) }
      return :done
    end
    text = render(rules)
    resp = api.sendMessage(chat_id: task.chat_id, text: text)
    Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(replied: true, rules: rules.size) }
    :done
  rescue => e
    LOGGER.error "[chat=#{task.chat_id}] RuleObituaryHandler[#{task.id}]: #{e.class}: #{e.message}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(e.message) }
    :failed
  end

  private

  def render(rules)
    if rules.size == 1
      r = rules.first
      "⚰️ Правило #{r['id']} («#{r['content']}») скончалось, не дожив до амнистии. Вечная память."
    else
      lines = ['⚰️ Братская могила правил:']
      rules.each { |r| lines << "• #{r['id']} «#{r['content']}»" }
      lines << 'Вечная память.'
      lines.join("\n")
    end
  end
end

TaskRunner.register('rule_obituary', RuleObituaryHandler)

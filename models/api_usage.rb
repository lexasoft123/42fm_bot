require 'bigdecimal'

class ApiUsage < ActiveRecord::Base
  self.table_name = 'api_usage'

  # Record usage + computed cost. Never raises — telemetry must not break the bot.
  def self.record(model:, purpose:, usage:, chat_id: nil)
    cost = compute_cost(model, usage)
    create!(
      chat_id:            chat_id,
      model:              model,
      purpose:            purpose,
      input_tokens:       usage[:input].to_i,
      output_tokens:      usage[:output].to_i,
      cache_read_tokens:  usage[:cache_read].to_i,
      cache_write_tokens: usage[:cache_write].to_i,
      cost_cents:         cost,
      created_at:         Time.now,
    )
  rescue => e
    LOGGER.warn "ApiUsage.record failed: #{e.class}: #{e.message}" if defined?(LOGGER)
    nil
  end

  # Compute cost in cents (BigDecimal). Pricing per 1M tokens in USD.
  def self.compute_cost(model, usage)
    price = pricing_for(model)
    unless price
      LOGGER.warn "ApiUsage: no pricing for model '#{model}', logging 0" if defined?(LOGGER)
      return BigDecimal('0')
    end
    per_mtok = BigDecimal('1000000')
    cents    = BigDecimal('100')
    (
      BigDecimal(usage[:input].to_i)       * BigDecimal(price['input'].to_s)       +
      BigDecimal(usage[:output].to_i)      * BigDecimal(price['output'].to_s)      +
      BigDecimal(usage[:cache_read].to_i)  * BigDecimal(price['cache_read'].to_s)  +
      BigDecimal(usage[:cache_write].to_i) * BigDecimal(price['cache_write'].to_s)
    ) / per_mtok * cents
  end

  def self.pricing_for(model)
    cfg = Settings.chat_gpt['pricing'] rescue nil
    cfg && cfg[model]
  end
end

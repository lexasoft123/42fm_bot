require 'bigdecimal'

class ApiUsage < ActiveRecord::Base
  self.table_name = 'api_usage'

  # Record usage + computed cost. Never raises — telemetry must not break the bot.
  def self.record(model:, purpose:, usage:, chat_id: nil, user_uid: nil)
    cost = compute_cost(model, usage)
    create!(
      chat_id:            chat_id,
      user_uid:           user_uid,
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

  # Cents saved by prompt caching in the given scope, relative to a no-cache baseline:
  #   saved = cache_read_tokens × (input_rate − cache_read_rate)
  #         − cache_write_tokens × (cache_write_rate − input_rate)
  # The read term is the discount on cached input; the write term is the surcharge we pay
  # on the initial cache creation. Net value tells us whether caching is actually winning.
  def self.cache_savings_cents(scope)
    per_mtok  = BigDecimal('1000000')
    cents     = BigDecimal('100')
    total_usd = BigDecimal('0')

    rows = scope.group(:model).pluck(
      :model,
      Arel.sql('SUM(cache_read_tokens)'),
      Arel.sql('SUM(cache_write_tokens)'),
    )
    rows.each do |model, read_tokens, write_tokens|
      price = pricing_for(model)
      next unless price
      input_rate  = BigDecimal(price['input'].to_s)
      read_rate   = BigDecimal(price['cache_read'].to_s)
      write_rate  = BigDecimal(price['cache_write'].to_s)
      total_usd += BigDecimal(read_tokens.to_i)  * (input_rate - read_rate)
      total_usd -= BigDecimal(write_tokens.to_i) * (write_rate - input_rate)
    end
    total_usd / per_mtok * cents
  end
end

require_relative 'test_helper'

require 'bigdecimal'

# Stub Settings before loading model so pricing lookup works
module Settings
  @chat_gpt = {
    'pricing' => {
      'claude-sonnet-4-6' => { 'input' => 3, 'output' => 15, 'cache_read' => 0.30, 'cache_write' => 3.75 },
      'claude-opus-4-6'   => { 'input' => 5, 'output' => 25, 'cache_read' => 0.50, 'cache_write' => 6.25 },
      'claude-opus-4-7'   => { 'input' => 5, 'output' => 25, 'cache_read' => 0.50, 'cache_write' => 6.25 },
      'text-embedding-3-small' => { 'input' => 0.02, 'output' => 0, 'cache_read' => 0, 'cache_write' => 0 },
    }
  }
  def self.chat_gpt; @chat_gpt; end
end unless Settings.respond_to?(:chat_gpt)

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../models/api_usage'

class ApiUsageCostTest < BotTest
  def test_sonnet_cost_matches_hand_calc
    # 10k input @ $3/M = 3¢; 2k output @ $15/M = 3¢; 5k cache_read @ $0.30/M = 0.15¢; cache_write 0
    # Total = 6.15¢
    cents = ApiUsage.compute_cost('claude-sonnet-4-6',
                                   input: 10_000, output: 2_000, cache_read: 5_000, cache_write: 0)
    assert_in_delta 6.15, cents.to_f, 0.0001
  end

  def test_opus_46_cost
    # 10k input @ $5/M = 5¢; 2k output @ $25/M = 5¢; 5k cache_read @ $0.50/M = 0.25¢
    # Total = 10.25¢
    cents = ApiUsage.compute_cost('claude-opus-4-6',
                                   input: 10_000, output: 2_000, cache_read: 5_000, cache_write: 0)
    assert_in_delta 10.25, cents.to_f, 0.0001
  end

  def test_opus_47_cost_matches_opus_46
    usage = { input: 10_000, output: 2_000, cache_read: 5_000, cache_write: 0 }
    assert_equal ApiUsage.compute_cost('claude-opus-4-6', usage).to_f,
                 ApiUsage.compute_cost('claude-opus-4-7', usage).to_f
  end

  def test_embedding_cost_output_ignored
    # 1M input @ $0.02/M = 2¢; output term contributes 0
    cents = ApiUsage.compute_cost('text-embedding-3-small',
                                   input: 1_000_000, output: 5_000, cache_read: 0, cache_write: 0)
    assert_in_delta 2.0, cents.to_f, 0.0001
  end

  def test_unknown_model_returns_zero
    cents = ApiUsage.compute_cost('mystery-model-v99',
                                   input: 1000, output: 1000, cache_read: 0, cache_write: 0)
    assert_equal 0, cents.to_i
  end

  def test_cache_write_billed
    # Sonnet cache_write @ $3.75/M; 1M tokens = 375¢
    cents = ApiUsage.compute_cost('claude-sonnet-4-6',
                                   input: 0, output: 0, cache_read: 0, cache_write: 1_000_000)
    assert_in_delta 375.0, cents.to_f, 0.0001
  end
end

class ApiUsageRecordTest < BotTest
  def test_record_persists_all_fields
    row = ApiUsage.record(
      model: 'claude-sonnet-4-6',
      purpose: 'agent',
      chat_id: -100_123,
      usage: { input: 100, output: 20, cache_read: 50, cache_write: 10 }
    )
    refute_nil row
    assert_equal -100_123,            row.chat_id
    assert_equal 'claude-sonnet-4-6', row.model
    assert_equal 'agent',             row.purpose
    assert_equal 100, row.input_tokens
    assert_equal 20,  row.output_tokens
    assert_equal 50,  row.cache_read_tokens
    assert_equal 10,  row.cache_write_tokens
    assert row.cost_cents > 0
    assert_kind_of Time, row.created_at
  end

  def test_record_with_nil_chat_id
    row = ApiUsage.record(model: 'claude-sonnet-4-6', purpose: 'translate',
                          usage: { input: 100, output: 20, cache_read: 0, cache_write: 0 })
    refute_nil row
    assert_nil row.chat_id
  end

  def test_record_swallows_failure
    # Passing something that can't be stored (rails-level create! will raise)
    # — stub to raise, ensure no exception propagates
    ApiUsage.stub(:create!, ->(*_) { raise StandardError, 'boom' }) do
      assert_nil ApiUsage.record(model: 'claude-sonnet-4-6', purpose: 'agent',
                                 usage: { input: 1, output: 1, cache_read: 0, cache_write: 0 })
    end
  end

  def test_record_unknown_model_still_creates_row_with_zero_cost
    row = ApiUsage.record(model: 'mystery-v99', purpose: 'agent',
                          usage: { input: 1000, output: 0, cache_read: 0, cache_write: 0 })
    refute_nil row
    assert_equal 0, row.cost_cents.to_i
  end
end

class ApiUsageCacheSavingsTest < BotTest
  def seed(usage)
    ApiUsage.create!(
      chat_id: 1, model: usage[:model], purpose: 'agent',
      input_tokens: usage[:input].to_i, output_tokens: usage[:output].to_i,
      cache_read_tokens: usage[:cache_read].to_i, cache_write_tokens: usage[:cache_write].to_i,
      cost_cents: 0, created_at: Time.now,
    )
  end

  def test_empty_scope_returns_zero
    assert_equal 0, ApiUsage.cache_savings_cents(ApiUsage.all).to_i
  end

  def test_pure_cache_read_yields_discount
    # 1M cache_read tokens on Sonnet 4.6: input=$3/M, cache_read=$0.30/M → saved $2.70 = 270¢
    seed(model: 'claude-sonnet-4-6', input: 0, output: 0, cache_read: 1_000_000, cache_write: 0)
    assert_in_delta 270.0, ApiUsage.cache_savings_cents(ApiUsage.all).to_f, 0.0001
  end

  def test_pure_cache_write_is_a_loss
    # 1M cache_write tokens on Sonnet 4.6: cache_write=$3.75/M vs input=$3/M → overhead $0.75 = -75¢ saved
    seed(model: 'claude-sonnet-4-6', input: 0, output: 0, cache_read: 0, cache_write: 1_000_000)
    assert_in_delta(-75.0, ApiUsage.cache_savings_cents(ApiUsage.all).to_f, 0.0001)
  end

  def test_net_savings_combines_reads_and_writes
    # 1M read + 100k write on Sonnet 4.6: 270¢ − 7.5¢ = 262.5¢
    seed(model: 'claude-sonnet-4-6', input: 0, output: 0, cache_read: 1_000_000, cache_write: 100_000)
    assert_in_delta 262.5, ApiUsage.cache_savings_cents(ApiUsage.all).to_f, 0.0001
  end

  def test_unknown_model_contributes_nothing
    seed(model: 'mystery-v99', input: 0, output: 0, cache_read: 1_000_000, cache_write: 0)
    assert_equal 0, ApiUsage.cache_savings_cents(ApiUsage.all).to_i
  end

  def test_per_model_prices_applied_independently
    # Sonnet cache_read save = 1M × ($3 − $0.30)  = 270¢
    # Opus 4.7 cache_read save = 500k × ($5 − $0.50) = 225¢
    # Total = 495¢
    seed(model: 'claude-sonnet-4-6', input: 0, output: 0, cache_read: 1_000_000, cache_write: 0)
    seed(model: 'claude-opus-4-7',   input: 0, output: 0, cache_read: 500_000,   cache_write: 0)
    assert_in_delta 495.0, ApiUsage.cache_savings_cents(ApiUsage.all).to_f, 0.0001
  end
end

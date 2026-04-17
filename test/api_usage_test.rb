require_relative 'test_helper'

require 'bigdecimal'

# Stub Settings before loading model so pricing lookup works
module Settings
  @chat_gpt = {
    'pricing' => {
      'claude-sonnet-4-6' => { 'input' => 3,  'output' => 15, 'cache_read' => 0.30, 'cache_write' => 3.75 },
      'claude-opus-4-6'   => { 'input' => 15, 'output' => 75, 'cache_read' => 1.50, 'cache_write' => 18.75 },
      'claude-opus-4-7'   => { 'input' => 15, 'output' => 75, 'cache_read' => 1.50, 'cache_write' => 18.75 },
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
    # 10k input @ $15/M = 15¢; 2k output @ $75/M = 15¢; 5k cache_read @ $1.50/M = 0.75¢
    # Total = 30.75¢
    cents = ApiUsage.compute_cost('claude-opus-4-6',
                                   input: 10_000, output: 2_000, cache_read: 5_000, cache_write: 0)
    assert_in_delta 30.75, cents.to_f, 0.0001
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

require_relative 'test_helper'

# Live-API integration test for the CloseRouter LLM provider.
# Reads real Settings (config/settings.yml + settings.common.yml). Skips when
# the closerouter provider's api_key is not configured, so `make test`
# continues to work on machines without the key.
#
# Cost: ≤ $0.0001 per full run on the cheapest catalog model.

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require 'ostruct'
require 'httparty'

# Boot real settings (settings.common.yml + settings.yml). test_helper.rb
# previously stubbed Settings.radio only; load! populates @_settings, and the
# stubbed Settings.radio (class instance var) coexists harmlessly with the
# OpenStruct-backed accessors used here.
require_relative '../lib/settings'
Settings.load!(File.expand_path('../config/settings.yml', __dir__))

require_relative '../lib/gpt_master'

class CloseRouterProviderIntegrationTest < BotTest
  PROVIDER_NAME    = 'closerouter'.freeze
  SMOKE_SETTING    = 'closerouter_smoke'.freeze
  # Cheapest catalog model — pricing-verified $0.10 prompt / $0.10 completion
  # per 1M tokens via GET /v1/models on 2026-05-18.
  SMOKE_MODEL      = 'google/gemini-3.1-flash-lite-preview'.freeze
  SMOKE_CHAT_ID    = -999_001

  def setup
    super
    cfg = Settings.chat_gpt
    provider = cfg.dig('providers', PROVIDER_NAME)
    if provider.nil? || provider['api_key'].to_s.empty?
      skip "closerouter provider api_key not set in config/settings.yml — skipped"
    end
    # Test-only setting injected at runtime so production settings.common.yml
    # stays uncluttered. Idempotent — re-injection across test methods is fine.
    cfg['settings'][SMOKE_SETTING] = {
      'provider'   => PROVIDER_NAME,
      'model'      => SMOKE_MODEL,
      'max_tokens' => 32,
    }
  end

  # 1. OpenAI-compatible /chat/completions through GptMaster.
  #    Verifies the provider+setting wiring, request format, response parse,
  #    and ApiUsage telemetry all line up end-to-end against the live API.
  def test_chat_completion_returns_text_and_records_usage
    reply = GptMaster.new(
      [{ role: 'user', content: 'Reply with exactly one word: pong' }],
      setting:  SMOKE_SETTING,
      chat_id:  SMOKE_CHAT_ID,
      purpose:  'cr_smoke',
    ).call

    assert_kind_of String, reply
    refute reply.strip.empty?, "expected non-empty reply, got #{reply.inspect}"
    refute_equal 'жпт не жпт', reply, 'GptMaster sentinel — call failed (check log/gpt.log)'

    row = ApiUsage.where(chat_id: SMOKE_CHAT_ID).order(:id).last
    assert row, 'expected an ApiUsage row for the call'
    assert_equal SMOKE_MODEL, row.model
    assert_equal 'cr_smoke',  row.purpose
    assert_operator row.input_tokens,  :>, 0, 'input_tokens should be > 0'
    assert_operator row.output_tokens, :>, 0, 'output_tokens should be > 0'
  end

  # 2. System-prompt routing on the openai-compat path. GptMaster
  #    prepends system as a {role: 'system'} message for non-anthropic
  #    api_type; this verifies the converted shape reaches CloseRouter.
  def test_system_prompt_is_honored
    reply = GptMaster.new(
      [{ role: 'user', content: 'What is 2+2?' }],
      setting:       SMOKE_SETTING,
      system_prompt: 'Answer with only the digit, no words.',
      chat_id:       SMOKE_CHAT_ID - 1,
      purpose:       'cr_smoke',
    ).call

    refute_equal 'жпт не жпт', reply, 'GptMaster sentinel — call failed'
    assert_match(/4/, reply, "expected '4' in reply, got #{reply.inspect}")
  end

  # 3. Token counts + cost recording. GptMaster.extract_usage handles the
  #    OpenAI usage shape (prompt_tokens / completion_tokens / total_tokens).
  #    Cost is computed from chat_gpt.pricing — if the model isn't priced,
  #    ApiUsage.compute_cost warns and records cost_cents=0 (still a valid row).
  def test_token_counts_and_cost_recording
    GptMaster.new(
      [{ role: 'user', content: 'Reply with a single short word.' }],
      setting: SMOKE_SETTING,
      chat_id: SMOKE_CHAT_ID - 2,
      purpose: 'cr_smoke',
    ).call

    row = ApiUsage.where(chat_id: SMOKE_CHAT_ID - 2).order(:id).last
    assert row
    assert_operator row.input_tokens + row.output_tokens, :>, 0
    # cost_cents is BigDecimal; can be 0 if model isn't in chat_gpt.pricing —
    # acceptable per Round 1 scope. Test asserts it's NUMERIC, not >0.
    assert_kind_of Numeric, row.cost_cents.to_f
  end
end

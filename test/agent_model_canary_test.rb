require_relative 'test_helper'
require_relative '../lib/agent/model_canary'

class AgentModelCanaryTest < BotTest
  UnavailableGpt = Class.new do
    def initialize(*) = nil
    def call_raw(tools:) = raise(Socket::ResolutionError, 'offline')
  end

  def settings(agent_provider: 'deepseek', closerouter_key: 'secret-canary-key', deepseek_key: 'ds')
    {
      'providers' => {
        'closerouter' => { 'api_key' => closerouter_key, 'api_type' => 'openai' },
        'deepseek' => { 'api_key' => deepseek_key, 'api_type' => 'openai' }
      },
      'settings' => { 'agent' => { 'provider' => agent_provider, 'model' => 'deepseek-flash' } }
    }
  end

  def test_skips_closerouter_cleanly_without_configured_glm_model
    targets = Agent::ModelCanary.new(settings: settings, closerouter_model: '').targets
    assert_match(/CANARY_CLOSEROUTER_MODEL/, targets.first[:skip])
    refute targets.last.key?(:skip)
  end

  def test_uses_configured_closerouter_agent_without_exposing_key
    cfg = settings(agent_provider: 'closerouter')
    cfg['settings']['agent']['model'] = 'z-ai/glm-test'
    target = Agent::ModelCanary.new(settings: cfg).targets.first
    assert_equal 'z-ai/glm-test', target[:model]
    refute_includes target.inspect, 'secret-canary-key'
  end

  def test_missing_provider_key_is_a_skip_not_an_exception
    target = Agent::ModelCanary.new(settings: settings(deepseek_key: nil)).targets.last
    assert_match(/API key is unavailable/, target[:skip])
  end

  def test_network_unavailability_is_reported_as_clean_skip
    results = Agent::ModelCanary.new(settings: settings, closerouter_model: 'z-ai/glm-test',
                                     gpt_class: UnavailableGpt).run
    assert results.all? { |result| result[:skip].to_s.include?('Socket::ResolutionError') }
    assert results.none? { |result| result.key?(:cases) }
  end
end

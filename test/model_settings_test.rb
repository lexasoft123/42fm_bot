require_relative 'test_helper'
require 'yaml'

class ModelSettingsTest < BotTest
  ROOT = File.expand_path('..', __dir__)

  def setup
    super
    @settings = YAML.load_file(File.join(ROOT, 'config/settings.common.yml'))
  end

  def test_all_active_deepseek_roles_use_v41_flash
    settings = @settings.dig('chat_gpt', 'settings')
    deepseek_roles = settings.select { |_name, cfg| cfg['provider'] == 'deepseek' }

    assert_equal %w[agent agent_vision image_prompt knowledge knowledge_review], deepseek_roles.keys.sort
    deepseek_roles.each do |name, cfg|
      assert_equal 'deepseek-flash', cfg['model'], "#{name} must use the V4.1 Flash API id"
    end
  end

  def test_thinking_modes_remain_role_specific
    settings = @settings.dig('chat_gpt', 'settings')

    assert_equal 'enabled', settings.dig('agent', 'thinking', 'type')
    assert_equal 'enabled', settings.dig('agent_vision', 'thinking', 'type')
    assert_equal 'disabled', settings.dig('image_prompt', 'thinking', 'type')
  end
end

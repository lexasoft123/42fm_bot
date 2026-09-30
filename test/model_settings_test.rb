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

    assert_equal 'disabled', settings.dig('agent', 'thinking', 'type')
    assert_equal 'disabled', settings.dig('agent_vision', 'thinking', 'type')
    assert_equal 'disabled', settings.dig('image_prompt', 'thinking', 'type')
    assert_equal 4096, settings.dig('agent', 'max_tokens')
    assert_equal 4096, settings.dig('agent_vision', 'max_tokens')
    assert_equal 768, settings.dig('image_prompt', 'max_tokens')
  end

  def test_current_non_deepseek_roles_are_pinned
    settings = @settings.dig('chat_gpt', 'settings')

    assert_equal 'claude-sonnet-5', settings.dig('lyrics', 'model')
    assert_equal 'disabled', settings.dig('lyrics', 'thinking', 'type')
    assert_equal 'text-embedding-3-small', settings.dig('embedder', 'model')
  end

  def test_agent_prompt_requires_authoritative_task_status
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'Никогда не выдумывай состояние фоновой задачи'
    assert_includes prompt, 'самому свежему доверенному результату'
    assert_includes prompt, 'generated ещё не означает delivered'
    assert_includes prompt, 'task_status'
    assert_includes prompt, 'задача #ID'
    assert_includes prompt, 'не переноси статус одной задачи на другую'
  end

  def test_agent_prompt_prioritizes_truth_and_admits_uncertainty
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'Сначала дай правильный и полезный ответ или выполни действие'
    assert_includes prompt, 'никогда не ценой фактов, намерения пользователя или правдивого статуса действия'
    assert_includes prompt, 'Если не уверен — прямо скажи, что именно неизвестно'
    assert_includes prompt, 'Не выдумывай факты, источники, причины ошибок, задержек или поведения сервисов'
    assert_includes prompt, 'проверь утверждение и явно исправь ошибку'
    refute_includes prompt, 'Делай вид что знаешь ответы на все вопросы'
  end

  def test_agent_prompt_defaults_to_concise_non_repetitive_humor
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'одну точную шутку или контекстную нелепость'
    assert_includes prompt, 'Не пересказывай всех участников'
    assert_includes prompt, '1–3 предложения и примерно до 500 символов'
    assert_includes prompt, 'не используй «в печь/печь», «выползет сам», «Дзен постигнут» и ритуальное ✌️'
  end

  def test_agent_prompt_limits_phrase_tool_to_explicit_requests
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'Вызывай get_random_phrase только когда пользователь явно просит'
    assert_includes prompt, 'Не вызывай его для обычного абсурдного, риторического или шуточного запроса'
    refute_includes prompt, 'Если запрос абсурдный, риторический или просто хочешь пошутить — вызови get_random_phrase'
  end

  def test_agent_prompt_has_bounded_fact_search_policy
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'Google-поиск обязателен для актуальных/изменчивых фактов'
    assert_includes prompt, 'нишевых фактических утверждений, медицины и других вопросов с высокой ценой ошибки'
    assert_includes prompt, 'когда пользователь явно просит найти, проверить или погуглить'
    assert_includes prompt, 'В остальных случаях отвечай напрямую без поиска'
    assert_includes prompt, 'не больше одного исходного поискового запроса и одной осмысленной переформулировки'
    assert_includes prompt, 'честно обозначь неопределённость'
  end

  def test_agent_prompt_preserves_translation_contract
    prompt = @settings.dig('chat_gpt', 'agent_prompt')

    assert_includes prompt, 'Если пользователь просит перевод текста — переведи сам, без инструментов'
    assert_includes prompt, 'для перевода отдавай ТОЛЬКО результат'
  end
end

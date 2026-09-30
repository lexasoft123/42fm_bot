require 'json'
require_relative '../gpt_master'

module Agent
  # Harmless, opt-in real-token smoke test for agent model candidates. It never
  # instantiates Runner or executes bot tools; advertised tools are inert and
  # only their selected names are inspected.
  class ModelCanary
    CASES = [
      { name: 'routing', prompt: 'Найди свежую погоду в Москве.', expected_tool: 'google_search' },
      { name: 'correction', prompt: 'Столица Австралии — Сидней. Поправь меня кратко.', contains: /канберр/i },
      { name: 'task_status', prompt: 'Задача #42 уже готова?', expected_tool: 'task_status' },
      { name: 'terse_chaos', prompt: 'Одной короткой фразой придумай безумный, но безобидный тост про радио и пельмени.', max_chars: 500 }
    ].freeze

    def initialize(settings: Settings.chat_gpt, closerouter_model: ENV['CANARY_CLOSEROUTER_MODEL'],
                   gpt_class: GptMaster, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @settings = settings
      @closerouter_model = closerouter_model.to_s.strip
      @gpt_class = gpt_class
      @clock = clock
    end

    def run
      targets.map { |target| target[:skip] ? target : run_target(target) }
    end

    def targets
      [closerouter_target, deepseek_target]
    end

    private

    def closerouter_target
      agent = @settings.dig('settings', 'agent') || {}
      model = agent['provider'] == 'closerouter' ? agent['model'].to_s : @closerouter_model
      target('closerouter_glm', 'closerouter', model,
             'configured agent is not CloseRouter and CANARY_CLOSEROUTER_MODEL is unset')
    end

    def deepseek_target
      model = @settings.dig('settings', 'agent', 'provider') == 'deepseek' ?
        @settings.dig('settings', 'agent', 'model').to_s : 'deepseek-flash'
      target('deepseek_v41_flash', 'deepseek', model, 'DeepSeek model is not configured')
    end

    def target(name, provider, model, missing_model_reason)
      cfg = @settings.dig('providers', provider) || {}
      reason = missing_model_reason if model.empty?
      reason ||= "#{provider} provider/API key is unavailable" if cfg.empty? || cfg['api_key'].to_s.empty?
      { name: name, provider: provider, model: model, skip: reason }.compact
    end

    def run_target(target)
      temp_name = "__canary_#{target[:name]}"
      settings = @settings.fetch('settings')
      previous = settings[temp_name]
      settings[temp_name] = {
        'provider' => target[:provider], 'model' => target[:model],
        'max_tokens' => 4096, 'thinking' => { 'type' => 'disabled' }
      }
      results = CASES.map { |test_case| run_case(temp_name, target[:provider], test_case) }
      if results.all? { |result| result[:error] }
        klass = results.first[:error_class]
        return target.merge(skip: "provider request unavailable (#{klass})")
      end
      target.merge(cases: results, passed: results.count { |r| r[:passed] }, total: results.length)
    rescue => e
      target.merge(error: e.class.name, passed: 0, total: CASES.length)
    ensure
      previous ? settings[temp_name] = previous : settings&.delete(temp_name)
    end

    def run_case(setting, provider, test_case)
      started = @clock.call
      raw = @gpt_class.new([{ role: 'user', content: test_case[:prompt] }], setting: setting,
                           purpose: 'agent_model_canary', report_errors: false,
                           record_usage: false,
                           system_prompt: 'Отвечай кратко и правдиво. При необходимости выбери доступный инструмент.').call_raw(
                             tools: tool_definitions(provider)
                           )
      text, tool_names = extract(raw, provider)
      passed = if test_case[:expected_tool]
        tool_names.include?(test_case[:expected_tool])
      elsif test_case[:contains]
        text.match?(test_case[:contains])
      else
        !text.strip.empty? && text.length <= test_case[:max_chars]
      end
      { name: test_case[:name], passed: passed,
        took_ms: ((@clock.call - started) * 1000).round,
        chars: text.length, tools: tool_names }
    rescue => e
      { name: test_case[:name], passed: false,
        took_ms: ((@clock.call - started) * 1000).round,
        error_class: e.class.name, error: e.class.name }
    end

    def tool_definitions(provider)
      names = %w[google_search task_status]
      return names.map { |name| { name: name, description: 'Read-only canary tool', input_schema: { type: 'object', properties: {} } } } unless provider == 'closerouter' || provider == 'deepseek'
      names.map { |name| { type: 'function', function: { name: name, description: 'Read-only canary tool', parameters: { type: 'object', properties: {} } } } }
    end

    def extract(raw, provider)
      return ['', []] unless raw.is_a?(Hash)
      if provider == 'closerouter' || provider == 'deepseek'
        message = raw.dig('choices', 0, 'message') || {}
        [message['content'].to_s, Array(message['tool_calls']).filter_map { |c| c.dig('function', 'name') }]
      else
        blocks = Array(raw['content'])
        [blocks.filter_map { |b| b['text'] if b['type'] == 'text' }.join, blocks.filter_map { |b| b['name'] if b['type'] == 'tool_use' }]
      end
    end
  end
end

require_relative 'test_helper'

require 'ostruct'

module Settings
  @replies = { 'admin_denied' => ['nope'] }
  def self.replies; @replies; end
  @chat_gpt = {
    'pricing' => {
      'claude-sonnet-4-6' => { 'input' => 3, 'output' => 15, 'cache_read' => 0.30, 'cache_write' => 3.75 },
    }
  }
  def self.chat_gpt; @chat_gpt; end
end unless Settings.respond_to?(:replies)

LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

require_relative '../models/api_usage'
require_relative '../lib/command_result'
require_relative '../lib/command_context'
require_relative '../lib/commands/base'
require_relative '../lib/commands/cost_report'

class CostReportPatternTest < BotTest
  [
    'бот затраты',
    'бот расходы',
    'бот cost',
    'бой затраты',
    'Бот, расходы',
  ].each do |input|
    define_method("test_matches_#{input.hash.abs}") do
      ctx = OpenStruct.new(cmd: input, user: OpenStruct.new(role: 'admin'), chat_id: 1)
      assert Commands::CostReport.new(ctx).match?, "expected match for: #{input.inspect}"
    end
  end

  [
    'бот затратная тема',
    'бот в расходах разберёмся',
    'bob cost something',
    'просто текст',
  ].each do |input|
    define_method("test_does_not_match_#{input.hash.abs}") do
      ctx = OpenStruct.new(cmd: input, user: OpenStruct.new(role: 'admin'), chat_id: 1)
      refute Commands::CostReport.new(ctx).match?, "expected no match for: #{input.inspect}"
    end
  end
end

class CostReportDispatchTest < BotTest
  def setup
    super
    @admin    = OpenStruct.new(role: 'admin', name: 'admin')
    @member   = OpenStruct.new(role: 'member', name: 'joe')
    @chat_id  = -100_555
  end

  def ctx(user:, cmd: 'бот затраты', message: nil)
    message ||= OpenStruct.new(chat: OpenStruct.new(title: 'claude_cook', type: 'supergroup'))
    OpenStruct.new(cmd: cmd, user: user, chat_id: @chat_id, message: message)
  end

  def seed_row(chat_id, cents, purpose: 'agent', at: Time.now - 60)
    ApiUsage.create!(
      chat_id: chat_id, model: 'claude-sonnet-4-6', purpose: purpose,
      input_tokens: 100, output_tokens: 20, cache_read_tokens: 0, cache_write_tokens: 0,
      cost_cents: cents, created_at: at,
    )
  end

  def test_non_admin_gets_admin_denied
    result = Commands::CostReport.new(ctx(user: @member)).execute
    assert_equal :text, result.type
    assert_equal 'nope', result.payload
  end

  def test_admin_with_no_history_renders_zero
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    assert_equal :text, result.type
    assert_includes result.payload, '💰'
    assert_includes result.payload, '0.00¢'
    assert_includes result.payload, 'сэкономлено кэшем'
  end

  def test_header_shows_chat_title_when_present
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    assert_includes result.payload, 'Этот чат (claude_cook)'
    refute_includes result.payload, "Этот чат (`#{@chat_id}`)"
  end

  def test_header_falls_back_to_user_name_for_private_chats
    private_msg = OpenStruct.new(chat: OpenStruct.new(title: nil, first_name: 'Alice', last_name: 'Smith', type: 'private'))
    result = Commands::CostReport.new(ctx(user: @admin, message: private_msg)).execute
    assert_includes result.payload, 'Этот чат (Alice Smith)'
  end

  def test_header_falls_back_to_chat_id_when_title_and_name_missing
    blank_msg = OpenStruct.new(chat: OpenStruct.new(title: nil, first_name: nil, last_name: nil, type: 'private'))
    result = Commands::CostReport.new(ctx(user: @admin, message: blank_msg)).execute
    assert_includes result.payload, "Этот чат (`#{@chat_id}`)"
  end

  def test_digest_surfaces_cache_savings
    ApiUsage.create!(
      chat_id: @chat_id, model: 'claude-sonnet-4-6', purpose: 'agent',
      input_tokens: 0, output_tokens: 0,
      cache_read_tokens: 1_000_000, cache_write_tokens: 0,
      cost_cents: 30, created_at: Time.now - 60,
    )
    # 1M cache_read → $2.70 saved = 270¢ → shown as "$2.70"
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    assert_includes result.payload, 'сэкономлено кэшем $2.70'
  end

  def test_admin_digest_includes_both_chat_and_global_sections
    seed_row(@chat_id, 50)           # this chat, today
    seed_row(@chat_id, 25, purpose: 'main_chat')
    seed_row(-200, 100)               # other chat
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    # This-chat total: 75¢
    # Global total: 175¢
    assert_includes result.payload, 'Этот чат'
    assert_includes result.payload, 'Все чаты'
    assert_includes result.payload, 'agent'
    assert_includes result.payload, 'main_chat'
  end

  def test_windows_filter_old_rows
    seed_row(@chat_id, 10, at: Time.now - 60)                  # today
    seed_row(@chat_id, 20, at: Time.now - 2 * 86_400)           # 7d but not today
    seed_row(@chat_id, 30, at: Time.now - 10 * 86_400)          # 30d only
    seed_row(@chat_id, 99, at: Time.now - 60 * 86_400)          # excluded from all windows
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    # Should mention the 30d cutoff total (10+20+30=60) but not 99
    refute_includes result.payload, '$0.99'
  end

  def test_top_users_lists_names_and_sorts_by_cost
    User.create!(uid: 777, name: 'alice', role: 'member')
    User.create!(uid: 888, name: 'bob',   role: 'member')
    ApiUsage.create!(chat_id: @chat_id, user_uid: 777, model: 'claude-sonnet-4-6', purpose: 'agent',
                     input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
                     cost_cents: 150, created_at: Time.now - 60)
    ApiUsage.create!(chat_id: @chat_id, user_uid: 888, model: 'claude-sonnet-4-6', purpose: 'agent',
                     input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
                     cost_cents: 50,  created_at: Time.now - 60)
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    assert_includes result.payload, 'Топ юзеров'
    assert_includes result.payload, 'alice'
    assert_includes result.payload, 'bob'
    # alice must appear before bob (higher cost first)
    assert result.payload.index('alice') < result.payload.index('bob'), 'alice should be listed before bob'
  end

  def test_top_users_ignores_rows_with_nil_uid
    ApiUsage.create!(chat_id: @chat_id, user_uid: nil, model: 'claude-sonnet-4-6', purpose: 'knowledge_extract',
                     input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
                     cost_cents: 99, created_at: Time.now - 60)
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    assert_includes result.payload, 'нет данных'
  end

  def test_top_users_section_limited_to_top_5
    (1..8).each do |i|
      User.create!(uid: 100 + i, name: "u#{i}", role: 'member')
      ApiUsage.create!(chat_id: @chat_id, user_uid: 100 + i, model: 'claude-sonnet-4-6', purpose: 'agent',
                       input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0,
                       cost_cents: i * 10, created_at: Time.now - 60)
    end
    result = Commands::CostReport.new(ctx(user: @admin)).execute
    %w[u8 u7 u6 u5 u4].each { |n| assert_includes result.payload, n }
    %w[u1 u2 u3].each { |n| refute_includes result.payload, n }
  end
end

class CostReportRegistryOrderTest < BotTest
  # Inspect the registry file directly (avoids requiring the entire command tree at test time)
  def test_registered_before_gpt_chat
    source = File.read(File.expand_path('../lib/commands/registry.rb', __dir__))
    cost_idx = source.index('CostReport')
    gpt_idx  = source.index('GptChat,')
    refute_nil cost_idx, "CostReport missing from registry"
    refute_nil gpt_idx, "GptChat missing from registry"
    assert cost_idx < gpt_idx, "CostReport must be registered before GptChat"
  end
end

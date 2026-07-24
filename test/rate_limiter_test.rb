require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Settings stub — RateLimiter consults Settings.auth.dig(...). Tests mutate
# this hash directly via Settings.auth = { ... } per case.
unless Settings.respond_to?(:auth)
  Settings.singleton_class.send(:define_method, :auth) {
    @auth ||= {}
  }
  Settings.singleton_class.send(:define_method, :auth=) { |v| @auth = v }
end

require_relative '../lib/rate_limiter'

class RateLimiterTest < BotTest
  CHAT = -100123

  def setup
    super
    Settings.auth = {
      'rate_limits' => {
        'image' => { 'max' => 1, 'window_minutes' => 20 },
        'suno'  => { 'max' => 1, 'window_minutes' => 20 },
      }
    }
  end

  def test_default_limit_for_no_role
    l = RateLimiter.limit_for(CHAT, 'image')
    assert_equal 1, l['max']
    assert_equal 20, l['window_minutes']
  end

  def test_admin_role_uses_admin_bucket_when_set
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 10, 'window_minutes' => 30 },
    }
    l = RateLimiter.limit_for(CHAT, 'image', role: 'admin')
    assert_equal 10, l['max']
    assert_equal 30, l['window_minutes']
  end

  def test_admin_role_falls_through_when_no_admin_bucket
    # admin bucket only configured for 'suno', not 'image'
    Settings.auth['rate_limits']['admin'] = {
      'suno' => { 'max' => 10, 'window_minutes' => 20 },
    }
    l = RateLimiter.limit_for(CHAT, 'image', role: 'admin')
    assert_equal 1, l['max'], 'falls through to default when admin.image not set'
  end

  def test_member_role_does_not_use_admin_bucket
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 10, 'window_minutes' => 30 },
    }
    l = RateLimiter.limit_for(CHAT, 'image', role: 'member')
    assert_equal 1, l['max']
  end

  def test_per_chat_override_still_wins_for_non_admin
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false,
                 rate_limits: { 'image' => { 'max' => 3, 'window_minutes' => 15 } }.to_json)
    l = RateLimiter.limit_for(CHAT, 'image')
    assert_equal 3, l['max']
  end

  # An explicit per-chat menu edit wins even for admins (previously the admin
  # default silently overrode it — the trap that let super-admins hit limits
  # despite raising the menu value for their own chat).
  def test_per_chat_edit_wins_over_admin_default
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 5, 'window_minutes' => 20 },
    }
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false,
                 rate_limits: { 'image' => { 'max' => 10, 'window_minutes' => 1 } }.to_json)
    l = RateLimiter.limit_for(CHAT, 'image', role: 'admin')
    assert_equal 10, l['max'], 'per-chat menu edit must apply to admins too'
    assert_equal 1,  l['window_minutes']
  end

  # Admin override applies when NO per-chat edit exists.
  def test_admin_default_applies_without_per_chat_edit
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 5, 'window_minutes' => 20 },
    }
    l = RateLimiter.limit_for(CHAT, 'image', role: 'admin')
    assert_equal 5, l['max'], 'no per-chat edit ⇒ admin override applies'
  end

  # Regression guard (prod: cloud_cook / Белоброва seeded image max=2 < admin 5):
  # a RESTRICTIVE per-chat/config-seeded value must NOT drop an admin below the
  # admin override — admins get the more permissive of the two.
  def test_restrictive_per_chat_does_not_lower_admin
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 5, 'window_minutes' => 20 },
    }
    Chat.create!(chat_id: CHAT, title: 't', chat_type: 'group', authorized: true, audio: false,
                 rate_limits: { 'image' => { 'max' => 2, 'window_minutes' => 20 } }.to_json)
    l = RateLimiter.limit_for(CHAT, 'image', role: 'admin')
    assert_equal 5, l['max'], 'admin keeps the higher admin cap, not the restrictive per-chat 2'
    # ...but a regular member in that chat still gets the restrictive per-chat 2.
    assert_equal 2, RateLimiter.limit_for(CHAT, 'image', role: 'member')['max']
  end

  def test_admin_keeps_going_after_regular_cap_hit
    # Default cap = 1; admin cap = 5. After 1 task, regular hits cap, admin doesn't.
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 5, 'window_minutes' => 20 },
    }
    BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, max_attempts: 60,
                           params: '{}')
    assert RateLimiter.exceeded?(CHAT, 'image'),
           'regular member should be exceeded at count=1, max=1'
    refute RateLimiter.exceeded?(CHAT, 'image', role: 'admin'),
           'admin should NOT be exceeded at count=1, admin max=5'
  end

  def test_admin_eventually_exceeded_too
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 3, 'window_minutes' => 20 },
    }
    3.times { BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, max_attempts: 60, params: '{}') }
    assert RateLimiter.exceeded?(CHAT, 'image', role: 'admin')
  end

  def test_minutes_until_free_uses_role_window
    # Older task created within the window; new role-specific window applies.
    Settings.auth['rate_limits']['admin'] = {
      'image' => { 'max' => 1, 'window_minutes' => 60 },
    }
    BackgroundTask.create!(task_type: 'image_generate', chat_id: CHAT, max_attempts: 60, params: '{}')
    mins = RateLimiter.minutes_until_free(CHAT, 'image', role: 'admin')
    # admin's 60-min window > regular 20-min window; admin wait should reflect 60-min
    assert mins.between?(58, 60), "expected ~60 min, got #{mins}"
  end

  def test_reply_uses_role
    # Just ensure reply doesn't blow up with role: kwarg
    Settings.auth['rate_limits']['admin'] = {
      'suno' => { 'max' => 5, 'window_minutes' => 20 },
    }
    BackgroundTask.create!(task_type: 'suno_generate', chat_id: CHAT, max_attempts: 60, params: '{}')
    msg = RateLimiter.reply(CHAT, 'suno', role: 'admin')
    assert_kind_of String, msg
    refute_empty msg
  end
end

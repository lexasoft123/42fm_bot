require_relative 'test_helper'
require_relative '../lib/radio'

# Radio#track / #queue must degrade gracefully when Liquidsoap returns
# blank metadata instead of surfacing "(нет данных)" placeholder lines.
class RadioDegradationTest < BotTest
  # Build a Radio whose private #command is replaced by a router over the
  # given case-block, so no real TCP socket is opened.
  def radio_with(&router)
    r = Radio.new
    r.define_singleton_method(:command, &router)
    r
  end

  def test_track_with_no_metadata_returns_idle_message
    radio = radio_with do |cmd, raw: false|
      cmd =~ /\.remaining/ ? '0' : ''
    end
    assert_equal 'сейчас ничего не играет', radio.track
  end

  def test_track_with_metadata_renders_name_and_remaining
    meta = %(--- 1 ---\nartist="Metallica"\ntitle="One"\n)
    radio = radio_with do |cmd, raw: false|
      cmd =~ /\.remaining/ ? '90' : meta
    end
    result = radio.track
    assert_includes result, 'Metallica — One'
    assert_includes result, 'осталось'
  end

  def test_queue_all_blank_slots_returns_nil
    radio = radio_with do |cmd, raw: false|
      cmd =~ /request\.queue/ ? '5 6' : ''
    end
    assert_nil radio.queue
  end

  def test_queue_drops_blank_slots
    radio = radio_with do |cmd, raw: false|
      case cmd
      when /request\.queue/         then '5 6'
      when /request\.metadata 5/    then %(artist="Nirvana"\ntitle="Lithium"\n)
      else ''
      end
    end
    result = radio.queue
    assert_includes result, 'Nirvana — Lithium'
    refute_includes result, '(нет данных)'
  end

  # Keepalive periodically pings with the status command so the persistent
  # socket never goes stale between user commands.
  def test_keepalive_pings_with_status_command
    pinged = Queue.new
    radio = Radio.new
    radio.define_singleton_method(:command) { |cmd, raw: false| pinged << cmd; '' }
    radio.start_keepalive(interval: 0.01)
    cmd = Timeout.timeout(2) { pinged.pop }
    assert_equal Radio::KEEPALIVE_CMD, cmd
  ensure
    radio.instance_variable_get(:@keepalive)&.kill
  end

  def test_keepalive_is_idempotent
    radio = Radio.new
    t1 = radio.start_keepalive(interval: 60)
    t2 = radio.start_keepalive(interval: 60)
    assert_same t1, t2
  ensure
    radio.instance_variable_get(:@keepalive)&.kill
  end

  # The keepalive loop must survive a raising command (its reliability
  # depends on never dying) — a later ping still arrives after one raises.
  def test_keepalive_survives_raising_command
    pinged = Queue.new
    first  = true
    radio  = Radio.new
    radio.define_singleton_method(:command) do |_cmd, raw: false|
      if first
        first = false
        raise IOError, 'boom'
      end
      pinged << :ok
      ''
    end
    radio.start_keepalive(interval: 0.01)
    assert_equal :ok, Timeout.timeout(2) { pinged.pop }
  ensure
    radio.instance_variable_get(:@keepalive)&.kill
  end
end

require_relative 'test_helper'
require_relative '../lib/radio'

# Radio#track / #queue must degrade gracefully when Liquidsoap returns
# blank metadata instead of surfacing "(нет данных)" placeholder lines.
class RadioDegradationTest < BotTest
  include Fixtures::Songs

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

  def test_queue_empty_when_no_alive_requests
    radio = radio_with { |cmd, raw: false| '' }
    assert_nil radio.queue
  end

  # request.alive lists rotation tracks too; only user requests carry the
  # annotate bot_req="1" tag and should appear in the queue.
  def test_queue_shows_only_tagged_user_requests
    radio = radio_with do |cmd, raw: false|
      case cmd
      when /request\.alive/         then '5 6 7'
      when /request\.metadata 5/    then %(artist="Nirvana"\ntitle="Lithium"\nbot_req="1"\n)
      when /request\.metadata 6/    then %(artist="Rotation"\ntitle="Filler"\nsource="music_txt"\n)
      when /request\.metadata 7/    then %(artist="Metallica"\ntitle="One"\nbot_req="1"\n)
      else ''
      end
    end
    result = radio.queue
    assert_includes result, 'Nirvana — Lithium'
    assert_includes result, 'Metallica — One'
    refute_includes result, 'Rotation — Filler' # untagged rotation track excluded
  end

  def test_queue_nil_when_alive_has_no_user_requests
    radio = radio_with do |cmd, raw: false|
      case cmd
      when /request\.alive/      then '6'
      when /request\.metadata 6/ then %(artist="Rotation"\ntitle="Filler"\nsource="music_txt"\n)
      else ''
      end
    end
    assert_nil radio.queue
  end

  # request push carries the annotate tag so #queue can find it later.
  def test_request_pushes_with_annotate_tag
    metallica(filepath: 'metallica/one.mp3')
    pushed = nil
    radio = radio_with do |cmd, raw: false|
      pushed = cmd if cmd.start_with?('request.push')
      cmd.start_with?('request.push') ? '42' : ''
    end
    radio.request('Metallica')
    assert_includes pushed, 'annotate:bot_req="1":'
  end

  # Regression: ordering a specific title must return THAT title, not a
  # random album-mate. "back in black" matches every track on AC/DC's album
  # "Back in Black", so the old blind songs.sample returned e.g. "Shoot to
  # Thrill". pick_request must prefer the title hit.
  def test_request_prefers_title_over_album_mate
    acdc(album: 'Back in Black')                       # title "Back in Black"
    Song.create!(artist: 'AC/DC', title: 'Shoot to Thrill',
                 album: 'Back in Black', filepath: 'acdc/shoot.mp3')
    radio = radio_with { |cmd, raw: false| cmd.start_with?('request.push') ? '42' : '' }
    # Sample many times: a random pick would eventually return the album-mate.
    20.times do
      name = radio.request('back in black')[:name]
      assert_includes name, 'Back in Black'
      refute_includes name, 'Shoot to Thrill'
    end
  end

  # Token-based matching means a re-ordered title still pins the right track
  # (a substring match would miss this and fall back to random sampling).
  def test_request_reordered_title_still_pins_track
    acdc(album: 'Back in Black')
    Song.create!(artist: 'AC/DC', title: 'Shoot to Thrill',
                 album: 'Back in Black', filepath: 'acdc/shoot.mp3')
    radio = radio_with { |cmd, raw: false| cmd.start_with?('request.push') ? '42' : '' }
    20.times do
      name = radio.request('black back in')[:name]
      assert_includes name, 'Back in Black'
      refute_includes name, 'Shoot to Thrill'
    end
  end

  # A broad/artist query must still return some track (variety preserved —
  # every hit qualifies, so pick_request samples across the whole set).
  def test_request_artist_query_returns_a_track
    acdc(album: 'Back in Black')
    Song.create!(artist: 'AC/DC', title: 'Shoot to Thrill',
                 album: 'Back in Black', filepath: 'acdc/shoot.mp3')
    radio = radio_with { |cmd, raw: false| cmd.start_with?('request.push') ? '42' : '' }
    assert_includes radio.request('ac/dc')[:name], 'AC/DC'
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

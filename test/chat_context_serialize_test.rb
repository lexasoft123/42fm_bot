require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/chat_context'

# ChatContext.serialize_msg shapes the per-message JSON the agent sees in
# the {CONTEXT} placeholder. The `audio: true` flag tells the agent that
# an earlier message has an audio attachment — the bot resolves the
# file_id internally for cover_audio / add_vocals, but the agent needs
# to know the upload exists so it doesn't re-prompt the user.
class ChatContextSerializeTest < BotTest
  CHAT = -88

  # Minimal stub matching the shape serialize_msg expects from the
  # left-joined messages+users SELECT in get_chat_context. Avoids hitting
  # the DB schema at all — these tests are about the JSON shape, not
  # persistence.
  Row = Struct.new(:message_id, :reply_to_message_id, :message_thread_id,
                   :forwarded, :edited_at, :role, :body,
                   :attachment_file_id, :attachment_mime_type,
                   :attachment_title, :attachment_performer, :attachment_duration,
                   :uid, :name, :first_name, :last_name, keyword_init: true) do
    def try(attr); respond_to?(attr) ? send(attr) : nil; end
  end

  def make(role: 'user', body: 'hi', message_id: 1, **attrs)
    defaults = { reply_to_message_id: nil, message_thread_id: nil, forwarded: false,
                 edited_at: nil, attachment_file_id: nil, attachment_mime_type: nil,
                 attachment_title: nil, attachment_performer: nil, attachment_duration: nil,
                 uid: 111, name: 'theuser', first_name: 'F', last_name: 'L' }
    Row.new(message_id: message_id, role: role, body: body, **defaults.merge(attrs))
  end

  def test_audio_flag_set_when_attachment_present
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AAA', attachment_mime_type: 'audio/mpeg'))
    assert_equal true, h[:audio]
  end

  def test_audio_flag_omitted_when_no_attachment
    h = ChatContext.serialize_msg(make)
    refute h.key?(:audio), 'audio key should be omitted (not false) when no attachment'
  end

  def test_audio_flag_omitted_when_attachment_blank_string
    # Defensive: a stale bug could persist a row with empty-string instead
    # of nil — `audio: true` only when there's a real id to resolve.
    h = ChatContext.serialize_msg(make(attachment_file_id: nil))
    refute h.key?(:audio)
  end

  def test_role_user_set_for_user_row
    h = ChatContext.serialize_msg(make)
    assert_equal 'user', h[:role]
  end

  def test_role_bot_set_for_bot_row
    h = ChatContext.serialize_msg(make(role: 'bot'))
    assert_equal 'bot', h[:role]
  end

  def test_who_object_includes_all_present_fields
    h = ChatContext.serialize_msg(make(uid: 663625, name: 'lxbelle',
                                       first_name: 'Alexander', last_name: 'Tarasov'))
    assert_equal({ uid: 663625, username: 'lxbelle',
                   first_name: 'Alexander', last_name: 'Tarasov' }, h[:who])
  end

  def test_who_object_omits_blank_username
    # name='' should not produce {username: ''} — orphan-paren bug regression.
    h = ChatContext.serialize_msg(make(uid: 222, name: '',
                                       first_name: 'MC Boa', last_name: nil))
    assert_equal({ uid: 222, first_name: 'MC Boa' }, h[:who])
  end

  def test_who_object_omits_blank_first_last
    h = ChatContext.serialize_msg(make(uid: 333, name: 'just_a_handle',
                                       first_name: '', last_name: nil))
    assert_equal({ uid: 333, username: 'just_a_handle' }, h[:who])
  end

  def test_who_object_returns_unknown_when_everything_blank
    # uid nil + all names blank → {unknown:true}.
    h = ChatContext.serialize_msg(make(uid: nil, name: nil,
                                       first_name: nil, last_name: nil))
    assert_equal({ unknown: true }, h[:who])
  end

  def test_who_object_strips_whitespace_only_first_name
    h = ChatContext.serialize_msg(make(uid: 444, name: 'u', first_name: '   ', last_name: 'L'))
    assert_equal({ uid: 444, username: 'u', last_name: 'L' }, h[:who])
  end

  def test_who_bot_row_returns_name_object
    # Bot row gets a structurally distinct object; no uid/username — the role
    # field disambiguates, and the bot's own uid isn't a meaningful mention.
    h = ChatContext.serialize_msg(make(role: 'bot'))
    assert_equal({ name: 'Жзяцля' }, h[:who])
  end

  # display_name is shared with Agent::Runner#trigger_user_display so the
  # trigger line and the history `who` agree on every edge case.
  def test_display_name_combined_when_both_present
    assert_equal 'lxbelle (Alex T)', ChatContext.display_name(name: 'lxbelle', first_name: 'Alex', last_name: 'T')
  end

  def test_display_name_username_only
    assert_equal 'lxbelle', ChatContext.display_name(name: 'lxbelle', first_name: nil, last_name: nil)
  end

  def test_display_name_full_name_only
    # Blank username — no leading space + paren regression.
    assert_equal 'Alex T', ChatContext.display_name(name: '', first_name: 'Alex', last_name: 'T')
  end

  def test_display_name_unknown_when_all_blank
    assert_equal 'unknown', ChatContext.display_name(name: '', first_name: nil, last_name: '')
  end

  # audio_meta surfaces title/performer/duration/mime so the agent can
  # name covers after the actual track instead of inventing from prior
  # chat context. Only present when at least one metadata field is set.
  def test_audio_meta_includes_all_present_fields
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AAA',
                                        attachment_mime_type: 'audio/mpeg',
                                        attachment_title: 'Rebreather Romance',
                                        attachment_performer: 'lex',
                                        attachment_duration: 158))
    assert_equal true, h[:audio]
    assert_equal 'Rebreather Romance', h[:audio_meta][:title]
    assert_equal 'lex', h[:audio_meta][:performer]
    assert_equal 158, h[:audio_meta][:duration]
    assert_equal 'audio/mpeg', h[:audio_meta][:mime]
  end

  def test_audio_meta_only_includes_set_fields
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AAA',
                                        attachment_title: 'Just a Title'))
    assert_equal true, h[:audio]
    assert_equal({ title: 'Just a Title' }, h[:audio_meta])
  end

  def test_audio_meta_omitted_when_no_fields_set
    # attachment present but with no title/performer/duration/mime → no meta key.
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AAA'))
    assert_equal true, h[:audio]
    refute h.key?(:audio_meta), 'audio_meta should be omitted when nothing to surface'
  end
end

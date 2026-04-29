module AdminMenu
  # Register `/admin` as a discoverable bot command scoped to each super-admin's
  # private chat. The default Telegram menu button (the "/" icon next to the
  # message input) shows this list, so super-admins can tap-and-pick instead of
  # remembering the slash command.
  #
  # Scoping to BotCommandScopeChat means the command appears ONLY for the
  # super-admin — regular users in other chats see whatever commands the bot
  # has registered globally (currently none). Idempotent: safe to call on every
  # boot. Failures are logged but never propagate (a missing/blocked private
  # chat must not crash startup).
  def self.register_commands(api)
    uids = Settings.auth['super_admin_uids'].to_a
    return if uids.empty?
    uids.each do |uid|
      api.setMyCommands(
        commands: [{ command: 'admin', description: 'Открыть админ-меню' }],
        scope: { type: 'chat', chat_id: uid }.to_json
      )
    rescue => e
      LOGGER.warn "[admin_menu] setMyCommands for uid=#{uid} failed: #{e.class}: #{e.message}"
    end
  end
end

require_relative 'admin_menu/session'
require_relative 'admin_menu/views'
require_relative 'admin_menu/router'
require_relative 'admin_menu/text_input_handler'
require_relative 'admin_menu/callback_handler'

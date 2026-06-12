---
paths:
  - "lib/admin_menu.rb"
  - "lib/admin_menu/*.rb"
  - "lib/commands/admin_menu_open.rb"
  - "lib/access_request.rb"
  - "models/chat.rb"
---

# Admin menu / authorization gotchas

Trap knowledge for the super-admin menu, chat authorization, access requests, and chat labels. Reference: `docs/architecture.md` § Admin menu.

| Task | File |
|------|------|
| Admin menu (super-admin only) | `lib/admin_menu/*.rb` + `lib/commands/admin_menu_open.rb` + `lib/bot_dispatcher.rb`. `/admin` or `бот меню` in private chat from a super-admin opens an inline-keyboard menu to manage authorized chats, per-chat rate limits, and global `users.role`. |
| /start access requests | `lib/access_request.rb` (filed from `BotDispatcher` unauthorized branch, private chats only) + `adm:req_accept`/`adm:req_decline` in `lib/admin_menu/router.rb` + `callback_handler.rb` + `Views.request_resolved` |
| Chat display labels | `Chat.label_from_telegram` (`models/chat.rb`) — title for groups, first/last name + @username for private chats; used by `BotDispatcher` (touch_seen) and the admin menu's `getChat` title backfill (`Views.refresh_titles!`) |

- **Super-admin (`Settings.auth['super_admin_uids']`)** — list of Telegram UIDs that get `/admin` menu access. Set in `config/settings.yml` (gitignored), NOT `settings.common.yml`. Empty list = no super-admins (fail-closed). Distinct from `users.role == 'admin'`: super-admin is the menu-gating list (settings-driven, almost-never-changes), `admin` role is the per-command gate (DB-driven, mutable via menu). At startup `AdminMenu.register_commands` calls `setMyCommands` scoped per super-admin uid so `/admin` shows in their Telegram menu button (the "/" icon next to the input field) — no need to remember the slash command.
- **Super-admin private-chat implicit authorization** — `BotDispatcher#authorized?` short-circuits the `Chat.where(authorized: true)` allowlist for super-admins in private chat. This makes `/admin` work on first deploy without pre-seeding a `chats` row, AND prevents the menu from creating an unrecoverable lock-out. Two further guards in `AdminMenu::CallbackHandler#perform_mutation`: refuse to deauthorize a chat whose `chat_id == any super_admin_uid`; refuse to demote a super-admin's `users.role`.
- **Admin menu `awaiting_input` early-exit** — `MessageResponder#maybe_handle_admin_input` intercepts plain-text from super-admin in private chat ONLY when `AdminMenu::Session.awaiting_input?(uid)` is true. `Session.awaiting_input?` has a built-in 5-min TTL — stale sessions auto-clear on access. `TextInputHandler` itself bypasses on `/cancel` keyword, on any `/`-prefixed slash command, and on `бот`/`жпт`/`балаболь`-prefixed agent triggers — so normal bot use is never locked out by a dangling session.
- Messages from non-whitelisted `chat_ids` are silently dropped in `BotDispatcher` — with ONE exception: `/start` in an unauthorized **private** chat files an access request (`AccessRequest.maybe_handle`): the `chats` row is created (`authorized: false`), the user gets a «заявка отправлена» reply, and every super-admin gets a DM with ✅/❌ inline buttons (`adm:req_accept`/`adm:req_decline`). An existing row (pending OR previously declined) → "already pending" reply, NO admin re-notification (anti-spam). Groups never trigger requests — group authorization stays a deliberate `/admin` menu act.
- **Admin menu chat labels** — legacy config-seeded rows carry the literal title `"unknown"`; `Views.unknown_title?` treats that as missing and falls back to the chat_id. The Чаты list orders `authorized DESC, last_seen_at DESC` (live chats first, dead rows sink) and self-heals titles on render via `getChat` (`Views.refresh_titles!` — **authorized rows only**, and failures never retry per render: a definitive `chat not found` persists a `💀 <chat_id>` title (visible dead-row marker, overwritten by `touch_seen` if the chat comes back with a derivable name — groups always have one), other errors land in an in-process negative cache retried only after restart. Verified on prod: each getChat 400 cost ~1s of whole-bot stall on the single-threaded listen loop — that's why unbounded retry is forbidden here). Private chats get names via `Chat.label_from_telegram` at message time — Telegram private chats have no `.title`, only first/last/username. `Chat.sync_from_config!` skips `name: unknown` config entries so restarts don't re-clobber backfilled titles (`Chat.unknown_title?` is the shared predicate).

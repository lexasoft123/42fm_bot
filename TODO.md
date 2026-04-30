# TODO

This file tracks pending work and parking-lot ideas. New entries land at the top of the relevant section.

## Done

* [x] Add agent tool to get knowledge
* [x] Add agent tool to get phrases
* [x] Refactor Google search
* [x] Add Google search to agent tools
* [x] Add tg reply functionality
* [x] Add telegram Bot interactive interface for admins — Phase 1: super-admin menu (`/admin` in private chat) for managing authorized chats, per-chat rate limits, global `users.role` admins. See `lib/admin_menu/`.

## Pending

* [ ] Latency warn for slow agent iterations. Now that `agent` runs DeepSeek V4 Pro thinking, p95 per-iteration time jumps materially (live probe showed ~7s/iter, sometimes 18s+ on hard tasks). `Agent::Runner` already logs `took=Nms` per iter (lib/agent/runner.rb:54,62) but no threshold-warn. Cheap addition: `LOGGER.warn` if `iter_ms > 15_000` so we have a grep target before users complain. Plan also called out a 25s p95 rollback trigger but that needs an automated signal — simplest is a daily aggregator that grep's `iteration .* took=` and reports p95.

* [ ] Per-chat admin permissions (Phase 2 of the admin menu).
  - **Today**: `users.role == 'admin'` is global — being admin in one chat means admin everywhere.
  - **Want**: per-chat admin assignment so user X can be admin in chat A but not in chat B.
  - **Schema**: either `chats.admin_uids` JSON-array column (matches `chats.rate_limits` pattern) or a `chat_admins` join table.
  - **Refactor**: `Commands::Base#admin?(chat = nil)` consults the per-chat list. The 4 admin commands (`CostReport`, `KnowledgeAdd`, `KnowledgeDelete`, `KnowledgeCompact`) pass chat context (already in `CommandContext`).
  - **Menu**: under chat-detail view, add an "Admins" sub-view listing per-chat admin uids with promote/demote.
  - **Migration**: backfill existing `users.role == 'admin'` into `admin_uids` for all currently-authorized chats.
  - **Trigger**: revisit when granting admin to someone in one chat unintentionally exposes them in another (e.g. `бот затраты` cost report leaking across chats).

* [ ] Temporary artifact storage for the agent — files / texts / scratch state that survives between agent turns within a session, distinct from the long-lived knowledge base and the per-chat scratchpad. Currently the agent re-fetches everything per turn. Open question: does the existing scratchpad already cover this, or do we need a separate ephemeral store with TTL?

* [ ] Admin-menu support for editing `Settings.auth.rate_limits.admin.<svc>` from inside the menu (currently YAML-only).
  - Today: per-chat rate limits are editable via the menu; admin per-role limits live in `settings.common.yml` and require a redeploy to change.
  - Want: a "global limits" sub-view alongside chat-detail showing both default and admin caps; tap to edit.
  - **Caveat**: `Settings` is read-only at runtime (loaded once at boot). Either move admin limits into a DB row (e.g. `chat_states.global_settings`) or accept that menu-edits write the YAML on disk + restart the container. The DB-row path is cleaner.

## Ideas / parking lot

(Speculative, not committed. Promote to Pending when concrete enough to plan.)

* Audit log of admin-menu changes — who flipped which `chats.authorized` and when. Cheap to add: `chat_admin_log` table with `chat_id, actor_uid, action, before_value, after_value, created_at`. Trigger when a misclick or accidental change happens that we can't trace.

* Ramp-up of admin menu actions:
  - Trigger group-chat admin actions (e.g. `/admin` in a group, scoped to that chat only) — requires Phase 2's per-chat admins to be coherent.
  - Authorize brand-new chats (chats the bot has never seen) from inside the menu — requires a way to seed `chats` row before the bot has received any message.
  - Multi-step undo of the last action.

* Replace `setMyCommands` with a Telegram **MiniApp** for the admin menu — richer UI than inline keyboards (proper forms, multi-select, search). Overkill for the current scope but tempting if the menu grows past ~10 views.

* Stem extraction / instrumental cleaning via Suno's `/api/v1/vocal-removal/generate` — separate feature, separate PR.

* Adding vocals to a track from the local music library (`Song` records) — requires a public static-file server on the bot host so Suno can pull the audio.

* Voice-message (OGG/Opus) input to add-vocals / cover-audio — Suno docs only mention MP3/WAV; today we pass through and let Suno reject. Worth adding a transcode step if it turns out to fail often.

* Music video generation via Suno's `/api/v1/create-music-video` — separate feature.

* Staging proxy that strips the bot token from Telegram file URLs before sending them to Suno (currently we leak the bot token in `https://api.telegram.org/file/bot<TOKEN>/<path>` URLs to Suno's logs). Not urgent — same risk profile already exists for voice messages — but eventually worth.

#!/usr/bin/env bash
#
# Hot-snapshot ~/bot/db/bot.db and prune old snapshots, keeping the most
# recent N (default 5; override with the first argument).
#
# Invoked by `make backup` via `ssh bot bash -exs -- $BACKUP_KEEP < bin/backup.sh`
# so it runs remotely on the prod host. Self-contained — can also be run
# standalone on the prod host: `bash backup.sh 10`.
#
# Uses SQLite's online backup API (the `.backup` dot-command) so it's safe in
# WAL mode under concurrent writes — a plain `cp` would miss writes still in
# the -wal file. The resulting .bak is a standalone SQLite DB.

set -euo pipefail

keep="${1:-5}"
cd ~/bot

ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="db/bot.db.bak-${ts}"

sqlite3 db/bot.db ".backup ${dest}"
echo "Created ${dest} ($(stat -c%s "${dest}") bytes)"

# Keep the $keep newest, delete the rest.
ls -1t db/bot.db.bak-* 2>/dev/null \
  | tail -n +$((keep + 1)) \
  | xargs -r rm -f

echo "Retained backups:"
ls -lht db/bot.db.bak-* 2>/dev/null | head -n "${keep}"

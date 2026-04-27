#!/usr/bin/env python3
"""
PreToolUse hook: auto-approve read-only SSH commands to the prod bot host.

Approves: ssh bot@92.241.191.11 'cd ~/bot && (grep|tail|head|cat|less|ls|find|wc|
awk|sed|jq|sort|uniq|cut|tr|xargs|column|sqlite3|bin/inspect|docker compose
logs|docker compose ps|git log|git status|git diff) ...'

Pipes between safe binaries are allowed. Compound commands (`;`, `&&`, `||`),
redirections (`>`, `<`), command substitution (`$(...)`, backticks), unsafe
leading binaries (rm/mv/sudo/wget/...) and SQL writes (DELETE/UPDATE/...) all
defer to the normal permission flow — the user gets prompted as usual.

Exit 0 + no output = defer (preserves existing permissions.allow rules).
Exit 0 + JSON allow decision = skip the prompt, run the command.
"""
import json
import re
import sys


_SSH_RE = re.compile(
    r"^ssh\s+bot@92\.241\.191\.11\s+(['\"])(.*)\1\s*$", re.DOTALL
)

_SAFE_LEAD = re.compile(
    r"""^(
        grep | egrep | fgrep |
        tail | head | cat | less | more |
        ls | find | wc | awk | sed |
        jq | sort | uniq | cut | tr | column |
        sqlite3 | bin/inspect |
        docker\s+compose\s+(?:logs|ps) |
        git\s+(?:log|status|diff)
    )(\s|$)""",
    re.VERBOSE,
)

_SQL_WRITE = re.compile(
    r"\b(DELETE|UPDATE|INSERT|DROP|ALTER|TRUNCATE|REPLACE|CREATE|"
    r"VACUUM|ATTACH|PRAGMA|REINDEX|BEGIN|COMMIT|ROLLBACK|SAVEPOINT)\b",
    re.IGNORECASE,
)
_SQL_SELECT = re.compile(r"\bSELECT\b", re.IGNORECASE)
_QUOTED_ARG = re.compile(r"\"[^\"]*\"|'[^']*'")


def decide(cmd: str):
    """Return an allow-decision dict, or None to defer to normal permissions."""
    m = _SSH_RE.match(cmd)
    if not m:
        return None
    inner = m.group(2)
    inner = re.sub(r"^cd\s+~/bot\s*&&\s*", "", inner)

    unquoted = _strip_quoted(inner)

    # Block redirection, command substitution outside quotes
    if re.search(r"[><]|\$\(|`", unquoted):
        return None
    # Block docker/git non-read subcommands
    if re.search(r"\bdocker\s+compose\s+(?!logs|ps)\b", unquoted):
        return None
    if re.search(r"\bgit\s+(?!log|status|diff)\b", unquoted):
        return None
    # No top-level shell chaining — only pipes are allowed
    if len(_split_top(inner, [";", "&&", "||"])) > 1:
        return None

    # Every pipe segment must lead with a safe binary
    for seg in _split_top(inner, ["|"]):
        seg = seg.strip()
        if not seg or not _SAFE_LEAD.match(seg):
            return None
        if seg.startswith("sqlite3") and not _sqlite3_segment_safe(seg):
            return None
        if seg.startswith("find") and re.search(
            r"\s-(?:exec|execdir|delete|fprint|fprintf|fls)\b", seg
        ):
            return None
        if seg.startswith("awk") and re.search(r"\bsystem\s*\(", seg):
            return None

    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "read-only ssh to prod (auto-approved)",
        }
    }


def _sqlite3_segment_safe(seg: str) -> bool:
    """sqlite3 must have an inline SQL arg; it must contain SELECT and no
    write keywords. Forbids stdin-fed SQL (e.g. `cat x.sql | sqlite3 db`)."""
    quoted = _QUOTED_ARG.findall(seg)
    if not quoted:
        return False
    sql = " ".join(quoted)
    if not _SQL_SELECT.search(sql):
        return False
    if _SQL_WRITE.search(sql):
        return False
    return True


def _split_top(s: str, ops: list) -> list:
    """Split s on `ops` outside of single/double quotes."""
    parts, buf, i, q = [], "", 0, None
    while i < len(s):
        c = s[i]
        if q:
            buf += c
            if c == q:
                q = None
            i += 1
            continue
        if c in ("'", '"'):
            q = c
            buf += c
            i += 1
            continue
        matched = False
        for op in ops:
            if s.startswith(op, i):
                parts.append(buf)
                buf = ""
                i += len(op)
                matched = True
                break
        if matched:
            continue
        buf += c
        i += 1
    parts.append(buf)
    return parts


def _strip_quoted(s: str) -> str:
    return _QUOTED_ARG.sub("", s)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    cmd = (data.get("tool_input") or {}).get("command", "")
    decision = decide(cmd)
    if decision is not None:
        print(json.dumps(decision))
    sys.exit(0)


if __name__ == "__main__":
    main()

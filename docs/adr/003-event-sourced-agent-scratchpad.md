# ADR-003: Event-Sourced Agent with Per-Chat Scratchpad

**Status:** Accepted
**Date:** 2026-04-26
**Updated:** 2026-04-26 — PR-1 (foundation) shipped: `chat_states` table, `Agent::Scratchpad` module, `remember`/`forget` tools, runner integration with `{SCRATCHPAD}` placeholder. PR-2 (event sources) and PR-3 (compaction + cron) still pending.

## Context

Today's agent is per-message, stateless, and reactive only to user input:

- `MessageResponder` matches a `бот <text>` message → `Agent::Runner.run` → returns text → exits.
- Background tasks (FLUX, Suno) run in `TaskRunner` and deliver results directly to the chat. The agent never sees those outcomes.
- Knowledge base (`KnowledgeBase`) holds long-term facts but is not the agent's *working memory* — there is no place for "I'm waiting for task 680 to finish so I can comment on the result" or "user said they'd report back about the meal — bring it up if they don't."

This means:

- Agent can't react to task failures with personality (apologize, joke, retry with adjusted prompt).
- Agent can't carry intentions across turns ("compose 3 songs" — done #1, working on #2).
- Agent can't be triggered by non-message events (cron, webhook, task completion).
- Every turn re-derives state from raw chat history, paying for tokens that an explicit memory could compress.

The user wants a path to address these without a multi-week rewrite.

## Options Considered

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A. Continuous global agent loop** | One thread, event queue, processes events serially | Most "agent-like" UX, supports proactive timer-based behavior | Cost explosion if poll-based; serializes all chats; large rewrite |
| **B. Per-chat agent loops** | One thread per authorized chat | Isolated, parallel | ~30 threads, lifecycle complexity, resource cost |
| **C. Event-sourced (event-triggered, no loop)** | Reuse `TaskRunner`; new `agent_event` task type fires the agent on any event (user msg, task done, cron) | Cost-bounded by event rate; reuses worker pool from ADR-002; incremental migration | No proactive *time-based* behavior unless we add a cron source |
| **D. Reactor pattern (single thread + event types)** | One thread, switch on event type | Deterministic, testable | Same serialization bottleneck as A |

## Decision

**Adopt variant C — event-sourced agent with per-chat scratchpad.**

Rationale:

- Captures ~80% of the value of a continuous loop (agent reacts to task results, has memory across turns, supports new event sources) at ~20% of the migration cost.
- Reuses the `TaskRunner` worker pool shipped in 2026-04-24 (the bounded `Concurrent::ThreadPoolExecutor`).
- Migration is incremental: ship plumbing first, wire one event source at a time, keep the existing per-message path for normal chat.
- Cost stays bounded — the agent fires only on real events, not on a timer.
- Every step is reversible: deleting the new task type and the `chat_states` row reverts to today's behavior.

## Architecture

### Three-layer state model

| Layer | Source | What it is | Status |
|---|---|---|---|
| **1. Chat history** | `messages` table, last ~50 rows via `ChatContext.get_chat_context` | What was *said* | existing |
| **2. Knowledge** | `knowledge` table + RAG via `KnowledgeBase.search` | *Facts* about chat/users | existing |
| **3. Scratchpad** | new `chat_states` table, JSON column | Agent's *working memory* — plans, intentions, expectations | **new** |

The scratchpad is fundamentally different from knowledge: knowledge is facts about the world, scratchpad is the agent's reflection on its own intentions.

### Storage schema

```sql
CREATE TABLE chat_states (
  chat_id    BIGINT PRIMARY KEY,
  scratchpad TEXT   NOT NULL DEFAULT '{}',
  updated_at TIMESTAMP NOT NULL
);
```

Single JSON column. Atomic updates per chat. Permissive layout to start, formalize as patterns emerge:

```json
{
  "intentions":    [{"id": "int-001", "content": "Wait for task 680, comment on outcome",
                     "created_at": "...", "status": "open"}],
  "notes":         [{"id": "note-001", "content": "..."}],
  "expectations":  [{"id": "exp-001", "content": "user said they'd report back about meal"}]
}
```

Hard cap: 1500 tokens per scratchpad. Compaction job (mirrors `KnowledgeBase.compact!`) runs periodically.

### How a turn's input is assembled

```
fn build_turn_input(chat_id, event):
  parts = [
    system_prompt,                            # cached
    Layer 1: chat_history(chat_id, n=50),     # existing
    Layer 2: knowledge_relevant(query, k=3),  # existing RAG
    Layer 3: scratchpad(chat_id),             # NEW: full read of chat_states.scratchpad
    recent_events_since_last_user_msg,        # NEW: e.g. "Task 680 failed", "Suno ready"
    event,                                    # the triggering event itself
  ]
  GptMaster.new(parts, setting: 'agent').call_raw(tools: ...)
```

Layers 3-5 land *after* the cache break since they vary per chat / per event. The cached system prefix doesn't grow.

### Scratchpad update mechanism

Hybrid approach:

1. **Explicit tools** — agent calls `remember(category, content, expires_at:)` and `forget(id)` when it consciously decides to track something. Auditable, debuggable.
2. **Lightweight delta-section** — agent's response can include `<scratchpad-delta>{...}</scratchpad-delta>`. Parsed and applied. Visible reply still sent if delta is malformed.

Rejected: passive post-turn extraction (extra LLM call per turn = ~$0.01 × 200 turns/day = doubles the agent cost), structured-output-only (one parse error breaks both reply and state).

### New event sources

Each event becomes a `BackgroundTask(task_type: 'agent_event', params: {...})`. `AgentEventHandler` runs `Agent::Runner.run` with the event payload as context.

- **`task_completed`** — image_gen / suno handlers emit one when outcome is "interesting" (failure after retries, success after retries, NOT first-try success — avoids spam).
- **`cron_tick`** — periodic enqueuer (daily digest, expectation expiry check).
- **`external_signal`** — webhook / queue listener (future).

### Loop protection

- `agent_event` tasks do **not** themselves emit `agent_event` follow-ups. Single-hop only.
- Per-chat rate limit: max 10 `agent_event` per hour. Misbehaving event source can't burn budget.
- Agent's own messages don't generate events — only external triggers do.

## Trade-offs

- **Cost**: agent fires on real events only. Failures are <5% of background tasks → maybe 5–10 extra agent calls/day at current volume. Negligible. Time-based proactivity needs a cron source which is opt-in per use case.
- **Serialization**: all `agent_event` tasks share the `TaskRunner` worker pool with image_gen / suno_generate. With `MAX_WORKERS=2` (today), this is fine; bump to 4 if it bottlenecks.
- **State contention**: scratchpad is per-chat, one row per chat. SQLite + WAL handles concurrent reads. Writes are rare (~per turn).
- **Debug surface**: harder than today (event sequences vs single request-response). Mitigated by NDJSON `gpt.log` (already shipped) plus `[AGENT] event=task_completed` log lines.
- **Schema migration risk**: scratchpad schema starts permissive (free-form JSON). When patterns solidify, formalize. Don't pre-architect.

## Consequences

### Positive

- Agent reacts to task failures with personality (apologize, retry, joke).
- Agent can carry multi-turn intentions ("compose 3 songs in different styles").
- New event sources are uniform: emit a `BackgroundTask`, the agent handles it.
- Reuses existing `TaskRunner` worker pool (ADR-002 + 2026-04-24 parallelization).
- Migration is incremental and reversible.
- Every layer is observable: `chat_states.updated_at`, agent_event task rows in `background_tasks`, `gpt.log`.

### Negative

- Adds a new persistence surface (`chat_states` table) to maintain.
- Agent's behavior is harder to reason about — it can react to events the user didn't trigger.
- Sparse-event chats lose Anthropic's 5-min ephemeral cache more often. Mitigation: switch to 1-hour cache for the system block (separate decision, ADR-005 candidate).

### Risks

- **Spam**: agent posts unsolicited messages users didn't ask for. Mitigation: tight word-limit hint in `agent_event` system addition; rate limit; trigger-criteria table that excludes first-try successes.
- **Loop**: agent's reply triggers another event triggering another agent run. Mitigation: depth=1 cap (no `agent_event` from another `agent_event`).
- **State drift**: agent and human disagree about scratchpad. Mitigation: human-readable scratchpad available for inspection via `бот память` (admin command, future).

## Migration

Three-PR rollout:

1. **PR-1 (foundation, no behavior change)**:
   - Migration `db/migrate/NNN_create_chat_states.rb` — table only.
   - `lib/agent/scratchpad.rb` — read/write helpers, JSON validation, size cap.
   - `Agent::Runner.run` reads scratchpad, prepends to user content, writes back unchanged. Behavior identical.
   - Add `remember` and `forget` tools. Agent can call them, but no event sources yet.
2. **PR-2 (first event source)**:
   - `agent_event` task type + `AgentEventHandler`.
   - Wire FLUX/Suno failure paths to emit `agent_event`. Validate the followup loop, scratchpad rate-limit, depth cap.
3. **PR-3 (compaction + cron)**:
   - Scratchpad compaction job.
   - `cron_tick` event source for time-based proactivity (e.g. daily digest at 09:00).

Each PR is independently deployable and reversible.

## Verification (per PR)

- **PR-1**: `make test`. Unit-test scratchpad read/write/cap. Issue normal chat messages — behavior unchanged.
- **PR-2**: trigger a FLUX failure (e.g. moderated prompt). Confirm `agent_event` task created, agent posts a follow-up reply, scratchpad updated with mention of the failure. Confirm a successful first-try image does NOT trigger a follow-up.
- **PR-3**: confirm cron tick fires; confirm scratchpad compaction runs and merges near-duplicate intentions; confirm both stay under the 1500-token cap.

## Alternatives Considered (rejected)

- **Synchronous wait** — agent blocks until task completes. Breaks the bot's pipeline; 5+ min Suno tasks lock the agent thread.
- **Synthetic Message row only (no proactive trigger)** — agent only reacts when user types again. User might give up before next turn.
- **Trigger followup on every outcome** — first-try successes don't need commentary; spam.
- **Predeclare action at submission ("if fail, retry")** — rigid; can't adapt to actual failure type.
- **Continuous loop (variant A)** — covered above. Cost/complexity > benefit at our scale.

## Out of Scope (deferred)

- 1-hour Anthropic cache for sparse-event chats.
- Cross-chat scratchpad (probably never — friend groups are intentionally isolated).
- Per-user scratchpad (fits inside chat scratchpad as a `users` subkey).
- UI for inspecting scratchpad (`бот память`).

# ADR-001: Agent Mode — LLM Tool-Use for Autonomous Bot Actions

**Status:** Accepted
**Date:** 2026-03-22
**Updated:** 2026-03-22 — multi-provider config, separate agent model

> **Superseded 2026-04-17:** the `chat_gpt.agent_mode` toggle has been removed and agent mode is now the only mode. `Commands::ReplyYou` and `GptMaster.chat` (the non-agent code paths) are gone. The rest of the ADR is retained for historical context; the architecture it describes is still accurate minus the toggle.

> **Updated 2026-04-30:** the `chat_gpt.settings` layout in this ADR (`main` / `agent` / `embedder`) has evolved. `main` was deprecated; current settings are `agent` (DeepSeek V4 Pro by default, with thinking-mode enabled), `agent_vision` (xAI grok-4-fast-reasoning — auto-picked when an image is attached; switched off Anthropic 2026-04-30 for less restrictive named-people image descriptions; bumped from `non-reasoning` later same day after the non-reasoning variant was caught hallucinating `🎨 <caption>` image replies as plain text instead of invoking generate_image — `Agent::Runner` also got a watchdog that catches that pattern at exit and re-loops with a nudge), `knowledge` (DeepSeek), `lyrics` (DeepSeek), and `embedder`. `GptMaster#build_body` translates Anthropic-shape vision blocks to OpenAI-shape `image_url` for any openai-compat provider, so callers stay shape-agnostic. The "two-level providers/settings" pattern from this ADR is unchanged; only the named-setting roster has grown. `GptMaster.ask` defaults `setting: 'main'` for the kwarg, but `main` is no longer defined — any forgotten caller fails loudly. See [docs/architecture.md](../architecture.md) for the current settings shape.

## Context

The bot has multiple services (radio control via Liquidsoap, weather, Google search, knowledge base, horoscope) accessible only through hardcoded command patterns. When a user writes `бот <text>`, the GPT handler generates a text-only response — it cannot interact with any of these services. This means GPT cannot answer questions like "what's playing on the radio?" or "put on some Metallica" even though the bot already has the infrastructure to do so.

The user experience is fragmented: explicit commands (`!трек`, `!погода Москва`) work but feel mechanical, while the GPT chat mode is conversational but blind to the bot's capabilities.

## Decision

Implement an **agentic tool-use loop** that allows the LLM to autonomously call bot services within a single user request. The architecture follows the standard LLM function-calling pattern:

1. User sends a message matching `бот <text>`
2. The message, chat context, knowledge, and a **tool definitions list** are sent to the LLM
3. If the LLM responds with tool calls → execute them, feed results back, repeat
4. If the LLM responds with text → return as final response
5. Safety cap at 5 iterations to prevent runaway loops

### Key design choices

**Agent mode as a toggle, not a replacement.** A `chat_gpt.agent_mode: true/false` setting in `config/settings.yml` controls whether `GptChat`/`GptQuestion` use the agent loop or the old direct `GptMaster.chat` path. This allows instant rollback without code changes if agent mode causes issues in production.

**Multi-provider configuration.** `chat_gpt` section uses a two-level config:
- `providers` — API credentials and type (anthropic, openai, deepseek, etc.)
- `settings` — named configurations (`main`, `agent`, `embedder`) that reference a provider + model

This allows mixing providers and models for different purposes. For example, a cheaper/faster model (e.g., `claude-haiku-4-5`) for agent tool-calling iterations, while the main chat uses a smarter model (e.g., `claude-sonnet-4-6`). `GptMaster.resolve_setting(name)` merges provider credentials with setting config into a flat hash.

```yaml
chat_gpt:
  providers:
    anthropic:
      api_key: sk-ant-...
      api_type: anthropic
    openai:
      api_key: sk-...
      api_type: openai
  settings:
    main:              # GptMaster.chat / .ask
      provider: anthropic
      model: claude-sonnet-4-6
      max_tokens: 16000
    agent:             # Agent::Runner tool-calling loop
      provider: anthropic
      model: claude-haiku-4-5
      max_tokens: 4096
    embedder:          # EmbeddingService
      provider: openai
      model: text-embedding-3-small
```

**Tool registry pattern.** Tools are defined declaratively via `Agent::ToolRegistry.register(name:, description:, parameters:, handler:, admin_only:)` in separate files under `lib/agent/tools/`. Each handler is a lambda receiving `(args, ctx)` where `ctx` provides access to `radio`, `chat_id`, and `user`. This mirrors the existing command registry pattern and makes adding/removing tools trivial.

**Runner owns provider abstraction.** `Agent::Runner` handles the differences between Anthropic and OpenAI tool-calling wire formats (tool definitions, response parsing, result message formatting). It resolves `api_type` from the `agent` setting at initialization. `GptMaster` gained a `call_raw(tools:)` method that returns the raw parsed API response — it does not know about tool execution or the agentic loop.

**Existing commands unchanged.** Specific commands (`!трек`, `бот погода`, `бот найди`) still match first in the registry. Agent mode only activates for freeform `бот <text>` that falls through to `GptChat`. This means explicit commands remain fast (no LLM call) while conversational requests gain tool access.

**Admin-only tools.** Tool definitions are filtered by user role at definition time (admin-only tools are not sent to the LLM for non-admin users) AND checked again at execution time as a safety belt.

## Architecture

```
lib/agent/
├── tool_registry.rb      # ToolDef struct, register/find/definitions_for(api_type:)
├── runner.rb             # Agentic loop, provider format handling, uses setting: 'agent'
└── tools/
    ├── radio.rb          # 8 tools: track, queue, search, request, listeners, history, meta, remove
    ├── weather.rb        # 1 tool: weather by city
    ├── google_search.rb  # 1 tool: web search
    ├── knowledge.rb      # 3 tools: search, add (admin), delete (admin)
    └── horoscope.rb      # 1 tool: horoscope by username
```

### Configuration resolution

```
GptMaster.new(messages, setting: 'agent')
  → GptMaster.resolve_setting('agent')
    → chat_gpt['settings']['agent']  →  { provider: 'anthropic', model: 'claude-haiku-4-5', ... }
    → chat_gpt['providers']['anthropic']  →  { api_key: '...', api_type: 'anthropic', api_url: '...' }
    → merged: { api_key, api_url, api_type, model, max_tokens, thinking_budget }
```

### Request flow (agent_mode: true)

```
GptChat.execute
  → Agent::Runner.new(text:, context:, knowledge:, radio:, chat_id:, user:)
    → resolve api_type from 'agent' setting
    → build prompt from agent_prompt template
    → ToolRegistry.definitions_for(user_role:, api_type:)  # filtered, provider-formatted
    → loop (max 5):
        GptMaster.new(messages, setting: 'agent').call_raw(tools:)
        extract_tool_calls(raw)     # provider-specific parsing
        if no tool calls → extract_text → return
        execute each tool via handler lambda
        append assistant + tool_result messages
    → if max iterations hit → final GptMaster#call without tools
  → save_bot_reply + CommandResult.text
```

### Provider format differences

| Aspect | Anthropic | OpenAI |
|--------|-----------|--------|
| Tool definitions | `{name, description, input_schema}` | `{type: "function", function: {name, description, parameters}}` |
| Tool call in response | `content: [{type: "tool_use", id, name, input}]` | `tool_calls: [{id, function: {name, arguments}}]` |
| Tool result message | `{role: "user", content: [{type: "tool_result", tool_use_id, content}]}` | `{role: "tool", tool_call_id, content}` |
| Arguments format | Parsed hash | JSON string (needs `JSON.parse`) |

### Which setting is used where

| Caller | Setting | Purpose |
|--------|---------|---------|
| `GptMaster.chat` | `main` | Regular GPT chat responses |
| `GptMaster.ask` | `main` | Translation, knowledge extraction |
| `Agent::Runner` | `agent` | Tool-calling iterations (can use cheaper/faster model) |
| `EmbeddingService` | `embedder` | Text embeddings for knowledge base RAG |

## Consequences

### Positive

- GPT can now answer questions about live radio state, weather, and search results conversationally
- GPT can chain actions (search → request a track) in a single user interaction
- Adding new tools requires only a new file in `lib/agent/tools/` with a `register` call
- Toggle allows safe production rollout and instant rollback
- Existing explicit commands are unaffected — no regression risk
- Cheaper model for tool-calling reduces cost while maintaining quality for final responses
- Multi-provider config allows mixing Anthropic, OpenAI, DeepSeek, etc. without code changes

### Negative

- Each agent call may make 2-6 LLM API calls (initial + per tool iteration), increasing latency and cost
- Tool result truncation (2000 chars) may lose information from large responses (e.g., long radio history)
- Anthropic overloaded errors (529) during the loop can leave the conversation mid-tool-call, returning the fallback response
- The LLM may occasionally call tools unnecessarily for questions it could answer directly

### Risks

- **Runaway loops**: Mitigated by MAX_ITERATIONS=5 cap and final forced text response
- **Unauthorized actions**: Mitigated by dual filtering (definition-time + execution-time admin checks)
- **Cost**: Each tool iteration is a full LLM call. Using a cheaper agent model helps. Monitor usage, potentially add per-user rate limiting later
- **Radio socket concurrency**: Not a concern — single-threaded within one message processing
- **Provider config errors**: `GptMaster.resolve_setting` raises immediately on unknown setting/provider names, failing fast at startup

## Alternatives Considered

**Prompt-only approach (no tool calling).** Inject service data into the prompt upfront (e.g., always include current track info). Rejected because: it wastes tokens when not needed, can't handle dynamic queries ("search for X"), and doesn't support actions (requesting tracks).

**Multi-turn conversation state machine.** Track conversation steps across multiple user messages. Rejected because: much higher complexity, requires new DB tables for state, and tool-calling within a single turn already covers most use cases.

**Separate `/agent` command.** Keep `бот <text>` as simple GPT and add a new trigger for agent mode. Rejected because: it fragments the user experience and the toggle setting achieves the same goal of controlled rollout.

**Single model for all purposes.** Use the same model for chat, agent, and embeddings. Rejected because: tool-calling iterations are mostly intent recognition and don't need the smartest model. A cheaper/faster model for agent iterations reduces cost and latency while the main model handles final user-facing responses.

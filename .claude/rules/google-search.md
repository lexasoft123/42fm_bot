---
paths:
  - "lib/gogolmogol.rb"
  - "lib/agent/tools/google_search.rb"
  - "lib/agent/tools/fetch_page.rb"
---

# Google search gotchas

Reference: `docs/architecture.md` § Gogolmogol.

- Google API keys are a pool in settings — `gogolmogol.rb` cycles through them
- **`google_search` intent is explicit:** the agent passes `media_type: 'text'|'photo'|'gif'` on every call (JSON-Schema enum, all tool params are auto-required). No query-string regex sniffing; `Gogolmogol.new(query, media_type:)` uses the intent directly to set `searchType=image` + `fileType=gif`. `download_results` includes an SSRF guard — http(s) only, no loopback/private/link-local literal IPs (DNS-based + redirect-target rebinding are residual risks). Tool file holds Telegram coupling (`sendMediaGroup` / `sendAnimation`); Gogolmogol stays Telegram-unaware.

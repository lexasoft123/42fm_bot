---
paths:
  - "lib/image_gen.rb"
  - "lib/image_gen/*.rb"
  - "lib/model_provider_client.rb"
  - "lib/task_handlers/image_gen_handler.rb"
  - "lib/agent/tools/image_gen.rb"
  - "lib/agent/tools/award.rb"
---

# Image generation gotchas

Trap knowledge for the image-gen adapter layer (FLUX / Atlas Cloud / CloseRouter Nano Banana Pro). Reference: `docs/architecture.md` § Image generation.

| Task | File |
|------|------|
| Image generation (FLUX / Atlas Cloud / CloseRouter Nano Banana Pro) | `lib/image_gen/*.rb` + `lib/model_provider_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` (agent-only, no direct command) |
| Auto-awards (🏆 images) | `lib/agent/tools/award.rb` (`make_award`) → `image_generate` task with `award: true`; caption via `ImageGenTaskHandler#caption_for` (shared by sync + async delivery) |

- Image generation is agent-only — the `generate_image` agent tool creates an `image_generate` background task (no direct `бот нарисуй` command). The handler's prompt-enrichment LLM step uses the active adapter's `prompt_template(:text_to_image|:edit)`.
- **Per-request model selection** — `generate_image` has a `model` enum; the agent picks a catalog key. `ImageGen::Catalog` (`lib/image_gen/catalog.rb`, backed by config `image_gen.models`) maps key→`{provider, t2i, edit, desc}`. The handler picks the adapter **by the entry's provider** (not just `current_adapter`), validates it against `ImageGen::ADAPTERS` (unknown provider → re-resolve to `default_model` so adapter+model id stay coherent), snapshots both `provider` and `model` into params, and threads the provider-specific id into `adapter.submit(model:)` (nil ⇒ adapter's configured default). Missing/invalid key → `image_gen.default_model`. `edit: false` entry → edit falls back to the adapter's `image_edit_model`.
  - **Lazy enum (load-order trap):** Settings is NOT loaded when tools are required (`boot.rb` requires `message_responder` → tools before `app_configurator` runs `Settings.load!`). So the `model` enum/description can't be in the static `parameters:` hash — the tool uses `enum_source`/`desc_suffix_source` **lambdas** resolved in `ToolRegistry.definitions_for` (per-turn, at runtime). `ToolRegistry.build_properties` strips those internal keys and `optional:` from the emitted JSON schema; `required` now excludes `optional: true` params (was a latent "all params required" bug).
  - **model_name interpolation:** the Atlas prompt templates are de-hardcoded to `%{model_name}`. The handler passes `model_name:` on **every** interpolation path (incl. `make_award` tasks with no `model` key → `'AI image generator'`) because Ruby `String#%` raises `KeyError` on a missing referenced key.
- **Image-gen adapter dispatch** — `Settings.image_gen['provider']` selects the backend for legacy/no-model tasks (`'flux'` | `'atlas'` | `'closerouter'`). `ImageGen.current_adapter` is read on submit for those; catalog-keyed tasks call `adapter_for(entry_provider)`. The chosen `adapter.name` is snapshotted into `task.params['provider']`; `ImageGen.adapter_for(provider)` is read on poll, so a config flip (e.g. `docker compose up -d --build` mid-flight) doesn't reroute polling to a different prediction id space — old tasks continue against the original backend, new tasks go to the new one.
- **Synchronous image adapters** — `Adapter#synchronous?` predicate (defaults `false`). When `true`, `#submit` returns a terminal result Hash (`{url:, completed:true}`) instead of an external_id String; `ImageGenTaskHandler` short-circuits the poll cycle in `deliver_sync_result` and marks the task done in one call. `#poll_once` raises `NotImplementedError` if reached. Only `CloseRouterImgAdapter` is sync today (CloseRouter's `/v1/images/generations` returns the result in the same response). Flux + Atlas stay async.
- **`ModelProviderClient`** (`lib/model_provider_client.rb`) — generic Bearer+JSON HTTP client (formerly `AtlasClient`). `POST` raises on non-2xx; `GET` returns `[code, body]` and swallows transient SSL/timeout. Constructor takes a config dict + `tag:` for greppable logs (`'AtlasImg'` / `'CloseRouterImg'` / future `'CloseRouterVideo'`). Reusable by any future Bearer-token, JSON-body model provider.
- **Image-gen settings** in `config/settings.common.yml` under `image_gen:` block (`provider` + `providers.atlas` + `providers.flux` + `providers.closerouter`); api_keys in `config/settings.yml`. `FluxAdapter` has a one-release back-compat shim that reads top-level `Settings.flux` if `image_gen.providers.flux` is missing — removed once prod settings.yml is migrated. CloseRouter's `providers.closerouter` has `text_to_image_model: 'google/nano-banana-pro'` + `image_edit_model: 'google/nano-banana-pro-edit'` (separate model ids — edit is not a parameter on the base model).
- FLUX API settings: top-level `flux:` block in `settings.yml`/`settings.common.yml` is the legacy location read by FluxAdapter's back-compat shim. New canonical location is `image_gen.providers.flux.{api_url,api_key,model}`.
- **Award captions** — `ImageGenTaskHandler#caption_for` is the single caption builder for BOTH delivery paths (sync CloseRouter + async Flux/Atlas); `award: true` params → `🏆` prefix.

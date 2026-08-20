---
paths:
  - "lib/knowledge_base.rb"
  - "lib/knowledge_base/*.rb"
  - "lib/embedding_service.rb"
  - "lib/embedding_cache.rb"
  - "models/knowledge.rb"
  - "models/knowledge_subject.rb"
  - "models/knowledge_compact_log.rb"
  - "lib/commands/knowledge_*.rb"
  - "lib/task_handlers/knowledge_review_handler.rb"
  - "lib/agent/tools/knowledge.rb"
---

# Knowledge base / embeddings gotchas

Reference: `docs/architecture.md` § KnowledgeBase / § EmbeddingCache / § EmbeddingService.

## Storage

- Embeddings live in `embedding_blob` — packed float32 via `Array#pack('f*')`, ~6 KB/row. The legacy `embedding` TEXT column (JSON, ~29 KB/row) is dual-written while `knowledge.dual_write_legacy` is on and read only as a fallback.
- **Never write packed bytes to `embedding`.** AR 7.2 + sqlite3 2.x raise `Encoding::UndefinedConversionError` binding an ASCII-8BIT string with high bytes to a `text` attribute. That is why migration 023 added a separate `binary` column instead of reusing the old one.
- `pack('f*')` is **native-endian** and must stay paired with `Numo::SFloat.from_binary`, which is also native. Restoring `bot.db` onto a big-endian host would misread; recovery is a re-run of `rake knowledge:pack_embeddings`.
- Dual-write is the rollback path for 023: with it off, facts created after the deploy exist only in the new format, so `git revert` would silently make them unsearchable. Flip it off only after `rake knowledge:verify_embeddings` passes; then `rake knowledge:drop_legacy_embeddings` (which refuses while any row still has JSON but no blob) and `VACUUM`.

## EmbeddingCache

- Invalidation is an **`after_commit` callback on `Knowledge`**, not discipline at each call site — a stale cache means silently wrong search results. `update_all` / `delete_all` / raw SQL bypass it. The offline backfill deliberately uses `update_all` (storage format changes, vector values don't).
- `after_commit` fires **only in the writing process**. `rake knowledge:compact` and `bin/console` mutate `knowledge` from a separate process, so a running bot keeps serving its already-built matrix until its next in-process write to that chat: merged facts stay invisible and result pages silently shorten. Deleted rows can't resurrect (`search` re-loads the top-K by id), but **restart the bot after any out-of-process knowledge mutation**. `rake knowledge:compact` prints a reminder.
- **`EmbeddingCache.fetch` must never block.** The per-chat build lock uses `try_lock`, never `synchronize`: `fetch` is reached from `bot.listen`'s single-threaded loop as well as the extraction `Thread`, TaskRunner and CronScheduler, and a cold build on the legacy JSON path takes ~1.7 s. A thread that loses the race builds its own copy instead of waiting.
- Any test that writes `Knowledge` rows must call `EmbeddingCache.reset_for_test!` in `setup`/`teardown` — the per-test transaction rollback otherwise leaves a cache built from rolled-back rows.
- Rows whose embedding length differs from the chat's modal length are dropped and warned about. `Numo`'s `cast` silently zero-pads ragged arrays, so a change of embeddings model would otherwise corrupt every score with no error.
- Norms are clamped (`maximum(norms, 1e-12)`): a stored zero-norm vector used to yield `NaN`, and `NaN` makes `sort_by` raise `ArgumentError` deep inside `search`.

## Dedup

- **One pipeline, one deleting actor.** `Cluster` proposes candidates, `Review` judges and applies. Nothing else deletes facts. `compact!`/`merge_cluster` and the `knowledge_compact` task type are gone; `KnowledgeBase.review!` replaces them.
- **There is no write-time dedup gate.** The old `similar_exists?` rejected only above 0.92 cosine; measured over all 18.8M pairs of the prod main chat the maximum similarity between any two facts is **0.6994**, so it never fired once. Deleted. Don't reintroduce a threshold gate without measuring the corpus first.
- **Two similarity spaces, never mixed in one clustering pass.** G1 is raw cosine at 0.66; G2 is the per-person centroid-removed residual at 0.55. The pairs G2 exists to find sit at *raw* cosine 0.58–0.66, so any raw-space admission test silently discards them — which looks like "fewer clusters", not like an error. Cluster each space separately and union the resulting **clusters**, never the pairs.
- **G2 emits first and claims its facts**; G1 runs over the remainder. That is what guarantees a fact never lands in two clusters, so no merge operates on a row another merge already soft-deleted.
- `subject_min_residual` ships at 0.0 (disabled) because the measured residual-norm distribution on prod is min 0.64 / p10 0.73 / median 0.81 — nothing sits near a centroid. That is a measurement, not an oversight; `rake knowledge:cluster_preview` prints the distribution to re-check it.
- **G2 is the productive generator, and it is deliberately loose.** Measured against the real judge: G2 supplied 9.7% of candidates but **64% of the merges** (23% hit rate vs G1's 4.4%). Its threshold is 0.42 even though the raw clusters there look bad to a human — the judge is the precision filter, and judging clusters that exist only at 0.42 gave the same ~20% hit rate with correct merges, including near-verbatim duplicates 0.55 could not reach.
- **Do not tune a candidate threshold by eyeballing raw clusters.** That is how G2 first got set to 0.55, which cut candidates from 414 to 30 and threw away ~3x the yield for no quality gain. Judge quality is measured on the judge's OUTPUT: run `rake knowledge:review DRY_RUN=1` and read the merges it proposes.
- Nothing exists above ~0.65 in the residual space, so there is no headroom above the current setting. Re-run `rake knowledge:cluster_preview` (no LLM, no writes) to inspect candidate shape before changing anything.
- **The judge must be allowed to refuse.** Candidate precision is ~67–80%, so refusing is the normal case. The old `MERGE_PROMPT` asserted the cluster *was* duplicated and only asked for merged text — at this precision that reliably fuses distinct facts. The "same person, different fact" trap is the one to guard against.
- Never trust the verdict: drop ids outside the chunk, never touch `source: 'manual'` facts, drop merges of fewer than 2 ids, skip facts younger than `min_age_days`, let merge win over delete for the same id, and log-but-don't-apply anything over the budget.
- **Deletion is soft.** All read paths go through `scope :live`; the enumerated call sites include `EmbeddingCache#build` and the subject-bucket queries — a tombstone left in a bucket pollutes its centroid and comes back as a candidate. `бот верни <id>` restores, and refuses on a `merged` source unless confirmed.
- **The daily deletion budget counts merge-sourced deletions** (a 3-fact merge spends 3) and is shared across every run that day, summed from `knowledge_compact_log.removed` — which is the TOTAL soft-deletes for a run, with `deleted` a breakdown of it. Summing both charges a direct deletion twice. Merging is by far the bigger deletion vector; a cap governing only the `delete` array understates the blast radius by an order of magnitude.
- `knowledge_subjects` has the schema's **first FK**, and sqlite runs `PRAGMA foreign_keys = ON` — `on_delete: :cascade` plus `dependent: :delete_all` are both required or every `Knowledge#destroy` raises.
- A single verdict can propose **overlapping merge groups** ([1,2] and [2,3]); apply only the first, or the shared fact is deleted twice and the second merged fact quotes a source already merged away. Treat every verdict element as untrusted shape too — `{"delete":[3]}` is valid JSON and must not raise.
- Build prompts with `gsub('{X}') { value }`, never `gsub('{X}', value)`: a string replacement expands `\\1`, `\\&` and `\\\\` occurring in fact content or JSON escapes, silently mangling what the model sees.
- **Facts judged within `review.ttl_days` are skipped** by candidate generation, which is what makes runs resumable and stops a just-merged fact being re-merged. A dry run must never stamp `reviewed_at`.
- A merged fact's subjects are the **union of its sources'**, and it is stamped `reviewed_at` at creation — otherwise it drops out of its buckets, shifts their centroids, and jumps to the head of the next sweep to be re-merged.
- **`knowledge.subject_aliases` is personal data and lives only in the gitignored `config/settings.yml`.** This repo is public; a uid→given-name/nickname map for a private community is a deanonymization table. Never match on a bare `users.first_name` — it is not unique, and collapsing two people into one bucket produces confident, wrong clusters.
- `KnowledgeBase.compact_logger` falls back `COMPACT_LOGGER → LOGGER → IO::NULL`. `COMPACT_LOGGER` is assigned only in `lib/bot.rb`, so the review path used to raise `NameError` from rake tasks and `bin/console`.
- `бот ревизия знаний` (admin only) **enqueues** a background task. It must never run the sweep inline — one LLM call per cluster would freeze the whole bot.

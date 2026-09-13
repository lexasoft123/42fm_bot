# ADR-005: Person-Bucketed Dedup with an LLM Judge

**Status:** Accepted — amended 2026-09-13 after three weeks in production (see "What happened in production")
**Date:** 2026-08-20

> ADR-004 is reserved for the deferred work on capping/retiring facts and extraction cadence.
> This ADR covers deduplication and removal only.

## Context

The per-chat knowledge base grows ~34 facts/day and compaction removed ~3.5/day, so it only ever
got bigger. The suspicion driving this work was "a lot of duplicates phrased differently."

A copy of the prod DB was pulled and **all 18,803,778 pairs** of the main chat
(`-1001273623296`, 6,133 facts) were scored. The results refuted most of the assumptions the work
started from:

| Measurement | Result |
|---|---|
| Max pairwise cosine between any two facts | **0.6994** |
| Mean pairwise cosine | 0.2513 |
| Highest lexical overlap (Jaccard, content words) | 0.29 — not one near-verbatim repeat |
| Compaction history | 372 runs, 289 merges, 663 facts removed |
| Facts naming one of 14 handles | 3,498 (57%) — 83.6% with a curated alias map |
| Facts naming two or more people | 1,385 (23%) |

Three conclusions followed.

**1. Compaction was working, and its threshold was above the data.** The distribution is truncated
just under the 0.70 `compact_threshold` *because* compaction kept trimming it there. There was no
giant-cluster failure and no silent breakage — there were simply **zero pairs at or above 0.70** left
to merge. The job read 171 MB twice a day to find nothing.

**2. The 0.92 write gate had never fired.** `similar_exists?` rejected only above 0.92; nothing in
the base reaches within 0.22 of that. It cost a full table scan plus an embeddings API call per
extracted fact, always to return false.

**3. Person identity dominates the embedding.** Every sampled pair in the 0.60–0.62 band was "same
person, different fact". Two facts about the same participant score ~0.60 largely *because* both are
about them — so no global threshold can separate "same fact restated" from "same person, new fact".

## Decision

**Bucket facts by the people they are about, subtract the per-bucket centroid, and cluster on the
residual — then let a cheap LLM judge every candidate.**

### Two candidate generators, two similarity spaces

| | Space | Threshold | Catches |
|---|---|---|---|
| G1 | raw normalized cosine | 0.66 | cross-person duplicates |
| G2 | per-bucket centroid-removed residual | 0.55 | same-person, same-incident families |

Removing the bucket centroid cancels the shared "aboutness" direction. On prod this surfaces
duplicate families that raw cosine ranks at 0.56–0.62 — e.g. three separate facts about the same
Bryansk bus incident, five about one participant's pet — which no safe global threshold can reach
(getting there globally means 0.58, which yields 5,475 pairs at ~0% precision and a 3,113-fact giant
component).

**The spaces must never be mixed in one clustering pass.** The pairs G2 exists to find sit *below*
G1's threshold in raw space, so any raw-space admission test discards them — and the symptom is
"fewer clusters", not an error. Each space is clustered separately and the resulting **clusters** are
unioned. G2 emits first and claims its facts; G1 runs over the remainder.

### Seed-and-absorb instead of union-find

Every member must be within the threshold of the *seed*, so clusters have a bounded semantic radius
and cannot chain. The previous union-find took the transitive closure, which at 0.62 produced a
single 1,385-fact component — and the code had no size cap, so that whole component would have gone
into one merge prompt. The size cap (8) is now native to the algorithm.

### The LLM judges; nothing merges mechanically

Sampled candidate precision is ~67% (G1) to ~80% (G2). Merging on a threshold alone would therefore
destroy information in a fifth to a third of cases. A cheap model (`deepseek-v4-flash`) receives each
cluster under a contract that lets it **refuse** — the previous `MERGE_PROMPT` asserted the cluster
*was* duplicated and only asked for merged text, which at this precision reliably fused distinct
facts. Every answer is validated in code before anything is written.

### Deletion is soft

The deleting actor is a language model, so over-deletion is the expected failure mode rather than a
remote one, and there was no per-fact undo: `make backup` restores the whole DB, rolling back every
message, task and cost row since the snapshot. Facts get `deleted_at`/`deleted_reason`; every read
path filters through `scope :live`; `бот верни <id>` restores.

### One pipeline

`compact!`, `merge_cluster` and the `knowledge_compact` task type are gone. `KnowledgeBase.review!`
is the only path that deletes a fact, so there is one deletion actor, one daily budget, one prompt
and one audit trail.

## Thresholds were calibrated, not chosen

Every number here came from sampling real clusters and reading them:

| Residual threshold | Clusters | Raw precision (eyeballed) | Judge hit rate (measured) |
|---|---|---|---|
| **0.42** | **414** | very low — clusters whole biographies | **20%** |
| 0.50 | 114 | ~37% | — |
| 0.55 | 30 | ~80% | 23% |
| 0.65+ | 0 | the residual space has no pairs this high | — |

**The two right-hand columns tell opposite stories, and the second one is the one that matters.**
G2 was initially set to 0.55 on the strength of eyeballed cluster quality. Measured against the real
judge that was a mistake: clusters existing *only* at 0.42 produced the same ~20% hit rate, every
merge inspected was correct, and one was a near-verbatim duplicate 0.55 could not reach. Tightening
had cut candidates from 414 to 30 and discarded roughly 3x the yield for no quality gain — because
the judge, not the threshold, is the precision filter. Tune candidate thresholds on the judge's
output, never on how the raw clusters look.

`rake knowledge:cluster_preview` reproduces this with no LLM calls and no writes. Re-run it before
changing any threshold; these are fitted to one corpus at one point in time.

## Trade-offs

- **Yield is modest.** ~356 facts (5.8% of the base) if every candidate merged, and the judge is
  *supposed* to refuse a large share. Against ~34 new facts/day, dedup holds the line at best.
  Shrinking the base needs per-person retirement — ADR-004 — for which `knowledge_subjects` is the
  prerequisite this work delivers.
- **Bucket quality is load-bearing.** A bad alias merging two people into one bucket produces
  confident, wrong clusters. The alias map is explicit per uid, never matches a bare first name, and
  `backfill_subjects` prints per-uid samples for review. It reaches 83.6% coverage; the residual is
  mostly facts with no individual subject, which correctly fall through to G1.
- **Subjects captured at write time are incomplete.** The extractor only sees uids of people who
  *spoke* in the 50-message window, so a fact about someone discussed in the third person gets no
  subject. The curated map is therefore an ongoing tool, not a one-off bootstrap.
- **The alias map is personal data.** It lives only in the gitignored `config/settings.yml`; this
  repo is public and a uid→nickname map for a private community is a deanonymization table.

## Consequences

**Measured contribution of the per-person generator:** G2 supplied 9.7% of candidates but **64% of
the merges** — a 23% hit rate against G1's 4.4%. Bucketing by person is what makes this work; global
cosine alone would have found a third as much.

**Positive:** duplicates that were previously unreachable are now detectable; deletions are
reversible for the first time; one deletion actor with one budget; thresholds are backed by
measurements and reproducible via `cluster_preview`.

**Negative:** more moving parts (a join table, two generators, a judge); the sweep occupies a
TaskRunner worker; subject coverage needs periodic re-curation.

**Risks:** a bad alias produces plausible-looking wrong clusters — mitigated by explicit per-uid
regexes, sampled review, and the judge refusing; LLM over-deletion — mitigated by soft delete, the
per-chat daily budget counting merge-sourced deletions, manual-fact immunity, and a dry-run mode.

## What happened in production (amendment, 2026-09-13)

A review 24 days after launch found the sweep had merged **41 facts on its first day and zero
afterwards**, and that the deploy had introduced a lock regression. Nothing in the decision above was
wrong; two implementation details defeated it, and a third bug came along in the same deploy.

**The sweep stalled for two compounding reasons.**

1. *Every candidate was stamped reviewed, judged or not.* On day one 1,250 facts were stamped against
   ~650 actually sent to the judge — the run stopped at `max_chunks`, and budget-blocked runs stamped
   everything they would have looked at. The rest were locked out for `ttl_days` unseen.
2. *Minimum age was enforced after the verdict, not before.* A young fact's approved merge was
   discarded, and the fact was stamped anyway. Each new fact therefore got exactly one look, while too
   young to act on, followed by a 30-day lockout. Reading the judge's raw answers from `gpt.log`:
   **it proposed 14 merges in those 24 days, and all 14 were discarded this way** — 10 of them with
   both facts zero days old. Reviews triggered straight after extraction made it worse.

The symptom was not an error. The sweep ran four to six times a day, paid for 188 judge calls
($0.036), and changed nothing — invisible without reading its output.

**Most remaining duplicates are born together.** The 14 discarded merges were mostly the extractor
restating one conversation twice *within a single batch* (ids 8258/8259, 8472/8473). The age guard's
rationale — a new fact hasn't been corroborated yet — does not apply to siblings at all. They are now
collapsed at extraction time, before saving (`BatchDedup`), under the same judge contract. Calibrated
on 922 prod facts: judge-approved sibling duplicates sit at cosine 0.554–0.743, ordinary siblings p95
0.50; a 0.50 threshold nominates all of them for ~88 judge calls a month.

**The lock regression.** `extract_and_store` wrapped its batch in a transaction and embedded each fact
inside it. Transactions here are DEFERRED — SQLite takes the write lock at the first write and holds it
until COMMIT — so after each batch's first INSERT the lock was held across the remaining embeds, several
seconds of HTTP per batch. (An earlier draft of this amendment said `BEGIN IMMEDIATE`; that is Rails 8's
default, not this stack's. The rule is unchanged, the mechanism was misstated.) Result: **48 `SQLite3::BusyException`s in 24 days** against 2 in all
prior history, every one within 10–30 s of a `knowledge_extract` call; **27 incoming chat messages
never saved**; the listen loop frozen up to 10 s each time. The code reviewer flagged exactly this
before launch. The fix was applied with a scripted string replacement that did not match and silently
did nothing, and the test written to guard it recorded transaction state without asserting it. Both
passed.

**Fixes, all regression-tested against the shipped code (each new test fails on 56706cf):**

- No network call inside any transaction: embed first, then a short write-only transaction
  (`extract_and_store`, `apply_merge`). Guard tests assert `open_transactions == baseline` during every
  embed *and* carry a negative control proving the detector sees a real transaction.
- Stamp only facts the judge actually ruled on (`judged_ids`): not unreached clusters, not unparseable
  answers, not a cluster whose verdict a cap cut off.
- Eligibility before the judge: young, recently-judged and manual facts never enter a cluster and are
  never stamped. G2's per-bucket proposals are seeded with that set, so one unavailable member no
  longer discards an otherwise good cluster.
- `rake knowledge:reset_reviewed` to clear the mis-stamps (merged facts keep theirs).
- Found by the code review of these fixes: a merge larger than the whole daily cap (clusters go to 8,
  the default cap is 5) would have left its cluster unstamped at the head of the queue forever — the
  same "runs, pays, merges nothing" stall from a new cause. It is now ruled out as `oversized`. Also:
  `apply_merge` no longer tombstones sources behind a merged fact it couldn't embed; batch dedup honours
  the judge's `duplicate` deletes; the run log is written in an `ensure`.
- Also fixed in passing: a top-level JSON array verdict raised out of the run; the cache rebuild read
  the legacy JSON column for every row (~171 MB, p50 765 ms per rebuild); dual-write turned off after
  three clean weeks on the blob path.

**The read path worked as designed but was not the latency win it looked like.** Lookup fell from
1,152 ms to p50 10 ms, yet `get_relevant_knowledge` still takes ~1.4 s: the query's own embeddings call
through the proxy is 97% of it. That is the next lever, and outside this ADR.

**Lesson worth more than any of the fixes:** a finding marked "applied" was never verified in the
code, and a guard test was never shown to fail. Both are now checked explicitly.

## Rollback

`git revert` alone is **actively harmful**: removing `scope :live` makes every soft-deleted source
visible again *alongside* the merged fact that replaced it, silently recreating the duplicates the
sweep removed. Run `rake knowledge:rollback_merges SINCE=<ts>` first — it hard-deletes merged facts
and restores their sources, leaving deliberate `admin` deletions alone — then revert.

## Out of Scope

Fact capping and per-person retirement (ADR-004); changing the extraction prompt's fact-selection
behaviour; compaction cadence.

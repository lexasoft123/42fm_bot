# ADR-005: Person-Bucketed Dedup with an LLM Judge

**Status:** Accepted
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

## Rollback

`git revert` alone is **actively harmful**: removing `scope :live` makes every soft-deleted source
visible again *alongside* the merged fact that replaced it, silently recreating the duplicates the
sweep removed. Run `rake knowledge:rollback_merges SINCE=<ts>` first — it hard-deletes merged facts
and restores their sources, leaving deliberate `admin` deletions alone — then revert.

## Out of Scope

Fact capping and per-person retirement (ADR-004); changing the extraction prompt's fact-selection
behaviour; compaction cadence.

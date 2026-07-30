---
date: 2026-07-30
status: Open
priority: P2
type: enhancement
component: doc-index
source: manual
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
  - skills/doc-superpowers/SKILL.md
screenshots: null
axiom-agent: null
branch: feat/archive-entry-batch-primitive
design-doc: null
report: null
---

## Summary

`move-entry` (v2.14.0) closed the single-doc re-key gap. It does not serve the
one consumer the skill **explicitly delegates to**: `*archive_doc*`.

`SKILL.md` declares `*archive_doc*` as `Optional, user-provided` and globs for
`scripts/*archive_doc*` during every action's discovery phase. So archival is a
first-class extension point — but a consumer implementing it cannot build on
`move-entry`, because archival is inherently **bulk** and `move-entry` is
deliberately **single-pair**.

The result: every consumer that fills the `*archive_doc*` slot must hand-roll
index manipulation, which is exactly the duplication `move-entry` was added to
end.

## Evidence

Measured against a real consumer (`abundance-mvp`, `scripts/archive_doc.py`,
358 lines, predates doc-superpowers by two months):

```
archive-eligible docs in that repo right now   691
move-entry, one call, 4019-entry / 1.9 MB index  0.39s
691 sequential calls                            ~269s (~4.5 min)
                                                 691 full-file rewrites
```

That consumer currently archives in **one in-memory pass**. Delegating per-doc
would trade ~0.4s for ~4.5 minutes and 691 rewrites of a file that has a custom
merge driver (`scripts/merge-doc-index.sh`) — so the correct architectural move
is currently the strictly worse one, and every consumer will reasonably decline
it.

## Why `move-entry` alone cannot be the answer

Its single-pair constraint is **deliberate and correct** — from its own source:

> A move is inherently PAIRED, so this takes exactly one pair. A varargs
> [form would] … the failure mode is an index full of wrong keys.

That reasoning holds. This issue is not a request to add varargs to
`move-entry`. It is a request for a primitive whose *shape* matches the bulk,
policy-driven consumer the skill already advertises.

Note the asymmetry: `add-entry` **does** take batch input on stdin. A consumer
can add 691 entries in one call and can move exactly one.

## What archival needs beyond a re-key

A consumer filling the `*archive_doc*` slot performs four steps. Only the third
is covered today:

| Step | Owner today |
|---|---|
| Decide eligibility (per-`doc_type` status triggers, top-dir constraints) | consumer — **policy, correctly theirs** |
| Move the file on disk | consumer — correctly theirs |
| Re-key the index entry, preserving metadata | **`move-entry`, but single-pair only** |
| Stamp `archived_at` on the moved entry | consumer — no upstream support |

Steps 1 and 2 are genuinely consumer policy and should stay there. Steps 3 and 4
are index mechanics and belong upstream, which is the whole argument `move-entry`
was accepted on.

## Proposed

Either of these resolves it; the first is smaller.

**A. `move-entry` gains a stdin batch form**, mirroring `add-entry`'s existing
shape — one pair per line, `<old>\t<new>` or `<old>::<new>`. The safety concern
that ruled out *varargs* does not apply to line-delimited pairs: varargs is
ambiguous because argument count is positional and unbounded; a line with exactly
two fields is self-delimiting. Keep the two-argument form as-is for the single
case. One index read/write for N moves.

**B. A dedicated `archive-entry` verb** that does the re-key **and** stamps
`archived_at`, batch-capable, leaving eligibility and the filesystem move to the
consumer. This covers step 4 as well and gives the advertised extension point a
matching primitive.

Both should preserve `move-entry`'s existing guards, which a hand-rolled
consumer typically lacks:

- refuse when the source key is absent
- refuse to overwrite an existing target key
- carry `code_refs` / `code_commit` / `last_verified` across, recompute
  `content_hash`

## Acceptance

- A consumer can re-key N entries in one invocation, with per-pair validation
  and no partial-write on failure.
- The existing two-argument `move-entry` behaviour is unchanged (regression-pinned).
- `SKILL.md`'s tooling table names the new form.
- A test proves the batch path preserves the same metadata the single path does —
  and fails if it stops doing so.

## Context

Surfaced 2026-07-30 while wiring `abundance-mvp`'s `scripts/doc-index/coverage.sh`
onto `move-entry` (the v2.14.0 consumer). The audit of that repo's other
index-writing paths found `archive_doc.py` doing its own pop-and-carry re-key —
correctly, and predating this tool — with no upstream primitive it could have
used at bulk scale.

Related: [`2026-07-29-doc-tools-has-no-move-entry-operation.md`](2026-07-29-doc-tools-has-no-move-entry-operation.md)
(the single-doc gap this follows from).

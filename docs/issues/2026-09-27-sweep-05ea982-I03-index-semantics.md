---
date: 2026-09-27
status: Resolved
priority: P1
type: bug
component: doc-index
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-3
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - references/doc-spec.md
  - references/spec-lifecycle-actions.md
  - docs/conventions.md
  - skills/doc-superpowers/SKILL.md
  - docs/.doc-index.json
  - docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-3 — Index semantics: what is stored, and who may attest to verification

> Cluster **I-3** of sweep run `05ea982`, ranked #8 of 14. Evidence lives in the
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S1, S11, X). The fix is
> **Task 5** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It also closes
> **GH #18** and the issue record `2026-07-30-no-batch-or-archive-aware-re-key-primitive.md` (filed by PR #16, merged `ae05f65`).

## Summary

The index stores `status: current` and `last_verified: now` whenever an entry is written. In the
code, "an entry was written" and "a human or agent read the doc against the code" are the same
event. As a result:

- verbs that verify nothing claim verification;
- the one verb that does verify (`update-index`) silently undoes deprecation;
- point-in-time records (plans, issues, audits, archived specs) carry `code_refs` and go stale
  forever.

The stored `current`/`stale` value is also dead data: no writer ever stores `stale`.

## Incorrect assumption

**A2:** "Writing an index entry is verifying the doc." Two related assumptions:
- "status is a stored lifecycle";
- "every indexed doc describes current code".

## Verified evidence

- `doc-tools.sh:776-787`: `update-index` always writes `status=current`, which un-deprecates the
  entry. The documented supersede flow reaches this path (`spec-lifecycle-actions.md:96 → :116`).
  Measured.
- `SKILL.md:639,373`; `doc-tools.sh:378-401,878-900,1157`: writers that verify nothing stamp
  `status=current` + `last_verified=now`. Measured.
  - `build-index` re-baselines every entry to HEAD.
  - `add-entry` baselines to HEAD.
  - `deprecate-entry` bumps `last_verified`.
- `:384,401,884,900`: the stored `current`/`stale` status is dead data. No writer stores `stale`;
  `build-index` resets deprecations. Structural.
- `:657`; `SKILL.md:335`: point-in-time records are stale by construction. On a clone of this repo,
  23 of 36 entries are stale and 21 of those are records (13 superpowers specs/plans, 4 plans,
  2 issues, 2 archive). Indexed archive entries are still evaluated. Measured.
- `:371-405,872-904`: `build-index`/`add-entry` never write `implementation`, although
  `docs/conventions.md:335` describes it (10 of 36 entries have it).
- `docs/conventions.md:309-317,331`: the status table contradicts the code:
  - `update-index` un-deprecates;
  - `stale` is never stored;
  - "hash mismatch" is described wrongly.
- `SKILL.md:290`, `doc-spec.md:33`: the in-doc `date | commit` marker is a second freshness claim
  that nothing reads.
- `replaces` has no writer. `deprecate-entry --superseded-by X` never sets `X.replaces`.
- **GH #18**: no verb edits an existing entry's `code_refs`. The only route is `remove-entry` +
  `add-entry`, which drops metadata.
- **PR #16** (issue record, now merged as `docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md`): there is no batch or archive re-key
  primitive.

## Proposed fix (fix plan Task 5, built on I-2's `_index_apply`)

- Stored `status` becomes `deprecated` or absent. `current`/`stale` are always computed, and a legacy
  stored `current` is read as absent.
- Only `update-index` writes `last_verified`, and it keeps an existing deprecation.
  `deprecate-entry` stops bumping `last_verified` and sets `replaces` on the successor.
- `add-entry` baselines to the doc's own last commit tree, not HEAD. With I-1 it records the OIDs
  from that tree.
- New `set-code-refs <doc> --refs a,b` (GH #18): edits in place, preserves key position and every
  other field, re-derives the OIDs.
- Batch `move-entry` from stdin (`<old>\t<new>` per line; PR #16 Option A): validates every pair
  before writing anything.
- Record docs (`doc_type` plan/issue/audit/design-spec, or anything under `docs/archive/`) are never
  reported stale.
- **Archive model decision:** archival = `git mv` into `docs/archive/<type>/` + `move-entry` +
  `deprecate-entry`. No `archived_at` field, so PR #16 Option B is not needed. Record this in
  `docs/conventions.md`.

## Acceptance criteria

- [x] `update-index` on a deprecated entry keeps it deprecated.
- [x] `build-index --force` preserves deprecations.
- [x] `add-entry` never claims verification for an unread doc.
- [x] `deprecate-entry --superseded-by X` sets `X.replaces`.
- [x] `set-code-refs` edits in place with all other fields preserved.
- [x] Batch `move-entry` is all-or-nothing and preserves the same metadata as the single form.
- [x] Record docs are never reported stale.
- [x] `docs/conventions.md` status table, `references/doc-spec.md` transitions and the `SKILL.md`
  tooling table are updated in the same change.

## Related

- GH #18, and `docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md` (PR #16, merged `ae05f65`). Set it Resolved when this cluster closes.
- I-11 fixes the prompt routing that sends agents to the wrong writer.
- I-14 migrates this repo's own record entries to empty `code_refs`.

## Resolution (Task 5)

Resolved by Task 5 of the fix plan. Writing an entry and verifying its doc are now separate events.

- **Only `update-index` attests.** It is the only writer of `last_verified`.
  - `build-index` and `add-entry` write `last_verified: null`, and store no status.
  - `deprecate-entry`, `move-entry` and the new `set-code-refs` leave `last_verified` as it is.
  - `update-index` reports a re-attestation of an unchanged doc as `Re-verified`, which is a real
    write, and no longer as `Unchanged`.
- **Stored `status` is `deprecated` or absent.**
  - `current`, `stale` and `missing` are computed by `check-freshness` and `status`.
  - A legacy stored `current`/`stale` reads as absent, and the next write that changes the index
    drops it.
  - `update-index`, `move-entry`, `set-code-refs` and `build-index --force` all keep a deprecation.
    `--force` also carries `superseded_by` and `replaces` for every key it re-indexes.
- **Non-attesting writers baseline to the doc's own last commit, never HEAD.**
  - `build-index` and `add-entry` record each ref's content (`code_oids`) and `code_commit` as of
    the newest commit that touched the doc, found with one `git log --stdin` walk for all docs. So
    an old doc indexed today reads stale if its code moved on.
  - A doc git has never committed is being written now, so its baseline is the working tree.
- **`deprecate-entry --superseded-by X` sets `X.replaces`** when it is empty. It holds one path, so
  an existing value is kept, with a warning. An unindexed successor is named in a warning, and a doc
  cannot supersede itself.
- **`set-code-refs <doc> --refs a,b`** (GH #18) edits `code_refs` in place.
  - The entry keeps its key position, its field order, and every other field.
  - The same list of paths is a no-op (`src` is a stored `src/`).
  - `code_oids` is re-derived: a ref the entry already had keeps its recorded id, and a new ref is
    recorded as `add-entry` records it. A pre-v3 entry's recorded id is the ref's content in the
    stored `code_commit` (fix round 1).
  - `code_commit`, the `commits_behind` baseline, is never newer than any ref's recorded content
    (fix round 2):
    - it stays when every ref is kept (removed, re-spelled or reordered);
    - it is derived as `add-entry` derives it when every ref's content comes from the doc's last
      commit;
    - with both, it is the older baseline, `git merge-base` of the stored and derived commits, or
      null when either is unusable or they share no ancestor.
    - So `commits_behind` may over-count but is never a masked 0. Round 1's "re-derive when a ref is
      added" could record a commit newer than a kept ref's content: the reviewer's
      `stale|1` → `stale|0`.
  - `--refs ''` clears the refs.
  - The `update-index` missing-file advice and `add-entry`'s SKIP now name it.
- **`move-entry --stdin`** (PR #16 Option A) reads one `<old><TAB><new>` pair per line.
  - Every pair is validated before anything is written, and one bad pair writes nothing.
  - The pairs are one simultaneous rename, so a path one pair vacates may be another's target.
  - The single form runs through the same code, so both forms carry the same metadata. A test
    compares the whole resulting index for both forms.
- **Record docs are never stale.** A record doc is one whose `doc_type` is plan, issue, audit or
  design-spec, or whose path is under `docs/archive/`.
  - They are reported `current` with `"record": true` and `commits_behind: null`, and their refs
    are never looked up.
  - No new status value was added, since hooks and CI count `stale`.
- **Archive model:** `git mv` into `docs/archive/<type>/`, then `move-entry`, then
  `deprecate-entry`. There is no `archived_at` field. This is recorded in `docs/conventions.md`.
- **Also fixed (a T4 carry-over):** under `/bin/bash` 3.2, a fatal `set -u` error exited 0,
  because the EXIT trap saw `$? = 0`. Such an abort now exits 1 on both interpreters, and the lock
  and scratch dir are still cleaned up.

**Measured on this repo** (`check-freshness`, index unchanged): stale fell from 31 to 10, and 44
entries now read as records. The 10 are:
- 4 living docs: `system-overview`, `codebase-guide`, `getting-started`, `workflows/doc-superpowers`;
- the 6 `docs/superpowers/specs/*` design specs, which this repo's index types `spec` rather than
  `design-spec`, so they are still compared.

I-14 retypes them and empties record docs' `code_refs` with `set-code-refs`.

---
date: 2026-09-27
status: Open
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
> **GH #18** and the issue recorded by **PR #16**.

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
- **PR #16** (issue record): there is no batch or archive re-key primitive.

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

- [ ] `update-index` on a deprecated entry keeps it deprecated.
- [ ] `build-index --force` preserves deprecations.
- [ ] `add-entry` never claims verification for an unread doc.
- [ ] `deprecate-entry --superseded-by X` sets `X.replaces`.
- [ ] `set-code-refs` edits in place with all other fields preserved.
- [ ] Batch `move-entry` is all-or-nothing and preserves the same metadata as the single form.
- [ ] Record docs are never reported stale.
- [ ] `docs/conventions.md` status table, `references/doc-spec.md` transitions and the `SKILL.md`
  tooling table are updated in the same change.

## Related

- GH #18 and PR #16. Recommendation: merge PR #16, the issue record, before starting this Task.
- I-11 fixes the prompt routing that sends agents to the wrong writer.
- I-14 migrates this repo's own record entries to empty `code_refs`.

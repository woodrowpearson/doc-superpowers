---
date: 2026-09-27
status: Resolved
priority: P0
type: bug
component: doc-index
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-5
run-id: 05ea982
related-files:
  - scripts/merge-doc-index.sh
  - scripts/test-merge-driver.sh
  - scripts/hooks/install.sh
  - docs/architecture/system-overview.md
  - docs/codebase-guide.md
  - docs/issues/2026-07-29-merge-driver-reads-version-not-schema-version.md
  - docs/issues/2026-05-04-doc-index-metadata-rewrite-on-every-commit.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-5 — The doc-index merge driver is not a three-way merge

> Cluster **I-5** of sweep run `05ea982`, ranked #2 of 14. It holds the **only P0** that survived
> adversarial verification. Evidence lives in the
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S3). The fix is
> **Task 6** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It subsumes
> `2026-07-29-merge-driver-reads-version-not-schema-version.md`.

## Summary

`scripts/merge-doc-index.sh` receives base, ours and theirs, but uses the base only in `has()`
checks. For each key it keeps the whole entry with the newer `last_verified`; on a tie it takes
`%A`. A key missing on one side is dropped, even when the other side changed it. As a result:
- changes made on one side are lost whenever the other side has a newer timestamp;
- the result depends on merge direction;
- `git rebase`, which replays in the other direction, loses different data from `git merge`.

The docs call the driver "three-way" and recommend rebase as the path that "resolves silently".

## Incorrect assumption

"The entry with the newest `last_verified` carries every change from both sides, and a side that is
missing a key meant to delete it."

## Verified evidence (measured through real `git merge` / `git rebase` / `git revert`)

- **[P0]** `merge-doc-index.sh:47-53,61,64-65,70-71`:
  - (a) Deprecate vs `update-index`: the deprecation is undone, in both merge directions.
  - (b) A `move-entry` repoint plus hand-edited refs are lost in one merge direction and under
    `git rebase`, leaving a dangling `superseded_by`.
  - (c) Reverting a deprecation does not revert it.
  - (d) Move vs re-verify: the re-verification is lost.
  - (e) A one-sided change with an older `last_verified` is dropped.
- [P2] `install.sh:187-190`: the driver is registered as an unquoted absolute path into the
  versioned skill dir.
  - A space in the path, or a pruned dir, gives CONFLICT with **no markers** and ours-only content.
  - Driver fixes never reach existing installs.
- [P2] `:32,55-57,84`: `jq empty` admits a 0-byte, `null` or `{}` side.
  - Every base entry is deleted, with exit 0.
  - A 0-byte ours makes `%A` = `"\n"`.
- [P3] `:14,39-40,77-83`: the top-level object is rebuilt from a fixed field list.
  - It drops `schema_version`, which is the existing issue.
  - `build_commit` becomes merge-time and `generated_at` becomes wall-clock.
- [P3] `:18,76`: `.docs` is sorted while writers keep insertion order (a 247+/246- diff for one
  change per side).
- [P3] `:10-11,27-35`: a failing driver leaves `%A` = ours with no markers; the header comment claims
  otherwise.
- [P2] `test-merge-driver.sh:17-41,49-157,244-251`: no fixture compares against the base. This is
  why the P0 passes 19/19 (tracked in I-13).

## Proposed fix (fix plan Task 6)

Per key, with base/ours/theirs = `b`/`o`/`t` (null when absent):

- `o==t → o`; `o==b → t`; `t==b → o`.
- Otherwise merge field by field:
  - the side that changed a field wins;
  - if both changed it, the newer `last_verified` wins;
  - `deprecated` wins.
- A deleted key is dropped only when the surviving side equals base; otherwise exit 1.

Other changes:
- Validate each side with `jq -e -s 'length==1 and (.[0].docs|type=="object")'`.
- The top level starts from ours. Keep ours' key order and append theirs-only keys.
- On any failure write conflict markers with `git merge-file -L ours -L base -L theirs` and exit 1.
- Quote the registered path and resolve the newest driver at runtime, or vendor it into the repo.

## Acceptance criteria

- [x] Fixtures built with the real verbs and merged with real `git merge`, `git rebase` and
  `git revert` in both directions. Each gives the same, correct result for:
  - deprecate vs update-index;
  - repoint vs add;
  - hand edit vs untouched;
  - delete vs modify;
  - delete on ours;
  - a tie;
  - an older one-sided change.
- [x] Degenerate sides make the driver exit non-zero with markers in `%A`.
- [x] `schema_version` survives a merge.
- [x] Docs no longer claim three-way behaviour the driver lacks, and no longer recommend rebase as
  silent resolution.

## Resolution (Task 6)

Resolved by Task 6 of the fix plan. `scripts/merge-doc-index.sh` is now a base-aware, per-key
three-way merge. Its header comment is the specification.

- **Per docs key**, with `b/o/t` = base/ours/theirs (absent = no entry): `o==t → o`, `o==b → t`,
  `t==b → o`. So a change that only one side made always survives, including a deletion. Before
  comparing, a legacy stored `current`/`stale` status reads as absent.
- **Both sides changed an entry**: it is merged field by field. The side that changed a field wins.
  When both changed the same field differently, the entry with the newer `last_verified` wins it.
  - A non-null `last_verified` beats null.
  - When `last_verified` does not order the two (equal, or both null), nothing decides. The merge
    is a **conflict**: markers, exit 1, and stderr names the doc key and the field. This is the
    common case, not a same-second rarity: only `update-index` writes `last_verified`, so two
    `set-code-refs`, `deprecate-entry --superseded-by`, `move-entry` repoints, `set-implementation`
    calls or hand edits of one field always tie. (Fix round 1 replaced the first version's "a tie
    keeps ours", which silently kept one branch's value depending on direction.)
  - `content_hash`, `code_oids`, `code_commit` and `last_verified` are **one** field. `update-index`
    writes them as a unit. Mixing one side's doc hash with the other side's code ids would attest a
    doc/code pair that nobody verified. The driver takes the newer record whole. Two different
    records with the same `last_verified` are a conflict; two equal records are not.
  - **Deprecated wins**: if both sides changed `status`, it resolves to `deprecated` when either
    side has it. `superseded_by` goes with the status the merge kept. Reverting a deprecation still
    removes it, because the revert removes it and the other side left it alone. When both sides
    have the same status, `superseded_by` follows the `last_verified` rule, so a repoint against a
    re-deprecation conflicts.
- **One side deleted a key and the other changed it**: this is a conflict, never a silent drop.
- **Any side that is not exactly one object with a `.docs` object** is a conflict: 0 bytes,
  `null`, `{}`, two documents, or invalid JSON. The check is
  `jq -e -s 'length==1 and (.[0].docs|type=="object")'`, on the base too unless the base is empty.
  An empty base is the add/add case.
- **On conflict**, `%A` gets markers from `git merge-file -L ours -L base -L theirs`, and the
  driver exits 1. If the line merge comes out clean (a side that only appended a second document),
  the driver redoes it against an empty base, so markers are always present.
- **The top level starts from ours.** `schema_version` (or a legacy `version`), `build_commit`,
  `generated_at` and unknown fields survive. A field only theirs changed is taken from theirs, so
  one side's upgrade from `version` to `schema_version` is kept. Key order is ours' at every level,
  with theirs-only keys appended. There is no re-sort and no merge-time metadata.
- **No lock.** The driver writes only `%A`, a temporary file git creates for the merge and reads
  back. Git writes the working-tree index file itself, under its own lock.
- **Registration** (`install.sh`). The command is quoted, and it resolves the driver when the merge
  runs.
  - A plugin-cache install (the skill dir's name is a version) runs the newest version-named
    sibling, in numeric order. Other siblings are never run. A plugin update therefore reaches
    existing installs without re-installing, and a pruned version dir is not fatal.
  - A checkout install runs its own copy.
  - If no driver is found, `%A` gets conflict markers (merge-file against an empty base) and the
    merge stops.
  - `status` reports which driver a merge would run, or flags a pre-3.0 pinned registration for
    re-install. The old `awk '{print $1}'` parse is gone.
  - Existing installs pick this up the next time `install --git` runs (T8 re-registers).
- **Signals**: an INT/TERM/HUP, even mid-write, restores `%A` from ours and leaves markers. `%A` is
  never left half-written.
- **Tests**: `scripts/test-merge-driver.sh` was rewritten. It has 486 assertions, up from 19, and
  they are stated against the base.
  - Fixtures are built with `build-index`, `add-entry`, `update-index`, `deprecate-entry`,
    `move-entry`, `remove-entry` and `set-code-refs`, on a controlled clock.
  - Each fixture is merged four ways: merge and rebase, in both directions. There are also two
    `git revert` cases.
  - Unordered same-field changes conflict in all four ways: `set-code-refs` on both sides, a
    `move-entry` repoint against `deprecate-entry --superseded-by`, and same-second `update-index`
    runs with different results. Same-second runs with the same result do not conflict.
  - Degenerate sides are tested through git in both directions, and so is a signal during the
    `%A` write.
  - The direct cases cover each rule.
  - The registration cases cover a path with a space, a version bump without re-install, numeric
    version order, a pruned dir, no driver at all, and legacy status.

## Related

- `2026-07-29-merge-driver-reads-version-not-schema-version.md`: resolved as a side effect.
- `2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`: its "rebase … driver resolves
  silently" advice is the lossy direction.
- I-1 reduces how often the driver runs, because identical verifications become byte-identical.

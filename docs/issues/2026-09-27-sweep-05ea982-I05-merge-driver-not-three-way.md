---
date: 2026-09-27
status: Open
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

- [ ] Fixtures built with the real verbs and merged with real `git merge`, `git rebase` and
  `git revert` in both directions. Each gives the same, correct result for:
  - deprecate vs update-index;
  - repoint vs add;
  - hand edit vs untouched;
  - delete vs modify;
  - delete on ours;
  - a tie;
  - an older one-sided change.
- [ ] Degenerate sides make the driver exit non-zero with markers in `%A`.
- [ ] `schema_version` survives a merge.
- [ ] Docs no longer claim three-way behaviour the driver lacks, and no longer recommend rebase as
  silent resolution.

## Related

- `2026-07-29-merge-driver-reads-version-not-schema-version.md`: resolved as a side effect.
- `2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`: its "rebase … driver resolves
  silently" advice is the lossy direction.
- I-1 reduces how often the driver runs, because identical verifications become byte-identical.

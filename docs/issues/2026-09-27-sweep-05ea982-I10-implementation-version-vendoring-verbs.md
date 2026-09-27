---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: doc-tools
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-10
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
  - references/doc-spec.md
  - .github/workflows/tests.yml
  - scripts/hooks/install.sh
  - README.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-10 — set-implementation / implementation-status / version / tools-vendoring verbs

> Cluster **I-10** of sweep run `05ea982`, ranked #11 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S2). Fix: **Task 11**
> of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). Removes two of the
> project's three hidden dependencies (GNU sed, ripgrep).

## Summary

`set-implementation` splices user-supplied values into `grep -E` patterns and GNU `sed` program
text:
- ordinary input corrupts the doc;
- a newline in `--note` injects `sed` commands;
- its create path anchors on a header style the shipped templates do not use, so it is a silent
  no-op.

Three parsers read the `Implementation:` / `Realized-by:` block using three different grammars.
The version verbs succeed on zero files. The vendoring verbs delete user files.

## Incorrect assumption

- "Values are inert text inside sed."
- "Every doc has `**Date:**`."
- "Three parsers agree on the block grammar."
- "The working directory is the repo root."
- "The vendored copy is never edited."

## Verified evidence (measured unless noted)

- [P1] `doc-tools.sh:1665,1684-1687,1699-1706`: `--ref/--note/--status` values go into regex and
  sed program text.
  - These inputs corrupt the doc: `R&D`, `(squash)`, `a|b`, backslashes.
  - `PR: #N` refs can delete the bullet.
  - A newline in `--note` injects sed `e`/`w` commands. File creation and write were measured.
- [P1] `:1702-1706`: the create path anchors on `**Date:**`, but the shipped ADR/SPEC templates use
  `**Date**:` / `**Created**:`. Result: rc 0 and a byte-identical file.
- [P1] `:1686-1698,1729-1735` vs `:758-762`: one writer and two readers use different grammars.
  - `Realized-by:` is dropped from the index.
  - An `Implementation: []` append is invisible to the readers.
  - Appends land inside later code fences.
  - Replacement is file-global.
- [P2] `:40-49,1678-1680` (+ `tests.yml:66-71`): GNU sed is a dependency for this one verb only,
  plus a `brew install gnu-sed` CI step. Structural.
- [P2] `:1747-1750`: `implementation-status --filter` is broken on every platform, depends on an
  undeclared `rg`, and has zero callers.
- [P2] `:1410,1417-1418,1447-1452,1280-1281,1300`: `var=$(cmd|filter)` under errexit + pipefail
  aborts silently.
  - `fragments list`: rc 1, no output.
  - `check-version`: rc 2, no output.
  - `bump-version`: partial bump, then rc 5.
- [P2] `:1862-1891`: `tools uninstall` runs `rm -rf` over user-added files in `doc-pr-release/` and
  over a drifted vendored `doc-tools.sh`.
- [P3] Smaller defects:
  - `:1275-1337`: `bump-version`/`check-version` succeed on 0 files; file mode goes from 644 to 600.
  - `:1300,1958`: the version is the first `## vX.Y.Z` substring anywhere; a pre-release suffix
    passes.
  - `:1759-1763,1817-1818`: `tools install` from the vendored copy fails (`cp: same file`).
  - `:1914-1927,1952-1965`: `tools status` from the vendored copy compares the file with itself.
  - `:1343-1433`: dead branches and an O(F²) list rebuild.
  - `:758-768`: the `Implementation:` capture reads inside code fences.
  - `install.sh:22`: the version fallback is unreachable under `pipefail`.

## Proposed fix (fix plan Task 11)

- One awk block locator shared by the three verbs.
- `set-implementation` becomes one awk pass: literal `index()` matching, values passed via
  `ENVIRON`, output to tmp + `mv`. It exits non-zero when no anchor exists and accepts every
  template header style.
- **Delete `gnu_sed()` and the brew step.** Delete `--filter`, or reimplement it with `grep`.
- One `_release_notes_version` helper: line-anchored, outside fences, no pre-release suffix.
- `bump-version` pre-validates all manifests, fails on 0 files and keeps file modes.
- `tools uninstall` compares with `cmp` before deleting. Short-circuit with `[ "$src" -ef "$dest" ]`.

## Acceptance criteria

See fix plan Task 11, Step 1. Additionally:
- [ ] `grep -n 'gsed\|gnu_sed\|\brg\b' scripts/` returns nothing.
- [ ] The README dependency table lists bash, git and jq only (plus POSIX tools).

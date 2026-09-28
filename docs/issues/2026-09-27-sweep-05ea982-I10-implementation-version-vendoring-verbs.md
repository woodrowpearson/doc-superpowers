---
date: 2026-09-27
status: Resolved
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
- [x] `grep -n 'gsed\|gnu_sed\|\brg\b' scripts/` returns nothing.
- [x] The README dependency table lists bash, git and jq only (plus POSIX tools).

## Resolution (Task 11)

Resolved by Task 11 of the fix plan. GNU sed and ripgrep are no longer dependencies:
`gnu_sed()`, the `rg` call and the `brew install gnu-sed` CI step are gone, and the README
dependency table lists bash (≥ 3.2), git, jq and a SHA-256 tool, plus the POSIX userland.

- **One block grammar** (`_AWK_IMPL_BLOCK` in `doc-tools.sh`, documented in
  `references/doc-spec.md` "Header style and the realization block" and in `--help`), shared by
  `set-implementation`, `implementation-status` and `update-index`:
  - the header is `Implementation:` or `Realized-by:` at a line start, outside ```` ``` ```` /
    `~~~` fences; the first one is the block, and `<key>: []` is explicitly empty;
  - entries are `- ` bullets at any indent;
  - an indented line after an entry wraps it (readers join with one space);
  - a blank line, an unindented line or a fence line ends the block.
  - `update-index` now records `Realized-by:` entries, 4-space and wrapped entries, and nothing
    from a fenced example; the stored text is the entry without indent and `- `.
- **`set-implementation`** is one awk pass over the doc (values via `ENVIRON`, matched with
  `index()`, never regex or program text), written to a tmp beside the doc and moved into place,
  keeping its mode. An unchanged result writes nothing.
  - The entry whose text starts with `<ref> —` is replaced in place, with its wrapped lines, only
    inside the block. Otherwise one is appended at the block's indent; `<key>: []` becomes a list.
  - With no block, one is created after the paragraph holding the first `**Date**:`, `**Date:**`
    (→ `Implementation:`), `**Created**:` or `**Created:**` (→ `Realized-by:`) line outside fences.
    With none of those it exits 1 and writes nothing.
  - `R&D`, `a|b`, `(squash)`, backslashes, `PR: #N` and `commit: <sha>` refs are written
    literally. `--status` is matched whole against the enum (`.*` and `complete partial` are
    refused).
  - **Decision:** a line break (LF or CR) in `--ref` or `--note` is refused with exit 2 and
    nothing written, rather than written as a second line: an entry is one bullet line, and a
    raw newline would end the block (the old code let it inject sed `e`/`w` commands). The test
    also proves no command runs and no file is written.
  - A symlinked doc is refused (exit 1), not replaced by a regular file.
- **`implementation-status --filter` is removed** (it never worked and needed `rg`; it had no
  callers). It is now an unknown option (exit 2).
- **Version verbs.** One `_release_notes_version` parser: the first line-anchored `## v…`
  heading outside code fences must be exactly `vMAJOR.MINOR.PATCH` followed by the end of the line
  or a space. A pre-release first heading is an error, not skipped. A missing file or no heading
  is an error with a message; before, the run aborted silently with rc 2.
  - `bump-version` reads and renders every manifest before replacing any. One that is not valid
    JSON writes nothing (exit 1). Finding none is exit 1. Each file keeps its mode.
  - `check-version` exits 1 on zero manifests, where it used to PASS on 0 files. A manifest that
    is not valid JSON is reported INVALID, not a silent abort.
  - The installer (`install.sh:22`) reads its version through the new `tools version`, the same
    parser. A plugin without a readable `RELEASE-NOTES.md` installs with version `unknown`,
    where the pipeline used to abort silently under `pipefail`.
- **Vendoring verbs** (the plugin copy is recognised by `skills/doc-superpowers/SKILL.md` above
  `scripts/` and by `scripts/hooks/ci/`):
  - `tools install --with-helpers` ships every helper the CI templates run: `doc-pr-release/`
    and `doc-superpowers-steps/`. Files go through a tmp beside the destination.
  - `tools uninstall` deletes a file only when it is byte-identical to the plugin's copy.
    A drifted `doc-tools.sh`, an edited helper, a copy from another plugin version and any file
    the user added are kept, and so is their directory; all of them are reported.
  - From a vendored copy: `tools install` onto itself is a no-op (`-ef`), not `cp: same file`.
    `--with-helpers` and `tools uninstall` exit 1 without touching anything. `tools status`
    reports presence only, never "matches plugin" or the consuming repo's version. The git-toplevel
    version lookup is gone.
  - `tools version` (new) prints the plugin's version and exits 1 from a vendored copy.
- **Tests:** 12 new tests in `scripts/test-doc-tools.sh` (`test_i10_*`), plus
  `test_install_ci_version_comes_from_doc_tools` in `scripts/test-hooks.sh`.

**Not in this Task:** the `fragments` items in this issue (`fragments list` silent abort,
O(F²) list rebuild, dead fragment-helper branches) belong to the fragment code that Task 10 (I-9)
rewrites. The `state.sh` tracking of the step-script helpers stays with Task 8, which will delegate
its vendoring to `tools install` / `tools uninstall`.


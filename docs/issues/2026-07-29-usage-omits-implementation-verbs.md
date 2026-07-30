---
date: 2026-07-29
status: Open
priority: P2
type: bug
component: doc-tools
source: manual
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: null
---

## Summary

`doc-tools.sh --help` does not list `implementation-status` or
`set-implementation`. Both have been dispatchable since v2.11.0. A verb that
exists only in the `case` block is a verb nobody discovers, and nothing in the
test suite asserts that the two lists agree.

The same heredoc also misstates what `bump-version` writes.

## Description

### The omission

`usage()` documents twelve subcommands; the dispatcher accepts fourteen.
Verified 2026-07-29 against `scripts/doc-tools.sh`:

| Verb | In `usage()` | In `case` dispatch |
|---|---|---|
| `build-index` | yes | yes |
| `check-freshness` | yes | yes |
| `update-index` | yes | yes |
| `add-entry` | yes | yes |
| `remove-entry` | yes | yes |
| `move-entry` | yes | yes |
| `deprecate-entry` | yes | yes |
| `status` | yes | yes |
| `bump-version` | yes | yes |
| `check-version` | yes | yes |
| `implementation-status` | **no** | yes |
| `set-implementation` | **no** | yes |
| `fragments` | yes | yes |
| `tools` | yes | yes |

Both missing verbs shipped in v2.11.0 (ADR/SPEC realization tracking) and are
documented in `CLAUDE.md`, `docs/codebase-guide.md` and
`docs/architecture/system-overview.md` — every enumeration *except* the one the
user actually reaches by typing `--help`.

### The second defect in the same heredoc

`usage()`'s `bump-version` entry reads:

```
  bump-version VER  Update version string in all manifest files
                    Files: RELEASE-NOTES.md, package.json, claude-code.json,
                    .claude-plugin/plugin.json, .claude-plugin/marketplace.json,
                    .cursor-plugin/plugin.json, gemini-extension.json
```

That is seven files including `RELEASE-NOTES.md`. `VERSION_FILES` holds **six**,
and `RELEASE-NOTES.md` is not among them:

```
package.json  claude-code.json  .claude-plugin/plugin.json
.claude-plugin/marketplace.json  .cursor-plugin/plugin.json
gemini-extension.json
```

This directly contradicts the stated convention that `RELEASE-NOTES.md` is the
canonical version source which `check-version` *reads* and `bump-version` never
writes. v2.13.1 corrected this same claim across the doc set but did not touch
`usage()`, so the help text is now the last place carrying it. It is the more
dangerous place to carry it: a maintainer who trusts `--help` will expect
`bump-version` to have written the release-notes heading and may not check.

Grouped here rather than filed separately because it is one heredoc, one
failure class (help text drifting from implementation), and one fix.

## Steps to Reproduce

1. `scripts/doc-tools.sh --help` — note no `implementation-status`, no
   `set-implementation`, and a seven-file `bump-version` list.
2. `scripts/doc-tools.sh implementation-status docs/` — it runs.
3. `awk '/^VERSION_FILES=/,/^\)/' scripts/doc-tools.sh` — six entries, no
   `RELEASE-NOTES.md`.

## Expected Behavior

`usage()` lists every dispatchable subcommand, and its `bump-version` entry
names the six files that verb actually writes.

## Actual Behavior

Two shipped verbs are undiscoverable from `--help`; `bump-version` is
documented as writing a file it does not write.

## Technical Context

- Both gaps are pure documentation-in-code; no behaviour change is involved.
- Unguarded by tests. `scripts/test-doc-tools.sh` gained a `usage()` assertion
  for `move-entry` in v2.14.0, which is the precedent to generalize — but a
  per-verb assertion list would itself drift.

## Proposed Solution

1. Add both verbs to the `usage()` heredoc, and correct the `bump-version` file
   list to the six `VERSION_FILES` entries.
2. Replace the per-verb `usage()` assertions with a **structural** test that
   extracts the verb set from the `case` block and asserts each one appears in
   `usage()` output. That closes the class rather than the instance, and is what
   would have caught this in v2.11.0. Deriving both lists from one array is the
   stronger fix but is a larger refactor of the dispatcher; the test is the
   cheap guard that makes the omission impossible to ship again either way.

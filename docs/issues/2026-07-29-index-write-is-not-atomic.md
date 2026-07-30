---
date: 2026-07-29
status: Open
priority: P2
type: bug
component: doc-index
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

All five index-mutating subcommands write `docs/.doc-index.json` with
`echo "$index" > "$index_file"`. The redirection truncates the file before the
write, so an interruption at that instant leaves a truncated or empty index —
the whole freshness corpus, not one entry. `build-index` already does this
correctly (render to a tempfile, then `mv`), so the safe pattern is present in
the same script and simply not shared.

## Description

### The five call sites

Verified 2026-07-29 in `scripts/doc-tools.sh`:

| Line | Verb |
|---|---|
| ~792 | `update-index` |
| ~918 | `add-entry` |
| ~980 | `remove-entry` |
| ~1089 | `move-entry` |
| ~1167 | `deprecate-entry` |

All five hold the complete new index in a shell variable and then redirect it
over the live file. `>` truncates on open, so the window between truncation and
the last byte written is a window in which the file on disk is not a valid
index.

`cmd_build_index` (~437) instead does `mktemp` → write → `mv`, which is atomic
within a filesystem. v2.13.1 added that to `build-index` specifically so "a
failed render can no longer truncate a good index" — the reasoning applies
verbatim to the other five and was not extended to them.

### Why it matters more than it looks

- The blast radius is the entire index, not the entry being edited. Recovery is
  a full `build-index`, which re-baselines `code_commit` and `last_verified` for
  every doc — so every doc silently reports `current` afterwards. A crash
  during a one-entry edit therefore costs the freshness history of the whole
  corpus.
- These five verbs are the ones automation calls. `post-commit-sync` runs
  `update-index` after **every** commit, and the CI doc-index workflow runs it
  on push — so the exposure is per-commit, on a path where the process can be
  killed (Ctrl-C on a slow hook, a CI job cancellation, a runner timeout).
- It is not hypothetical filesystem pedantry: the failure is a plain
  interrupted-process case, not a power-loss case.

### Deliberately not fixed alongside `move-entry`

`move-entry` (v2.14.0) follows the sibling `echo >` pattern on purpose. Making
the new verb alone atomic would have left the shared hazard in place while
making it look addressed — and would have made the eventual shared fix touch a
verb that had already diverged. This was raised in that change's plan review as
a P2 and explicitly declined there with that reasoning, recorded rather than
dropped. This issue is where it lands.

## Steps to Reproduce

Not reliably reproducible by hand — it is a timing window. It is established by
reading the code: `echo "$x" > f` truncates `f` before writing. To observe the
truncation directly, interpose a slow write (e.g. run one of the five verbs
against an index large enough that the write is not instantaneous, and send
SIGINT during it) and inspect `docs/.doc-index.json`.

## Expected Behavior

Every index write is atomic: render to a tempfile on the same filesystem, then
`mv` into place. A killed or failed write leaves the previous index intact.

## Actual Behavior

Five of six writers truncate the live index first. An interruption leaves a
partial or empty `docs/.doc-index.json`.

## Technical Context

- The fix is one shared helper — `write_index <json> <path>` doing
  `mktemp` + write + `mv`, with the tempfile created in the index's own
  directory so `mv` cannot cross a filesystem boundary — called from all five
  sites, and ideally from `build-index` too so there is exactly one writer.
- `mktemp -t` (as used elsewhere in the script) places the file in `$TMPDIR`,
  which may be a different filesystem than the repo; `mv` then degrades to
  copy-then-unlink and is no longer atomic. Any fix must create the tempfile
  beside the target, not in `$TMPDIR`.
- A test can assert the pattern structurally (no `> "$index_file"` outside the
  helper), which is cheaper and more durable than trying to test the race.

## Proposed Solution

1. Add the shared `write_index` helper writing beside the target file.
2. Convert all five verbs, and `build-index`, to call it.
3. Add a static assertion to `scripts/test-doc-tools.sh` that the only
   redirection into the index path lives in that helper — the same guard shape
   as the existing bash-4-construct scan.

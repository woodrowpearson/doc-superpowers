---
date: 2026-05-04
status: Open
priority: P2
type: enhancement
component: doc-index
source: manual
related-files:
  - scripts/doc-tools.sh
  - scripts/merge-doc-index.sh
  - scripts/hooks/install.sh
  - .gitattributes
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: null
---

## Summary

`docs/.doc-index.json` rewrites its top-level `generated_at` and `build_commit`
fields on **every** `update-index` invocation, even when no doc content has
changed. Combined with the post-commit hook that runs `update-index` after
every commit, this guarantees a doc-index merge conflict whenever `main`
advances between PR creation and PR merge — even on PRs that don't touch any
documentation.

The shipped merge driver (`scripts/merge-doc-index.sh`, registered via
`.gitattributes: docs/.doc-index.json merge=doc-index`) resolves these
conflicts cleanly **locally**. But GitHub's server-side mergeability check
does not invoke custom merge drivers, so PRs flag "this branch has conflicts"
until a developer rebases manually.

## Description

### Impact

Every consumer of doc-superpowers experiences:

1. **Constant "branch has conflicts" UI noise on GitHub PRs** — even when the
   PR's diff has nothing to do with docs. Reviewers see a red banner; authors
   feel obligated to rebase.
2. **Forced rebase loops** — fix conflict locally, push, `main` advances
   again, repeat. On busy projects this can happen multiple times before a
   PR merges.
3. **Downstream workarounds** — projects end up writing their own GitHub
   Actions to re-run the driver server-side (e.g., `abundance-mvp` is
   currently shipping `.github/workflows/doc-index-resolve.yml`). Each
   consumer has to maintain this themselves; it papers over the symptom.
4. **`last_verified` per-entry timestamps** have a similar (smaller) churn
   problem: `update-index --all` re-stamps every entry even when content
   hashes are unchanged.

### Root Cause

`scripts/doc-tools.sh` writes `generated_at` (current UTC time) and
`build_commit` (current `HEAD`) at the top level of `docs/.doc-index.json`
on every `build-index` and `update-index` invocation. These fields are
**regeneration metadata** — useful for debugging stale indexes — not
review-relevant content. They are not surfaced in any pre-push gate, doc
freshness check, or skill workflow that I can find.

Because they change on every commit (via the post-commit hook), and because
they live as adjacent JSON lines at the top of the file, two PR branches
will always have textual conflicts on these lines after `main` advances.

### Why the merge driver isn't enough

The merge driver works perfectly **locally**: 3-way jq merge, union by key,
newer `last_verified` wins, regenerates `generated_at`/`build_commit` to
current. But:

> **Correction (sweep 05ea982, I-5):** that driver was not three-way and did
> not work perfectly. It used the base only to detect additions, and let the
> entry with the newer `last_verified` carry the whole key. A change only one
> side made was lost whenever the other side's timestamp was newer, and a
> deletion won over a modification. See the Task 6 resolution below.

- GitHub's server-side mergeability check uses `git`'s default text merge
  with no driver registration — it always reports a conflict on this file
  whenever the top-level lines diverge.
- GitHub's web-UI merge buttons (squash/rebase/merge) likewise do not run
  custom merge drivers.

So even with the driver installed, GitHub still surfaces the conflict in the
PR UI until a human rebases locally and pushes the resolved version.

## Steps to Reproduce

1. Open PR A and PR B simultaneously, each touching unrelated code (no doc
   changes on either side).
2. Each branch's post-commit hook runs `update-index`, rewriting top-level
   `generated_at`/`build_commit`.
3. Merge PR A.
4. Observe: PR B now shows "this branch has conflicts" — solely because of
   the top-level metadata divergence in `docs/.doc-index.json`.
5. Rebase PR B locally → driver resolves silently → push. *(Corrected by
   I-5: before Task 6 this silent resolution was lossy, and a rebase lost
   different changes from a merge because it replays in the other direction.
   Do not treat rebase as the safe path. Since Task 6 a rebase gives the same
   docs as a merge, and anything the driver cannot decide stops with conflict
   markers.)*
6. Repeat for the next PR that lands while another is open.

**Frequency:** every PR that overlaps in time with another commit to `main`.

## Expected Behavior

A regenerate of `docs/.doc-index.json` produces **zero git diff** when no
doc content has changed. PRs that don't touch documentation never conflict
on doc-index. The merge driver becomes a fallback for the genuine
content-change case, not a constantly-firing workaround.

## Actual Behavior

`docs/.doc-index.json` rewrites top-level metadata on every invocation,
guaranteeing a conflict surface for every PR.

## Technical Context

- doc-superpowers v2.9.0
- Affected fields:
  - **Top level:** `generated_at`, `build_commit` (rewritten on every
    `update-index`)
  - **Per entry:** `last_verified` (rewritten when `update-index` re-stamps
    even unchanged docs)
- The merge driver (`scripts/merge-doc-index.sh`) already handles these
  fields correctly during local merge — see `newer_entry` jq function and
  the regenerated top-level metadata in the merge output. *(Superseded by
  Task 6: `newer_entry` and the regenerated metadata were the I-5 defect.
  The driver now merges three-way and keeps ours' top level.)*

## Proposed Solution

Split regeneration metadata out of the version-controlled index.

### Option A — Sidecar file (recommended)

```
docs/
  .doc-index.json         # version-controlled; per-doc entries + version
  .doc-index-meta.json    # gitignored; generated_at, build_commit, etc.
```

Changes:

1. `scripts/doc-tools.sh`:
   - `build-index` / `update-index`: write top-level fields to
     `.doc-index-meta.json` (new file, gitignored).
   - All readers that need this metadata (debug output, freshness diagnostics)
     read from the sidecar.
   - The committed `docs/.doc-index.json` becomes content-addressable: it
     only changes when `version`, the `docs` map, or schema metadata
     genuinely changes.
2. `scripts/hooks/install.sh`: append `docs/.doc-index-meta.json` to
   `.gitignore` if not present.
3. `scripts/merge-doc-index.sh`: simpler — no longer needs to regenerate
   `generated_at`/`build_commit` since they're not in the merged file.
4. Per-entry `last_verified`: keep current behavior, since this IS
   review-relevant (signals when freshness was last confirmed). But change
   `update-index --all` to only re-stamp entries whose content hash actually
   changed, not blindly re-stamp every entry.

### Option B — Git notes

Same idea, but use `git notes` instead of a sidecar file. Cleaner from a
filesystem perspective but adds a `git notes` operation to every
`update-index`, which is more friction than `.gitignore`'d JSON.

### Option C — Determinism only

Keep the metadata in `.doc-index.json` but make values content-derived
(e.g., `generated_at` = mtime of newest tracked doc, `build_commit` =
commit that last modified any tracked doc). Eliminates churn but changes
the meaning of these fields. Less clean than splitting; not recommended.

## Acceptance Criteria

- [ ] Running `update-index` (or `update-index --all`) on a state where no
      tracked doc has changed produces a `git diff` of zero bytes on
      `docs/.doc-index.json`.
- [ ] Two simultaneous PRs that don't touch documentation never conflict
      on `docs/.doc-index.json`.
- [ ] The merge driver still works correctly for the genuine
      content-change case (covered by `scripts/test-merge-driver.sh`).
- [ ] `last_verified` only updates when `content_hash` actually changes.
- [ ] Migration: existing `docs/.doc-index.json` files in consumer repos
      either auto-migrate on first `update-index` post-upgrade, or the
      release notes document a one-line migration command.

## Open Questions

1. **Is `last_verified` review-relevant enough to keep version-controlled?**
   Arguments for: pre-push gate uses it to decide what's stale. Arguments
   against: same churn problem at smaller scale, and "last verified" can be
   derived from git log of the doc itself.
2. **Migration path for in-flight PRs:** when this lands, every consumer's
   open PRs will conflict once on the schema change. Worth gating behind a
   major version bump (v3.0.0) with a clear release note.
3. **Does GitHub-side mergeability check now pass without the per-PR
   workflow?** Should test in a consumer repo before declaring victory —
   the workflow is belt-and-suspenders even after this lands.

## Resolution (partial — sweep 05ea982 Tasks 4 and 6; T7 closes the rest)

Task 4 ([I-1](2026-09-27-sweep-05ea982-I01-freshness-identity-model.md)) removes most of the
*content* churn from this conflict surface. It does not change the top-level metadata:

- **Verification is content-addressed.** A doc's freshness is its refs' object ids (`code_oids`), not
  the id of the last commit touching them. Two branches that verify the same bytes now write the same
  `code_oids`. Squash merges, rebase-merges and cherry-picks no longer re-stale a doc that then needs a
  fresh `update-index` (and a fresh index diff) on each branch.
- **A no-op write is still byte-identical** (T2): nothing is written, and `generated_at` is not bumped.
  The first real write stamps `schema_version: 3`.

Left for the owning Tasks: the premise that a post-commit hook runs `update-index` on every commit was
refuted (see I-6; T7 removes that dead call and moves pre-commit to `--tree`). The merge driver's
three-way semantics are I-5 (T6). `last_verified` re-stamping belongs to T5. This issue stays open
until those land.

### Task 6 ([I-5](2026-09-27-sweep-05ea982-I05-merge-driver-not-three-way.md))

The local half of this issue rested on the driver, and the driver was lossy. Task 6 replaces it with
a base-aware, per-key three-way merge.

- **A change only one side made always survives.** This holds for a deprecation, a repoint, a
  re-verification, a hand edit and a deletion, in every direction: `git merge` either way,
  `git rebase` either way, and `git revert`.
- **The same docs either way.** Rebase is no longer a riskier path than merge: both give the same
  docs, with no exception. When both sides changed one field to different values and
  `last_verified` does not say which is newer, the merge stops with markers naming the key and
  field in every direction. Only `update-index` writes `last_verified`, so this is the usual case
  for two edits of one field, for example two `set-code-refs` runs or a repoint against a
  re-deprecation.
- **A merge adds no metadata churn of its own.** The top level starts from ours, so
  `generated_at` and `build_commit` are no longer rewritten to merge time and HEAD, and the key
  order is kept rather than re-sorted.
- **Undecidable changes stop the merge.** The same field changed on both sides with no newer
  `last_verified`, an entry deleted on one side and changed on the other, or
  a malformed side, leaves conflict markers and exit 1 instead of a silent guess.
- **The server-side half is unchanged.** GitHub's mergeability check and merge buttons still do
  not run custom drivers. That remains open with T7 and the workaround below.

## Workaround (current)

Consumers can ship a GitHub Actions workflow that runs the merge driver
server-side on `pull_request` events. Reference implementation:
`woodrowpearson/abundance-mvp`'s `.github/workflows/doc-index-resolve.yml`.
This is what motivated this issue — the workaround works, but every
consumer of doc-superpowers shouldn't have to write it.

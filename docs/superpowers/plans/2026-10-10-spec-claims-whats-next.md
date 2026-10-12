# Spec claims — what's next (execution handoff, 2026-10-12)

Plan: [`2026-10-10-spec-claims.md`](2026-10-10-spec-claims.md) · Design: [`../specs/2026-10-10-spec-claims-design.md`](../specs/2026-10-10-spec-claims-design.md) · Branch: `design/spec-claims`

## Where execution stopped

**Tasks 1–13 are complete and reviewed** (Chunks 1–3). HEAD of `design/spec-claims` before this note: `7227199`. Every task got an independent spec + quality review, and every Critical/Important finding was fixed and re-reviewed.

| Chunk | Tasks | Last commit |
|---|---|---|
| 1 — validate core | 1–6 (verb group, V1, V2, V5, V6, render + V11) | `f439332` |
| 2 — runners | 7–10 (adapters + `claims run`, V3, V4, V9) | `703596d` |
| 3 — promote | 11–13 (mutant, `observed_red`, verdict store, `--reverify`) | `7227199` |

At `7227199`, all six suites pass under bash 5.3 and `/bin/bash` 3.2. The new suite `test-spec-claims.sh` has 1657 assertions; the counts in `CLAUDE.md` are not updated yet (Task 30 does that).

**Task 14 (plan parser + V12) was interrupted.** The implementer's unreviewed work, with no confirmed test results, is parked on branch **`wip/spec-claims-task-14`** (`f760162`, committed with `--no-verify`). Either resume from it (run both interpreters, then review), or restart Task 14 from `design/spec-claims`.

## Resuming

The SDD progress ledger is local, gitignored scratch on `w-mm`:
`.worktrees/spec-claims-design/.superpowers/sdd/2026-10-10-spec-claims/progress.md`
It sits next to the per-task briefs, reports, `plan-context.md`, `implementer-common.md` and `reviewer-common.md`. On another machine, copy that directory over, or rebuild it with the subagent-driven-development skill's `task-brief` script. Resume at **Task 14**; never re-run Tasks 1–13.

## Controller rulings that later tasks must follow

These overrule or sharpen plan text. Each is recorded in the ledger with its reasoning.

- **Fences follow CommonMark pairing.** A fence closes only on the same character with a run at least as long as the opener's. Use the jq `claims_fence_kinds` everywhere: Task 14's plan parser and Task 18's section tracker included. Never a bare toggle.
- **AMENDED-block membership** is read from the source lines, before `~~…~~` strikes are blanked.
- **Re-promote owed, verdict missing** (Task 5): compare the claim's `states` and `test` in the sidecar at `promotion.at` with the current record. If they differ, it is `owed`; if `promotion.at` is unresolvable, or the sidecar or claim is absent there, it is `unverifiable-here`. There is no ruling-ancestry walk. `<since-rev>` stays in the signature but is unread. Tasks 16/17 consume this.
- **Path safety** (Tasks 6–12). Every repo path taken from a sidecar or config (doc, tracker, record, adapter, `test.file`, lint paths, mutant file, subjects) goes through `_claims_safe_relpath`, plus `_claims_contained_path` (no symlinked component, physically inside the root) when it is read from or written to a work tree. An unsafe path is a finding or a skip, never read or written.
- **`_claims_parse_run <out> <nodes> <rc>`** and `_claims_parse_log`: the rc is **required**, never defaulted.
- **Promote proof path** (`_claims_prove`, shared with `--reverify`):
  - the green run in the work tree, then the unmutated node must `pass` in the clean worktree;
  - the mutant file must round-trip through jq unchanged (UTF-8), and must not be the bound test's own file;
  - `observed_red` must be a full-length commit id; a subject must not be or contain the test file;
  - when both proofs are present, both must hold.
- **V3 mutant uniqueness** is checked only for `built`/`gated` claims. A frozen claim skips the adapter- and tree-dependent parts of V3.
- **V4.** Selftests are written as lines. An `unbuilt` lint claim may lack its file; an unsafe path is a finding for every status.
- **V9.** An adapter rc ≠ 0, or an implausible id line, is indeterminate, never empty.
- **No repo-wide `git worktree prune`.** Cleanup removes only the worktrees it registered.
- **`--planes-of` computes its path set in one helper**, `_claims_range_paths`.

## Open decisions for upcoming tasks

1. **Task 16 range rule: trunk merges.** As planned, `claims gate` over `<from>..HEAD` would include files and commits brought in by merging the base into the branch. That affects `--planes-of`, V8/V9 hunks and the chunk record's patch-ids.
   - The proposed rule, verified on a real gate run: first-parent non-merge commits (`git log --first-parent --no-merges <from>..HEAD`) for files, hunks and patch-ids. Plus, for each first-parent merge M in range, `git show --cc M`, which yields only conflict resolutions and evil-merge edits.
   - Caveat: `--cc` hunks are combined-diff format (`@@@`), so V8/V9 hunk parsing must handle them or use only the `--name-only` file list.
   - Decide this at Task 16. Check that Task 17's patch-id matching uses the same set.
   - The orchestrator conformance design in the host project wraps `claims gate`, and its own range script already uses this rule. Tell that side the final rule.
2. **Task 21 (`gated`).** Promote's verdict records `status_to: built`, while `_claims_verdict_check` requires `status_to == claim.status`, so a `gated` claim's verdict reads `mismatch`. Decide promote's `status_to` for gated claims.
3. **Task 27 (pre-commit hook).** Adapter stderr passes through, so the hook must not capture the claims call with `2>&1`; a backgrounded adapter child could hold the capture open.

## Before merge

- **Perf budgets.** The doc-tools 4000-key `add-entry` / `update-index` budgets under `/bin/bash` missed in Tasks 4, 8 and 10 (21–23 s against 20 s), always under host load average 7–22, and passed on quieter re-runs (17–18 s). Script growth adds only about 0.02 s per invocation. Re-run on an idle machine before merge; CI's macOS leg enforces these budgets.
- **Deferred minor findings.** About 60 are recorded in the ledger (`minor (deferred)` lines). The final whole-branch review triages which must be fixed before merge.

## Remaining tasks

14 (redo or resume) → 15–19 (Chunk 4: gate records, `claims gate`, `attest`, V8, V8n) → 20–23 → 24–29 (references, spec-lifecycle wiring, hooks, CI templates, `references/spec-claims.md`) → 30–31 (counts, release 3.2.0) → the final whole-branch review → finishing the branch.

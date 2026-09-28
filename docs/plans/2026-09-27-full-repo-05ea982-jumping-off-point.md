---
date: 2026-09-27
status: Draft
type: plan
source: sweep-skill
run-id: 05ea982
related-files:
  - docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
  - docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md
  - docs/plans/2026-09-27-full-repo-05ea982-evidence.md
---

# doc-superpowers sweep `05ea982` — Jumping-off point

> The resume sheet for the session that **executes** the sweep's fix plan. The audit itself is done.
> **Execution is in progress. T1–T7 are done.** See [Execution status](#execution-status-paused-2026-09-27) below.

## Execution status (paused 2026-09-27)

Branch: `claude/resume-plan-execution-03646c` (pushed). It was branched from
`claude/affectionate-turing-tu1o9x` @ `b59375f`. Every Task went through
`superpowers:subagent-driven-development`: one implementer, then a spec + quality review, then
fix rounds until the re-review was clean. Each Task's step 1 was a failing test (TDD).

| Task | Cluster | Commits | Review |
|---|---|---|---|
| T1 harness | I-13 | `8630c5b`..`184daa7` | clean after 2 fix rounds |
| T2 persistence | I-2 | `c74f578`..`1d295c6` | clean after 1 |
| T3 CLI/input | I-4 | `37be531`..`15b3109` | clean after 1 |
| T4 content identity | I-1 | `c3cf36c`..`eb7a3ce` | clean after 2 |
| T5 honest state (closes #18) | I-3 | `f770ade`..`16050ba` | clean after 3 |
| T6 three-way merge driver (P0) | I-5 | `63fd1c5`..`e0a6526` | clean after 1 |
| T7 hook tier | I-6 | `f68c978`..`0c31a8e` | clean after 1 |

**Tests:** 2052 assertions per interpreter, 0 fail, 2 known XFAILs owned by T10. Verified locally
under bash 5.3 and `/bin/bash` 3.2.57, and under a BSD-only PATH. CI is still down because of the
GitHub account billing lock (Gotcha 1).

**Next:** T11 → T8 → T9 → T10 → T12 → T13 → T14, strictly in that order. There are no parallel
worktrees: T10 and T11 share doc-tools.sh, and T6 and T8 share install.sh. T11 runs before T8 so
that T8 can delegate vendoring to the fixed `tools` verbs. After T14 come, in order:
1. the final whole-branch review, with one fix wave;
2. `/doc-superpowers audit`, then `update`, then `diagram` (the owner's directive);
3. the release flow: draft notes, `bump-version 3.0.0`, `check-version`.

**Ledger:** [`2026-09-27-full-repo-05ea982-execution-ledger.md`](2026-09-27-full-repo-05ea982-execution-ledger.md)
is a committed copy of the controller ledger. It holds:
- every ruling, with its cost if wrong;
- every deferred minor, most of them routed to a later Task;
- items carried into later Tasks' dispatches.
Read it before dispatching T11.

**Carry-forwards the next session must not drop:**
- **Deferred-important for the final wave:** readers can still show a masked `commits_behind: 0`
  after `update-index` captured uncommitted content. The suggested fix is `stale && count==0 → null`.
- **T8:**
  - the integration block drops `"$@"`, stdin, stderr and the exit code;
  - `$CLAUDE_PROJECT_DIR` command strings;
  - the `--helpers=false` refusal is not state-aware;
  - hooks installed into a quoted path break via `sed`;
  - re-register the merge driver for existing installs.
- **T10:** the 7 V-FU1 fragment mutants from I-13; the 2 XFAILs (extract-context base-commit leak;
  commit-and-push sweeping pre-staged files); porcelain `git log` in `fragments merge`.
- **T14:**
  - retype the 6 design specs typed `spec` as `design-spec`;
  - three legacy non-ancestor `code_commit`s (`abb3e64`, `c2496da`, `f063b04`);
  - this repo's own `.git/hooks` and `.claude/hooks` are still the old copies. The old
    prepare-commit-msg injects `# stale:` lines into `-m` messages, so commit with
    `git commit --cleanup=strip` until T14 re-installs;
  - the stale suite counts in docs.
- **Commit messages:** T1's three commits carry injected `# stale:` body lines. They were
  deliberately not rewritten, because rewriting would orphan the `code_commit`s recorded in the
  index.

## Resume prompt (paste into a fresh session)

```text
Execute the doc-superpowers sweep fix plan, run-id 05ea982.

Execution is IN PROGRESS on branch `claude/resume-plan-execution-03646c` (T1–T7 done). Continue
on that branch. Read the "Execution status" section of the jumping-off point and the execution ledger
(docs/plans/2026-09-27-full-repo-05ea982-execution-ledger.md) first, and resume at T11.
Do not re-run completed Tasks.

Read first, in order:
  1. docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md   (this file: priorities + gotchas)
  2. docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md            (Tasks T1–T14, TDD steps)
  3. docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md       (evidence, by surface)
  4. The cluster issue named by the Task you are starting (docs/issues/2026-09-27-sweep-05ea982-I*.md)
  5. docs/plans/2026-09-27-full-repo-05ea982-evidence.md — verifier reports + prototypes, when you need
     the exact reproduction behind a finding

Use superpowers:subagent-driven-development: one fresh implementer per Task, review between Tasks.
Order: T1 → T2 → T3 → T4 → T5 strictly in sequence; then T6/T7/T8/T10/T11 in parallel worktrees;
T9 after T7+T8; T12 after T3–T11; T13 after T12's tool-resolution decision; T14 last.

Constraints:
- zero new dependencies (bash 3.2 + BSD userland + git + jq + POSIX);
- tool ↔ prompt lockstep in the same Task;
- tests never run tools with the real repo as cwd;
- every Task's Step 1 is a failing test first.

Close-out per Task:
- set the cluster issue to `status: Resolved`;
- run `scripts/doc-tools.sh update-index` for each doc edited;
- commit as `<type>(<scope>): … (sweep 05ea982 I-N)`.

Before T1: confirm GitHub Actions is executing again in this repo (see Gotcha 1). Without CI,
no Task's bash-3.2 claim can be checked.
```

## Priority order (by weight: severity × blast radius × how cheap the foundation is)

| # | Do | Why now | Cluster / Task |
|---|---|---|---|
| 0 | **Owner action: get GitHub Actions executing again**, then require the Tests jobs on `main` | Since 2026-08-31 every job fails in 2–6 s with no logs, so v2.15.0 merged untested. Every later Task depends on the bash-3.2 leg | I-14 (settings, not code) |
| 1 | ~~Merge **PR #16**~~ **Done**: merged `ae05f65` (2026-09-27) | Its issue record `docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md` is now on `main`; T5 closes it | I-3 / T5 |
| 2 | T1 harness | Until this lands, a green run can be a false PASS, and the suite can write into a contributor's global hooks dir | I-13 |
| 3 | T2 persistence primitive | Every writer, the lock and the signal handling are built on it | I-2 |
| 4 | T3 CLI/input | One parser for args and one for stdin lines; the tab-collapse false-current bug | I-4 |
| 5 | T4 content identity | The biggest win: squash/rebase/shallow correctness and O(N·H) → one batch-check | I-1 |
| 6 | T5 honest state | Closes GH #18 and the PR #16 issue record; stops un-deprecation | I-3 |
| 7 | T6 three-way merge driver | The only **P0** | I-5 |
| 8 | T7 hooks → T8 installer → T9 CI | Makes the hook and CI tiers real; T9 closes GH #5 | I-6, I-7, I-8 |
| 9 | T10 fragments, T11 verbs | Lossy consumer; set-implementation injection; drops GNU sed and rg | I-9, I-10 |
| 10 | T12 prompts, T13 packaging, T14 dogfood | The prompts must describe the fixed tools; dogfood last | I-11, I-12, I-14 |

**If only one thing ships:** T6 (P0, self-contained, one file + tests).
**If only one foundation ships:** T2 + T4 together. They remove the largest classes of wrong answers
and the scaling cliff.

## Inventory (artifacts of this run)

- Findings index: `docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md`. It has no `status:`
  by design.
- Fix plan: `docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md` (`Draft`, 14 Tasks).
- Cluster issues: `docs/issues/2026-09-27-sweep-05ea982-I01 … I14-*.md`, all `Open`.
  - Dedup key in frontmatter: `cluster-key: sweep-skill:full-repo:I-N`.
  - They are local issue records only. Nothing was filed on GitHub.
- Open GitHub items the plan closes: **GH #5** (T9, via `github_token`, not `id-token: write`),
  **GH #18** (T5, `set-code-refs`), and `docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md`, filed by PR #16 and merged (T5, batch `move-entry`).
- Older local issues the plan closes:
  - `2026-07-29-index-write-is-not-atomic` (T2);
  - `2026-07-29-usage-omits-implementation-verbs` (T3);
  - `2026-07-29-merge-driver-reads-version-not-schema-version` (T6);
  - `2026-05-04-doc-index-metadata-rewrite-on-every-commit`: its stated cause is refuted; T4, T6 and
    T7 remove the real causes.

## Gotchas

1. **CI is not executing.** From 2026-08-31, every run of every workflow here ends `failure` in 2–6 s,
   with no logs (log download returns HTTP 404) and empty check output. The API cannot show the
   cause. Check Actions billing/spending limits and whether Actions is enabled for the repo or
   account. Do not diagnose this as a test failure, and do not push "fixes" for it.
2. **Never run doc-tools, hooks or the installer with this repo as cwd while testing.** Two
   sweep verifiers did it by accident: one overwrote `docs/.doc-index.json` with a fixture, the
   other left a stray `docs/a.md`. Work in `mktemp -d`. T1 makes the harness enforce this.
3. **The test suites currently encode the wrong contracts.** The Claude hook tests inject
   `TOOL_INPUT`, so the *correct* fix makes 4 of them fail. Change the test to the real stdin
   contract first. Do not revert the fix to satisfy the old test.
4. **Do not "fix" the dead `update-index` call in `post-commit-sync.sh` / `session-summary.sh`.
   Delete it.** A working version would stamp every doc as verified without anyone reading it.
5. **Do not ship `id-token: write` for GH #5.** It swaps in a Claude App token that `permissions:`
   does not bound, and bot pushes re-trigger workflows. Use
   `github_token: ${{ github.token }}`.
6. **bash 3.2:**
   - no `local -n`, `declare -A`, `${x,,}`, `mapfile`, `[[ -v`, `|&`, `;&`, `read -N`, `exec {fd}>`;
   - guard `"${arr[@]}"` when the array may be empty under `set -u`;
   - no `sed -i`, `sort -V`, `readlink -f`, `date -d`, `stat -c`, `timeout`;
   - use a `mkdir` lock, not `flock`.
7. **Index schema v3 is additive.** Readers must keep handling legacy entries without `code_oids`
   (fall back to `code_commit`) until they are re-verified. Writers must refuse `code_commit` in a
   shallow clone.
8. **Merge-driver changes reach existing installs only through re-registration.** The driver is
   registered by absolute path into the versioned skill directory. T6 changes that; T8 re-registers.
9. **Record docs** (plans, issues, audits, design specs, archive) will stop being reported stale
   after T5. Expect this repo's stale count to fall from 23 to about 2. That is the intended result,
   not a regression.
10. **Versioning:** RELEASE-NOTES.md is canonical. Use `bump-version` then `check-version`; never
    edit manifest versions by hand. Suggested: T2–T5 + T8 defaults + T9 removal ship as **v3.0.0**.
12. **The "obvious" one-pass fragment consumer is wrong as written.**
    `git log --diff-filter=A <s>..<e> -- RELEASE-NOTES.next/` misses renamed fragments (it reports
    them as `R`) and fragments added in merge commits. Use `--no-renames`, and decide the
    merge-commit policy explicitly. The fixture table is in V-FU1 in the
    [evidence appendix](2026-09-27-full-repo-05ea982-evidence.md).
13. **Changing extract-context payloads:** Linux's limit is per argument (128 KiB), not only total.
    Anything index- or PR-sized goes through stdin or files, never argv or a single env var. The same
    rule underlies I-8's E2BIG.
11. **Coverage caveats carried forward** (Phase-4 attestation):
    - portability verdicts are structural until the macOS leg runs;
    - the provisional P1s need one real run before their cluster closes: the AI templates being
      inert, the `doc-release.yml` `contains` check, and the Cursor install path.

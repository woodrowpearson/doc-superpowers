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
> Nothing below has been implemented yet.

## Resume prompt (paste into a fresh session)

```text
Execute the doc-superpowers sweep fix plan, run-id 05ea982.

The sweep artifacts were committed on branch `claude/affectionate-turing-tu1o9x`. Start from that
branch, or from `main` once that branch has been merged. If `docs/plans/2026-09-27-full-repo-05ea982-*`
is missing, you are on the wrong base.

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

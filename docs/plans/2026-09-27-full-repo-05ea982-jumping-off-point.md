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
> **Execution is in progress. T1–T14 are done and reviewed. The final-review fix wave is paused
> after its first area (core tools).** See [Execution status](#execution-status-paused-2026-09-28).

## Execution status (paused 2026-09-28)

- **Branch:** `claude/resume-plan-execution-03646c`, branched from `b59375f`.
  - It is **not pushed** past `1070fb1`: this pause stays on the same host.
  - HEAD is the handoff commit (docs only) on top of `34a3841`.
- **Worktree:** `/Volumes/abundance-worktrees/abundance-mvp/doc-superpowers/resume-plan-execution-03646c`, on the external volume. Its git common dir is `/Users/w/code/doc-superpowers/.git`.
- **Process:** every Task went through `superpowers:subagent-driven-development`: one implementer, a spec + quality review, then fix rounds until the re-review was clean. Each Task's Step 1 was a failing test.

| Task | Cluster | Commits | Review |
|---|---|---|---|
| T1 harness | I-13 | `8630c5b`..`184daa7` | clean after 2 fix rounds |
| T2 persistence | I-2 | `c74f578`..`1d295c6` | clean after 1 |
| T3 CLI/input | I-4 | `37be531`..`15b3109` | clean after 1 |
| T4 content identity | I-1 | `c3cf36c`..`eb7a3ce` | clean after 2 |
| T5 honest state (closes #18) | I-3 | `f770ade`..`16050ba` | clean after 3 |
| T6 three-way merge driver | I-5 | `63fd1c5`..`e0a6526` | clean after 1 |
| T7 hook tier | I-6 | `f68c978`..`0c31a8e` | clean after 1 |
| T11 implementation/version/vendoring verbs | I-10 | `1070fb1`..`71eceb2` | clean after 1 |
| T8 installer | I-7 | `71eceb2`..`1ab0557` | approved, 0 rounds |
| T9 CI templates (closes #5) | I-8 | `1ab0557`..`5d5f8aa` | clean after 2 |
| T10 release fragments | I-9 | `5d5f8aa`..`888dfd7` | clean after 1 |
| T12 skill prompt ↔ tool contract | I-11 | `888dfd7`..`fa8384a` | clean after 1 |
| T13 cross-client packaging | I-12 | `fa8384a`..`8e9d4f6` | approved, 0 rounds |
| T14 dogfood + living docs | I-14 | `8e9d4f6`..`cfabc56` | approved, 0 rounds |

**Final whole-branch review.** It ran at `cfabc56` as five area seats in parallel, because the diff is about 2.4 MB: core tools, installer + hooks, CI, prompt layer, and living docs. Every seat returned "With fixes": 0 Critical, 14 Important, about 30 Minor.
- **Fix wave:** ONE wave, specified in `final-fix-wave.md` with rulings F1–F10.
- **Area 1 (core tools) is done:** `34a3841`.
- **Remaining areas:** installer + hooks, then CI, then prompt layer, then living docs + the follow-up issue.

**Tests at `34a3841`:** 3447/3447 under both bash 5.3 and `/bin/bash` 3.2.57, with 0 XFAIL:
- doc-tools 1279
- hooks 844
- spec-status-model 432
- doc-pr-release 406
- merge-driver 486

The BSD-PATH legs are green and `check-version` passes. CI is still down (billing lock, Gotcha 1).

**Host-local state.** All of this is git-ignored and exists only in this worktree, under `.superpowers/sdd/2026-09-27-full-repo-05ea982-fix-plan/`:
- `progress.md`: the live ledger. It is authoritative. The committed copy is [`2026-09-27-full-repo-05ea982-execution-ledger.md`](2026-09-27-full-repo-05ea982-execution-ledger.md).
- `final-fix-wave.md`: the fix wave's requirements and binding rulings F1–F10.
- `final-review-findings-seat{1..5}-*.md`: every finding, with evidence and file:line.
- `final-fix-wave-report.md`: its `## Paused` section lists every item ID as DONE (with its commit) or remaining (with what is left).
- `final-fix-wave-drafts/`: unapplied drafts, for example the "Upgrading from 2.x" section and the follow-up issue.
- `task-*-brief.md`, `task-*-report.md`, `task-*-carry.md`: per-Task records. Each report has a "v3.0.0 release-note behaviour changes" section.

**Next, in order:**
1. **Resume the fix wave.** Dispatch a fresh implementer (opus) on `final-fix-wave.md` plus the report's `## Paused` section.
   - Go area by area: installer + hooks, then CI, then prompt layer, then living docs + the follow-up issue doc (F10).
   - Five living docs read stale after `34a3841`: system-overview, codebase-guide, conventions, getting-started, and workflows/doc-superpowers. The docs area reads them, fixes them, and runs `update-index`.
2. **Run ONE scoped re-review of `cfabc56..HEAD`** against `final-fix-wave.md`, then adjudicate the residuals. There is no second fix wave.
3. **Run `/doc-superpowers audit`, then `update`, then `diagram`** (the owner's directive), using this branch's tools. Also re-render the system-overview PNG, which still says "15 subcommands".
4. **Release flow.**
   - Draft the v3.0.0 notes with `/doc-superpowers release`. Collect each Task report's v3.0.0 section, the fix-wave report's, and the "Upgrading from 2.x" section.
   - Run `bump-version 3.0.0`, then `check-version`.
   - Tag and push `v3.0.0`: the AI templates install the plugin from tag `v<version>`.
5. **Finish.**
   - List every `Ruling:` line from the ledger for the owner.
   - Delete the plan workspace only after the release.
   - Then run `superpowers:finishing-a-development-branch`.

**Owner follow-ups after merge.** These are for the owner, not agent tasks:
- **Shared git hooks point here.** T14's dogfood install wrote the hooks and merge-driver config shared by every checkout in `/Users/w/code/doc-superpowers/.git`, and they point at this worktree's `scripts/`. If the volume is missing they degrade safely: pre-commit skips, and the merge driver leaves conflict markers. After merging, run `scripts/hooks/install.sh install --git --claude` from the main checkout.
- **The main checkout's Claude files will be deleted.** Merging removes its tracked `.claude/settings.local.json` (21 permission rules) and `.claude/hooks/doc-superpowers/*.sh`. Restore the settings with `git show ORIG_HEAD:.claude/settings.local.json > .claude/settings.local.json`, then run `install --claude`.
- **One item is deferred by F8 and could still be pulled in.** In one worktree, `uninstall --claude` removes the `info/exclude` block that every worktree shares, so the other worktrees' per-user `.claude` files show as untracked.

## Resume prompt (paste into a fresh session)

```text
Resume the doc-superpowers sweep 05ea982 execution in THIS worktree (branch
claude/resume-plan-execution-03646c). T1–T14 are complete and reviewed — do NOT re-dispatch them.
The final whole-branch review is done; its ONE fix wave is PAUSED after area 1 (core tools,
commit 34a3841).

Read first, in order:
  1. docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md — "Execution status (paused 2026-09-28)"
  2. .superpowers/sdd/2026-09-27-full-repo-05ea982-fix-plan/progress.md — the live ledger (tail first)
  3. .superpowers/sdd/2026-09-27-full-repo-05ea982-fix-plan/final-fix-wave.md — fix-wave requirements + rulings F1–F10
  4. .superpowers/sdd/2026-09-27-full-repo-05ea982-fix-plan/final-fix-wave-report.md — "## Paused" (done vs remaining per item)

Use superpowers:subagent-driven-development as the controller:
  - Dispatch ONE fresh implementer (opus) to finish the fix wave from final-fix-wave.md + the
    report's "## Paused" section: installer+hooks → CI → prompt layer → living docs + follow-up
    issue (F10). It appends to final-fix-wave-report.md and commits per area.
  - Then ONE scoped re-review of cfabc56..HEAD (skill's re-review-prompt.md) against
    final-fix-wave.md; adjudicate residuals (park with rulings); no second fix wave.
  - Then /doc-superpowers audit → update → diagram (owner directive), then the release flow
    (v3.0.0 notes, bump-version 3.0.0, check-version). Ask the owner before any push or tag push.
  - Record every decision in the ledger as "Ruling: … — why — cost if wrong".

Constraints: zero new dependencies (bash 3.2 + BSD userland + git + jq + POSIX); tool ↔ prompt
lockstep; tests never run tools with the real repo as cwd; both interpreters
(/opt/homebrew/bin/bash and /bin/bash) + BSD-PATH legs before each commit; never launch suites
with `&`; commit with `git commit --cleanup=strip`; never push without the owner; no `git stash`.
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

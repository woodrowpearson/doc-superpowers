---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: docs
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-14
run-id: 05ea982
related-files:
  - .github/workflows/doc-freshness-pr.yml
  - .github/workflows/doc-freshness-schedule.yml
  - .github/workflows/doc-index-update.yml
  - .github/workflows/tests.yml
  - .claude/settings.local.json
  - .claude/hooks/doc-superpowers/pre-commit-gate.sh
  - .claude/hooks/doc-superpowers/post-commit-sync.sh
  - .claude/hooks/doc-superpowers/session-summary.sh
  - .gitignore
  - CLAUDE.md
  - README.md
  - docs/codebase-guide.md
  - docs/conventions.md
  - docs/workflows/doc-superpowers.md
  - docs/architecture/system-overview.md
  - docs/.doc-index.json
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-14 — Self-dogfooding gap and living-doc drift

> Cluster **I-14** of sweep run `05ea982`, ranked #14 of 14 by finding weight. Priority is raised
> to **P1** by the CI-execution finding below, which was confirmed after Phase 4. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S11, S5, S6, Phase 4).
> Fix: **Task 14** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md), except the
> CI-execution item, which is a repository-settings action for the owner and is **not** a code
> change.

## Summary

This repository installs its own Claude and CI tiers, but none of them has been working:
- **CI tier:** the self-installed workflows call `.github/scripts/doc-tools.sh`, which was never
  committed, and the gate fails open.
- **Claude tier:** the hooks are pinned to `/Users/w/…` paths, and the tier could not have fired
  anyway (I-6).
- **Tests workflow:** since 2026-08-31 *every* GitHub Actions job in the repo has ended as `failure`
  within 2–6 s with no logs. v2.15.0 (PR #17) merged with the Tests workflow red and never executed.
  Its bash 3.2 leg last ran on 2026-07-30.

Because the tool never ran against itself, none of the runtime defects in I-6 and I-8 surfaced. The
living docs also describe features that do not work, and repeat counts that have drifted.

## Incorrect assumption

- "Hand-mirrored self-installs stay current."
- "A green badge once means CI is running."
- "Counts copied into N docs stay in sync."
- "Refreshing the index == verifying the doc."

## Verified evidence

- **[P1, new after Phase 4; measured via the GitHub API]** Actions jobs are not executing.
  - Every workflow run from 2026-08-31 onward concluded `failure` within 2–6 s:
    - Tests runs 8–11, both the `ubuntu / bash 5.x` and `macos / bash 3.2` jobs;
    - Doc Index Update runs 19–20;
    - Doc Freshness Check run 20;
    - Doc Freshness Audit (Scheduled) runs 23–26, the latest on 2026-09-21.
  - Job logs return HTTP 404 and check runs carry no output, which is consistent with jobs that
    never started.
  - The last run that actually executed was the scheduled audit on 2026-08-24 (success, 10 s).
  - The cause is **needs-runtime**: it is not visible through the API. Typical causes are an Actions
    spending limit or billing lock, or Actions disabled for the repo or account; macOS minutes bill
    at 10×.
  - Consequences:
    - PR #17 (v2.15.0) and HEAD `05ea982` merged without the five suites ever running in CI;
    - the "696 assertions in CI on bash 5.x and 3.2" claim in CLAUDE.md is unverified for v2.15.0;
    - the sweep measured 696/696 locally on bash 5.2 only.
  - PR #17 merged about 3 minutes after its Tests check failed. Either `main` has no required status
    checks, or they were bypassed. The API calls used here cannot tell which.
- [P1] `.github/workflows/doc-freshness-pr.yml:51`, `doc-freshness-schedule.yml:33`,
  `doc-index-update.yml:52` call `.github/scripts/doc-tools.sh`, which was never committed (since
  4727d2f, 2026-04-05). None of these workflows has ever run doc-tools here. PR #17 had 20 stale
  docs under STRICT=1 and passed. Measured.
- [P2] `.claude/settings.local.json` is tracked. It is a personal settings file, committed with
  `/Users/w/…` paths and broad pre-approvals (`Bash(git push:*)`, `Bash(gh repo:*)`). The
  self-installed hooks pin `/Users/w/code/doc-superpowers/scripts/doc-tools.sh`, so this repo's
  Claude tier is dead on every clone. `.gitignore` does not list the file. Measured.
- [P2] `README.md:202`, `codebase-guide.md:58-59`, workflows doc `:384` claim the Claude hooks
  auto-run `update-index`. That call has never worked.
- [P2] `CLAUDE.md:23-28`, `README.md:291-295`, `codebase-guide.md:21-25,168` describe the
  self-installed CI tier as working.
- [P2] `CLAUDE.md:150,152`, workflows doc `:514,527,582`, `codebase-guide.md:342`,
  `conventions.md:274`: v2.15.0's `:amends` / `spec-verify --plan` are missing from the agent-facing
  docs.
- [P2] `docs/conventions.md:309-317,331`: the status table contradicts the code (also I-3).
- [P3] Reinstated after Phase-4 review; verifier V-S3 had dropped it. The repo does not register its
  own merge driver, and has no `.gitattributes` entry for `docs/.doc-index.json`. PR #16's conflict,
  which exists only in the generated index, is exactly the case the driver exists for. Dogfood it
  only **after** I-5 makes the driver three-way.
- [P3] Index and doc hygiene:
  - three `code_commit` SHAs are reachable only from tag v2.12.0 (pre-rebase copies);
  - point-in-time records are 91% of the stale signal;
  - archived docs are not deprecated;
  - test counts disagree (`(68)` / `680`);
  - GNU sed is missing from the dependency lists;
  - the `.claude/mcp.json` location is wrong;
  - the C4 PNGs are older than their Mermaid;
  - docs name `__DOC_TOOLS_PATH__`;
  - `tests.yml` is missing from the directory trees;
  - a `doc_type` mismatch;
  - the v2.14.0 `[""]` explanation is wrong;
  - the INSTALL pin check is not followed;
  - "except hooks" wording;
  - lying code comments at `doc-tools.sh:284,428,429,510`.
- [P3, unverified carry-over] `tests.yml` has no step that diffs the self-installed workflows and
  the vendored tool against their templates. That missing guard is why this drift went unnoticed.

## Proposed fix

**Owner action, immediately, not a code change:** open *Settings → Billing and plans* (Actions
spending limit / payment) and *Settings → Actions → General* for the repository and the account, to
find why jobs stop before starting. Then:
- re-run Tests on `main`;
- add branch protection on `main` requiring the two Tests jobs, so a red or never-run CI cannot
  merge.

**Code (fix plan Task 14, run last):**
- Re-run the installer for this repo once T7–T9 have landed.
- Commit the vendored tool, or re-render the self-installed workflows to call `scripts/doc-tools.sh`.
- Untrack `.claude/settings.local.json` and git-ignore it.
- Add a `tests.yml` step that diffs self-installed files against their templates.
- Index hygiene via `set-code-refs` (T5).
- Keep suite counts only in CLAUDE.md.
- Fix the drifted docs.
- Amend drifted mechanism sentences in the five governing specs.
- Register the merge driver after T6.

## Acceptance criteria

- [ ] The Tests workflow executes on `main`, both legs, and is required by branch protection.
- [ ] The self-installed freshness workflows run doc-tools and fail closed.
- [ ] `check-freshness` on this repo reports only genuinely living docs as stale.
- [ ] No doc claims a hook behaviour the hook lacks.

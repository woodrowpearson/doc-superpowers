---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: ci
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-8
run-id: 05ea982
related-files:
  - scripts/hooks/ci/doc-freshness-pr.yml
  - scripts/hooks/ci/doc-freshness-schedule.yml
  - scripts/hooks/ci/doc-index-update.yml
  - scripts/hooks/ci/doc-audit-update.yml
  - scripts/hooks/ci/doc-review-pr.yml
  - scripts/hooks/ci/doc-release.yml
  - scripts/hooks/ci/doc-spec-verify.yml
  - scripts/hooks/ci/doc-pr-full-cycle.yml
  - scripts/hooks/ci/doc-pr-release.yml
  - scripts/hooks/install.sh
  - scripts/hooks/state.sh
  - scripts/test-hooks.sh
  - scripts/test-doc-pr-release.sh
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-8 — CI templates fail open, one fails every run, and the AI templates cannot do their jobs

> Cluster **I-8** of sweep run `05ea982`, ranked #5 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S6, S7). Fix:
> **Task 9** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). Also closes
> **GH #5**.

## Summary

The shell freshness templates **fail open**: a tool failure is reported as `stale_count=0`, STRICT
still passes, and the schedule job closes the tracking issue.

`doc-index-update.yml` feeds every changed `docs/` path to `update-index`. That includes the index
itself and PNGs, so it exits 1 on essentially every push. When it does succeed, it records a
shallow-clone graft as the verified commit.

Index-sized JSON goes through `$GITHUB_OUTPUT` into a single env var, which breaks at about 421 docs.

The six AI templates run `claude-code-action` in agent mode with no `plugins` and no
`claude_args`. The model therefore has neither the `/doc-superpowers` skill nor Bash/Write tools.

## Incorrect assumption

- "A tool failure means 0 stale."
- "The runner's Claude has the local skill and tool grants."
- "Every changed `docs/` path is an indexed doc."
- "Two commits of history are enough."
- "Editing a doc on main re-verifies it."

## Verified evidence

- [P1] `ci/doc-index-update.yml:30,52` passes every changed `docs/` path to `update-index`, which
  aborts. Replaying 12 of 12 recent main commits gave rc 1 every time. Measured.
- [P1] `ci/doc-index-update.yml:24-25,52`: `fetch-depth: 2` makes the shallow graft the recorded
  `code_commit`, so the doc stays stale forever in full history. Measured.
- [P1] E2BIG (root cause not named in the Phase-5 draft; added after Phase-4 review).
  - Where: `ci/doc-freshness-schedule.yml:39-44,102-104`; `doc-freshness-pr.yml:29-40,57-62,117-119`.
  - What: index-sized JSON goes through `$GITHUB_OUTPUT` into one env var and fails with E2BIG at
    ≈421 docs (311 B/entry).
  - Why: Linux caps a single env string at 131,072 B, measured for `/bin/true` and node.
  - Level: measured locally; needs-runtime on Actions.
- [P1, provisional: pinned-source read + needs-runtime] The six AI templates have no
  `claude_args`/`plugins`.
  - In agent mode (`prompt:` supplied) the action grants no allowedTools and loads no local skill.
  - The audit-update and full-cycle prompts never say "push".
- [P2] `doc-freshness-pr.yml:51-55,121-127`, `doc-freshness-schedule.yml:33-37,106-133` fail open:
  a tool failure becomes `stale_count=0` and the schedule job **closes** the issue. Measured.
- [P2] `doc-index-update.yml:45-52` treats "doc edited on main" as "doc re-verified", so a typo fix
  clears real staleness (see I-3).
- [P2] `doc-review-pr.yml:16-24,31-33,68-69`: `prompt:` forces agent mode on every comment.
  - `trigger_phrase` is dead.
  - Any member comment runs a paid review of the *default branch*.
  - A comment cancels the in-flight PR review.
- [P2] All six `claude-code-action` steps: **GH #5**.
  - The proposed `id-token: write` fix swaps in a Claude App installation token. That token's scope
    is set server-side, not bounded by `permissions:`, and bot pushes made with it re-trigger
    workflows.
  - `github_token: ${{ github.token }}` fixes #5 without OIDC.
- [P2] Further structural gaps:
  - fork, Dependabot and bot PRs get red checks: there is no same-repo guard outside doc-pr-release;
  - path filters are hard-coded to this repo's layout;
  - three templates commit to the same PR branch under separate concurrency groups.
- [P3] Unverified carry-over from Phase 2: the CI gates ignore `.summary.missing`, so a PR that
  deletes an indexed doc passes.
- [P3] Smaller defects:
  - the "recursion guard" rationale for `paths-ignore` is wrong;
  - the changed-file list word-splits and globs, and an empty list means no filter;
  - the report comment is never cleared, only the first page is read, and the author is not checked;
  - `workflow_dispatch` runs without PR context;
  - the `DOC_SUPERPOWERS_VERSION` env is dead, and one permission is unused;
  - there is no `timeout-minutes` or `--max-turns`;
  - pin comments are imprecise (the pinned SHAs are genuine);
  - `__BASE_BRANCH__` is unvalidated.
- [P1, provisional: needs-runtime] Filed under I-9: `doc-release.yml:33-34` uses
  `!contains(head_commit.message,'[doc-superpowers]')`, which skips the release job when a squash
  commit lists the bot's sync commits.

## Proposed fix (fix plan Task 9)

- **Remove** `doc-index-update.yml`: the template, the installer entry and this repo's copy. Nothing
  consumes it, it equates "edited" with "verified", and it fails every run.
- **Freshness templates:**
  - write the result to `$RUNNER_TEMP`, filter it with jq, and read it from the file;
  - count `missing`;
  - emit `::error::` and exit 1 on tool failure under STRICT;
  - never auto-close on failure;
  - upsert one marker comment.
- **AI templates:**
  - `github_token: ${{ github.token }}` (closes #5);
  - `plugins`/`plugin_marketplaces` pinned to the version;
  - least-privilege `--allowedTools`;
  - a deterministic commit/push step that asserts the diff paths;
  - a same-repo guard;
  - one write concurrency group per branch;
  - `--max-turns` and `timeout-minutes`.
- **`doc-review-pr.yml`:** split into a fixed-prompt PR job and a tag-mode comment job.

## Acceptance criteria

- [ ] No placeholder survives `install --all`.
- [ ] Every AI template passes `github_token`, `plugins` and a scoped `--allowedTools`.
- [ ] Every job has `timeout-minutes`.
- [ ] No index-sized data goes through `$GITHUB_OUTPUT`.
- [ ] The schedule's close step is gated on a successful check.
- [ ] One real Actions run per template is recorded before the cluster closes (needs-runtime).

## Related

- GH #5.
- I-7: installer default workflow set.
- I-9: fragment pipeline templates.
- I-14: this repo's self-installed copies call a script that was never committed.

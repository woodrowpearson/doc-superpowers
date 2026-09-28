---
date: 2026-09-27
status: Resolved
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

- [x] No placeholder survives `install --all`.
- [x] Every AI template passes `github_token`, `plugins` and a scoped `--allowedTools`.
- [x] Every job has `timeout-minutes`.
- [x] No index-sized data goes through `$GITHUB_OUTPUT`.
- [x] The schedule's close step is gated on a successful check.
- [ ] One real Actions run per template is recorded before the cluster closes (needs-runtime).
  Still open: Actions does not run on this repository (billing lock since 2026-08-31). The
  templates are proven on the installer's output instead (see Resolution); record one run per
  template when CI returns.

## Resolution

Fixed by Task 9 of the fix plan (commit `fix(ci)!: … (sweep 05ea982 I-8; closes #5)`, which
closes GH #5). Proven on the installer's output — `install --all --workflows=all` in a fixture,
asserted as YAML and by running the vendored step scripts the way a step runs them
(`scripts/test-doc-pr-release.sh`, "CI templates as installed" and "I-8 step helpers";
`scripts/test-hooks.sh`, "retired doc-index-update, step scripts").

- **`doc-index-update.yml` removed**: the template, the installer's default set and
  known-workflow list, and this repository's copy. `install.sh` keeps it in
  `RETIRED_WORKFLOWS`: any `install --ci` (and a full `uninstall --ci`) removes a copy that
  carries the workflow marker — the ownership rule for every managed workflow — and drops its
  state entry (`state_wf_drop`); a file of that name without the marker is kept and reported.
  `install --workflows=doc-index-update` is an error.
- **Freshness templates fail closed.** Their steps are `doc-superpowers-steps/freshness-check.sh
  gate|audit`: the result goes to `$RUNNER_TEMP/freshness.json`, is filtered with jq to
  `freshness-report.json` (`{summary, docs}`: stale + missing only), and only scalars reach
  `$GITHUB_OUTPUT`; `github-script` reads the report with `fs.readFileSync`. The PR gate scopes
  with `check-freshness --code-refs-from <file>` (no argv list, no word splitting) and also
  counts indexed docs the PR deletes. A check that cannot run writes `status=failed` and no
  count: `::warning::`, or `::error::` + exit 1 under STRICT; the schedule run always fails and
  its create/close steps need `status == 'ok'`. One PR comment, found by a hidden marker and the
  bot author across every page, is updated each push (to "none" too); the schedule's issue is
  found the same way.
- **AI templates can run and are bounded:** `github_token: ${{ github.token }}` (no
  `id-token: write`); the plugin from `prepare-agent.sh`'s checkout of tag
  `v<installed version>` (`plugin_marketplaces` takes a local path; a Git URL there cannot name
  a tag) with `plugins: doc-superpowers@doc-superpowers`; `--max-turns` and a per-template
  `--allowedTools` list; `timeout-minutes`; a same-repository guard (job `if:`, or
  `pr-guard.sh` for comment events); no trigger path filters — a `freshness-check.sh scope` step
  gates the agent on the docs (or specs) the change touches; the agent never commits —
  `commit-changes.sh` checks HEAD and every changed path, then commits and pushes without
  force; one `doc-superpowers-write-<branch>` concurrency group, never cancelled, for the three
  that commit to a branch.
- **`doc-review-pr.yml` split** into a fixed-prompt `pull_request` job and a tag-mode `respond`
  job (no `prompt:`) gated on a member's PR comment containing `@claude`.
- Pins carry their exact version comments (`# v4.3.1`, `# v7.1.0`, `# v1.0.88`).
- P3s: the `paths-ignore` comment now gives the real reason (GITHUB_TOKEN pushes start no run);
  the changed-file list is a file (no word splitting, globbing or "empty means everything");
  `workflow_dispatch` is gone from the PR-only templates (review-pr, spec-verify, full-cycle),
  which had no PR context; `DOC_SUPERPOWERS_VERSION` is read (the plugin pin); audit-update's
  unused `pull-requests: write` is dropped (`__BASE_BRANCH__` was validated in I-7).

Review fix round 1: the commit step stages deletions too (`git update-index --add --remove`,
so a `git rm`'d fragment commits); it runs from `prepare-agent.sh`'s pre-agent snapshot under
`$RUNNER_TEMP` with git hooks and fsmonitor off (pr-release's `commit-and-push.sh` step gets the
same through `GIT_CONFIG_*`) — an integrity check against agent mistakes, not a sandbox (the
security ceiling is the job token's `permissions:`); `--ignore` means a directory; the write
group queues pending runs in order (`queue: max`, with a note for GHES).

Review fix round 2: the three writers check out the branch (doc-audit-update now too), so a
queued run starts from the tip the earlier runs left; `commit-changes.sh` calls a run superseded
(exit 0, nothing committed, a notice naming the range) only when the branch received a commit
whose subject does not start with `[doc-superpowers]`; a branch moved only by doc-superpowers
commits, or behind the checkout, is an `::error::`.

Left for later tasks: I-9 (T10) owns `doc-release.yml`'s `contains(…)` skip and the fragment
pipeline; the runtime criterion above waits for CI.

## Related

- GH #5.
- I-7: installer default workflow set.
- I-9: fragment pipeline templates.
- I-14: this repo's self-installed copies call a script that was never committed.

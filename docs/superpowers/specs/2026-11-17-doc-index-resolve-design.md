# doc-index-resolve CI template — design

**Status:** approved by the developer 2026-11-17 · **Scope:** `scripts/hooks/` (one new opt-in CI
template and its step script), the installer's vendoring, the tests and the docs ·
**Release:** one minor release, 3.15.0.

## What this decides

doc-superpowers gains an opt-in CI template, `doc-index-resolve`. After each push to the base
branch, it merges the base into every open pull request whose only conflict is the doc index
(`docs/.doc-index.json`), using doc-superpowers' own index merge driver. It pushes that merge with a
lease, starts the project's test workflow on it, and comments on the pull request.

A pull request that the driver cannot fix is left for its author, with a comment that says why.

## Why

Every merge to the base branch rebuilds the doc index. Every open pull request that also rebuilt
it then conflicts there, and only there. The merge driver resolves that conflict entry by entry,
but git runs it only in a clone that registers it, and GitHub's merge button never does. Each
author has to merge the base by hand, once per merge to the base. A consumer project with many open
pull requests measured this as its most frequent merge chore.

## Requirements

**R1. Trigger.** The workflow runs on a push to the base branch (`__BASE_BRANCH__`) and on
`workflow_dispatch`, with an optional input `pr` (one pull request number). It never runs on a
`pull_request` or `pull_request_target` event, so a pull request's own code never runs with its
token.

**R2. Selection.** It is a shell opt-in template, like `doc-ledger-publish`: installed by name
(`install --ci --workflows=doc-index-resolve`), and never by `--workflows=all`, because it writes
to other people's branches. `setup` lists it under `ci.workflows`.

**R3. Which pull requests.** The step lists open pull requests against the base branch.

- **Left out** (no comment, listed in the run's summary): a pull request from a fork, against
  another base, labelled `no-index-resolve`, or whose head is the base.
- **Not touched** (no comment): one GitHub reports as mergeable. A pull request whose mergeable
  state is still unknown after one retry is left out.
- **Considered:** one GitHub reports as conflicting.

**R4. The merge.** For a considered pull request, the step fetches its head and checks that the
head is still the one the listing named. It then merges the base with `docs/.doc-index.json` routed
to the vendored driver, and accepts the merge only when all of these hold:

1. The only path git reports as conflicted without the driver is `docs/.doc-index.json`.
2. With the driver, the merge completes with no conflict.
3. No index entry is dropped: every key present in the head's index and in the base's index is in
   the merged index, unless one side deleted it since the merge base.
4. The merge brings no file under `.github/workflows/`. The workflow token cannot push one.

Anything else is a skip, with a comment naming the reason and the local command that resolves it
(`git merge origin/<base>` in a clone with the driver registered, `install.sh install --git`).

**R5. The push.** The merge commit's first parent is the head that was read, so the push is a
fast-forward. The step pushes with `--force-with-lease=refs/heads/<branch>:<head>`, so a branch
that moved since it was read refuses the push. A refused push on a branch that moved is a skip; on
a branch that did not move it is a failure. That case is a protected branch (a branch protection
rule or ruleset: signed commits, linear history, restricted updates), which refuses every later run
too. So it also gets the skip's comment: the refusal, the local command and the `no-index-resolve`
label that opts out. Git authenticates through the template family's
git-token block, reading `DOC_SUPERPOWERS_GIT_TOKEN`; no token is kept on disk.

**R6. Checks on the merge.** A push with the workflow token starts no workflow. When the recorded
choice `resolve_test_workflow` names a workflow file, the step dispatches it on the pull request's
branch (`POST /actions/workflows/<file>/dispatches`). When the choice is empty, nothing is
dispatched and the comment asks the author to push a commit (`git commit --allow-empty` works)
or to close and reopen the pull request. A re-run does not help: it checks the commit its run
first checked, not the merge. A dispatch starts that one workflow only, so the pull request's other
required `pull_request` checks stay missing until the author pushes. A failed dispatch after a
successful push still posts the comment, which says the checks could not be started and asks for
the same push.

**R7. The comment.** Each pull request gets at most one comment from the resolver, marked with
`<!-- doc-superpowers:index-resolve -->`. The step updates its own comment (author type `Bot`)
rather than adding another. It comments on a merge, on a skip and on a refused push (R5). It does not
comment on a pull request it left out or did not touch, or on any other failure.

**R8. Outcomes and exit codes.** Each considered pull request ends `merged`, `skipped` or
`failed`. The step prints one line per pull request and exits 0 when none failed, 2 when any
failed, and 3 on a usage error. A failure on one pull request does not stop the others.

**R9. Hardening.** It follows the template family's rules:

- Job-level permissions only: `contents: write`, `pull-requests: write`, `actions: write`.
- One run at a time: `concurrency` with a fixed group and `cancel-in-progress: false`, so a run is
  never stopped between its push and its dispatch.
- `actions/checkout` at the pinned commit, with `persist-credentials: false` and full history.
- `install-jq.sh` first, `timeout-minutes` set, the template marker on line 1, zizmor clean.

**R10. Vendoring.** The driver (`scripts/merge-doc-index.sh`) is vendored into
`.github/scripts/doc-superpowers-steps/` when an installed workflow's step needs it. The step finds
it beside itself. `check-self-install.sh` holds it as a byte copy like the other vendored files.

## The design

- **Template:** `scripts/hooks/ci/doc-index-resolve.yml`, rendered with `__BASE_BRANCH__`,
  `__VERSION__` and one new placeholder, `__RESOLVE_TEST_WORKFLOW__`.
- **Choice:** `--resolve-test-workflow=<file>` on `install --ci`, recorded in `installed.json` as
  `.tiers.ci.resolve_test_workflow`, with the usual precedence (flag, recorded, default empty).
- **Step:** `scripts/hooks/ci/doc-superpowers-steps/index-resolve.sh`, bash 3.2 and jq 1.6, using
  `gh api` with `GH_TOKEN` for the GitHub calls. It reads `BASE_BRANCH`, `PR`, `TEST_WORKFLOW` and
  `GITHUB_REPOSITORY` from its environment.
- **Tests:**
  - `scripts/test-hooks.sh`: install, vendoring (step and driver), the choice's record and
    precedence, the `all` exclusion, uninstall.
  - `scripts/test-doc-pr-release.sh`: the template's structure (triggers, permissions,
    concurrency, checkout, pins, env), and the step run against a bare remote with a stubbed `gh`.
    One case per outcome in R3–R8.

## Not in this release

- **A GitHub App token**, whose push would start the pull request's own checks. It needs a new
  pinned action; the dispatch in R6 covers the gap.
- **Shortening CI after an index-only merge.** Which jobs a merge needs is the consumer's CI
  layout, not doc-superpowers'.

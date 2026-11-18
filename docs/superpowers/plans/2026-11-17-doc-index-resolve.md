# doc-index-resolve CI template — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task by task, test-first (superpowers:test-driven-development). Steps use checkbox (`- [ ]`) syntax.

**Goal:** an opt-in shell CI template, `doc-index-resolve`, that merges the base branch into every
open pull request whose only conflict is `docs/.doc-index.json`, with the vendored index merge driver.
The design is `docs/superpowers/specs/2026-11-17-doc-index-resolve-design.md` (R1–R10).

**Architecture:** the template runs one step script, `doc-superpowers-steps/index-resolve.sh`. The
step lists pull requests with `gh api`, merges with `git merge-tree --write-tree` (the working tree
is never left mid-merge), pushes with a lease, dispatches the recorded test workflow and upserts one
marked comment. The driver, `scripts/merge-doc-index.sh`, is vendored beside the step as a step
companion: `tools install --step merge-doc-index.sh` resolves it from `scripts/`.

**Tech stack:** bash 3.2+, jq 1.6+, git 2.40+ (`--attr-source`, `merge-tree --write-tree`), `gh`.

## Global constraints

- No new dependency and no new action pin: the checkout pin the family already uses.
- `doc-index-resolve` is never installed by `--workflows=all`; only by name.
- The step never edits the repository's config or attributes: the driver and the attribute go in
  through `git -c` and `--attr-source=<tree>`.
- Exit codes: 0 none failed, 2 any failed, 3 usage error.
- No release notes, version bump or tag: the release is done separately.
- Prose follows the writing rule (`bash scripts/doc-tools.sh writing check <file>`).

---

### Task 1: The choice, the template and the opt-in registration

**Files:**
- `scripts/hooks/install.sh`: the opt-in set, `workflow_desc`, help, the `--resolve-test-workflow`
  flag, `preflight_ci`, `render_workflow`, status.
- `scripts/hooks/state.sh`: the record, `.tiers.ci.resolve_test_workflow`.
- `scripts/hooks/ci/doc-index-resolve.yml`, and its step with the usage checks only
  (`scripts/hooks/ci/doc-superpowers-steps/index-resolve.sh`).
- The renders: `scripts/check-ci.sh` (zizmor) and `scripts/check-self-install.sh`.
- The tests: `scripts/test-hooks.sh`.

- [ ] Write the failing tests:
  - it installs by name, and `--workflows=all` leaves it out but refreshes an installed copy;
  - the flag renders `TEST_WORKFLOW` and is recorded, and a plain install reproduces it;
  - `--resolve-test-workflow=` clears it, and an invalid value exits 2 and writes nothing;
  - help lists it under "shell, opt-in by name", and status reports the choice.
- [ ] Run them and see them fail; implement; see them pass.
- [ ] Check: `BASH_BIN=/bin/bash bash scripts/test-hooks.sh` names no failure.

### Task 2: The driver vendored beside the step (R10)

**Files:** `scripts/doc-tools.sh` (`_TOOLS_STEP_COMPANIONS`, `tools install`/`uninstall`, the step
selection), `scripts/hooks/install.sh` (`unused_steps`), `scripts/check-self-install.sh`,
`scripts/test-hooks.sh`, `scripts/test-doc-tools.sh`.

- [ ] Write the failing tests: installing the template vendors `merge-doc-index.sh` beside the step,
  a byte copy, executable; uninstalling removes it; an edited copy is kept; the self-install check
  passes with it and fails on an edited copy.
- [ ] Run them and see them fail; implement; see them pass.
- [ ] Check: the two suites name no failure.

### Task 3: The step (R3–R8)

**Files:** `scripts/hooks/ci/doc-superpowers-steps/index-resolve.sh`, `scripts/test-doc-pr-release.sh`.

- [ ] Write the failing tests, one per outcome, against a bare remote with a stubbed `gh`:
  - left out: a fork, another base, the label, a head that is the base;
  - not touched: mergeable, or still unknown after one retry;
  - merged: only the index conflicts; the first parent is the head; a lease push; the dispatch;
    one comment;
  - skipped: another file conflicts, the driver conflicts, an entry is dropped, a workflow file
    comes in, the head moved, or the push is refused on a branch that moved;
  - failed: the push is refused on a branch that did not move;
  - the comment: updated, never duplicated, and only a Bot's; exit codes 0, 2 and 3.
- [ ] Run them and see them fail for the right reason; implement; see them pass.
- [ ] Check: `bash scripts/test-doc-pr-release.sh` under both bashes names no failure.

### Task 4: The family's hardening rules (R9)

**Files:** `scripts/test-doc-pr-release.sh` (`ALL_REPO`, the workflow counts, the git-token list and
the pushing-step regex, a template structure test).

- [ ] Add the template to `ALL_REPO`, the step to the byte-identical git-token list and to the
  pushing-step check; write the structure test (triggers, job permissions, concurrency, checkout,
  env). See it fail before the counts change; then pass.
- [ ] Check: zizmor through `check_zizmor` (if `uvx` reaches it) and the suite.

### Task 5: The documents and the counts

**Files:** `references/hooks.md`, `README.md`, `CLAUDE.md` (directory map, key files, suite counts),
`skills/doc-superpowers/SKILL.md`, `scripts/setup/catalog.json`, `scripts/help/ci.txt`,
`docs/architecture/system-overview.md`, `docs/codebase-guide.md`, `docs/conventions.md`,
`docs/guides/getting-started.md`, `docs/workflows/doc-superpowers.md`.

- [ ] Name the template where `doc-ledger-publish` is named; 9 workflows become 10.
- [ ] Update the catalog test's count; run the suites; set the assertion counts in `CLAUDE.md`.
- [ ] Check: `bash scripts/leak-scan.sh`, `bash scripts/check-self-install.sh`, each touched suite
  under both bashes.

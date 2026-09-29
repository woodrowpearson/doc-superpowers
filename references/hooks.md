# `hooks` — Install Workflow Hooks

**Read by** SKILL.md's `hooks` action — **REQUIRED** before running the installer. `$ROOT` is the
plugin root SKILL.md's *Detect Bundled Tooling* resolved (`$ROOT/scripts/hooks/install.sh` is the
installer, `$DOC_TOOLS` = `$ROOT/scripts/doc-tools.sh`).

Scaffolding command — installs opt-in hooks into the target project for automated freshness monitoring. No discovery phase needed.

```
/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]
/doc-superpowers hooks status [--git] [--claude] [--ci]
/doc-superpowers hooks uninstall [--git] [--claude] [--ci] [--all]
```

Routes to `"$ROOT/scripts/hooks/install.sh" <subcommand> [flags]` (`install.sh help` lists every hook and workflow). A flag the subcommand does not take exits 2; CI options (`--workflows`, `--base-branch`, `--cron`, `--ci-strict`, `--helpers`, `--force`, `--transient`) need `--ci` or `--all`.

**IMPORTANT:** ALWAYS use the installer script. NEVER manually add hook entries to `.claude/settings.json` or `.claude/settings.local.json`, and never copy hook templates by hand — the installer renders the templates (the `__DOC_TOOLS_RESOLVE__` placeholder becomes the program that finds `doc-tools.sh`), merges settings per entry, and refuses unsafe targets. Hand-made entries break.

**Where it writes.** Every subcommand acts on the repository holding the current directory, at its top level (`git rev-parse --show-toplevel`; a linked worktree or a submodule is its own top level), so it can run from a subdirectory. Git hooks go where git runs them (`git rev-parse --git-path hooks`: a repository-local `core.hooksPath`, a worktree's common dir, a submodule's `.git/modules/<name>/hooks`). It refuses — writing nothing — when:
- `core.hooksPath` comes from the user's global or system git config (every repository's hooks dir; a repository-local one, or a worktree's with `extensions.worktreeConfig`, is this repository's): tell the user to set a repository-local one or unset it. `uninstall --git` refuses it too, and leaves hooks an older installer put there for the user to delete by hand;
- a write target, or a directory on the way to it, is a symbolic link (a committed link could point at `~/.bashrc` or `~/.claude`): tell the user which path, never work around it;
- `.claude/settings.local.json` is not one JSON object, or `.claude/doc-superpowers/installed.json` cannot be read (see *State*).

**What it owns.** Only what it can name exactly: a hook whose first lines carry `doc-superpowers hook v<N>`; the `# doc-superpowers:begin` … `:end` block in a hook of the user's, in `.gitattributes` and in git's `info/exclude`; the `merge.doc-index.*` git config; each settings hook *entry* whose command runs `.claude/hooks/doc-superpowers/{pre-commit-gate,post-commit-sync,session-summary}.sh` (other entries and groups — even ones mentioning doc-superpowers — are the user's and survive install and uninstall byte-for-byte); a workflow whose first lines carry `doc-superpowers workflow v<N>`. Uninstall is the inverse of install: an integrated hook of the user's comes back byte-for-byte, a `.gitattributes` or settings file the installer created is removed, and only the state file stays.

**Tier options:**
- `--git` — Git hooks: pre-commit (freshness gate on the staged tree, so it reports the commit being made: the docs its staged paths reach and every entry the staged index adds; an indexed doc the commit leaves out is "not in this commit" — `git add` it — when it is on disk, "missing from disk" with `move-entry` advice when it is gone), post-merge (stale alert), post-checkout (branch check), prepare-commit-msg ("already stale" comments, editor commits only), pre-push (release reminder for the pushed refs). Also registers the `docs/.doc-index.json` custom merge driver (`scripts/merge-doc-index.sh`) via `git config` + a marked `.gitattributes` block; re-running `install --git` re-registers a pre-3.0 (pinned) registration. When the user already has a hook, it is kept: if it is a shell script (`sh`, `bash`, `dash`, `zsh`, … or no `#!` line), a marked POSIX block goes right after its `#!` line and runs our copy (`.doc-superpowers-<hook>` beside it) with git's arguments — pre-commit passes our exit code on, so `DOC_SUPERPOWERS_STRICT=1` blocks; pre-push hands both hooks the same ref lines on stdin. A hook in another language is skipped with a message. Re-install refreshes the copy and replaces an older block.
- `--claude` — Claude Code hooks, **per-user**: registered in `.claude/settings.local.json` with commands `bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/<hook>.sh`, and both that file and `.claude/hooks/doc-superpowers/` are excluded from git through git's `info/exclude` (they hold this machine's paths; each contributor installs their own). If the repository tracks either, the installer prints the command that untracks both (`git rm -r --cached --ignore-unmatch -- .claude/settings.local.json .claude/hooks/doc-superpowers`) and warns that pulling that commit deletes them from every other clone: relay that each teammate re-runs `install --claude` after pulling (a lost permission allowlist comes back with `git show ORIG_HEAD:.claude/settings.local.json`). PreToolUse pre-commit gate, PostToolUse post-commit sync, Stop session summary. They read the event JSON on stdin and answer with `additionalContext` (for Claude) and `systemMessage` (for the user). Under `DOC_SUPERPOWERS_STRICT=1` the gate exits 2 with the reason on stderr, even under `DOC_SUPERPOWERS_QUIET=1`, because that is Claude's feedback. It gates `git … commit` only in command position, so `echo git commit` is not a commit. It defers `git add … && git commit` and `commit -a` to the git pre-commit hook, which sees the real index — and counts that hook only when it is the doc-superpowers one or holds the current integration block. Stop fires after every response, so the summary covers only working-tree changes.
- No hook runs `update-index` or writes the index: attesting a doc stays a reviewer's step. A hook whose check fails (jq missing from PATH, a corrupt index) prints one line and blocks only under STRICT; absent tooling is silent. Installed hooks find `doc-tools.sh` by the merge driver's rule: for a plugin-cache install, the newest version-named sibling in numeric order (a plugin update needs no re-install; other sibling directories never run); for a checkout, its own pinned path.
- `--ci` — CI/CD workflows. **Default: the two shell workflows** (`doc-freshness-pr`, `doc-freshness-schedule`); the Claude-powered templates are opt-in by name (`--workflows=…`). Plus `doc-tools.sh` vendored into `.github/scripts/` through `doc-tools.sh tools install`, with the helper directories exactly while an installed workflow runs them (every workflow runs step scripts from `.github/scripts/doc-superpowers-steps/`). `doc-index-update` was **retired in v3.0.0** (it recorded every doc edited on the base branch as verified, unread, and failed every run): any `install --ci` removes an installed copy the installer owns (its `doc-superpowers workflow v<N>` marker) and drops its state entry; a file of that name without the marker is kept and reported (`Kept …`) — relay it, never delete it for the user.

**Status and upgrades.** `status` compares each installed git hook, the local copy an integrated hook runs, each Claude script and each settings command with what this install would write (the install date on line 2 aside). A hook of another doc-superpowers version carries the same marker, so anything else reads `⚠ … outdated: re-run install --git` (or `--claude`): re-run that tier. After upgrading from 2.x, walk the user through `$ROOT/README.md` → *Upgrading from 2.x* (v2's AI workflows, the per-user Claude tier, hooks in unconfigured directories, retyping design specs).

**Consent before `--ci`.** Before installing workflows, show the user what each one may do in their repository and get a yes — permissions come from the workflow's `permissions:` block:

| Workflow | Runs on | Permissions | Commits / writes |
|---|---|---|---|
| `doc-freshness-pr` (default) | PR open/sync | contents: read, pull-requests: write | one PR comment (updated each push); `--ci-strict` fails the check |
| `doc-freshness-schedule` (default) | weekly cron | contents: read, issues: write | opens/updates/closes an audit issue |
| `doc-audit-update` (AI) | push to a non-base branch that leaves indexed docs stale or missing | contents: write | **a checked step commits `docs/` and indexed docs to that branch** |
| `doc-review-pr` (AI) | PR open/sync touching indexed docs or their code; `@claude` PR comments by members | contents: read, pull-requests + issues: write | PR comments only |
| `doc-release` (AI) | push to `release/**` | contents + pull-requests: write | a checked step commits the release files to a new branch and opens a PR |
| `doc-spec-verify` (AI) | PR open/sync touching indexed specs or their code | contents: read, pull-requests: write | PR comment only |
| `doc-pr-full-cycle` (AI) | PR open touching indexed docs or their code | contents + pull-requests: write | **a checked step commits `docs/` and indexed docs to the PR branch** |
| `doc-pr-release` (AI) | PR pushes | contents + pull-requests: write | **a checked step commits the PR's fragment to the PR branch**, edits the PR body |

How every workflow behaves (tell the user when they ask what they agree to):
- A check that cannot run is never "all current": the freshness PR check warns (fails under `--ci-strict`), the schedule run fails and never closes the issue, and the AI jobs' scope step fails the job. Results stay in files; only counts reach step outputs.
- Which docs and code a change touches comes from the doc index (`check-freshness --code-refs-from`), not from path filters in the workflow.
- AI workflows use the job's own `GITHUB_TOKEN` (`github_token: ${{ github.token }}`; no `id-token: write`), so `permissions:` bounds them and their pushes start no other workflow run. They install this plugin from its GitHub tag `v<the installed version>`, run only for same-repository PRs (never forks or Dependabot), grant the agent a scoped `--allowedTools` list with `--max-turns`, and have `timeout-minutes`. The agent never commits: a later step (a pre-agent copy of the checker, git hooks and fsmonitor off — an integrity check against agent mistakes, not a sandbox; the security ceiling is the job token's `permissions:`) refuses any changed path outside the workflow's set, then commits and pushes without force. The three that commit to a branch check out the branch and share one concurrency group per branch: never cancelled mid-run, pending runs queued in order (`queue: max`; on a GitHub Enterprise Server without it, delete that key). A run whose branch received someone else's commits meanwhile ends green as superseded, committing nothing; one whose branch moved only by doc-superpowers commits, or backwards, fails visibly — re-run it.
- `doc-release` opens its PR with the job's token: the repository setting *Allow GitHub Actions to create and approve pull requests* must be on (the step says so when it is off).

AI workflows need a `CLAUDE_CODE_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` repository secret. Do not combine `doc-review-pr` and `doc-pr-full-cycle` (both review every PR). Name only the workflows the user agreed to in `--workflows=`.

**CI-specific flags:**
- `--workflows=<csv|all|none>` — Workflow selection.
  - omitted: the recorded set (see *State*); a first install gets the two shell workflows.
  - CSV (e.g. `--workflows=doc-pr-release,doc-freshness-schedule`): install the listed workflows (names are basenames without `.yml`, repeats count once; an unknown name, a retired one — `doc-index-update` — or an empty list errors out). An explicit name overrides an earlier intentional uninstall.
  - `all`: every template, except those uninstalled on purpose.
  - `none`: no workflow, only the vendored `doc-tools.sh` (prefer `tools install` for that).
- `--base-branch NAME` — Target branch (default: `main`); a name git accepts, of letters, digits and `. _ / -` only (anything else could corrupt a workflow line).
- `--cron EXPR` — Schedule, 5 fields (default: `0 9 * * 1`).
- `--ci-strict[=true|false]` — Fail the PR check on stale docs (default false).
- `--helpers=<true|false>` — Deprecated, and inert: the helper directories ship exactly while an installed workflow runs them (the `doc-pr-release` producer helpers with `doc-pr-release`, the step scripts in `.github/scripts/doc-superpowers-steps/` with any workflow), whatever this flag says. Its only effect: `--helpers=false` is refused (non-zero, nothing written) while `doc-pr-release` is selected or already installed; a `doc-pr-release` uninstalled on purpose does not count. Do not pass it.
- `--force` — Also re-install workflows uninstalled on purpose. **Never pass `--force` unless the user asked for exactly that.**

**Uninstall-specific flags:**
- `--workflows=<csv|all|none>` — Which workflows (default: all, plus the vendored files and a retired `doc-index-update.yml` the installer owns). An unknown name exits non-zero; `doc-index-update` is accepted here (it removes an owned copy).
- `--transient` — Record the removal as temporary (`intentional:false`) so the next plain `install --ci` puts them back. Without it the removal is intentional.

Vendored files are removed through `doc-tools.sh tools uninstall`: a file with local edits (or from another plugin version) is kept and reported as `Kept …` — relay those lines to the user; the uninstall is not "clean" then. `RELEASE-NOTES.next/README.md` goes with the `doc-pr-release` helpers only when it is byte-identical to the plugin's fragment-format spec and the only file in `RELEASE-NOTES.next/`; an edited copy, and any fragment, stay.

**State** (`.claude/doc-superpowers/installed.json`, committed — tell the user to commit it with the workflows):
- It records the CI tier only (the git and Claude tiers are per-clone / per-user): the workflow set (`installed`, or `uninstalled` with `intentional`), `base_branch`, `cron`, `ci_strict`, and each workflow's `installed_at` (set once, never rewritten on a refresh).
- A plain `install --ci` reproduces the recorded choices and refreshes exactly the recorded workflows (it adds no default); flags override a choice and are recorded. Upgrading a pre-3.0 install keeps the choices found in its rendered workflows.
- A doc-superpowers workflow on disk counts as installed whatever the state says, and is refreshed.
- An unreadable state file (a merge conflict, the wrong shape) is never overwritten: install and uninstall exit 1 and `status` warns. Have the user resolve the conflict, or move the file to `installed.json.corrupt` — the next install then rebuilds it from disk and installs nothing that is not already there.

**Standalone `tools` subcommand (v2.12.0+):**

For projects that want only `doc-tools.sh` (and optionally the CI helpers) without workflows, route to `$DOC_TOOLS tools …` directly instead of `hooks install --ci`:

```bash
$DOC_TOOLS tools install [--dest <path>] [--with-helpers | --helper <dir>...]
$DOC_TOOLS tools uninstall [--dest <path>] [--helper <dir>...]
$DOC_TOOLS tools status    [--dest <path>]
$DOC_TOOLS tools version
```

`--dest` defaults to `.github/scripts`. `--with-helpers` ALSO installs every helper the CI templates run — `doc-pr-release/*.sh` and `doc-superpowers-steps/*.sh` — and `RELEASE-NOTES.next/README.md` if absent; `--helper <dir>` (repeatable: `doc-pr-release`, `doc-superpowers-steps`) only those directories (the README comes with `doc-pr-release`). `install --ci` uses exactly this, per installed workflow. Use it when the user wants to wire `doc-tools.sh` into their own (non-doc-superpowers) workflows. `tools uninstall` removes only files byte-identical to the plugin's copies (with `--helper`, only in those directories, keeping `doc-tools.sh`; with the `doc-pr-release` helpers, also an unmodified `RELEASE-NOTES.next/README.md` that is alone there): an edited or user-added file (and a copy from another plugin version) is kept and reported — tell the user, never delete it for them. `tools status` also says whether `RELEASE-NOTES.next/README.md` matches the plugin's spec: a pre-3.0 copy (it is created only when absent, so an upgrade keeps it) gives outdated advice — offer to replace it with the plugin's `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`. Both refuse a symbolic link at a destination or on the way to it. Run these from the plugin's `doc-tools.sh` (`$DOC_TOOLS`): a vendored copy cannot uninstall, cannot ship helpers, and `tools status` from it reports presence only (no drift, no version).

When no tier flags are provided via SKILL.md routing, present the options to the user (with the consent table for `--ci`) and pass the appropriate flags. The installer's interactive menu is for direct terminal invocation only.

## CI sub-workflows

The `--ci` tier's templates (a path holding a workflow that is not a
doc-superpowers one is skipped). The first two are the default set; the
others install only when named:

| Workflow | Trigger | Purpose |
|---|---|---|
| `doc-freshness-pr.yml` | PR open/sync | One PR comment listing the docs the diff leaves stale or missing (updated every push; STRICT fails the check) |
| `doc-freshness-schedule.yml` | Weekly cron | Keeps one audit issue open while docs are stale or missing; closes it after a clean check |
| `doc-audit-update.yml` | Push to non-main leaving indexed docs stale | AI-powered audit + update on feature branches |
| `doc-review-pr.yml` | PR open/sync touching indexed docs; `@claude` PR comment | AI-powered PR doc review (a fixed-prompt job), and tag mode for `@claude` |
| `doc-release.yml` | Push to `release/**` | AI-powered release-notes drafting, opened as a PR |
| `doc-spec-verify.yml` | PR open/sync touching indexed specs | Verifies spec compliance against changed code |
| `doc-pr-full-cycle.yml` | PR open touching indexed docs | Superset of review-pr — runs review + update + diagram + sync |
| `doc-pr-release.yml` | PR open/sync/reopen | Drafts/maintains `RELEASE-NOTES.next/PR-<N>.md` fragments and the managed `<!-- doc-superpowers:start/end -->` section of the PR body |

The `doc-pr-release.yml` workflow uses shell helpers installed alongside
it at `.github/scripts/doc-pr-release/`:
- `extract-context.sh` — emits JSON context: PR body, the fragment and its computed hash state, and the PR's own commits (never base-branch or bot commits) since the checkout the last sync recorded
- `update-pr-body.sh` — idempotent marker-based PR body merge (markers inside code fences are ignored; an END before the START, or no section and a body ending inside an unclosed fence, is refused)
- `fragment-lib.sh` — the fragment line rules (markers, hash line, sha256) the helpers source
- `commit-and-push.sh` — seals the fragment (writes its line-2 hash), commits only that file, and pushes it only while the branch is still at the checkout (`--force-with-lease` on the checkout: someone else's push → superseded, exit 0; a force-push or reset → exit 1, never undone); never overwrites a hand-edited fragment

Every template's `run:` steps are scripts in
`.github/scripts/doc-superpowers-steps/` (the freshness check and the AI
jobs' scope gate `freshness-check.sh`, auth selection, the pinned plugin
fetch `prepare-agent.sh`, the checked commit `commit-changes.sh`, the fork
guard `pr-guard.sh`, and `doc-pr-release.yml`'s sentinel skip, context
extraction and post-agent verification, `doc-release.yml`'s precheck),
installed with the first workflow and removed with the last of them. The
fragment commit itself is `commit-and-push.sh`, run as a workflow step after
the agent, never by it.

It also installs `RELEASE-NOTES.next/README.md` (if missing) with the
fragment-format spec — markers, SHA-256 hash from line 3+ and how to re-seal
a hand edit, the one section vocabulary (`### Added`, `### Changed`,
`### Deprecated`, `### Removed`, `### Fixed`, `### Security`,
`### Dependencies`; aliases fold onto it, other `### ` headings are kept after
it) with its mapping onto a Features/Fixes-style RELEASE-NOTES.md, the
lossless-or-skipped merge rules, the no-notes state, and why the release
commit must reach `main`. Both the `doc-pr-release.yml` producer and the
`/doc-superpowers release` consumer (steps 3 and 8 of `references/release.md`) adhere to this
format.


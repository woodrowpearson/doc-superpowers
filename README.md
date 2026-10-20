# doc-superpowers

Documentation orchestrator for AI-assisted development. Generates, audits, and maintains project documentation through parallel agent dispatch, agentic workflow discovery, Mermaid diagram generation, and formal spec lifecycle tracking.

A superset of [obra/superpowers](https://github.com/obra/superpowers) documentation patterns — extends them with automated discovery of agentic pipelines (skills, commands, MCP tools), multi-scope parallel auditing, architecture diagram generation, formal specification tracking through implementation, workflow hooks for automated freshness monitoring, and release notes management.

## What It Does

doc-superpowers is a Claude Code skill that treats documentation as a first-class engineering artifact. It:

- **Discovers** your project's doc tooling, directory structure, and agentic workflows automatically
- **Generates** a complete documentation suite from scratch (`init`)
- **Audits** existing docs against current code for staleness (`audit`)
- **Reviews** PR-scoped documentation impact (`review-pr`)
- **Updates** stale docs with agent-verified changes (`update`)
- **Regenerates** architecture and workflow diagrams (`diagram`)
- **Syncs** doc indexes with the filesystem (`sync`)
- **Installs** opt-in workflow hooks for automated freshness monitoring (`hooks`)
- **Tracks specifications** through implementation with formal spec lifecycle (`spec-generate`, `spec-inject`, `spec-verify`)
- **Checks spec claims** (opt-in, with `docs/spec-claims/`): executable claims quoted from a spec's normative text, each bound to a check, run by `doc-tools.sh claims` and gated through the spec actions and the hooks
- **Keeps a work ledger** (opt-in, with `docs/ledger/config.json`): issue files get stable keys, ledger pages and one HTML view are generated from them, related work is found through named contracts, and work in flight on other branches and machines raises notices (`ledger`, `doc-tools.sh ledger`)
- **Drafts release notes** from git history with agent-assisted diff review (`release`)
- **Syncs CLAUDE.md and README.md** automatically in the actions that write docs (`init`, `update`, `sync`, `release`, `spec-generate`) to prevent drift; in a CI workflow `update` and `sync` report the change instead of editing them
- **Tracks freshness** via bundled `scripts/doc-tools.sh` — content hashing for docs, content identity (git object ids per code ref) for code

## Installation

### Claude Code

Add this repository as a plugin marketplace, then install the plugin from it (both are named `doc-superpowers` in `.claude-plugin/marketplace.json`):

```
/plugin marketplace add woodrowpearson/doc-superpowers
/plugin install doc-superpowers@doc-superpowers
```

**From a checkout** (to follow `main` or edit the skill) — symlink the whole repository into your personal skills directory. Claude Code follows a symlinked skill folder there, and a skill folder holding `.claude-plugin/plugin.json` (the repository root does) loads as the plugin `<name>@skills-dir` — here `doc-superpowers@skills-dir` (Claude Code docs, [*Skills → Choose where skills load*](https://code.claude.com/docs/en/skills)):

```bash
git clone git@github.com:woodrowpearson/doc-superpowers.git ~/code/doc-superpowers
ln -s ~/code/doc-superpowers ~/.claude/skills/doc-superpowers
```

### Manual

Copy the whole repository into `.claude/skills/doc-superpowers/` in any project. Copy all of it, not only `skills/doc-superpowers/SKILL.md` and `references/`: the skill runs `scripts/doc-tools.sh` and reads `references/` from two directories above its `SKILL.md`. The copy holds `.claude-plugin/plugin.json`, so Claude Code loads it as the plugin `doc-superpowers@skills-dir`, and in a project's `.claude/skills/` that requires accepting the workspace trust dialog first.

### Cursor

Not in the Cursor marketplace yet: install it as a local plugin in `~/.cursor/plugins/local/doc-superpowers`. See `.cursor-plugin/INSTALL.md`.

### Codex

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers
mkdir -p ~/.agents/skills
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
```

See `.codex/INSTALL.md` for details.

### OpenCode

Add to your `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

See `.opencode/INSTALL.md` for details.

### Gemini CLI

```bash
gemini extensions install https://github.com/woodrowpearson/doc-superpowers
```

### skills.sh (`npx skills add`)

Not supported. `npx skills add woodrowpearson/doc-superpowers` copies only the skill folder, `skills/doc-superpowers/` (its `SKILL.md`), and the skill needs `scripts/` and `references/` from two directories above it. A skills.sh install has neither, so the skill stops at its *Detect Bundled Tooling* step. Use one of the installs above.

In a client other than Claude Code, [`references/tool-mappings.md`](references/tool-mappings.md) maps the skill's tool names to the client's and says which hook tiers and features it supports.

## Upgrading from 2.x

v3.0.0 changes what the installer writes, the doc-index schema and a few verbs' contracts. An install made by 2.x keeps working badly rather than failing: its hooks carry the same marker, and the v2 Claude gate read an environment variable nothing sets, so it never gated. `install.sh status` now says so (`⚠ … outdated: re-run install --git` / `--claude`). In each repository that has doc-superpowers installed:

1. **Re-run every tier you use**, from the upgraded plugin: `install.sh install --git`, `install --claude`, `install --ci`. Re-installing is idempotent, and it is what replaces the v2 hooks, the pinned merge-driver registration and the vendored `.github/scripts/` copies.
2. **Re-install before you uninstall.** `uninstall` removes only files byte-identical to the plugin's copies, so the v2 copies an old install vendored are kept (and reported) by a v3 `uninstall`.
3. **CI tier.** v2's default `--ci` installed every AI workflow, and a plain re-install keeps the recorded set: remove the ones you did not choose with `install.sh uninstall --ci --workflows=<names>`. `doc-index-update` is retired — any `install --ci` removes a copy the installer owns (a file of that name without its marker is kept and reported). An existing `RELEASE-NOTES.next/README.md` is never overwritten, so a v2 copy keeps giving v2 advice: `doc-tools.sh tools status` reports when it differs from the plugin's; replace it with `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`. `--helpers` is deprecated and inert (the helpers ship exactly while a workflow runs them); its one effect is that `--helpers=false` is refused, exit 1 with nothing written, while `doc-pr-release` is selected or already installed. Before keeping an AI workflow, read `references/hooks.md` → *What an AI job's agent can reach*, and protect the base branch and `release/**` with required human review.
4. **Claude tier: per-user now.** Its files hold this machine's paths and live in git's `info/exclude`. If your repository tracks `.claude/settings.local.json` or `.claude/hooks/doc-superpowers/`, untrack them (`git rm -r --cached --ignore-unmatch -- .claude/settings.local.json .claude/hooks/doc-superpowers`) and commit. **Pulling that commit deletes those files from every other clone**: tell each teammate to re-run `install.sh install --claude` after pulling, and to restore a permission allowlist they kept in that file with `git show ORIG_HEAD:.claude/settings.local.json`.
5. **Git hooks in the wrong place.** v2 could install into a `.githooks/` directory git was not configured to run, or into a global `core.hooksPath`. v3 installs only where git runs hooks and refuses a global `core.hooksPath`, so it never touches those copies: delete them by hand (their first lines say `doc-superpowers hook v1`).
6. **The doc-index.** Schema v3 records each code ref's content (`code_oids`); a v2 index is read as it is and upgraded by its next write, and a v2 entry keeps the old commit comparison, which is slow on a large index, until it records `code_oids`. Fill them without re-baselining anything with `doc-tools.sh upgrade-entries --all`: each ref's `code_oids` is its content at the entry's recorded `code_commit`, and `last_verified` is not touched. It is idempotent, and it lists the entries it cannot fill (no `code_commit`, a commit the clone lacks, a ref missing at that commit, such as a v2 glob); those keep the commit comparison until `update-index` re-baselines them after a review. Plans, issues, audits and design specs are record docs now, never reported stale, decided by `doc_type`: v2 indexes often typed design specs `spec` — retype them with `doc-tools.sh set-doc-type <doc> design-spec`, or many in one write with `set-doc-type --stdin` (`<doc><TAB>design-spec` lines) — never `remove-entry` + `add-entry`, which drops the entry's baseline and links.
7. **Verb contracts that can break a script.** `deprecate-entry` exits 1 for a path not in the index (after applying the rest; `remove-entry` stays idempotent, exit 0). The index verbs (`build-index`, `check-freshness`, `status`, `update-index`, `add-entry`, `remove-entry`, `move-entry`, `set-code-refs`, `set-doc-type`, `upgrade-entries`, `deprecate-entry`) and `fragments merge` exit 2 when run from a subdirectory, and `bump-version` / `check-version` exit 1 there (they read the manifests and RELEASE-NOTES.md from the current directory): run `doc-tools.sh` from the repository root. `claude-code.json` is gone (nothing read it), and `bump-version` / `check-version` no longer look for it.
8. **Spec amendments.** The `AMENDED`-block landed-check reads the whole block, so blocks written with the citation on their last line (the 2.x layout) still pass.

## Usage

```
/doc-superpowers <action> [scope]

Actions: init | audit | review-pr | update | diagram | sync | hooks | release | spec-generate | spec-inject | spec-verify | ledger
Scopes:  all | one scope from Detect Scopes (application, api-contracts, data-layer, …)
```

`[scope]` applies to `audit`, `update` and `diagram` only: it limits their scope agents to that one scope (default `all`), and every other action ignores it. Scopes are structural categories the skill detects from the project itself (`application`, `api-contracts`, `data-layer`, `infrastructure`, `ci-cd`, `testing`, `agentic`, `adr`, `spec`, `monorepo`), not from the layout of `docs/`.

### Actions

| Action | Purpose | When to Use |
|--------|---------|-------------|
| `init` | Generate full doc suite from scratch | New project or missing docs |
| `audit` | Check all docs, CLAUDE.md, README.md, and RELEASE-NOTES.md for staleness via parallel scope agents; writes a report to `docs/plans/` | Periodic health check |
| `review-pr` | Check docs, CLAUDE.md, and README.md affected by PR changes | Before merging PRs |
| `update` | Apply fixes from an audit report (`--report=<path>`; else this session's audit, else the freshness check), then archive the applied report | After audit identifies stale docs |
| `diagram` | Regenerate architecture diagrams | After structural changes |
| `sync` | Sync doc index with filesystem, check CLAUDE.md and README.md currency | After adding/removing doc files |
| `hooks` | Install workflow hooks (git, Claude Code, CI/CD) | Setting up automated freshness monitoring |
| `release` | Draft release notes entry from git history | Cutting a new version |
| `spec-generate` | Generate formal specs from design doc; scans overlapping specs for stale content | After brainstorming produces a design spec |
| `spec-inject` | Inject spec tasks into plans, track during execution | During plan writing and after each chunk executes |
| `spec-verify` | Verify spec compliance, review spec coverage | Before merging or during code review |
| `ledger` | Work ledger (opt-in): show, list, find and relate work items, file them (`ledger file`), allocate keys, note item state, propose missing relations at merge time, render views, check in-flight notices (`doc-tools.sh ledger <verb>`) | Tracking work as issue files across branches and machines |

### Examples

```bash
# Generate docs for a new project
/doc-superpowers init

# Audit all documentation (writes report to docs/plans/)
/doc-superpowers audit

# Apply that report's findings (audit suggests this exact command)
/doc-superpowers update --report=docs/plans/<date>-audit-report.md

# Check docs before merging a PR
/doc-superpowers review-pr

# Regenerate diagrams
/doc-superpowers diagram

# Draft release notes from git history
/doc-superpowers release

# Override the starting commit
/doc-superpowers release --from=v2.2.0
```

### Spec Lifecycle

```bash
# Generate formal specs from a design doc
/doc-superpowers spec-generate --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md

# Inject spec tasks into an implementation plan
/doc-superpowers spec-inject --phase=plan --plan=docs/superpowers/plans/2026-03-14-feature.md --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md

# Check spec freshness after a chunk executes
/doc-superpowers spec-inject --phase=execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md

# Final compliance check before merging
/doc-superpowers spec-verify --mode=post-execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md --plan=docs/superpowers/plans/2026-03-14-feature.md

# Spec coverage check during review
/doc-superpowers spec-verify --mode=review --changed-files=src/auth/oauth.py,src/auth/session.py

# Declare spec roles explicitly (v2.13.0+) — a target is advanced, a constraint is never written
/doc-superpowers spec-inject --phase=execute --specs=docs/specs/SPEC-UI-010-collection-view.md:target,docs/specs/SPEC-API-006-backend.md:constraint
```

The `:target` / `:constraint` / `:amends` suffix is optional — unsuffixed paths remain valid and are role-inferred at execution time (inference never yields `:amends`; an amendment is declared, never inferred). Pass `--plan=<path>` to `spec-verify` so an `:amends` spec's landed-check can verify the amendment cites the plan; without it the check degrades to block-present and warns. With `docs/spec-claims/`, post-execute needs `--plan`: without it there is no plan to attest, and the verdict is "claims verdict owed", never PASS.

For wrapper skill integration, see `references/spec-lifecycle-protocol.md`.

### Spec claims (opt-in)

A spec or ADR can carry **executable claims**: atomic, falsifiable statements quoted from its normative text, stored beside it in a sidecar (`docs/spec-claims/<DOC-ID>.json`) and each bound to a check — a host test run through a small runner adapter, a `grep -E` lint, a production log query, or a named human judgment. `doc-tools.sh claims <verb>` (`validate`, `run`, `promote`, `render`, `gate`, `attest`, `rulings`) is the checker: `promote` is a test claim's only path to `built`, and only with a proof that the bound test can fail (a lint, log or judge claim moves to `built` by a reviewed status edit, and its own check verifies it); `spec-generate` writes an `unbuilt` stub claim for each requirement, decision, invariant or interface a generated spec states; `spec-inject` adds a claims gate to each chunk of a plan and a final gate, whose verdicts are recorded under `docs/spec-claims/gates/`; `spec-verify` takes its post-execute verdict from `claims attest --final` (with no verdict it reports "claims verdict owed", never PASS), and its review mode reports a red claim as a **P1 Claim red** finding; a target spec reaches `Implemented` only through the final gate (**Spec Status Model → R5** in `references/spec-lifecycle-actions.md`); and when a doc and the code disagree, the direction — `CODE-DIVERGES` (the doc is the intent: fix the code, or defer it as `diverged` with a tracker), `DOC-STALE` (amend the doc) or `RETIRE` — is ruled and recorded on the claim before either side is edited. The git hooks and the `doc-spec-verify` and `doc-freshness-schedule` workflows run the same verbs.

It is **inert without `docs/spec-claims/`**: every `claims` verb then prints `{"verb":"<verb>","enabled":false,"exit":0}` and exits 0 (run outside a git repository, below its top level, or without git, jq ≥ 1.6 and `sha256sum`/`shasum`, a verb exits 2 before it gets that far, as every `doc-tools.sh` verb does), and the hooks, CI templates and `spec-*` actions behave exactly as before. A project opts in by creating that directory with its first sidecar. The schema, the checks (V1–V12), the adapter contracts, the gates and the policy keys are in [`references/spec-claims.md`](references/spec-claims.md), and the direction protocol is in [`references/spec-lifecycle-protocol.md`](references/spec-lifecycle-protocol.md).

### Work ledger (opt-in)

Projects that track work as markdown issue files (`docs/issues/*.md`) — or as GitHub issues — can turn on the **work ledger** with `docs/ledger/config.json` (`{}` is a complete config). The issue stays the only source of truth: each item gets a short stable key (`checkout-14`) allocated so two branches or machines never take the same one, ledger pages and one self-contained HTML file are generated from the items and never edited, related work is computed through named *contracts* an item `changes` or `consumes`, and — with in-flight awareness on — branches here, on the remote and on other machines raise `stop` / `heads-up` / `info` notices when they touch what this branch depends on.

`doc-tools.sh ledger <verb>` has 20 verbs: `show`, `ls`, `find`, `related`, `suggest`, `sweep`, `recheck` and `upkeep` read; `new`, `assign`, `link`, `note` and `finalize` write item fields and keys; `inflight` and `notices` (with `--gate`, an exit-1 gate that exits 2 rather than pass on in-flight data it could not fetch) cover work in flight; `view` renders locally and `publish` pushes the views to an orphan branch (`doc-ledger-views`); `validate` checks staged items, every item, a plan's Related work marks or a push; `state-watch` is a hook mode; and `init --report` / `--accept` / `--import` bootstraps a ledger from the issues, GitHub issues and hand-written ledger tables a repository already has (the `init` action runs it as an opt-in step, with your review of the proposed registry and assignments). Text output is the default and `--format json` prints one verdict object; exits are the claims family (0 ok, 1 findings, 2 could not run, 3 usage). Adapters plug in a host's systems — PRs, contract registries, hosted items — and two reference adapters for GitHub ship with it (`doc-superpowers:ledger-pr-gh`, `doc-superpowers:ledger-items-gh`, through `gh`). With the ledger on, `spec-inject` pastes a `## Related work` sweep into each plan and gives each chunk a `Ledger notices (chunk N)` gate, and spec-claims V5 reads ledger items' status classes (so `Won't Fix` closes a tracker). Relations are declared, never inferred: `suggest` (or `new --suggest-contracts`) and `related` propose candidates, you confirm, and one `link` writes them (comma lists; `link --relations none` when there is nothing to declare); with `validate.require_relations: "new"` in the config, the pre-commit leg refuses a new open item that declares no relation and does not say `relations: none`.

- **Filing:** `/doc-superpowers ledger file [<title>]` checks for duplicates first, asks one round of questions, writes the item with `ledger new --create` (path, frontmatter, key and body in one write, all or nothing) and links the relations you confirm.
- **Merge-time upkeep:** `ledger upkeep --range <base>...HEAD` (or `--pr <n>`) compares a range's diff with what its items declare and proposes the missing `changes` / `consumes`, with evidence and a ready `ledger link` line, never written; `review-pr` shows them on a ledger host (read-only), and the pre-push leg reports, as an advisory, a contract the push changes that none of the items it involves declares (only when it involves at least one; offline, at the cost of an index build per pushed ref; config `validate.undeclared_contract_change: false` turns it off).

It is **inert without `docs/ledger/config.json`**: every verb but `init` prints `ledger: not enabled (no docs/ledger/config.json)` and exits 0. Everything — config keys and defaults, keys and provisional keys, adapter contracts, how to declare relations, privacy of in-flight refs, the hooks, and the JSON surface and exit codes to build skills and scripts on — is in [`references/ledger.md`](references/ledger.md).

### Workflow Integration

Install opt-in hooks for automated freshness monitoring:

```bash
# Install all hook tiers
/doc-superpowers hooks install --all

# Or pick specific tiers
/doc-superpowers hooks install --git           # Git hooks (where git runs them)
/doc-superpowers hooks install --claude        # Claude Code hooks (per-user)
/doc-superpowers hooks install --ci            # GitHub Actions: the 2 shell workflows

# The work ledger's opt-in sets (need docs/ledger/config.json; never part of --all)
/doc-superpowers hooks install --ledger        # git legs: pre-commit validate, pre-push provisional-key check, post-commit in-flight push
/doc-superpowers hooks install --ledger-claude # Claude Code: SessionStart notices, PostToolUse state-watch (per-user)

# Claude-powered workflows are opt-in by name
/doc-superpowers hooks install --ci --workflows=doc-pr-release,doc-review-pr
/doc-superpowers hooks install --ci --workflows=doc-ledger-publish  # the ledger views publisher (shell, no secret)
/doc-superpowers hooks install --ci --workflows=all    # every template (doc-ledger-publish only with docs/ledger/config.json)
/doc-superpowers hooks install --ci --workflows=none   # only vendor doc-tools.sh
/doc-superpowers hooks install --ci --force            # also re-add workflows you removed on purpose

# CI tuning flags (recorded: a plain `install --ci` later reproduces them)
/doc-superpowers hooks install --ci --base-branch develop   # target branch (default: main)
/doc-superpowers hooks install --ci --cron "0 6 * * 1"      # weekly audit schedule (default: 0 9 * * 1)
/doc-superpowers hooks install --ci --ci-strict             # PR checks fail on stale docs, and on a freshness or claims check that cannot run (--ci-strict=false undoes it)

# Standalone tool install (v2.12.0+) — doc-tools.sh only, no workflows
# ($DOC_TOOLS is the plugin's scripts/doc-tools.sh: see docs/guides/getting-started.md, "Independent of hooks")
$DOC_TOOLS tools install                       # → .github/scripts/doc-tools.sh
$DOC_TOOLS tools install --with-helpers        # + every helper the CI templates run
$DOC_TOOLS tools install --helper doc-superpowers-steps  # + only the named helper set(s)
$DOC_TOOLS tools install --helper ledger       # + the work ledger's modules and adapters (ledger/, adapters/)
$DOC_TOOLS tools status                        # present? matches the plugin? which version?
$DOC_TOOLS tools uninstall                     # removes only files identical to the plugin's

# Check what's installed (optionally one tier: --git / --claude / --ci, or --all; the ledger
# sets with --ledger / --ledger-claude, each in its own section after the tiers);
# "⚠ … outdated: re-run install --git|--claude|--ledger|--ledger-claude" marks another version's install
/doc-superpowers hooks status

# Remove hooks
/doc-superpowers hooks uninstall --all
/doc-superpowers hooks uninstall --ci --workflows=doc-release  # remove ONE workflow
/doc-superpowers hooks uninstall --ledger --ledger-claude      # the ledger sets (--all removes neither)
```

The installer works from anywhere in the repository (it acts on the top level; a linked worktree or submodule is its own top level) and puts git hooks where git runs them (`git rev-parse --git-path hooks`). It refuses, writing nothing, when `core.hooksPath` comes from your global/system git config, or when a file it would write — or a directory on the way — is a symbolic link. It owns only what it marks: a hook of yours is kept, with a marked POSIX block after its `#!` line that runs ours (skipped if the hook is not a shell script); its `.gitattributes` and `info/exclude` entries are marked blocks; in `.claude/settings.local.json` it touches only the entries that run its own scripts. The work ledger's sets mark theirs `# ledger-superpowers:begin` … `:end` (a hook the set created holds only `#!/bin/sh` and that block), and neither set's markers match the other's. `uninstall` puts all of that back as it was. The Claude tier is **per-user**: its settings file and scripts are excluded from git through `.git/info/exclude`, and its commands run `"$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/…`.

**State tracking:** the CI tier's choices — the workflow set, base branch, cron, strict — persist in `.claude/doc-superpowers/installed.json` (commit it). A plain `install --ci` reproduces them and respects intentional uninstalls; pass `--workflows=<name>` to add one back, `--force` to re-add all, or `uninstall --ci --transient` so the next install re-installs. An unreadable state file (e.g. a merge conflict) is never overwritten: resolve it, or move it to `installed.json.corrupt` and the next install rebuilds it from disk without adding anything. Uninstall keeps a vendored helper you edited and says so (`Kept …`).

**Git hooks (5, the `--git` tier):** Pre-commit checks the staged tree, so it reports the docs *this* commit leaves stale (renames included), and every entry the staged index adds. An indexed doc the commit leaves out is "not in this commit" when it is on disk (`git add` it), "missing from disk" when it is gone. With `docs/spec-claims/`, pre-commit first runs a claims leg, `claims validate --staged` over the staged change: a finding blocks the commit whatever STRICT says, and a check that cannot run blocks only under STRICT. Post-merge and post-checkout report the docs a merge or branch switch left stale or missing. Prepare-commit-msg lists the stale docs as comment lines, only for a message written in the editor (git strips them; with `-m`/`-F` it adds nothing). Pre-push reminds about unreleased commits on the branches being pushed; with `docs/spec-claims/`, it also runs an advisory claims leg (`claims run --planes-of` over the pushed commits, and `claims attest --plan` for each plan with gate records but no `final.json`) that never blocks.

**Work-ledger git legs (`--ledger`, 3):** pre-commit runs `ledger validate --staged`, and any non-zero exit — findings, or a check that could not run — blocks the commit, STRICT or not. Pre-push runs `ledger validate --pushed` over each pushed ref and refuses a push that adds a provisional key when `keys.mode` is `cas` (and refuses when it cannot save git's ref lines for the checks after it). Post-commit runs `ledger inflight --push` in the background — the one leg that writes to the remote: with in-flight awareness on, it pushes this branch's in-flight ref, logging to `<git common dir>/doc-superpowers/ledger/push.log`, and never prompts. All three are silent without `docs/ledger/config.json`.

**Claude Code hooks (3, the `--claude` tier):** They read the event JSON on stdin and answer through Claude Code's JSON output (`additionalContext` for Claude, `systemMessage` for you). The pre-commit gate (PreToolUse) checks the staged tree of a `git commit`; a command that stages as it commits (`git add … && git commit`, `commit -a`) is left to the git pre-commit hook, which sees the real index, and the gate says so. Post-commit sync (PostToolUse) reports the docs a commit left stale. Session summary (Stop, which fires after every response) reports docs citing code changed in the working tree; a clean tree costs nothing. Every report stays under Claude Code's 10,000-character hook-output limit, whatever the stale count: each list names its first entries, then `…and N more` with the command for the full list. Each check has a time budget inside the hooks' 10 s timeout; past it the hook says `check skipped (budget)`, and under `DOC_SUPERPOWERS_STRICT=1` the gate blocks. No hook runs `update-index`: only a reviewer who read a doc against its code re-baselines it.

**Work-ledger Claude events (`--ledger-claude`, 2; it never installs the `--claude` tier):** SessionStart prints the unacked `stop` and `heads-up` notices for the session's branch (offline, at most 15 lines, a 2 s budget; silent with none or with in-flight awareness off), and PostToolUse (`Write|Edit|MultiEdit`) suggests `ledger note <key> "…"` when a write lands under the config's `state_watch.paths` naming an item key and a `state_watch.patterns` phrase. Both are thin wrappers over `ledger notices --hook` and `ledger state-watch --hook`, which a host can register in its own committed `.claude/settings.json` instead (`references/hooks.md`).

**CI/CD (9 workflows — 2 shell-based, installed by default; the shell workflow `doc-ledger-publish` and 6 Claude-powered ones, opt-in by name):** The PR freshness check keeps one comment listing the docs the PR leaves stale or missing (`--ci-strict` fails the check). The weekly cron keeps one drift issue open while docs are stale and closes it after a clean check; with `docs/spec-claims/`, its claims step also re-runs the spec claims and re-proves every promotion, and the issue reports the findings. Both fail closed: a check that cannot run is never reported as "all current". Which docs a change touches comes from the doc index, not from path filters. `doc-ledger-publish` runs `ledger publish` every 30 minutes (and by hand) to push the work-ledger views to their branch; without `docs/ledger/config.json` it does nothing. On a ledger host (`docs/ledger/config.json` exists), the workflows that run the claims check — the default `doc-freshness-schedule`, and `doc-spec-verify` — and `doc-ledger-publish` ship the ledger helper set (`.github/scripts/ledger/`, `.github/scripts/adapters/`): after enabling the ledger (or upgrading a ledger host), re-run `install --ci` and commit it (`hooks status --ci` warns until then). A host without the ledger gets neither directory, and `--workflows=all` skips `doc-ledger-publish` there (a note says so; name it to install it). (The post-merge `doc-index-update` workflow was retired in v3.0.0: it re-baselined docs nobody had read. `install --ci` removes an installed copy it owns.) Claude-powered workflows provide AI audit+update on feature branches, AI PR doc review with @claude interactive support, AI release notes drafting on release branches, AI spec compliance checks on PRs (with `docs/spec-claims/`, `doc-spec-verify` also runs a non-AI `claims` job on every same-repository PR — `claims validate`, `claims run` and `claims attest` for the plans the PR touches — which needs no Claude secret and fails on any finding; under `--ci-strict` it also fails when the check cannot run), AI PR full-cycle orchestration (review, update, diagram, sync), and AI per-PR release-notes fragment producer (drafts `RELEASE-NOTES.next/PR-<N>.md` on every push, consumed by the release workflow at release time; the release commit, which deletes the consumed fragments, must then reach `main` — until it does, the next release refuses rather than release them twice). Claude-powered workflows require one of `CLAUDE_CODE_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` as a GitHub Actions secret; if both are set, `CLAUDE_CODE_OAUTH_TOKEN` takes precedence. They run with the job's own `GITHUB_TOKEN` (so `permissions:` bounds the token, and its pushes trigger no other workflow — nor any check run: a PR whose head is the bot's commit waits at "Expected" for its required checks until you push again or close and reopen it), install this plugin from its GitHub tag for the installed version, run only for same-repository PRs, and give the agent a scoped tool list and a turn cap. The agent never commits: a later step checks which paths changed (only docs, or only the release files) and commits them without force. That check is not a sandbox: an agent steered by text it reads (a PR, a comment) can run code with the job's secrets and use the token repository-wide, so protect your base branch and `release/**` with required human review (`references/hooks.md`, *What an AI job's agent can reach*). `doc-release` opens its PR with that token, which needs the repository setting *Allow GitHub Actions to create and approve pull requests* — a setting that also lets workflow jobs approve pull requests.

Set `DOC_SUPERPOWERS_STRICT=1` to make the git pre-commit hook and the Claude pre-commit gate block instead of warn (the gate exits 2 with the reason on stderr). Set `DOC_SUPERPOWERS_QUIET=1` to suppress hook output while still enforcing checks (the Claude gate still gives Claude its block reason). Set `DOC_SUPERPOWERS_SKIP=1` to bypass all hooks temporarily (the work-ledger legs included), `DOC_SUPERPOWERS_CLAIMS_SKIP=1` to bypass only the claims legs, or `DOC_SUPERPOWERS_LEDGER_SKIP=1` to bypass only the work-ledger legs and events. `DOC_TOOLS_LEDGER_OFFLINE=1` stops the ledger's remote adapters (`pr`, `items`), fetches and in-flight pushes (the SessionStart event sets it); the `contracts` adapter, a local script, still runs; key allocation (`new`, `assign`, `finalize`, `init --accept`) still reaches the counter ref, except `init --accept` with hosted items to write, which needs the items adapter and exits 2. In the `--git` and `--claude` tiers, a hook whose tooling is absent (no skill, no `docs/.doc-index.json`) stays silent, except the claims legs, which need no index: with the skill present they run whenever `docs/spec-claims/` exists; one whose check fails (jq missing from PATH, a corrupt index) prints one line saying so and, under STRICT, blocks. The work-ledger legs differ, as above: their pre-commit and pre-push block without STRICT.

## Generated Documentation

The `init` action generates a structured documentation suite in `docs/`:

| Directory/File | Content | When Generated |
|----------------|---------|---------------|
| `architecture/system-overview.md` | System overview, C4 diagrams, tech stack (plus a `## Packages` section with `monorepo`) | Always |
| `architecture/{component}.md` | Per major component/domain | `application` scope |
| `architecture/diagrams/` | C4 and component diagrams | Always |
| `architecture/diagrams/erd.png` | ERD | `data-layer` scope |
| `specs/README.md` + `template.md` | Spec index and template | Always |
| `adr/README.md` + `template.md` | ADR log and template | Always |
| `workflows/{name}.md` | Process flows: the primary workflow always | Always |
| `workflows/deployment.md` | Deployment flow | `ci-cd` scope |
| `workflows/agentic/README.md` | Agentic workflow index + overview flowchart | `agentic` scope |
| `workflows/agentic/{skill}.md` | One agentic workflow doc per skill | `agentic` scope |
| `workflows/diagrams/` | Workflow, sequence, state diagrams | Always |
| `guides/getting-started.md` | Prerequisites, installation, verification | Always |
| `api-contracts.md` | Endpoints, schemas, request/response | `api-contracts` scope |
| `data-layer.md` | Data models, ERD, storage | `data-layer` scope |
| `ci-cd.md` | Pipeline overview, triggers, environments | `ci-cd` scope |
| `infra.md` | Infrastructure topology, components | `infrastructure` scope |
| `codebase-guide.md` | Directory map, key files, code flow (plus a `## Packages` section with `monorepo`) | Always |
| `conventions.md` | Code style, naming, git conventions (plus a `## Testing` section with `testing`) | Always |
| `.doc-index.json` | Machine-readable freshness index | Always |

## Agentic Workflow Discovery

doc-superpowers automatically discovers Claude Code artifacts that define agentic pipelines:

- **Skills** (`.claude/skills/*/SKILL.md` and `skills/*/SKILL.md`) — sub-agents, scripts, user gates
- **Commands** (`.claude/commands/*.md`) — which skills they invoke
- **MCP tools** (MCP config files) — server names and tool purposes
- **Scripts** (`scripts/`) — roles in pipelines (dispatch, validate, merge)

Each discovered workflow gets documented with:
- Pipeline overview flowchart
- Phase/session subgraph diagrams
- Multi-actor sequence diagrams with sub-agent lifelines
- State diagrams for pipelines with recovery flows

## Audit Severity Levels

| Level | Meaning |
|-------|---------|
| **P0 Critical** | Doc describes behavior code no longer implements |
| **P1 Stale** | Code changed, doc probably needs updating |
| **P2 Incomplete** | Doc missing sections for new functionality |
| **P3 Style** | Formatting, broken links, outdated terminology |

## Architecture

doc-superpowers uses a hub-and-spoke architecture:

1. **Discovery phase** runs first, building an inventory of the project
2. **Action router** dispatches to the requested action
3. **Parallel agents** handle scope-isolated reviews (one agent per doc scope)
4. **Verification gates** ensure agent findings include evidence (exact doc vs code quotes)
5. **Output** is a structured report with severity-ranked findings

## Relationship to obra/superpowers

This skill is designed as a **documentation superset** of the [obra/superpowers](https://github.com/obra/superpowers) framework:

- Uses the same skill structure conventions (SKILL.md frontmatter, description triggers)
- Follows superpowers' verification-before-completion patterns
- Extends with documentation-specific workflows not covered by the base framework
- Compatible with superpowers' code review integration (callback pattern)

## File Structure

```
doc-superpowers/
├── .gitignore            # Git ignore rules
├── .gitattributes        # This repo's own git tier: the doc-index merge driver
├── .worktrees/           # Parallel-agent worktree location (gitignored; not created by the skill)
├── .claude/
│   └── doc-superpowers/
│       └── installed.json    # This repo's own CI tier record (the Claude tier is per-user, gitignored)
├── .claude-plugin/       # Claude Code plugin manifest + marketplace
│   ├── plugin.json
│   └── marketplace.json
├── .cursor-plugin/       # Cursor plugin manifest + installation guide
│   ├── plugin.json
│   └── INSTALL.md
├── .codex/               # Codex installation guide
│   └── INSTALL.md
├── .github/              # This repo's own CI tier (installer output) + its test workflow
│   ├── scripts/          # Vendored doc-tools.sh + doc-superpowers-steps/ (no ledger set: this repo has no docs/ledger/config.json)
│   └── workflows/
│       ├── doc-freshness-pr.yml
│       ├── doc-freshness-schedule.yml
│       └── tests.yml     # This repo only: every test suite (bash 5.x + 3.2), check-version, self-install check, release tag (main); each step is scripts/check-ci.sh
├── .opencode/            # OpenCode plugin + installation guide
│   ├── INSTALL.md
│   └── plugins/
│       └── doc-superpowers.js
├── skills/
│   └── doc-superpowers/
│       └── SKILL.md      # Main skill definition
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling
│   ├── test-doc-tools.sh # Test suite for doc-tools.sh
│   ├── test-helpers.sh   # Shared test utilities
│   ├── test-hooks.sh     # Test suite for hooks installer
│   ├── test-spec-status-model.sh # Test suite for the Spec Status Model + call sites
│   ├── test-spec-claims.sh       # Test suite for the spec claims checker (doc-tools.sh claims)
│   ├── test-doc-pr-release.sh    # Test suite for doc-pr-release helpers
│   ├── test-ledger.sh            # Test suite for the work ledger (doc-tools.sh ledger, adapters, hook modes)
│   ├── bench-ledger.sh           # Work-ledger performance check on a synthetic corpus (not run in CI)
│   ├── check-ci.sh               # Maintainer: run locally what tests.yml runs (--fast for the quick part)
│   ├── check-self-install.sh     # Maintainer: the self-installed CI tier matches the installer
│   ├── install-maintainer-hooks.sh # Maintainer: opt-in pre-push hook running check-ci.sh --fast
│   ├── leak-scan.sh              # Machine paths, emails and tokens in tracked files
│   ├── ledger/                   # The work ledger's modules (lib.sh + sourced *.sh, *.jq, *.awk)
│   ├── adapters/                 # Reference ledger adapters (ledger-pr-gh.sh, ledger-items-gh.sh; GitHub via gh)
│   ├── merge-doc-index.sh        # Custom git merge driver for .doc-index.json
│   ├── test-merge-driver.sh      # Test suite for merge driver
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── state.sh          # Install-state tracking
│       ├── git/              # Git hook scripts (pre-commit, post-merge, etc.; ledger-* legs)
│       ├── claude/           # Claude Code hook scripts (and ledger-session-notices, ledger-state-watch)
│       └── ci/               # GitHub Actions workflow templates
├── references/
│   ├── doc-spec.md       # Templates and conventions
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format + spec compliance report
│   ├── release.md                 # `release` action steps
│   ├── hooks.md                   # `hooks` action: tiers, consent table, CI templates
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec lifecycle actions
│   ├── spec-lifecycle-protocol.md # Spec lifecycle integration guide
│   ├── spec-claims.md             # Spec claims (opt-in): schema, checks, adapters, gates
│   ├── ledger.md                  # Work ledger (opt-in): config, verbs, keys, adapters, hooks, init
│   ├── ledger-index.schema.json   # The work-ledger index shape (ledger-index/1)
│   ├── integration-patterns.md    # Code review, commit review, wrapper skill integration
│   └── tool-mappings.md           # Per-client tool names and capabilities
├── evals/                # Evaluation test cases
│   ├── evals.json        # Test prompts and machine-checkable assertions
│   └── fixtures/         # Per-eval scenario setup scripts
├── docs/                 # Documentation about this skill
│   ├── architecture/
│   │   ├── system-overview.md
│   │   └── diagrams/
│   ├── workflows/
│   │   ├── doc-superpowers.md
│   │   └── diagrams/
│   ├── guides/
│   │   └── getting-started.md
│   ├── superpowers/
│   │   ├── specs/        # Design specs from brainstorming
│   │   └── plans/        # Implementation plans from writing-plans
│   ├── .doc-index.json   # Machine-readable freshness index
│   ├── issues/           # Bug reports and enhancement requests
│   ├── plans/            # Audit reports and update plans
│   ├── archive/          # Archived docs
│   ├── codebase-guide.md
│   └── conventions.md
├── README.md
├── LICENSE               # MIT
├── RELEASE-NOTES.md
└── CLAUDE.md
```

## Dependencies

The skill runs the bundled tooling in `scripts/` and reads `references/` from its plugin root, so it needs the whole repository (see *Manual* under Installation) and:

| Dependency | Required | Notes |
|-----------|----------|-------|
| `bash` | Yes, **≥ 3.2** | macOS's `/bin/bash` (3.2) is supported; nothing needs bash 4 |
| `git` | Yes; **≥ 2.36** in a claims-enabled project | Already required by doc-superpowers. A claims check over a commit range that holds a merge reads the merge with `git show --remerge-diff` (git 2.36+); an older git makes that check indeterminate (exit 2) |
| `jq` | Yes, **≥ 1.6** | `brew install jq` / `apt install jq`. 1.6 is the floor: the index writers use `--args` / `$ARGS.positional`. `doc-tools.sh` refuses an older jq with a clear error |
| `sha256sum` or `shasum` | Yes | Standard on Linux/macOS respectively |
| `gh` (GitHub CLI), authenticated | Only for the work ledger's GitHub adapters | `doc-superpowers:ledger-pr-gh`, `doc-superpowers:ledger-items-gh` and `ledger init --sources github`, when a project's `docs/ledger/config.json` names them |

Everything else is the POSIX userland (`awk`, `sed`, `grep`, `mktemp`, …) as stock macOS and Linux ship it: no GNU-only tool (GNU sed, ripgrep) is needed. Where `awk` is mawk (Debian, Ubuntu), it must be 1.3.4 or newer: older mawk lacks the POSIX character classes (`[[:space:]]`) the tools use.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes — the skill is `skills/doc-superpowers/SKILL.md` and `references/`, the tooling `scripts/`
4. Run every test suite under both bash 5.x and macOS's `/bin/bash` 3.2 (the loop and the suite list are in [CLAUDE.md → Conventions](CLAUDE.md#conventions)); all must pass. CI runs the same matrix
5. If you changed a CI template, `scripts/doc-tools.sh` or a CI helper script, re-run `bash scripts/hooks/install.sh install --ci` and commit what it writes: this repository installs its own CI tier, and CI fails when the installed copies drift from their sources
6. For a change to the skill's behaviour, also try it with `/doc-superpowers init` (or the action you changed) on a sample project
7. Submit a PR

## License

MIT License. See [LICENSE](LICENSE).

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
- **Drafts release notes** from git history with agent-assisted diff review (`release`)
- **Syncs CLAUDE.md and README.md** automatically across all write actions to prevent drift
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

Copy the whole repository into `.claude/skills/doc-superpowers/` in any project. Copy all of it, not only `skills/doc-superpowers/SKILL.md` and `references/`: the skill runs `scripts/doc-tools.sh` and reads `references/` from two directories above its `SKILL.md`.

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

### skills.sh (Any Agent)

```bash
npx skills add woodrowpearson/doc-superpowers
```

Works with 40+ supported agents. See [skills.sh](https://skills.sh) for details.

In a client other than Claude Code, [`references/tool-mappings.md`](references/tool-mappings.md) maps the skill's tool names to the client's and says which hook tiers and features it supports.

## Upgrading from 2.x

v3.0.0 changes what the installer writes, the doc-index schema and a few verbs' contracts. An install made by 2.x keeps working badly rather than failing: its hooks carry the same marker, and the v2 Claude gate read an environment variable nothing sets, so it never gated. `install.sh status` now says so (`⚠ … outdated: re-run install --git` / `--claude`). In each repository that has doc-superpowers installed:

1. **Re-run every tier you use**, from the upgraded plugin: `install.sh install --git`, `install --claude`, `install --ci`. Re-installing is idempotent, and it is what replaces the v2 hooks, the pinned merge-driver registration and the vendored `.github/scripts/` copies.
2. **Re-install before you uninstall.** `uninstall` removes only files byte-identical to the plugin's copies, so the v2 copies an old install vendored are kept (and reported) by a v3 `uninstall`.
3. **CI tier.** v2's default `--ci` installed every AI workflow, and a plain re-install keeps the recorded set: remove the ones you did not choose with `install.sh uninstall --ci --workflows=<names>`. `doc-index-update` is retired — any `install --ci` removes a copy the installer owns (a file of that name without its marker is kept and reported). An existing `RELEASE-NOTES.next/README.md` is never overwritten, so a v2 copy keeps giving v2 advice: `doc-tools.sh tools status` reports when it differs from the plugin's; replace it with `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`. `--helpers` is deprecated and inert (the helpers ship exactly while a workflow runs them). Before keeping an AI workflow, read `references/hooks.md` → *What an AI job's agent can reach*, and protect the base branch and `release/**` with required human review.
4. **Claude tier: per-user now.** Its files hold this machine's paths and live in git's `info/exclude`. If your repository tracks `.claude/settings.local.json` or `.claude/hooks/doc-superpowers/`, untrack them (`git rm -r --cached --ignore-unmatch -- .claude/settings.local.json .claude/hooks/doc-superpowers`) and commit. **Pulling that commit deletes those files from every other clone**: tell each teammate to re-run `install.sh install --claude` after pulling, and to restore a permission allowlist they kept in that file with `git show ORIG_HEAD:.claude/settings.local.json`.
5. **Git hooks in the wrong place.** v2 could install into a `.githooks/` directory git was not configured to run, or into a global `core.hooksPath`. v3 installs only where git runs hooks and refuses a global `core.hooksPath`, so it never touches those copies: delete them by hand (their first lines say `doc-superpowers hook v1`).
6. **The doc-index.** Schema v3 records each code ref's content (`code_oids`); a v2 index is read as it is and upgraded by its next write, and a v2 entry keeps the old commit comparison until `update-index` re-verifies it. Plans, issues, audits and design specs are record docs now, never reported stale, decided by `doc_type`: v2 indexes often typed design specs `spec` — retype them with `doc-tools.sh set-doc-type <doc> design-spec` (never `remove-entry` + `add-entry`, which drops the entry's verification and links).
7. **Verb contracts that can break a script.** `deprecate-entry` exits 1 for a path not in the index (after applying the rest; `remove-entry` stays idempotent, exit 0). The index verbs (`build-index`, `check-freshness`, `status`, `update-index`, `add-entry`, `remove-entry`, `move-entry`, `set-code-refs`, `set-doc-type`, `deprecate-entry`) and `fragments merge` exit 2 when run from a subdirectory, and `bump-version` / `check-version` exit 1 there (they read the manifests and RELEASE-NOTES.md from the current directory): run `doc-tools.sh` from the repository root. `claude-code.json` is gone (nothing read it), and `bump-version` / `check-version` no longer look for it.
8. **Spec amendments.** The `AMENDED`-block landed-check reads the whole block, so blocks written with the citation on their last line (the 2.x layout) still pass.

## Usage

```
/doc-superpowers <action> [scope]

Actions: init | audit | review-pr | update | diagram | sync | hooks | release | spec-generate | spec-inject | spec-verify
Scopes:  all | <auto-detected from docs/ structure>
```

### Actions

| Action | Purpose | When to Use |
|--------|---------|-------------|
| `init` | Generate full doc suite from scratch | New project or missing docs |
| `audit` | Check all docs, CLAUDE.md, README.md, and RELEASE-NOTES.md for staleness via parallel scope agents; writes a report to `docs/plans/` | Periodic health check |
| `review-pr` | Check docs, CLAUDE.md, and README.md affected by PR changes | Before merging PRs |
| `update` | Apply fixes from audit/review | After audit identifies stale docs |
| `diagram` | Regenerate architecture diagrams | After structural changes |
| `sync` | Sync doc index with filesystem, check CLAUDE.md and README.md currency | After adding/removing doc files |
| `hooks` | Install workflow hooks (git, Claude Code, CI/CD) | Setting up automated freshness monitoring |
| `release` | Draft release notes entry from git history | Cutting a new version |
| `spec-generate` | Generate formal specs from design doc; scans overlapping specs for stale content | After brainstorming produces a design spec |
| `spec-inject` | Inject spec tasks into plans, track during execution | During plan writing and after each chunk executes |
| `spec-verify` | Verify spec compliance, review spec coverage | Before merging or during code review |

### Examples

```bash
# Generate docs for a new project
/doc-superpowers init

# Audit all documentation (writes report to docs/plans/)
/doc-superpowers audit

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
/doc-superpowers spec-verify --mode=post-execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md

# Spec coverage check during review
/doc-superpowers spec-verify --mode=review --changed-files=src/auth/oauth.py,src/auth/session.py

# Declare spec roles explicitly (v2.13.0+) — a target is advanced, a constraint is never written
/doc-superpowers spec-inject --phase=execute --specs=docs/specs/SPEC-UI-010-collection-view.md:target,docs/specs/SPEC-API-006-backend.md:constraint
```

The `:target` / `:constraint` / `:amends` suffix is optional — unsuffixed paths remain valid and are role-inferred at execution time (inference never yields `:amends`; an amendment is declared, never inferred). Pass `--plan=<path>` to `spec-verify` so an `:amends` spec's landed-check can verify the amendment cites the plan; without it the check degrades to block-present and warns.

For wrapper skill integration, see `references/spec-lifecycle-protocol.md`.

### Workflow Integration

Install opt-in hooks for automated freshness monitoring:

```bash
# Install all hook tiers
/doc-superpowers hooks install --all

# Or pick specific tiers
/doc-superpowers hooks install --git           # Git hooks (where git runs them)
/doc-superpowers hooks install --claude        # Claude Code hooks (per-user)
/doc-superpowers hooks install --ci            # GitHub Actions: the 2 shell workflows

# Claude-powered workflows are opt-in by name
/doc-superpowers hooks install --ci --workflows=doc-pr-release,doc-review-pr
/doc-superpowers hooks install --ci --workflows=all    # every template
/doc-superpowers hooks install --ci --workflows=none   # only vendor doc-tools.sh
/doc-superpowers hooks install --ci --force            # also re-add workflows you removed on purpose

# CI tuning flags (recorded: a plain `install --ci` later reproduces them)
/doc-superpowers hooks install --ci --base-branch develop   # target branch (default: main)
/doc-superpowers hooks install --ci --cron "0 6 * * 1"      # weekly audit schedule (default: 0 9 * * 1)
/doc-superpowers hooks install --ci --ci-strict             # PR check fails on stale docs (--ci-strict=false undoes it)

# Standalone tool install (v2.12.0+) — doc-tools.sh only, no workflows
$DOC_TOOLS tools install                       # → .github/scripts/doc-tools.sh
$DOC_TOOLS tools install --with-helpers        # + every helper the CI templates run
$DOC_TOOLS tools install --helper doc-superpowers-steps  # + only the named helper dir(s)
$DOC_TOOLS tools status                        # present? matches the plugin? which version?
$DOC_TOOLS tools uninstall                     # removes only files identical to the plugin's

# Check what's installed (optionally one tier: --git / --claude / --ci);
# "⚠ … outdated: re-run install --git|--claude" marks another version's install
/doc-superpowers hooks status

# Remove hooks
/doc-superpowers hooks uninstall --all
/doc-superpowers hooks uninstall --ci --workflows=doc-release  # remove ONE workflow
```

The installer works from anywhere in the repository (it acts on the top level; a linked worktree or submodule is its own top level) and puts git hooks where git runs them (`git rev-parse --git-path hooks`). It refuses, writing nothing, when `core.hooksPath` comes from your global/system git config, or when a file it would write — or a directory on the way — is a symbolic link. It owns only what it marks: a hook of yours is kept, with a marked POSIX block after its `#!` line that runs ours (skipped if the hook is not a shell script); its `.gitattributes` and `info/exclude` entries are marked blocks; in `.claude/settings.local.json` it touches only the entries that run its own scripts. `uninstall` puts all of that back as it was. The Claude tier is **per-user**: its settings file and scripts are excluded from git through `.git/info/exclude`, and its commands run `"$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/…`.

**State tracking:** the CI tier's choices — the workflow set, base branch, cron, strict — persist in `.claude/doc-superpowers/installed.json` (commit it). A plain `install --ci` reproduces them and respects intentional uninstalls; pass `--workflows=<name>` to add one back, `--force` to re-add all, or `uninstall --ci --transient` so the next install re-installs. An unreadable state file (e.g. a merge conflict) is never overwritten: resolve it, or move it to `installed.json.corrupt` and the next install rebuilds it from disk without adding anything. Uninstall keeps a vendored helper you edited and says so (`Kept …`).

**Git hooks (5):** Pre-commit checks the staged tree, so it reports the docs *this* commit leaves stale (renames included), and every entry the staged index adds. An indexed doc the commit leaves out is "not in this commit" when it is on disk (`git add` it), "missing from disk" when it is gone. Post-merge and post-checkout report the docs a merge or branch switch left stale or missing. Prepare-commit-msg lists the stale docs as comment lines, only for a message written in the editor (git strips them; with `-m`/`-F` it adds nothing). Pre-push reminds about unreleased commits on the branches being pushed.

**Claude Code hooks (3):** They read the event JSON on stdin and answer through Claude Code's JSON output (`additionalContext` for Claude, `systemMessage` for you). The pre-commit gate (PreToolUse) checks the staged tree of a `git commit`; a command that stages as it commits (`git add … && git commit`, `commit -a`) is left to the git pre-commit hook, which sees the real index, and the gate says so. Post-commit sync (PostToolUse) reports the docs a commit left stale. Session summary (Stop, which fires after every response) reports docs citing code changed in the working tree; a clean tree costs nothing. No hook runs `update-index`: only a reviewer attests a doc.

**CI/CD (8 workflows — 2 shell-based, installed by default; 6 Claude-powered, opt-in by name):** The PR freshness check keeps one comment listing the docs the PR leaves stale or missing (`--ci-strict` fails the check). The weekly cron keeps one drift issue open while docs are stale and closes it after a clean check. Both fail closed: a check that cannot run is never reported as "all current". Which docs a change touches comes from the doc index, not from path filters. (The post-merge `doc-index-update` workflow was retired in v3.0.0: it recorded docs as verified that nobody had read. `install --ci` removes an installed copy it owns.) Claude-powered workflows provide AI audit+update on feature branches, AI PR doc review with @claude interactive support, AI release notes drafting on release branches, AI spec compliance checks on PRs, AI PR full-cycle orchestration (review, update, diagram, sync), and AI per-PR release-notes fragment producer (drafts `RELEASE-NOTES.next/PR-<N>.md` on every push, consumed by the release workflow at release time; the release commit, which deletes the consumed fragments, must then reach `main` — until it does, the next release refuses rather than release them twice). Claude-powered workflows require one of `CLAUDE_CODE_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` as a GitHub Actions secret; if both are set, `CLAUDE_CODE_OAUTH_TOKEN` takes precedence. They run with the job's own `GITHUB_TOKEN` (so `permissions:` bounds the token, and its pushes trigger no other workflow — nor any check run: a PR whose head is the bot's commit waits at "Expected" for its required checks until you push again or close and reopen it), install this plugin from its GitHub tag for the installed version, run only for same-repository PRs, and give the agent a scoped tool list and a turn cap. The agent never commits: a later step checks which paths changed (only docs, or only the release files) and commits them without force. That check is not a sandbox: an agent steered by text it reads (a PR, a comment) can run code with the job's secrets and use the token repository-wide, so protect your base branch and `release/**` with required human review (`references/hooks.md`, *What an AI job's agent can reach*). `doc-release` opens its PR with that token, which needs the repository setting *Allow GitHub Actions to create and approve pull requests* — a setting that also lets workflow jobs approve pull requests.

Set `DOC_SUPERPOWERS_STRICT=1` to make the git pre-commit hook and the Claude pre-commit gate block instead of warn (the gate exits 2 with the reason on stderr). Set `DOC_SUPERPOWERS_QUIET=1` to suppress hook output while still enforcing checks (the Claude gate still gives Claude its block reason). Set `DOC_SUPERPOWERS_SKIP=1` to bypass all hooks temporarily. A hook whose tooling is absent (no skill, no `docs/.doc-index.json`) stays silent; one whose check fails (jq missing from PATH, a corrupt index) prints one line saying so and, under STRICT, blocks.

## Generated Documentation

The `init` action generates a structured documentation suite in `docs/`:

| Directory/File | Content | When Generated |
|----------------|---------|---------------|
| `architecture/system-overview.md` | System overview, C4 diagrams, tech stack | Always |
| `architecture/{component}.md` | Per major component/domain | `application` scope |
| `architecture/diagrams/` | C4, component, ERD diagrams | Always |
| `specs/README.md` + `template.md` | Spec index and template | Always |
| `adr/README.md` + `template.md` | ADR log and template | Always |
| `workflows/{name}.md` | Process flows, CI/CD | Always |
| `workflows/agentic/{skill}.md` | Agentic workflow docs | `agentic` scope |
| `workflows/diagrams/` | Workflow, sequence, state diagrams | Always |
| `guides/getting-started.md` | Prerequisites, installation, verification | Always |
| `api-contracts.md` | Endpoints, schemas, request/response | `api-contracts` scope |
| `data-layer.md` | Data models, ERD, storage | `data-layer` scope |
| `ci-cd.md` | Pipeline overview, triggers, environments | `ci-cd` scope |
| `infra.md` | Infrastructure topology, components | `infrastructure` scope |
| `codebase-guide.md` | Directory map, key files, code flow | Always |
| `conventions.md` | Code style, naming, git conventions | Always |
| `.doc-index.json` | Machine-readable freshness index | Always |

## Agentic Workflow Discovery

doc-superpowers automatically discovers Claude Code artifacts that define agentic pipelines:

- **Skills** (`.claude/skills/*/SKILL.md`) — sub-agents, scripts, user gates
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
├── .worktrees/           # Parallel agent dispatch worktrees (gitignored)
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
│   ├── scripts/          # Vendored doc-tools.sh + doc-superpowers-steps/
│   └── workflows/
│       ├── doc-freshness-pr.yml
│       ├── doc-freshness-schedule.yml
│       └── tests.yml     # This repo only: the five test suites (bash 5.x + 3.2), check-version, self-install check
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
│   ├── test-doc-pr-release.sh    # Test suite for doc-pr-release helpers
│   ├── merge-doc-index.sh        # Custom git merge driver for .doc-index.json
│   ├── test-merge-driver.sh      # Test suite for merge driver
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── state.sh          # Install-state tracking
│       ├── git/              # Git hook scripts (pre-commit, post-merge, etc.)
│       ├── claude/           # Claude Code hook scripts
│       └── ci/               # GitHub Actions workflow templates
├── references/
│   ├── doc-spec.md       # Templates and conventions
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format + spec compliance report
│   ├── release.md                 # `release` action steps
│   ├── hooks.md                   # `hooks` action: tiers, consent table, CI templates
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec lifecycle actions
│   ├── spec-lifecycle-protocol.md # Spec lifecycle integration guide
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

The skill itself (`skills/doc-superpowers/SKILL.md` + `references/`) has zero dependencies. The bundled tooling in `scripts/` requires:

| Dependency | Required | Notes |
|-----------|----------|-------|
| `bash` | Yes, **≥ 3.2** | macOS's `/bin/bash` (3.2) is supported; nothing needs bash 4 |
| `git` | Yes | Already required by doc-superpowers |
| `jq` | Yes, **≥ 1.6** | `brew install jq` / `apt install jq`. 1.6 is the floor: the index writers use `--args` / `$ARGS.positional`. `doc-tools.sh` refuses an older jq with a clear error |
| `sha256sum` or `shasum` | Yes | Standard on Linux/macOS respectively |

Everything else is the POSIX userland (`awk`, `sed`, `grep`, `mktemp`, …) as stock macOS and Linux ship it: no GNU-only tool (GNU sed, ripgrep) is needed. Where `awk` is mawk (Debian, Ubuntu), it must be 1.3.4 or newer: older mawk lacks the POSIX character classes (`[[:space:]]`) the tools use.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes — the skill is `skills/doc-superpowers/SKILL.md` and `references/`, the tooling `scripts/`
4. Run the five test suites under both bash 5.x and macOS's `/bin/bash` 3.2 (the loop and the suite list are in [CLAUDE.md → Conventions](CLAUDE.md#conventions)); all must pass. CI runs the same matrix
5. If you changed a CI template, `scripts/doc-tools.sh` or a CI helper script, re-run `bash scripts/hooks/install.sh install --ci` and commit what it writes: this repository installs its own CI tier, and CI fails when the installed copies drift from their sources
6. For a change to the skill's behaviour, also try it with `/doc-superpowers init` (or the action you changed) on a sample project
7. Submit a PR

## License

MIT License. See [LICENSE](LICENSE).

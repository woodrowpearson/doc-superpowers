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
- **Tracks freshness** via bundled `scripts/doc-tools.sh` — content hashing for docs, commit SHA comparison for code

## Installation

### Claude Code (Skill)

Copy or symlink into your Claude Code skills directory:

```bash
# Clone
git clone git@github.com:woodrowpearson/doc-superpowers.git ~/code/doc-superpowers

# Symlink into Claude Code skills
ln -s ~/code/doc-superpowers ~/.claude/skills/doc-superpowers
```

### Manual

Copy `SKILL.md` and `references/` into `.claude/skills/doc-superpowers/` in any project.

### Cursor

Use Cursor's plugin system:

```
/add-plugin doc-superpowers
```

Or clone and point `.cursor-plugin/plugin.json` at the repo.

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
| `audit` | Check all docs for staleness | Periodic health check |
| `review-pr` | Check docs affected by PR changes | Before merging PRs |
| `update` | Apply fixes from audit/review | After audit identifies stale docs |
| `diagram` | Regenerate architecture diagrams | After structural changes |
| `sync` | Sync doc index with filesystem | After adding/removing doc files |
| `hooks` | Install workflow hooks (git, Claude Code, CI/CD) | Setting up automated freshness monitoring |
| `release` | Draft release notes entry from git history | Cutting a new version |
| `spec-generate` | Generate formal specs from design doc | After brainstorming produces a design spec |
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
```

For wrapper skill integration, see `references/spec-lifecycle-protocol.md`.

### Workflow Integration

Install opt-in hooks for automated freshness monitoring:

```bash
# Install all hook tiers
/doc-superpowers hooks install --all

# Or pick specific tiers
/doc-superpowers hooks install --git           # Git hooks
/doc-superpowers hooks install --claude        # Claude Code hooks
/doc-superpowers hooks install --ci            # GitHub Actions

# Check what's installed
/doc-superpowers hooks status

# Remove hooks
/doc-superpowers hooks uninstall --all
```

**Git hooks:** Pre-commit warns when staged files affect stale docs. Post-merge and post-checkout alert on branch switches. Prepare-commit-msg injects freshness comments.

**Claude Code hooks:** Pre-commit gate catches Claude-initiated commits. Session summary reminds about stale docs when ending a session.

**CI/CD:** PR freshness check comments on PRs. Weekly cron detects drift. Post-merge workflow keeps the doc index in sync.

Set `DOC_SUPERPOWERS_STRICT=1` to make pre-commit block instead of warn. Set `DOC_SUPERPOWERS_QUIET=1` to suppress hook output while still enforcing checks. Set `DOC_SUPERPOWERS_SKIP=1` to bypass all hooks temporarily.

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
├── .claude-plugin/       # Claude Code plugin manifest + marketplace
│   ├── plugin.json
│   └── marketplace.json
├── .cursor-plugin/       # Cursor plugin manifest
│   └── plugin.json
├── .codex/               # Codex installation guide
│   └── INSTALL.md
├── .opencode/            # OpenCode plugin + installation guide
│   ├── INSTALL.md
│   └── plugins/
│       └── doc-superpowers.js
├── SKILL.md              # Main skill definition
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling
│   ├── test-doc-tools.sh # Test suite for doc-tools.sh
│   ├── test-helpers.sh   # Shared test utilities
│   ├── test-hooks.sh     # Test suite for hooks installer
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── git/              # Git hook scripts (pre-commit, post-merge, etc.)
│       ├── claude/           # Claude Code hook scripts
│       └── ci/               # GitHub Actions workflow templates
├── references/
│   ├── doc-spec.md       # Templates and conventions
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format + plan template
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec lifecycle actions
│   ├── spec-lifecycle-protocol.md # Spec lifecycle integration guide
│   ├── integration-patterns.md    # Code review, commit review, wrapper skill integration
│   └── tool-mappings.md           # Cross-framework tool name mappings
├── evals/                # Evaluation test cases
│   └── evals.json        # Test prompts and assertions
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

The skill itself (`SKILL.md` + `references/`) has zero dependencies. The bundled tooling in `scripts/` requires:

| Dependency | Required | Notes |
|-----------|----------|-------|
| `git` | Yes | Already required by doc-superpowers |
| `jq` | Yes | `brew install jq` / `apt install jq` |
| `sha256sum` or `shasum` | Yes | Standard on Linux/macOS respectively |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes to `SKILL.md` or `references/doc-spec.md`
4. Test with `/doc-superpowers init` on a sample project
5. Submit a PR

## License

MIT License. See [LICENSE](LICENSE).

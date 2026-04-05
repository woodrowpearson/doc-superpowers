# Installing doc-superpowers for Cursor

## Quick Install

Install from the Cursor plugin marketplace, or clone manually:

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.cursor/plugins/doc-superpowers
```

The `.cursor-plugin/plugin.json` manifest declares the skill path. Cursor discovers `skills/doc-superpowers/SKILL.md` automatically.

## Verify

Start a new Cursor session. Try:

```
audit my project's documentation
```

## Tool Compatibility

Cursor uses the same tool names as Claude Code (both are Anthropic-ecosystem). No translation is needed — all skill instructions work as-is.

## Available Commands

| Command | Purpose |
|---------|---------|
| `init` | Generate docs from scratch |
| `audit` | Full documentation health check |
| `review-pr` | PR-scoped doc review |
| `update` | Execute doc updates from audit |
| `diagram` | Regenerate diagrams |
| `sync` | Sync doc index with filesystem |
| `hooks install` | Install workflow hooks |
| `hooks status` | Show installed hooks |
| `hooks uninstall` | Remove installed hooks |
| `release` | Draft release notes |
| `spec-generate` | Generate formal specs from design doc |
| `spec-inject` | Inject spec tasks or track drift |
| `spec-verify` | Verify spec compliance |

## Feature Parity

Cursor has **full feature parity** with Claude Code:

- All 11 commands listed above
- Parallel agent dispatch (up to 3 agents for init/audit)
- All 3 hook tiers (git, Claude Code, CI/CD)
- Mermaid MCP diagram generation (if MCP configured)
- WebSearch / WebFetch
- Spec lifecycle tracking

## Hooks Support

| Hook Tier | Supported | Notes |
|-----------|-----------|-------|
| Git hooks (5) | Yes | Installed via `scripts/hooks/install.sh` |
| Claude Code hooks (3) | Yes | Uses `.claude/settings.local.json` |
| CI/CD workflows (7) | Yes | Framework-agnostic GitHub Actions templates |

Install hooks with: `hooks install --all`

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) are harness-agnostic — they read/write files and run shell commands, all of which work identically in Cursor. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Usage

See the project [README.md](../README.md) for command reference and examples.

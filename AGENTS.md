# doc-superpowers

Documentation orchestrator skill for AI coding agents. Generates, audits, and maintains project documentation.

## Skill Location

The main skill definition is `skills/doc-superpowers/SKILL.md`. Activate it when the user asks about documentation quality, auditing, freshness, diagrams, specs, ADRs, or release notes.

## Key Commands

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

## Platform Setup

| Platform | Setup |
|----------|-------|
| Claude Code | `/plugin marketplace add woodrowpearson/doc-superpowers`, then `/plugin install doc-superpowers@doc-superpowers` (manifest: `.claude-plugin/plugin.json`) — see `README.md` |
| Cursor | `.cursor-plugin/INSTALL.md` |
| Codex | `.codex/INSTALL.md` |
| OpenCode | `.opencode/INSTALL.md` |
| Gemini CLI | `gemini extensions install https://github.com/woodrowpearson/doc-superpowers` (`gemini-extension.json` loads `GEMINI.md`) |

## Tool Mapping and Capabilities

This skill is written with Claude Code's tool names. `references/tool-mappings.md` is the one capability matrix: each client's tool for every Claude Code tool the skill names, and which hook tiers, subagent and diagram features each client supports. Read it when your client is not Claude Code; it is not repeated here.

## Directory Structure

See `CLAUDE.md` for the full directory map, key files table, and conventions.

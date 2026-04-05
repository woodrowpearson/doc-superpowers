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

| Platform | Setup Guide | Tool Translation |
|----------|-------------|------------------|
| Claude Code | `.claude-plugin/plugin.json` (auto-discovered) | Native — no translation |
| Cursor | `.cursor-plugin/INSTALL.md` | Native — same as Claude Code |
| Codex | `.codex/INSTALL.md` | `references/tool-mappings.md` |
| OpenCode | `.opencode/INSTALL.md` | Auto-injected by plugin |
| Gemini CLI | `GEMINI.md` (loaded via `gemini-extension.json`) | `references/tool-mappings.md` |

## Capability Matrix

| Capability | Claude Code | Cursor | Codex | OpenCode | Gemini CLI |
|------------|------------|--------|-------|----------|------------|
| All 11 commands | Yes | Yes | Yes | Yes | Yes |
| Parallel agent dispatch | Yes | Yes | Yes (needs config) | Yes (`@mention`) | No (sequential) |
| Git hooks | Yes | Yes | Partial (sandbox) | Yes | Yes |
| Claude Code hooks | Yes | Yes | No | No | No |
| CI/CD workflows | Yes | Yes | Yes | Yes | Yes |
| WebSearch / WebFetch | Yes | Yes | No | No | Yes |
| Mermaid MCP diagrams | Yes | Yes | If configured | If configured | No (source only) |

## Tool Mapping

This skill was written for Claude Code. If your agent uses different tool names, see `references/tool-mappings.md` for the translation table.

## Directory Structure

See `CLAUDE.md` for the full directory map, key files table, and conventions.

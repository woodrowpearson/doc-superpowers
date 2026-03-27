# doc-superpowers

Documentation orchestrator skill for AI coding agents. Generates, audits, and maintains project documentation.

## Skill Location

The main skill definition is `SKILL.md` at the repository root. Activate it when the user asks about documentation quality, auditing, freshness, diagrams, specs, ADRs, or release notes.

## Key Commands

| Command | Purpose |
|---------|---------|
| `init` | Generate docs from scratch |
| `audit` | Full documentation health check |
| `review-pr` | PR-scoped doc review |
| `update` | Execute doc updates from audit |
| `diagram` | Regenerate diagrams |
| `sync` | Sync doc index with filesystem |
| `hooks` | Install/manage workflow hooks |
| `release` | Draft release notes |
| `spec-generate` | Generate formal specs from design doc |
| `spec-inject` | Inject spec tasks or track drift |
| `spec-verify` | Verify spec compliance |

## Tool Mapping

This skill was written for Claude Code. If your agent uses different tool names, see `references/tool-mappings.md` for the translation table.

## Directory Structure

See `CLAUDE.md` for the full directory map, key files table, and conventions.

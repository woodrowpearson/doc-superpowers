# doc-superpowers

Documentation orchestrator skill for AI coding agents. Generates, audits, and maintains project documentation.

## Skill Location

The main skill definition is `skills/doc-superpowers/SKILL.md`. Activate it when the user asks to set doc-superpowers up in a repository, or about documentation quality, auditing, freshness, diagrams, specs, ADRs, release notes, a work ledger (keyed issue files, ledger views, related or in-flight work), or doc-search (one MCP server over the docs and the code).

## Key Commands

| Command | Purpose |
|---------|---------|
| `init` | Generate docs from scratch |
| `audit` | Full documentation health check |
| `review-pr` | PR-scoped doc review |
| `update` | Execute doc updates from audit |
| `diagram` | Regenerate diagrams |
| `sync` | Sync doc index with filesystem |
| `setup` | Set this repository up in one pass: fixed safe defaults, every write shown first |
| `help` | One-screen help: every feature and command, or one topic |
| `hooks install` | Install workflow hooks |
| `hooks status` | Show installed hooks |
| `hooks uninstall` | Remove installed hooks |
| `hooks install --search` | Register doc-search, the opt-in MCP server over docs and code (`docs/search/config.json`, `references/search.md`; the server is the `search/` uv package) |
| `hooks install --search-gate` | Register doc-search's readiness gate as Claude Code and Codex hooks (`.claude/settings.json`, `.codex/hooks.json`; needs the `--search` launcher; `references/hooks.md`) |
| `release` | Draft release notes |
| `spec-generate` | Generate formal specs from design doc |
| `spec-inject` | Inject spec tasks or track drift |
| `spec-verify` | Verify spec compliance |
| `ledger` | Work ledger (opt-in, `docs/ledger/config.json`): `doc-tools.sh ledger <verb>` |

## Platform Setup

| Platform | Setup |
|----------|-------|
| Claude Code | `/plugin marketplace add woodrowpearson/doc-superpowers`, then `/plugin install doc-superpowers@doc-superpowers` (manifest: `.claude-plugin/plugin.json`) — see `README.md` |
| Cursor | `.cursor-plugin/INSTALL.md` |
| Codex | `.codex/INSTALL.md` |
| OpenCode | `.opencode/INSTALL.md` |
| Gemini CLI | `gemini extensions install https://github.com/woodrowpearson/doc-superpowers` (`gemini-extension.json` loads `GEMINI.md`) |

After installing, the entry point in each repository is `setup` (`/doc-superpowers setup`, or `scripts/doc-superpowers setup` from the plugin's root in a terminal): fixed safe defaults, every write shown first, the team's choice recorded; `references/setup.md`. `help` prints the one-screen map of every feature and command.

## Tool Mapping and Capabilities

This skill is written with Claude Code's tool names. `references/tool-mappings.md` is the one capability matrix: each client's tool for every Claude Code tool the skill names, and which hook tiers, subagent and diagram features each client supports. Read it when your client is not Claude Code; it is not repeated here.

## Directory Structure

See `CLAUDE.md` for the full directory map, key files table, and conventions.

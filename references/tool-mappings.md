# Tool Mappings

This skill was written for Claude Code. The table below maps Claude Code tool names to their equivalents in other agent frameworks.

> Last verified: Claude Code 2026-04-05, Cursor 2026-04-05, Codex 2026-04-05, OpenCode 2026-04-05, Gemini CLI 2026-04-05

## Quick Reference

| Claude Code | Codex | OpenCode | Gemini CLI |
|-------------|-------|----------|------------|
| `Read` | `read_file` | `read_file` | `read_file` |
| `Write` | `write_file` | `write_file` | `write_file` |
| `Edit` | `edit_file` | `edit_file` | `replace` |
| `Bash` | `shell` | `shell` | `run_shell_command` |
| `Grep` | `grep_search` | `grep_search` | `grep_search` |
| `Glob` | `glob` | `glob` | `glob` |
| `WebSearch` | N/A | N/A | `google_web_search` |
| `WebFetch` | N/A | N/A | `web_fetch` |
| `Skill` | Native (auto-discovered) | `skill` | `activate_skill` |
| `TodoWrite` | `update_plan` | `todowrite` | `write_todos` |
| `Task` (subagent) | `spawn_agent` | `@mention` syntax | **Not available** — use sequential execution |
| `Agent` (subagent) | `spawn_agent` | `@mention` syntax | **Not available** — use sequential execution |
| `AskUserQuestion` | `ask` | `ask` | N/A (use inline text) |
| `EnterPlanMode` / `ExitPlanMode` | N/A | N/A | N/A |
| `NotebookEdit` | N/A | N/A | N/A |
| `mcp__mermaid__*` (diagram MCP) | MCP if configured | MCP if configured | N/A — output Mermaid source only |

## Tool resolution

Every client finds the bundled tooling the same way: from the skill's own directory, never from a client-specific install location. SKILL.md's *Detect Bundled Tooling* block sets `ROOT="${CLAUDE_SKILL_DIR}/../.."` — the plugin root, two levels above the directory holding `SKILL.md` — and takes `$ROOT/scripts/doc-tools.sh`, `$ROOT/scripts/hooks/install.sh` and `$ROOT/references/` from it.

- **Claude Code** substitutes `${CLAUDE_SKILL_DIR}` when it loads the skill, so the block runs as written.
- **Any other client** leaves it literal: put in the path of the directory the client loaded `SKILL.md` from (the skill path it reports, or the path you read the file at).
- The Claude Code plugin cache (`~/.claude/plugins/cache/doc-superpowers/doc-superpowers/<version>/`) is only a fallback, tried when `$ROOT` holds no executable `doc-tools.sh`; with neither, the block stops rather than run a tool that is not there.
- CI workflows do not resolve at all: they call the vendored `.github/scripts/doc-tools.sh` by that literal path, the one their `--allowedTools` grants.

## Hooks Compatibility

| Hook Tier | Claude Code | Cursor | Codex | OpenCode | Gemini CLI |
|-----------|------------|--------|-------|----------|------------|
| Git hooks (5) | Yes | Yes | Partial (sandbox limits `git push`) | Yes | Yes |
| Claude Code hooks (3) | Yes | Yes | No | No | No |
| CI/CD workflows (7) | Yes | Yes | Yes | Yes | Yes |

Claude Code hooks use `.claude/settings.local.json` which only Claude Code and Cursor support. Git hooks and CI/CD workflows are framework-agnostic.

## Framework-Specific Notes

### Cursor
- Tool names match Claude Code (both are Anthropic-ecosystem) — no translation needed
- Plugin manifest at `.cursor-plugin/plugin.json` declares skill paths explicitly
- Full feature parity with Claude Code

### Codex
- Subagent dispatch via `spawn_agent` requires `multi_agent = true` in config
- Codex App runs in a sandbox (detached HEAD, no `git push`) — doc-superpowers works fine since it only reads code and writes doc files
- WebSearch/WebFetch not available — skill workflows do not depend on them

### OpenCode
- Subagents use `@mention` syntax rather than explicit tool calls
- Plugin at `.opencode/plugins/doc-superpowers.js` auto-registers the skill path and injects this mapping file into the system prompt automatically
- WebSearch/WebFetch not available — skill workflows do not depend on them

### Gemini CLI
- No subagent support — parallel audit dispatch falls back to sequential scope-by-scope execution
- `GEMINI.md` loads the skill and this mapping file via `@` includes
- Has `google_web_search` and `web_fetch` (shared capability with Claude Code)
- Mermaid MCP not available — `diagram` action outputs Mermaid source instead of PNGs

# Tool Mappings

This skill was written for Claude Code. The table below maps Claude Code tool names to their equivalents in other agent frameworks.

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

## Framework-Specific Notes

### Codex
- Subagent dispatch via `spawn_agent` requires `multi_agent = true` in config
- Codex App runs in a sandbox (detached HEAD, no `git push`) — doc-superpowers works fine since it only reads code and writes doc files

### OpenCode
- Subagents use `@mention` syntax rather than explicit tool calls
- Plugin at `.opencode/plugins/doc-superpowers.js` auto-registers the skill path

### Gemini CLI
- No subagent support — parallel audit dispatch falls back to sequential scope-by-scope execution
- `GEMINI.md` loads the skill and this mapping file via `@` includes

### Cursor
- Tool names match Claude Code (both are Anthropic-ecosystem)
- Plugin manifest at `.cursor-plugin/plugin.json` declares skill paths explicitly

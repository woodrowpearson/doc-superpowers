@./skills/doc-superpowers/SKILL.md
@./references/tool-mappings.md

# Gemini CLI Notes

This skill was written for Claude Code. The sections below cover what differs in Gemini CLI.

## Tool Names

See the tool mappings loaded above. Key translations:

| Claude Code | Gemini CLI |
|-------------|------------|
| `Read` / `Write` | `read_file` / `write_file` |
| `Edit` | `replace` |
| `Bash` | `run_shell_command` |
| `Skill` | `activate_skill` |
| `TodoWrite` | `write_todos` |

## Subagent Dispatch (Sequential Fallback)

Gemini CLI does not support parallel subagent dispatch. Where the skill references `Agent` or `Task` tools (used by `init` and `audit` to dispatch up to 3 parallel agents), work through scopes sequentially instead:

1. Run discovery to detect all scopes
2. For each scope, perform the agent's work inline (gather, analyze, report/execute)
3. Merge results after processing all scopes

This is slower but functionally equivalent.

## Feature Parity

| Feature | Status |
|---------|--------|
| All 11 commands | Full parity |
| File I/O, shell, grep, glob | Full parity (translated tool names) |
| WebSearch / WebFetch | Full parity (`google_web_search`, `web_fetch`) |
| Freshness tooling (`doc-tools.sh`) | Full parity |
| Spec lifecycle (generate/inject/verify) | Full parity |
| Parallel agent dispatch (init, audit) | Degraded — sequential only |
| Mermaid diagram generation | Degraded — Mermaid source only, no PNG (MCP not available) |
| Git hooks (5) | Full parity |
| Claude Code hooks (3) | Not available (requires `.claude/settings.local.json`) |
| CI/CD workflows (7) | Full parity |

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) are harness-agnostic — they read/write files and run shell commands, all of which work identically in Gemini CLI. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Hooks

Git hooks and CI/CD workflow templates work in Gemini CLI (they are framework-agnostic shell scripts and GitHub Actions). Claude Code hooks (PreToolUse, PostToolUse, Stop) are not available — they require `.claude/settings.local.json`.

Install hooks with: `hooks install --git --ci`

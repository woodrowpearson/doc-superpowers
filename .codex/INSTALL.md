# Installing doc-superpowers for Codex

## Quick Install

```bash
# Clone the repo
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers

# Create the cross-client skills directory if it doesn't exist
mkdir -p ~/.agents/skills

# Symlink the skill (Codex scans ~/.agents/skills/ at startup)
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
```

## Verify

Start a new Codex session. The skill should appear in the available skills list. Try:

```
audit my project's documentation
```

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

## Tool Differences

Codex uses different tool names than Claude Code. The skill references Claude Code tool names — Codex translates them automatically via SKILL.md discovery. See `references/tool-mappings.md` for the full mapping table.

Key differences:

| Claude Code | Codex |
|-------------|-------|
| `Task` / `Agent` (subagent dispatch) | `spawn_agent` |
| `TodoWrite` | `update_plan` |
| `Bash` | `shell` |
| `Skill` | Native (auto-discovered from SKILL.md) |

## Subagent Dispatch

Parallel agent dispatch (`init` and `audit` use up to 3 agents) requires multi-agent mode:

```toml
# In your Codex config
multi_agent = true
```

Without this, subagent dispatch will fail. The skill's `init` and `audit` commands will not be able to parallelize scope discovery.

## Hooks Support

| Hook Tier | Supported | Notes |
|-----------|-----------|-------|
| Git hooks (5) | Partial | Works, but Codex App sandbox blocks `git push` (pre-push hook runs but push is denied) |
| Claude Code hooks (3) | No | These use `.claude/settings.local.json` which Codex does not support |
| CI/CD workflows (7) | Yes | Framework-agnostic GitHub Actions templates |

Install hooks with: `hooks install --git --ci`

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) are harness-agnostic — they read/write files and run shell commands, all of which work identically in Codex. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Known Limitations

- **WebSearch / WebFetch**: Not available in Codex. The skill's core workflows do not depend on these tools.
- **Mermaid MCP**: Available if you configure MCP in your Codex environment. Without it, the `diagram` action outputs Mermaid source text instead of PNGs.
- **Git sandbox**: Codex App runs with a detached HEAD and blocks `git push` / `git checkout -b`. doc-superpowers works fine since it only reads code and writes documentation files.

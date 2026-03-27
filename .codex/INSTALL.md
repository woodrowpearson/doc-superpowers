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

## Tool Differences

Codex uses different tool names than Claude Code. See `references/tool-mappings.md` for the full mapping. Key differences:

| Claude Code | Codex |
|-------------|-------|
| `Task` (subagent dispatch) | `spawn_agent` (requires `multi_agent = true`) |
| `TodoWrite` | `update_plan` |
| `Skill` | Skills load natively via SKILL.md discovery |

## Codex App Notes

The Codex App runs in a sandbox with a detached HEAD and blocked `git push`/`git checkout -b`. doc-superpowers works fine in this mode — it reads code and writes documentation files, neither of which require git write operations.

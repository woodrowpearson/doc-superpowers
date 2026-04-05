# Installing doc-superpowers for OpenCode

## Quick Install

Add to your project's `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

Or pin to a specific version:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git#v2.8.0"]
}
```

> **Tip:** Check `RELEASE-NOTES.md` for the latest version before pinning.

## Alternative: Local Install

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.config/opencode/plugins/doc-superpowers
```

Then add to `opencode.json`:

```json
{
  "skills": {
    "paths": ["~/.config/opencode/plugins/doc-superpowers"]
  }
}
```

## Verify

Start a new OpenCode session. Try:

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

The plugin at `.opencode/plugins/doc-superpowers.js` handles tool translation automatically. It registers the skill path and injects `references/tool-mappings.md` into the system prompt — you do not need to do anything manually.

Key differences from Claude Code:

| Claude Code | OpenCode |
|-------------|----------|
| `Task` / `Agent` (subagent dispatch) | `@mention` syntax |
| `TodoWrite` | `todowrite` |
| `Bash` | `shell` |
| `Skill` | `skill` |

## Subagent Dispatch

OpenCode uses `@mention` syntax for subagent dispatch rather than explicit `Task`/`Agent` tool calls. The skill's `init` and `audit` commands reference parallel agent dispatch — in OpenCode, mention the relevant agent to dispatch work.

## Hooks Support

| Hook Tier | Supported | Notes |
|-----------|-----------|-------|
| Git hooks (5) | Yes | Installed via `scripts/hooks/install.sh` |
| Claude Code hooks (3) | No | These use `.claude/settings.local.json` which OpenCode does not support |
| CI/CD workflows (7) | Yes | Framework-agnostic GitHub Actions templates |

Install hooks with: `hooks install --git --ci`

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) are harness-agnostic — they read/write files and run shell commands, all of which work identically in OpenCode. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Known Limitations

- **WebSearch / WebFetch**: Not available in OpenCode. The skill's core workflows do not depend on these tools.
- **Mermaid MCP**: Available if you configure MCP in your OpenCode environment. Without it, the `diagram` action outputs Mermaid source text instead of PNGs.

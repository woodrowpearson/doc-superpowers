# Installing doc-superpowers for OpenCode

## Quick Install

Add to your project's `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

Or pin to a release — replace `vX.Y.Z` with a tag from `RELEASE-NOTES.md`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git#vX.Y.Z"]
}
```

## Alternative: Local Install

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.config/opencode/plugins/doc-superpowers
```

Then load the clone's plugin by file URL in `opencode.json` (use your absolute home path); the plugin registers the skill path itself:

```json
{
  "plugin": ["file:///ABSOLUTE/HOME/.config/opencode/plugins/doc-superpowers/.opencode/plugins/doc-superpowers.js"]
}
```

Registering only the skill — `"skills": { "paths": ["~/.config/opencode/plugins/doc-superpowers"] }` — also works, but then nothing puts the tool mapping into the system prompt: point the agent at [`references/tool-mappings.md`](../references/tool-mappings.md) yourself.

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

## Tool names and capabilities

The plugin at `.opencode/plugins/doc-superpowers.js` registers the skill path and adds `references/tool-mappings.md` to the system prompt — one more entry in OpenCode's system-prompt list, read once when the plugin loads. That file is the one capability matrix: OpenCode's tool for each Claude Code tool the skill names, and which hook tiers, subagent and diagram features work here. See [`references/tool-mappings.md`](../references/tool-mappings.md).

## Hooks

Install the tiers that work outside Claude Code with `hooks install --git --ci`. The Claude hook tier needs Claude Code; see the matrix.

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) read and write files and run shell commands, so they work in OpenCode as in Claude Code. See `references/spec-lifecycle-actions.md` for detailed procedures.

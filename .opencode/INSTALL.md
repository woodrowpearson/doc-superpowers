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

## Set up a repository

The entry point, once per repository: ask for `/doc-superpowers setup`, or run the plugin's `scripts/doc-superpowers setup` in a terminal — `~/.config/opencode/plugins/doc-superpowers/scripts/doc-superpowers setup` for the local install (a full-screen picker; `--link-bin` adds the terminal command `~/.local/bin/doc-superpowers`). It starts from fixed safe defaults — the doc-index merge driver and the 5 report-only git hooks; nothing downloads, nothing reaches the network, no CI — and shows every write before it makes one; it never commits, and prints the `git add` line instead. `doc-superpowers help` (or `/doc-superpowers help`) prints a one-screen map of every feature; [`references/setup.md`](../references/setup.md) is the full reference.

- The defaults also install the 3 Claude Code hooks, which OpenCode does not run: untick *Claude hooks* (`--set claude=off`) unless you use Claude Code too.
- With doc-search on, tick *OpenCode* under *Harness* (`--set harness=claude-code,opencode`): setup merges the doc-search entry into the project's `opencode.json` under `mcp`, keeping every other key (your `plugin` line included).

## Available Commands

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
| `release` | Draft release notes |
| `spec-generate` | Generate formal specs from design doc |
| `spec-inject` | Inject spec tasks or track drift |
| `spec-verify` | Verify spec compliance |
| `ledger` | Work ledger (opt-in, `docs/ledger/config.json`): `doc-tools.sh ledger <verb>` |

## Tool names and capabilities

The plugin at `.opencode/plugins/doc-superpowers.js` registers the skill path and adds `references/tool-mappings.md` to the system prompt — one more entry in OpenCode's system-prompt list, read once when the plugin loads. That file is the one capability matrix: OpenCode's tool for each Claude Code tool the skill names, and which hook tiers, subagent and diagram features work here. See [`references/tool-mappings.md`](../references/tool-mappings.md).

## Hooks

`setup` (above) installs the default tiers and records the choice. To install the tiers that work outside Claude Code by hand: `hooks install --git --ci`; in a project with a work ledger (`docs/ledger/config.json`), also its git legs, `hooks install --ledger`. The Claude hook tier and the ledger's Claude events (`--ledger-claude`) need Claude Code; see the matrix.

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) read and write files and run shell commands, so they work in OpenCode as in Claude Code. See `references/spec-lifecycle-actions.md` for detailed procedures.

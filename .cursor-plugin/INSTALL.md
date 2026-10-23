# Installing doc-superpowers for Cursor

## Install

doc-superpowers is not in the Cursor marketplace (as of 2026-09-27 it is not among the plugins in `cursor/plugins`' `marketplace.json`). Install it as a local plugin — Cursor loads local plugins from `~/.cursor/plugins/local/<name>/`:

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.cursor/plugins/local/doc-superpowers
```

Then restart Cursor, or run **Developer: Reload Window**.

- Clone into that folder; do not symlink a checkout from elsewhere. Cursor skips a symlink in `~/.cursor/plugins/local` whose target is outside that folder.
- On Teams and Enterprise plans an admin must allow **Local Plugin Imports** (Dashboard → Settings → Security & Identity → Marketplace and Plugins); it is off by default on Enterprise.
- `.cursor-plugin/plugin.json` points Cursor at `./skills/`, where the skill lives (`skills/doc-superpowers/SKILL.md`).

This path is what Cursor's plugin docs specify (cursor.com/docs/plugins, *Test plugins locally*); it has not yet been confirmed by an end-to-end install of this plugin. If the skill does not show up, check **Customize** for the plugin's skills and report what you see.

To update: `git -C ~/.cursor/plugins/local/doc-superpowers pull`, then reload.

## Verify

Open **Customize** and confirm the `doc-superpowers` skill is listed. Then start an Agent chat and try:

```
audit my project's documentation
```

## Set up a repository

The entry point, once per repository: ask for `/doc-superpowers setup`, or run `~/.cursor/plugins/local/doc-superpowers/scripts/doc-superpowers setup` in a terminal (a full-screen picker; `--link-bin` adds the terminal command `~/.local/bin/doc-superpowers`). It starts from fixed safe defaults — the doc-index merge driver and the 5 report-only git hooks; nothing downloads, nothing reaches the network, no CI — and shows every write before it makes one; it never commits, and prints the `git add` line instead. `doc-superpowers help` (or `/doc-superpowers help`) prints a one-screen map of every feature; [`references/setup.md`](../references/setup.md) is the full reference.

- The defaults also install the 3 Claude Code hooks, which are unverified under Cursor (below): untick *Claude hooks* (`--set claude=off`) unless you checked that they fire, or use Claude Code too.
- With doc-search on, tick *Cursor* under *Harness* (`--set harness=claude-code,cursor`): setup writes Cursor's entry in `.cursor/mcp.json` (unverified: no CLI to check it with).

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

The skill is written with Claude Code's tool names; Cursor's tools do the same jobs under different names. What each Claude Code tool corresponds to in Cursor, and which hook tiers, subagent and diagram features work here, is in the one capability matrix: [`references/tool-mappings.md`](../references/tool-mappings.md).

For hooks in particular (`setup`, above, installs the default tiers): git hooks and the CI workflows work as in any client. The Claude hook tier (`hooks install --claude`) is unverified under Cursor — Cursor's docs say it runs Claude Code hooks from `.claude/settings.json` when **Include Third-Party Plugins, Skills, and Other Configs** is enabled, but this tier writes `.claude/settings.local.json`, which they do not mention. Install it only after checking that the hooks fire, or use `hooks install --git --ci`. The same holds for the work ledger's sets: its git legs (`hooks install --ledger`) work as any git hook; its Claude events (`--ledger-claude`, which add a `SessionStart` hook Cursor's docs do not map) are unverified.

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) read and write files and run shell commands, so they work in Cursor as in Claude Code. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Usage

See the project [README.md](../README.md) for command reference and examples.

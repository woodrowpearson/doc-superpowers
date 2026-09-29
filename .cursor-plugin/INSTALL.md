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

The skill is written with Claude Code's tool names; Cursor's tools do the same jobs under different names. What each Claude Code tool corresponds to in Cursor, and which hook tiers, subagent and diagram features work here, is in the one capability matrix: [`references/tool-mappings.md`](../references/tool-mappings.md).

For hooks in particular: git hooks and the CI workflows work as in any client. The Claude hook tier (`hooks install --claude`) is unverified under Cursor — Cursor's docs say it runs Claude Code hooks from `.claude/settings.json` when **Include Third-Party Plugins, Skills, and Other Configs** is enabled, but this tier writes `.claude/settings.local.json`, which they do not mention. Install it only after checking that the hooks fire, or use `hooks install --git --ci`.

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) read and write files and run shell commands, so they work in Cursor as in Claude Code. See `references/spec-lifecycle-actions.md` for detailed procedures.

## Usage

See the project [README.md](../README.md) for command reference and examples.

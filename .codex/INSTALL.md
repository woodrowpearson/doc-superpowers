# Installing doc-superpowers for Codex

## Quick Install

```bash
# Clone the repo
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers

# Create the user skills directory if it doesn't exist
mkdir -p ~/.agents/skills

# Symlink the whole plugin (Codex reads user skills from ~/.agents/skills/ and follows symlinks)
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
```

Link the whole checkout, not only `skills/doc-superpowers/`: the skill finds `scripts/doc-tools.sh` and `references/` two directories above its own (see *Tool resolution* in [`references/tool-mappings.md`](../references/tool-mappings.md)). Codex then has to find `skills/doc-superpowers/SKILL.md` inside the link. Its skill loader has a recursive mode (up to six levels deep, hidden directories skipped); whether it scans `~/.agents/skills` in that mode is not documented (unverified). If the skill does not appear, link the skill directory itself instead — `ln -sfn ~/.codex/doc-superpowers/skills/doc-superpowers ~/.agents/skills/doc-superpowers` — and when the skill asks for its directory, give the real path, `~/.codex/doc-superpowers/skills/doc-superpowers`, not the link.

To pin a release, check out its tag: `git -C ~/.codex/doc-superpowers checkout vX.Y.Z` (the versions are in `RELEASE-NOTES.md`).

## Verify

Start a new Codex session. The skill should appear in the available skills list. Try:

```
audit my project's documentation
```

## Set up a repository

The entry point, once per repository: ask for `/doc-superpowers setup`, or run `~/.codex/doc-superpowers/scripts/doc-superpowers setup` in a terminal (a full-screen picker; `--link-bin` adds the terminal command `~/.local/bin/doc-superpowers`). It starts from fixed safe defaults — the doc-index merge driver and the 5 report-only git hooks; nothing downloads, nothing reaches the network, no CI — and shows every write before it makes one; it never commits, and prints the `git add` line instead. `doc-superpowers help` (or `/doc-superpowers help`) prints a one-screen map of every feature; [`references/setup.md`](../references/setup.md) is the full reference.

- The defaults also install the 3 Claude Code hooks, which Codex does not run: untick *Claude hooks* (`--set claude=off`) unless you use Claude Code too.
- With doc-search on, tick *Codex* under *Harness* (`--set harness=claude-code,codex`): setup writes Codex's entry in `.codex/config.toml`, which Codex loads only for a trusted project.

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

The skill is written with Claude Code's tool names, and Codex does not translate them by itself. SKILL.md's references table points the agent at the mapping; the full table — Codex's tool for each Claude Code tool, and which hook tiers, subagent and diagram features work here — is the one capability matrix: [`references/tool-mappings.md`](../references/tool-mappings.md).

## Subagent Dispatch

`init`, `audit`, `review-pr` and `update` dispatch one subagent per scope. Codex's subagent tools come with the `multi_agent` feature, which is **on by default**. If you have turned it off, turn it back on in `~/.codex/config.toml` — it is a `[features]` key (a top-level `multi_agent` is ignored):

```toml
[features]
multi_agent = true
```

## Hooks

`setup` (above) installs the default tiers and records the choice. To install the tiers that work outside Claude Code by hand: `hooks install --git --ci`; in a project with a work ledger (`docs/ledger/config.json`), also its git legs, `hooks install --ledger`. The Claude hook tier and the ledger's Claude events (`--ledger-claude`) need Claude Code; see the matrix.

## Spec Lifecycle

The spec lifecycle actions (`spec-generate`, `spec-inject`, `spec-verify`) read and write files and run shell commands, so they work in Codex as in Claude Code. See `references/spec-lifecycle-actions.md` for detailed procedures.

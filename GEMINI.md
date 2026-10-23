@./references/tool-mappings.md

# doc-superpowers in Gemini CLI

This extension ships the doc-superpowers skill in its `skills/doc-superpowers/` directory. Gemini CLI lists the skill at the start of each session and loads its `SKILL.md` only when a task matches — documentation audits, stale docs, diagrams, specs, ADRs, doc hooks, release notes or a work ledger of issue files. It is deliberately not imported here: this file is loaded into every session, the skill only when needed.

The skill is written with Claude Code's tool names. The mapping imported above is the one capability matrix: the **Gemini CLI** column gives the tool to use for each one, and the *Capabilities* table says which hook tiers, subagent and diagram features work here.

When the skill's *Detect Bundled Tooling* block asks for the skill's directory, use the path of `skills/doc-superpowers/` inside this extension; the extension root, two directories up, holds `scripts/doc-tools.sh` and `references/`.

The entry point in a repository is `setup` (`/doc-superpowers setup`, or `scripts/doc-superpowers setup` from the extension root in a terminal): it shows every write first, and its default Claude Code hooks are not run by Gemini CLI. The first run records them as the team's choice: leave them on when a teammate uses Claude Code and untick them for yourself on a later run (`--set claude=off`, a per-user override); untick them on the first run only when nobody does; with doc-search, tick *Gemini CLI* as a harness. `help` prints the one-screen map of every feature.

Or install the hook tiers that work outside Claude Code with `hooks install --git --ci` (and, with a work ledger — `docs/ledger/config.json` — its git legs, `hooks install --ledger`; its Claude events, `--ledger-claude`, need Claude Code).

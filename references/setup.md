# `setup` and `help` — set up a repository, and the one-screen help

**Read by** SKILL.md's `setup` and `help` actions — **REQUIRED** before either runs. `$ROOT` is the plugin root SKILL.md's *Detect Bundled Tooling* resolved; the dispatcher is `"$ROOT/scripts/doc-superpowers"`, and `setup` is its `scripts/setup/setup.sh`.

## What setup does

`setup` is one guided entry point for turning doc-superpowers on in a repository. It shows every feature as an item with a fixed safe default, shows every write before it makes one, then runs the hook installer (`scripts/hooks/install.sh`) for the items the installer manages and writes the few files it owns itself. It never re-implements the installer: each installer-managed item is one `install.sh install` or `uninstall` step, with the installer's own refusals.

- **The safety rule.** The defaults block no commit, download nothing, reach no network and add no CI. Nothing downloads without *Write and build* and a `[y/N]` yes (or `--build` with `--yes` or `--apply`). A scan hint never changes a selection; a host check only disables an item or option, and says why.
- **Where it acts.** The repository holding the current directory, at its top level (`git rev-parse --show-toplevel`): it runs from a subdirectory, and a linked worktree is its own top. Outside a git work tree it exits 1 with one line.
- **How to run it.** In a terminal, `doc-superpowers setup` (the terminal command, *The terminal command* below, or `"$ROOT/scripts/doc-superpowers" setup`): a full-screen picker, or plain prompts. From the skill, `/doc-superpowers setup`: the same engine, driven with flags (*The flow*).
- **It never commits.** It writes the files and prints the `git add -- <paths…>` line of the team's files that changed; committing them is your call.
- **It is idempotent.** The plan is the selection against what is installed now (`install.sh status --json --git --claude --ci --search` and the files on disk), never against the defaults: an item in place and current is no step, an outdated one (another version's install) is refreshed, an absent one is installed, and an installed one you untick is uninstalled. A re-run with nothing to change prints `nothing to do` and changes no byte.
- **Its order.** The switches the installer reads come first (`docs/search/config.json`, `docs/ledger/config.json`, `docs/spec-claims/config.json`), then the installer's steps, then the other harnesses' doc-search entries, the env hook, setup's exclude block and the terminal command, then the records, and a build last, only after every write succeeded. A step that fails stops the run (exit 2); every step is idempotent, so running setup again finishes the job.

What it does not do: run `ledger init`'s bootstrap, configure spec-claims adapters (`doc-superpowers help ledger` and `help claims` point to those flows), add CI templates, change what any installer tier installs, or commit.

## The defaults

The defaults are fixed: the same in every repository and on every host.

| On | Off |
|---|---|
| the `docs/.doc-index.json` merge driver, the 5 report-only git hooks, the 3 Claude Code hooks, the harness `claude-code` | doc-search, CI workflows, the work ledger, spec claims, the terminal command |

The git hooks and the Claude gate block a commit only under `DOC_SUPERPOWERS_STRICT=1` (and the git pre-commit's claims leg with `docs/spec-claims/`, which the defaults never write); none of the eight hooks reaches the network.

What setup starts from, the *base*:
- **No record, nothing installed:** the fixed defaults.
- **No record, but something installed** (an earlier `hooks install`, a `docs/search/config.json`, workflows): the defaults plus what is installed, each such item marked `(already installed)`. Unticking an installed item removes it, so a default run never removes anything.
- **A team record** (*The records*): the record, then your own overrides. That is what makes a re-run idempotent and lets `--apply` reproduce the team's setup.

A summary line reads `[x] <Group>  <value>` or `[ ] <Group>  off`, with ` (changed)` when it differs from the base and ` (already installed)` when the probe found it in place. Hints follow it (`  hint: …`): the docs corpus size, a gte first-build estimate, the harnesses the repository suggests, no doc index yet (`/doc-superpowers init`), no GitHub remote. They are never applied.

**A host that cannot run the git hooks.** When this host disables the git tier's *hooks* mode (a `core.hooksPath` in the global or system git config, or a repository-local one inside the work tree, such as Husky's `.husky/`), a base that wants *hooks* falls back to `merge-driver`, never to `off`, which would remove the team's merge driver; setup names it (`skipped: git: <reason>`). An installed hooks mode is kept when a `core.hooksPath` appears later. The team record keeps the team's wish: a host on the fallback never writes `"git": "merge-driver"` into it.

## The flow

**In a terminal** (the TUI, on a terminal of at least 60×16; below that, one line says why and the prompts run):
1. **Summary**: one line per group. *Apply these* → the review · *Customize…* → the tree · *Show what each does* (`help setup`) · *Cancel*.
2. **Tree and details**: the groups, collapsible, pre-ticked from the summary; the details pane shows the highlighted item's text, its scope, how to undo it and any reason it is disabled or locked (beside the tree at 80 columns or more, under it below that).
3. **Esc**: back to the summary, the changed groups marked `(changed)`.
4. **Review**: what the plan writes, split by where, the network and the downloads (the review sections, *Flags and exit codes*). *Write and build* (only when something builds), *Write only* (the cursor's default), *Back*. *Write and build* asks once more: `This downloads <what>. Continue? [y/N]` — `y` builds, `n` or Enter writes only, Esc goes back to the review.

| Key | Action |
|---|---|
| ↑ ↓ / k j | Move |
| space | Toggle (a choice item takes its next option) |
| → / enter | Open a group, or choose |
| ← | Close a group |
| e | Edit a value |
| Esc / b | Back |
| ? | The row's details in full |
| q | Quit: nothing is written |

**The prompts** (`--plain`, or when stdin or stdout is not a terminal, or `TERM` is `dumb` or unset): the summary, then `[a]pply  [c]ustomize  [s]how details  [q]uit`; Customize lists the groups, then a group's items as `n) [x] <label>[: <value>] -- <scope>` (a number toggles or asks for the value, `d <n>` shows the details, an empty line goes back); the review, then `[w]rite and build  [o] write only  [b]ack`, and `w` asks the same `[y/N]` question: `y` builds, `n` or an empty answer writes only, anything else asks again. `q`, or the end of input, quits with nothing written (exit 0). Nothing is written before the last answer in either UI.

**From the skill** (the Bash tool has no terminal, so the skill drives the engine through flags, with the same screens):
1. `"$ROOT/scripts/doc-superpowers" setup --dry-run` — the summary and the review, shown verbatim.
2. One question: *Apply these* / *Customize* / *Cancel*.
3. Customize: `setup --list` gives every item with its id, value, scope, options and any disabled or locked reason; one question round per group to change; then `setup --dry-run --set <id>=<value> …` prints the new review. When it exits 1 with a line naming `--for-team` (R9, below), the *for you only* / *for the team* question comes here.
4. One question: *Write and build* / *Write only* / *Back*. *Write and build* is offered only with doc-search on and when `setup --dry-run --set … --build` exits 0 (exit 1: this host has no `uv`), and needs a second, explicit yes to the download line that run printed. When a per-user item changed and a team record exists, the same round asks *for you only* (the default) / *for the team*; *for the team* changes the plan (the change goes to `installed.json`), so `setup --dry-run --set … --for-team` shows that review and the user confirms it before step 5.
5. `setup --yes --set … [--for-team] [--build] [--link-bin]`; with `--build`, in the background (a gte first build can take hours).
6. What was written, and the `git add` line.

**Per-user items and the team.** `git` (its hooks part), `claude`, `ledger.git` and `ledger.claude` are per-user. The first record a repository gets stores their values as the team's choice. After that a change to one is yours only (an override in `installed.local.json`), unless you save it for the team: *for the team* in the UIs, `--for-team` with `--yes`. `--for-team` makes the team's only the per-user values this run sets (named with `--set`, or changed against the base); any other override of yours stays yours. One exception: a `git` change that adds or removes the merge driver changes the committed `.gitattributes`, so it is the team's — refused (exit 1, `pass --for-team to change the team's choice`) without `--for-team`. `hooks` ↔ `merge-driver` stays a per-user change. A stored override that conflicts this way only because the team's choice changed later (yours `merge-driver`, then a teammate records `git=off` and you pull) is not refused: the team's value wins in every mode, `--apply` included. setup prints `setup: your git override (<yours>) conflicts with the team's choice (<team's>): dropped`, applies the team's value, and rewrites `installed.local.json` without the override (listed under *Local to you:*).

**A teammate's clone.** `setup --apply` reproduces the recorded team setup without asking: the team record, your local overrides, and `.tiers.ci`'s workflows and choices. It installs the per-user parts and re-writes any missing team file; it never writes the team record and takes no `--set` or `--for-team` (exit 3). With no team record (a CI-only record included) it exits 1: `no team setup recorded: run doc-superpowers setup`. An item this host's checks disable is skipped and named last (`skipped: <id>: <reason>`), the rest is applied, and the run exits 0: the teammate did not choose the record. It lists its writes outside the repository under *Local to you (outside the repository):*. `--apply --dry-run` shows what it would do.

**Unticking.** setup never deletes team content it did not just create:
- An installer-managed item (the git and Claude tiers, CI workflows, the ledger's hook sets, doc-search's launcher and `.mcp.json` entry) is removed by its own `install.sh uninstall` step; the other harnesses' entries as *Harness entries* says.
- `docs/search/config.json` is left in place when doc-search goes off; the review says so.
- The ledger and spec claims cannot be turned off while `docs/ledger/config.json` or `docs/spec-claims/` exists: that switch is the team's data. The item is shown ticked and locked, and its reason gives the manual step (`git rm` the switch, then `setup --yes --set ledger=off` or `claims=off`, and commit both).

## Items

`setup --list` prints one line per item: `<id>=<value>`, its scope, label, options, the reason this host disables it (or `<option>: <reason>` for one option, or `(locked: <reason>)`) and its hint, TAB-separated. `--set <id>=<value>` takes these ids; a multi's value is a CSV in the options' order, or `none`.

| Id | Group | Kind: values | Default | Scope | Writes | Undo |
|---|---|---|---|---|---|---|
| `harness` | Harness | multi: `claude-code,codex,cursor,opencode,gemini` | `claude-code` | team | with doc-search on, each harness's entry (*Harness entries*) | `--set harness=claude-code` |
| `search` | doc-search | toggle | `off` | team | `docs/search/config.json`, `.claude/doc-superpowers/search-mcp.sh`, `.mcp.json` | `--set search=off` (the config stays) |
| `search.model` | doc-search | choice: `static,gte` | `static` | team | `docs.model` in `docs/search/config.json` | `--set search.model=static` |
| `search.cache` | doc-search | value: `host` or an absolute path | `host` | local | `installed.local.json`; your env hook | `--set search.cache=host` |
| `git` | Git hooks | choice: `hooks,merge-driver,off` | `hooks` | team (the driver's `.gitattributes` block), local (`.git/config`, the hooks) | `.gitattributes`, `.git/config`, `.git/hooks/` | `doc-superpowers hooks uninstall --git` |
| `claude` | Claude hooks | toggle | `on` | local | `.claude/settings.local.json`, `.claude/hooks/doc-superpowers/`, `.git/info/exclude` | `doc-superpowers hooks uninstall --claude` |
| `ci.workflows` | CI workflows | multi: the 9 workflows `install.sh help` lists | `none` | team | `.github/workflows/`, `.github/scripts/`, `.tiers.ci` in `installed.json` | `doc-superpowers hooks uninstall --ci` |
| `ci.base_branch` | CI workflows | value: a branch name | `main` | team | the workflows, `.tiers.ci` | `--set ci.base_branch=main` |
| `ci.cron` | CI workflows | value: 5 cron fields (UTC) | `0 9 * * 1` | team | the workflows, `.tiers.ci` | `--set 'ci.cron=0 9 * * 1'` |
| `ci.strict` | CI workflows | toggle | `off` | team | the workflows, `.tiers.ci` | `--set ci.strict=off` |
| `ledger` | Work ledger | toggle | `off` | team | `docs/ledger/config.json` = `{}` | `git rm docs/ledger/config.json` |
| `ledger.git` | Work ledger | toggle | `off` | local | marked blocks in `.git/hooks/` | `doc-superpowers hooks uninstall --ledger` |
| `ledger.claude` | Work ledger | toggle | `off` | local | `.claude/settings.local.json`, `.claude/hooks/doc-superpowers/` | `doc-superpowers hooks uninstall --ledger-claude` |
| `claims` | Spec claims | toggle | `off` | team | `docs/spec-claims/config.json` = `{"schema": 1}` | `git rm -r docs/spec-claims` |
| `bin` | Terminal command | toggle | `off` | local, outside the repository | `~/.local/bin/doc-superpowers` | `--no-link-bin` |

(*Undo* `--set …` means `doc-superpowers setup --yes --set …`.)

- **Children.** `search.model` and `search.cache` need `search=on`; `ledger.git` and `ledger.claude` need `ledger=on`; `ci.base_branch`, `ci.cron` and `ci.strict` need `ci.workflows` other than `none`. Setting a child turns its parent on (`ci.*` with the installer's default set, `doc-freshness-pr,doc-freshness-schedule`), except that setting a child to its default while its parent is off changes nothing (the *Undo* lines above are such sets: `--set search.cache=host` with doc-search off is `nothing to do`); turning a parent off resets its children to their defaults.
- **`claude-code` stays on while doc-search is on**: `install --search` always registers the Claude Code entry in `.mcp.json`, so `--set harness=…` without `claude-code` is refused then.
- **`search.model=gte`** stores `"transformer:gte-modernbert-base"` in `docs/search/config.json` and in the record. The config setup writes is `doc-search init`'s defaults, written with jq: `uv` never runs on *Write only*. An existing config gets `docs.model` alone changed. On a host that cannot run gte (*Host checks*) with a team record holding gte, a missing config is still written with gte, the record's model: one host's quirk is not the team's setting. That host skips gte (`skipped: search.model: gte: <reason>`) and refuses `--build` (exit 1).
- **The git tier is three modes**, not five toggles: the installer installs the tier as a whole. *hooks* is the merge driver plus pre-commit, post-merge, post-checkout, prepare-commit-msg and pre-push (`references/hooks.md`).
- **Can block a commit:** the spec-claims pre-commit leg (a claims finding blocks it, whatever `DOC_SUPERPOWERS_STRICT` says), the ledger's pre-commit set (`ledger validate --staged`), and `ci.strict` (a PR check, never a local commit).
- **Can reach a remote** (the review's *Network:* lists each ticked one): doc-search's downloads (*Write and build*, `--build`, or each client's first start of the server after that client's own approval prompt); the ledger's `keys.mode cas` key issuing; the ledger git set's post-commit leg when `inflight.enabled` is on (off in the `{}` config setup writes); the CI workflows, which run on GitHub.

**Host checks** (each disables, never decides; a check that cannot decide disables nothing):

| Check | Disables |
|---|---|
| No `uv` | doc-search's build (`uv not found`); the item stays, so a team can commit the entries without a build |
| arm64 macOS below 14 | `search.model`'s `gte` (onnxruntime 1.31 needs macOS 14) |
| A host that is neither macOS nor Linux | `search.model`'s `gte` |
| `core.hooksPath` in the global or system git config | `git`'s `hooks` mode (the installer refuses it); `merge-driver` stays |
| A repository-local `core.hooksPath` inside the work tree | `git`'s `hooks` mode: the hooks would be committed with this machine's plugin path; `merge-driver` stays |
| `~/.local/bin` (or the file in it) a symbolic link, not a directory, or not writable; a `~/.local/bin/doc-superpowers` that is not setup's shim | `bin` |

A `--set` that forces a disabled item or option exits 1.

## Flags and exit codes

`doc-superpowers setup [flags]`:

| Flag | Effect |
|---|---|
| (none) | Interactive: the TUI on a terminal, else the prompts. Refuses `--build` and `--for-team` (exit 3): the UI asks both |
| `--dry-run` | The summary, a blank line, then the review; writes nothing; exit 0 |
| `--yes` | Applies the selection (the base plus `--set`) without asking: the steps, as the review lists them, then the `git add` line, or `nothing to do`. *Write only*: nothing downloads |
| `--apply` | Reproduces the recorded team setup (*The flow* → *A teammate's clone*). Takes no `--set` and no `--for-team`; `--apply --dry-run` previews it |
| `--build` | With `--yes` or `--apply`: the download consent; doc-search's first index build runs last (refused, exit 1 and nothing written, on a host without `uv`, or when `docs/search/config.json` holds gte and this host cannot run it). With `--dry-run`: the review includes it |
| `--set <id>=<value>` | Changes one item (*Items*); repeatable; `--set=<id>=<value>` too |
| `--list` | Every item, one line each (*Items*) |
| `--for-team` | With `--yes` or `--dry-run`: the per-user values this run sets are the team's, written to the team record |
| `--link-bin` | Ticks the terminal command (`--set bin=on`), with any mode, `--apply` included |
| `--no-link-bin` | Unticks it: setup removes its own shim, never a file of yours. Not with `--link-bin` (exit 3) |
| `--plain` | The prompts instead of the TUI, on a terminal too |

`--list`, `--dry-run`, `--yes` and `--apply` are modes: one at a time, except `--apply --dry-run`.

The review prints its sections in this order, each header on its own line and `  (nothing)` under an empty one: `Steps:` (numbered, each with the command it runs), `Committed for the team:`, `Local to you:`, `Local to you (outside the repository):`, `Network:`, `Downloads:`, `Then commit:` (one `git add -- <paths…>` line). A team path that git ignores (and does not track) would never ship, since `git add` refuses it: the review and the run each add one line per such path after the `git add` line, `warning: <path> is ignored by git: commit it with git add -f, or un-ignore it`. A run (`--yes`, `--apply`, the UIs) prints each step as `<n>. <the review's text>` before it runs it, the installer's own output after it, then `Then commit:`.

| Exit | Meaning |
|---|---|
| `0` | Done, or `nothing to do` (a quit in the UIs too) |
| `1` | Refused, nothing written: outside a git work tree, no `jq`, an unreadable `scripts/setup/catalog.json`, a disabled item forced with `--set`, `--build` on a host without `uv` or with a config holding gte where gte cannot run, the env hook without `HOME` (and no `XDG_CONFIG_HOME` or `DOC_SEARCH_ENV_FILE`), a locked item (the ledger, spec claims) turned off, `--apply` without a team record, a file setup will not change (a symbolic link on the way, a file that is not the expected shape, an entry of yours), a record `state.sh` refuses (its reason), the merge driver changed without `--for-team`. One line says why |
| `2` | A step failed: `setup: step <n> (<op>) failed; done: <ops>; re-run to finish`. Each step is idempotent: a re-run finishes the job |
| `3` | Usage: an unknown flag, two modes, a flag the mode does not take, a `--set` with an unknown id or a value the item does not take |

## The records

**The team's: `.claude/doc-superpowers/installed.json`** (committed). setup adds a top-level `setup` object to the installer's state file:

```json
{
  "schema_version": 2,
  "setup": {
    "format": 1,
    "harnesses": ["claude-code"],
    "git": "hooks",
    "claude": true,
    "search": null,
    "ledger": null,
    "claims": false
  }
}
```

- `git` is `hooks`, `merge-driver` or `off`; `search` is `null` or `{"model": "static" | "transformer:gte-modernbert-base"}`; `ledger` is `null` or `{"git": bool, "claude": bool}`. CI stays in `.tiers.ci`, which `install --ci` writes with the choices setup passes it.
- No timestamps and no versions: they would churn on every run.
- `schema_version` stays 2, so a 3.8.0 installer still reads the file (it refuses anything above 2) and keeps `setup` (its writes keep unknown top-level keys). `setup.format` versions the object on its own.
- `setup.git` and `setup.claude` are the team's *choice*, which `--apply` installs for each contributor. The tiers' *state* stays per clone (`.git`) and per user (`.claude/settings.local.json`).
- Written last, after the installer's steps, merged into the current file with jq (a temp file beside it, then `mv`, never through a symbolic link), and only when its content changes. `--apply` never writes it.
- A CI-only record (`.tiers.ci`, no `setup`) is read as it is: its workflows pre-tick the CI group, and the first write adds `setup`. A file the installer refuses (corrupt, from a newer installer) makes setup refuse too, with the installer's reason.

**Yours: `.claude/doc-superpowers/installed.local.json`** (untracked):

```json
{ "format": 1, "overrides": { "claude": false }, "search": { "cache": null } }
```

- `overrides` holds your departures from the team's per-user choices (`git`, `claude`, `ledger.git`, `ledger.claude`); `search.cache` is `null` (the host default) or an absolute path. It never holds anything another contributor needs.
- It is kept out of git by setup's own block in git's `info/exclude`, `# doc-superpowers setup:begin` … `# doc-superpowers setup:end`, not the Claude tier's (`install --claude` rewrites that block and `uninstall --claude` removes it), so it stays excluded after `uninstall --claude`.

## The env hook

doc-search's cache path and `DOC_SUPERPOWERS_ROOT` reach the server through the launcher's per-user env hook, `${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-~/.config}/doc-search/env.sh}` (`references/search.md`). setup owns one marked block there:

```sh
# doc-superpowers setup:begin (managed; edit with doc-superpowers setup)
export SEMBLE_CACHE_LOCATION='/abs/path/semble'
export DOC_SEARCH_CACHE_LOCATION='/abs/path/doc-search'
export DOC_SUPERPOWERS_ROOT='/abs/path/to/clone'
# doc-superpowers setup:end
```

- Written only with doc-search on. The cache lines come from `search.cache` set to a path (and go when it is set back to `host`); `DOC_SUPERPOWERS_ROOT` is written only when setup runs from a clone, outside the plugin cache (`${CLAUDE_PLUGIN_CACHE:-~/.claude/plugins/cache}`): a clone install is what a non-Claude harness uses, and otherwise the launcher finds the plugin cache itself.
- It is per user and per host, not per repository: a cache path chosen in one repository applies to every repository on this host (the cache is keyed by path, so sharing it is safe). setup changes it per variable: a value this run does not set keeps the line already there, so another repository's cache path stays.
- The rest of the file is yours and kept byte for byte. The values are `sh`-quoted, and the result must pass `sh -n` before it is moved into place. A block left with no line is removed, and the file with it when it held nothing else.

## Harness entries

Written only with doc-search on, one per ticked harness, merged into the project file; without doc-search nothing is written, and the review points each newly ticked client to its INSTALL guide (`.codex/INSTALL.md`, `.cursor-plugin/INSTALL.md`, `.opencode/INSTALL.md`, `GEMINI.md`). The entries are the ones `references/search.md` → *Other clients* shows, with what was verified for each client.

| Harness | File | Entry |
|---|---|---|
| `claude-code` | `.mcp.json` | `install --search`'s (the installer's own) |
| `codex` | `.codex/config.toml` | setup's marked block (`# doc-superpowers setup:begin doc-search` … `:end doc-search`): `[mcp_servers.doc-search]`, `sh -c 'cd "$(git rev-parse --show-toplevel)" && exec sh .claude/doc-superpowers/search-mcp.sh serve'`, `startup_timeout_sec = 60`. Codex loads it only for a trusted project |
| `cursor` | `.cursor/mcp.json` | `sh -c 'cd "$1" && exec …' sh ${workspaceFolder}` (unverified: no CLI to check it with) |
| `opencode` | `opencode.json` | the same `cd` to the repository top, then the launcher; `timeout` 60000. A new file gets `$schema` |
| `gemini` | `.gemini/settings.json` | `sh .claude/doc-superpowers/search-mcp.sh serve`. Start Gemini CLI from the repository top, in a trusted folder |

Codex and OpenCode start a server in the directory they were launched from, so their entries change to the repository top first. For OpenCode, starting from a subdirectory was verified; for Codex only *loaded* was (from the top and a subdirectory) — that its server starts from one is unverified.

**What is setup's.** Only an entry exactly as setup writes it (a JSON `doc-search` entry) or setup's marked Codex block. An entry that differs is yours: setup leaves it alone, and ticking that harness is refused (exit 1) naming the file and key. setup removes an entry only when you untick its harness or turn doc-search off in that run, and then removes only the `doc-search` key or its block, never the file, its directory or the server table, even when setup created them.

**Refused untouched** (exit 1, before any step runs): a JSON file that is not one object (comments included) or whose server table is not an object; in `.codex/config.toml`, a `doc-search` definition outside setup's block (a `[mcp_servers.doc-search]` table, a dotted key, an inline `mcp_servers = {…}`), markers that do not form one block, or removing the block while a table of yours outside it extends it (`[mcp_servers.doc-search.env]`). Every other byte of a file setup edits stays (JSON in jq's layout).

## The terminal command

A plugin install puts nothing on the terminal's `PATH`. The `bin` item (unticked by default; `--link-bin` / `--no-link-bin`) writes `~/.local/bin/doc-superpowers`, a small POSIX `sh` script (mode 755), not a link: a plugin update replaces the versioned plugin directory, so the script finds doc-superpowers each time it runs, in this order:
1. `$DOC_SUPERPOWERS_ROOT`;
2. the clone setup ran from, written into the script when setup ran from a clone (empty for a plugin install);
3. the newest numeric `X.Y.Z` directory under `${CLAUDE_PLUGIN_CACHE:-~/.claude/plugins/cache}/*/doc-superpowers/`.

It then runs `scripts/doc-superpowers` under the `bash` on `PATH`; with no candidate it prints one line and exits 2.

- Its second line is the marker `# doc-superpowers terminal shim v1`: a file there without it is yours, never replaced or removed (the item is disabled, with the reason), and so is a symbolic link.
- When `~/.local/bin` is not on `PATH`, setup prints the line to add (`export PATH="$HOME/.local/bin:$PATH"`). It never edits a shell profile.
- An existing shim of setup's counts as in place whatever it holds: it is never refreshed, so a shim written from a clone keeps that clone's path, which a later plugin install does not change. To re-render it, run `doc-superpowers setup --yes --no-link-bin`, then `--yes --link-bin` (`--no-link-bin`, then `--link-bin`).

## Help

`doc-superpowers help` (or `-h`, `--help`, or no command) prints the overview: every feature and command on one line each, with the topic or reference that has the rest. `doc-superpowers help <topic>` prints one topic: `setup`, `search`, `hooks`, `ci`, `ledger`, `claims`, `release`. Each topic says what the feature is, whether it is on by default, its terminal commands and skill actions, what it commits and what stays local, how to undo it, and its reference.

- The text is `scripts/help/<topic>.txt` (`overview.txt` for the overview), printed as it is: one source for the terminal and the skill. The skill's `help` action runs `"$ROOT/scripts/doc-superpowers" help [topic]` and shows the output verbatim, in a code block, never paraphrased.
- Limits (pinned by tests): the overview is at most 24 lines, a topic at most 50, every line at most 80 columns, plain text with no ANSI escapes.
- An unknown topic, or more than one, prints the topic list on stderr and exits 3. An unknown command exits 3 too, pointing to `doc-superpowers help`.

The dispatcher's other commands, so that every command `help` names runs from a terminal: `doc-superpowers version` (the plugin's version, `doc-tools.sh tools version`), `doc-superpowers hooks …` (`install.sh …`), `doc-superpowers tools …` (`doc-tools.sh …`) and `doc-superpowers search …` (doc-search's CLI, through the repository's committed launcher when it has one). `version`, `hooks` and `tools` run under the interpreter that runs the dispatcher; `search` runs the launcher under `sh`. Each exits with the sub-command's status.

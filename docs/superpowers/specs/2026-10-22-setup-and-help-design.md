# `setup` and `help` — design

**Status:** Draft, awaiting owner approval (revised after a second review, §14)
**Issue:** #51 (phase 1 of the roadmap tracker #54)
**Target release:** 3.9.0 (the next minor)

#51 records the owner's decisions. This document does not reopen them. It turns them into a buildable design and settles #51's four open questions (§9). Calls marked **[builder's call]** were made while writing this document, not by the owner. They are collected in §12 so they can be checked.

---

## 1. Intent

Turning doc-superpowers on in a repository takes several installer commands today, each with its own flags and reference. Nothing tells a new user what exists, which pieces are safe and which are opt-in, or what a choice writes and commits. A team has no record that the next contributor can replay.

`setup` is one guided entry point with fixed safe defaults. `help` is a one-screen map of every feature. Both are available from the skill and from a terminal, and print the same text in both.

**The design rule (#54):** the core is the safest, most minimal choice, suitable for corporate repositories:
- Nothing is written to a repository until someone runs `setup` there.
- The defaults block nothing, download nothing, call no network and add no CI.
- Everything else is opt-in, and every opt-in is shown with what it writes and how to undo it.

## 2. Goals, non-goals, anti-goals

**Goals**
- `setup`: interactive (a TUI, with a plain-prompt fallback), plus `--apply`, `--dry-run` and `--yes`. Idempotent: re-running it is always safe.
- `help`, `-h`, `--help` and `help <topic>`, with identical text from `/doc-superpowers help` and the `doc-superpowers` terminal command.
- One record of the team's choices (committed) and one of each user's (untracked).
- Tests under bash 5.x and `/bin/bash` 3.2 that prove a default `setup` downloads nothing, calls no network, adds no CI and blocks no commit.

**Non-goals**
- Routines or anything scheduled (#53).
- New CI templates. Changes to what any existing tier installs: `setup` orchestrates `scripts/hooks/install.sh`. It never duplicates or alters the installer.
- Running `ledger init`'s bootstrap, or configuring spec-claims adapters. `setup` turns these features on, and `help` points to the full flows.
- Committing anything. `setup` writes files and prints the `git add` line. Committing them is the user's call.

**Anti-goals** (each would be a failure even if everything else worked):
- A default that differs by repository or host, or a hint that changes a default.
- Any download or network call without explicit consent on the review screen.
- A per-user choice (a cache path, a machine path) written into a committed file.
- A second copy of the installer's logic, or a second copy of the help text.

## 3. Constraints

- **Runtime:** bash 3.2 + `jq` ≥ 1.6 + git. No Python, node or other dependency for `setup` or `help`. doc-search's own Python is only needed for a build, and only after consent.
- **Portability:** no bash-4-only constructs (`test-doc-tools.sh`'s static guard covers the new scripts) and no jq-1.7-only forms. Shellcheck at warning severity.
- **Tests:** in the existing suites, no new suite (§10). Every run is isolated like the rest of the harness.
- **Public text** names no private repository or host. The leak scan covers the new files.
- Versions are changed only by `bump-version`. The doc-index is kept current.

## 4. Entry points

### 4.1 `scripts/doc-superpowers` (new)

A bash dispatcher in `scripts/`, beside `doc-tools.sh`. It is not in a top-level `bin/`: claude.ai and Cowork do not install a plugin that has a `bin/` directory (§9.3).

| Command | Does |
|---|---|
| `doc-superpowers help` · `-h` · `--help` | Prints the overview (§7) |
| `doc-superpowers help <topic>` | Prints one topic: `setup`, `search`, `hooks`, `ci`, `ledger`, `claims`, `release` |
| `doc-superpowers setup [flags]` | The wizard (§5) |
| `doc-superpowers version` | The plugin's version: `doc-tools.sh tools version`, the reader `install.sh` uses |
| `doc-superpowers hooks …` · `tools …` · `search …` | Pass-throughs to `install.sh`, `doc-tools.sh` and doc-search's launcher. They exist so that every command named in `help` runs from a terminal **[builder's call]** |

Every client, Claude Code included, runs it as `"$ROOT/scripts/doc-superpowers"`, through the `$ROOT` that *Detect Bundled Tooling* already resolves. There is one invocation form and no dependency on `PATH`. The dispatcher runs every sub-script with `"$BASH"` (as `install.sh` runs `doc-tools.sh`), never a bare `bash`, so the interpreter a test chose is the one that runs.

### 4.2 The terminal command (`~/.local/bin`)

A plugin install puts nothing on the terminal's `PATH` (§9.3). `setup` offers it as an item: **Terminal command** (local to you, unticked by default, asked before writing). When ticked, setup writes `~/.local/bin/doc-superpowers`.

That file is a small POSIX-sh shim, not a symlink **[builder's call]**. Plugin-cache directories are versioned and an update removes the old one, so a symlink would dangle after an upgrade. The shim resolves the root at run time, in the launcher's order:
1. `$DOC_SUPERPOWERS_ROOT`;
2. the clone path baked in when setup ran from a clone;
3. the newest `X.Y.Z` under the plugin cache.

It then `exec`s `bash "$ROOT/scripts/doc-superpowers"`. A terminal has no interpreter to keep, so `bash` from `PATH` is right here.

- An existing `~/.local/bin/doc-superpowers` that is not this shim is refused, with the reason.
- When `~/.local/bin` is not on `PATH`, setup prints the line to add. It never edits a shell profile.
- A clone install is linked the same way, with step 2 baked in.

### 4.3 The skill

Two new actions in `SKILL.md`'s routing: `setup` and `help`. Both skip discovery but run *Detect Bundled Tooling*, as `hooks` does. Both have a REQUIRED pointer to a new `references/setup.md`.

- **`help [topic]`** runs `"$ROOT/scripts/doc-superpowers" help [topic]` and shows its output **verbatim**, in a code block. The skill never paraphrases it, which is what keeps the two identical.
- **`setup`** cannot drive a TUI: the Bash tool has no TTY. It drives the same engine through flags, with the same screens:
  1. `"$ROOT/scripts/doc-superpowers" setup --dry-run` prints the summary and review. Show them verbatim.
  2. Ask one question: *Apply these* / *Customize* / *Cancel*.
  3. Customize: `setup --list` prints every item, with its id, value, scope and any disabled reason. Ask one question round per group the user wants to change. Then `setup --dry-run --set id=value …` prints the new review.
  4. Ask: *Write and build* / *Write only* / *Back*. *Write and build* needs a second, explicit yes to the download line the review printed. When a per-user item differs from the record, ask *for you only* / *for the team* too (§5.2).
  5. Run `setup --yes --set … [--for-team] [--build] [--link-bin]`. Run a build in the background: a gte first build can take hours.
  6. Show what was written and the `git add` line.

  The skill also tells the user that `doc-superpowers setup` in a terminal is the full-screen version.

## 5. The `setup` engine

`scripts/setup/setup.sh` (bash 3.2), `doc-superpowers setup`'s target. It is split in layers, so that most of it is tested without a terminal:

1. **Catalog**: `scripts/setup/catalog.json`, read once by jq into bash indexed arrays. One entry per item:
   - `id`, `group`, `label`;
   - `scope`: `team` or `local`;
   - `kind`: `toggle`, `choice` or `value`, with its `options`;
   - the fixed default;
   - `details` (the pane text), `writes` (paths), `undo` (a command);
   - `requires` (other ids).
2. **Probe** (read-only): the scan hints and the host checks (§5.4), plus the current state:
   - `install.sh status --json --git --claude --ci --search`. All four tiers must be named: `--search` alone reports only doc-search. A record that `state.sh` cannot use shows here as `tiers.ci.state_readable: false` with `state_error` (the command still exits 0), which is how setup learns to refuse with the installer's own reason (§6.1);
   - the record files (§6);
   - the config files that switch features on.
3. **Model**: the selection, starting from the *base* (§5.2), plus the user's changes. These are pure functions: toggle, set and a `requires` closure. The `(changed)` marks are the selection against the base.
4. **Plan**: the selection against the **probed state** (what `status --json` and the files on disk say), never against the base. An item already in place, current and not `outdated` is no action, and an `outdated` one is a refresh. So `--apply` in a fresh clone, where the selection equals the record but nothing per-user is installed, plans the per-user installs; a re-run with nothing to change plans nothing (*nothing to do*); and an upgrade plans the refreshes. The plan is an ordered list of actions. Each action says what it writes (path, `team`|`local`), whether it downloads, and the command it runs. `--dry-run` prints this plan as the review screen.
5. **UI**: the TUI (§5.5), the prompt fallback (§5.6), or nothing (`--yes`, `--apply`).
6. **Executor**: runs the plan, stopping at the first failure. Then it writes the records (§6) and prints the summary of what was written and the `git add` line.

### 5.1 Groups and items

Items in **bold** are ticked by the fixed defaults. Everything else starts unticked.

| Group | Items | Scope | Maps to |
|---|---|---|---|
| **Harness** | **Claude Code**; Codex; Cursor; OpenCode; Gemini CLI | team | With doc-search on: that harness's MCP entry (§8). Always: its skill install steps, printed as pointers to the INSTALL guides |
| doc-search | on/off; model: **static** \| gte; cache: **host default** \| a path | team (on, model), local (cache) | `docs/search/config.json`, written by setup itself with jq (`{}`, or `{"docs": {"model": "transformer:gte-modernbert-base"}}`), never through `doc-search init`, which runs `uv`; then `install --search`, the per-harness entries, the env hook (cache path, `DOC_SUPERPOWERS_ROOT`) |
| Git hooks | **mode: hooks + merge driver** \| merge driver only \| off. Its children list the 5 hooks and the driver, read-only, each with its details | merge driver: team (`.gitattributes`) + local (git config); hooks: local | `install --git` / `install --git --merge-driver-only` |
| Claude hooks | **on** (3 hooks) | local | `install --claude` |
| CI workflows | the 9 workflows, each a toggle, with its consent row in the details pane; base branch, cron and strict as values | team | `install --ci --workflows=… --base-branch … --cron … --ci-strict=…` |
| Work ledger | on/off; ledger git hooks; ledger Claude hooks | team (on); local (the hook sets) | `docs/ledger/config.json` = `{}`; `install --ledger`, `install --ledger-claude`; `help ledger` points to `ledger init` |
| Spec claims | on/off | team | `docs/spec-claims/config.json` = `{"schema": 1}`; `help claims` points to the adapters |
| Terminal command | the `~/.local/bin` shim | local, outside the repository | §4.2 |

The git tier is shown as three modes, not five hook toggles. The installer installs the tier as a whole, and #51 rules out changing what a tier installs **[builder's call]**. The per-hook children are shown so that the details pane explains each hook.

The details pane says when an opt-in item can block a commit:
- the spec-claims pre-commit leg (a finding blocks whatever STRICT says);
- the ledger pre-commit set;
- `--ci-strict`.

### 5.2 The base selection

- **No record** (§6) and nothing installed: the fixed defaults. These are the merge driver, the 5 report-only git hooks, the 3 Claude hooks and Claude Code as the harness. There is no doc-search, CI, ledger, claims or terminal command.
- **No record, but something is already installed** (an earlier `hooks install`, a `docs/search/config.json`, workflows): the defaults ∪ what is installed **[builder's call]**. Current state is not a hint. Unticking an installed item removes it, so a default run must never remove anything. The summary marks those items "already installed".
- **A record**: the record (team part, then the user's local overrides). This is what makes re-runs idempotent and lets `--apply` reproduce the team's setup.

A scan hint never changes the base. A host check can only disable an item, and a disabled item that the base ticks is shown unticked, with the reason.

**Per-user items after the first record** **[builder's call]**. Some items are per-user: the git hooks part of Git hooks, Claude hooks and the ledger hook sets. The first record a repository gets stores the selection of these as the team's choice. After that, changing one of them changes only the user's `overrides` (§6.2). The details pane shows both values (`Team: on · You: off`). When a per-user item differs from the record, the review asks once: *Save these for: you only / the team*, defaulting to *you only*. *The team* writes them into the record, and the review then lists `installed.json` under *Committed for the team*. Non-interactively, `--set` is for you only, and `--for-team` makes the per-user `--set` values the team's.

**Unticking** **[builder's call]**. setup never deletes team content it did not just create:
- An installer-managed item is removed by its own `install.sh uninstall` command. This covers the git and Claude tiers, CI workflows, the ledger hook sets, `--search` (the launcher and the `.mcp.json` entry) and the other harnesses' doc-search entries, which setup removes from their marked block or key.
- `docs/search/config.json`, `docs/ledger/config.json` and `docs/spec-claims/` are left in place. The review says so, and how to remove them by hand.
- Spec claims and the ledger cannot be turned off by setup while their directory or config exists, since that switch is the team's data. Their item is shown ticked and locked, and the details pane shows the manual step.

### 5.3 Flags

| Flag | Effect |
|---|---|
| (none) | Interactive: the TUI on a TTY, else the prompt fallback |
| `--dry-run` | Prints the summary and the review for the selection, then exits 0. Writes nothing |
| `--yes` | Non-interactive. Applies the selection: base + `--set`. *Write only* unless `--build` |
| `--apply` | Non-interactive. Reproduces the **recorded** team setup: it installs the per-user parts and re-writes any missing team files. It never changes the team record. Exits 1 with one line when there is no record (`no team setup recorded: run doc-superpowers setup`), and so does a v2 record that holds only `tiers.ci` (no `setup` key). Its output lists any write outside the repository (the env hook, §6.3) under *Local to you (outside the repository)*. An item this host's checks disable is skipped with its reason, the rest is applied, and the run exits 0 with the skipped items listed last **[builder's call]**: the teammate did not choose the record, so one unusable item must not block the safe rest |
| `--build` | With `--yes` or `--apply`: *Write and build*. This flag is the download consent in non-interactive use **[builder's call]**. Without it, nothing downloads |
| `--set <id>=<value>` | Repeatable. Changes one item: `search=on`, `search.model=gte`, `harness=claude-code,codex`, `ci.workflows=doc-freshness-pr`, `git=merge-driver`, … |
| `--list` | Prints the catalog with the current selection, scopes and disabled reasons. Used by the skill |
| `--link-bin` · `--no-link-bin` | The terminal-command item, non-interactively |
| `--plain` | Forces the prompt fallback on a TTY |

Exit codes:
- `0`: done, or nothing to do.
- `1`: refused. Examples: a disabled item was forced with `--set`, `--apply` found no record, or a file is not ours to change. Nothing is written.
- `2`: a step failed. The executor stops and reports which steps ran. Each step is idempotent, so re-running finishes the job.
- `3`: usage.

### 5.4 Scan hints and host checks

**Hints** (shown, never applied):
- The docs-corpus count, using the default `docs.include` against `git ls-files`.
- A gte first-build estimate, from the corpus size (≈ 750 characters per chunk) and the per-host rates `references/search.md` gives: ≈ 16 chunks/s on arm64 macOS and ≈ 3.6 chunks/s on Intel macOS. No estimate elsewhere.
- Harnesses detected: `.cursor/`, `.codex/`, `.gemini/`, `opencode.json`, `AGENTS.md`.
- No doc index yet: run `/doc-superpowers init`.
- A GitHub remote, or none (a hint on CI).
- `docs/spec-claims/` already present, so its blocking pre-commit leg is already the repository's choice.

**Host checks** (each disables an item and says why):

| Check | Disables |
|---|---|
| No `uv` | doc-search's **build** ("uv not found"). The item itself stays: the owner's decision lets a team write and commit the entries without a build (§5.5) |
| arm64 macOS below 14 | the gte model (onnxruntime 1.31 needs macOS 14) |
| A non-macOS, non-Linux host | the gte model |
| A `core.hooksPath` in global or system git config | Git hooks' *hooks* mode (the installer refuses it). The merge-driver-only mode stays |
| A repository-local `core.hooksPath` inside the work tree (Husky's `.husky/`, say) | Git hooks' *hooks* mode **[builder's call]**. `install --git` would write four whole hooks and `.doc-superpowers-pre-commit` into the tracked folder and integrate into the hook runner's own `pre-commit`, and the rendered hooks carry this machine's plugin path. They would be committed, machine-specific files, no longer local or certainly report-only. The details pane says exactly that. The merge-driver-only mode stays |
| `~/.local/bin` not writable | Terminal command |
| An existing non-shim `~/.local/bin/doc-superpowers` | Terminal command |

A check that cannot decide does not disable the item.

### 5.5 The TUI (bash 3.2)

The flow is the one the owner approved (mockup *wizard-flow-c-to-b*). Nothing is written before the last screen.

1. **Summary**: one line per group, showing the selection. Changed lines are marked `(changed)`, installed ones `(already installed)`. Actions: *Apply these* → Review · *Customize…* → Tree · *Show what each does* (pages `help setup`) · *Cancel*.
2. **Tree + details pane**: groups collapsible, pre-ticked from the summary. The details pane on the right shows the highlighted item's text, its scope (*committed for the team* / *local to you*), how to undo it and any disabled reason. Below 80 columns the pane goes under the tree.
3. **Esc**: back to the summary, with the changes marked.
4. **Review**: the plan, split into **Committed for the team** and **Local to you**, then the downloads (sizes and an estimate). Actions: *Write and build* (only when something builds) · *Write only* · *Back*. *Write and build* asks once more: `This downloads <what>. Continue? [y/N]`.

   **Network.** The review lists every ticked item that can reach a remote, not only downloads. Examples: the ledger git set's post-commit leg pushes in-flight refs when `inflight.enabled` is on (off in the `{}` config setup writes); `keys.mode cas` fetches and pushes the counter ref; the CI workflows run on GitHub. The default selection has none.

   **Downloads and doc-search (owner's decision, 2026-10-22).** With doc-search on, the static model and gte both count as a build: either way the first run fetches the Python packages and semble's model, and gte adds about 150 MB more. *Write only* still writes and commits the harness entries. The review warns, in its own block, that each contributor's client downloads these on its first start of the server, after that client's own approval prompt (Claude Code's project-server approval, Codex's trust prompt). That prompt is each contributor's consent. setup itself downloads only on *Write and build*, or with `--build`.

Keys:

| Key | Action |
|---|---|
| ↑ ↓ / k j | Move |
| space | Toggle |
| → / enter | Open a group, or choose an option |
| ← | Close a group |
| e | Edit a value (cooked-mode line read) |
| Esc / b | Back |
| ? | The item's help |
| q | Quit without writing |

**Implementation** (all bash 3.2):
- A reducer, `ui_key <key>`, changes the UI state: screen, cursor, open groups and the model. A renderer, `ui_render`, prints the whole frame from that state.
- The frame is a full redraw on the alternate screen (`\033[?1049h`), with the cursor hidden. The size is `COLUMNS` / `LINES` when they are set (the tests rely on this), else `tput cols` / `tput lines`. Whether to draw at all is decided on `TERM`, never on `tput`'s exit code: `TERM=dumb tput cols` succeeds. Colour is used only when `TERM` is not `dumb` and `NO_COLOR` is unset.
- Keys are read with `IFS= read -rsn1`. After an ESC, a `read -rsn1 -t 1` tells an arrow (`[` or `O` follows) from a bare Esc. Any other byte is replayed as the next key. bash 3.2's `read -t` takes whole seconds only (`read -t 0.5` is an invalid timeout there). On a real TTY, `stty -icanon min 0 time 1` makes that second read return after 100 ms, so a bare Esc is quick. On a pipe it falls back to the 1 s wait, and `b` is always instant.
- `stty` state is saved and restored, and the alternate screen and cursor are reset, on EXIT, INT, TERM and HUP.

**Testability:** the key reader reads stdin whether or not it is a TTY. It touches `stty` only on a TTY. A test sets `DOC_SP_SETUP_UI=tui` (internal, documented as test-only) and pipes bytes in: arrows, spaces, Esc, `q`. It then asserts on the frames, with `NO_COLOR=1` and a fixed `COLUMNS`/`LINES`, and on what was written. The reducer and renderer run the same code a user runs. Only the `stty`/alternate-screen calls are skipped.

### 5.6 The prompt fallback

Used when stdin or stdout is not a TTY, when `TERM=dumb`, or with `--plain`. These are numbered line prompts over the same model:
- the summary, then `[a]pply  [c]ustomize  [s]how details  [q]uit`;
- Customize lists the groups, then a group's items as `n) [x] label — scope`. Typing a number toggles that item or asks for its value; `d n` shows its details; an empty line goes back;
- the review, then `[w]rite and build  [o] write only  [b]ack`.

End of input is *quit, nothing written*. This is also what the tests drive with piped answers.

## 6. The record

### 6.1 Team: `.claude/doc-superpowers/installed.json` (committed)

The file keeps `schema_version: 2`. setup adds a top-level `setup` object **[builder's call]**:

```json
{
  "schema_version": 2,
  "tiers": { "ci": { "…": "unchanged: the CI tier's record, written by install.sh as today" } },
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

The fields:
- `git` is `hooks`, `merge-driver` or `off`.
- `search` is `null` or `{"model": "static" | "transformer:gte-modernbert-base"}`.
- `ledger` is `null` or `{"git": bool, "claude": bool}`.
- CI stays in `tiers.ci`, which `install --ci` writes. setup passes it the selected flags.
- There are no timestamps and no versions: they would churn on every run, and a churning committed file was the old merge-conflict source.

**Why not `schema_version: 3`.** 3.8.0's `state.sh` refuses any file whose `schema_version` is above 2 ("written by a newer installer"). Bumping it would break `install --ci` for every teammate still on 3.8.0. The `setup` key is additive instead. `state.sh` validates only `.tiers.ci`, and its write filter keeps unknown top-level keys, so 3.8.0 reads the file and preserves `setup`. A test pins this. `setup.format` versions the new object on its own.

**Per-user tiers in a team record.** `state.sh` says a committed record of the git or Claude tier "would be wrong for every other contributor". That is still true of their *state*, which stays in `.git` and `settings.local.json`. `setup.git` and `setup.claude` are the team's *choice*, which `--apply` installs for each contributor. A user can override that choice locally (§6.2). The comment in `state.sh` is updated to say this.

**Migration.** A v2 CI-only record (this repository's own, for one) is read as it is: its workflows pre-tick the CI group. The first setup write adds `setup`. A version 1 file is migrated by `install.sh` as today, because setup runs the installer before it writes its record. A file `state.sh` refuses (corrupt, newer) makes setup refuse too, with the same reason, read from the probe's `tiers.ci.state_error`.

**Writes:** setup writes `setup` last, after the installer steps. It merges into the current file (jq), using a temp file plus `mv` beside it, and never through a symlink. It writes only when the content changed.

### 6.2 User: `.claude/doc-superpowers/installed.local.json` (untracked)

The file is excluded through git's `info/exclude`, in **setup's own** marked block: `# doc-superpowers setup:begin` … `# doc-superpowers setup:end`. It is not the Claude tier's block. `install --claude` rewrites that block whole and `uninstall --claude` removes it, so a line setup put there would be dropped, and after an uninstall `installed.local.json` would end up in a `git add -A`. setup's markers must not begin with `# doc-superpowers:begin` / `:end`, which the installer's block editor matches. A test pins that `uninstall --claude` leaves the file excluded.

```json
{ "format": 1, "overrides": { "claude": false }, "search": { "cache": "/abs/path" } }
```

- `overrides` holds per-user departures from the team's per-user choices (`git`, `claude`, the ledger hook sets).
- `search.cache` is `null` (the host default) or an absolute path.

The file never holds anything another contributor needs.

### 6.3 The env hook

The cache path and `DOC_SUPERPOWERS_ROOT` reach the server through the launcher's per-user env hook: `${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-~/.config}/doc-search/env.sh}`. setup owns a marked block there:

```sh
# doc-superpowers setup:begin (managed; edit with doc-superpowers setup)
export SEMBLE_CACHE_LOCATION='/abs/path/semble'
export DOC_SEARCH_CACHE_LOCATION='/abs/path/doc-search'
export DOC_SUPERPOWERS_ROOT='/abs/path/to/clone'
# doc-superpowers setup:end
```

- The rest of the file is the user's and is kept.
- The values are `sh`-quoted, and the result must pass `sh -n` before it is moved into place.
- `DOC_SUPERPOWERS_ROOT` is written only when setup runs from outside the plugin cache, that is, from a clone. A clone install is what a non-Claude harness uses. Otherwise the launcher already finds the plugin cache, whatever harness starts it.

The env hook is per user and per host, not per repository. A cache path chosen in one repository applies to every repository on the host. The details pane and the review say so **[builder's call]**. The cache is keyed by path inside semble, so sharing it is safe.

## 7. `help`

- The text lives in `scripts/help/<topic>.txt`: `overview`, `setup`, `search`, `hooks`, `ci`, `ledger`, `claims`, `release`. Plain text, no ANSI.
- `doc-superpowers help [topic]` `cat`s it. The skill runs that command and shows the output verbatim. There is one source and no second copy.
- **Limits** (pinned by a test): the overview is ≤ 24 lines and every topic ≤ 50 lines **[builder's call]**, all ≤ 80 columns.
- **The overview** lists every feature and command on one line each, each pointing to `help <topic>` or a reference file. It includes `init`, `audit`, `review-pr`, `update`, `diagram`, `sync`, `release`, the `spec-*` actions, `ledger`, `hooks`, `setup` and `help`.
- **A topic** gives what the feature is, whether it is on by default, its terminal commands and skill actions, what it writes, how to undo it, and the reference file for the rest.
- An unknown topic prints the overview's topic list to stderr and exits 3.

## 8. Harness entries

These are written only when doc-search is on, one per ticked harness, by merging into the project file. The rest of the file is kept, and a file that is not the expected shape is refused.

| Harness | File | Entry | Verified |
|---|---|---|---|
| Claude Code | `.mcp.json` | via `install --search` (unchanged) | yes (shipped) |
| Codex | `.codex/config.toml` | a marked block: `[mcp_servers.doc-search]`, `command = "sh"`, `args = ["-c", "cd \"$(git rev-parse --show-toplevel)\" && exec sh .claude/doc-superpowers/search-mcp.sh serve"]`, `startup_timeout_sec = 60` | loaded: yes (§9.4) |
| Cursor | `.cursor/mcp.json` | as `references/search.md` gives it | no (no CLI to check it with) |
| Gemini CLI | `.gemini/settings.json` | as `references/search.md` gives it | to verify while building |
| OpenCode | `opencode.json` | as `references/search.md` gives it | to verify while building |

- The JSON files are merged with jq.
- TOML has no jq. The Codex entry is a marked block. An unmarked `[mcp_servers.doc-search]` table already in the file is refused (TOML forbids a duplicate table), and so is a file setup cannot parse at all.
- Codex loads project config only for a **trusted** project. The details pane and the printed steps say so.
- Any entry still unverified at release says *unverified* in its details pane, as `references/search.md` does.

## 9. The open questions, settled

### 9.1 A TUI in portable bash

§5.5 covers it:
- a reducer and renderer over bash indexed arrays;
- a key reader that works on pipes;
- `stty` touched only on a real TTY;
- a 1 s Esc disambiguation (bash 3.2 has no fractional `read -t`).

The prompt fallback (§5.6) shares the model, so both UIs produce the same plan by construction. The tests drive both through pipes, under each interpreter `check-ci.sh` runs (§10).

### 9.2 The `installed.json` schema and migration

§6.1: an additive `setup` object at `schema_version` 2, so 3.8.0 installers keep working, with its own `format`. A v2 CI-only record pre-ticks CI and gains `setup` on the first write.

### 9.3 Can a plugin put a command on `PATH`?

**Not usefully.** Claude Code adds a plugin's top-level `bin/` to the **Bash tool's** `PATH` while the plugin is enabled (code.claude.com plugin docs, *Standard layout → Executables*). Nothing reaches the user's terminal, and no install hook writes to `~/.local/bin` or a shell profile. The same page says claude.ai and Cowork do not install a plugin that has a `bin/` directory, so shipping one would cost those installs.

So:
- ship the dispatcher as `scripts/doc-superpowers`, with no `bin/`;
- keep the asked-first `~/.local/bin` shim for the terminal (§4.2);
- every client, Claude Code included, calls `"$ROOT/scripts/doc-superpowers"`.

### 9.4 A committed `.codex/config.toml`

Checked on 2026-10-22 with codex-cli 0.163.0 installed into a scratch folder, with a temporary `CODEX_HOME` and no model call.

What was run, and what it showed:
- An untrusted repository: `codex mcp list` shows nothing.
- The same repository marked `trust_level = "trusted"`: it shows the project's `doc-search` server, run from the repository top or a subdirectory.

What the Codex source says (`stdio_server_launcher.rs`):
- A server starts in Codex's launch directory, not the project root.
- Relative paths resolve from there.

So `references/search.md`'s "servers start in the project root" is wrong. The committed entry changes to the repository top itself (§8), which makes it work from any subdirectory.

`codex mcp list` does not start servers, so this check did not start the server. It is recorded as *loaded: verified; started: unverified*. Starting it needs a model session. The search reference is corrected in the same PR.

## 10. Tests

All tests go in the existing suites and run under both interpreters. `bash_bin_shim` wraps the one script it is given, so it covers the dispatcher only because the dispatcher runs every sub-script with `"$BASH"` (§4.1). Tests of the `~/.local/bin` shim, which picks `bash` from `PATH`, run with `PATH="$REAL_PATH"`, as `test-hooks.sh` does elsewhere.

**`test-hooks.sh`** (setup orchestrates the installer):
- **The safety proof.** In a fixture repository, a default `setup --yes`, then a commit:
  - `PATH` holds recording stubs for `curl`, `wget`, `uv`, `gh`, `npm`, `pip`, `pip3`, `python3`, `node`, `ssh` and `nc`. None of them is invoked.
  - A `git` wrapper first on `PATH` logs every argv and refuses `fetch`, `push`, `pull`, `clone` and `ls-remote`. None of them appears in its log. `GIT_TRACE_PACKET` alone would not prove it: it logs only once a transport runs, and a failed attempt behind a `|| true` would pass. `origin` is still set to a URL that would fail if it were contacted.
  - No `.github/` is created.
  - `installed.json` has no `tiers.ci`.
  - A commit that leaves a doc stale exits 0, and so does the Claude gate hook run on it (STRICT unset).
  - The env hook and `~/.local/bin` are untouched. The fixture has a private `HOME`.
  - The same proof for `--yes --set search=on` without `--build`: no stub is invoked, and only the files the review listed are written (the config, the launcher, `.mcp.json`).
- **The writes.** `--dry-run` writes nothing (tree and `HOME` checksums). `--yes` writes exactly the files the review listed, split as listed.
- **Idempotency.** A second `--yes` says *nothing to do* and changes no byte and no mtime in the work tree, `.git/hooks`, `.git/info/exclude`, `.claude/` and `HOME`. `.git/config` is left out of the mtime check: `install_merge_driver` runs `git config --local` every time, and git rewrites the file even for an unchanged value. Its content is checked instead.
- **The exclude block.** `uninstall --claude` after setup leaves `installed.local.json` excluded.
- **Records.**
  - `--apply` with no record exits 1.
  - In a fresh clone of a repository with a record, `--apply` installs the per-user parts and changes no committed file.
  - Local overrides win for their user only.
  - A v2 CI-only record migrates.
  - A file `install --ci` writes afterwards keeps `setup`.
  - A refused (corrupt, newer) record makes setup refuse.
- **The base.** On a repository with workflows already installed and no record, the default run removes nothing.
- **Host checks.** `uname`, `sw_vers`, `uv` and `git config --global core.hooksPath` are stubbed: each disables only its item and prints its reason, and a forced `--set` exits 1.
- **The UIs.**
  - TUI key scripts piped in: navigate, toggle, Esc → summary with `(changed)`, review → *Write only*; `q` writes nothing.
  - The prompt fallback with piped answers produces the same plan.
  - EOF quits and writes nothing.
  - A narrow `COLUMNS` stacks the details pane under the tree.
- **The harness entries.** Each JSON merge keeps other keys and refuses a non-object file. The Codex block is idempotent, and an unmarked table is refused.
- **The env hook block.** It keeps the user's lines, is `sh -n` clean, and is replaced in place.
- **The `~/.local/bin` shim.** It is asked first (`--no-link-bin` writes nothing), refuses a foreign file, and resolves the newest plugin-cache version.

**`test-spec-status-model.sh`** (the skill ↔ tool contract):
- `SKILL.md` routes `help` and `setup` to `doc-superpowers`, and says the help output is shown verbatim.
- `references/setup.md` exists and is the REQUIRED pointer.
- The help files: every topic exists, the overview names every topic and action, and the line and column limits hold.
- The evals cover `setup --dry-run` and `help`.
- The description stays ≤ 1,536 characters, and the OpenCode text stays under its ceiling.

**`test-doc-tools.sh`**: the static gates (shellcheck, bash-4, jq-1.7) cover `scripts/doc-superpowers`, `scripts/setup/*.sh` and the shim template. The `n ≥ 40` gate count rises.

**`search/tests`** (pytest): the config setup writes for doc-search equals what `doc-search init` writes. This guards against drift between them.

**Evidence:** `bash scripts/check-ci.sh` in full, run locally in the background. GitHub Actions cannot start jobs on this account right now, so the local run is the evidence and its summary goes in the PR.

## 11. Docs and packaging

- **New:** `references/setup.md` (the full reference: flow, items, flags, exit codes, records, env hook, harness entries, the shim) and `scripts/help/*.txt`.
- **`SKILL.md`:** the `setup` and `help` actions, plus a Quick Reference line.
- **`README.md`:** install, then `doc-superpowers setup`, with the safety rule.
- **`docs/guides/getting-started.md`:** rewritten setup-first.
- **`AGENTS.md`, `GEMINI.md`, the INSTALL guides:** the entry point.
- **`CLAUDE.md`:** the directory map, the key-files rows, the commands, the test counts.
- **`references/search.md`:** the Codex correction (§9.4), and the other clients' status after the build-time checks.
- **`references/hooks.md`:** a pointer to setup.
- **`state.sh`:** the header comment (§6.1).
- **`docs/codebase-guide.md`, the doc-index, `RELEASE-NOTES.next`:** updated as usual.

No version bump in the PR: the release is the owner's call.

## 12. Calls made in this design (for the owner to check)

1. The `doc-superpowers hooks|tools|search` pass-throughs, so that every command named in `help` runs from a terminal. The dispatcher lives in `scripts/`, not a top-level `bin/` (revised, §14).
2. A `~/.local/bin` POSIX shim instead of a symlink (a symlink dangles after a plugin update).
3. The git tier shown as three modes (hooks + driver / driver only / off), not five per-hook toggles. The installer cannot split the tier, and #51 rules out changing it.
4. With no record, the base is the defaults ∪ what is already installed, so a default run never removes anything.
5. `--build` is the download consent for `--yes` and `--apply`. Interactively, consent is the review's *Write and build* plus a `[y/N]` that defaults to No.
6. `installed.json` stays at `schema_version` 2, with an additive `setup` object (`format: 1`), so 3.8.0 installers keep working.
7. A cache path in the env hook is host-wide, not per repository, and setup says so.
8. Help limits: the overview ≤ 24 lines, each topic ≤ 50, all ≤ 80 columns.
9. The Codex entry `cd`s to the repository top, since Codex starts servers in its launch directory.
10. Turning on the ledger writes `docs/ledger/config.json` = `{}`, and turning on spec claims writes `docs/spec-claims/config.json` = `{"schema": 1}`. Both are opt-in. The details pane warns that the spec-claims pre-commit leg blocks on findings.
11. Gemini CLI and OpenCode entries are verified with their CLIs while building, the way Codex was. Cursor stays *unverified*.
12. Per-user items: the first record seeds the team's choice. After that, when a per-user item differs from the record, the review asks once: *for you only* (the default) or *for the team*. Non-interactively, `--set` is for you only, and `--for-team` records the per-user `--set` values as the team's (revised, §14).
13. Unticking never deletes team content setup did not just create. Installer-managed items are uninstalled; config files and directories are left in place with the manual step shown; ledger and claims are locked on while their switch exists.
14. `--apply` skips an item this host cannot run, with its reason, applies the rest and exits 0.
15. A repository-local `core.hooksPath` inside the work tree (Husky) disables *hooks* mode; the merge driver alone stays.

## 13. Left to the builder

- The exact wording of the help texts and the details panes, within the limits above.
- The internal shape of the catalog and the plan, as long as the review prints the plan the executor runs.
- The plan's step order, with these fixed points: the installer steps come first, the records come last, and downloads come only after every write succeeded.
16. `--for-team` (above, call 12) is a flag #51 did not list.
17. The probe asks `status --json` for all four tiers, and the plan diffs the selection against what is installed, so `--apply` and upgrades plan real work.

## 14. Revision after the second review (2026-10-22)

A second reviewer, on a more capable model, checked the design against the code and in throwaway fixture repositories. What it confirmed:
- 3.8.0's `install --ci` keeps an added top-level `setup` key, even with no `tiers` key at all.
- `--git` and `--claude` never touch `installed.json`.
- A global or system `core.hooksPath` is refused, and `--merge-driver-only` skips that check.
- The default blocks nothing: the git pre-commit exits 1 only under STRICT or with `docs/spec-claims/`, and the Claude gate exits 2 only under STRICT.
- None of the eight default hooks calls the network.
- bash 3.2 behaves as §5.5 says: whole-second `read -t`, ESC-then-`[` read from a pipe, and `COLUMNS` honoured by `tput` with no TTY.

What changed:
- **The dispatcher moved from `bin/` to `scripts/`** (§4.1, §9.3). A top-level `bin/` stops claude.ai and Cowork from installing the plugin. Every client now runs it through `$ROOT`.
- **The plan is the selection against the probed state, not against the base** (§5). Before, `--apply` in a fresh clone would have planned nothing.
- **setup writes `docs/search/config.json` itself, with jq** (§5.1). `doc-search init` runs `uv`, which would download on *Write only*. The safety proof now also covers `--set search=on` without `--build`, and a `git` wrapper that refuses every remote verb.
- **The probe names all four tiers** (§5). `status --json --search` alone reports only doc-search.
- **setup has its own exclude block** (§6.2). The Claude tier's block is rewritten whole and removed by `uninstall --claude`.
- **Smaller fixes:**
  - no `uv` disables the build, not the item;
  - the Husky details text is spelled out;
  - the review lists every item that can reach a remote;
  - the idempotency check leaves out `.git/config`'s mtime;
  - `--apply` names its writes outside the repository, and exits 1 on a CI-only record;
  - sub-scripts run with `"$BASH"`;
  - a 100 ms Esc on a real TTY;
  - `version` reads `doc-tools.sh tools version`.
- **Call 12 is simpler:** one *for you / for the team* question at review time replaces the `t` key and the `team.` prefix.


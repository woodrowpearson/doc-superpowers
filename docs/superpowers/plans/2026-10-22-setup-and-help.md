# `setup` and `help` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `doc-superpowers setup` (a wizard with fixed safe defaults: TUI, prompt fallback, `--apply`, `--dry-run`, `--yes`) and `doc-superpowers help` (one-screen overview plus topics), identical from the skill and the terminal (#51).

**Architecture:**
- A bash dispatcher, `scripts/doc-superpowers`, routes `help`, `setup`, `version` and three pass-throughs.
- `setup` is layered: catalog → probe → model → plan → UI → executor. Most of it is driven by flags, so it is tested without a terminal.
- setup orchestrates `scripts/hooks/install.sh` and never duplicates it. It writes its own small set of files: the doc-search config, the per-harness MCP entries, the env-hook block, the exclude block, the records and the `~/.local/bin` shim.
- The help text lives in plain files that both entry points print verbatim.

**Tech Stack:** bash 3.2 + jq ≥ 1.6 + git; POSIX sh for the shim; the repository's shell test harness (`scripts/test-helpers.sh`); pytest for one drift check in `search/tests`.

**Spec:** `docs/superpowers/specs/2026-10-22-setup-and-help-design.md` (approved 2026-10-22). Executors read it beside this plan; the section numbers below (§n) are its.

## Global Constraints

- bash 3.2 compatible.
  - Banned: `declare -A`/`local -A`, `mapfile`/`readarray`, `${v,,}`/`${v^^}`, `declare -n`, `&>>`, `|&`, fractional `read -t`, negative array subscripts, `printf '%(…)T'`.
  - `test-doc-tools.sh`'s bash-4 guard and its jq-1.7 guard scan every new script.
- jq ≥ 1.6. No Python, node or other dependency in `setup` or `help`.
- shellcheck clean at `-S warning`. A disabled finding sits on its own line with a reason.
- Sub-scripts run as `"$BASH" <script>`, never a bare `bash`; only the `~/.local/bin` shim uses `bash` from `PATH` (§4.1, §4.2).
- Every write:
  - goes to a temp file beside the target, then `mv`;
  - is never made through a symbolic link (refuse with exit 1);
  - is skipped when the content would not change.
- Exit codes:
  - `0`: done, or nothing to do;
  - `1`: refused, nothing written;
  - `2`: a step failed (the steps that ran are listed);
  - `3`: usage.
- Fixed defaults:
  - On: the merge driver, the 5 report-only git hooks, the 3 Claude hooks, harness `claude-code`.
  - Off: doc-search, CI, the ledger, spec claims and the terminal command.
- A scan hint never changes a selection. A host check only disables an item, with a reason.
- Nothing downloads or touches a remote without *Write and build* plus `[y/N]`, or `--build` in non-interactive use.
- Public text names no private repository or host. The leak scan runs over every new tracked file.
- Tests go in the existing suites only. They run under bash 5.x and `/bin/bash` 3.2 (`bash scripts/check-ci.sh --bash /bin/bash hooks`).
- No version bump and no release.

## Review Focus

1. **Existing harness files with other content.** `.mcp.json`, `.cursor/mcp.json`, `.gemini/settings.json`, `opencode.json` or `.codex/config.toml` may already hold other servers, other keys or comments. Every other byte must survive; a file that is not the expected shape is refused untouched. Test in Task 6.
2. **Interrupted runs.** On ^C during the TUI, the terminal is restored (`stty`, cursor, alternate screen) and nothing is written. On ^C during the executor, a re-run finishes the job. Tests in Task 10 (TUI trap) and Task 4 (re-run after a failed step).
3. **Where setup runs.** From a subdirectory, setup acts on the repository top. In a linked worktree it acts on that worktree. Outside a git work tree it exits 1 with one line. Test in Task 2.
4. **Paths with spaces** in the repository path, `HOME`, the cache path and the plugin root. Every write quotes them: the env hook (`sh -n` clean), the shim, the TOML block and the `git add` line. Test in Tasks 6 and 9.
5. **Small terminals and non-UTF-8 locales.**
   - Below 60×16 the TUI falls back to the prompt UI with one line saying why.
   - Below 80 columns the details pane stacks under the tree.
   - Under `LC_ALL=C` the frames use ASCII only (`[x]`, `[ ]`, `>`, `|`, `-`, `+`).
   - Test in Task 10.

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/doc-superpowers` (create, executable, `#!/usr/bin/env bash`) | The dispatcher: `help`, `-h`, `--help`, `setup`, `version`, `hooks`, `tools`, `search` |
| `scripts/help/{overview,setup,search,hooks,ci,ledger,claims,release}.txt` (create) | The help text: one source for the skill and the terminal |
| `scripts/setup/setup.sh` (create) | `setup`'s entry: flags, sourcing the libs, the run modes |
| `scripts/setup/catalog.json` (create) | The items: ids, groups, kinds, options, defaults, scopes, details, writes, undo |
| `scripts/setup/lib-model.sh` (create) | Loading the catalog into arrays; the selection, base, `--set` and `requires` |
| `scripts/setup/lib-probe.sh` (create) | Installer status, records, installed state, host checks, hints |
| `scripts/setup/lib-plan.sh` (create) | Selection vs probed state → actions; the summary and review text |
| `scripts/setup/lib-exec.sh` (create) | Running the actions; the records, the exclude block, the env hook, the build |
| `scripts/setup/lib-harness.sh` (create) | The per-harness doc-search MCP entries (JSON merge, the Codex TOML block) |
| `scripts/setup/lib-prompt.sh` (create) | The plain-prompt UI |
| `scripts/setup/lib-tui.sh` (create) | The TUI: key reader, reducer, renderer, terminal setup/restore |
| `scripts/setup/search-config.json` (create) | doc-search's `DEFAULTS`, as `doc-search init` writes them |
| `scripts/setup/shim.sh` (create) | The template for the `~/.local/bin/doc-superpowers` shim (POSIX sh) |
| `references/setup.md` (create) | The full reference |
| `scripts/test-hooks.sh`, `scripts/test-spec-status-model.sh`, `scripts/test-doc-tools.sh`, `search/tests/test_setup_config.py` | Tests |
| `skills/doc-superpowers/SKILL.md`, `README.md`, `docs/guides/getting-started.md`, `AGENTS.md`, `GEMINI.md`, `.cursor-plugin/INSTALL.md`, `.codex/INSTALL.md`, `.opencode/INSTALL.md`, `CLAUDE.md`, `docs/codebase-guide.md`, `references/hooks.md`, `references/search.md`, `references/tool-mappings.md`, `scripts/hooks/state.sh` (comment only), `evals/evals.json` + `evals/fixtures/setup-defaults/setup.sh`, `docs/.doc-index.json` | Wiring and docs |

## Shared definitions (every task reads these)

**Item ids and values** (`catalog.json`; "multi" values are a CSV in catalog option order, or `none`):

| id | kind | options | default | scope | per-user |
|---|---|---|---|---|---|
| `harness` | multi | `claude-code,codex,cursor,opencode,gemini` | `claude-code` | team | no |
| `search` | toggle | `on,off` | `off` | team | no |
| `search.model` | choice | `static,gte` | `static` | team | no |
| `search.cache` | value | `host`, or an absolute path | `host` | local | — |
| `git` | choice | `hooks,merge-driver,off` | `hooks` | team (driver) + local (hooks) | yes |
| `claude` | toggle | `on,off` | `on` | local | yes |
| `ci.workflows` | multi | the 9 names `install.sh` lists, in its order | `none` | team | no |
| `ci.base_branch` | value | a valid branch name | `main` | team | no |
| `ci.cron` | value | 5 fields | `0 9 * * 1` | team | no |
| `ci.strict` | toggle | `on,off` | `off` | team | no |
| `ledger` | toggle | `on,off` | `off` | team | no |
| `ledger.git` | toggle | `on,off` | `off` | local | yes |
| `ledger.claude` | toggle | `on,off` | `off` | local | yes |
| `claims` | toggle | `on,off` | `off` | team | no |
| `bin` | toggle | `on,off` | `off` | local (outside the repository) | — |

`requires`:
- `search.model`, `search.cache` → `search=on`;
- `ledger.git`, `ledger.claude` → `ledger=on`;
- `ci.base_branch`, `ci.cron`, `ci.strict` → `ci.workflows≠none`.

Setting a child turns its parent on. Turning a parent off resets its children to their defaults. `search.model=gte` stores `"transformer:gte-modernbert-base"` in the config and the record.

**Records** (§6):
- Team: `.claude/doc-superpowers/installed.json` → `.setup = {"format":1,"harnesses":[…],"git":"hooks|merge-driver|off","claude":true|false,"search":null|{"model":"static"|"transformer:gte-modernbert-base"},"ledger":null|{"git":bool,"claude":bool},"claims":bool}`. `schema_version` stays 2, and CI stays in `.tiers.ci`.
- Local: `.claude/doc-superpowers/installed.local.json` = `{"format":1,"overrides":{…per-user ids…},"search":{"cache":null|"/abs"}}`.

**Fixed strings the tests pin:**
- **Review section headers**, each on its own line:
  - `Committed for the team:`
  - `Local to you:`
  - `Local to you (outside the repository):`
  - `Network:`
  - `Downloads:`
  - `Then commit:` (followed by one `git add -- <paths…>` line)
  - an empty section prints `  (nothing)` under its header.
- **Summary lines:** `[x] <Group>  <value text>` or `[ ] <Group>  off`. A line gets ` (changed)` when it differs from the base and ` (already installed)` when the probe found it in place.
- **Exclude block markers:** `# doc-superpowers setup:begin` / `# doc-superpowers setup:end`.
- **Env hook block markers:** `# doc-superpowers setup:begin (managed; edit with doc-superpowers setup)` / `# doc-superpowers setup:end`.
- **The shim** carries the marker line `# doc-superpowers terminal shim v1` on line 2.
- **Messages:**
  - no record: `no team setup recorded: run doc-superpowers setup`;
  - nothing to change: `nothing to do`.

**Plan action ops** (one line per action, fields separated by TAB, built by `lib-plan.sh`, run by `lib-exec.sh`):
- Installer actions:
  - `git-install hooks|merge-driver`, `git-uninstall hooks|merge-driver`;
  - `claude-install`, `claude-uninstall`;
  - `ci-install <csv> <base> <cron> <true|false>`, `ci-uninstall <csv>`;
  - `search-install`, `search-uninstall`;
  - `ledger-install`, `ledger-uninstall`;
  - `ledger-claude-install`, `ledger-claude-uninstall`.
- Files setup writes itself:
  - `search-config <static|gte>`;
  - `harness-add <h>`, `harness-remove <h>`;
  - `ledger-config`, `claims-config`;
  - `envhook <cache|-> <root|->`;
  - `exclude-local`;
  - `bin-link`, `bin-unlink`;
  - `record-team`, `record-local`.
- `build`: a download, and always last.

---

### Task 1: Help text and the dispatcher

**Files:**
- Create: `scripts/doc-superpowers`, `scripts/help/overview.txt`, `scripts/help/{setup,search,hooks,ci,ledger,claims,release}.txt`
- Modify: `scripts/test-spec-status-model.sh` (new section `--- setup and help: the help text and the dispatcher ---`, before the leak-scan section), `scripts/test-doc-tools.sh` (add `scripts/doc-superpowers` to the shellcheck list at :515 and to the bash-4 and jq-1.7 ship lists)

**Interfaces:**
- Produces:
  - `scripts/doc-superpowers <cmd> [args]`:
    - `help|-h|--help [topic]` → prints `scripts/help/<topic|overview>.txt`, exit 0. An unknown topic: the topic list on stderr, exit 3.
    - `version` → `"$BASH" "$ROOT/scripts/doc-tools.sh" tools version`.
    - `hooks …` → `"$BASH" "$ROOT/scripts/hooks/install.sh" …`.
    - `tools …` → `"$BASH" "$ROOT/scripts/doc-tools.sh" …`.
    - `search …` → `sh .claude/doc-superpowers/search-mcp.sh …` when that file exists at the repository top, else `sh "$ROOT/scripts/search/launch.sh" …`.
    - `setup …` → `exec "$BASH" "$ROOT/scripts/setup/setup.sh" "$@"`.
    - No command → the overview.
    - Anything else → `doc-superpowers: unknown command '<x>' (doc-superpowers help)` on stderr, exit 3.
  - `$ROOT` is the dispatcher's own directory's parent, with symlinks resolved by a loop of `readlink`: bash 3.2 macOS has no `readlink -f`.

- [ ] **Step 1: Write the failing tests** in `test-spec-status-model.sh`, using a shim: `DS="$(bash_bin_shim "$REPO_ROOT/scripts/doc-superpowers")"`.
  - `help`, `-h` and `--help` print byte-identical output, equal to `cat scripts/help/overview.txt`.
  - For each of the 7 topics: `help <t>` equals `scripts/help/<t>.txt`, and `overview.txt` contains `help <t>`.
  - The overview is ≤ 24 lines. Every topic is ≤ 50 lines. Every line of every file is ≤ 80 columns: `awk 'length > 80'` is empty.
  - The overview names `init`, `audit`, `review-pr`, `update`, `diagram`, `sync`, `release`, `spec-generate`, `spec-inject`, `spec-verify`, `ledger`, `hooks`, `setup` and `help`.
  - No ANSI escape in any help file: `grep -c $'\033'` is 0.
  - `help nosuch` exits 3, and its stderr names the topics.
  - `doc-superpowers nosuch` exits 3.
  - `version` prints the `RELEASE-NOTES.md` version (`3.8.0` on this branch: read it with `sed -n 's/^## v\([0-9.]*\).*/\1/p' RELEASE-NOTES.md | head -1`).
  - `hooks help` output equals `install.sh help`'s.
  - Run from a symlink to the dispatcher, `help` still works.
- [ ] **Step 2: Run them and see them fail.** Run `bash scripts/test-spec-status-model.sh 2>&1 | tail -5`. Expected: FAIL, because the dispatcher is missing.
- [ ] **Step 3: Write the help files.**
  - Each topic covers:
    - what the feature is, and whether it is on by default;
    - its terminal command (`doc-superpowers …`) and its skill action (`/doc-superpowers …`);
    - what it writes, split into committed and local;
    - how to undo it;
    - its reference file (`references/<x>.md`).
  - The overview carries one line per feature or action, and ends with `doc-superpowers help <topic>  (topics: setup search hooks ci ledger claims release)`.
  - The `setup` topic states the defaults verbatim from Global Constraints.
- [ ] **Step 4: Write `scripts/doc-superpowers`** to the interface above. Make it `chmod +x`.
- [ ] **Step 5: Run the tests and see them pass.** Run `bash scripts/test-spec-status-model.sh` and `bash scripts/test-doc-tools.sh 2>&1 | grep -E 'shellcheck|bash-4|jq-1.7|Results'`. Expected: all PASS, and the shellcheck gate count is one higher.
- [ ] **Step 6: Commit.** `git add scripts/doc-superpowers scripts/help scripts/test-spec-status-model.sh scripts/test-doc-tools.sh && git commit -m "feat(help): doc-superpowers help and the dispatcher (#51)"`

### Task 2: The setup skeleton: catalog, model, probe, `--list`

**Files:**
- Create: `scripts/setup/setup.sh`, `scripts/setup/catalog.json`, `scripts/setup/lib-model.sh`, `scripts/setup/lib-probe.sh`
- Modify:
  - `scripts/test-hooks.sh`: a new section `=== setup: model, probe, --list (#51) ===` before the final Claude-contract section. Add a helper `SETUP="$(bash_bin_shim "$SCRIPT_DIR/doc-superpowers")"`, and `run_setup [VAR=value …] -- <args>`, which sets `RUN_RC`/`RUN_OUT`/`RUN_ERR` like `run_hooked`, with `PATH="$REAL_PATH"`.
  - `scripts/test-doc-tools.sh`: add `scripts/setup/*.sh` to all three ship lists.

**Interfaces:**
- Consumes: the Task 1 dispatcher (`setup` route).
- Produces (sourced libs; all state in globals, bash 3.2 indexed arrays):
  - `model_load_catalog <file>` fills these arrays, all of length `CAT_N`: `CAT_ID`, `CAT_GROUP`, `CAT_KIND`, `CAT_OPTIONS` (CSV), `CAT_DEFAULT`, `CAT_SCOPE` (`team|local|mixed|outside`), `CAT_PERUSER` (`0|1`), `CAT_LABEL`, `CAT_DETAILS`, `CAT_UNDO`, `CAT_WRITES`, `CAT_REQUIRES` (`id=value`, or empty). It also fills `GROUPS` (ordered: Harness, doc-search, Git hooks, Claude hooks, CI workflows, Work ledger, Spec claims, Terminal command).
  - `model_idx <id>` echoes the index, or returns 1.
  - `model_get <id>` echoes `SEL[i]`.
  - `model_set <id> <value>` validates the value against the kind and options (CSVs are normalised to catalog order; `none` for empty), applies `requires`, and refuses a `DISABLED` item. It returns 1, with `MODEL_ERROR` set, on refusal.
  - `model_base_init` sets `BASE[]` and `SEL[]` per §5.2 (record + local overrides; else defaults ∪ `probe_installed`).
  - `model_changed <id>` returns 0 when `SEL` ≠ `BASE`.
  - `probe_run` sets:
    - `TOP` (the repository top);
    - `PROBE_STATUS` (the JSON of `install.sh status --json --git --claude --ci --search`);
    - `PROBE_TEAM` (the `.setup` JSON, or empty);
    - `PROBE_LOCAL` (the local record JSON, or empty);
    - `PROBE_RECORD_ERROR` (from `.tiers.ci.state_error` when `state_readable` is false; a local record that is not JSON also sets it).
  - `probe_installed <id>` echoes the installed value in the item's value space. For example, `git` → `hooks` when all 5 hooks are `installed|integrated`, `merge-driver` when only the driver is `registered`, else `off`. `search` → `on` when `docs/search/config.json` exists. `search.model` is read from that config. `harness` → the harnesses whose entry is present.
  - `probe_state <id>` echoes `current`, `outdated` or `absent`.
  - `DISABLED[i]` holds a reason, or empty (filled in Task 8; empty here).
  - `HINT[i]` holds a hint (filled in Task 8).
  - `setup.sh --list` prints, per item, `<id>=<value><TAB><scope><TAB><label><TAB><options><TAB><disabled reason>`.

- [ ] **Step 1: Write the failing tests** (`test_setup_list_defaults`, `test_setup_list_installed_union`, `test_setup_set_validation`, `test_setup_outside_repo`, `test_setup_subdir`, `test_setup_refuses_bad_record`):
  - A fresh `setup` fixture: `--list` has `git=hooks`, `claude=on`, `harness=claude-code`, `search=off`, `ci.workflows=none`, `ledger=off`, `claims=off`, `bin=off`. Exit 0, and nothing written: `git status --porcelain` is empty and `HOME` is unchanged (find + `hash_file` over both, before and after).
  - After `install.sh install --ci` in the fixture, `--list` has `ci.workflows=doc-freshness-pr,doc-freshness-schedule` (the union).
  - `--list --set search.model=gte` has `search=on` (requires).
  - These exit 3, with the item and value named on stderr:
    - `--set nosuch=1`;
    - `--set git=bogus`;
    - `--set ci.cron='1 2'`;
    - `--set search.cache=relative/path`.
  - Run outside a git work tree (`cd "$SUITE_TMP"`), it exits 1 with `not a git repository` on stderr.
  - From `src/`, `--list` gives the same output as from the top.
  - With `installed.json` holding `{"schema_version":3}`, it exits 1, and its stderr contains the `state.sh` reason (`newer doc-superpowers installer`).
- [ ] **Step 2: Run and see them fail.** Run `bash scripts/test-hooks.sh 2>&1 | grep -A2 'setup:' | head`. Expected: FAIL.
- [ ] **Step 3: Write `catalog.json`** with the shared table's 15 items.
  - Each item's `details` gives what it does, its scope wording (*committed for the team* / *local to you*), whether it can block a commit, and whether it can reach the network.
  - The `ci.workflows` options' details are the consent rows of `references/hooks.md` (*Consent before `--ci`*).
  - `undo` holds the exact command, for example `doc-superpowers hooks uninstall --claude`.
- [ ] **Step 4: Write `lib-model.sh`, `lib-probe.sh` and `setup.sh`.**
  - Flag parsing covers all of §5.3's flags, but only `--list` and `--set` act yet. The others exit 3 with `not implemented yet` until their tasks; that line must be gone by Task 9.
  - The catalog is read with one jq call into US-separated lines (as `state.sh` does).
  - `setup.sh` `cd`s to `git rev-parse --show-toplevel`.
- [ ] **Step 5: Run and see them pass**, under both interpreters: `bash scripts/check-ci.sh --bash /bin/bash hooks` (Expected: the hooks suite passes), then the same with the default bash.
- [ ] **Step 6: Commit.** `git commit -m "feat(setup): the catalog, the model and the probe; setup --list (#51)"`

### Task 3: The plan and the review (`--dry-run`)

**Files:**
- Create: `scripts/setup/lib-plan.sh`
- Modify: `scripts/setup/setup.sh`, `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: `SEL`, `BASE`, `probe_installed`, `probe_state` and `CAT_*` (Task 2).
- Produces:
  - `plan_build` fills these arrays:
    - `PLAN` (op lines, as in the shared definitions);
    - `W_TEAM`, `W_LOCAL`, `W_OUTSIDE` (`path<TAB>what` lines);
    - `NET` (`item<TAB>what`);
    - `DL` (`what<TAB>size or estimate`).

    It diffs `SEL` against the **probed state**, not the base (§5): `current` → no op, `outdated` → refresh (an install op), `absent` → install.
  - Op order: the installer ops (git, claude, ci, search, ledger), then `search-config`, harness entries, `ledger-config`, `claims-config`, `envhook`, `exclude-local`, `bin-*`, `record-team`, `record-local`, and `build` last.
  - `plan_is_empty` returns 0 when `PLAN` holds nothing except, at most, record ops whose content would not change.
  - `plan_render_summary` and `plan_render_review` print to stdout, with the fixed strings above.
  - `setup.sh --dry-run` prints the summary, a blank line, then the review, and exits 0.

- [ ] **Step 1: Write the failing tests** (`test_setup_dry_run_defaults`, `test_setup_dry_run_writes_nothing`, `test_setup_dry_run_search_static`, `test_setup_dry_run_ci_consent`, `test_setup_dry_run_ledger_network`):
  - On a fresh fixture, `--dry-run`:
    - lists, under `Committed for the team:`, `.gitattributes` and `.claude/doc-superpowers/installed.json`;
    - lists, under `Local to you:`, `.git/config`, `.git/hooks/`, `.git/info/exclude`, `.claude/settings.local.json` and `.claude/hooks/doc-superpowers/`;
    - has `Network:` followed by `  (nothing)`, and `Downloads:` followed by `  (nothing)`;
    - has `Then commit:` followed by `git add -- .gitattributes .claude/doc-superpowers/installed.json`.
  - A checksum of the work tree, `.git` (minus `index`) and `HOME` is unchanged afterwards.
  - With `--set search=on`, the review has the additions below, and **no** `build` op unless `--build`:
    - `docs/search/config.json`, `.claude/doc-superpowers/search-mcp.sh` and `.mcp.json` under the team section;
    - a Downloads block naming the contributor's client download on first start (§5.5 owner's decision; the line contains `first start`).
  - With `--set ci.workflows=doc-review-pr`:
    - the review lists `.github/workflows/doc-review-pr.yml`;
    - its `Network:` section names `doc-review-pr`;
    - the details (via `--list`) contain `pull-requests + issues: write`.
  - With `--set ledger=on --set ledger.git=on`, the review's `Network:` names the ledger git set (`keys.mode cas`).
- [ ] **Step 2: Run and see them fail** (`not implemented yet`).
- [ ] **Step 3: Write `lib-plan.sh`**, and wire up `--dry-run`.
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): the plan and the review screen; setup --dry-run (#51)"`

### Task 4: The executor for the defaults; `--yes`; the safety proof

**Files:**
- Create: `scripts/setup/lib-exec.sh`
- Modify: `scripts/setup/setup.sh`, `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: `PLAN` (Task 3).
- Produces:
  - `exec_plan` runs each op through `op_<name with - as _>`.
    - On a failure it prints `setup: step <n> (<op>) failed; done: <ops>; re-run to finish` and exits 2.
    - At the end it prints `Then commit: git add -- …` (only paths that changed), or `nothing to do`.
  - `op_git_install`, `op_git_uninstall`, `op_claude_install`, `op_claude_uninstall` call `"$BASH" "$ROOT/scripts/hooks/install.sh" install|uninstall --git [--merge-driver-only] | --claude`.
  - `op_record_team` writes `.setup` into `installed.json`, merging with jq. It creates `{"schema_version":2,"setup":…}` when the file is absent.
  - `op_record_local` writes the local record.
  - `op_exclude_local` adds the exclude block for `.claude/doc-superpowers/installed.local.json` to `$(git rev-parse --git-path info/exclude)`.
  - `setup.sh --yes [--set …]` runs probe → model → plan → exec.

- [ ] **Step 1: Write the failing tests:**
  - `test_setup_yes_defaults_safety`: the §10 safety proof. Steps:
    1. In `indexed_fixture`, put a stub directory first on `PATH`. It holds `curl`, `wget`, `uv`, `gh`, `npm`, `pip`, `pip3`, `python3`, `node`, `ssh` and `nc`, each `#!/bin/sh` that appends `$0 $*` to `$STUBLOG` and exits 0. It also holds a `git` wrapper that appends argv to `$GITLOG`, exits 128 for `fetch|push|pull|clone|ls-remote` (scanning every argument), and otherwise `exec`s the real git (its path captured with `type -P git` before `PATH` changes).
    2. Set `git remote add origin https://example.invalid/x.git`.
    3. Run `--yes`, then `git add -A`, then `echo changed >> src/util.js && git commit -qam code` (a commit that leaves the doc stale).

    Asserts:
    - setup exits 0;
    - `$STUBLOG` is empty;
    - `$GITLOG` has no `fetch|push|pull|clone|ls-remote`;
    - `.github` does not exist;
    - `jq '.tiers.ci'` of the record is `null`, and `jq -c .setup` is `{"format":1,"harnesses":["claude-code"],"git":"hooks","claude":true,"search":null,"ledger":null,"claims":false}`;
    - the commit exits 0 (DOC_SUPERPOWERS_STRICT unset);
    - `run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')"` gives `RUN_RC` = 0;
    - `$XDG_CONFIG_HOME/doc-search` and `$HOME/.local/bin` do not exist.
  - `test_setup_yes_writes_what_review_listed`: the paths the `--dry-run` review listed equal the set of paths changed by `--yes`. Changed paths come from `git status --porcelain --ignored` plus `.git/hooks`, `.git/config` and `.git/info/exclude` diffs.
  - `test_setup_idempotent`: a second `--yes` prints `nothing to do`. It leaves no byte and no mtime changed in the work tree, `.git/hooks`, `.git/info/exclude`, `.claude/` and `HOME`. `.git/config`'s content is checked, not its mtime (§10). Compare `ls -lT`/`stat` output: use `find … -newer <marker>` with a marker file touched before the run.
  - `test_setup_rerun_after_failed_step`: make `.claude` a file (so `claude-install` fails), run `--yes` (exit 2, and stderr names `claude-install`), remove the file, run `--yes` again (exit 0), and check that everything is installed.
  - `test_setup_refuses_symlinked_record`: `installed.json` is a symlink → exit 1, and the target is unchanged.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Write `lib-exec.sh`** for the default ops, the records and the exclude block.
  - The record write: jq over the current file, temp beside it, `mv`, skipped when unchanged.
  - The exclude block is added only when the local record is written.
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): the executor and setup --yes; a default run downloads nothing, calls no network, adds no CI, blocks no commit (#51)"`

### Task 5: doc-search: config, launcher, env hook, build

**Files:**
- Create: `scripts/setup/search-config.json`, `search/tests/test_setup_config.py`
- Modify: `scripts/setup/lib-exec.sh`, `scripts/setup/lib-plan.sh`, `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: the plan ops `search-config`, `search-install`, `search-uninstall`, `envhook` and `build`.
- Produces:
  - `HOST_NO_BUILD`, set by `probe_run` in `lib-probe.sh` (this task adds it): `uv not found` when `command -v uv` fails, else empty. Task 8 builds the other host checks beside it.
  - The config is doc-search's full `DEFAULTS`, not `{}`. The design's §5.1 shows `{}` while its §10 requires that setup's file equal `doc-search init`'s output. This plan takes §10, as the second review advised: `init` writes `DEFAULTS` verbatim, and a user reads the same file whichever way doc-search was turned on.
  - `op_search_config <static|gte>`:
    - when the config is absent, copies `search-config.json` (`gte`: `jq '.docs.model = "transformer:gte-modernbert-base"'`);
    - when present, changes only `.docs.model`, and only if it differs;
    - never runs `uv`.
  - `op_search_install` / `op_search_uninstall` → `install.sh install|uninstall --search`. Unticking leaves `docs/search/config.json` in place and prints the manual step (§5.2).
  - `op_envhook <cache|-> <root|->`:
    - writes or replaces the marked block in `${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/doc-search/env.sh}`;
    - the block exports `SEMBLE_CACHE_LOCATION=<cache>/semble`, `DOC_SEARCH_CACHE_LOCATION=<cache>/doc-search` and `DOC_SUPERPOWERS_ROOT=<root>`, each `sh`-quoted;
    - the result must pass `sh -n` before the `mv`;
    - the block is removed when both values are `-`.
  - The plan emits `envhook` only with `search=on`, and only when the cache is a path or `$ROOT` is not under `${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}`.
  - `op_build` runs `sh .claude/doc-superpowers/search-mcp.sh index` in the foreground. It is planned only with `--build`, or with the interactive *Write and build*. With no `uv` (`HOST_NO_BUILD`), it is refused at plan time with exit 1.

- [ ] **Step 1: Write the failing tests:**
  - pytest `test_setup_search_config_matches_init`: `json.loads(Path(<repo>/scripts/setup/search-config.json).read_text()) == DEFAULTS`, and the file's text equals `json.dumps(DEFAULTS, indent=2) + "\n"`.
  - Shell `test_setup_search_write_only_safety`:
    - `--yes --set search=on` with the Task 4 stubs and git wrapper leaves `$STUBLOG` empty;
    - it writes `docs/search/config.json` (equal to `search-config.json`), the launcher and `.mcp.json`;
    - `$XDG_CONFIG_HOME/doc-search/env.sh` is absent (setup runs from this checkout, which is not under the plugin cache, but the fixture sets `CLAUDE_PLUGIN_CACHE` to a directory holding a fake `doc-superpowers/9.9.9/` that is this checkout's root via a symlink, so no root block is needed; assert this exact case).
  - `test_setup_search_gte_and_cache`:
    - `--yes --set search.model=gte --set search.cache="$TEST_DIR/my cache"` (a path with a space) writes the config with `docs.model` = `transformer:gte-modernbert-base`;
    - the env hook's block passes `sh -n`, and sourcing it in `sh` exports `SEMBLE_CACHE_LOCATION="$TEST_DIR/my cache/semble"`;
    - a user line already in the file (`export FOO=1`) is kept;
    - a second run leaves the file byte-identical.
  - `test_setup_build_needs_consent`: `--yes --set search=on` leaves `uv` uninvoked. `--yes --set search=on --build` invokes the `uv` stub once, with `run --project` and `doc-search index` in its argv.
  - `test_setup_search_untick_keeps_config`: after search is on, `--yes --set search=off`:
    - removes the launcher and the `.mcp.json` entry;
    - keeps `docs/search/config.json`;
    - prints `docs/search/config.json is left in place`.
  - `test_setup_no_uv_build_refused`: with `uv` missing from `PATH`, `--yes --set search=on` exits 0 (written), and `--yes --set search=on --build` exits 1 with `uv not found`.
- [ ] **Step 2: Run and see them fail.** Run `uv run --project search --frozen --all-extras pytest -q search/tests/test_setup_config.py` and the hooks suite.
- [ ] **Step 3: Implement** the ops and the plan rules above. Write `search-config.json` from `json.dumps(DEFAULTS, indent=2)`.
- [ ] **Step 4: Run and see them pass** (pytest, and hooks under both interpreters).
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): doc-search: config without uv, launcher, env hook, build only with consent (#51)"`

### Task 6: Harness entries

**Files:**
- Create: `scripts/setup/lib-harness.sh`
- Modify: `scripts/setup/lib-exec.sh`, `scripts/setup/lib-plan.sh`, `scripts/setup/lib-probe.sh` (`probe_installed harness`), `scripts/test-hooks.sh`

**Interfaces:**
- Produces:
  - `harness_file <h>` echoes, for `claude-code|codex|cursor|opencode|gemini`, one of `.mcp.json`, `.codex/config.toml`, `.cursor/mcp.json`, `opencode.json`, `.gemini/settings.json`.
  - `harness_entry_state <h>` echoes `registered`, `different`, `absent` or `unreadable`.
  - `harness_entry_add <h>` / `harness_entry_remove <h>` return 1 with `HARNESS_ERROR` set on refusal. `claude-code` delegates to `install.sh --search`. The JSON harnesses are merged with jq, keeping every other key. Codex gets this exact block:

    ```toml
    # doc-superpowers setup:begin doc-search
    [mcp_servers.doc-search]
    command = "sh"
    args = ["-c", "cd \"$(git rev-parse --show-toplevel)\" && exec sh .claude/doc-superpowers/search-mcp.sh serve"]
    startup_timeout_sec = 60
    # doc-superpowers setup:end doc-search
    ```
  - The JSON entry bodies are exactly `references/search.md` → *Other clients*:
    - Cursor: the `sh -c 'cd "$1" && …' sh ${workspaceFolder}` form;
    - Gemini: `{"command":"sh","args":[".claude/doc-superpowers/search-mcp.sh","serve"]}` under `mcpServers`;
    - OpenCode: `{"type":"local","command":["sh",".claude/doc-superpowers/search-mcp.sh","serve"],"timeout":60000}` under `mcp`, with `"$schema"` added only when the file is created.
  - Each harness ticked without doc-search prints only its skill install steps: a pointer to its INSTALL guide (`.codex/INSTALL.md` etc.) and `doc-superpowers help setup`.

- [ ] **Step 1: Write the failing tests** (`test_setup_harness_entries`, `test_setup_harness_keeps_other_content`, `test_setup_harness_refuses`, `test_setup_codex_block_idempotent`):
  - `--yes --set search=on --set harness=claude-code,codex,cursor,opencode,gemini` writes all five files.
    - Each parses: `jq -e .` for the JSON files. For the TOML, `grep -c '^\[mcp_servers.doc-search\]'` = 1.
    - Each `harness_entry_state` is `registered`.
    - The review listed all five under `Committed for the team:`, and the output names the Codex trust requirement (`trusted`).
  - **Review Focus 1:**
    - a pre-existing `.cursor/mcp.json` with another server `other` keeps it;
    - a pre-existing `.codex/config.toml` with `model = "x"` and a `[mcp_servers.other]` table keeps both byte-for-byte, outside the block;
    - a re-run adds no second block.
  - `opencode.json` holding `[]` (not an object) → exit 1, and the file is unchanged.
  - A `.codex/config.toml` with an unmarked `[mcp_servers.doc-search]` → exit 1 (`already defines [mcp_servers.doc-search]`), unchanged.
  - Unticking `codex` removes exactly the block, and the file is otherwise byte-identical.
  - **Review Focus 4:** the fixture repository path contains a space (`setup` in a `mktemp -d "$SUITE_TMP/with space.XXXX"` repo), and every entry is still written and parses.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement `lib-harness.sh`**, and the plan/exec wiring.
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): doc-search entries for Codex, Cursor, OpenCode and Gemini CLI (#51)"`

### Task 7: CI, ledger, claims; unticking; per-user overrides; `--apply`; migration

**Files:**
- Modify: `scripts/setup/lib-plan.sh`, `scripts/setup/lib-exec.sh`, `scripts/setup/lib-model.sh`, `scripts/setup/setup.sh`, `scripts/test-hooks.sh`

**Interfaces:**
- Produces:
  - **CI:** `op_ci_install <csv> <base> <cron> <true|false>` → `install.sh install --ci --workflows=<csv> --base-branch <base> --cron <cron> --ci-strict=<b>`. `op_ci_uninstall <csv>` → `uninstall --ci --workflows=<csv>`.
  - **Ledger and claims:**
    - `op_ledger_config` writes `docs/ledger/config.json` = `{}` only when absent.
    - `op_claims_config` writes `docs/spec-claims/config.json` = `{"schema": 1}` only when absent.
    - Ledger and claims cannot be unticked while their switch exists: `model_set ledger off` returns 1 with `MODEL_ERROR` naming the manual step, and in the UIs the item is locked.
    - `op_ledger_install`, `op_ledger_uninstall`, `op_ledger_claude_install` and `op_ledger_claude_uninstall` → `install.sh --ledger` / `--ledger-claude`.
  - **Per-user items** (`CAT_PERUSER=1`):
    - When a team record exists, a changed per-user item goes into the local record's `overrides`.
    - It goes into the team record only with `--for-team`, or when no team record exists yet (the first record seeds it).
    - `setup.sh --for-team` is a new flag.
  - `setup.sh --apply`:
    - exits 1 with `no team setup recorded: run doc-superpowers setup` when `PROBE_TEAM` is empty (a CI-only v2 record included);
    - otherwise the selection = team record + local overrides + `tiers.ci`'s recorded workflows and choices;
    - plans against the probed state, and never emits `record-team`;
    - skips `DISABLED` items, printing `skipped: <id>: <reason>` last, and exits 0;
    - lists writes outside the repository under `Local to you (outside the repository):`.

- [ ] **Step 1: Write the failing tests:**
  - `test_setup_ci_opt_in`: `--yes --set ci.workflows=doc-freshness-pr --set ci.strict=on` installs `.github/workflows/doc-freshness-pr.yml`. Then `jq .tiers.ci.ci_strict` = `true` and `.tiers.ci.workflows["doc-freshness-pr"].state` = `installed`. `--set ci.workflows=none` uninstalls it, and `.setup` is still there.
  - `test_setup_ledger_claims`: `--set ledger=on --set ledger.git=on --set claims=on` writes the two configs and the ledger pre-commit block. A later `--set ledger=off` exits 1, and its stderr names `docs/ledger/config.json`.
  - `test_setup_apply_no_record`: `--apply` on a fresh fixture, and on one with only `install --ci` done, exits 1 with the message.
  - `test_setup_apply_fresh_clone`:
    1. In repo A: `--yes --set search=on`, then commit everything.
    2. `git clone` A to B (a new `HOME`), and run `--apply` in B.
    3. B now has 5 hooks `installed`, the driver `registered`, and the 3 Claude hooks `active` (status json).
    4. `git status --porcelain` in B is empty: no committed file changed.
  - `test_setup_peruser_override`:
    1. In a recorded fixture, `--yes --set claude=off` uninstalls the Claude tier.
    2. Then `installed.local.json` has `.overrides.claude == false`, and `.setup.claude` in the team record is still `true`.
    3. `installed.local.json` is excluded (`git check-ignore -q`).
    4. `--yes --set claude=off --for-team` sets `.setup.claude == false`.
  - `test_setup_exclude_survives_claude_uninstall`: after the override above, `install.sh uninstall --claude`, then `git check-ignore -q .claude/doc-superpowers/installed.local.json` still exits 0.
  - `test_setup_migrates_ci_only_record`: in a fixture with a v2 CI-only record (from `install --ci`), `--yes` keeps `.tiers.ci` byte-identical, adds `.setup`, and keeps `schema_version` 2. Then `install.sh install --ci` (the 3.8.0 code path in this tree) keeps `.setup` unchanged.
  - `test_setup_installed_union_removes_nothing`: with workflows installed and no record, `--yes` (no `--set`) uninstalls nothing. The workflow files are still there, and the record's `.setup` exists.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): CI, ledger and claims; per-user overrides and --for-team; setup --apply (#51)"`

### Task 8: Host checks and scan hints

**Files:**
- Modify: `scripts/setup/lib-probe.sh`, `scripts/setup/lib-model.sh` (`model_set` also refuses a disabled option), `scripts/setup/lib-plan.sh` (hint lines in the summary), `scripts/test-hooks.sh`

**Interfaces:**
- Produces:
  - `probe_host_checks` fills `DISABLED[i]`, per §5.4 (`HOST_NO_BUILD` is Task 5's):
    - `uname -s`/`-m`, plus `sw_vers -productVersion` on Darwin;
    - arm64 Darwin with a major version < 14 → `search.model`'s `gte` option is disabled (`onnxruntime 1.31 needs macOS 14`);
    - a host that is neither Darwin nor Linux → `gte` is disabled;
    - status json `.tiers.git.hooks_path_foreign == true` → the `git` option `hooks` is disabled (`core.hooksPath is set in your <scope> git config`);
    - `hooks_path_scope` is `local|worktree` and `hooks_dir` is inside `$TOP` but not under `.git` → `hooks` is disabled, and the reason names the folder, says the hooks would be committed with this machine's plugin path, and says that the merge driver alone stays (§5.4);
    - `~/.local/bin` not writable (when it exists), or an existing `~/.local/bin/doc-superpowers` without the shim marker → `bin` is disabled.
  - An option-level disable is held in `DISABLED_OPT` lines (`<id>=<option><TAB><reason>`), so that `gte` can be disabled while `static` stays.
  - `probe_hints` fills `HINT[i]`:
    - `search`: `N docs (default corpus)`, counted with `git ls-files --cached --others --exclude-standard` filtered by `docs/**/*.md` and `*.md` (excluding `docs/archive/` and `docs/.doc-index.json`);
    - `search.model`: `a gte first build: about <t> here`, from the corpus bytes / 750 / (16 on arm64 Darwin, 3.6 on x86_64 Darwin), and no estimate elsewhere;
    - `harness`: detected `.cursor/`, `.codex/`, `.gemini/`, `opencode.json`;
    - `git`: `no doc index yet: run /doc-superpowers init` when `docs/.doc-index.json` is absent;
    - `ci.workflows`: `no GitHub remote` when no remote URL contains `github.com`;
    - `claims`: `docs/spec-claims/ already present: its pre-commit leg blocks on findings`.

- [ ] **Step 1: Write the failing tests** (`test_setup_host_checks`, `test_setup_hints_never_change_defaults`):
  - Stub `uname`, `sw_vers` and `uv` first on `PATH`.
    - Darwin arm64 13.6: `--list` shows the `search.model` disabled reason containing `macOS 14`, and `--yes --set search.model=gte` exits 1.
    - Darwin arm64 14.5: no reason.
    - Darwin x86_64: no reason, and the gte hint names an estimate.
  - With a global `core.hooksPath` (the fixture's `GIT_CONFIG_GLOBAL` points at a file setting it), `git=hooks` is disabled with the scope named. `--yes` installs the merge driver only (`git=merge-driver`), and the summary shows the reason.
  - `git config core.hooksPath .husky` with `.husky/` tracked: `hooks` is disabled with `.husky` named.
  - **Hints:** in a fixture with `.cursor/` and 3 docs, `--list` equals the fresh fixture's output except for the hint column; selections are unchanged.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): host checks that only disable, scan hints that never decide (#51)"`

### Task 9: The terminal command and the prompt UI

**Files:**
- Create: `scripts/setup/shim.sh`, `scripts/setup/lib-prompt.sh`
- Modify: `scripts/setup/lib-exec.sh`, `scripts/setup/setup.sh` (interactive mode: no TUI yet, so always the prompt UI), `scripts/test-hooks.sh`, `scripts/test-doc-tools.sh` (add `scripts/setup/shim.sh` to the ship lists; shellcheck it with `-s sh`)

**Interfaces:**
- Produces:
  - `op_bin_link`:
    - renders `shim.sh` with `@CLONE_ROOT@` replaced by the `sh`-quoted `$ROOT` when `$ROOT` is outside the plugin cache, else by `''`;
    - writes `~/.local/bin/doc-superpowers` with mode 755;
    - refuses an existing file without `# doc-superpowers terminal shim v1` on line 2;
    - prints `add ~/.local/bin to your PATH: export PATH="$HOME/.local/bin:$PATH"` when it is not on `PATH`.
  - `op_bin_unlink` removes the file only when it is ours.
  - The shim resolves the root from `$DOC_SUPERPOWERS_ROOT`, then the baked clone root, then the newest numeric `X.Y.Z` under `${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}/*/doc-superpowers/`. Each candidate must hold `scripts/doc-superpowers`. The shim then runs `exec bash "$root/scripts/doc-superpowers" "$@"`. If no root is found it prints one stderr line and exits 2.
  - `prompt_run` returns `PROMPT_RESULT` = `build`, `write` or `quit`, and leaves `SEL` changed. It reads its answers from stdin line by line.
    - Screens: §5.6.
    - EOF at any prompt → `quit`.
    - With a team record and changed per-user items, the review asks `Save the per-user changes for: [y]ou only  [t]he team` (default `y`).
    - *Write and build* asks `This downloads <what>. Continue? [y/N]`.
  - Interactive `setup` with no TTY on stdin or stdout, or `--plain`, or `TERM=dumb`: `prompt_run`, then plan and exec per its result. `bin` is asked as an item; it is never written without a tick.

- [ ] **Step 1: Write the failing tests:**
  - `test_setup_bin_shim` (`PATH="$REAL_PATH"`, a private `HOME` with a space in it, for Review Focus 4):
    - `--yes --link-bin` writes the shim, and `"$HOME/.local/bin/doc-superpowers" help` equals `cat scripts/help/overview.txt`;
    - a foreign file there → exit 1, unchanged;
    - `--no-link-bin` writes nothing;
    - with `CLAUDE_PLUGIN_CACHE` holding `m/doc-superpowers/3.9.0` and `3.10.0` (each a copy of `scripts/doc-superpowers` plus `scripts/help`, where 3.10.0's `overview.txt` reads `NEWEST`) and no baked root, `help` prints `NEWEST`.
  - `test_setup_prompt_defaults`: `printf 'a\no\n' | run_setup -- ` (stdin a pipe) writes the same files as `--yes`.
  - `test_setup_prompt_customize`: `printf 'c\n2\n1\n\n\na\no\n'` turns doc-search on, matching `--yes --set search=on`. Customize numbers the groups in `GROUPS` order (doc-search = 2). A group numbers its items in catalog order (`search` = 1). An empty line goes up one level. `a` opens the review, and `o` is *Write only*.
  - `test_setup_prompt_eof_quits`: `printf 'c\n' |` (EOF) writes nothing (checksums).
  - `test_setup_prompt_build_consent`: after `w`, the answer `n` to `Continue? [y/N]` writes and does not build (the `uv` stub is not invoked); the answer `y` builds.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement** `shim.sh`, the bin ops and `lib-prompt.sh`. Remove any `not implemented yet` left for these flags.
- [ ] **Step 4: Run and see them pass** under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): the terminal command (asked first) and the plain-prompt UI (#51)"`

### Task 10: The TUI

**Files:**
- Create: `scripts/setup/lib-tui.sh`
- Modify: `scripts/setup/setup.sh` (a TTY on both ends, `TERM` not `dumb`, and no `--plain` → `tui_run`; `DOC_SP_SETUP_UI=tui` forces it for tests, `=prompt` forces the prompt), `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: the model, the plan renderers and the per-user question (Tasks 2–9).
- Produces:
  - `tui_read_key` sets `KEY` to one of `up`, `down`, `left`, `right`, `enter`, `space`, `esc`, `eof`, or `char:<c>`.
    - It reads with `IFS= read -rsn1`.
    - After an ESC it runs `read -rsn1 -t 1`; on a TTY, `stty -icanon min 0 time 1` makes that wait 100 ms. `[` or `O`, then a letter, is an arrow. Any other byte is queued as the next key.
    - `k`/`j` alias `up`/`down`, and `b` aliases `esc`.
  - `tui_key` is the reducer over `UI_SCREEN` (`summary|tree|review|confirm|scope`), `UI_CUR`, `UI_OPEN` (a CSV of open groups) and `SEL`.
  - `tui_render` prints one frame from that state.
    - The size is `COLUMNS`/`LINES` when set, else `tput`. Two panes at ≥ 80 columns, stacked below that, and the prompt UI below 60×16 (with one line saying why).
    - ASCII only under `LC_ALL=C` or a non-UTF-8 `LC_CTYPE`; otherwise `✓`, `▸` and `▾` are allowed.
    - Colour only when `TERM` is not `dumb` and `NO_COLOR` is unset.
  - `tui_run` sets `TUI_RESULT` = `build`, `write` or `quit`. Only on a real TTY, it saves `stty -g`, enters the alternate screen and hides the cursor, and restores all three on EXIT, INT, TERM and HUP.
  - Keys and screens: §5.5 exactly (`e` edits a value, via a cooked-mode `read -r` on the bottom line).

- [ ] **Step 1: Write the failing tests:** pipe bytes into `DOC_SP_SETUP_UI=tui NO_COLOR=1 COLUMNS=100 LINES=30 run_setup -- `.
  - `test_setup_tui_defaults_write_only`: the input `\n\n` writes the same files as `--yes`.
    - The summary's actions are *Apply these*, *Customize…*, *Show what each does* and *Cancel*, with the cursor on *Apply these*.
    - The review's actions are *Write and build* (shown only when something builds), *Write only* and *Back*. The cursor starts on *Write only*: a build is never the default.
  - `test_setup_tui_customize_esc_changed`:
    1. `\e[B\n` (Customize).
    2. Move to the doc-search group, then `' '`.
    3. `\e` (Esc; the 1 s pipe wait) back to the summary.

    The last frame's doc-search line contains `(changed)`. Then `q` writes nothing.
  - `test_setup_tui_arrow_vs_esc`: `\eq` is Esc then `q`, and `\e[A` is up (the cursor index in a debug line printed when `DOC_SP_SETUP_DEBUG=1`).
  - `test_setup_tui_narrow` (Review Focus 5):
    - `COLUMNS=70`: the frame has no line longer than 70, and the details text comes after the tree lines;
    - `COLUMNS=50 LINES=12`: the output contains `terminal too small` and the prompt UI's first line;
    - `LC_ALL=C`: no byte ≥ 0x80 in the output.
  - `test_setup_tui_eof_quits`: an empty input writes nothing.
  - **Review Focus 2 (TTY restore):** when `script` is available, run `script -q /dev/null` (BSD) or `script -qc` (util-linux) on `setup` with a `kill -INT` after 1 s, and assert the `stty -g` before equals after. Without `script`, `record_skip`.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement `lib-tui.sh`.**
- [ ] **Step 4: Run and see them pass**, under both interpreters (`bash scripts/check-ci.sh --bash /bin/bash hooks`).
- [ ] **Step 5: Commit.** `git commit -m "feat(setup): the tree-and-details TUI in portable bash (#51)"`

### Task 11: Verify the other clients' entries; correct `references/search.md`

**Files:**
- Modify: `references/search.md` (*Other clients*), `scripts/setup/catalog.json` (the `harness` details: verified or *unverified* per client)

No product code. A verification task:
1. Install `@google/gemini-cli` and `opencode-ai` with `npm install --prefix <scratch>`, using a temporary `HOME`/config dir under the scratchpad.
2. In a throwaway repository with setup's entries, run `gemini mcp list` and `opencode mcp list`, with no model call.
3. Record each CLI's version and output.
4. Delete the scratch directory.

- [ ] **Step 1: Run the checks.** Save each command's output in the commit body.
- [ ] **Step 2: Update `references/search.md` → *Other clients*:**
  - Codex: verified on 2026-10-22 with codex-cli 0.163.0. The project file loads only for a trusted project, and a server starts in Codex's launch directory, so the entry `cd`s to the top first. *Started: unverified*.
  - Gemini and OpenCode: per what Step 1 showed.
  - Cursor: stays *unverified*.
- [ ] **Step 3: Update the catalog's per-harness details to match.** Then run `bash scripts/test-spec-status-model.sh` (the search.md section pins its ten headings; they are unchanged) and the hooks suite.
- [ ] **Step 4: Commit.** `git commit -m "docs(search): the client entries checked against Codex, Gemini CLI and OpenCode (#51)"`

### Task 12: The skill, the reference, the evals and the docs

**Files:**
- Create: `references/setup.md`, `evals/fixtures/setup-defaults/setup.sh`
- Modify: `skills/doc-superpowers/SKILL.md`, `evals/evals.json`, `scripts/test-spec-status-model.sh`, `README.md`, `docs/guides/getting-started.md`, `AGENTS.md`, `GEMINI.md`, `.cursor-plugin/INSTALL.md`, `.codex/INSTALL.md`, `.opencode/INSTALL.md`, `references/hooks.md` (a pointer to setup), `references/tool-mappings.md` (only if the OpenCode ceiling allows: one line, *terminal command: `$ROOT/scripts/doc-superpowers`*), `scripts/hooks/state.sh` (header comment, §6.1), `CLAUDE.md` (directory map, key files, commands, test counts), `docs/codebase-guide.md`, `docs/.doc-index.json`

**Interfaces:**
- **SKILL.md:**
  - Quick Reference and Usage gain `setup` and `help`.
  - The Discovery exception list becomes "`hooks`, `setup`, `help`, `release` and `ledger`".
  - Two action sections: `### \`setup\` — Set up this repository` and `### \`help\` — One-screen help`, each opening with **REQUIRED:** Read `$ROOT/references/setup.md`.
  - `help` runs `"$ROOT/scripts/doc-superpowers" help [topic]` and shows the output verbatim in a code block, with no paraphrase.
  - `setup` follows §4.3's six steps, with `--for-team` in step 5.
  - The description stays ≤ 1,536 characters. Add "setting up a repository" only if it fits.
- **`references/setup.md`** sections, in order:
  - `## What setup does`
  - `## The defaults`
  - `## The flow`
  - `## Items`
  - `## Flags and exit codes`
  - `## The records`
  - `## The env hook`
  - `## Harness entries`
  - `## The terminal command`
  - `## Help`

- [ ] **Step 1: Write the failing tests** (in `test-spec-status-model.sh`):
  - SKILL.md names `references/setup.md` and `scripts/doc-superpowers` (the existing path check then covers both).
  - Its `help` section contains `verbatim`.
  - Its `setup` section contains `--dry-run`, `--list`, `--yes`, `--build` and `--for-team`.
  - `setup.md`'s `## ` headings equal the list above.
  - Every flag `setup.sh` parses appears in `## Flags and exit codes`. Read the flags from `setup.sh`'s `case` arms with `grep -oE '^ *--[a-z-]+\)'`.
  - Every catalog id appears in `## Items`, with ids read from `jq -r '.items[].id' scripts/setup/catalog.json`.
  - A new eval `setup-defaults`:
    - the prompt is `/doc-superpowers setup` (the user picks *Apply these*, then *Write only*);
    - assertions: `tool_call_check` `doc-superpowers"? setup --dry-run`; `tool_call_check` `doc-superpowers"? setup --yes`; `tool_call_check` `--build` with `negate: true`; `file_exists` `.gitattributes`; `file_not_exists` `.github/workflows/doc-freshness-pr.yml`; `content_check` `.claude/doc-superpowers/installed.json` pattern `"setup"`;
    - the fixture is an indexed project, like `hooks-install-all`.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Write the reference and the SKILL.md sections.** Then update the other docs:
  - README: install, then `doc-superpowers setup`, with the safety rule.
  - getting-started: rewritten setup-first.
  - AGENTS.md, GEMINI.md, the INSTALL guides: the entry point.
  - `state.sh`: the comment.
  - CLAUDE.md: the structure tree gains `scripts/doc-superpowers`, `scripts/help/`, `scripts/setup/` and `references/setup.md`; the key-files rows; the commands `/doc-superpowers setup` and `/doc-superpowers help`.
  - `codebase-guide.md`.
- [ ] **Step 4: Index the new docs** with `printf 'references/setup.md:scripts/setup/,scripts/doc-superpowers,scripts/help/:reference\n' | bash scripts/doc-tools.sh add-entry`. For each existing doc this task changed, run `bash scripts/doc-tools.sh update-index <doc>`, for example `bash scripts/doc-tools.sh update-index README.md`.
- [ ] **Step 5: Run and see them pass:** `bash scripts/test-spec-status-model.sh` (frontmatter, paths, evals, the OpenCode ceiling, the leak scan).
- [ ] **Step 6: Commit.** `git commit -m "docs(setup): the skill's setup and help actions, references/setup.md, the guides (#51)"`

### Task 13: Full verification and the PR

- [ ] **Step 1: Run the whole check in the background, alone.** Run `bash scripts/check-ci.sh > <scratchpad>/check-ci.log 2>&1` with `run_in_background`, and record the PID it started. Only that PID may be killed. Expected: every suite PASS under both interpreters, plus `search`, `self-install`, `check-version`, `tag` (`--warn`) and `plugin-validate`.
- [ ] **Step 2: Update CLAUDE.md's test counts** from the run's per-suite summary lines (the counts live only there), plus the `search` pytest count. Commit that.
- [ ] **Step 3: Run the self-install check.** Re-run `bash scripts/check-ci.sh self-install`. If it reports drift, run `bash scripts/hooks/install.sh install --ci` and commit what it writes (`doc-tools.sh` did not change, so no drift is expected).
- [ ] **Step 4: Push, and open the PR** against `main`.
  - Title: `feat: setup and help (#51)`.
  - The body gives:
    - the summary and the safety proof;
    - the check-ci summary lines (Actions is blocked by the account's billing lock, so the local run is the evidence);
    - the Codex/Gemini/OpenCode verification;
    - "no release cut".
  - It closes #51 and refers to #54.

# doc-search readiness gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a repository requires doc-search, a session of a developer who has it installed is halted
while doc-search cannot answer. Nothing changes for everyone else.

**Architecture:**
- A `doc-search check` verb decides readiness, with a bounded incremental refresh, and maps it to gating
  exit codes.
- The committed launcher answers the cases Python cannot reach and provides a `gate` entry for client
  hooks:
  - `SessionStart` adds context;
  - `UserPromptSubmit` blocks;
  - `PreToolUse` denies from a per-worktree verdict file.
- `install.sh --search-gate` registers the hooks for Claude Code and Codex. A shipped rule template tells
  agents what each exit means.

**Tech Stack:** Python 3.12 (`search/`, pytest), POSIX sh (`scripts/search/launch.sh`), bash 3.2+
(`install.sh`, `doc-tools.sh`, shell suites), jq.

**Spec:** `docs/superpowers/specs/2026-10-27-doc-search-readiness-gate-design.md`

## Global Constraints

- **Exit codes:**
  - `check`: `0` ready or degraded, `1` not-ready (halt), `3` usage, `4` not-in-force.
  - `gate`: always `0`; its decision is the JSON it prints.
- **Config keys:** `"required"` (bool, default `false`) and `"requires"` (`null` or a string matching
  `^>=[0-9]+\.[0-9]+\.[0-9]+$`).
- **Launcher stamp:** line 2 of `scripts/search/launch.sh` is exactly `# doc-search launcher vX.Y.Z`, the
  release version.
- **Refresh budget:** `--budget` defaults to `20` seconds, is an integer from 1 to 600, and is the same in
  `gate`.
- **Verdict file:** `$(git rev-parse --git-path doc-search-gate)`. Line 1 is the verdict
  (`not-ready`); line 2 is the reason and fix, one line. It is written atomically (temp file in the same
  directory, then rename) and removed when the verdict is not `not-ready`.
- **Allowed while halted:** a `Bash` tool whose whole `command` matches
  `^sh (\"?[^ ;&|]*/)?\.claude/doc-superpowers/search-mcp\.sh\"? (index|status|check)( --format (text|json))?$`.
  Everything else is denied.
- **Per-developer variables:** `DOC_SEARCH_MCP=0` and `DOC_SEARCH_GATE=0`, read from the environment
  after the launcher's env hook.
- **Codex root:** `${CODEX_HOME:-$HOME/.codex}/doc-superpowers`, checked after "this repository" and
  before the plugin cache.
- **Constructs:**
  - The launcher stays POSIX sh: its static gate in `test-hooks.sh` (no `[[`, `<<<`, `local -a` …)
    passes.
  - `install.sh` and `doc-tools.sh` stay bash 3.2-safe and jq 1.6-safe.
- **Tracked files:** no machine paths (`scripts/leak-scan.sh`); North American spelling.
- **Commits:** author and committer are the repository's configured identity.
  Each ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A `check` that raises or times out while required.** `gate prompt` must block with `check failed:
   <error>`, not allow silently. A client-side timeout lets the prompt through and leaves the verdict
   file unchanged; that is documented, not tested.
2. **Two sessions in one worktree writing the verdict at once.** The file is replaced atomically, never
   half-written. Tested in Task 5.
3. **A chained fix command** (`sh .claude/doc-superpowers/search-mcp.sh index && rm -rf x`) or a
   look-alike must be denied while halted. Tested in Task 4.
4. **`requires` above the running plugin.** The verdict is `not-ready` with the update command. Tested in
   Task 3.
5. **A hook run from a subdirectory, or outside any repository.** From a subdirectory it resolves the
   top; outside a repository it is silent. Tested in Task 4.

---

### Task 1: Config keys `required` and `requires`

**Files:**
- Modify: `search/src/doc_search/config.py` (`DEFAULTS`, `Config`, `load_config`)
- Modify: `references/search.md` (*Configuration* table: two rows)
- Test: `search/tests/test_config.py`

**Interfaces:**
- Produces:
  - `Config.required: bool`;
  - `Config.requires: tuple[int, int, int] | None`;
  - `parse_version(text: str) -> tuple[int, int, int] | None`, which parses `X.Y.Z` and returns None
    otherwise.

- [ ] **Step 1: Write the failing tests**
  - `test_required_defaults_false_and_requires_none`: `{}` → `required is False`, `requires is None`.
  - `test_required_and_requires_parse`: `{"required": true, "requires": ">=3.10.0"}` →
    `(True, (3, 10, 0))`.
  - `test_requires_rejects_other_forms`, parametrized over `"3.10.0"`, `">3.10.0"`, `">=3.10"`, `">=v3.10.0"`
    and `5`: `ConfigError` whose message contains `requires must be ">=X.Y.Z"`.
  - `test_required_must_be_bool`: `"yes"` → `ConfigError` containing `required must be true or false`.
- [ ] **Step 2: Run** `uv run --project search --frozen pytest search/tests/test_config.py -q`. Expected:
  the four new tests FAIL.
- [ ] **Step 3: Implement.** Add both keys to `DEFAULTS` (top level), validate them in `load_config`, and
  add them as the last two `Config` fields. Put `parse_version` in `config.py`.
- [ ] **Step 4: Run** the same command. Expected: PASS (the whole file).
- [ ] **Step 5: Document.** Add the two rows to *Configuration* in `references/search.md`, including the
  note that a plugin older than 3.10.0 answers `invalid config: unknown key required`.
- [ ] **Step 6: Commit** `feat(search): required and requires config keys`.

### Task 2: Launcher stamp and Codex root

**Files:**
- Modify: `scripts/search/launch.sh` (line 2 stamp; the root lookup)
- Modify: `scripts/doc-tools.sh` (`bump-version` and `check-version` also cover the stamp)
- Create: `search/src/doc_search/version.py`
- Test: `scripts/test-hooks.sh` (launcher section), `scripts/test-doc-tools.sh` (bump/check-version),
  `search/tests/test_version.py`

**Interfaces:**
- Produces:
  - `plugin_root() -> Path`: `Path(__file__).resolve().parents[3]`.
  - `plugin_version(root: Path) -> tuple[int, int, int] | None`: `package.json` `.version`.
  - `launcher_stamp(path: Path) -> tuple[int, int, int] | None`: the first `# doc-search launcher vX.Y.Z`
    line within the first 5 lines.
  - `STAMP_RE`.

- [ ] **Step 1: Write the failing tests**
  - **`test-hooks.sh`:**
    - `${CODEX_HOME}/doc-superpowers` with `search/pyproject.toml` is chosen over the plugin cache.
    - `$DOC_SUPERPOWERS_ROOT` and "this repository" still win over it.
    - Unset `CODEX_HOME` falls back to `$HOME/.codex`.
    - Line 2 of `launch.sh` matches `^# doc-search launcher v[0-9]+\.[0-9]+\.[0-9]+$`.
  - **`test-doc-tools.sh`:**
    - `bump-version 9.8.7` rewrites the stamp to `v9.8.7` along with the five manifests.
    - `check-version` fails, naming `scripts/search/launch.sh`, when the stamp differs from
      `RELEASE-NOTES.md`.
  - **`test_version.py`:**
    - the stamp is parsed;
    - a file without a stamp gives None;
    - `plugin_version` of the repository equals `package.json`'s version.
- [ ] **Step 2: Run** `bash scripts/test-hooks.sh`, `bash scripts/test-doc-tools.sh` and the pytest file.
  Expected: the new assertions FAIL.
- [ ] **Step 3: Implement.**
  - The stamp line goes in at line 2 (`v3.9.0` until the release task).
  - The root lookup gains the Codex rule.
  - `doc-tools.sh` handles the stamp as one more versioned file, edited with `sed`, not jq. Keep it out of
    `VERSION_FILES`, whose entries are JSON paths.
  - Add `version.py`.
- [ ] **Step 4: Run** the three suites. Expected: PASS, including the launcher's POSIX static gate.
- [ ] **Step 5: Commit** `feat(search): a version stamp in the launcher; the Codex install is a root`.

### Task 3: `doc-search check`

**Files:**
- Create: `search/src/doc_search/check.py`
- Modify: `search/src/doc_search/cli.py` (verb `check`; `_VERBS`)
- Modify: `scripts/test-spec-status-model.sh` (the verb pin)
- Modify: `references/search.md` (*CLI*: the verb, its exit table and its JSON)
- Test: `search/tests/test_check.py`

**Interfaces:**
- Consumes: Task 1's `Config.required` / `.requires`; Task 2's `plugin_root`, `plugin_version` and
  `launcher_stamp`.
- Produces:
  - `@dataclass(frozen=True) class Verdict`, with fields:
    - `state: Literal["ready", "degraded", "not-ready", "not-in-force"]`
    - `reason: str | None`
    - `fix: str | None`
    - `required: bool`
    - `requires: str | None`
    - `version: str | None`
    - `launcher: Literal["current", "differs", "below-floor", "absent"]`
    - `mcp: Literal["expected", "off", "not-registered"]`
    - `cache: dict[str, str | None]`
    - `refreshed: bool`
  - `Verdict.exit_code() -> int`: 0, 0, 1, 4 respectively.
  - `Verdict.line() -> str`: the one-line verdict, e.g. `doc-search: not ready: docs index absent; run sh .claude/doc-superpowers/search-mcp.sh index`.
  - `assess(top: Path, *, budget_s: float, env: Mapping[str, str]) -> Verdict`.

**`assess` order.** This is decided here, not by the implementer:
1. **No config:** `not-in-force` "no docs/search/config.json".
2. **`ConfigError`:** `not-ready` when the raw text matches `"required"\s*:\s*true`, else `not-in-force`.
   The reason is `invalid config: …`.
3. **Plugin below `requires`:** `not-ready`. The fix is `claude plugin update doc-superpowers` (Codex:
   `git -C ~/.codex/doc-superpowers pull`).
4. **Launcher copy** (`<top>/.claude/doc-superpowers/search-mcp.sh`):
   - absent, or stamp below `requires`: `not-ready`, with fix `install.sh install --search`;
   - differs from `plugin_root()/scripts/search/launch.sh` but meets the floor: remember `degraded`.
5. **Cache states** come from `IndexPool.cache_state` and `fallback_cache_state`. Transformer docs:
   - transformer cache `valid` → docs ok;
   - transformer cache `absent` with fallback `valid` → `degraded` "static index while the transformer
     index builds", with the other process's progress line appended when `read_progress` has one;
   - transformer cache `absent` with fallback `stale` → refresh with a static-docs config
     (`dataclasses.replace` of `docs` with `model=None, transformer=None`);
   - transformer cache `absent` with fallback `absent` → `not-ready` "transformer index not built".
6. **Any `absent` static or code index:** `not-ready` "<kind> index absent", with fix
   `… search-mcp.sh index`. There is no build here.
7. **Any `stale`:** one bounded refresh, `IndexPool(cfg, fallback=False).get(top, wait_s=budget_s)`.
   - `Building` → `not-ready` "refresh did not finish within Ns".
   - An `error` → `not-ready` "<kind> index failed: <error>".
   - Otherwise re-read the cache states once.
   - Set `refreshed=True`.
8. **Required:** the result stands (`ready` / `degraded` / `not-ready`).
9. **Not required:** `not-in-force`, with reason "not required here (<would-be state>: <reason>)".
10. **`mcp`:**
    - `off` when `env["DOC_SEARCH_MCP"] == "0"`;
    - `expected` when `.mcp.json` has `mcpServers["doc-search"]`, or `${CODEX_HOME:-~/.codex}/config.toml`
      or `<top>/.codex/config.toml` contains `[mcp_servers.doc-search]`;
    - else `not-registered`.

- [ ] **Step 1: Write the failing tests.** Use `test_cli.py`'s fixtures (`repo`, `tx_repo`, `run`,
  `fake_transformer`); move shared ones to `conftest.py` if needed. One test per row:
  - `test_check_ready_after_index`: exit 0; `ready`.
  - `test_check_refreshes_a_stale_docs_index_within_budget`: touch a doc after `index` → exit 0,
    `refreshed` true, `cache.docs == "valid"` afterwards.
  - `test_check_budget_overrun_is_not_ready`: a fake slow build (BuildSpy-style gate) with `--budget 1` →
    exit 1; reason starts `refresh did not finish within 1s`.
  - `test_check_absent_index_is_not_ready_with_fix`: exit 1; the line contains `search-mcp.sh index`.
  - `test_check_degraded_on_static_fallback`: `tx_repo`, static fallback valid, transformer held → exit
    0; `degraded`.
  - `test_check_transformer_nothing_built_is_not_ready`.
  - `test_check_plugin_below_floor`: `requires: ">=99.0.0"` → exit 1; fix names the plugin update.
  - `test_check_launcher_absent_or_below_floor_is_not_ready`.
  - `test_check_launcher_differs_but_meets_floor_is_degraded`.
  - `test_check_not_required_is_not_in_force`: exit 4 even when stale; the reason names the would-be state.
  - `test_check_no_config_is_not_in_force`: exit 4.
  - `test_check_invalid_required_config_is_not_ready`: exit 1.
  - `test_check_invalid_config_without_required_is_not_in_force`: exit 4.
  - `test_check_mcp_states`: `off`, `expected` (`.mcp.json`), `expected` (codex toml), `not-registered`.
  - `test_check_json_shape`: every `Verdict` field present.
  - `test_check_budget_usage`: `--budget 0` and `--budget 601` exit 3.
- [ ] **Step 2: Run** `uv run --project search --frozen pytest search/tests/test_check.py -q`. Expected:
  FAIL (no module).
- [ ] **Step 3: Implement** `check.py` and the verb. Text format: `Verdict.line()` first, then `mcp:
  <state>` and `launcher: <state>`. JSON: `asdict(verdict)` plus `"exit"`. Update the
  `test-spec-status-model.sh` pin to `serve init index query status eval check gate`; `gate` arrives in
  Task 5, so pin `check` now and `gate` there.
- [ ] **Step 4: Run** the pytest suite and `bash scripts/test-spec-status-model.sh`. Expected: PASS.
- [ ] **Step 5: Document** `check` in *CLI* (`references/search.md`): the verdict table, the order above
  in prose, the JSON shape, and that only `check` refreshes (`status` still never builds).
- [ ] **Step 6: Commit** `feat(search): doc-search check, the gating readiness probe`.

### Task 4: Launcher `check` and `gate` paths

**Files:**
- Modify: `scripts/search/launch.sh`
- Test: `scripts/test-hooks.sh` (stub `uv` as the existing launcher tests do)

**Interfaces:**
- Consumes: Task 3's exit codes; Task 5's `doc-search gate <event>` (by name only; the launcher just
  `exec`s it).
- Produces: `search-mcp.sh check …`, and `search-mcp.sh gate session-start|prompt|tool`.

The launcher's behavior, after the env hook:

| Case | `check` | `gate session-start` / `gate prompt` | `gate tool` |
|---|---|---|---|
| `DOC_SEARCH_GATE=0` | unchanged | exit 0, no output | exit 0, no output |
| not in a git work tree | `doc-search: not in force: not a git work tree`, exit 4 | silent, exit 0 | silent, exit 0 |
| no root | `doc-search: not in force: doc-superpowers is not installed for this developer`, exit 4 | silent, exit 0 | silent, exit 0 |
| no `uv`, raw config `"required": true` | `doc-search: not ready: uv not found (https://docs.astral.sh/uv/)`, exit 1 | prompt: block JSON with that reason; session-start: context JSON with it | normal |
| no `uv`, otherwise | `not in force: uv not found`, exit 4 | silent | normal |
| otherwise | `exec uv run … doc-search check "$@"` | `exec uv run … doc-search gate <event>` | read the verdict file; absent, or line 1 not `not-ready` → silent; else allow only the constraint's command regex (needs `jq` for `.tool_name` and `.tool_input.command`; without `jq`, deny), and deny everything else with `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"doc-search is required here and not ready: <line 2>. Stop and report this to the user; do not work around it."}}` (line 2 JSON-escaped with `jq -Rs`; without jq, a fixed reason) |

- [ ] **Step 1: Write the failing tests.** One assertion group per row above.
  - **`gate tool`:**
    - allows `sh .claude/doc-superpowers/search-mcp.sh index` and `sh "/abs/top/.claude/doc-superpowers/search-mcp.sh" status --format json`;
    - denies `… index && rm -rf x`, `… index; ls`, `rg foo`, a `Read` tool, and anything without `jq`.
  - **Subdirectory:** run from a subdirectory finds the verdict file.
  - **Outside a repository:** silent.
  - **Event input:** the event JSON is read from stdin and never echoed.
- [ ] **Step 2: Run** `bash scripts/test-hooks.sh`. Expected: the new assertions FAIL.
- [ ] **Step 3: Implement** in `launch.sh`. `gate tool` must not call `uv`.
- [ ] **Step 4: Run** `bash scripts/test-hooks.sh` (the POSIX static gate included) and `/bin/bash
  scripts/test-hooks.sh` on macOS. Expected: PASS.
- [ ] **Step 5: Commit** `feat(search): the launcher answers check and gate where doc-search cannot run`.

### Task 5: `doc-search gate`

**Files:**
- Create: `search/src/doc_search/gate.py`
- Modify: `search/src/doc_search/cli.py` (verb `gate`, positional `event` in {`session-start`, `prompt`},
  `--budget`)
- Modify: `scripts/test-spec-status-model.sh` (verb pin adds `gate`)
- Test: `search/tests/test_gate.py`

**Interfaces:**
- Consumes: `assess`, `Verdict` (Task 3).
- Produces:
  - `verdict_path(top: Path) -> Path` (`git rev-parse --git-path doc-search-gate`, resolved against `top`);
  - `write_verdict(path: Path, verdict: Verdict) -> None` (atomic; removes the file unless `not-ready`);
  - `hook_output(event: str, verdict: Verdict) -> dict | None`.

**Output, the same for Claude Code and Codex:**
- **`session-start`:** always
  `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": <text>}}`, where
  `<text>` is:
  - `doc-search: ready` or `doc-search: ready (degraded: …)`, then the `mcp:` line, for ready or degraded;
  - `doc-search is required here and not ready: <reason>. Fix: <fix>. Do no work until it is ready: tell the user this line and stop.` for not-ready;
  - nothing (no output) for not-in-force.
- **`prompt`:**
  - not-ready: `{"decision": "block", "reason": "doc-search is required here and not ready: <reason>. Run: <fix> — then send your message again. (Set DOC_SEARCH_GATE=0 to turn the gate off for yourself.)"}`;
  - otherwise no output.
- **An exception in `assess`** is a not-ready verdict with reason `check failed: <ExceptionType>: <message>`
  when the raw config says `"required": true`; otherwise no output.
- **Exit code:** always 0.

- [ ] **Step 1: Write the failing tests:**
  - `test_gate_prompt_blocks_when_not_ready` (verdict file written: line 1 `not-ready`);
  - `test_gate_prompt_silent_and_clears_when_ready`;
  - `test_gate_session_start_context_per_state`;
  - `test_gate_assess_exception_blocks_when_required`;
  - `test_gate_assess_exception_silent_when_not_required`;
  - `test_write_verdict_is_atomic`: 8 threads write alternating verdicts; every read in between parses as
    a whole verdict or no file;
  - `test_gate_reads_and_ignores_the_event_on_stdin`.
- [ ] **Step 2: Run** the pytest file. Expected: FAIL.
- [ ] **Step 3: Implement** `gate.py` and the verb. Add `gate` to the `test-spec-status-model.sh` pin.
- [ ] **Step 4: Run** pytest (the whole `search/tests`) and `bash scripts/test-spec-status-model.sh`.
  Expected: PASS.
- [ ] **Step 5: Document** `gate` in *CLI*.
- [ ] **Step 6: Commit** `feat(search): doc-search gate, the hook entry for the readiness gate`.

### Task 6: `install.sh --search-gate`

**Files:**
- Modify: `scripts/hooks/install.sh` (set constants, preflight, install, uninstall, status, `--json`
  `.tiers.search_gate`, usage text)
- Modify: `references/hooks.md` (*doc-search gate set*), `references/tool-mappings.md` (the gate row
  per client), `.codex/INSTALL.md` (a *doc-search* section: the root path, the MCP entry with `cwd`, and
  hooks needing a trusted project plus `/hooks` approval), `skills/doc-superpowers/SKILL.md` and
  `CLAUDE.md` / `AGENTS.md` (command tables)
- Test: `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: the launcher's `gate` commands (Task 4).
- Produces: the hook command strings, verbatim:
  - `sh "$(git rev-parse --show-toplevel)/.claude/doc-superpowers/search-mcp.sh" gate session-start`
  - `… gate prompt`
  - `… gate tool`

**Entries:**
- **`.claude/settings.json` `hooks`:**
  - `SessionStart`, matcher `startup|resume|clear|compact`, timeout 45;
  - `UserPromptSubmit`, timeout 45;
  - `PreToolUse`, matcher `*`, timeout 10.
- **`.codex/hooks.json`:** the same three events and timeouts. Codex's matcher for all tools is
  omitted.
- **Merging:** per event, an entry is identified by its command string. Others' entries are kept, and a
  file already holding them is not rewritten.
- **Preflight:** needs `docs/search/config.json` and the `--search` launcher installed. It refuses,
  exit 1, writing nothing.
- **Status:** `installed` / `partial` / `absent` for each file. When it finds a marked
  `doc-superpowers:search-rule` block in `AGENTS.md` or `CLAUDE.md`, it also reports `current` / `outdated`
  against `references/search-rule.md` (Task 7). Until then it reports `absent`.

- [ ] **Step 1: Write the failing tests:**
  - install into empty and pre-populated settings files (others' hooks kept);
  - idempotent re-install;
  - uninstall removes only these entries, and removes a file left as `{"hooks": {}}` or `{}`;
  - preflight refusals;
  - status lines and `--json`;
  - a symbolic link refused.
- [ ] **Step 2: Run** `bash scripts/test-hooks.sh`. Expected: FAIL.
- [ ] **Step 3: Implement**, following the `--search` set's functions (`preflight_search`,
  `install_search`, `status_search`).
- [ ] **Step 4: Run** `bash scripts/test-hooks.sh` and `/bin/bash scripts/test-hooks.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(hooks): --search-gate registers the readiness gate for Claude Code and Codex`.

### Task 7: The rule template (writing-skills, RED then GREEN)

**Files:**
- Create: `references/search-rule.md`
- Modify: `scripts/hooks/install.sh` (status: block drift), `scripts/test-hooks.sh`, `references/search.md`
  (a pointer)

**Interfaces:**
- Consumes: Task 3's verdict lines; Task 5's injected context text.
- Produces: the marked block, `<!-- doc-superpowers:search-rule vX.Y.Z -->` … `<!-- /doc-superpowers:search-rule -->`.

- [ ] **Step 1: RED is in hand.** These are the baseline transcripts (A 2/2 fail, B 2/2 fail, C correct).
  Add a no-guidance control micro-test: the template absent, the injected not-ready context present,
  5 reps.
- [ ] **Step 2: Write the template.**
  - *Use when* line.
  - The `check` exit table: 0 / 1 / 4.
  - The two predicates (`mcp: expected` with tools missing → halt; a `worktree:` mismatch → pass
    `worktree:`).
  - Degraded: say it once.
  - The halt recipe: report the verdict line and the fix, then stop. No `rg`, no CLI-as-substitute, no
    further edits.
  - A rationalization table with the baseline's verbatim excuses, and red flags.
- [ ] **Step 3: Micro-test the wording.** 5 reps each of A, B and C with the template, against the
  control. Read every flagged match.
  - Pass: A and B halt and report 5/5; C uses `rg` with a one-line reason and does not halt, 5/5.
- [ ] **Step 4: Refactor** any new rationalization into the table and re-run until it passes.
- [ ] **Step 5: Add block drift to `install.sh status --search-gate`,** with a test (current, outdated,
  absent).
- [ ] **Step 6: Commit** `docs(search): the shipped search-rule template, keyed to check`. Record the
  micro-test tallies in the commit body.

### Task 8: Release 3.10.0

**Files:** `RELEASE-NOTES.md`, the five manifests and the launcher stamp (via `bump-version`), README and
CLAUDE.md (suite counts and command lists), `docs/.doc-index.json`.

- [ ] **Step 1: Write** the `RELEASE-NOTES.md` 3.10.0 entry: the new keys, `check`, `gate`, `--search-gate`,
  the template, the Codex root, and the 3.9.0 "unknown key" behavior.
- [ ] **Step 2: Run** `bash scripts/doc-tools.sh bump-version 3.10.0`, then `bash scripts/doc-tools.sh
  check-version`. Expected: exit 0.
- [ ] **Step 3: Re-baseline the doc-index** for the changed docs, in this repository's usual way: a
  `docs(index): re-baseline …` commit.
- [ ] **Step 4: Run** `bash scripts/check-ci.sh` (every suite, pytest, self-install drift,
  `check-version`) and `bash scripts/leak-scan.sh`. Expected: all exit 0. Record the counts.
- [ ] **Step 5: Commit** `chore(release): v3.10.0`.

### Task 9: GREEN, end to end

- [ ] **Step 1: Run the hooks for real.** In a throwaway repository with
  `{"required": true, "requires": ">=3.10.0"}`, `install --search --search-gate` and
  `DOC_SUPERPOWERS_ROOT` set to this checkout:
  - feed each hook a recorded event on stdin;
  - capture block, deny and allow outputs for ready, not-ready (index absent) and not-in-force (no root).
- [ ] **Step 2: Codex.** Record what can be verified without the network: `codex --version`, and
  whether the installed `.codex/hooks.json` loads (`codex` config check, if one exists offline). State
  what was not run.
- [ ] **Step 3: Pressure scenarios.** Run A, B and C with the template plus the hook's injected context,
  5 reps each, combined pressure. Pass criteria are as in Task 7.
- [ ] **Step 4: Bundle.** Write `doc-superpowers-search-readiness.bundle` (`main..feat/search-readiness-gate`),
  its `.sha256` and the PR body in the artifacts folder. Do not push.

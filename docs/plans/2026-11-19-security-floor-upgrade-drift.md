# doc-superpowers 3.19.0: security floor, upgrade command and copy drift check, implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

For the receiving side, from the SlideCreator coordinator, 11/19. Run it in the doc-superpowers repository, not in
SlideCreator. Follow that repository's `AGENTS.md`, its test scripts and its release steps wherever this plan is silent.

**Goal:** A project that uses doc-superpowers learns, without a person noticing, when its installed release is below a
security release. A checkout install upgrades with one command. The copies a project commits are checked against the
installed release.

**Architecture:** Release notes already mark security releases with a `### Security` section under each
`## vX.Y.Z (date)` heading. A new `doc_search.releases` module parses that marker. `check` compares the installed
version against a cached copy of the newest release notes. It never fetches: only `install.sh upgrade` and a new
scheduled CI template fetch. The installer gains `upgrade`, and `status --check`, which reuses the render-and-compare
logic now private to `scripts/check-self-install.sh`.

**Tech Stack:** Python 3.11+ (doc-search, pytest), bash 3.2-compatible shell (`install.sh`, `test-hooks.sh`), git,
GitHub Actions templates (zizmor-clean).

**Spec:** no separate spec. The design is the "Decisions" section below; it came from the SlideCreator coordinator's
review of 11/19 (ADR-078 raises SlideCreator's floor to 3.18.0 by hand, and nothing told anyone 3.18.0 was a
security release).

## Decisions

1. **The marker:** a release is a security release when its `## vX.Y.Z (YYYY-MM-DD)` section holds a `### Security`
   heading before the next `## ` heading. No new file and no manifest field; old releases already follow this.
2. **The data source for `check`:** never the network. In order: the file `$DOC_SEARCH_RELEASE_NOTES` names; the
   cache `~/.cache/doc-superpowers/release-notes.md` with its sidecar `release-notes.json`
   (`{"tag": "vX.Y.Z", "fetched": "<ISO-8601 UTC>", "source": "<remote URL>"}`); otherwise the plugin's own
   `RELEASE-NOTES.md`. The plugin's own notes can never show a newer release, so a fresh install with no cache is
   never "behind".
3. **The opt-in:** a new config key `"security_floor": false` (default) in `docs/search/config.json`. With `true`,
   and the installed version below the newest security release in the data, `check` returns `not-ready`. The reason
   reads `doc-superpowers 3.18.0 is below security release 3.19.2 (release notes v3.20.0, fetched 2026-12-01)`, and
   the fix is the upgrade command. With `false`, the same finding is a `degraded` reason, never a halt.
4. **Fetching:** only `install.sh upgrade` (and `upgrade --check`) and the scheduled template fetch. They
   use `git fetch --tags` against the install's own `origin`. Fetched text is data: only the heading regexes read it,
   and nothing in it runs.
5. **Install kinds:** a Claude Code plugin install (root under `~/.claude/plugins/`) is updated by
   `claude plugin update doc-superpowers`; `upgrade` prints that and changes nothing. Any other git checkout is
   upgraded in place by `upgrade`, Codex's included.
6. **Upgrade layout:** a new detached worktree at `<parent of root>/doc-superpowers-v<version>`, from the tag. The
   old root stays, untouched. `~/.config/doc-search/env.sh` gets its `DOC_SUPERPOWERS_ROOT=` line replaced (one line;
   a `.bak` copy first; the file is created when absent). `~/.claude/skills/doc-superpowers` is relinked only when it
   is a symlink that resolves inside the old root.
7. **Drift:** a committed copy (each installed workflow, each step script, `doc-tools.sh`, the helpers, the search
   launcher) is `drifted` when its bytes differ from what `install --ci` / `install --search` would write now.

## Global Constraints

- Shell stays bash 3.2-compatible; `test-hooks.sh` runs under `/bin/bash` 3.2 and bash 5.
- doc-search keeps `requires-python = ">=3.11"`; no new runtime dependency in `search/pyproject.toml` or `uv.lock`.
- `check` makes no network call, whatever the config.
- New CI templates pass `zizmor` (pinned actions by SHA, `permissions: contents: read`, no `pull_request_target`).
- Version: this is 3.19.0 (new features). `doc-tools.sh bump-version` writes the manifests and the launcher stamp.
- Fetched release notes are untrusted data (SECURITY.md, "What is trusted"): parsed by regex only.

## Review Focus

1. **A cache from another install's remote** (a fork's notes): `check` names the cache's `source` in its reason, and
   `upgrade --check` rewrites the cache from this root's `origin`. Test: Task 2, `test_reason_names_source`.
2. **Malformed or hostile notes** (no headings, 10 MB of text, headings inside code fences, `## v99999.0.0`): the
   parser returns what it can, ignores fenced blocks, caps input at 2 MB, and never raises. Tests: Task 1.
3. **A dirty or branch-checked-out root on upgrade:** `upgrade` refuses with exit 2 and touches nothing. Test: Task 3,
   `upgrade refuses a dirty root`.
4. **`env.sh` with other settings** (`UV_PYTHON=3.14`, comments, `export` forms): only the one
   `DOC_SUPERPOWERS_ROOT` line changes, in either the `export X=` or `X=` form. Test: Task 3.
5. **A project with no install record** (`.claude/doc-superpowers/installed.json` absent, copies made by hand):
   `status --check` reports `untracked` and exits 0; drift needs a record. Test: Task 4.

---

### Task 1: Parse security releases from release notes

**Files:**
- Create: `search/src/doc_search/releases.py`
- Test: `search/tests/test_releases.py`

**Interfaces:**
- Produces:
  - `MAX_NOTES_BYTES = 2_000_000`
  - `@dataclass(frozen=True) class Release: version: tuple[int, int, int]; date: str; security: bool`
  - `parse_releases(text: str) -> list[Release]`: newest first, by version.
  - `newest_security(releases: Sequence[Release]) -> tuple[int, int, int] | None`

- [ ] **Step 1: Write the failing tests**

```python
NOTES = "# Release Notes\n\n## v3.18.0 (2026-11-18)\nx\n### Security\n- y\n\n## v3.17.1 (2026-11-18)\n### Changed\n"

def test_marks_security_release():
    rs = parse_releases(NOTES)
    assert [(r.version, r.security) for r in rs] == [((3, 18, 0), True), ((3, 17, 1), False)]

def test_newest_security():
    assert newest_security(parse_releases(NOTES)) == (3, 18, 0)

def test_fenced_headings_ignored():
    assert parse_releases("```\n## v9.9.9 (2026-01-01)\n### Security\n```\n") == []

def test_oversized_input_truncated_not_raised():
    assert parse_releases(NOTES + "z" * (MAX_NOTES_BYTES + 10))[0].version == (3, 18, 0)

def test_no_headings():
    assert parse_releases("hello") == [] and newest_security([]) is None
```

- [ ] **Step 2: Run, expect FAIL** (`ModuleNotFoundError`): `uv run --frozen pytest search/tests/test_releases.py -q`
- [ ] **Step 3: Implement** with two anchored regexes, `^## v(\d+)\.(\d+)\.(\d+) \((\d{4}-\d{2}-\d{2})\)$` and `^### Security\s*$`. Toggle a fence flag on lines starting with three backticks, truncate the input to `MAX_NOTES_BYTES` first, and reuse `config.parse_version` where it fits.
- [ ] **Step 4: Run, expect PASS** (same command).
- [ ] **Step 5: Commit** `feat(doc-search): parse security releases from release notes`

### Task 2: `check` reads the security floor

**Files:**
- Modify: `search/src/doc_search/config.py` (`DEFAULTS`, `Config`, `load_config`)
- Modify: `search/src/doc_search/check.py` (`_would_be`, a new `_security`, `_plugin_fix`)
- Create: `search/src/doc_search/release_cache.py`
- Test: `search/tests/test_check.py`, `search/tests/test_config.py`

**Interfaces:**
- Consumes: Task 1's `parse_releases`, `newest_security`.
- Produces:
  - `Config.security_floor: bool`, from the `"security_floor"` key, default `False`; a non-bool is a `ConfigError`.
  - `release_cache.cache_dir(env) -> Path`: `$XDG_CACHE_HOME/doc-superpowers`, else `~/.cache/doc-superpowers`.
  - `release_cache.load(env) -> tuple[str, dict[str, str]] | None`: the notes text and sidecar, in Decision 2's order.
  - `release_cache.store(env, text: str, tag: str, source: str) -> None`: atomic write of both files.
  - `UPGRADE_FIX = "bash <root>/scripts/hooks/install.sh upgrade"` (rendered with `shlex.quote(str(plugin_root()))`).

- [ ] **Step 1: Write the failing tests** in `test_check.py`, with a fake cache through `DOC_SEARCH_RELEASE_NOTES` and a sidecar:
  - `test_below_security_release_halts_when_opted_in`: config `required: true, security_floor: true`, plugin 3.18.0, notes with a `v3.19.0` security section. Expect `state == "not-ready"`, `"below security release 3.19.0" in reason`, and the fix ends with `install.sh upgrade` for a checkout root.
  - `test_below_security_release_degrades_when_not_opted_in`: same data with `security_floor` absent. Expect `state == "degraded"`.
  - `test_no_cache_never_behind`: no env var and an empty cache dir. Expect no security reason.
  - `test_reason_names_source`: the sidecar's `source` and `fetched` both appear in the reason.
  - `test_check_never_fetches`: monkeypatch `subprocess.run` and `socket.create_connection` to raise. `assess` still returns.
  - In `test_config.py`: `test_security_floor_must_be_bool` (`"yes"` raises `ConfigError`).
- [ ] **Step 2: Run, expect FAIL:** `uv run --frozen pytest search/tests/test_check.py search/tests/test_config.py -q`
- [ ] **Step 3: Implement.** Evaluate the security finding in `_would_be` right after the `requires` floor test, so it ranks with the floor. Put `not-ready` with `UPGRADE_FIX` when `cfg.security_floor`, else prepend the reason to `degraded`. `_plugin_fix` returns `UPGRADE_FIX` for any root that is not under `~/.claude/plugins/`, and keeps `PLUGIN_FIX` for plugin installs. Update the module docstring's row list (row 3b).
- [ ] **Step 4: Run, expect PASS**, then the whole doc-search suite: `uv run --frozen pytest search/tests -q` (903 passed today, plus the new tests).
- [ ] **Step 5: Commit** `feat(doc-search): check halts below a security release when security_floor is on`

### Task 3: `install.sh upgrade`

**Files:**
- Modify: `scripts/hooks/install.sh` (verb dispatch near `install)` / `status)`, `usage()`, flag parsing for `--to`, `--check`)
- Modify: `scripts/search/launch.sh:439` (the not-found message)
- Modify: `README.md` (new section "Installing without a plugin marketplace")
- Test: `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: Task 2's cache files (written here in the same format: notes plus sidecar).
- Produces: `install.sh upgrade [--to vX.Y.Z] [--check] [--json]`. Exit codes: 0 done or already current; 1 behind (`--check` only); 2 refused (dirty root, plugin install, older `--to` without `--force`, unknown tag).

- [ ] **Step 1: Write the failing tests** in `test-hooks.sh`, against a local bare "origin" holding tags `v3.18.0` and `v3.19.0` (the second with a `### Security` section):
  - `upgrade --check` from a v3.18.0 worktree prints `installed 3.18.0`, `latest 3.19.0` and `newest security 3.19.0`, exits 1, and writes the cache and sidecar with `tag` `v3.19.0`.
  - `upgrade` creates `<parent>/doc-superpowers-v3.19.0` detached at the tag and leaves the old root's files byte-identical.
  - `upgrade` rewrites only the `DOC_SUPERPOWERS_ROOT` line of an `env.sh` that also holds `UV_PYTHON=3.14`, a comment and an `export` line, and leaves `env.sh.bak` behind.
  - `upgrade` relinks a skill symlink that points inside the old root, and leaves one that points elsewhere alone.
  - `upgrade refuses a dirty root`: an untracked file in the root gives exit 2 and no new worktree.
  - From a root under a fake `$HOME/.claude/plugins/`, `upgrade` prints `claude plugin update doc-superpowers` and exits 2.
  - `--to v3.17.0` from 3.18.0 exits 2 without `--force`.
- [ ] **Step 2: Run, expect FAIL:** `bash scripts/test-hooks.sh` (the new cases fail; the 4423 existing ones pass).
- [ ] **Step 3: Implement** the verb on Decisions 4 to 6: `git -C "$ROOT" fetch --quiet --tags origin`. The newest tag comes from `git tag --list 'v[0-9]*' | sort -t. -k1,1 -k2,2n -k3,3n` (bash 3.2 has no `sort -V` on macOS). Read the notes with `git show <tag>:RELEASE-NOTES.md`, then `git worktree add --detach`. Change the launcher's message to `cannot find doc-superpowers: set DOC_SUPERPOWERS_ROOT in ~/.config/doc-search/env.sh to a release checkout (git clone --branch v<floor> <url>), or install the plugin`. Here `<floor>` comes from the project's `requires`, and `<url>` is the README's install URL.
- [ ] **Step 4: Run, expect PASS** under both shells: `bash scripts/test-hooks.sh && /bin/bash scripts/test-hooks.sh`.
- [ ] **Step 5: Commit** `feat(hooks): upgrade a checkout install to a release tag`

### Task 4: `install.sh status --check` reports drifted copies

**Files:**
- Modify: `scripts/hooks/install.sh` (`status_ci`, `status_search`, `status_json`, a new `expected_copy`)
- Modify: `scripts/check-self-install.sh` (call `expected_copy` instead of its own render code)
- Test: `scripts/test-hooks.sh`

**Interfaces:**
- Produces:
  - `expected_copy <project-relative path> <out file>`: writes the bytes `install` would write today, using the recorded choices in `.claude/doc-superpowers/installed.json` (the `render_workflow` substitutions).
  - `status --check [--ci] [--search] [--json]`: new per-file state `drifted`; the JSON object gains `"drift": [<path>, ...]`. Exit 1 when any file is `drifted` or `recorded-missing`, else 0. `untracked` (no install record) is exit 0.

- [ ] **Step 1: Write the failing tests:**
  - After `install --ci --search` into a temp project, `status --check --ci --search` exits 0.
  - Append a byte to `.github/scripts/doc-tools.sh`: exit 1, and the output names that path as `drifted`.
  - Change the launcher's stamp line: exit 1, with the launcher path `drifted`.
  - `--json` lists both paths under `drift`.
  - With no `installed.json`: exit 0, state `untracked`.
  - `bash scripts/check-self-install.sh` still exits 0 on this repository.
- [ ] **Step 2: Run, expect FAIL:** `bash scripts/test-hooks.sh`
- [ ] **Step 3: Implement** by moving the render and compare logic out of `check-self-install.sh` into `expected_copy`, so both callers share one copy. Then have `status_ci` and `status_search` compare with `cmp -s`.
- [ ] **Step 4: Run, expect PASS** under both shells, plus `bash scripts/check-self-install.sh` (exit 0).
- [ ] **Step 5: Commit** `feat(hooks): status --check reports copies that drifted from the installed release`

### Task 5: Scheduled security check template for projects

**Files:**
- Create: `scripts/hooks/ci/doc-security-schedule.yml`
- Create: `scripts/hooks/ci/doc-superpowers-steps/security-floor.sh`
- Modify: `scripts/hooks/install.sh` (register the template as opt-in via `--workflows doc-security-schedule`; not part of the default set)
- Test: `scripts/test-hooks.sh`

**Interfaces:**
- Consumes: Task 1's marker rule, re-implemented in the step with `awk`. The step stays shell and `jq` only, as the other steps are.
- Produces: `security-floor.sh <release-notes file> <docs/search/config.json>`. It prints `::error::` and exits 1 when `requires` is below the newest security release, and exits 0 otherwise. It reads `requires` with `jq -r .requires`.

- [ ] **Step 1: Write the failing tests:**
  - With `requires: ">=3.18.0"` and notes with a security 3.19.0: exit 1, and the message names both versions.
  - With `requires: ">=3.19.0"`: exit 0.
  - A `### Security` inside a code fence doesn't count.
  - With no `requires`: exit 0, and a warning line.
- [ ] **Step 2: Run, expect FAIL:** `bash scripts/test-hooks.sh`
- [ ] **Step 3: Implement** a weekly template (`schedule: cron`, plus `workflow_dispatch`) that checks out the project, then shallow-fetches the doc-superpowers repository at its newest tag (`git ls-remote --tags`). The URL comes from the installer's recorded `--marketplace-url`, else the README's URL. Then run the step. Pin actions by SHA, set `permissions: contents: read`, and use no secrets.
- [ ] **Step 4: Run, expect PASS**, plus `bash scripts/check-ci.sh zizmor` (exit 0).
- [ ] **Step 5: Commit** `feat(ci): opt-in weekly check that requires meets the newest security release`

### Task 6: Document and release 3.19.0

**Files:**
- Modify: `RELEASE-NOTES.md` (`## v3.19.0 (<date>)`: Added, Upgrading from 3.18.x, Other with the run counts)
- Modify: `SECURITY.md` ("Supported versions": a release with a `### Security` section is a security release; projects opt in with `security_floor`)
- Modify: `README.md` (config key `security_floor`; `upgrade`; `status --check`)
- Modify: the manifests via `doc-tools.sh bump-version 3.19.0`

- [ ] **Step 1:** `bash scripts/doc-tools.sh bump-version 3.19.0`, then confirm `check-version` exits 0.
- [ ] **Step 2:** Write the notes and docs above. Every claim names its test or command.
- [ ] **Step 3:** Run the full set: `bash scripts/check-ci.sh` (not `--fast`: zizmor, dep-audit, gitleaks, self-install, check-version, tag in warn mode) and every `scripts/test-*.sh` under both shells. Record each count and exit code in the notes' "Other".
- [ ] **Step 4:** Commit `release: v3.19.0`, tag `v3.19.0`, push the branch and the tag. Releasing and pushing are the developer's own steps.

## After 3.19.0: SlideCreator's side (separate PRs there, not part of this plan)

- Raise `requires` to `>=3.19.0` and set `"security_floor": true` in `docs/search/config.json`, with an ADR-078
  follow-up (or fold into ADR-078 if it is still Proposed).
- Replace the launcher copy (`install.sh install --search`) and the CI copies (`install --ci`).
- Add a test that runs `install.sh status --check --ci --search` from `DOC_SUPERPOWERS_ROOT`, skipped where the plugin
  is absent, as the launcher-hash test is.
- Install the opt-in template: `install --ci --workflows doc-security-schedule`.
- AGENTS.md and `.claude/rules/code-and-doc-search.md`: the fix for a below-floor halt becomes
  `bash "$DOC_SUPERPOWERS_ROOT/scripts/hooks/install.sh" upgrade` or `claude plugin update doc-superpowers`.

## Not in this plan

- Signed tags and an installer that verifies them (`git tag -v v3.18.0` exited 1 on the sending side; unsigned tag or
  no key, not checked).
- A GitHub Security Advisory per fixed alert, which is a repository setting, not code.
- Shipping the CI tier as a pinned action instead of copies (it would reverse the copy-by-name design).

---

## Amendments (plan review, 2026-11-19): these override the text above where they conflict

The review ran against HEAD bdcd3751 (v3.18.0) and was checked by the executing session. File:line references are at that HEAD.

### Task order and chunks

Tasks now run in this order: **1 → 3 → 2 → 4 → 5 → 6**. Task 2's `UPGRADE_FIX` names the verb Task 3 adds, and Task 3 writes the cache that Task 2 reads. Tasks 3, 4 and 5 all edit `install.sh`, so they run strictly one after another, and Task 4 extends Task 3's flag parser (`allowed()`).

### Decision changes

- **D2 (data source, C3):** add a fourth offline source, `~/.claude/plugins/marketplaces/<mkt>/RELEASE-NOTES.md`. Claude Code keeps that git clone fresh on its own. `check` takes the newest release across all sources. On a plugin install, `upgrade --check` fetches and writes the cache before it prints the `claude plugin update doc-superpowers` line. Plugin cache copies have no `.git`.
- **D5/D6 (install kinds, C1):** a Codex root (`~/.codex/doc-superpowers`, recognised as in `check.py:295-303` and `launch.sh:234-247`) upgrades in place. It must be clean (`git status --porcelain`, so ignored files such as `search/.venv` don't count), and then gets `git -C <root> checkout --detach <tag>`. A clean branch checkout is allowed there. The sibling-worktree layout applies only to a root reached through `DOC_SUPERPOWERS_ROOT`. The README notes that a linked worktree depends on the old root's `.git`.
- **D4 (tags, C2):** filter tag names with `grep -xE 'v[0-9]+\.[0-9]+\.[0-9]+'`, strip the `v`, and sort with `-t. -k1,1n -k2,2n -k3,3n` (as `launch.sh:432` does). Write the `env.sh` value through `sh_squote` (`install.sh:502`). The tag's own `RELEASE-NOTES.md` first heading must equal the tag (the `_check_version_tag` rule, `doc-tools.sh:6825-6845`). Tests cover a hostile tag name (`v3.20.0;touch pwned`) and `v10` ordering.

### Task 1 (I8, M2)

The Python fence rule matches `_AWK_FENCE` (`doc-tools.sh:7426`): both fence characters (backtick and tilde) and fence lengths. Read files with `read(MAX_NOTES_BYTES + 1)` and cut on a line boundary; never read the whole file and then truncate. Add a shared fixture (for example `search/tests/fixtures/release-notes-security.md`) that Task 5's shell test reads too.

### Task 2 (I1, I2, I3, M2)

- `_plugin_fix` and `launch.sh`'s `plugin_fix` (`:234-247`, comment `:79-83`) change in the same commit, with `test_check.py:276,:293`, `test_gate.py`, the `test-hooks.sh` asserts and `references/search.md:178`. Detect a plugin install with `${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}` (`launch.sh:420`).
- Tests use a fake plugin root (as `test_check.py:280-287` does), never the real one; it becomes 3.19.0 at Task 6. The degraded test runs `run("index")` first. The never-fetches test guards socket connects and refuses only the git verbs that reach the network (`fetch`, `ls-remote`, `pull`, `clone`); `repo.py:41` uses `subprocess.run` for local git. In the degraded path the fix is `UPGRADE_FIX` (not the `check.py:199` `install --search` fix).
- Add `"security_floor"` to `INIT_OMITS` (`cli.py:277`) so `init` and `scripts/setup/search-config.json` don't write it. Document it in the `references/search.md:99` table on the `requires` precedent, and say that the halt applies only with `required: true` (`check.py:134`).
- Validate the sidecar fields: `tag` against `^v\d+\.\d+\.\d+$`, `fetched` against ISO-8601 UTC, and `source` against the `valid_marketplace_url` character set (`install.sh:2407`). A field that fails shows as `unknown`. Strip control and ANSI characters from anything put in a reason. Refuse a cache dir that is a symlink or that the user doesn't own.

- (Chunk 1 review follow-up) Whatever source `check` reads, drop any security version above the source's own newest release heading (for the cache, the sidecar `tag`), as `install.sh`'s `upg_scan` does: a release is never newer than the notes that carry it. Clamp in `releases.newest_security` (add an optional `ceiling`) or in the caller, and test it with a hostile `## v99999.0.0` plus `### Security`.

### Task 3 (I4, M3)

- Dispatch `upgrade` before `enter_repo` (`install.sh:3194`, `:3342`), as `print-merge-driver` is. Give `allowed()` (`:3235`) `upgrade:` entries. `--force` is valid with `upgrade`.
- Exit codes: 0 current or done · 1 behind (`--check`) · 2 usage · 3 refused (dirty, plugin install, older `--to` without `--force`, an existing target dir, an `env.sh` with more than one `DOC_SUPERPOWERS_ROOT` assignment) · 4 fetch failed.
- Honour `DOC_SEARCH_ENV_FILE` and `XDG_CONFIG_HOME` (`launch.sh:372`).
- Launcher message: update the asserts at `test-hooks.sh:6245,:7633`, `references/search.md:412` and the similar message in `setup/shim.sh:44`. `ROOT` is empty at that point, so the URL is a literal. Read `<floor>` without jq, and drop it when `requires` is null.

### Task 4 (I5, I6)

- `ci.workflows.<name>.state` keeps its existing values (`scripts/setup/lib-probe.sh:602`). `--check` adds a `drift` list. The launcher reuses its existing `outdated` state (`install.sh:1949-1956`), and its compare needs no install record (the search tier is never recorded).
- `expected_copy` reads `DOC_SUPERPOWERS_COMMIT` from the committed file (as `check-self-install.sh:84` does), never `ci_plugin_commit`'s `ls-remote`.
- **Do not refactor `check-self-install.sh`.** Add a `test-hooks.sh` case in which both it and `status --check` exit 0 on this repo and 1 on a mutated copy.
- Document that `--check` departs from the "always exit 0" contract of `status --json` (`references/hooks.md:93`).

### Task 5 (I7, I8)

- Register the template in `SHELL_OPTIN_WORKFLOWS` (`install.sh:72`), `workflow_desc`, `scripts/setup/catalog.json` (`ci.workflows` options and `option_details`), the `test_setup_catalog` count (`test-hooks.sh:9245`), `help/ci.txt`, the `hooks.md` workflow table and the README. `--workflows=all` now includes it.
- The marker parser is `doc-tools.sh tools security-floor` (a new verb built on `_AWK_FENCE`). The step script calls the vendored `doc-tools.sh` and reuses `install-jq.sh`. The workflow fetches only `RELEASE-NOTES.md` (`fetch --depth 1` plus `git show`) and never runs anything it fetched. Re-render the self-installed tier (`install.sh install --ci`) because `doc-tools.sh` changed.
- (Chunk 1 review follow-up) Replace `install.sh`'s own copy of the parser (`_UPG_NOTES_AWK`, Task 3) by running the new verb, `"$BASH" "$DOC_TOOLS" tools security-floor …`, as `install.sh` already runs `tools version`. Keep the shared-fixture parity test (`bf67871a`) passing.

### Task 6 (I10, M1, M4)

- 3.19.0's notes carry **no** `### Security` section. Add a Conventions line to `CLAUDE.md`: `### Security` is only for a fix users must upgrade for. v3.13.0 used it for a docs-only change, so an opted-in project would have treated it as a forced floor.
- Test commands: `(cd search && uv run --project . --frozen --all-extras pytest -q …)`. The baseline is 905 collected, 903 passed and 2 live tests skipped.
- Update the CLAUDE.md test counts (they are kept only there), the directory map and key-files table (`releases.py`, `release_cache.py`, the new template and step script), the command tables in AGENTS.md and CLAUDE.md, `help/hooks.txt` (`upgrade`, `status --check`; at most 50 lines) and `help/search.txt` (`security_floor`).

# Writing engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship step 1 of the writing rule: the lint, the anchor check, their configuration, the `doc-tools.sh writing` verbs, the rule block, the reference page and the help topic, as release 3.13.0.

**Architecture:** Four standard-library Python files in `scripts/writing/`, run by `python3 -I -B -X utf8` and dispatched by `doc-tools.sh writing <verb>`. The source lint is ported behavior for behavior, with configuration replacing its fixed paths. Nothing calls the verbs by default yet; steps 2 to 4 of the design do that.

**Tech Stack:** Python 3.9+ (standard library only), stdlib `unittest`, bash 3.2, jq 1.6.

**Spec:** `docs/superpowers/specs/2026-11-03-writing-rule-design.md` (sections *The engine*, *The behaviors kept from the source*, *Fixes made in the move*, *Registers and configuration*, *The rule and its reference*, and *Order* step 1).

**Source:** the sibling project's writing lint, anchor check, code checker and code list, with their three test files. They are handed to the implementer outside the repository and never committed.

## Global Constraints

- **Nothing from the source project** in any file, commit message or GitHub text: no name, example text, code, path or measurement.
- Every test fixture and doc example is invented; grep each diff before committing.
- Python floor **3.9**, standard library only: no `match`, no `tomllib`, no 3.10+ API.
- Keep `from __future__ import annotations` in every file.
- Every Python run is `python3 -I -B -X utf8` (no bytecode beside the scripts; UTF-8 output on any locale).
- Tests use stdlib `unittest`, not pytest: the locked pytest (9.1.1) needs Python 3.10, and the floor is 3.9. This replaces the design's "pytest in a small locked dev project".
- Shell code: bash 3.2 and jq 1.6, as the static gates in `test-doc-tools.sh` enforce.
- Exit codes of every `writing` verb: 0 clean, 1 findings, 2 a usage error or a file, base or config that cannot be read, 3 could not run (no python3 3.9+).
- The counting version starts at **1**.
- Register limits: terse 35 words a sentence, 50 a list item, 2 sentences an item; full 40 words a sentence, no item limit.
- Versions are never edited by hand: `scripts/doc-tools.sh bump-version 3.13.0`.
- Plans and commit bodies follow the writing rule; lint this plan's successors with the verbs once Task 7 lands.

## Review Focus

1. **CRLF line endings or a byte-order mark:** linted as the same text with LF and no mark; the mark is not a word. Test in Task 3.
2. **A file that is not UTF-8:** exit 2 with `cannot read <path>: not UTF-8`, never a traceback. Test in Task 3.
3. **A path with a space or a non-ASCII letter in range mode:** linted under its real name, since git quotes such names without `-z`. Test in Task 4.
4. **A base git cannot resolve, as in a shallow clone:** exit 2 naming the base. Test in Task 4.
5. **A malformed `docs/writing/config.json`** (bad JSON, an unknown key, a pattern that does not compile): exit 2 naming the key, never a traceback. Test in Task 2.

---

### Task 1: Shared Markdown parser and the test harness

**Files:**
- Create: `scripts/writing/markdown.py`
- Create: `scripts/writing/tests/support.py`
- Create: `scripts/writing/tests/test_markdown.py`
- Modify: `scripts/check-ci.sh` (a `writing` check), `.github/workflows/tests.yml` (a step per leg)

**Interfaces:**
- Produces, in `markdown.py`:
  - `class Codes(NamedTuple)`: `patterns: tuple[re.Pattern, ...]`, `allowed: frozenset[str]`, `gloss_chars: frozenset[str]`.
  - `prose_lines(text: str) -> Iterator[tuple[int, str]]`: 1-based line numbers; skips fences (any indent), headings, table rows and link targets as the source's `_prose_lines` does.
  - `paragraphs(lines: list[tuple[int, str]]) -> Iterator[list[tuple[int, str]]]`.
  - `bare_spans(line: str, codes: Codes) -> list[tuple[int, int]]` and `path_spans(text: str) -> list[tuple[int, int]]`: the one file-path rule (a token with a `/` that ends in `/` or has an extension).
  - `bare_codes(text: str, codes: Codes) -> list[str]`.
  - `unquote(line: str) -> tuple[int, str]`.
- Produces, in `tests/support.py`:
  - `load(name: str) -> ModuleType`: imports a sibling of `tests/` by name, with `scripts/writing/` first on `sys.path`.
  - `git_repo() -> ContextManager[Path]`: a temporary repository with `GIT_CONFIG_GLOBAL=/dev/null`, a private `HOME`, and a user name and email.
  - `commit(repo: Path, files: dict[str, str], message: str) -> str`: returns the commit id.
  - `DEFAULT_CODES: Codes`: the source's four patterns, until Task 2 replaces it with the defaults file.

- [ ] **Step 1: Write the failing tests:** port the source's decision-lint parser tests into `test_markdown.py`, as `unittest.TestCase` methods of the same names (about 24).
  - Port the bare-code, gloss, allowed-word, overlap, issue-number, file-path, fence, link-target, wrapped-line, blockquote and paragraph-boundary tests.
  - Leave out every test of decisions, recommendations, rulings, the canvas, node and the reference example.
  - Invent every fixture, with made-up codes such as an orbit record (ORB-12).
- [ ] **Step 2: Run them to see them fail.**
  Run: `python3 -I -B -X utf8 -m unittest discover -s scripts/writing/tests -t scripts/writing`
  Expected: errors, `No module named 'markdown'`.
- [ ] **Step 3: Implement `markdown.py`** by porting the parser half of the source's decision lint, taking `Codes` as an argument instead of loading a JSON file at import.
- [ ] **Step 4: Run the tests to see them pass**, under `python3` and under `/usr/bin/python3` (3.9.6 on macOS). Expected: `OK` under both.
- [ ] **Step 5: Add the `writing` check to `check-ci.sh`:**
  - It runs the Step 2 command under each distinct interpreter it finds: `python3` on `PATH`, and `/usr/bin/python3` when present. It prints each one's version.
  - `DOC_SP_REQUIRE_FLOOR_PYTHON=1` fails the check unless one run was on 3.9.
  - `--fast` includes it.
  - `tests.yml` gets a `writing` step on both legs, with `DOC_SP_REQUIRE_FLOOR_PYTHON: "1"` on the macOS leg only.
- [ ] **Step 6: Verify:** `bash scripts/check-ci.sh writing` prints both interpreters and passes; `bash scripts/check-ci.sh self-install` still passes.
- [ ] **Step 7: Commit:** `feat(writing): shared Markdown parser, unittest harness and the writing check`.

### Task 2: Configuration and registers

**Files:**
- Create: `scripts/writing/defaults.json`, `scripts/writing/config.py`
- Test: `scripts/writing/tests/test_config.py`

**Interfaces:**
- Consumes: `Codes` from Task 1.
- Produces, in `config.py`:
  - `class Config(NamedTuple)`: `enabled: bool`, `codes: Codes`, `limits: dict[str, Limits]`, `skip_prefixes: tuple[str, ...]`, `skip_blocks: tuple[str, ...]`, `doc_types: dict[str, str]`, `paths: tuple[PathRule, ...]`, `counting_version: int`.
  - `class Limits(NamedTuple)`: `sentence: int`, `item: int | None`, `item_sentences: int | None`.
  - `class PathRule(NamedTuple)`: `prefix: str`, `suffix: str`, `register: str | None`.
  - `class Malformed(ValueError)`.
  - `load(root: Path, rev: str | None = None) -> Config`: reads `defaults.json` beside the module, then `docs/writing/config.json` from the working tree (`rev=None`) or from `git show <rev>:` and merges it key by key. Adds the ledger patterns when `docs/ledger/config.json` exists.
  - `register_for(path: str, config: Config, index: dict | None) -> str | None`: the doc-index `doc_type` first, then the path rules, then `None`.
  - `is_record(path: str, index: dict | None) -> bool`: `doc_type` in plan, issue, audit, design-spec, or a path under `docs/archive/`.
  - `read_index(root: Path, rev: str | None) -> dict | None`: the `docs` object of `docs/.doc-index.json`, or `None` when there is none.
  - `COUNTING_VERSION = 1`.

`defaults.json` holds exactly:
- `enabled`: true.
- `limits`: the values in *Global Constraints*.
- `codes.patterns`: the source's first, second and fourth patterns unchanged, and its provisional-key pattern widened to `(?<![A-Za-z0-9_])[a-z0-9][a-z0-9-]{0,15}-~[0-9a-f]{4,8}(?![A-Za-z0-9_])`.
- `codes.allowed`: the source's list plus the diagram model's name (C4).
- `codes.gloss_chars`: the source's list.
- `skip_prefixes`: `Ledger-Claims:`, `Co-Authored-By:`.
- `skip_blocks`: `Implementation:`, `Realized-by:`. The header, its `- ` items and their indented wraps are skipped, and the two headers are not in `skip_prefixes`.
- `doc_types`: plan, issue and audit → terse; design-spec, spec, adr and the living types → full.
- `paths`, in order: `docs/archive/` → none; `AGENTS.md` and `CLAUDE.md` by name → terse; `docs/plans/` with suffix `-design.md` → full; `docs/plans/` and `docs/issues/` → terse; `docs/` → full.

An unknown `doc_type` in the index is full. The ledger patterns come from `docs/ledger/ledgers.json` `.ledgers[].id`: `(?<![A-Za-z0-9_])(?:<ids, escaped>)-[1-9][0-9]*(?![A-Za-z0-9_])`. The ledger items folder (`items.dir` in the ledger config, default `docs/issues/`) is terse.

- [ ] **Step 1: Write the failing tests** in `test_config.py`:
  - `test_defaults_alone_give_the_documented_limits`: `load(empty repo).limits["terse"] == Limits(35, 50, 2)`.
  - `test_a_project_file_overrides_key_by_key`: a config setting only `limits.full.sentence = 30` keeps the terse limits.
  - `test_doc_type_wins_over_path`: an index entry `docs/notes/x.md` typed `plan` is terse.
  - `test_an_unknown_doc_type_is_full` and `test_markdown_outside_the_paths_is_not_linted` (`README.md` → `None`).
  - `test_records_are_plan_issue_audit_design_spec_and_archive`.
  - `test_ledger_ids_become_code_patterns`: with a ledger `orbit`, `bare_codes("see orbit-14", codes) == ["orbit-14"]`.
  - `test_enabled_false_is_read`.
  - Review Focus 5: `test_malformed_config_names_the_key` for bad JSON, an unknown top-level key, and an uncompilable pattern; each raises `Malformed` whose message names the file and the key.
- [ ] **Step 2: Run them to see them fail.** Expected: `No module named 'config'`.
- [ ] **Step 3: Implement** `defaults.json` and `config.py` as specified. Replace `support.DEFAULT_CODES` with `config.load(...)` from the defaults.
- [ ] **Step 4: Run all tests to see them pass** under both interpreters.
- [ ] **Step 5: Commit:** `feat(writing): configuration, registers by doc type and path, ledger key patterns`.

### Task 3: The whole-file lint

**Files:**
- Create: `scripts/writing/lint.py`
- Test: `scripts/writing/tests/test_lint_check.py`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces, in `lint.py`:
  - `class Finding(NamedTuple)`: `path`, `line`, `rule`, `message`, `paragraph_first_line`, `paragraph_last_line`, as the source's.
  - `lint_text(text: str, path: str, register: str, config: Config, *, github: bool = False) -> list[Finding]`.
  - `identifier_density(text: str) -> float`.
  - `main(argv: list[str] | None = None) -> int`, with subcommands `check`, `range`, `ceilings` and `counts`.
  - `check [--profile terse|full] [--github] [--format text|json] [--name LABEL] FILE...|-`. Without `--profile`, each file's register comes from `register_for`.
  - A file with no register prints `<path>: not linted (no register)` on stderr and is not a finding.
  - The entry point wraps `main` so an uncaught exception prints `writing: internal error: <type>: <message>` on stderr and exits 2.
  - `lint.py` puts its own directory first on `sys.path`, since `-I` leaves it out.

- [ ] **Step 1: Write the failing tests:** port every whole-file test of the source's writing-lint suite into `test_lint_check.py`, with the same names and invented fixtures.
  - They cover behaviors 1 and 8 to 12 of the design; range and ceilings tests wait for Tasks 4 and 5.
  - The two pull-request-body tests keep their names, with invented bodies that fail the same way.
  - Add these:
  - `test_stdin_is_read_with_its_label`: `check --profile terse --name body.md -` on piped text reports `body.md:<line>`. Stdin needs `--profile`, since a body has no path to find a register by.
  - `test_a_crash_exits_2_not_1`: patch `lint_text` to raise; exit 2 and `internal error` on stderr.
  - `test_tool_written_lines_are_skipped`: a `Realized-by:` block holding a bare code is no finding.
  - Review Focus 1: `test_crlf_and_a_byte_order_mark_lint_as_lf` (same findings and lines as the LF text).
  - Review Focus 2: `test_a_file_that_is_not_utf8_exits_2` (`cannot read <path>: not UTF-8`).
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** by porting the source's text half: sentence spans, defined codes, item and sentence limits from `Config.limits`, density, and the injected-task skip, kept until step 2 of the design. Read files as UTF-8 with `utf-8-sig`, and normalize CRLF.
- [ ] **Step 4: Run all tests to see them pass** under both interpreters.
- [ ] **Step 5: Commit:** `feat(writing): whole-file lint with stdin, JSON output and a crash exit of 2`.

### Task 4: Range mode

**Files:**
- Modify: `scripts/writing/lint.py`
- Test: `scripts/writing/tests/test_lint_range.py`

**Interfaces:**
- Produces: `lint_range(root: Path, base: str, config: Config) -> list[Finding]`, and `range BASE...HEAD [--format text|json]`.
- Each file's register comes from `register_for`, with the index and config read at `HEAD`.
- Any head other than `HEAD` is a usage error (exit 2).

- [ ] **Step 1: Write the failing tests:** port every range-mode test of the source suite, with the same names and invented fixtures built by `support.git_repo` and `support.commit`.
  - They cover behaviors 2 to 7.
  - Add these:
  - `test_a_record_is_linted_in_range_mode`: a new sentence in a `plan`-typed doc is a finding.
  - Review Focus 3: `test_a_path_with_a_space_or_accent_is_linted_under_its_name` (`docs/a b/café.md`).
  - Review Focus 4: `test_an_unknown_base_exits_2_naming_it`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** by porting the source's git half: merge base, renames and deletions with `-z`, moved text, the closest base sentence at a ratio of 0.6, and `_edit_adds`.
- [ ] **Step 4: Run all tests to see them pass** under both interpreters.
- [ ] **Step 5: Commit:** `feat(writing): range mode over the sentences a branch adds`.

### Task 5: Ceilings, counts and the counting version

**Files:**
- Modify: `scripts/writing/lint.py`
- Create: `scripts/writing/tests/corpus/` (four invented files: two terse, two full)
- Test: `scripts/writing/tests/test_ceilings.py`

**Interfaces:**
- Produces:
  - `ceilings [--file PATH] [--base REF] [--update]`; the file defaults to `docs/writing/ceilings.json`.
  - The ceilings format: `{"counting_version": <int>, "paths": {"<file or folder>": <count>}}`.
  - Without `--update` it counts at the committed `HEAD`. `--update` counts the working tree and rewrites the file with `COUNTING_VERSION`.
  - `counts [PATH...] [--format text|json]`, whose JSON is `{"counting_version": 1, "folders": [{"folder": "<dir>", "register": "terse|full", "files": <n>, "findings": <n>}], "records_skipped": <n>}`.
  - `counts` reads `git ls-files -co --exclude-standard -z` under the given paths, by default the top level. It leaves out records and files with no register.
  - Folders are sorted by path.

The rules, from the design: a count above or below its ceiling fails. A ceiling may only fall, and a path may not be dropped, unless the range changes `docs/writing/config.json` or changes `counting_version` to `COUNTING_VERSION`. A recorded version that differs from `COUNTING_VERSION` exits 1 with `writing ceilings: counted with version <n>; this engine counts with <m>: run writing ceilings --update`. A folder skips records; a ceiling that names a record file fails with `<path> is a record; records take no ceiling`. A path new since the base must name a file the lint reads.

- [ ] **Step 1: Write the failing tests:** port every ceilings test of the source suite, with invented fixtures.
  - Its page-ceiling test becomes `test_ceiling_values_parse_as_whole_numbers`.
  - Add these:
  - `test_a_version_bump_in_the_range_allows_a_raise`.
  - `test_a_hand_edited_version_that_is_not_the_engines_does_not_allow_a_raise`.
  - `test_a_stale_counting_version_exits_1_with_the_update_line`.
  - `test_update_records_the_working_tree_counts_and_the_version`.
  - `test_a_record_file_takes_no_ceiling`.
  - `test_counts_groups_by_folder_and_register_and_skips_records`.
  - `test_the_corpus_counts_match_the_counting_version`: `counts` over `tests/corpus/` equals `EXPECTED[COUNTING_VERSION]`. The comment above `EXPECTED` says: a change that moves these counts adds a new version entry and raises `COUNTING_VERSION`; an existing entry never changes.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** by porting the source's ceilings half, with the exemption keyed on the config file and the counting version instead of the source's file list.
- [ ] **Step 4: Run all tests to see them pass** under both interpreters.
- [ ] **Step 5: Commit:** `feat(writing): ceilings keyed on a counting version, and counts per folder`.

### Task 6: The anchor check

**Files:**
- Create: `scripts/writing/anchors.py`
- Test: `scripts/writing/tests/test_anchors.py`

**Interfaces:**
- Consumes: `markdown.py`, and `config.load` for the code patterns.
- Produces: `anchors.py --base REF [--format text|json] FILE...` with the source's exit codes, and `missing(before: str, after: str, codes: Codes) -> list[Loss]` and `unresolved(before: str, after: str, folder: Path) -> list[Anchor]`.

- [ ] **Step 1: Write the failing tests:** port all 15 anchor tests, with the same names and invented fixtures.
  - They cover behavior 14, including the backtick span wrapped across lines.
  - Add `test_a_crash_exits_2_not_1`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement** by porting the source's anchor check, loading codes through `config.load` instead of the source's lint.
- [ ] **Step 4: Run all tests to see them pass** under both interpreters.
- [ ] **Step 5: Commit:** `feat(writing): the anchor check for rewrites`.

### Task 7: The `doc-tools.sh writing` verbs

**Files:**
- Modify: `scripts/doc-tools.sh` (five rows in `_VERBS`, `_main`, a `_writing_run` function)
- Test: `scripts/test-doc-tools.sh`

**Interfaces:**
- Consumes: the Python command lines of Tasks 3 to 6.
- Produces:
  - Verbs `writing check`, `writing range`, `writing ceilings`, `writing counts`, `writing anchors`, each with `needs` set to `none` and a help entry in the existing row format.
  - In `_main`, right after `--help` is handled and before `_parse_args`: a `writing` verb calls `_writing_run "<sub>" "$@"`, so Python parses its own arguments.
  - `_writing_run` picks `${DOC_SUPERPOWERS_PYTHON:-python3}` and checks it is 3.9 or later, with `-I -c` on `sys.version_info`.
  - Otherwise it prints `writing: skipped (needs python3 3.9 or later)` on stderr and exits 3.
  - Then it `exec`s `<py> -I -B -X utf8 "$SCRIPT_DIR/writing/<lint.py|anchors.py>" <sub> "$@"`.

- [ ] **Step 1: Write the failing tests** in `test-doc-tools.sh`, in a fixture repository:
  - `writing check` on a clean file exits 0, and on a long sentence exits 1 with `long-sentence`.
  - `writing range HEAD~1...HEAD` passes through exit 1.
  - `writing --help` lists all five verbs; `writing check --help` prints the row's help and exits 0.
  - `DOC_SUPERPOWERS_PYTHON=<stub printing 3.8>` gives exit 3 and the skip line; a missing interpreter gives the same.
  - After any run, the plugin tree has no `__pycache__` under `scripts/writing/`.
- [ ] **Step 2: Run them to see them fail:** `bash scripts/test-doc-tools.sh`.
- [ ] **Step 3: Implement** the rows, the `_main` branch and `_writing_run`.
- [ ] **Step 4: Run the suites:** `bash scripts/check-ci.sh doc-tools writing` under bash 5.x and `/bin/bash` 3.2. Expected: all pass, and shellcheck is clean.
- [ ] **Step 5: Commit:** `feat(writing): doc-tools.sh writing verbs with a python3 3.9 check`.

### Task 8: The rule block, the reference page and the help topic

**Files:**
- Create: `references/writing-rule.md`, `references/writing.md`, `scripts/help/writing.txt`
- Modify: `scripts/doc-tools.sh` (`STAMP_FILES`, `WRITING_RULE_STAMP_FILE`), `scripts/help/overview.txt`, `scripts/test-spec-status-model.sh`, `scripts/test-doc-tools.sh`

**Interfaces:**
- Produces: the marked block `<!-- doc-superpowers:writing-rule vX.Y.Z -->` … `<!-- /doc-superpowers:writing-rule -->`, stamped by `bump-version` and checked by `check-version` like the search rule. Step 4 of the design compares copies in `hooks status`.

`references/writing-rule.md` opens with a short preamble, as `references/search-rule.md` does: what the block is, and that a project copies it into `AGENTS.md` or `CLAUDE.md` unchanged. The block is this text, copied exactly:

```markdown
<!-- doc-superpowers:writing-rule v3.12.1 -->
## Writing

Every text another person or agent reads follows this rule: docs, plans, issues, pull-request (PR)
bodies, commit messages and instruction files. doc-superpowers' `references/writing.md` holds the
key format, the lint and how to run it.

**Everywhere.**

1. Know the reader and the job they do with the text. Put first what that job needs first.
2. Every code (a decision, issue, spec, record, run or finding id) has words before it with the
   code in brackets, a link, or an entry under `## Key`. Treat shorthand that is not a code the
   same way.
3. GitHub links issue and PR numbers, so a `#` and a number passes in PR bodies, issues and
   comments. In a committed file it needs a link.
4. Name a thing by what it does. Put an identifier in backticks after the words, and only where
   the reader needs it to act.
5. Short sentences: at most 35 words in the terse register, 40 in the full one.
6. Keep each claim within its evidence, and say what was not checked.
7. Detail goes in a linked file. The text keeps the conclusion and the link.

**Terse** (read between other work): one idea per list item, at most two sentences and 50 words.
Plans, issues, PR bodies and agent instructions are terse.
**Full but plain** (read to learn the system): complete, with each term defined on first use and
one term per concept. Specs, decision records, designs and generated docs are full but plain.

**What comes first, by scenario.**

- Someone decides: the question, the options, the recommendation and why, the date needed,
  evidence by link.
- Someone reviews a PR: what changed, in one sentence; what must hold before it merges; what was
  not run.
- Someone picks up an issue: what is wrong; how to see it; what done looks like.
- Someone follows a plan: the steps, each with its files and its check.
- An agent follows instructions: the rules, then the commands.
- Someone learns the system: what it decides or requires, then why, then the detail.

Add your project's own readers below this block.
<!-- /doc-superpowers:writing-rule -->
```

`references/writing.md` invents every example. Its sections:
- *The registers*: by `doc_type`, then path, as a table.
- *What comes first*, *The key*, and *What the lint counts and cannot count*.
- *How it reads a file*, and *The verbs* with exit codes and JSON fields.
- *Configuration*, *Ceilings*, *The anchor check* and *Known limits*.

`scripts/help/writing.txt`, copied exactly:

```text
doc-superpowers help writing: the writing rule and its lint

The rule: put first what the reader needs, give every code words or a
link, and keep sentences short. A lint counts what it can of that.

Default:    the lint runs only when you call it, in this release. Later
            releases run it in audit, review-pr and the pre-push hook,
            report-only.
Terminal:   doc-superpowers tools writing check FILE...
            doc-superpowers tools writing range origin/main...HEAD
            doc-superpowers tools writing ceilings|counts|anchors
            doc-superpowers tools writing <verb> --help
Skill:      none yet.
Committed:  docs/writing/config.json and docs/writing/ceilings.json, both
            optional; the rule block, once you copy it into AGENTS.md.
Local:      nothing. It needs python3 3.9 or later and downloads nothing.
Undo:       delete docs/writing/, and the marked block from AGENTS.md.
Reference:  references/writing.md
```

- [ ] **Step 1: Write the failing tests:**
  - In `test-spec-status-model.sh`, add `writing` to `_TOPICS`; the overview test then expects 9 files and `(topics: setup search hooks ci ledger claims release writing)`.
  - In `test-doc-tools.sh`, `bump-version` writes the writing-rule stamp, and `check-version` fails when it differs.
  - In `test_lint_check.py`: `test_the_rule_block_passes_terse` and `test_the_reference_page_passes_full`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Write the three files and the stamp row, then the overview:**
  - Add the row `writing        the writing rule and its lint               help writing`, aligned with its neighbours.
  - Append `writing` to the topics line.
  - Keep the overview at 24 lines or fewer by removing the blank line before `Agent only:`.
- [ ] **Step 4: Run** `bash scripts/check-ci.sh spec-status-model doc-tools writing`. Expected: all pass.
- [ ] **Step 5: Commit:** `feat(writing): the rule block, its reference page and the help topic`.

### Task 9: Docs, security notes and release 3.13.0

**Files:**
- Modify: `SECURITY.md`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/codebase-guide.md`, `RELEASE-NOTES.md`, `docs/.doc-index.json`, the five manifests (through `bump-version`)

- [ ] **Step 1: Update `SECURITY.md`:**
  - A tool row: `python3`, floor `3.9`, advised `3.12 or later`. Why: it runs only the writing lint, standard library only, and 3.9 is past its end of life.
  - In the threat model: `docs/writing/config.json` is data, and its patterns compile as regular expressions under the caller's budget.
- [ ] **Step 2: Update `CLAUDE.md`, `AGENTS.md`, `README.md` and `docs/codebase-guide.md`:**
  - The directory tree gains `scripts/writing/` and its `tests/`.
  - Key Files gains `scripts/writing/`, `references/writing.md`, `references/writing-rule.md` and the `writing` verbs.
  - CLAUDE.md's *Testing* convention gains the writing suite, its test count, and the `writing` check in `check-ci.sh`.
- [ ] **Step 3: Index the new docs:** `add-entry` for `references/writing.md` (type `reference`, refs `scripts/writing/`) and `references/writing-rule.md` (type `reference`, no refs).
- [ ] **Step 4: Write the `v3.13.0` entry** in `RELEASE-NOTES.md`, terse, with no source-project content. Then run `bash scripts/doc-tools.sh bump-version 3.13.0` and `check-version`.
- [ ] **Step 5: Run everything:** `bash scripts/check-ci.sh` (local; `dep-audit` needs the network) and `bash scripts/leak-scan.sh`. Expected: every check passes, the writing check runs on 3.9.6, and the leak scan finds nothing.
- [ ] **Step 6: Lint this branch's own text** with the new verb: `bash scripts/doc-tools.sh writing range origin/main...HEAD`. Fix what it reports in the files this branch added.
- [ ] **Step 7: Grep the branch for source-project content:** search `git log -p origin/main..HEAD` for the source's name, its record codes and its paths. Expected: nothing.
- [ ] **Step 8: Commit:** `chore(release): v3.13.0`.

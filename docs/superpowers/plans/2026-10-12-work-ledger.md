# Work Ledger (3.3.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `doc-tools.sh ledger` verb group that turns markdown (or hosted) issues into keyed items, renders immutable ledger views, computes related work through contracts, and reports in-flight work across branches and machines.

**Architecture:** Logic lives in sibling files under `scripts/ledger/` (bash 3.2 + awk + jq programs) sourced from a thin `ledger` dispatch in `scripts/doc-tools.sh` — only when a ledger verb runs and `docs/ledger/config.json` exists — so the concurrent 3.2.0 edits to `doc-tools.sh` collide only on the verb table, help notes and exit hooks, and vendored copies without `ledger/` keep working. Every index and view is derived and cached under the git common dir; nothing derived is committed to a working branch. Views publish to an orphan branch through git plumbing.

**Tech Stack:** bash 3.2 (`/bin/bash` on macOS) and bash 5.x, POSIX awk (BWK and gawk/mawk), jq ≥ 1.6, git ≥ 2.20. No other dependency. Optional host executables (adapters).

**Spec:** `docs/superpowers/specs/2026-10-12-work-ledger-design.md` (this repo). Executors read both; §A–§K refer to it.

**Base:** branch `design/work-ledger`, created from `claude/task-3-quote-reading-bugs-7d538a` (owner direction). Worktree: `/Volumes/abundance-worktrees/abundance-mvp/doc-superpowers/work-ledger`. Before the PR: rebase onto the released 3.2.0 and do §"After the 3.2.0 rebase".

## Global Constraints

- bash 3.2 compatible: no associative arrays, `mapfile`/`readarray`, `${var,,}`, `{fd}` redirection or `declare -n`; explicit character lists instead of ranges (house rule, `doc-tools.sh:109`); expand possibly-empty arrays as `${a[@]+"${a[@]}"}` under `set -u`; `set -euo pipefail` like `doc-tools.sh:2`.
- awk must run under macOS `awk` (BWK): no `\x` escapes in regexes (pass a BOM in with `-v`), no gawk-only functions.
- `jq` ≥ 1.6 only (`_jq_version_ok`, `doc-tools.sh:16`). One jq program per join — never one jq process per item.
- Inert without `docs/ledger/config.json`, decided **in `doc-tools.sh` before sourcing anything**: text mode prints exactly `ledger: not enabled (no docs/ledger/config.json)`; `--format json` prints `{"verb":"ledger <sub>","enabled":false,"exit":0}`; exit 0.
- Exit codes: `0` ok · `1` findings · `2` could not run (never reported as clean; an internal crash is 2, not 1) · `3` usage.
- `--format json` prints exactly one object `{"verb":"ledger <sub>","enabled":true,"exit":<rc>, …payload}`; text is the default.
- Key regex `^[a-z0-9-]{1,16}-[1-9][0-9]*$`; ledger id regex `^[a-z0-9-]{1,16}$`; provisional key `<ledger>-~<4 lowercase hex>`; reserved ledger value `unassigned`.
- Defaults (verbatim from §B): `base` `origin/main`; `keys.mode` `cas`; `keys.remote` `origin`; `keys.counter_ref` `refs/doc-superpowers/ledger/counters`; `inflight.ref_prefix` `refs/doc-superpowers/inflight`; `inflight.max_age_days` 21; `views.branch` `doc-ledger-views`; `views.recent_days` 14; `cache.remote_ttl_minutes` 10; `summary` ≤ 140 chars; weak summary < 20 chars (advisory); severity order `P0 P1 P2 P3`; status classes as in the §B config block.
- Budgets (3,000 items, warm caches, no network): `show`/`ls`/`find` < 1 s; cold local index < 5 s; `validate --staged` < 1 s for ≤ 20 staged items; `SessionStart` notice hook < 2 s and never fetches. CI runs a 300-item smoke of the same verbs with every budget ×3 (bash 3.2 on shared runners); `scripts/bench-ledger.sh 3000` is the full check, run by each task that touches the index and recorded in its commit body. (Deviation from spec Verification 8, which puts the full budget in the suite: CI runner variance.)
- Output budgets: `ledger show` ≤ 25 lines; hook notices ≤ 15 lines; `ledger ls --ledger L --sev P1,P2 --open` over a 300-item ledger ≤ 8,000 bytes.
- No verb touches the network unless `--refresh`, `--fetch`, `publish`, `new`/`assign`/`finalize` (cas), `init` (key seeding), or an expired remote TTL.
- Each task adds the options its verbs take to their `_VERBS` rows (`_parse_args` rejects undeclared options with rc 3).
- Every new script under `scripts/ledger/` and `scripts/adapters/` joins the bash-4 guard list in `scripts/test-doc-tools.sh:516-522`.
- Git refuses branch names with spaces; tests use spaces only in file and worktree paths, and unicode / dash-prefixed segments in branch names.
- Commits: conventional (`feat(ledger): …`, `test(ledger): …`, `docs(ledger): …`), at least one per task, each ending with the session's attribution lines.

## Review Focus

1. **Malformed item files** — CRLF, a UTF-8 BOM, no frontmatter, an unterminated frontmatter block, `---` inside a fenced body block: a per-file finding; one bad file never aborts the index. (Task 2.)
2. **Awkward paths and names** — item and worktree paths with spaces or unicode, branch names with unicode or `-`-led segments: every git call uses `-z`/`--`; nothing word-splits. (Tasks 2, 3, 11.)
3. **Contention and offline allocation** — concurrent `ledger new` never share a number; lock contention retries; exhausted retries exit 2 (no silent provisional); offline gives a provisional key that `cas` pre-push refuses and `finalize` replaces. (Task 6.)
4. **Stale caches** — a moved remote ref, edited registry/config/legacy map/doc-index/plan/spec, or a staged-but-uncommitted item invalidate exactly what they feed; a cache from another schema is ignored. (Tasks 4, 10.)
5. **Missing or failing tools** — `gh` absent, an adapter that exits non-zero or prints invalid JSON, an unreachable remote: verbs that need them exit 2 with the reason; views show "—" and the age of the last good data; nothing is reported clean. (Tasks 9, 10, 13.)

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/doc-tools.sh` (modify) | `_VERBS` rows; `_USAGE_NOTES` "Work ledger" section + exit lines; `_main` family switch `_LG_ACTIVE` (+ `exec 9>&1`); inert check; sourcing `scripts/ledger/lib.sh`; ledger branches in `_die`, `_usage_error`, `_require_repo_fail`, `_deps_fail`, `_on_exit`. |
| `scripts/ledger/lib.sh` | Sources the other modules; verdict helpers (fd 9, emitted marker, fallback); config load/merge; doc-index wrapper. |
| `scripts/ledger/config.jq` | Default config object and the deep merge. |
| `scripts/ledger/frontmatter.awk` / `fm-write.awk` | Item text → JSON line; field rewrite. |
| `scripts/ledger/parse.sh` | Worktree and blob (staged / base) parsing with a per-file cache keyed by content hash / blob oid. |
| `scripts/ledger/glob.sh` | Glob → ERE; ownership map. |
| `scripts/ledger/index.sh` | Index build, joins, caches, derived status. |
| `scripts/ledger/keys.sh` | Resolution; counter read/CAS; allocation (single, batch); provisional; finalize; assign. |
| `scripts/ledger/validate.sh` | `validate --staged|--all|--registry|--plan`. |
| `scripts/ledger/query.sh` | `show`, `ls`, `find`, `new`, `assign`, `note`, `link`. |
| `scripts/ledger/relations.sh` | Contracts, neighbours, candidates, `related`, `recheck`, `sweep`, message-trailer parsing. |
| `scripts/ledger/render-md.jq`, `render-html.jq`, `views.sh` | Renderers, `view`, `publish`. |
| `scripts/ledger/adapters.sh` | Adapter calls, JSON-lines validation, remote cache with TTL keyed by ref oids. |
| `scripts/ledger/inflight.sh` | Branch scan, facts, `inflight`, notices, acks, push, prune. |
| `scripts/ledger/init.sh` | `init`. |
| `scripts/adapters/ledger-pr-gh.sh`, `ledger-items-gh.sh` | Reference adapters. |
| `scripts/hooks/git/ledger-*`, `scripts/hooks/claude/ledger-*.sh`, `scripts/hooks/install.sh` | Opt-in `--ledger` hook set. |
| `scripts/hooks/ci/doc-ledger-publish.yml` | Publish workflow template. |
| `scripts/test-ledger.sh`, `scripts/bench-ledger.sh` | Suite; synthetic-corpus bench. |
| `references/ledger.md`, `references/ledger-index.schema.json` | Reference doc; schema. |

Run tests in the worktree with both shells: `bash scripts/test-ledger.sh` and `BASH_BIN=/bin/bash /bin/bash scripts/test-ledger.sh`. A task is done when both pass and `bash scripts/test-doc-tools.sh` still passes (plus `test-hooks.sh` for Tasks 16–17).

---

## Chunk 1 — Core

### Task 1: Verb group, exit family, config, inert behaviour, suite skeleton

**Files:** Modify `scripts/doc-tools.sh` (`_VERBS` after the claims rows ~:2220; `_USAGE_NOTES` ~:2385-2440; `_main` ~:2697; `_die` :1418; `_usage_error` :2538; `_require_repo_fail` :2670; `_deps_fail` :2678; `_on_exit` :1504); create `scripts/ledger/lib.sh`, `scripts/ledger/config.jq`, `scripts/test-ledger.sh`; modify `.github/workflows/tests.yml` (one step per matrix leg after spec-claims), `scripts/test-doc-tools.sh:516-522`.

**Interfaces:**
- Produces globals `_LG_ACTIVE`, `_LG_VERB`, `_LG_FORMAT` (`text|json`), `_LG_CFG` (merged config path in `$_SCRATCH`), `_LG_ROOT`, `_LG_CACHE` (`$(git rev-parse --git-common-dir)/doc-superpowers/ledger`, created on demand).
- In **`doc-tools.sh`** (so they exist before `lib.sh` is sourced): `_lg_json_str <s>` → `_LG_JS` (same algorithm as `_claims_json_str` :5558; do not call claims helpers), `_lg_out <line>` (fd 9), `_lg_mark_emitted <rc>` (marker file like `_claims_mark_emitted` :5584, so a verdict printed inside `$(…)` is known), `_lg_fallback` (called from `_on_exit` when `_LG_ACTIVE=1` and nothing was emitted or rc is unexpected: prints `{"verb","enabled":true,"exit":2,"error":"internal"}` in JSON mode, a `ledger: internal error` line in text mode, forces rc 2). Both pre-source paths mark their verdict emitted (inert → 0; missing `ledger/` → 2 with exactly one object in JSON mode).
- In `lib.sh`: `_lg_init <sub>` (config load; called only after `doc-tools.sh` established the config exists), `_lg_cfg <jq-filter>`, `_lg_emit <sub> <rc> [payload-json-file]`, `_lg_die <msg>` (rc 2; JSON mode prints the verdict object with `"error"` once), `_lg_usage <msg>` (rc 3).
- Produces `_lg_doc_index` → path to the doc-index JSON or to an empty `{"docs":{}}` when `docs/.doc-index.json` is absent; rc 2 when present but invalid (never the `exit 1` of `_index_load` :1651).
- `doc-tools.sh` switch: `if [ "$1" = ledger ]; then _USAGE_RC=3; _LG_ACTIVE=1; _LG_VERB="${2:-ledger}"; exec 9>&1; fi`; after `_parse_args` **and** the `needs=repo` check (outside a repo or below the repo root → rc 2 as today), if `docs/ledger/config.json` is absent → print the inert output and `_exit_ok`; else if `$SCRIPT_DIR/ledger/lib.sh` is missing → rc 2 with `ledger needs scripts/ledger/ beside doc-tools.sh (<path>)`; else `. "$SCRIPT_DIR/ledger/lib.sh"`.
- `_VERBS` rows (all `needs=repo`, each with `format=`): `ledger show|ls|find|related|sweep|recheck|inflight|notices|new|assign|link|note|view|validate|publish|finalize|init`, handlers `cmd_ledger_<sub>` (until their task: `_lg_init` then `_lg_die "not implemented"`).

- [ ] **Step 1: Failing tests** (`scripts/test-ledger.sh`: source `test-helpers.sh`; `DOC_TOOLS="$(bash_bin_shim "$REPO_DIR/scripts/doc-tools.sh")"` like `test-spec-claims.sh:4-11`; runner `lg` sets `LG_RC`, `LG_OUT`, `LG_ERR` like `cl` :84; `lg_fixture` = `setup` + `mkdir -p docs/issues docs/ledger`): `test_lg_inert_text_every_verb` (17 sub-verbs, rc 0, exact line) · `test_lg_inert_json` (`.verb`=`ledger ls`, `.enabled` false, `.exit` 0) · `test_lg_unknown_option_is_usage` (rc 3) · `test_lg_config_invalid_json` (`{` → rc 2, stderr names `docs/ledger/config.json`) · `test_lg_config_merge` (`jq -n --argjson h '{"views":{"recent_days":7}}' -f scripts/ledger/config.jq` → `.views.recent_days` 7, `.views.branch` `doc-ledger-views`, `.keys.counter_ref` default) · `test_lg_vendored_copy_no_config_inert` (copy `doc-tools.sh` alone to a temp dir; no config → rc 0, inert line) · `test_lg_vendored_copy_with_config_rc2` (stderr names `scripts/ledger/`; JSON mode prints exactly one object) · `test_lg_outside_repo_rc2` (a ledger verb outside a git repo → rc 2, not the inert line) · `test_lg_die_inside_subshell_one_object` (a debug-only hidden env `DOC_TOOLS_LEDGER_SELFTEST=die-in-subst` makes a handler call `x=$(_lg_die boom)`; JSON mode → exactly one object, rc 2) · `test_lg_crash_is_rc2` (`DOC_TOOLS_LEDGER_SELFTEST=unset-var` triggers a `set -u` failure → rc 2, one object).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Both shells + `test-doc-tools.sh` → PASS.
- [ ] **Step 5:** Commit `feat(ledger): verb group, exit family, config, inert behaviour`.

### Task 2: Frontmatter parser, writer, parse cache

**Files:** Create `scripts/ledger/frontmatter.awk`, `scripts/ledger/fm-write.awk`, `scripts/ledger/parse.sh`; modify `scripts/test-ledger.sh`.

**Interfaces:**
- `frontmatter.awk` (stdin = one file's text; `-v path=… -v bom=$'\357\273\277'`) → one JSON object `{"path","fm":{<key>:<string>|[<string>…]},"fm_errors":[…],"h1","first_para","resolution","log"}`; `resolution` = first non-empty line after `resolution_heading`; `first_para` ≤ 300 chars; `log` = `log_heading` present. Scalars, flow sequences `[a, b]`, block sequences of scalars are parsed; a nested map in any key → an `fm_errors` entry naming the key, the key omitted, the rest parsed. Frontmatter starts only on line 1 (after an optional BOM) and ends at the next `---` line; fenced blocks in the body are ignored.
- `parse.sh`: `_lg_parse_worktree <paths-file> <out.jsonl>` (cache entry per file keyed by `sha256(content)`; `"archived"` set from `archive_globs`); `_lg_parse_blobs <rev> <paths-file> <out.jsonl>` (`git cat-file --batch` on `<rev>:<path>`, `<rev>` = `:` for the index/staged, or a commit; cache keyed by blob oid). Both emit records with `"blob"` (oid or content hash).
- `_lg_item_paths <rev|worktree> <out>` → item paths from `git ls-files -z` (worktree adds untracked files under the globs) or `git ls-tree -r -z --name-only <rev>`, filtered by `items.globs` + `archive_globs`.
- Writers: `_lg_fm_set <file> <field> <value>`, `_lg_fm_list_add <file> <field> <item>`, `_lg_fm_del <file> <field>` via `fm-write.awk` + `_replace_file` (:1627); a missing field is appended as the LAST frontmatter line; scalars containing `:`, `#`, leading/trailing space or starting with `[`/`-` are double-quoted; body bytes untouched.
- `_lg_field <logical> <record-json>`: first configured candidate name present.

- [ ] **Step 1: Failing tests:** `test_lg_fm_scalars_and_lists` (`key: x-3`, `changes: [field:a, component:B]`, block `related-files:\n  - src/a.js\n  - "src/b c.js"` → exact values) · `test_lg_fm_crlf_bom` (identical record) · `test_lg_fm_nested_map_rejected` · `test_lg_fm_no_frontmatter` · `test_lg_fm_unterminated` · `test_lg_fm_fence_dash` · `test_lg_fm_quoted_values` (`summary: "Totals: wrong # sometimes"`) · `test_lg_fm_resolution_h1_para` · `test_lg_fm_write_append_and_replace` (body hash unchanged) · `test_lg_fm_write_quotes` · `test_lg_parse_path_space_unicode` (`docs/issues/ü x.md`) · `test_lg_parse_blobs_staged_differs_from_worktree` (staged blob says `key: x-1`, worktree says `x-2` → blob parse returns `x-1`) · `test_lg_parse_cache_reuse_by_content` (second run reads the cache entry — assert via a counter env `DOC_TOOLS_LEDGER_TRACE=1` printing `parse-miss <path>` to stderr).
- [ ] **Steps 2–4:** FAIL → implement → both shells PASS. **Step 5:** Commit `feat(ledger): frontmatter parse/write with blob cache`.

### Task 3: Registry, globs, `validate --registry`

**Files:** Create `scripts/ledger/glob.sh`, `scripts/ledger/validate.sh` (registry part); modify `scripts/ledger/lib.sh`, `scripts/test-ledger.sh`, `_VERBS` row `ledger validate` (`staged all registry plan= strict format=`).

**Interfaces:**
- `_lg_glob_ere <glob>` → `^…$` ERE (`**/` zero or more dirs, `**` anything, `*` one segment, `?`, `{a,b,c}`).
- `_lg_owner_map <paths-file> <out.tsv>` → `path<TAB>ledger|-|multi:a,b`; ordinary `paths` first, `residual_paths` only for paths no ordinary glob claims; a `!glob` excludes within its own ledger. One awk pass over all paths with all EREs.
- `_lg_registry` → validated registry path (`docs/ledger/ledgers.json`; absent = `{"schema":"ledger-registry/1","ledgers":[]}`).
- `validate --registry` findings (rc 1): bad `schema`; bad/duplicate id; `status` ∉ {active, retired}; `kind` ∉ {service, platform}; bad/duplicate contract id; a tracked file claimed twice (`overlap`); when any ledger declares `paths`, a tracked file outside `docs/` owned by none (`unowned`). Text `registry <class> <detail>`; JSON `{"findings":[{"class","detail"}]}`.

- [ ] **Step 1: Failing tests:** `test_lg_glob_ere_cases` (table incl. `src/**/x.js` vs `src/x.js` and `src/a/b/x.js`; `{a,b}`; `*` not crossing `/`; a path with a space) · `test_lg_registry_valid_clean` · `…_duplicate_id` · `…_bad_status` · `…_contract_dup` · `…_overlap` · `…_unowned` · `…_residual` · `…_exclusion`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): registry validation and glob ownership`.

### Task 4: Index core — joins, dates, derived status (local), caches, schema

**Files:** Create `scripts/ledger/index.sh`, `references/ledger-index.schema.json`; modify `scripts/test-ledger.sh`.

**Interfaces:**
- Consumes `_lg_parse_worktree`/`_lg_parse_blobs` (T2), `_lg_registry` (T3), `_lg_doc_index` (T1).
- `_lg_index [--rev <rev>|--staged]` → cached index path (default: the worktree). Shape (schema `ledger-index/1`): `{"schema","built":{"head","base","inputs_hash"},"ledgers":[…],"items":[{"path","archived","key","ledger","status","class","severity","date","summary","changes":[],"consumes":[],"relates":[{"kind","key"}],"superseded_by","owed","aliases":[],"paths":[],"h1","first_para","resolution","docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status","detail"},"pr":null,"inflight":[],"neighbours":null,"recheck_after":[],"fm_errors":[]}],"legacy":{},"finalized":{}}`. `class` ∈ `open|fixed|closed|wontfix|unknown` by case-insensitive leading-word match.
- **Dates** (deterministic): `fields.date` (YYYY-MM-DD) else the first-add date from one `git log --reverse --date=short --format='%ad' --name-status -M --diff-filter=AR <HEAD>` pass, chaining `R` records so a renamed file keeps its original add date — the path→date map is cached in `$_LG_CACHE/dates-<HEAD>.tsv` and extended incrementally from the newest cached HEAD that is an ancestor; else mtime (only for uncommitted files). `bench-ledger.sh` includes a 2,000-commit history case.
- **Docs joins:** doc-index entries with `doc_type` in `doc_columns.<col>` (+ handoff globs when set) whose text links the item (relative link resolving to its path, or to a former path via the rename chain above) or contains its key as a word; one awk pass over the candidate docs.
- **Derived status (local inputs):** `superseded → <key>`, `won't fix`, `closed`, `shipped`, `merged · owed: <owed>`, `planned` (a linked plan whose `status` is not terminal), `spec'd`, `not started` (§E.1 order; PR/in-flight inputs arrive in Tasks 10–11).
- **Cache:** `$_LG_CACHE/index-<sha256 of (schema, HEAD, base oid, config hash, registry hash, legacy.json hash, doc-index hash, sorted (path, blob) of items, sorted (path, content hash) of dirty or untracked docs under doc_columns)>.json`; per-file parse caches (T2) make a one-item change an incremental rebuild; a cache file whose `schema` differs is ignored; keep the newest 3.

- [ ] **Step 1: Failing tests:** `test_lg_index_fields` (open P1 with key; fixed + owed; closed + superseded_by + resolution; unassigned without key → exact `class`/`derived.status`) · `test_lg_index_status_classes_case` (`resolved` → fixed) · `test_lg_index_date_fallback_and_rename` (no `date:`; file renamed after add → original add date) · `test_lg_index_docs_links` · `test_lg_index_renamed_link` · `test_lg_index_absent_doc_index_ok` · `test_lg_index_invalid_doc_index_rc2` · `test_lg_index_cache_invalidation` (each of registry, config, legacy.json, doc-index, an item, an uncommitted plan edit → a different cache file; no change → same file, asserted by name and content hash) · `test_lg_index_foreign_schema_ignored` · `test_lg_index_staged_mode` (staged blob values win).
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): index core, joins, caches`.

### Task 5: `show`, `ls`, `find`, bench and CI smoke

**Files:** Create `scripts/ledger/query.sh` (show/ls/find), `scripts/bench-ledger.sh`; modify `_VERBS` rows (`show <ref>`; `ls ledger= sev= open status= cluster=`; `find <words>`), `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger show <ref>` (ref = path or key here; Task 6 extends resolution) ≤ 25 lines: `<key|path>  <ledger>  <severity>  <derived.status>` / summary / spec·plan·handoff / changes·consumes·relates / resolution line when terminal.
- `ledger ls [--ledger L] [--sev a,b] [--open] [--status S] [--cluster C]`: `<key or path-stem>  <sev>  <derived.status>  <summary>` sorted by severity order then date; JSON `{"items":[…]}`.
- `ledger find <words…>`: score 3 × (all words in key/summary) + 2 × (in H1/slug) + 1 × (in first_para), case-insensitive; top 15 with scores.
- `scripts/bench-ledger.sh <N>`: builds an N-item synthetic repo (deterministic seed) and prints cold/warm timings for `ls`, `show`, `find`, `validate --staged` (20 staged) — exit 1 when a Global Constraints budget is exceeded. `test_lg_smoke_budgets` runs it with N=300 and budgets ×3.

- [ ] **Step 1: Failing tests:** `test_lg_show_limits` · `test_lg_ls_filters_and_order` · `test_lg_ls_output_budget` (300-item ledger, 60 open P1/P2 → ≤ 8,000 bytes) · `test_lg_find_ranks` · `test_lg_smoke_budgets`.
- [ ] **Steps 2–4:** FAIL → implement → PASS; run `bash scripts/bench-ledger.sh 3000` and record timings in the commit body. **Step 5:** Commit `feat(ledger): show/ls/find and budgets`.

### Task 6: Keys — resolution, CAS, batch, provisional, finalize, new, assign

**Files:** Create `scripts/ledger/keys.sh`; modify `scripts/ledger/query.sh` (`new`, `assign`), `scripts/ledger/index.sh` (alias/legacy/finalized resolution), `_VERBS` rows (`new ledger= summary= file= finalize`; `assign <ref> <ledger>`; `finalize all`), `scripts/test-ledger.sh`.

**Interfaces:**
- `_lg_resolve <ref>` → item path, rc 1 none, rc 3 ambiguous. Accepts `L-14`, `L 14`, `L #14`, an alias, a provisional key mapped in `docs/ledger/finalized.json` (written by finalize), a legacy ref `<old>#<row>` / `<old> row <n>` / `<old> ledger row <n>` where `<old>` is a legacy id (Task 15's rule) (via `legacy.json`: `{"key"}` → that item; `{"item"}` → that path; `{"archived"}` → prints the anchor, rc 0), or a path.
- `_lg_counter_read` → `{ledger: next}` from `<remote> <counter_ref>` (single-ref fetch into `refs/doc-superpowers/ledger/counters-remote`); seeding: a ledger absent from the blob starts at (highest key number for that ledger among items at `<base>`, parsed with `_lg_parse_blobs <base>`) + 1.
- `_lg_counter_cas <expected-oid|""> <new-json>` → commit (tree = one blob `counters.json`; parent = expected; message `ledger: allocate …`), `git push --porcelain --no-verify --force-with-lease=<ref>:<expected> <remote> <oid>:<ref>`; classify: success **only** when the push exits 0 and the ref's porcelain flag is ` `, `*` or `=` → rc 0; `!` with `stale info`, `failed to lock` or `failed to update ref` → rc 1 (retry); exit 128 / no status line → rc 4 (transport); any other `!` (e.g. `pre-receive hook declined`, a refused namespace) → rc 2.
- `_lg_alloc_batch <json {ledger:count}>` → prints `ledger<TAB>key` lines; one CAS commit for all ledgers; ≤ 8 retries with 0.1–0.6 s jitter re-reading each time; exhausted → rc 2 (no provisional); transport (rc 4) → provisional keys `<ledger>-~<first 4 hex of sha256(item path)>` (cas mode, with a stderr warning, rc 0); `keys.mode: merge` → always provisional, no network.
- `_lg_alloc <ledger> <count>` = `_lg_alloc_batch` for one ledger.
- `ledger new --ledger L --summary S [--file F] [--finalize]`: writes `ledger`, `summary`, and (unless `L` = `unassigned`) `key`; F defaults to the single staged-or-untracked item file without a key (usage error if 0 or > 1); `summary` > 140 chars → usage error; `--finalize` = `ledger finalize` for F only.
- `ledger assign <ref> <L>`: new key in L; the previous key appended to `aliases`.
- `ledger finalize [--all]`: cas mode — replace provisional keys in the working tree (the file's own `key` and every item's `relates`/`superseded_by`/`aliases` that reference it), recording `provisional → key` in `docs/ledger/finalized.json` as one `"<provisional>": "<key>"` entry per line with the object's keys sorted (concurrent branches add distinct lines and merge cleanly); merge mode on the base — the same for every provisional key in one commit `ledger: finalize N keys`.
- `_lg_provisional_in_range <range>` → provisional keys added in a push range (Task 16's pre-push leg).

- [ ] **Step 1: Failing tests** (bare remote + clones): `test_lg_resolve_forms` · `test_lg_resolve_legacy_forms` · `test_lg_resolve_finalized` · `test_lg_resolve_ambiguous` · `test_lg_alloc_seeds_from_base` (`x-1`, `x-5` on base, no counter ref → `x-6`) · `test_lg_alloc_batch_one_commit` (`{"x":2,"y":3}` → counter ref advanced by one commit) · `test_lg_alloc_race` (two clones × 10 allocations in background jobs under `harness_kill_after`, each pid waited → 20 distinct keys, no provisional) · `test_lg_alloc_exhausted_rc2` (a fake remote that always rejects with `stale info` → rc 2 after the retries) · `test_lg_alloc_declined_rc2` (a bare remote whose `pre-receive` hook exits 1 → rc 2 immediately, no key handed out) · `test_lg_alloc_offline_provisional` · `test_lg_merge_mode_provisional_and_finalize` (references rewritten; `finalized.json` updated; nothing else) · `test_lg_new_writes_fields` · `test_lg_new_unassigned_no_key` · `test_lg_new_summary_too_long` · `test_lg_assign_moves_old_key_to_aliases` · `test_lg_counter_push_no_verify` (a failing `pre-push` hook does not block).
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): keys — resolution, CAS allocation, finalize`.

### Task 7: `validate --staged | --all | --plan`

**Files:** Modify `scripts/ledger/validate.sh`, `scripts/test-ledger.sh`.

**Interfaces:**
- `--staged` (blocking): items staged in the index (`git diff --cached --name-only -z`, added = `--diff-filter=A`), parsed from **staged blobs** (`_lg_index --staged`): (a) a present key matches the key or provisional form and is unique across keys + aliases of the staged index; (b) `ledger` is an active registered id or `unassigned`, except a `legacy_ids` value on a **modified** file → advisory `legacy-ledger-id`; (c) **added** files carry `ledger` and `summary`; (d) status changed (vs HEAD) into closed/wontfix → non-empty resolution, and a `superseded_by` resolves, has no cycle and ends at a non-superseded item; (e) `superseded_by` on an item whose class is not closed → finding `superseded-not-closed`. Runs `--registry` when `docs/ledger/ledgers.json` is staged. Budget < 1 s for ≤ 20 staged items (incremental index).
- `--all`: (a)–(e) across the index (blocking classes → rc 1), plus advisories `missing-key`, `missing-ledger`, `missing-summary`, `weak-summary` (< 20 chars), `unassigned-open`, `no-contract`, `parse-error` (any `fm_errors`).
- `--plan <path> [--strict]`: every row of the plan's `## Related work` table is marked `include` or `exclude: <reason>` (advisory; `--strict` → rc 1).
- Text `<class> <path|key> <detail>`; JSON `{"findings":[{"class","severity":"block|advisory","path","key","detail"}]}`.

- [ ] **Step 1: Failing tests:** `test_lg_validate_staged_clean` · `…_dup_key` · `…_alias_collision` · `…_unknown_ledger` · `…_added_needs_fields` · `…_modified_legacy_ok` · `…_reads_staged_blob` (worktree fixed, staged still bad → rc 1) · `…_superseded_dangling` · `…_cycle` · `…_chain_ends_superseded` · `…_missing_resolution` · `…_superseded_not_closed` · `test_lg_validate_all_advisories_rc0` · `test_lg_validate_plan_marks`.
- [ ] **Steps 2–4:** FAIL → implement → PASS; bench `validate --staged` in the 3,000-item corpus. **Step 5:** Commit `feat(ledger): validate staged/all/plan`.

---

## Chunk 2 — Views and related work

### Task 8: Renderers, `view`, `publish`

**Files:** Create `scripts/ledger/render-md.jq`, `scripts/ledger/render-html.jq`, `scripts/ledger/views.sh`; modify `_VERBS` rows (`view <target> md html out= open`; `publish dry-run`), `scripts/test-ledger.sh`.

**Interfaces:**
- `render-md.jq` (index + `$ledger` + `$generated`) → the §E.2 page: `# <title> (`<id>`)`; header quote; scope/open-count line; per cluster `## <cluster title> — `<contract>` (<n>)` (primary contract = first of `changes`, else first of `consumes`) with `| Key | Issue | Why it matters | Sev | Spec | Plan | PR | Latest handoff | Status |`, then `↳` neighbour lines when `neighbours` is non-null (Task 9); `## Unclustered (<n>)`; `## Recently closed (<recent_days> days)`; `## Superseded / won't fix (<recent_days> days)` with `<key> → <superseded_by>: <resolution>`. Clusters by (P0..P3 counts) desc then title; rows by severity then date. PR column `—` and in-flight counts `0` until Tasks 10–11 populate them. `$mode == "readme"` → one line per ledger with open counts and in-flight count, then the open P0/P1 rollup.
- `render-html.jq` → one self-contained HTML document (inline CSS/JS; light/dark via `prefers-color-scheme`): all ledgers in the cluster layout, filters (ledger, severity, status class, in flight), search over key/summary/slug/H1.
- `ledger view <L|all> [--md|--html] [--out DIR] [--open]` → `<L>.md` (+ `README.md` for `all`) or `ledger.html` in DIR (default `$_LG_CACHE/views`).
- `ledger publish [--dry-run]`: `git fetch <remote>`; build the index at `<base>` from a detached worktree under `$_LG_CACHE/publish-wt` (removed in the exit cleanup with `git worktree remove --force` + `git worktree prune`, also after a kill); render; write the files into a commit with **plumbing only** (`GIT_INDEX_FILE` temp, `git hash-object -w`, `git update-index --add --cacheinfo`, `git write-tree`, `git commit-tree [-p <previous views oid>]`), push `<oid>:refs/heads/<views.branch>` without force (rejected → rc 2); never touches the user's HEAD, index or worktree. Message `views @ <base>@<short-sha>, <n> in-flight branches, <UTC>`.

- [ ] **Step 1: Failing tests:** `test_lg_render_pure` (same `$generated` twice → identical; shuffled item order → identical) · `test_lg_render_clusters_and_unclustered` · `test_lg_render_footer_recent_days` · `test_lg_render_superseded_line` · `test_lg_render_readme_rollup` · `test_lg_html_self_contained` (no `src=`/`href=` to `http(s)://` scripts or styles; every key present) · `test_lg_view_writes_files` · `test_lg_publish_orphan_branch` (first publish: views branch holds only view files; second fast-forwards; `git status --porcelain` and HEAD unchanged) · `test_lg_publish_rejects_non_ff`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): markdown/HTML views and publish`.

### Task 9: Contracts, relations, message trailers, re-check

**Files:** Create `scripts/ledger/relations.sh`, `scripts/ledger/adapters.sh` (contracts part); modify `scripts/ledger/index.sh`, `scripts/ledger/query.sh` (`link`, `show` gains neighbours), `scripts/ledger/render-md.jq` (neighbour lines; unclustered suggestions), `_VERBS` rows (`related <ref> depth=`; `recheck <ref>`; `sweep plan= files+ contracts+ keys+`; `link <ref> consumes= changes= relates=`), `scripts/test-ledger.sh`.

**Interfaces:**
- `_lg_adapter <name> <args…>` → runs `adapters.<name>`; the value is an absolute path, a repo-root-relative path, or `doc-superpowers:<adapter>` → `$SCRIPT_DIR/adapters/<adapter>.sh` (the plugin's, or a vendored copy's sibling); every output line must parse as JSON with the contract's required fields; non-zero exit or invalid output → rc 2 with the adapter's stderr; absent → rc 0, no output.
- Index: `"contracts":[{"id","ledger","defined_in":[],"title"}]` (registry + `contracts` adapter `list`; an id present in both is one contract — the registry's `ledger`/`defined_in`/`title` win, the adapter's values fill only fields the registry leaves empty); per item `neighbours = {"upstream":[{"key","via"}],"downstream":[…],"siblings":[…]}` (upstream = items whose `changes` ∩ this item's `consumes`; downstream inverse; siblings share a contract on one side; `relates` adds `root-cause`/`depends-on`/`sibling` edges).
- `_lg_msg_claims <commit-range>` → TSV `commit<TAB>kind<TAB>value` from **any** message line matching `^[[:space:]*-]*<Trailer>:[[:space:]]+(.+)$` for each configured trailer (`claims`, `claims_by_path`, `claims_by_ref`, `contract_change`, `ack`).
- Re-check marker: `recheck_after: [<key>…]` on an open item when an upstream or `relates` source reached a terminal class, or a `<base>` commit changed a contract it consumes (`defined_in` diff or `Contract-Change:` line), **after** the item file's last commit on `<base>`; views show `re-check: <key> landed` in Status; a later commit to the item clears it.
- `ledger related <ref> [--depth N]` (1–3): confirmed neighbours by kind, then candidates — open items sharing ≥ 2 `paths`, a `docs.spec` entry, or `paths` ∩ the `defined_in` of a contract the item names — each with its reason.
- `ledger recheck <ref>`: downstream + `relates` dependents with `re-verify | close as superseded by <ref> | reshape`.
- `ledger sweep --plan P | --files … | --contracts … | --keys …` → a `## Related work` table `| Item | Why related | Mark |` (confirmed first, then candidates; Mark empty).
- `ledger link <ref> --consumes C | --changes C | --relates kind:key` → validates, then `_lg_fm_list_add`.
- Views: `↳ Downstream` / `↳ Upstream` lines per cluster (other ledgers only, de-duplicated); each Unclustered item shows its top candidate cluster. `show` lists neighbours.

- [ ] **Step 1: Failing tests:** `test_lg_contract_upstream_downstream` · `test_lg_contract_siblings` · `test_lg_relates_edges` · `test_lg_related_candidates_paths` (≥ 2 shared → candidate; 1 → not) · `test_lg_related_candidates_spec` · `test_lg_recheck_lists_dependents` · `test_lg_sweep_table_shape` · `test_lg_link_validates` · `test_lg_contracts_adapter_absent_ok` · `test_lg_adapter_plugin_prefix_resolves` · `test_lg_contract_registry_wins_over_adapter` · `…_failing_rc2` · `…_invalid_json_rc2` · `test_lg_msg_claims_squash_bullets` (`* Ledger-Claims: x-3` in a squash body counts) · `test_lg_recheck_marker_set_and_cleared` · `test_lg_render_neighbours_and_suggestions` · `test_lg_show_neighbours`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): contracts, relations, re-check`.

---

## Chunk 3 — Remote sources and in-flight awareness

### Task 10: PR adapter, remote cache, review/merged status

**Files:** Create `scripts/adapters/ledger-pr-gh.sh`; modify `scripts/ledger/adapters.sh`, `scripts/ledger/index.sh`, `_VERBS` rows (`refresh` on show/ls/view), `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger-pr-gh.sh list` → `{"number","head","state":"open|merged|closed","url","merge_commit"}` lines from `gh pr list --state all --limit 500 --json number,headRefName,state,url,mergeCommit`; `gh` failure → exit 2 with its stderr.
- `_lg_remote_cache <name> <key-material> <producer…>` → path; refreshed when older than `cache.remote_ttl_minutes`, on `--refresh`, or by `publish`; entries record fetch time; views show `PR data as of <age>` when stale.
- Derived status adds `in review #<n>` (open PR whose head branch claims the item; claims via `_lg_msg_claims <base>..<head>` + item files modified in that range) and `merged · owed: <owed>` when a claims/claims-by-path line for the item is reachable from `<base>` while the item is open, or a merged PR's head claimed it.

- [ ] **Step 1: Failing tests** (fake `gh` on `PATH`, call counter file): `test_lg_pr_adapter_normalises` · `test_lg_pr_adapter_gh_missing_rc2` · `test_lg_remote_cache_ttl` · `test_lg_remote_cache_refresh_flag` · `test_lg_status_in_review` · `test_lg_status_merged_open_item` · `test_lg_view_stale_pr_marker`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): PR adapter, remote cache, review/merged status`.

### Task 11: In-flight scan, branch facts, `inflight`

**Files:** Create `scripts/ledger/inflight.sh`; modify `scripts/ledger/index.sh` (`inflight` per item; `on branch <b>` status; `show` lists claims), `_VERBS` row (`inflight branch= fetch push`), `scripts/test-ledger.sh`.

**Interfaces:**
- `_lg_host_id` → `inflight.host_id`, else `git config doc-superpowers.ledger.host`, else first 8 hex of the sha256 (`sha256sum` or `shasum -a 256`, as `check_deps` :38) of `hostname || uname -n`.
- `_lg_branches` → TSV `host<TAB>name<TAB>oid<TAB>sources` — local branches and every worktree's HEAD (detached worktrees as `(detached:<path-hash>)`), `refs/remotes/<remote>/*`, and `<ref_prefix>/<host>/<branch>` (after `git fetch --prune <remote> +<ref_prefix>/*:<ref_prefix>/*` on `--fetch` or expired TTL); excludes `<base>`'s branch, `HEAD`, and `views.branch`; de-duplicated by (host, name) where local, remote and own-host in-flight copies of one branch count as one (newest oid wins).
- `_lg_branch_facts <oid>` (cache keyed by (oid, merge-base oid)) → `{"merge_base","files":[…],"claims":[keys],"contract_changes":[{"id","line"}],"acks":[ids]}` — claims from `_lg_msg_claims` (paths → keys; `#N` via the items adapter mapping when present) + item files modified in the range + keys named by plans modified in the range; contract changes from diff paths ∩ `defined_in` and `Contract-Change:` lines.
- `ledger inflight [--branch B] [--fetch]`: one line per branch `<name> <sources>[@host] <PR #n|no PR> claims:<keys> contracts:<ids> files:<n>`.

- [ ] **Step 1: Failing tests** (bare remote; clone A with worktrees `wt1`, `wt2`; clone B as another host pushing an in-flight ref): `test_lg_inflight_sources` (local, remote-without-PR, other-host in-flight all listed) · `test_lg_inflight_excludes_views_branch` · `test_lg_inflight_dedup_host_name` (two hosts' same-named branches stay separate; own copies merge) · `test_lg_inflight_detached_worktree` · `test_lg_inflight_prune_on_fetch` · `test_lg_inflight_unicode_branch` (`feat/ü-x`, `-dash` segment) · `test_lg_host_id_anonymous` · `test_lg_branch_facts_claims_and_contracts` · `test_lg_show_inflight_claims`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): in-flight scan and branch facts`.

### Task 12: Notices, acks, gate, push, prune

**Files:** Modify `scripts/ledger/inflight.sh`, `scripts/ledger/views.sh` (`publish` prunes), `_VERBS` row (`notices branch= gate fetch`), `scripts/bench-ledger.sh` (notices case), `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger notices [--branch B] [--gate] [--fetch]` (default B = current branch): against every other branch and `<base>` commits since B's merge-base — `stop` (another branch or `<base>` changes a contract B's claimed items consume or B also changes; two branches claim one item), `heads-up` (shared changed files), `info` (siblings of B's claims claimed elsewhere). `id` = first 12 hex of sha256(other + NUL + overlap + NUL + other-oid). Notices acked by `Ledger-Ack: <id>` on B are hidden. Text `<urgency> <id> <other>[@host] <PR #n|no PR> <overlap> — <what_changed> → <action>` (`action` ∈ `reconcile-before-next-chunk`, `rebase-after-merge`, `heads-up`); JSON per §H.2. `--gate`: rc 1 on any unacked `stop`.
- `ledger inflight --push`: when `inflight.enabled` and the branch has commits not on `<base>`: run `inflight.pre_push_check` with the commit range on stdin (non-zero → abort, show its output, rc 1); then `git push --no-verify --force <remote> HEAD:<ref_prefix>/<host>/<branch>` (offline → warning, rc 0).
- `publish` prunes `<ref_prefix>/*` refs reachable from `<base>` or older than `max_age_days` (`git push <remote> --delete <ref>`).
- Bench: `notices` with a cold branch-facts cache over 20 branches < 2 s.

- [ ] **Step 1: Failing tests:** `test_lg_notice_contract_change_stop` · `test_lg_notice_double_claim_stop` · `test_lg_notice_file_overlap_headsup` · `test_lg_notice_base_changed_contract` · `test_lg_notice_sibling_info` · `test_lg_notice_ack_hides_and_moved_head_refires` · `test_lg_notices_gate_rc` · `test_lg_inflight_push_and_pre_push_check` · `test_lg_inflight_push_offline_warns` · `test_lg_publish_prunes_inflight`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): notices, acks, gate, push, prune`.

---

## Chunk 4 — Item sources and init

### Task 13: `note`, items adapter, GitHub reference adapter

**Files:** Create `scripts/adapters/ledger-items-gh.sh`; modify `scripts/ledger/query.sh` (`note`), `scripts/ledger/adapters.sh`, `scripts/ledger/index.sh` (hosted items), `scripts/ledger/validate.sh` (`--all` over hosted items), `_VERBS` row (`note <ref> <text> kind=`), `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger note <ref> "<text>" [--kind log|ruling|owed]`: file items — append `- <YYYY-MM-DD> <text>` under `log_heading` (created at the end when absent), under `## Rulings` with `RULING:` for `ruling`, or set `owed` (empty text clears it); hosted items — adapter `note`/`write`.
- Items adapter (§G): `list [--since <ts>]`, `write <ref> <field> <value>`, `note <ref> <text>`, `create --title T --body-file F` → `{"ref","url"}`.
- `ledger-items-gh.sh`: `list` via `gh issue list --state all --limit 1000 --json number,title,body,state,stateReason,labels,updatedAt,url`; `ledger`/`severity` from labels with prefixes (`LEDGER_GH_LEDGER_PREFIX` default `ledger:`, `LEDGER_GH_SEV_PREFIX` default `sev:`); other fields from the body block between `<!-- doc-superpowers-ledger` and `-->` (same grammar as frontmatter); status: `OPEN` → `Open`, `CLOSED`+`COMPLETED` → `Fixed`, `CLOSED`+`NOT_PLANNED` → `Won't Fix`, any closed with `superseded_by` in the block → `Closed`; `write` edits labels or rewrites the block (`gh issue edit --body-file`); `note` = `gh issue comment`; `create` = `gh issue create`.
- Index: hosted items with `path` = `gh#<number>` and `url`, cached via `_lg_remote_cache items`; offline → last cache + a `stale` marker in views.

- [ ] **Step 1: Failing tests:** `test_lg_note_log_appends` · `test_lg_note_ruling_heading` · `test_lg_note_owed_set_and_clear` · `test_lg_items_gh_list_normalises` · `test_lg_items_gh_block_roundtrip` · `test_lg_items_gh_close_reason_mapping` · `test_lg_items_offline_stale_marker` · `test_lg_validate_all_hosted_items`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): notes, items adapter, GitHub reference adapter`.

### Task 14: `init` — sources, registry proposal, assignment decisions file

**Files:** Create `scripts/ledger/init.sh`; modify `_VERBS` row (`init dry-run registry= report= accept= import sources=`), `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger init --report <file> [--registry <file>] [--sources files,github]` (writes only the report, the decisions file and `docs/ledger/ledgers.proposed.json`):
  1. Sources: item globs; a suggestion (not auto-added) for any tracked dir whose `*.md` files carry `status:` frontmatter in ≥ 3 files; GitHub when `--sources github` or `items.adapter` is set and `gh repo view --json hasIssuesEnabled` is true; hand-written ledgers = tracked `*.md` with a markdown table whose header has a `#` column and a column whose cells link to item files, plus every file named in `legacy_ledgers` wherever it lives (an archived ledger included).
  2. Registry proposal (when `--registry` absent and `ledgers.json` absent): one ledger per top-level code dir, and per second-level dir of the largest top-level dir when it holds > 40 % of tracked code files; `docs`, `.github`, CI dirs, `scripts`, test dirs → `platform`; per ledger, hints from item `component`/`area` values, GitHub labels, hand-written ledger names, and initial contracts from `contracts` adapter entries whose `defined_in` falls in its paths; `validate --registry` findings appended to the report. Never overwrites `ledgers.json`.
  3. Assignment suggestions (needs a registry — `--registry` or `ledgers.json`): per item — a registered existing `ledger` value; membership in a hand-written ledger named like a registered id; owner of the item's `paths` by plurality, skipping hub files cited by > 5 % of items; a `ledger:` label; else `unassigned`. Written to `<report>.decisions.tsv`: `path<TAB>class<TAB>suggestion<TAB>reason<TAB>decision`, `decision` pre-filled with the suggestion for terminal items and empty for open ones.

- [ ] **Step 1: Failing tests** (fixture: `app/checkout/…`, `server/orders/…`, 6 issues incl. one with `related-files` under `server/orders`, a fake `gh`, `docs/ledgers/checkout-ledger.md` with 3 rows — one done, one open linking a plan, one open linking an issue): `test_lg_init_report_writes_only_report_files` · `test_lg_init_registry_proposal_mece` · `test_lg_init_registry_hints_and_contracts` · `test_lg_init_assignment_reasons` · `test_lg_init_hub_files_downweighted` · `test_lg_init_decisions_prefill` · `test_lg_init_github_source`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): init — sources, registry proposal, assignment decisions`.

### Task 15: `init --accept` — legacy import, stubs, summaries, keys, first views, `--import`

**Files:** Modify `scripts/ledger/init.sh`, `scripts/test-ledger.sh`.

**Interfaces:**
- `ledger init --accept <decisions.tsv> [--dry-run]`: applies only rows with a non-empty `decision` (a registered id or `unassigned`); writes `config.json` if absent (`{}` + detected sources), `legacy.json`, item fields (`ledger`; `summary` when missing; `key` for rows whose decision is a ledger and whose class is open — numbered per ledger in item-date order, allocated with **one** `_lg_alloc_batch` call), stubs, then renders the first views to `$_LG_CACHE/views` and prints their path. `--dry-run` prints the changes without writing.
- Legacy import: each hand-written row with a tracker link → `legacy.json` `{"<legacy-id>#<row>": {"key"|"item"}}`, where `<legacy-id>` is the id that `legacy_ledgers` (config, default `{}`) maps to that file, else the file stem with a trailing `-ledger` removed; a row whose tracker is not an item and whose state cell does not start (after `~~` stripping, case-insensitive) with `done|shipped|resolved|closed|superseded|dropped` → a stub item (file: `docs/issues/<YYYY-MM-DD>-<slug>.md`, `status: Open`, the row's suggested ledger, `summary` from the row, body `Migrated from <file> row <n>.` + the row text; hosted: adapter `create`); done rows without an item → `{"archived": "<file>#<row>"}`.
- Summaries: existing `summary`, else the legacy row's first `**bold**` span, else H1, else first sentence of `first_para`; truncated to 140 chars at a word boundary.
- `ledger init --import`: converts hosted items to file items once (link back via `note`; closes nothing).
- Idempotent: a second `--accept` of the same file changes nothing; new items/rows only on a fresh `--report`.

- [ ] **Step 1: Failing tests:** `test_lg_init_accept_only_decided_rows` · `test_lg_init_legacy_map_and_stub` · `test_lg_init_legacy_ids_from_config` (`legacy_ledgers: {"tier1": "docs/ledgers/tier1-pipeline-ledger.md"}` → keys `tier1#<row>`; unmapped `checkout-ledger.md` → `checkout#<row>`) · `test_lg_init_summaries_sources` · `test_lg_init_keys_one_commit_date_order` · `test_lg_init_first_views_rendered` · `test_lg_init_idempotent` · `test_lg_init_import_converts_once` · `test_lg_init_accept_dry_run`.
- [ ] **Steps 2–4:** FAIL → implement → PASS. **Step 5:** Commit `feat(ledger): init accept — legacy import, stubs, summaries, keys`.

---

## Chunk 5 — Hooks, vendoring, docs

### Task 16: `--ledger` hook set

**Files:** Create `scripts/hooks/git/ledger-post-commit`, `scripts/hooks/claude/ledger-session-notices.sh`, `scripts/hooks/claude/ledger-state-watch.sh`; modify `scripts/hooks/install.sh`, `references/hooks.md`, `scripts/test-hooks.sh`.

**Interfaces / rules:**
- `install.sh install --ledger [--claude]`: refuses (exit 1, message names `docs/ledger/config.json`) without the config; `--all` does **not** include it; `uninstall --ledger`; `status` reports the ledger set separately.
- Markers `# ledger-superpowers:begin` / `# ledger-superpowers:end` (they must not start with `# doc-superpowers:begin`, which `strip_blocks`/`blocks_balanced`/`has_block` match at `install.sh:343-392`).
- Git legs as **blocks**, never whole-file writes: pre-commit block runs `"$DOC_TOOLS" ledger validate --staged` (rc 1 or 2 blocks; `DOC_SUPERPOWERS_LEDGER_SKIP=1` bypasses with a printed reason line); pre-push block uses the stdin capture-and-replay idiom (`install.sh:569-572`) and refuses provisional keys in `cas` mode via `_lg_provisional_in_range`; post-commit → a block in `$HOOKS_DIR/post-commit` (the installer's resolved hooks dir, honouring `core.hooksPath` and linked worktrees; created with a shebang when absent) running `"$DOC_TOOLS" ledger inflight --push` in the background, output to `$_LG_CACHE/push.log`.
- Coexistence: when the git tier owns a hook file (`is_our_hook`), the ledger block is re-inserted after `install --git` re-renders it (install order independent); `uninstall --git` keeps a file that still holds a ledger block (removing only the git tier's content); `render_matches` ignores ledger blocks.
- Claude hooks (copied like the existing tier, second ownership regex beside :830): `SessionStart` → `ledger-session-notices.sh` (`ledger notices`, no `--fetch`, clipped to 15 lines with `hook-lib.sh` `_clip`/`_bounded`, silent when none); `PostToolUse` matcher `Write|Edit` → `ledger-state-watch.sh` (advisory line naming `doc-tools.sh ledger note <key> "…"` when the written path matches `state_watch.paths` — entries may start with `~/` (expanded to `$HOME`) and may contain `*` and the content matches the key regex plus one of `state_watch.patterns`; never blocks).

- [ ] **Step 1: Failing tests** (`scripts/test-hooks.sh`): `test_ledger_install_requires_config` · `test_ledger_all_excludes_ledger` · `test_ledger_blocks_markers_distinct` · `test_ledger_install_order_git_then_ledger` · `…_ledger_then_git` · `test_ledger_uninstall_each_tier_independent` · `test_ledger_pre_commit_blocks_invalid` · `test_ledger_pre_push_refuses_provisional_cas` · `test_ledger_pre_push_allows_provisional_merge_mode` · `test_ledger_pre_push_stdin_replayed` (both blocks see the ref lines) · `test_ledger_post_commit_backgrounds` (waits on a sentinel file with a timeout before teardown) · `test_ledger_session_hook_clip` (40 notices → ≤ 15 lines) · `test_ledger_state_watch_advisory`.
- [ ] **Steps 2–4:** FAIL → implement → `test-hooks.sh` and `test-ledger.sh` both shells PASS. **Step 5:** Commit `feat(ledger): opt-in hook set`.

### Task 17: Vendoring and the publish workflow

**Files:** Modify `scripts/doc-tools.sh` (`cmd_tools_install` :5254, uninstall :5312, status :5396, help rows :2250-2283), `scripts/hooks/install.sh` (`needed_helpers`/`vendor_sync` :1254-1319); create `scripts/hooks/ci/doc-ledger-publish.yml`; modify `.github/workflows/tests.yml` (drift `cmp` covers the vendored ledger files), `scripts/test-doc-tools.sh`.

**Interfaces / rules:**
- A `ledger` helper set: `tools install --helper ledger` copies `scripts/ledger/*.{sh,awk,jq}` to `<dest>/ledger/` and `scripts/adapters/*.sh` to `<dest>/adapters/` (so `$SCRIPT_DIR/ledger` resolves in the vendored copy); uninstall removes only byte-identical files; status reports them; `needed_helpers` returns `ledger` when the publish workflow is installed.
- `doc-ledger-publish.yml`: `schedule` (every 30 min) + `workflow_dispatch`, `contents: write`, vendors the helper set, runs `.github/scripts/doc-tools.sh ledger publish`.

- [ ] **Step 1: Failing tests:** `test_tools_install_ledger_helper_set` · `test_tools_uninstall_ledger_byte_identical_only` · `test_vendored_ledger_runs` (a vendored copy + helper set runs `ledger ls` in a fixture) · `test_ci_publish_template_vendors_ledger`.
- [ ] **Steps 2–4:** FAIL → implement → PASS (`test-doc-tools.sh`, `test-hooks.sh`, `test-ledger.sh`). **Step 5:** Commit `feat(ledger): vendoring and publish workflow`.

### Task 18: Docs, skill, lifecycle integration, release fragment

**Files:** Create `references/ledger.md`, `RELEASE-NOTES.next/ledger.md`; modify `skills/doc-superpowers/SKILL.md` (Quick Reference row; actions list :59; tool table row; `init` new step between 12 and 13 "Ledger (opt-in)": `ledger init --report`, review the proposed registry and the decisions file with the user, then `ledger init --accept`; step 14 also offers `hooks install --ledger`), `references/spec-lifecycle-actions.md` §Plan Phase (when `docs/ledger/config.json` exists: before the first task paste `ledger sweep --plan <plan>` as `## Related work`; each chunk gets "Ledger notices (chunk N)" running `doc-tools.sh ledger notices --gate`), `references/integration-patterns.md`, `README.md`, `CLAUDE.md` (tree, key files, suites, subcommand count), `docs/conventions.md:82`, `docs/superpowers/specs/2026-10-12-work-ledger-design.md` (Verification 4: "a rejected nested map"; Verification 12: "finalize rewrites references to the provisional key in items and adds one line per key to `finalized.json`; nothing else"; Verification 8: "CI runs a 300-item smoke with budgets ×3; `scripts/bench-ledger.sh 3000` is the full check"); modify `scripts/ledger/lib.sh` (`_lg_status_class <tracker>` → `open|fixed|closed|wontfix|unknown`).

- [ ] **Step 1:** `test_lg_status_class_helper` (key, path, unknown) → FAIL; implement; PASS.
- [ ] **Step 2:** Write the docs. `references/ledger.md` covers every config key + default, registry, item fields, verbs (synopsis + exit codes), adapters (exact JSON lines), hooks, views, init (report → decisions → accept), `legacy.json` and `finalized.json` formats, the privacy note for in-flight refs.
- [ ] **Step 3:** Every suite in both shells (`test-doc-tools`, `test-hooks`, `test-spec-status-model`, `test-doc-pr-release`, `test-merge-driver`, `test-spec-claims`, `test-ledger`) → PASS; `bash scripts/doc-tools.sh check-version` unchanged (manifests stay 3.1.0 — release is post-rebase).
- [ ] **Step 4:** Commit `docs(ledger): reference, skill, lifecycle and integration docs`.

---

## After the 3.2.0 rebase (not part of this execution; for the release session)

1. Rebase onto the 3.2.0 release; keep both families in `_VERBS`/`_USAGE_NOTES`/`_main`/exit hooks.
2. Spec-claims V5: with the ledger enabled, a tracker resolvable by `_lg_status_class` uses it (`Won't Fix` counts closed); tests `test_v5_ledger_key_tracker`, `test_v5_ledger_wontfix_closed`, byte-identical V5 output with the ledger off. Item pages and `show` gain counts of `diverged`/`unbuilt` claims an item tracks (§I).
3. `bump-version 3.3.0`, `## v3.3.0` RELEASE-NOTES entry from the fragment, `check-version`, `install.sh install --ci` refresh, system-overview label.

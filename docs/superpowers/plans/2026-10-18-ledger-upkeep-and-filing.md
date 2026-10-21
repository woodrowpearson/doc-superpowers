# Work ledger: filing flow and merge-time upkeep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ledger new --create` + the `/doc-superpowers ledger file` flow (#36 row 1) and `ledger upkeep` with its `validate --pushed` advisory and review-pr leg (#39).

**Architecture:** One new ledger module, `scripts/ledger/upkeep.sh` (sourced by `lib.sh` after `relations.sh`), holds the upkeep core as one function the verb and `validate --pushed` share; `--create` extends `cmd_ledger_new` in `keys.sh`, reusing init's item-dir, slug and stub-defaults helpers; `read_by` is one more contract field through registry validation, the adapter contract and the index. Docs: `references/ledger.md`, SKILL.md, the doc-tools.sh help table (which is also the verb/option dispatch table).

**Tech Stack:** bash 3.2+ (no bash-4 constructs: `test-doc-tools.sh` has a static guard), jq ≥ 1.6 (no 1.7-only forms; guarded too), POSIX awk, git.

**Spec:** `docs/superpowers/specs/2026-10-18-ledger-upkeep-and-filing-design.md` — read it first; its section numbers (§1–§6) are cited below and hold every exact string.

## Global Constraints

- bash 3.2 compatible; every test passes under `/usr/local/bin/bash` (5.x, this host) and `/bin/bash` (3.2): `BASH_BIN=$B $B scripts/test-ledger.sh`.
- jq floor 1.6; awk is `LC_ALL=C awk` (POSIX); no new runtime dependency.
- Every verb prints exactly one JSON object with `--format json` (`_lg_emit`); exits 0/1/2/3 per `references/ledger.md` → *Output and exit codes*; inert without `docs/ledger/config.json` (handled by `_lg_init`).
- A new option or verb is declared in doc-tools.sh's help table line `ledger <verb>|cmd_ledger_<verb>|repo|<opts>` — that line is the parser's spec (`name=` one value, `name+` values to the next option, bare = flag; `-` in a name becomes `_` in `_OPT_`).
- Comment density and naming follow the surrounding module (`_lg_<area>_<name>` functions, `_LG_JQ_<NAME>` jq programs, a header comment per function stating inputs/outputs).
- Never write `key`, `aliases`, `finalized.json` by hand; `link` writes relations; upkeep and review-pr write nothing.
- Not in this branch: RELEASE-NOTES.md, version bumps, `scripts/hooks/install.sh`, CI templates (a parallel session owns them).
- Test counts live only in CLAUDE.md → *Testing* (update in Task 8; base is v3.5.0's 11942).
- shellcheck at warning severity is a gate (`test-doc-tools.sh`): a new option a handler reads as plain `"$_OPT_x"` / `"${_OPTV_x[@]}"` without a default goes in doc-tools.sh's `_shellcheck_opt_names` (`_OPT_range` is already there); a finding is fixed, or disabled on its own line with a reason.
- The pre-PR gate is `bash scripts/check-ci.sh` (all seven suites under both detected interpreters, self-install drift, check-version); `bash scripts/check-ci.sh --bash /bin/bash ledger` runs one.

## Review Focus

1. **A push must never be blocked by the new advisory**: a contracts adapter that fails, a range with 2,000 files, or a new branch (all-zeros `<a>`) — `validate --pushed` still exits 0 unless a provisional key blocks. (Task 6 tests the failing adapter and the zero range.)
2. **`--create` leaves nothing behind on failure**: a cas allocation that loses all retries (exit 2) or a usage error after the path is chosen must not leave a half-written or keyless file. (Task 2 tests exit 2 via an unpushable remote with `--finalize`.)
3. **Paths with spaces, unicode or a leading `-`** in the diff and in item `paths` attribute and print correctly (no word splitting, JSON-escaped). (Task 3 commits `src/order/total two.js`.)
4. **A merge commit inside the range** (trunk merged into the branch) must not make trunk's files look touched when the caller uses `<base>...HEAD`. (Task 3 tests `...` with a merge of main into the branch.)
5. **Message-only involvement is noisy**: a commit that merely mentions `app-1` in prose ("unlike app-1") must not receive listed-path `consumes` proposals (rank rule in spec §4). (Task 4 tests it.)

---

### Task 0: A null config `base` means the default

Found while reviewing the abundance install (2026-10-19; abundance-mvp itself has no `base` key, so it is not affected): a host config that writes `"base": null` explicitly replaces the default (`$d * $h`), so keys.sh, relations.sh, index.sh, inflight.sh and views.sh read base `""`. `validate --pushed 000..tip` on a new branch then refuses every provisional key already at the tip ("config base \"\" does not resolve here"), `publish` dies ("config base is not a revision: ''"), and `trailers.since: "adoption"` finds no adoption commit. Upkeep's all-zeros and `--pr` (open PR) ranges read the same base, so this lands first.

**Files:**
- Modify: `scripts/ledger/config.jq` (after `$d * $h`: a null `base` takes `$d.base`; the header comment says so)
- Modify: `references/ledger.md` (*Config* `base` row: "`null` is the default")
- Test: `scripts/test-ledger.sh`

- [ ] **Step 1: Write the failing tests**

```bash
test_lg_config_base_null_is_default() {
  echo "test: a host config \"base\": null means the default origin/main (not no base)"
  # config {"base": null, keys cas}; main carries an item with a provisional key, pushed to the bare remote;
  # a new branch off it adds nothing: validate --pushed 0000000000000000000000000000000000000000..HEAD → rc 0
  # the same with "base": "origin/main" → rc 0 (unchanged); with "base": "nope/x" → the nobase refusal (rc 1, unchanged)
  # ledger show <item> --format json: .item still resolves (no "not a revision" die)
}
```

- [ ] **Step 2: Run** the suite — Expected: the new test FAILs (rc 1 with base null).
- [ ] **Step 3: Implement** in config.jq.
- [ ] **Step 4: Run** the suite — Expected: all pass.
- [ ] **Step 5: Commit** `fix(ledger): a null config base means the default (origin/main)`

---

### Task 1: Contract `read_by` (registry, adapter, index)

**Files:**
- Modify: `scripts/ledger/validate.sh` (registry shape + glob checks, ~lines 60–95: treat `read_by` exactly as `defined_in`)
- Modify: `scripts/ledger/adapters.sh` (~line 100: the `list` line validator accepts an optional `read_by` string list)
- Modify: `scripts/ledger/index.sh` (~lines 1151–1170: carry `read_by` through the registry/adapter merge — registry's when non-empty, else the adapter's, else `[]`)
- Modify: `scripts/ledger/glob.sh` only if `validate --registry`'s glob check enumerates fields there (~line 182)
- Modify: `references/ledger-index.schema.json` (contract `required` + property), `references/ledger.md` (*Registry* bullet for `contracts[]`, *Adapters* `contracts` row)
- Test: `scripts/test-ledger.sh`

**Interfaces:**
- Produces: every index contract object has `read_by: [glob…]` (a list, possibly empty). Task 4 reads `$ix.contracts[].read_by`.

- [ ] **Step 1: Write the failing tests** (register them in `run_tests` under a new `# --- upkeep / filing (#36, #39) ---` comment)

```bash
test_lg_contract_read_by_index() {
  echo "test: #39 — contracts[].read_by: registry globs reach the index (always a list); the adapter's fill an empty registry list"
  # registry: field:order.total read_by ["src/cart/*.js"]; component:Sheet without read_by;
  # a contracts adapter (/bin/sh stub) listing component:Sheet with read_by ["src/ui/**"] and field:order.total with read_by ["x/**"]
  # assertions (via lg show ... or the index file the lg_ix_item helper reads):
  #   field:order.total read_by == ["src/cart/*.js"]   (registry wins)
  #   component:Sheet   read_by == ["src/ui/**"]       (adapter fills)
  #   endpoint:create   read_by == []
}
test_lg_registry_read_by_shape() {
  echo "test: #39 — validate --registry: read_by not a list of strings is a shape finding; a bad glob in it is reported like defined_in's"
  # "read_by": "src/x.js"  → class shape, detail contains 'read_by is not a list of strings'
  # "read_by": ["src/{a"]   → the same class/detail a bad defined_in glob gets
}
test_lg_adapter_read_by_contract() {
  echo "test: #39 — a contracts adapter line whose read_by is not a string list breaks the contract: exit 2 (show)"
}
```

- [ ] **Step 2: Run** `BASH_BIN=/usr/local/bin/bash /usr/local/bin/bash scripts/test-ledger.sh 2>&1 | grep -E "FAIL|Results"` — Expected: the three new tests FAIL.
- [ ] **Step 3: Implement** the four touch points above; schema: add `"read_by"` to the contract's `required` and `properties` (`$ref: #/$defs/strList`, description "Globs of the files that read it (registry, else the contracts adapter); upkeep's reader signal").
- [ ] **Step 4: Run** the suite — Expected: all pass (3204 + new).
- [ ] **Step 5: Commit** `feat(ledger): contracts carry read_by globs (registry, contracts adapter, index)`

---

### Task 2: `ledger new --create`

**Files:**
- Modify: `scripts/doc-tools.sh` (help table line `ledger new|cmd_ledger_new|repo|…`: add `create title= body-file= paths= sev=`; its usage line and help text per spec §1)
- Modify: `scripts/ledger/keys.sh` (`cmd_ledger_new`, ~line 1146; a new helper `_lg_k_create_path` and the one-write file builder)
- Modify: `references/ledger.md` (*Verbs* `new` row; *Example: a filing wrapper* rewritten to `new --create … --suggest-contracts`)
- Test: `scripts/test-ledger.sh`

**Interfaces:**
- Consumes: `_lg_init_item_dir` (→ `$_LG_INIT_IDIR`), `_lg_init_stub_defaults <today> <out>` (tab lines `q|b <name> <value>`), jq `lg_stubslug` (init.sh line ~1011; lift it into a shared jq def string if it is not reachable from keys.sh), `_lg_init_glob_check`, `_lg_fm_ops_reset` / `_lg_fm_op set|setq` / `_lg_fm_ops_apply`, `_lg_alloc`, `_lg_k_emit_lines`.
- Produces: `_lg_k_create_path <title> → $_LG_KC_PATH` (the free `<dir>/<date>-<slug>[-n].md`); JSON payload key `created: true`.

- [ ] **Step 1: Write the failing tests**

```bash
test_lg_new_create_writes_item() {
  echo "test: #36 — ledger new --create: <dir>/<today>-<slug>.md with status (status.open[0]), date, severity, paths, stub_defaults, then key/ledger/summary; H1 + body"
  # config {"base":"main","keys":{"mode":"merge"},"init":{"stub_defaults":{"type":"bug","verify":"code"}}}, LG_REG_REL registry
  # body.md = "Steps:\n1. refund\n"
  lg new --create --title "Refund totals round twice!" --ledger app --summary "Totals round twice on refunds" \
     --sev P1 --paths src/order/total.js,src/cart/badge.js --body-file body.md --format json
  # rc 0; .created == true; .path == "docs/issues/$(date +%F)-refund-totals-round-twice.md"; .key matches ^app-~
  # lg_fmblock == "status: open|date: <today>|severity: P1|related-files: [src/order/total.js, src/cart/badge.js]|type: bug|verify: code|key: <key>|ledger: app|summary: Totals round twice on refunds"
  # body after frontmatter == "# Refund totals round twice!\n\nSteps:\n1. refund"
  # second identical call → path ends "-2.md"
  # text mode: first line "created docs/issues/<…>.md", second "<key>  <path>"
}
test_lg_new_create_usage() {
  echo "test: #36 — --create usage: with --file, flags without --create, empty or multi-line title, unreadable --body-file, items.adapter set, --sev outside severity_order: exit 3, no file"
  # each: rc 3 and `git status --porcelain docs/issues` empty
}
test_lg_new_create_no_file_on_failure() {
  echo "test: #36 — --create --finalize with an unreachable remote (cas): exit 2 and no file written"
  # config keys.mode cas, remote origin pointing at "$TEST_DIR/none.git"; rc 2; no new file under docs/issues
}
test_lg_new_create_suggest_contracts() {
  echo "test: #36 — --create --suggest-contracts: the new item's candidates (changes field:order.total from its listed src/order/total.js)"
  # JSON .candidates[0] == {field:"changes", contract:"field:order.total", …}
}
test_lg_new_create_glob_mismatch() {
  echo "test: #36 — items.globs whose first entry is not <dir>/<pattern>.md and docs/issues/*.md not matched: exit 3 naming --file"
}
```

- [ ] **Step 2: Run** the suite — Expected: the five FAIL.
- [ ] **Step 3: Implement.** Order inside `cmd_ledger_new` when `--create`: validate flags → `_lg_k_create_path` → glob check → allocate with the computed path (`_lg_alloc "$L" 1 "$F"` exactly as today; `unassigned` allocates nothing) → build the whole file in `$s/new.md` (frontmatter `---` block via `_lg_fm_op`s on a seed file holding only `---\n<status>: <open>\n---\n# <title>\n\n<body>`) → `_lg_init_put`-style move into place (refuse a symlink, as `_lg_init_put` does) → payload `+ {created: true}` → `_lg_k_emit_lines`. YAML-typed stub default strings are quoted exactly as init does (reuse the `q` flag).
- [ ] **Step 4: Run** the suite — Expected: all pass.
- [ ] **Step 5: Commit** `feat(ledger): new --create writes the item file (one write, all or nothing)`

---

### Task 3: `ledger upkeep` — range, involved items, `changes` proposals

**Files:**
- Create: `scripts/ledger/upkeep.sh` (header comment = spec §4 condensed, like `relations.sh`'s per-verb headers)
- Modify: `scripts/ledger/lib.sh` (source `upkeep.sh` after `relations.sh`, with the `# shellcheck source=` line)
- Modify: `scripts/ledger/config.jq` (`"upkeep": {"skip_globs": [spec §4 default list verbatim], "skip_contracts": []}`)
- Modify: `scripts/doc-tools.sh` (help table: `ledger upkeep|cmd_ledger_upkeep|repo|range= pr= items+ top= strict no-repo-adapters format=` after `ledger recheck`; usage line; help paragraph; the "Work ledger (ledger show, …)" verb list)
- Modify: `scripts/test-ledger.sh` (`LG_VERBS` gains `upkeep` after `recheck`; the inert test then covers it)
- Test: `scripts/test-ledger.sh`

**Interfaces:**
- Consumes: `_lg_msg_claims <rev-args…>` (relations.sh:241), `_lg_r_file_contracts <index> <files-lines> <out.json>` (relations.sh:970), `_LG_JQ_RESOLVE_DEFS` / `lg_resolve`, `lg_r_maps` (defs.jq:207: `.BYP` path→item, `.K2P` key→path, `.D` file→contract ids, `.P` file→paths), `_lg_paths_filter` (glob matching of a NUL list), `_lg_index` with `_LG_IX_NEED_CONTRACTS=1`.
- Produces (for Tasks 4–6): `_lg_up_core <a-oid> <b-oid> <body-file|""> <named-paths-file|""> <out.json>` writing `{range, files, commits, items:[{key,path,found_by,rank,proposed,total,truncated,declared_untouched,link}], unattributed_contracts:[{contract,files}], touched:[{contract, files, cc_line|null}]}` — `touched` is internal (stripped from the verb's payload; `validate --pushed` reads it); `_lg_up_range <spec> → $_LG_UP_A $_LG_UP_B` (dies 2 when an end does not resolve); `cmd_ledger_upkeep`.

- [ ] **Step 1: Write the fixture and failing tests**

```bash
# lg_upkeep_fixture: lg_rel_fixture + committed src/order/total.js, "src/order/total two.js",
# src/cart/badge.js, src/util/a.js, server/create.js, docs/notes.md, src/order/total.test.js on main;
# then `git checkout -q -b feat` for the test's own commits.
test_lg_upkeep_changes_proposal() {
  echo "test: #39 — upkeep: a range whose commit claims app-6 (Ledger-Claims) and edits src/order/total.js proposes changes field:order.total to app-6, with evidence and a link line"
  # commit on feat: edit src/order/total.js, message "fix totals\n\nLedger-Claims: app-6"
  lg upkeep --range main..feat --format json
  # rc 0; .items[0].key=="app-6"; .items[0].found_by==["trailer:claims"]
  # .items[0].proposed[0]=={"field":"changes","value":"field:order.total","evidence":["diff touches src/order/total.js (defined_in of field:order.total)"]}
  # .items[0].link=="ledger link app-6 --changes field:order.total"
  # text: line 1 starts "range "; contains "app-6  found by trailer:claims"; "  + changes field:order.total  — diff touches src/order/total.js"
}
test_lg_upkeep_covered_and_untouched() {
  echo "test: #39 — a contract an involved item already declares in changes is proposed to nobody; declared changes the range misses are declared_untouched"
  # claim app-1 (changes field:order.total) and app-6 together; edit src/order/total.js → no proposal for either;
  # claim app-1 and edit only src/util/a.js → app-1 .declared_untouched==["field:order.total"]
}
test_lg_upkeep_found_by_signals() {
  echo "test: #39 — found_by: trailer:claims_by_path, item-file-edited, key-in-message (an alias too), ranked; --items restricts to named items"
  # config trailers.claims_by_path ["Doc-Fixes"]; commits: one "Doc-Fixes: docs/issues/h.md", one editing docs/issues/g.md,
  # one message "see APP-4 for context"; .items[].found_by per item; --items app-4 → only app-4, found_by ["named"]
  # --items nope-9 → rc 3
}
test_lg_upkeep_attribution() {
  echo "test: #39 — several involved items: the contract goes to the one whose paths overlap its defined_in most (then diff overlap, rank, key)"
  # app-6 lists src/order/total.js, app-4 lists none of src/order/*: both claimed → changes field:order.total proposed to app-6 only
}
test_lg_upkeep_skip_globs_and_contracts() {
  echo "test: #39 — a contract touched only through skip_globs files (a .test.js, a .md) is not touched; upkeep.skip_contracts ids are never proposed"
}
test_lg_upkeep_contract_change_trailer() {
  echo "test: #39 — a Contract-Change: endpoint:create — <line> trailer touches the contract with that evidence, ranked first"
}
test_lg_upkeep_unattributed() {
  echo "test: #39 — no involved item: unattributed_contracts [{contract, files}] and '(no proposals)'"
}
test_lg_upkeep_three_dot_and_merge() {
  echo "test: #39 — --range main...feat after main moved and was merged into feat: only feat's own files count"
}
test_lg_upkeep_spaced_path() {
  echo "test: #39 — a diff file with a space (src/order/total two.js) matches defined_in src/order/*.js and is printed whole in evidence and JSON"
}
test_lg_upkeep_top_strict_exits() {
  echo "test: #39 — --top 1 truncates (total/truncated, 'showing 1 of 2'); --strict with proposals exit 1, without 0; bad range exit 2; neither/both --range/--pr, --top x: exit 3"
}
```

- [ ] **Step 2: Run** the suite — Expected: new tests FAIL (`ledger upkeep` unknown verb → 3).
- [ ] **Step 3: Implement** `_lg_up_range`, `_lg_up_core`, `cmd_ledger_upkeep` per spec §4 (*Range*, *Involved items*, *Touched contracts*, *Proposals* — the `changes` half, *Output and exits*). One `git diff --name-only -z --no-renames <a> <b>` (net diff; `...` resolved to the merge-base first), one `_lg_msg_claims "<a>..<b>"`, one `git log --format=%x01%H%n%B <a>..<b>` for the word scan, one index build. Do the joins in one jq program (`_LG_JQ_UPKEEP`) over the index with the diff/claims/words as `--slurpfile`/`--rawfile` inputs; glob-match diff files against `skip_globs` with `_lg_paths_filter` before `_lg_r_file_contracts`. Until Task 5, `--pr` and `--no-repo-adapters` exit 3 (`ledger upkeep: --pr is not available yet`); Task 5 replaces that branch and owns their tests.
- [ ] **Step 4: Run** the suite — Expected: all pass (the inert-every-verb test now includes `upkeep`).
- [ ] **Step 5: Commit** `feat(ledger): upkeep — propose missing changes from a range's diff`

---

### Task 4: `ledger upkeep` — `consumes` proposals

**Files:**
- Modify: `scripts/ledger/upkeep.sh` (`_LG_JQ_UPKEEP`)
- Test: `scripts/test-ledger.sh`

**Interfaces:**
- Consumes: Task 1's `read_by`; Task 3's `_lg_up_core` and attribution.
- Produces: `consumes` entries in `items[].proposed` (spec §4 *Proposals* (a) and (b)), ranked after `changes`.

- [ ] **Step 1: Write the failing tests**

```bash
test_lg_upkeep_consumes_read_by() {
  echo "test: #39 — a range touching a read_by file (src/cart/badge.js, read_by of field:order.total) and no defined_in file proposes consumes field:order.total, evidence 'diff touches src/cart/badge.js (read_by of field:order.total)'"
  # registry variant with read_by ["src/cart/*.js"]; claimed item app-5 (no consumes)
  # an item already consuming it (app-2 claimed instead) → nothing proposed
  # a range touching both src/cart/badge.js and src/order/total.js → changes, not consumes (read only when defined_in is untouched)
}
test_lg_upkeep_consumes_listed_unchanged() {
  echo "test: #39 — an involved item listing src/order/total.js that the range does not change gets consumes field:order.total ('the item lists src/order/total.js (defined_in of field:order.total), which the range does not change')"
}
test_lg_upkeep_message_only_no_listed_consumes() {
  echo "test: #39 — an item found only by key-in-message gets no listed-path consumes proposal (rank rule)"
}
test_lg_upkeep_ranking_and_cap() {
  echo "test: #39 — per item: changes before consumes; default --top 3 keeps three, total counts all"
}
```

- [ ] **Step 2: Run** — Expected: FAIL. **Step 3: Implement.** **Step 4: Run** — Expected: all pass.
- [ ] **Step 5: Commit** `feat(ledger): upkeep — consumes proposals from read_by and listed, unchanged files`

---

### Task 5: `ledger upkeep --pr` and `--no-repo-adapters`; the PR adapter's `view`

**Files:**
- Modify: `scripts/ledger/upkeep.sh` (`_lg_up_pr <n>`: reads the cached PR list through the existing adapter layer — find the function `ls` uses for `pr_data`; `view` through `_lg_adapter pr view <n>`)
- Modify: `scripts/ledger/adapters.sh` (allow the `view` subcommand; exit 3 from it = unsupported)
- Modify: `scripts/adapters/ledger-pr-gh.sh` (`view <n>` → `gh pr view <n> --json number,body` → one line `{"number":n,"body":"…"}`)
- Modify: `references/ledger.md` (*Adapters* `pr` row: optional `view <n>`)
- Test: `scripts/test-ledger.sh` (stub `pr` adapters as `/bin/sh` scripts, as the existing PR-adapter tests do)

**Interfaces:**
- Consumes: Task 3's `_lg_up_core <a> <b> <body-file> …`.
- Produces: JSON `pr: {number, state, body_scanned}`; found_by `key-in-pr-body`.

- [ ] **Step 1: Write the failing tests**

```bash
test_lg_upkeep_pr_merged_and_open() {
  echo "test: #39 — --pr N: merged → merge_commit^1..merge_commit; open → merge-base(base, head_oid)..head_oid; the body's keys are key-in-pr-body"
  # stub list prints {"number":7,"head":"feat","state":"merged","url":"u","head_oid":<feat>,"merge_commit":<m>} and
  # {"number":8,"head":"feat2","state":"open","url":"u","head_oid":<feat2 tip>}; view 8 prints {"number":8,"body":"Fixes the badge (app-5)"}
  # --pr 7: .range == "<m^1>..<m>"; --pr 8: app-5 found_by contains "key-in-pr-body"; .pr.body_scanned true
}
test_lg_upkeep_pr_failures() {
  echo "test: #39 — --pr without adapters.pr, an adapter failing, an unknown number, a closed PR, a merge_commit not here: exit 2 (never '(no proposals)'); view exit 3: body_scanned false, rc 0"
}
test_lg_upkeep_no_repo_adapters() {
  echo "test: #39 — --no-repo-adapters: exit 2 naming the adapter when adapters.contracts / adapters.pr / items.adapter is a repository path; null or doc-superpowers:<name> runs; the refusing run executes no adapter"
  # the repository adapter stub writes a marker file when run: assert it is absent after the refusal
}
```

- [ ] **Step 2: Run** — Expected: FAIL. **Step 3: Implement.** **Step 4: Run** — Expected: all pass.
- [ ] **Step 5: Commit** `feat(ledger): upkeep --pr (merged/open PRs, body keys) and --no-repo-adapters`

---

### Task 6: `validate --pushed` advisory `undeclared-contract-change`

**Files:**
- Modify: `scripts/ledger/validate.sh` (`_lg_validate_pushed`, ~line 1014: run the cas provisional check only in cas mode, then the advisory in both modes)
- Modify: `scripts/doc-tools.sh` (`ledger validate` help text: the new class)
- Modify: `references/ledger.md` (*Validation* class list; *Hooks* pre-push bullet: one sentence)
- Test: `scripts/test-ledger.sh`

**Interfaces:**
- Consumes: `_lg_up_core` (its `touched` and `items`); the contracts adapter failure must be caught: call the core in a subshell / with the index built under a guard so that `_lg_die` from the contracts adapter becomes one advisory finding (spec §5 detail `could not check: <message>`), never exit 2.

- [ ] **Step 1: Write the failing tests**

```bash
test_lg_validate_pushed_undeclared_contract_change() {
  echo "test: #39 — validate --pushed: a pushed range involving app-6 that changes field:order.total → one advisory undeclared-contract-change (exit 0), detail names ledger upkeep --range; a range involving no item: no finding"
  # merge mode too; JSON finding {class, severity:"advisory", path:"src/order/total.js", key:"app-6", detail contains "ledger upkeep --range"}
}
test_lg_validate_pushed_advisory_zero_range_and_cap() {
  echo "test: #39 — all-zeros <a>: merge-base(base, b)..b; more than 10 contracts: 10 findings and one '… N more contracts'"
}
test_lg_validate_pushed_adapter_failure_never_blocks() {
  echo "test: #39 — a failing contracts adapter: one advisory 'could not check: …', exit 0; a provisional key in cas still blocks (exit 1) alongside it"
}
```

- [ ] **Step 2: Run** — Expected: FAIL. **Step 3: Implement.** **Step 4: Run** the ledger suite and `scripts/test-hooks.sh` (the pre-push leg tests) — Expected: all pass.
- [ ] **Step 5: Commit** `feat(ledger): validate --pushed reports undeclared contract changes (advisory)`

---

### Task 7: Skill and reference docs — the filing flow and the review-pr leg

**Files:**
- Modify: `skills/doc-superpowers/SKILL.md` (`review-pr` step 9 per spec §6, with its exact command `"$DOC_TOOLS" ledger upkeep --range "$BASE...HEAD" --no-repo-adapters --format json`; `ledger` action: a **Filing** bullet routing `/doc-superpowers ledger file [<title>]` to `references/ledger.md` → **Filing an item**; Usage/Quick Reference mention)
- Modify: `references/ledger.md` (*Verbs*: `upkeep` row; a new `## Merge-time upkeep` section (spec §4–§6 condensed: range, involvement, proposals, exits, the advisory, review-pr leg, CI note); *Building on the ledger*: `upkeep` payload row in the payloads table, **Filing an item** procedure (spec §2 steps 1–7))
- Modify: `CLAUDE.md` (Commands: `/doc-superpowers ledger file`, `ledger upkeep`; Directory/Key Files: `scripts/ledger/` 12 → 13 modules with `upkeep`), `docs/codebase-guide.md` (module list), `README.md` (ledger feature bullets: one line each for filing and upkeep), `AGENTS.md` if it lists ledger verbs
- Modify: `scripts/test-spec-status-model.sh` (pins: SKILL.md review-pr section contains `ledger upkeep --range "$BASE...HEAD" --no-repo-adapters`; it says the step is skipped in a CI run; the `ledger` action names `ledger file` and `new --create`; references/ledger.md has `### Filing an item`)
- Test: `scripts/test-spec-status-model.sh`

- [ ] **Step 1: Write the failing pins** in `test-spec-status-model.sh` (next to the I-11 review-pr block, same `assert_contains "$_review" …` style).
- [ ] **Step 2: Run** `BASH_BIN=/usr/local/bin/bash /usr/local/bin/bash scripts/test-spec-status-model.sh 2>&1 | grep -E "FAIL|Results"` — Expected: the new pins FAIL.
- [ ] **Step 3: Write the docs.** review-pr stays "read-only: edits nothing and runs no repository script" — the step text says why `--no-repo-adapters` keeps that true.
- [ ] **Step 4: Run** all seven suites under bash 5 — Expected: all pass.
- [ ] **Step 5: Commit** `docs(ledger): the filing flow, merge-time upkeep and review-pr's ledger leg`

---

### Task 8: Validate on abundance-mvp (throwaway), replay, and close out

No shipped files except what the findings force (tuning defaults, fixes) and the close-out files listed in Step 6.

- [ ] **Step 1: Throwaway clone with a private remote** (scratchpad `$S`): `git clone -q --bare --shared ~/code/abundance-mvp "$S/ab-remote.git"`; `git clone -q --shared "$S/ab-remote.git" "$S/ab"`; in `$S/ab`: `git config remote.origin.url "$S/ab-remote.git"`; no hooks installed; `DT=<worktree>/scripts/doc-tools.sh`. Counter pushes land in `ab-remote.git`, never on GitHub or in `~/code/abundance-mvp`.
- [ ] **Step 2: Filing end to end:** `$DT ledger new --create --title "…" --ledger <an active id> --summary "…" --sev P2 --paths <two real files> --suggest-contracts --format json`, then `ledger related`, `ledger link … ` with two candidates, then `$DT ledger validate --staged` after `git add` → exit 0 (abundance has `require_relations: "new"`); also `--relations none` on a second item. Record outputs.
- [ ] **Step 3: Upkeep replay:** for the 50 most recent merged PRs (`GH_REPO=woodrowpearson/abundance-mvp gh pr list --state merged --limit 50 --json number,mergeCommit`), in a detached worktree of `$S/ab` at each merge commit: `$DT ledger upkeep --range <m>^1..<m> --format json`; collect per PR proposals, run time; precision proxy = proposals whose (item, field, value) the item declares at `origin/main` now; median proposals per PR; write `$S/upkeep-replay.md`.
- [ ] **Step 4: Tune** only through defaults the spec names (`--top` default, `skip_globs` default, the rank rule) if the replay shows a clear win; each change gets its unit test and a commit `fix(ledger): upkeep defaults from the abundance replay`.
- [ ] **Step 5: Delete the throwaway**: remove `$S/ab`, its worktrees and `$S/ab-remote.git`; confirm `~/code/abundance-mvp` `git status` and refs are unchanged (`git -C ~/code/abundance-mvp for-each-ref refs/doc-superpowers refs/heads/doc-superpowers` identical to before Step 1).
- [ ] **Step 6: Close out:** `bash scripts/hooks/install.sh install --ci` (doc-tools.sh changed → vendored copy) and commit what it writes; refresh the doc index for touched docs (`scripts/doc-tools.sh check-freshness` then `update-index` per stale entry); update CLAUDE.md → *Testing* counts from the suites' Results lines; run `bash scripts/check-ci.sh` (both interpreters; plugin-validate may SKIP); commit `docs(index): counts and index after upkeep/filing`.

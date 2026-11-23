# undeprecate-entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `deprecate-entry` an inverse, `undeprecate-entry`, so a doc that came back into use can leave `status: deprecated` without `remove-entry` + `add-entry` or a hand edit (GH #98).

**Architecture:** A new index writer in `scripts/doc-tools.sh`, built like `deprecate-entry`: one `_index_apply --report` pass under the index lock, its rows classified into changed / unchanged / not indexed. The index stores `status` only as `"deprecated"` (current and stale are computed by `check-freshness`), so undeprecating deletes the `status` key — exactly the shape a `git revert` of a deprecation already leaves, which the merge driver merges field by field today. A new patch-row form, `unset`, lets a row delete fields.

**Tech Stack:** bash 3.2 + jq ≥ 1.6; the shell test harness (`scripts/test-helpers.sh`).

**Spec:** GitHub issue woodrowpearson/doc-superpowers#98 (the "Proposal" section).

## Global Constraints

- bash 3.2 compatible; no jq-1.7-only form (static gates in `test-doc-tools.sh`); shellcheck clean at warning severity.
- `last_verified` is never touched: undeprecating is not a baseline reset (same as `deprecate-entry`).
- Per-path verb contract: takes the lock, writes atomically, a path not indexed is reported and skipped with the rest applied and exit 1; usage errors and a bad option exit 2 and write nothing; needs a git repository (dispatch mode `repo`).
- `superseded_by` is cleared only with `--clear-superseded-by`; then a successor whose `replaces` names the doc gets `replaces: null`; a successor whose `replaces` names another doc is left as it is.
- A run that changes nothing writes nothing (byte-identical index, no `generated_at` bump).
- `.github/scripts/doc-tools.sh` is installer output: after changing `scripts/doc-tools.sh`, run `bash scripts/hooks/install.sh install --ci` and commit what it writes.
- Docs edited in this change are re-baselined with `scripts/doc-tools.sh update-index` after being read against the code.
- No release bump in this change (a separate release PR, as the repo does).

## Review Focus

1. **Entry whose doc file is gone (`missing`).** Undeprecating needs no file read: it succeeds, and `check-freshness` then reports the doc `missing`. Test in Task 1.
2. **Already-live entry.** Reported `Unchanged … (not deprecated)`, exit 0, index byte-identical. Test in Task 1.
3. **`--clear-superseded-by` when the successor's `replaces` names a different doc, or the successor is not indexed.** The successor is left alone; no error; `superseded_by` still cleared. Test in Task 1.
4. **Undeprecated entry that still names a successor (no flag).** A `NOTE:` line tells the user the link is kept and how to drop it. Test in Task 1.
5. **Concurrent branches: one undeprecates, the other re-verifies the same doc.** The merge driver keeps both (status absent, the newer `last_verified`). Test in Task 2.

---

### Task 1: the `undeprecate-entry` verb

**Files:**
- Modify: `scripts/doc-tools.sh` — `_INDEX_PATCH` (~line 1496) and its comment; the `_VERBS` table (new row after `deprecate-entry`, ~line 2297; `update-index`'s help line "A deprecated entry stays deprecated." gains "(undeprecate-entry lifts it)"); the "Stored state" help paragraph (~line 3266); the index-writer list in the lock help line (~line 3237); new `cmd_undeprecate_entry` after `cmd_deprecate_entry` (~line 6382).
- Test: `scripts/test-doc-tools.sh` — new test functions, registered in `run_tests` next to the deprecate-entry tests; add `undeprecate-entry` to the existing loops: 0-byte index (~4267), bad option exit 2 (~4744), outside a git repo (~4997), arity exit 2 (~5170).
- Modify: `.github/scripts/doc-tools.sh` (installer output).

**Interfaces:**
- Produces: CLI `doc-tools.sh undeprecate-entry [--clear-superseded-by] <doc_path>...`; table row `undeprecate-entry|cmd_undeprecate_entry|repo|clear-superseded-by` (→ `_OPT_clear_superseded_by=1`).
- Produces: patch row `{"key": k, "unset": [field, …]}` — deletes those fields from an existing entry (absent key: no-op). May be combined with `merge` in the same row (`unset` first, then `merge`).
- Report lines (stderr): `_report_keys "Undeprecated" ""`; `_report_keys "Unchanged" "(not deprecated)"`; `ERROR: '<p>' not found in index; skipped (after a move-entry, name the new path).`; `Unlinked: '<succ>' no longer replaces '<p>'.`; `NOTE: '<p>' still names superseded_by '<succ>' (pass --clear-superseded-by to drop the link).`; final `N path(s) not in the index (see above).` then exit 1.

- [ ] **Step 1: Write the failing tests** in `scripts/test-doc-tools.sh`:

`test_undeprecate_entry_lifts_a_deprecation` — fixture as `test_i3_deprecate_entry_sets_replaces_not_last_verified` (architecture, new, other; `_mv_inject_sentinels`); `deprecate-entry docs/architecture.md --superseded-by docs/new.md`; then `undeprecate-entry docs/architecture.md`:
- rc 0; `.docs["docs/architecture.md"] | has("status")` → `false`; `last_verified` → `2020-01-01T00:00:00Z`; `superseded_by` → `docs/new.md`; `.docs["docs/new.md"].replaces` → `docs/architecture.md`;
- output contains `Undeprecated 1 entry:` and `still names superseded_by 'docs/new.md'`;
- `check-freshness` JSON: `.docs["docs/architecture.md"].status` is not `deprecated`.
- Re-run: output contains `(not deprecated)`, rc 0, index byte-identical (`cmp -s`).

`test_undeprecate_entry_clear_superseded_by` — same fixture, deprecate architecture → new, and other → new (new.replaces stays architecture):
- `undeprecate-entry --clear-superseded-by docs/other.md` → other's `superseded_by` `null`, `new.replaces` still `docs/architecture.md`, no `Unlinked`;
- `undeprecate-entry docs/architecture.md --clear-superseded-by` → architecture's `superseded_by` `null`, `new.replaces` `null`, output contains `Unlinked: 'docs/new.md' no longer replaces 'docs/architecture.md'.`, `new.last_verified` untouched;
- an entry deprecated `--superseded-by docs/nope.md` (unindexed) then undeprecated with the flag → rc 0, `superseded_by` `null`, `.docs | has("docs/nope.md")` `false`.

`test_undeprecate_entry_reports_unknown_and_missing` —
- `undeprecate-entry docs/architecture.md docs/nope.md` (architecture deprecated) → rc 1; architecture undeprecated anyway; output contains `'docs/nope.md' not found in index`;
- a deprecated entry whose file was `git rm`'d → rc 0, status gone, `check-freshness` reports it `missing`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bash scripts/test-doc-tools.sh 2>&1 | grep -E 'undeprecate|FAIL' | head`
Expected: FAILs (unknown subcommand).

- [ ] **Step 3: Extend `_INDEX_PATCH`** with `elif ($x | has("unset"))`: when the key is indexed, `delpaths([$x.unset[] | [.]])` on the entry, then `+= ($x.merge // {})`; else no-op. Order the branch before `merge` and document the row in the comment.

- [ ] **Step 4: Implement `cmd_undeprecate_entry "$@"`** in `scripts/doc-tools.sh`, modelled on `cmd_deprecate_entry`: index-exists check; `_usage_error undeprecate-entry` with no path; `_targets_from_args`; patch rows `{key, unset: ["status"]}` plus `merge: {superseded_by: null}` when the flag is set. With the flag, read under `_index_lock` (re-entrant) each target's `superseded_by` and whether that successor is indexed and its `replaces` names the target; append to the `_index_apply --report "$_INDEX_PATCH"…` program a reduce that sets those successors' `replaces` to `null`. Without the flag, collect targets that were deprecated and keep a non-null `superseded_by` for the `NOTE:` lines. Classify `_INDEX_CLASSES` as `deprecate-entry` does (`c` undeprecated, `u` unchanged, else not found).

- [ ] **Step 5: Add the `_VERBS` row and help** — usage line `[--clear-superseded-by] <doc_path>...`; text: reverses deprecate-entry: drops the stored status, so check-freshness judges the entry current or stale against its recorded baseline again; last_verified and every other field kept (not a baseline reset); superseded_by kept unless --clear-superseded-by, which also clears a successor's replaces that names the doc; unknown path reported and skipped, exit 1. Update the `update-index` and "Stored state" help lines and the lock-writer list.

- [ ] **Step 6: Add `undeprecate-entry` to the four contract loops** (0-byte index, `--bogus` exit 2, no git repo, arity exit 2 for bare `undeprecate-entry` and `undeprecate-entry --clear-superseded-by`).

- [ ] **Step 7: Run the suite**

Run: `bash scripts/test-doc-tools.sh 2>&1 | tail -5` and `/bin/bash scripts/test-doc-tools.sh 2>&1 | tail -5`
Expected: `0 failed` under both interpreters (static gates included).

- [ ] **Step 8: Re-vendor and commit**

```bash
bash scripts/hooks/install.sh install --ci
git add scripts/doc-tools.sh scripts/test-doc-tools.sh .github/scripts/doc-tools.sh
git commit -m "feat(doc-tools): undeprecate-entry reverses deprecate-entry (#98)"
```

### Task 2: merge-driver coverage

**Files:**
- Test: `scripts/test-merge-driver.sh` (after the "deprecate vs update-index" case, ~line 213). No driver change expected: `status` is two-valued (`deprecated` / absent), so a per-field three-way pick already orders it; the test pins that.

**Interfaces:**
- Consumes: `undeprecate-entry [--clear-superseded-by]` from Task 1.

- [ ] **Step 1: Write the case** `--- undeprecate vs update-index ---`: `base_repo`; on main `dt "$T1" deprecate-entry --superseded-by docs/b.md docs/a.md`, commit; branch A: `dt "$T2" undeprecate-entry --clear-superseded-by docs/a.md`, commit; branch B from main: change `src/a.js`, `dt "$T3" update-index docs/a.md`, commit; `run_ways`. Assert every way: `.docs["docs/a.md"] | has("status")` `false`; `superseded_by` `null`; `.docs["docs/b.md"].replaces` `null`; `last_verified` `$T3`; `assert_ways_same_docs`.

- [ ] **Step 2: Run it**

Run: `bash scripts/test-merge-driver.sh 2>&1 | tail -5`
Expected: `0 failed`. If it fails, the driver change goes in this task.

- [ ] **Step 3: Commit** `test(merge-driver): an undeprecation merges with a concurrent re-verify`.

### Task 3: docs

**Files:**
- Modify: `skills/doc-superpowers/SKILL.md` — tool table row after `deprecate-entry`; Index-write routing row "Doc back in use after a deprecation (reopened, or deprecated by mistake)" → `undeprecate-entry <doc>` (`--clear-superseded-by` when its successor no longer replaces it), Never: `remove-entry` + `add-entry` · hand-editing `status`; add the verb to the "Index writers" list.
- Modify: `references/doc-spec.md` — the `status` / `superseded_by` / `replaces` field rows and the transitions list (~1076-1090): `deprecated` → absent by `undeprecate-entry` only.
- Modify: `docs/conventions.md` (~467, 472 "nine" → "ten" writers, 505 table row), `docs/codebase-guide.md` (directory line, 22 → 23 subcommands, writer lists ~361), `docs/workflows/doc-superpowers.md` (~862), `CLAUDE.md` (directory line, 22 → 23 subcommands, test counts), `README.md` (~139 verb contracts: exit 1 for an unknown path, like `deprecate-entry`).

- [ ] **Step 1: Edit the docs above.**
- [ ] **Step 2: Run** `bash scripts/test-spec-status-model.sh 2>&1 | tail -3` — Expected `0 failed`.
- [ ] **Step 3: Re-baseline** the edited indexed docs with `scripts/doc-tools.sh update-index <docs…>`; `scripts/doc-tools.sh check-freshness` shows none of them stale.
- [ ] **Step 4: Run** `bash scripts/check-ci.sh --fast` — Expected: every suite passes; then update CLAUDE.md's assertion counts from the full suite run and commit `docs: undeprecate-entry in the skill, references and guides (#98)`.

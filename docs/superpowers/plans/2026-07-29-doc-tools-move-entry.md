# `doc-tools.sh move-entry` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `move-entry <old-path> <new-path>` subcommand that re-keys a `docs/.doc-index.json` entry in place without losing metadata, closing [`docs/issues/2026-07-29-doc-tools-has-no-move-entry-operation.md`](../../issues/2026-07-29-doc-tools-has-no-move-entry-operation.md).

**Architecture:** One new `cmd_move_entry()` in `scripts/doc-tools.sh` following the existing path-verb shape (`normalize_doc_path()` at the boundary → in-memory `jq` mutation → single write → stderr report). The entry object is carried over **wholesale** via `jq` object addition so unknown fields survive; only `content_hash` is adjusted. The re-key is done with `to_entries | map | from_entries` so the key keeps its position in `.docs` and the resulting `git diff` is one renamed key rather than a delete-plus-append. A companion one-line fix stops `build-index`/`add-entry` writing the phantom `code_refs: [""]`. Every site that enumerates the verb list is updated in the same change, plus the five hook scripts whose missing-doc advice currently offers only the two lossy verbs.

**Tech Stack:** `bash` (must run under bash 3.2.57 — macOS system bash — as well as 5.x), `jq`, the repo's `scripts/test-helpers.sh` harness, `shellcheck`.

## Global Constraints

- **Issue:** [`docs/issues/2026-07-29-doc-tools-has-no-move-entry-operation.md`](../../issues/2026-07-29-doc-tools-has-no-move-entry-operation.md) — the authority for the failure-mode table and the preserve/recompute split. Do not re-decide those here.
- **NO version bump, and do NOT touch `RELEASE-NOTES.md` version headings.** Release is a separate, later, owner-gated stage. `doc-tools.sh bump-version` must not be run. (For the record: a new subcommand is a MINOR bump, and `bump-version` syncs 7 files — that is the *next* stage's job, not this one.)
- **NO push, NO PR, NO merge, NO tag.** This plan ends at local commits on `feat/doc-tools-move-entry`.
- **bash 3.2 compatibility is a hard requirement.** No associative arrays (`declare/local -A`), no `mapfile`/`readarray`, no `${v,,}`/`${v^^}`, no `&>>`, no `${a[-1]}`, no `coproc`, no `wait -n`. `test_scripts_are_free_of_bash4_only_constructs` in `scripts/test-doc-tools.sh` statically enforces this and will catch a violation.
- **Guard every array expansion** as `"${arr[@]+"${arr[@]}"}"` — bash 3.2 under `set -u` treats an unguarded `"${arr[@]}"` on an empty array as unbound. Every sibling command in this file already does this.
- **`shellcheck -x scripts/doc-tools.sh` baseline is 4 findings** (SC2004 ×1, SC2001 ×2, SC2155 ×1) and exit 1. Do not add findings; do not "fix" the pre-existing four (out of scope, and it muddies the diff).
- **Test baseline is 209 assertions passing in `test-doc-tools.sh`; 636 across all five suites.** All five must be green at the end.
- **Every added test must be proven load-bearing:** break the feature, watch the new assertion fail, restore, watch it pass. Record which assertion failed.
- **Two harness properties make naive assertions vacuous — design around both.** (a) `iso_now()` (`:51-53`) has **1-second** resolution, so two writes in the same second produce an identical `last_verified`/`generated_at`; the existing `test_update_index_updates_generated_at` (`test-doc-tools.sh:761-777`) carries an explicit `sleep 1` for exactly this reason. (b) A pure `git mv` leaves the file's **content hash unchanged**, and a test repo with no second commit leaves `code_commit` unchanged — so an assertion that a field was "preserved" passes just as well against an implementation that re-derives it. Every preservation assertion must therefore be made against a value that *would* differ: jq-inject a sentinel before the move, or mutate the file.
- **Commit trailer:** every commit ends with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **`/bin/rm`, not `rm`,** in any throwaway shell used for manual verification — the operator's `rm` is aliased to `trash` and silently rejects `-rf`.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/test-doc-tools.sh` | Modify | New `move-entry` tests + one `code_refs` hygiene test, registered in `run_tests()` |
| `scripts/doc-tools.sh` | Modify | `cmd_move_entry()`, `usage()` line, `case` dispatch arm, two `code_refs` CSV filters |
| `CLAUDE.md` | Modify | Directory Structure verb list; Key Files table "13 subcommands" → 14 |
| `docs/codebase-guide.md` | Modify | Key Files table verb list + count |
| `docs/architecture/system-overview.md` | Modify | C4 container description + Staleness Detection table (both say "13 subcommands") |
| `skills/doc-superpowers/SKILL.md` | Modify | Detect Bundled Tooling table gains a `move-entry` row |
| `references/doc-spec.md` | Modify | Key-contract consumer list (line ~851) gains `move-entry` |
| `scripts/hooks/git/{pre-commit,post-merge,post-checkout}` | Modify | Missing-doc advice names `move-entry` |
| `scripts/hooks/claude/{pre-commit-gate.sh,post-commit-sync.sh}` | Modify | Same advice |
| `.claude/hooks/doc-superpowers/{pre-commit-gate.sh,post-commit-sync.sh}` | Modify | Installed copies — kept in lockstep with their templates |
| `docs/issues/2026-07-29-doc-tools-has-no-move-entry-operation.md` | Create (done) | The issue |
| `docs/superpowers/plans/2026-07-29-doc-tools-move-entry.md` | Create (done) | This plan |
| `docs/.doc-index.json` | Modify | `add-entry` rows for the two new docs above |

**Explicitly NOT touched:** `RELEASE-NOTES.md`, `package.json`, `claude-code.json`, `.claude-plugin/*`, `.cursor-plugin/*`, `gemini-extension.json` (all version-bump targets), `scripts/merge-doc-index.sh` (see Task 7 note).

---

### Task 1: Failing tests for the happy path

**Files:** Modify `scripts/test-doc-tools.sh`

**Interfaces:**
- Consumes `scripts/test-helpers.sh`: `setup`, `teardown`, `assert_eq`, `assert_contains`, `assert_json_field`, `hash_file`, and `DOC_TOOLS` (the `bash_bin_shim`-wrapped path — always invoke `"$DOC_TOOLS"`, never `scripts/doc-tools.sh` directly, or the bash-3.2 CI leg silently tests bash 5).
- Produces the assertions Task 2 must satisfy.

- [ ] **Step 1: `test_move_entry_preserves_all_metadata`**

Sentinel values are load-bearing here, not decoration — see the harness-properties constraint above. `code_commit` and `last_verified` are injected as values the implementation could not possibly re-derive, and the doc's content is mutated so a recomputed hash provably differs from the stored one. Without all three, the assertions pass against an implementation that does the exact opposite.

```bash
test_move_entry_preserves_all_metadata() {
  echo "test: move-entry re-keys an entry and preserves code_refs/code_commit/last_verified"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index

  # Sentinels: a re-querying implementation cannot reproduce either of these, so
  # the "preserved" assertions below can actually fail. Without them, code_commit
  # is unchanged anyway (no second commit to src/) and last_verified collides on
  # iso_now()'s 1-second resolution.
  jq '.docs["docs/architecture.md"].code_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    | .docs["docs/architecture.md"].last_verified = "2020-01-01T00:00:00Z"' \
    docs/.doc-index.json > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json

  git mv docs/architecture.md docs/arch-renamed.md
  # Mutate the content so a recomputed hash necessarily DIFFERS from the stored
  # one — after a pure `git mv` the two are identical and the hash assertion
  # would pass against an implementation that never recomputed.
  echo "renamed and edited" >> docs/arch-renamed.md
  local old_hash
  old_hash=$(jq -r '.docs["docs/architecture.md"].content_hash' docs/.doc-index.json)

  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch-renamed.md 2>/dev/null

  local json; json=$(cat docs/.doc-index.json)
  # `.docs["missing"]` evaluates to null, which is ALSO what a destroyed .docs
  # map yields — so assert has()==false plus the surviving entry count.
  assert_json_field "$json" '.docs | has("docs/architecture.md")' "false" "old key is gone"
  assert_json_field "$json" '.docs | length' "1" "entry count unchanged (nothing else dropped)"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].code_refs[0]' "src/" "code_refs preserved"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].code_commit' \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "code_commit preserved, not re-queried"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].last_verified' \
    "2020-01-01T00:00:00Z" "last_verified preserved, not re-stamped"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].doc_type' "architecture" "doc_type preserved"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].content_hash' \
    "sha256:$(hash_file docs/arch-renamed.md)" "content_hash recomputed at new path"
  assert_json_field "$json" \
    "$(printf '.docs["docs/arch-renamed.md"].content_hash != %s' "\"$old_hash\"")" "true" \
    "recomputed hash actually differs from the stored one"
  teardown
}
```

Write the temp file inside `$TEST_DIR` (`docs/.idx.tmp`), never `/tmp` — the two CI matrix legs would otherwise race on a shared path.

- [ ] **Step 2: `test_move_entry_preserves_unknown_fields`**

Inject a synthetic key into the entry before moving, then assert it survives. This is the assertion that fails if someone rewrites the implementation as an enumerate-and-copy field list:

```bash
  jq '.docs["docs/architecture.md"].future_field = "keep-me"' docs/.doc-index.json \
    > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json
```

Assert `.docs["docs/arch-renamed.md"].future_field == "keep-me"`.

- [ ] **Step 3: `test_move_entry_preserves_key_position`**

Index three docs, move the middle one, assert `.docs | keys_unsorted` still has the moved entry at index 1 (not appended at index 2). `build-index` accumulates with `reduce .[] as $row ({}; . + $row)` (`:407`), so insertion order is the mapping order and this is deterministic.

Rationale, stated accurately: this keeps the **commit-time** `git diff` a one-line key rename rather than a delete-plus-append, which is what a reviewer reads. It does **not** survive a merge — `scripts/merge-doc-index.sh:76` sorts `.docs` alphabetically, so the first merge after a `move-entry` re-sorts the whole map anyway. Do not claim durability past that point in the code comment.

- [ ] **Step 4: `test_move_entry_status_deprecated_survives`**

`deprecate-entry --superseded-by docs/workflows.md docs/architecture.md`, then move it, then assert `status == "deprecated"` and `superseded_by == "docs/workflows.md"`. Catches a re-key that resets `status` to `current` the way `add-entry` does. `setup()` (`test-helpers.sh:59-70`) creates only `docs/architecture.md` and `src/index.js` — create `docs/workflows.md` first.

- [ ] **Step 5: `test_move_entry_bumps_generated_at`**

Capture `.generated_at`, `sleep 1`, move, assert it changed. **The `sleep 1` is required, not defensive** — `iso_now()` is 1-second resolution, so without it the two stamps are identical and this test fails spuriously. Mirrors `test_update_index_updates_generated_at:761-777`.

- [ ] **Step 6: Register all five in `run_tests()`** under a new comment banner `# --- move-entry (re-key without metadata loss) ---`, placed after the existing `# --- doc-path key normalization ---` block (which is the last block before `print_summary`).

- [ ] **Step 7: Run the suite and confirm the new tests FAIL**

```bash
bash scripts/test-doc-tools.sh 2>&1 | tail -20
```

Expected: the new assertions fail (`move-entry` hits `usage()` → exit 1 → no index change). Record the failure text. A new test that passes here means it is asserting nothing.

---

### Task 2: `cmd_move_entry()` — happy path + failure modes

**Files:** Modify `scripts/doc-tools.sh`

**Interfaces:**
- Consumes: `normalize_doc_path()` (`:114`), `hash_file()` (`:28`), `iso_now()` (`:51`).
- Produces: `cmd_move_entry`, dispatched from the `case` block (`:1845`).

- [ ] **Step 1: Write `cmd_move_entry()`**

Insert it immediately after `cmd_remove_entry()` (before `cmd_deprecate_entry()`) — `move` belongs with the other structural key operations.

```bash
cmd_move_entry() {
  local index_file="docs/.doc-index.json"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  if [ $# -ne 2 ]; then
    echo "ERROR: move-entry requires exactly two arguments." >&2
    echo "Usage: move-entry <old_doc_path> <new_doc_path>" >&2
    exit 1
  fi

  # A move is inherently paired, so this takes exactly one pair — a varargs
  # `move-entry old1 new1 old2 new2` form would silently mis-pair on an odd
  # argument count, and the failure would be an index full of wrong keys.
  local old_path new_path
  old_path=$(normalize_doc_path "$1" "old doc path") || exit 1
  new_path=$(normalize_doc_path "$2" "new doc path") || exit 1

  # Same-path is a no-op, and deliberately writes NOTHING — not even a
  # generated_at bump. A re-run of an operator script must not fail, and must
  # not manufacture a doc-index diff (see issue 2026-05-04 on churn).
  if [ "$old_path" = "$new_path" ]; then
    echo "SKIP: '$old_path' — old and new path are the same; nothing to move." >&2
    return 0
  fi

  local index
  index=$(cat "$index_file")

  local exists
  exists=$(echo "$index" | jq --arg p "$old_path" '.docs | has($p)')
  if [ "$exists" != "true" ]; then
    echo "ERROR: '$old_path' not found in index. Nothing to move." >&2
    exit 1
  fi

  # Refuse to clobber: overwriting the destination would discard ITS metadata,
  # which is the precise loss move-entry exists to prevent.
  local target_exists
  target_exists=$(echo "$index" | jq --arg p "$new_path" '.docs | has($p)')
  if [ "$target_exists" = "true" ]; then
    echo "ERROR: '$new_path' is already in the index. Refusing to overwrite it." >&2
    echo "       Remove it first (remove-entry) if it is genuinely obsolete." >&2
    exit 1
  fi

  # Unlike add-entry — which tolerates a not-yet-written doc because it supports
  # authoring — re-keying onto a path with no file on it is a typo, and it would
  # mint an entry with a null hash and no code refs: unfindable and permanently
  # "current". Refuse.
  if [ ! -f "$new_path" ]; then
    echo "ERROR: '$new_path' does not exist on disk. Move the file first, then re-key." >&2
    exit 1
  fi

  # The old file still being present is legitimate (a partially-staged `git mv`,
  # or a deliberate copy-then-reindex) so this warns rather than refuses — but it
  # is silent otherwise, and a copy-instead-of-move typo leaves an orphaned
  # unindexed doc on disk that resurfaces later as untracked. Say so.
  if [ -f "$old_path" ]; then
    echo "WARNING: '$old_path' still exists on disk; it will be left unindexed." >&2
  fi

  local now content_hash_val
  now=$(iso_now)
  content_hash_val="\"sha256:$(hash_file "$new_path")\""

  # The entry object is carried over WHOLESALE (`.value + {content_hash: …}`)
  # rather than field-by-field, so a field this code has never heard of still
  # survives a move. Only content_hash is adjusted: code_commit and
  # last_verified are deliberately preserved, because a move is not a
  # verification and re-deriving them would make the entry assert a freshness
  # nobody confirmed. Run update-index afterwards for a genuine re-verify.
  #
  # to_entries|map|from_entries re-keys IN POSITION, so the commit-time diff is a
  # one-line key rename rather than the delete-plus-append that
  # `.docs[$new] = .docs[$old] | del(.docs[$old])` would produce. (Only until the
  # next merge: merge-doc-index.sh sorts .docs alphabetically.)
  #
  # The second stage repoints other entries' path-valued fields, which
  # references/doc-spec.md holds to the same key contract as the keys themselves
  # — without it a rename leaves a dangling superseded_by/replaces.
  index=$(echo "$index" | jq \
    --arg old "$old_path" \
    --arg new "$new_path" \
    --argjson content_hash "$content_hash_val" \
    --arg generated_at "$now" \
    '.docs |= (to_entries
               | map(if .key == $old
                     then {key: $new, value: (.value + {content_hash: $content_hash})}
                     else . end)
               | from_entries)
    | .docs |= map_values(
        (if .replaces == $old then .replaces = $new else . end)
        | (if .superseded_by == $old then .superseded_by = $new else . end))
    | .generated_at = $generated_at')

  echo "$index" > "$index_file"

  echo "Moved 1 entry:" >&2
  echo "  $old_path -> $new_path" >&2
}
```

Notes for the implementer:
- `map_values` is jq ≥1.5; the repo already requires jq and uses comparable constructs.
- Use `->`, not `→`, in the report line: the sibling reports are plain ASCII and a test asserting the arrow with `grep -F` should not depend on the operator's locale.
- No `local -A`, no arrays at all here, so the bash-3.2 array hazards do not arise.

- [ ] **Step 2: Add the dispatch arm**

In the `case` block, immediately after `remove-entry` so the ordering matches the function ordering:

```bash
  move-entry)       shift; cmd_move_entry "$@" ;;
```

- [ ] **Step 3: Add the `usage()` line**

In the heredoc, after the `remove-entry` line:

```
  move-entry        Re-key an entry after a doc moves, preserving its metadata
                    Usage: move-entry <old_doc_path> <new_doc_path>
```

- [ ] **Step 4: Re-run the suite — Task 1's tests must now pass**

```bash
bash scripts/test-doc-tools.sh 2>&1 | tail -12
```

- [ ] **Step 5a: Refusal tests (four)**

All use `assert_eq` on a captured exit code plus `assert_contains` on stderr. Every one must also assert the index was **not** mutated — a verb that errors after writing is worse than one that does not error.

| Test | Asserts |
|---|---|
| `test_move_entry_requires_two_args` | 0 args and 1 arg both exit 1, stderr names the usage |
| `test_move_entry_unknown_old_path_errors` | exit 1, `not found in index`, index byte-identical |
| `test_move_entry_refuses_existing_target` | exit 1, `already in the index`, **both** entries intact afterwards |
| `test_move_entry_requires_new_file_on_disk` | exit 1, `does not exist on disk`, index byte-identical |

- [ ] **Step 5b: Tolerance + normalization tests (three)**

| Test | Asserts |
|---|---|
| `test_move_entry_same_path_is_noop` | exit **0**, stderr `SKIP`, and the index file **byte-identical** via `cmp` against a pre-copy |
| `test_move_entry_warns_when_old_file_remains` | with both files present: exit **0**, the move still happens, stderr contains `still exists on disk` |
| `test_move_entry_normalizes_absolute_paths` | absolute in-tree paths for both args work; an out-of-tree path (e.g. under a separate `mktemp -d`) exits 1 |

The `cmp` in the same-path test is the load-bearing one: an implementation that bumps `generated_at` on a no-op passes an exit-code check and fails this.

- [ ] **Step 6: Add `test_move_entry_repoints_references`**

Index two docs; `deprecate-entry --superseded-by docs/architecture.md docs/workflows.md`; move `docs/architecture.md`; assert `.docs["docs/workflows.md"].superseded_by` now names the new path. Do the same for `replaces` by setting it with `jq` directly (no verb writes `replaces`).

- [ ] **Step 7: Add `test_move_entry_usage_lists_move_entry`**

Assert `"$DOC_TOOLS" --help 2>&1` contains `move-entry`. Nothing else guards the usage heredoc — the existing usage tests only assert the literal string `Usage` (`test-doc-tools.sh:15-51`), which is why the heredoc already silently omits `implementation-status` and `set-implementation`. (Those two omissions are pre-existing and out of scope; note them as a follow-up rather than fixing them here.)

- [ ] **Step 8: Register the new tests, run, confirm green**

- [ ] **Step 9: Prove load-bearing — one inverse edit at a time**

Four separate cycles, each: apply the edit, run the suite, record the exact assertion text that failed, restore, re-confirm green. Do not batch them, or a failure cannot be attributed to the guard it is meant to prove.

| # | Inverse edit | Must break |
|---|---|---|
| 1 | delete the `[ ! -f "$new_path" ]` guard | `requires_new_file_on_disk` |
| 2 | replace `return 0` on same-path with a fall-through | `same_path_is_noop` (the `cmp`) |
| 3 | drop the `map_values` repointing stage | `repoints_references` |
| 4 | swap `.value + {content_hash: …}` for an enumerated object literal | `preserves_unknown_fields` |

Also confirm the sentinel assertions from Step 1 are load-bearing by a fifth cycle: make the implementation re-query `code_commit` (`git log -1 --format=%H -- …`) and re-stamp `last_verified` to `$now`, and confirm **both** those assertions fail. That is the pair the whole preserve/recompute split rests on.

---

### Task 3: `code_refs: [""]` hygiene fix

**Files:** Modify `scripts/doc-tools.sh`, `scripts/test-doc-tools.sh`

- [ ] **Step 1: Failing test**

```bash
test_empty_code_refs_field_yields_empty_array() {
  echo "test: an omitted code_refs field yields [] not [\"\"]"
  setup
  echo "docs/architecture.md::architecture" | "$DOC_TOOLS" build-index
  local json; json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].code_refs | length' "0" \
    "build-index writes no phantom empty ref"
  echo "# W" > docs/workflows.md
  echo "docs/workflows.md::workflows" | "$DOC_TOOLS" add-entry 2>/dev/null
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/workflows.md"].code_refs | length' "0" \
    "add-entry writes no phantom empty ref"
  teardown
}
```

Confirm it fails with `expected: 0 / actual: 1` before touching the implementation.

- [ ] **Step 2: One-line fix in both call sites**

`cmd_build_index` (`:341`) and `cmd_add_entry` (`:840`) share the line

```bash
    code_refs_json=$(echo "$code_refs_raw" | tr ',' '\n' | jq -R . | jq -s .)
```

Change the final stage to drop empty strings:

```bash
    # An omitted refs field must yield [] — `[""]` is a phantom ref that is not
    # a path, and a consuming project had to normalize 1691 such entries away.
    # Behaviourally identical to [] (compute_freshness filters empty strings),
    # so this only stops new ones being minted; no migration is needed.
    code_refs_json=$(echo "$code_refs_raw" | tr ',' '\n' | jq -R . | jq -s 'map(select(. != ""))')
```

- [ ] **Step 3: Re-run the full suite.** `test_build_index_accepts_entry_with_no_code_refs` already asserts `code_commit == null` for this input and must stay green — it does, because the count guard reads the raw CSV, not the JSON.

- [ ] **Step 4: Prove load-bearing** — revert one of the two lines, watch that half of the assertion fail, restore.

---

### Task 4: Documentation — every site that enumerates the verb list

**Files:** `CLAUDE.md`, `docs/codebase-guide.md`, `docs/architecture/system-overview.md`, `skills/doc-superpowers/SKILL.md`, `references/doc-spec.md`

- [ ] **Step 1: Find them mechanically, do not rely on this list**

```bash
grep -rn 'deprecate-entry' --exclude-dir=.git .
grep -rn '13 subcommand' --exclude-dir=.git .
```

`deprecate-entry` is a *heuristic*, not a proof: ~24 files cite some verb without mentioning it. It was checked exhaustively at plan time and every such file cites individual verbs in prose rather than enumerating the set or a count — so the two greps do yield the right edit set here. Re-verify rather than assuming, and if a new enumeration has appeared, add it.

**Dated snapshots are excluded from rewriting:** `RELEASE-NOTES.md`, `docs/plans/*-audit-report.md`, and `docs/superpowers/{specs,plans}/2026-03-12-*` are records of what was true when written. Do not retro-edit them; the "13 subcommands" hits inside `docs/plans/2026-07-24-audit-report.md` are audit findings, not live claims.

Confirmed **out of scope** (zero `doc-tools` references): `.opencode/`, `.codex/`, `.cursor-plugin/`, `.claude-plugin/`, `AGENTS.md`, `GEMINI.md`. Also out of scope: the `tools install` vendoring path, which copies `doc-tools.sh` itself plus the `doc-pr-release` helpers (`:1691`) — none of which enumerates verbs.

- [ ] **Step 2: `CLAUDE.md`** — two edits: the `scripts/doc-tools.sh` parenthetical in Directory Structure gains `move-entry` after `remove-entry`; the Key Files table's "13 subcommands" → "14 subcommands".

- [ ] **Step 3: `docs/codebase-guide.md:117`** — verb list + count.

- [ ] **Step 4: `docs/architecture/system-overview.md:66` and `:107`** — both say "13 subcommands"; `:66` also enumerates.

- [ ] **Step 5: `skills/doc-superpowers/SKILL.md`** — add a row to the Detect Bundled Tooling table after the `remove-entry` row:

```
| `doc-tools.sh move-entry` | Bundled | Re-key an entry after a doc moves (preserves metadata) |
```

- [ ] **Step 6: `references/doc-spec.md:851`** — add `move-entry` to the consumer list. This paragraph is also the authority for repointing `replaces`/`superseded_by`, so state that `move-entry` maintains them.

- [ ] **Step 7: `docs/conventions.md:300-304`** — the "Read/Write Separation" list classifies verbs by whether they mutate the index. `move-entry` is a write verb and belongs there; add one bullet. (Deliberately in scope: this is the doc that defines write semantics, and omitting a new write verb from it is the same drift class as omitting it from `usage()`. The Status Transitions table below it needs no row — `move-entry` does not change `status`.)

- [ ] **Step 8: Verify no live site still says 13.** Re-run the greps; every remaining hit must be a dated snapshot.

---

### Task 5: Hook advice names the right verb

**Files:** `scripts/hooks/git/{pre-commit,post-merge,post-checkout}`, `scripts/hooks/claude/{pre-commit-gate.sh,post-commit-sync.sh}`, `.claude/hooks/doc-superpowers/{pre-commit-gate.sh,post-commit-sync.sh}`

All five templates print the identical line when the missing count is non-zero:

```
  Run 'doc-tools.sh remove-entry' or 'deprecate-entry' to clean up.
```

- [ ] **Step 1: Rewrite it, leading with the most likely cause**

```
  Run 'doc-tools.sh move-entry <old> <new>' if it was renamed, or 'remove-entry'/'deprecate-entry' to clean up.
```

A missing indexed doc is more often a rename than a deletion, and the current advice routes the common case to the lossy verbs — that is the defect. Apply the same line in all five templates.

- [ ] **Step 2: Mirror into the two installed copies** under `.claude/hooks/doc-superpowers/`. Those are tracked and differ from their templates only in the two substituted placeholder lines (`__INSTALL_DATE__`, `__DOC_TOOLS_PARENT__`); verify with `diff` before and after that the delta is still exactly those two lines. `session-summary.sh` has no such line.

- [ ] **Step 3: Also update `cmd_update_index`'s WARNING** (`scripts/doc-tools.sh:708`) to the same effect — it is the in-tool twin of the hook advice and the message an operator most often actually hits.

- [ ] **Step 4: `bash scripts/test-hooks.sh`** — no assertion currently matches this string (verified: `grep -n "remove-entry\|deprecate-entry\|missing from disk" scripts/test-hooks.sh` is empty), so the suite should stay green. If it does not, the assertion is the authority — read it before editing it.

---

### Task 6: Index the two new docs

**Files:** `docs/.doc-index.json`

- [ ] **Step 1:** `docs/issues/` and `docs/plans/`-family docs are indexed in this repo (31 existing keys, including both current issues). Add both new docs:

```bash
printf '%s\n%s\n' \
  'docs/issues/2026-07-29-doc-tools-has-no-move-entry-operation.md:scripts/doc-tools.sh:issue' \
  'docs/superpowers/plans/2026-07-29-doc-tools-move-entry.md:scripts/doc-tools.sh,scripts/test-doc-tools.sh:plan' \
  | ./scripts/doc-tools.sh add-entry
```

- [ ] **Step 2:** Confirm neither new entry has `code_refs: [""]` — with Task 3 landed, a real refs list is supplied anyway, but check.

- [ ] **Step 3:** Do NOT run `update-index --all` or `build-index`. 26 pre-existing entries are stale on this branch; re-stamping them would bury this change's diff in unrelated churn.

---

### Task 7: Verification

- [ ] **Step 1: All five suites, on both interpreters.** The CI matrix runs bash 5.x and `/bin/bash` 3.2.57; reproduce both locally:

```bash
for BB in "$(command -v bash)" /bin/bash; do
  echo "=== $BB ($("$BB" -c 'echo ${BASH_VERSINFO[0]}')) ==="
  for s in test-doc-tools test-hooks test-spec-status-model test-doc-pr-release test-merge-driver; do
    BASH_BIN="$BB" "$BB" "scripts/$s.sh" >/tmp/dsp-$s.log 2>&1 \
      && echo "  PASS $s ($(grep -c 'PASS' /tmp/dsp-$s.log || true) lines)" \
      || { echo "  FAIL $s"; tail -20 /tmp/dsp-$s.log; }
  done
done
```

Record the real assertion counts. `test-doc-pr-release.sh` needs a YAML parser (python3+PyYAML or ruby); `set-implementation` needs GNU sed (`gsed` on macOS) — if either is absent locally, say so rather than reporting a pass that did not happen.

- [ ] **Step 2: `shellcheck -x scripts/doc-tools.sh`** — must still be exactly the 4 baseline findings. Report before/after counts.

- [ ] **Step 3: `./scripts/doc-tools.sh check-version`** — unchanged and passing (proves no accidental version edit).

- [ ] **Step 4: End-to-end manual fixture.** In a throwaway git repo (use `/bin/rm`, not the aliased `rm`), build an index with real code refs, `git mv` the doc, run `move-entry`, and show `code_refs`/`code_commit`/`last_verified` byte-identical while `content_hash` changed. Then show `check-freshness` still correctly reporting the moved entry stale after a commit to `src/` — the whole point being that the moved entry retains the ability to go stale.

- [ ] **Step 5: `git diff --stat` review.** Confirm nothing outside the File Structure table changed, and specifically that no version manifest and no `RELEASE-NOTES.md` heading moved.

- [ ] **Step 6: Note, do not fix — three pre-existing defects found while planning.** Report them for separate issues; do not widen this diff.

1. **`scripts/merge-doc-index.sh:78` reads `.version`**, but `build-index` has written `schema_version` since the schema-2 rename (`:414-417`). It happens to be *correct for this repo today* — `docs/.doc-index.json` still carries `version: 1` with no `schema_version`, exactly as `docs/conventions.md:321` documents. The defect is **latent**: against any freshly-built index the driver would emit `version: 0` and drop `schema_version`. State it that way or the follow-up is unreproducible.
2. **`usage()` omits `implementation-status` and `set-implementation`** — two shipped verbs absent from the help text, unguarded by any test (Task 2 Step 7 adds a guard only for `move-entry`).
3. **The index write is non-atomic** in all five mutating verbs — `echo "$index" > "$index_file"` truncates before writing, where `cmd_build_index` correctly uses `mktemp` + `mv` (`:424-440`). `move-entry` follows the sibling pattern deliberately (see the rejected-findings note below); the fix is a shared helper across all five, which is its own change.

- [ ] **Step 7: Commit.** Logical units, conventional messages, trailer on each. **Stop there** — no push, no PR, no tag, no bump.

---

## Plan-review adjudication (2026-07-29)

Reviewed by a dedicated reviewer subagent before any code was written. Verdict: **CHANGES REQUESTED**, 12 findings. All were verified by execution, not prose, and all are recorded here — accepted or rejected, never dropped.

**Accepted and folded in (11):**

| # | Sev | Finding | Where fixed |
|---|---|---|---|
| 1 | P1 | Three preservation assertions vacuous: a pure `git mv` leaves the hash identical, no second commit leaves `code_commit` identical, and `iso_now()`'s 1-second resolution leaves `last_verified` identical — so all three pass against an implementation that re-derives them | Task 1 Step 1 rewritten with injected sentinels + content mutation; Global Constraints gained the harness-properties note |
| 2 | P1 | `test_move_entry_bumps_generated_at` would fail *spuriously* — same 1-second resolution; the existing precedent test has an explicit `sleep 1` | Task 1 Step 5 |
| 3 | P1 | `.docs["absent"]` evaluates to `null`, so the old-key-gone assertion also passes if the whole `.docs` map is destroyed | Task 1 Step 1 — `has()` → `false` plus an entry-count assertion |
| 4 | P1 | Missing failure mode: the OLD file still present on disk | Issue failure-mode table + implementation WARNING + Task 2 Step 5b test |
| 5 | P2 | Key-position rationale over-claimed: `merge-doc-index.sh:76` sorts `.docs`, so the minimal diff does not survive a merge | Task 1 Step 3 + the code comment in Task 2 Step 1 |
| 6 | P2 | Test-registration placement contradicted itself between Steps 1 and 6 | Task 1 Steps 1/6 |
| 7 | P2 | Task 2 Step 6 used `docs/workflows.md`, which `setup()` does not create | Task 1 Step 4 + Task 2 Step 6 |
| 8 | P2 | The merge-driver note was wrong for *this* repo — the live index really does carry `version: 1`, so the driver reads it correctly today; the defect is latent | Task 7 Step 6 item 1 |
| 10 | P2 | Task 2 Steps 5 and 8 were each well over 5 minutes | Split into 5a/5b and a four-cycle table in Step 9 |
| 11 | P2 | The `deprecate-entry` proxy claim was literally false (~24 files cite a verb without it), though it yields the right edit set | Task 4 Step 1 reworded from proof to heuristic; also records the confirmed out-of-scope surfaces |
| 12 | P2 | The `usage()` line would be unguarded by any test | Task 2 Step 7 adds one |

**Rejected, with reason (1):**

- **#9 (P2) — non-atomic index write.** Correct observation, declined *in this change*. All four sibling mutating verbs use the same `echo "$index" > "$index_file"`; making `move-entry` alone atomic would leave the shared hazard in place while making it look addressed, and the honest fix is one shared write helper across all five call sites. Recorded as follow-up item 3 in Task 7 Step 6 instead.

**Reviewer open questions, answered:**

1. Warn, don't refuse, when the old file remains (finding #4 above).
2. `docs/conventions.md` Read/Write Separation **is** in scope — Task 4 Step 7.
3. Keep the `to_entries|map|from_entries` form; only the justification needed correcting (finding #5).

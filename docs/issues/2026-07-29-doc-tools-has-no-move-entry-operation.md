---
date: 2026-07-29
status: Open
priority: P1
type: enhancement
component: doc-index
source: manual
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
  - scripts/hooks/git/pre-commit
  - scripts/hooks/git/post-merge
  - scripts/hooks/git/post-checkout
  - scripts/hooks/claude/pre-commit-gate.sh
  - scripts/hooks/claude/post-commit-sync.sh
  - references/doc-spec.md
screenshots: null
axiom-agent: null
branch: feat/doc-tools-move-entry
design-doc: null
report: null
---

## Summary

`doc-tools.sh` owns `docs/.doc-index.json` and every metadata field in it, but
has **no operation that re-keys an entry when a doc moves.** It detects the
resulting state and names a remedy — and the remedy it names is lossy.

`remove-entry` + `add-entry` is the documented path, and it discards
`code_refs`, `code_commit`, and `last_verified`. Losing `code_refs` is not
cosmetic: `compute_freshness()` derives staleness by comparing the current
commit across `code_refs` to the stored `code_commit`, so an entry with no
refs has nothing to compare and is reported `current` **unconditionally and
forever** — a silent false-green indistinguishable from a healthy entry.

## Description

### Detection already exists; only the remedy is missing

Two code paths already recognise a doc that is indexed but gone from disk:

- `cmd_check_freshness` has a dedicated `status: "missing"` branch with its own
  `count_missing` counter (`scripts/doc-tools.sh:536`).
- `cmd_update_index` warns and skips
  (`scripts/doc-tools.sh:707-710`):

  ```
  WARNING: 'docs/old.md' no longer exists on disk. Skipping.
           Use remove-entry or deprecate-entry to clean up.
  ```

Five installed hook scripts print the same advice to the developer whenever the
missing count is non-zero:

```
  Run 'doc-tools.sh remove-entry' or 'deprecate-entry' to clean up.
```

(`scripts/hooks/git/pre-commit:57`, `scripts/hooks/git/post-merge:48`,
`scripts/hooks/git/post-checkout:50`,
`scripts/hooks/claude/pre-commit-gate.sh:62`,
`scripts/hooks/claude/post-commit-sync.sh:64`.)

So the tool reliably tells the user "this doc is gone" and then routes them to
the two verbs that cannot express what actually happened. Neither
`remove-entry` (delete the entry) nor `deprecate-entry` (mark superseded) means
*"the same doc is now at a different path."*

### What the lossy path costs

`add-entry`'s stdin line is `doc_path:code_refs_csv:doc_type`. To re-add a
moved doc without losing anything, the operator must first read the old entry's
`code_refs` out of the index and re-supply them by hand — and even then
`code_commit` and `last_verified` are re-derived, not carried:

| Field | `move-entry` should | `remove-entry` + `add-entry` does |
|---|---|---|
| `code_refs` | preserve | **lost** unless manually re-supplied |
| `code_commit` | preserve | re-queried from HEAD — silently claims the doc was verified against current code |
| `last_verified` | preserve | reset to now — silently claims the doc was just verified |
| `doc_type` | preserve | must be manually re-supplied |
| `status` | preserve | reset to `current` — a `deprecated` entry silently un-deprecates |
| `replaces` / `superseded_by` | preserve | reset to `null` |
| `implementation` | preserve | dropped (only `update-index` writes it) |
| `content_hash` | recompute at the new path | recomputed (correct) |

Three of those are worse than "lost": `code_commit` and `last_verified` being
re-derived means the entry actively *asserts* a verification that never
happened, and a re-keyed `deprecated` entry quietly returns to `current`.

### The observed downstream consequence

When the `code_refs` CSV is omitted (the easy thing to do, since the operator
no longer has the refs), `add-entry` writes `code_refs: [""]` rather than `[]` —
a phantom ref string that is not a path. Reproduced on `main` @ `99287e3`:

```
$ echo "docs/b.md::spec" | doc-tools.sh add-entry
Added 1 entry:
  docs/b.md
$ jq -c '.docs["docs/b.md"].code_refs' docs/.doc-index.json
[""]
$ doc-tools.sh status docs/b.md
{"path":"docs/b.md","status":"current", ...}
```

Behaviourally `[""]` and `[]` are the same to `compute_freshness()` (it filters
empty strings out of `code_refs_arr`, so both leave nothing to compare and both
report `current` forever) — but `[""]` is the *shape* the false-green takes in
a real index, and it is not a state any caller intended to write. A consuming
project (`abundance-mvp`) had to add a `normalize_empty_code_refs` pass to undo
it across **1691 entries**, with the comment: *"a `""` ref … can NEVER go
stale — a silent false-green."*

## Steps to Reproduce

1. Index a doc with real code refs:
   `echo "docs/old.md:src/:spec" | doc-tools.sh build-index`
2. `git mv docs/old.md docs/new.md`
3. `doc-tools.sh update-index docs/new.md`
   → `ERROR: 'docs/new.md' not found in index. Use add-entry to add new docs.`
4. `doc-tools.sh update-index docs/old.md`
   → `WARNING: … no longer exists on disk. Skipping. Use remove-entry or
   deprecate-entry to clean up.`
5. Follow that advice: `doc-tools.sh remove-entry docs/old.md` then
   `echo "docs/new.md::spec" | doc-tools.sh add-entry`
6. Observe `code_refs: [""]`, `code_commit: null`, `last_verified` reset — and
   `check-freshness` reporting the entry `current` from now on, whatever
   happens to `src/`.

**Frequency:** every doc rename or directory reorganisation.

## Expected Behavior

A `move-entry <old-path> <new-path>` subcommand that re-keys the entry in
place, preserving every field except `content_hash` (recomputed from the file
at the new path), and refusing rather than guessing when the move is not
well-formed.

## Actual Behavior

No move/rename verb exists. The tool detects the state, names a lossy remedy,
and silently converts an accurate freshness entry into a permanently-green one.

## Technical Context

- doc-superpowers v2.13.1 (`main` @ `99287e3`)
- Subcommand dispatch: `scripts/doc-tools.sh:1845-1878` — 13 verbs, no move
- Freshness derivation: `compute_freshness()` `scripts/doc-tools.sh:161-225`
- Key contract: `references/doc-spec.md:851` — entries are keyed by
  repo-root-relative paths, *"and the same rule applies to path-valued fields
  (`replaces`, `superseded_by`)"*. A rename therefore also dangles any other
  entry's `superseded_by`/`replaces` that pointed at the old path.
- `normalize_doc_path()` (`scripts/doc-tools.sh:114`) already exists and is the
  boundary every path-taking verb uses; `move-entry` must use it for both
  arguments.

## Proposed Solution

### `move-entry <old-path> <new-path>`

Exactly two positional arguments — a move is inherently paired, so a
`move-entry old1 new1 old2 new2` varargs form would be silently
mis-parseable on an odd argument count.

Behaviour on success:

1. Normalize both paths via `normalize_doc_path()`.
2. Re-key the entry **in position** (`to_entries | map(...) | from_entries`)
   rather than appending the new key, keeping the `git diff` minimal — this
   repo already carries a known doc-index conflict-churn problem
   ([2026-05-04](2026-05-04-doc-index-metadata-rewrite-on-every-commit.md)).
3. Carry the entry object over wholesale and adjust only `content_hash`. Do not
   enumerate-and-copy a field list — an unknown future field must survive.
4. Recompute `content_hash` from the file at the new path.
5. Repoint any other entry's `replaces` / `superseded_by` that pointed at the
   old path, per the `doc-spec.md:851` key contract.
6. Bump top-level `generated_at` (matching every sibling write verb).

Deliberately **not** done: re-query `code_commit`, re-stamp `last_verified`, or
re-parse the `implementation` block. A move is not a verification, and doing
any of those would make the entry assert a freshness it has not earned. Use
`update-index` afterwards if a genuine re-verify is intended.

### Failure modes

| Condition | Behaviour | Why |
|---|---|---|
| old key absent from index | `ERROR` + exit 1 | The caller's intent cannot be satisfied. Matches `update-index`'s not-in-index error, not `remove-entry`'s batch `SKIP` (which is tolerable only because removal is idempotent). |
| new key already present | `ERROR` + exit 1 | Overwriting would discard the destination entry's metadata — the exact loss this feature exists to prevent. |
| new path not a regular file | `ERROR` + exit 1 | `add-entry` tolerates a not-yet-written doc (null hash) because it supports authoring; re-keying onto a path with nothing on it is a typo, and it would mint precisely the unfindable/never-stale entry this issue is about. |
| `old == new` after normalization | exit 0, **no write at all** | Idempotent re-runs must not fail; and not writing avoids a pointless `generated_at` bump. |
| old path still exists on disk | `WARNING`, proceed, exit 0 | A partially-staged `git mv` and a deliberate copy-then-reindex both legitimately leave it present, so this must not refuse. But a copy-instead-of-move typo silently orphans an unindexed doc that resurfaces later as untracked — so it must not be silent either. |
| either path outside the working tree | `ERROR` + exit 1 | Delegated to `normalize_doc_path()`. |

### Companion fix — `code_refs: [""]`

Filter empty strings out of the `code_refs` CSV parse in `cmd_build_index` and
`cmd_add_entry` so an omitted refs field yields `[]`, not `[""]`. One line
each. No migration needed: existing `[""]` entries behave identically to `[]`
today, so this only stops new ones being minted.

### Documentation sites that enumerate the verb list

`move-entry` must be added everywhere the verb set is stated, not just to
`usage()`:

- `scripts/doc-tools.sh` — `usage()` heredoc + the `case` dispatch
- `CLAUDE.md` — Directory Structure verb list + Key Files table ("13 subcommands")
- `docs/codebase-guide.md` — Key Files table ("13 subcommands", full verb list)
- `docs/architecture/system-overview.md` — C4 container description + Staleness Detection table (both say "13 subcommands")
- `skills/doc-superpowers/SKILL.md` — Detect Bundled Tooling table
- `references/doc-spec.md` — the key-contract consumer list at line 851
- the five hook scripts whose missing-doc advice currently offers only the two
  lossy verbs, plus their installed counterparts under `.claude/hooks/`

## Acceptance Criteria

- [ ] `move-entry <old> <new>` re-keys the entry with `code_refs`,
      `code_commit`, `last_verified`, `doc_type`, `status`, `replaces`,
      `superseded_by` and `implementation` byte-identical to before.
- [ ] `content_hash` matches `sha256:` of the file at the new path.
- [ ] A field not known to the implementation survives the move (proven with a
      synthetic extra key).
- [ ] Each of the five failure modes above behaves exactly as tabulated, with
      the documented exit code.
- [ ] Another entry's `superseded_by` pointing at the old path is repointed.
- [ ] Absolute in-tree paths are accepted for both arguments; out-of-tree paths
      are rejected non-zero.
- [ ] `add-entry`/`build-index` with an empty refs field write `[]`, not `[""]`.
- [ ] Every doc site listed above names `move-entry`, and no site still says
      "13 subcommands".
- [ ] All five shell suites green on bash 5.x **and** bash 3.2, and
      `shellcheck -x scripts/doc-tools.sh` no worse than its 4-finding baseline.

## Open Questions

1. **Should the hooks' missing-doc advice mention `move-entry` first?** A
   missing indexed doc is more often a rename than a deletion, so leading with
   `move-entry` is probably the better default — but it changes five hook
   scripts' user-visible output and their installed copies.
2. **Batch form.** If a directory reorganisation moves 40 docs, 40 invocations
   is 40 index read/write cycles. A future `--from-stdin` mode taking
   `old:new` pairs would fix that; deliberately out of scope here.
3. ~~**Should `move-entry` verify the old path is actually gone?**~~ **Resolved
   (plan review, 2026-07-29):** warn, do not refuse. Refusing would reject both
   a partially-staged `git mv` and a legitimate copy-then-reindex; staying
   silent would let a copy-instead-of-move typo orphan an unindexed doc. See the
   failure-mode table.

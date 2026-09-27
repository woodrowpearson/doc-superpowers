---
date: 2026-09-27
status: Resolved
priority: P1
type: bug
component: doc-index
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-1
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/hooks/git/pre-commit
  - scripts/hooks/git/prepare-commit-msg
  - scripts/hooks/claude/pre-commit-gate.sh
  - scripts/hooks/ci/doc-index-update.yml
  - scripts/test-doc-tools.sh
  - references/doc-spec.md
  - docs/conventions.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-1 — Freshness is keyed on commit identity instead of content identity

> Cluster **I-1** of sweep run `05ea982`, ranked #1 of 14. Evidence lives in the
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S1, S5, S6, X). The fix
> is **Task 4** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md).

## Summary

A doc is "stale" when the commit SHA that last touched its `code_refs`, found by walking history,
differs from the SHA stored at verification time. The question the tool needs to answer is
"has the *content* of these refs changed since someone verified the doc?". A commit SHA is a proxy
for content, and a poor one:

- squash merges, GitHub rebase-merges, cherry-picks and reverts mint new SHAs for identical bytes;
- shallow clones graft history, so the walk returns the wrong commit;
- a commit cannot contain its own SHA, so the commit that verifies a doc never matches;
- the walk runs once per doc, so cost is O(N·H).

## Incorrect assumption

**A1:** "The commit that last touched the refs identifies the code a doc was verified against, and
history is complete and linear."

## Verified evidence (all measured unless noted)

- `scripts/doc-tools.sh:177,365,569,743,867` (+ `git/pre-commit:26`, `claude/pre-commit-gate.sh:37`):
  - After a squash merge the doc reads **stale** (`commits_behind 1`), although
    `git rev-parse <stored>:<ref>` equals `HEAD:<ref>` for every ref.
  - Rebase-merge, cherry-pick and revert are misjudged the same way, and so is verifying a doc in
    the same commit as the code.
  - A staged invalidating change reads **current**.
  - After squash + branch delete, the stored commit object is **absent** in a fresh clone. A
    reader-only `<code_commit>:<ref>` lookup therefore cannot fix this; the object IDs must be
    **stored** in the index.
- `:564-597,166-207`: every doc pays its own `git log -1` + `git rev-list --count` walk and spawns
  7–21 processes.
  - t ≈ 16.1 ms·N at H=201 (N=100 → 1.7 s; N=400 → 6.5 s).
  - 117 s at N=4,000 / H=3,000; ≈23 min extrapolated at H=30,000.
  - Synthetic `build-index` over 2,000 docs took 421 s.
- `:193-208,580-597`: `code_refs_changed` compares each ref's last commit to the doc-level SHA, so
  refs that were never touched are listed. A null `code_commit` gives stale with `commits_behind 0`.
- `:578-581`: `commits_behind` is computed for every *current* doc, where it is always 0. That is
  about half of all git time.
- `:511,629-641`: `read -d ''` from a process substitution does one `read` syscall per byte
  (73,985 reads for 73,784 B).
- `ci/doc-index-update.yml:24-25,52`: `fetch-depth: 2` records the shallow graft as `code_commit`,
  so the doc stays stale forever in full history (see also I-8).
- `git/pre-commit:16-31`, `prepare-commit-msg:15-26`, `claude/pre-commit-gate.sh:29-41`: freshness is
  evaluated at HEAD. The commit that makes a doc stale passes, and under STRICT the *next* commit is
  blocked (hook side tracked in I-6).

**Prototype (sweep scratch):** storing per-ref object IDs and checking them with one
`git cat-file --batch-check` pass:
- resolves 12,000 refs in 0.25 s regardless of history depth;
- handles 4,000 docs in 0.79 s at H=3k and 0.46 s at H=30k;
- produces the same stale set as today on a linear history.

## Proposed fix (fix plan Task 4)

- Additive `code_oids` map per entry (`schema_version: 3`).
- Writers capture blob/tree OIDs from the working tree at verification time.
- Readers do one batch-check against `HEAD` or `--tree <tree-ish>`. Pre-commit passes the staged
  tree from `git write-tree`.
- Legacy entries fall back to the `code_commit` logic until they are re-verified.
- `commits_behind` and `code_refs_changed` are computed only for stale docs. `code_refs_changed`
  becomes exact per ref. `commits_behind` is `null` when the verified commit is unreachable, never a
  masked `0`.
- Writers refuse to record `code_commit` in a shallow repo; the OIDs remain valid there.
- Remove the `date | commit` part of the in-doc marker, so the index is the only freshness record.

No new dependency: only `git cat-file`, `git write-tree` and `git rev-parse`.

## Acceptance criteria

- [x] Fixtures for squash-merge, rebase-merge, cherry-pick, revert-to-verified-bytes, a
  `--depth 1` clone, and "code + doc + update-index in one commit" all give the correct verdict.
- [x] A staged invalidating change is reported by `check-freshness --tree "$(git write-tree)"`.
- [x] N=2,000 docs, H≥500 commits: `check-freshness` < 5 s, with a process-count bound.
- [x] `code_refs_changed` lists exactly the refs whose OID changed.
- [x] `references/doc-spec.md`, `docs/conventions.md` and `SKILL.md` describe the content model.

## Resolution (Task 4)

Resolved by Task 4 of the fix plan. Freshness is now keyed on content (the "Content identity"
section of `scripts/doc-tools.sh`; index `schema_version` 3):

- **Writers store content.** `build-index`, `add-entry` and `update-index` record `code_oids`: for
  each ref, the git object id of its content in the working tree (a blob, a tree, or `"missing"`).
  The working tree is what the verifier read. The capture copies git's index to a private one,
  re-stages each ref from the working tree, runs `git write-tree`, and resolves every ref in one
  `git cat-file --batch-check`. The user's staging is never touched. `move-entry` carries
  `code_oids` over unchanged.
- **Readers compare content.** `check-freshness` and `status` resolve every ref of the index in
  HEAD, or in `--tree <tree-ish>`, in one `git cat-file --batch-check`: stale ⇔ some ref's object
  id differs. The pre-commit hook can pass `--tree "$(git write-tree)"` (wired in T7).
- **Stale docs only.** `code_refs_changed` is the exact set of refs whose id differs.
  `commits_behind` is `git rev-list --count <code_commit>..HEAD -- <refs>`, run once per distinct
  stale (`code_commit`, refs) group. It is `null` when the repository lacks that commit (a deleted
  squash-merged branch, a shallow clone), never a masked `0`.
- **Shallow clones.** Writers record `code_commit: null` there, with a warning; the object ids are
  exact there.
- **Literal refs.** Refs reach git with `--literal-pathspecs`. A ref containing `*`, `?` or `[`
  draws a warning when written. The doc-index family is dropped from the content of any ref that
  covers it (`.`, `docs/`), so an index write never makes such a doc stale.
- **Legacy entries** without `code_oids` keep the old commit logic (refs as git pathspecs) until
  re-verified. A v2 index is read as it is; the first real write stamps `schema_version: 3` and
  drops a pre-v2 `version` key.
- **The in-doc marker** is now `<!-- Generated by doc-superpowers -->`, with no date or commit. The
  index is the single freshness record.

The writers' per-key reports now come from one classification made in the writer's own jq pass
(`_index_apply --report`). Loops over many paths no longer call functions while `"$@"` holds the
paths, which under bash 3.2 copies them on every call. Both costs were quadratic.

Tests: `test_i1_*` in `scripts/test-doc-tools.sh` (17 tests). All of them were RED against the
pre-fix script. Measured on this branch (M-series laptop, before → after):

- `check-freshness` over 2,000 docs and 503 commits, 60 of them stale: 43.0 s → 1.1 s on bash 5,
  62 s → 1.8 s on bash 3.2. git processes went from 4,062 to 7.
- `build-index` of the same 2,000 docs: 26.1 s → 2.3 s on bash 5.
- 2,000 keys on bash 3.2: `add-entry` 29.1 s → 3.0 s, `update-index` 5.5 s → 2.1 s,
  `deprecate-entry` 3.9 s → 0.6 s, `remove-entry` 3.8 s → 0.6 s.

## Related

- Removes most of the conflict surface behind
  `docs/issues/2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`: identical verifications
  become byte-identical. That issue's stated cause (the post-commit hook) is refuted; see I-6.
- Consumers: I-6 (pre-commit `--tree`), I-8 (CI shallow checkouts), I-5 (merge conflicts).

# doc-index-resolve settles cite line-number conflicts — design

**Status:** approved 2026-11-18 by the consumer project's coordinator · **Scope:** the
`doc-index-resolve` step (`scripts/hooks/ci/doc-superpowers-steps/`), one new step script, the
tests and the step's docs · **Release:** part of 3.15.0, no separate bump.

## What this decides

The `doc-index-resolve` step merges the base branch into a pull request only when the doc index is
its only conflict. It now also merges one whose other conflicts are all in indexed Markdown docs,
where the two sides differ only in the line numbers of code citations (`path:12`, `path:12-14`).
The step recomputes each such citation against the merged code, re-records those docs with
`update-index`, and pushes as before. Everything it refused before, it still refuses.

## Why

A merge to the base branch that changes code shifts the line citations in the docs that describe it.
The next pull request that edited the same docs then conflicts in their text, and the step skips
it. A consumer project counted, after one merge, 2 to 29 such blocks per open pull request. A hand
merge in GitHub's editor then lost an unrelated paragraph.

## Requirements

**R1. Which pull requests qualify.** Besides the index, every file git conflicts on (without the
driver) is a Markdown file keyed in both sides' indexes and changed on both sides from one merge
base (stages 1, 2 and 3 at one path). In each conflict block of `git merge-file --diff3`, the head's
side and the base branch's side are equal once each citation's numbers are replaced by a placeholder. Any
other difference, digits outside a citation included, is a skip. Every earlier refusal still holds.

**R2. Citations.** A full cite is a path-like token with a file extension, then `:N` or `:N-M`. A
list item `, N` or `, N-M` straight after a cite or another list item in the same code span takes
that cite's path. A continuation, a bare `:N` or `:N-M` after a backtick, space, comma or
parenthesis, takes the nearest path-like token before it; the search stops at a blank line or a
heading. A path resolves as written, then relative to the doc's directory, then as the one tracked
file ending in `/<path>`. It must resolve to the same file in the head's, the base branch's and the
merged tree.

**R3. Recomputing.** Neither side's numbers are copied. Each side's cite names lines in that side's
tree; those lines are searched for in the merged file. A unique match is the new range. Several
matches widen the search by one line of the side's context above and below, up to five. Both
sides must land on the same range. No match, several at five lines, a range past the end of the
side's file, or two different ranges is a skip. The rewritten block is the head's side with the
recomputed numbers.

**R4. Anchored.** Every cite outside the blocks of a rewritten doc is anchored: some side holds the
same doc line with the same numbers, and the lines it names are equal in that side's tree and the
merged tree. Otherwise a skip: the merge left a cite pointing at moved code.

**R5. Re-recording.** Each rewritten doc must read `current` with `doc_modified: false` in
`check-freshness --tree` on the head and on the base. The step re-records the rewritten docs with
`doc-tools.sh update-index` in a temporary worktree at the head holding the merged files. That
worktree runs no hook, filter or LFS process; no file of the pull request runs. Each re-recorded
entry keeps the newer of the two sides' `last_verified`. The step only read the cites, so it does
not stamp a new verification. On the final tree, `check-freshness` reads each re-recorded doc
`current` and the dropped-entry check passes, or it is a skip.

**R6. What the pull request sees.** The merge commit's message and the comment name the docs whose
cites were recomputed and the number of cites. A skip under R1–R5 names the doc and the block's line
in the head's version.

## The design

- `cite-resolve.sh`, a step script beside `index-resolve.sh`, called as
  `"$(dirname "$0")/cite-resolve.sh"`, so `needed_steps` vendors it. bash 3.2+ and jq 1.6+, as
  the step needs; no Python. One doc per call: it prints the rewritten doc, or one reason line and
  exits 1.
- `index-resolve.sh`: the driver merge's exit 1 is read against its `--name-only` list (docs may
  conflict now). Each doc's blob is replaced through a temporary index (`GIT_INDEX_FILE`). Then the
  re-record, the freshness check and the dropped-entry check run on the final tree, before
  `commit-tree`.
- `update-index` runs from the step's own checkout, the base branch's vendored `doc-tools.sh`.

## Not in this change

- Link fragments (`#L12`), and conflicts in prose or non-doc files.
- Fixing cites outside the blocks. R4 refuses them; it does not move them.
- Re-recording a doc stale on either side.

# doc-index-resolve settles cite line-number conflicts — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task by task, test-first (superpowers:test-driven-development). Steps use checkbox (`- [ ]`) syntax.

**Goal:** the `doc-index-resolve` step also merges a pull request whose other conflicts are only
cite line numbers in indexed Markdown docs, recomputing each cite against the merged code.
The design is `docs/superpowers/specs/2026-11-18-index-resolve-cite-lines-design.md` (R1–R6).

**Architecture:** a new step script, `cite-resolve.sh`, rewrites one doc. `index-resolve.sh`
qualifies the conflicts, calls it per doc and swaps the blobs through a temporary index. It then
re-records the docs with `update-index` in a temporary worktree at the head. The freshness and
dropped-entry checks run on the final tree before `commit-tree`.

**Tech stack:** bash 3.2+, jq 1.6+, git 2.40+, `gh`.

## Global constraints

- No new dependency, no Python, no new action pin.
- The step never runs a file of the pull request: the temporary worktree has hooks off
  (`core.hooksPath=/dev/null`) and the empty attribute source (no filter, no LFS).
- Exit codes unchanged: 0 none failed, 2 any failed, 3 usage error.
- No release notes, version bump or tag.
- Prose follows the writing rule (`bash scripts/doc-tools.sh writing check <file>`).
- Synthetic fixtures only.

---

### Task 1: the relocator recomputes the cites of one doc

**Files:**
- Create: `scripts/hooks/ci/doc-superpowers-steps/cite-resolve.sh`
- Test: `scripts/test-doc-pr-release.sh` (a new `cite-resolve` section)


**Steps:**
1. Write the failing tests. The relocator takes the doc path, the head, `main`, the merge tree and
   the three stage blobs. It prints the rewritten doc on stdout and exits 0, or prints one reason
   line and exits 1:
   - a full cite, a range, a list item (`, N-M`) and a continuation (`:N`) all move to the lines
     their content moved to;
   - a continuation whose path is on an earlier line of the same paragraph;
   - a bare file name resolves to the one tracked file with that name;
   - a digit difference outside a cite is a text difference: exit 1, with the doc and line;
   - code duplicated with equal context five lines out: exit 1, ambiguous;
   - the two sides' cites landing on different lines: exit 1;
   - a cite outside the blocks that is not anchored: exit 1;
   - a cite range past the end of its file: exit 1.
2. Run them: red, with the exit code.
3. Write `cite-resolve.sh`: a bash wrapper that gathers the cited files' blobs, and one jq program
   for the grammar, the blocks, the search and the anchor check.
4. Run them: green. Then `bash scripts/test-doc-pr-release.sh` in full.
5. Commit.

### Task 2: the step qualifies, rewrites and re-records

**Files:**
- Modify: `scripts/hooks/ci/doc-superpowers-steps/index-resolve.sh`
- Test: `scripts/test-doc-pr-release.sh` (the `doc-index-resolve` section)


**Steps:**
1. Write the failing tests, end to end with the `_ir_` fixture and the gh shim:
   - a PR whose only other conflict is cite numbers in an indexed doc is merged and pushed with the
     lease. Its doc carries the recomputed lines; its comment and message name the doc;
   - doc-freshness reads the re-recorded doc `current` on the pushed head, and `last_verified` is
     the newer side's;
   - the merged index keeps every entry;
   - a text conflict in a doc, a conflict in a file that is not an indexed doc, and a doc stale or
     modified on one side are each skipped, with one comment naming the doc;
   - a numbers-only doc conflict in a merge that brings a workflow file is still skipped;
   - an index-only PR merges exactly as before.
2. Run them: red, with the exit code.
3. Change the step:
   - the qualification of conflicted files;
   - the driver merge's exit 1 read against its `--name-only` list;
   - the relocator per doc, with the blobs replaced through a temporary index;
   - the freshness precondition on both sides;
   - `update-index` in a temporary worktree at the head, with hooks off and the empty attribute
     source, and the newer `last_verified` written back;
   - the freshness check and the dropped-entry check on the final tree;
   - the message and comment lines.
4. Run them: green. Then `bash scripts/test-doc-pr-release.sh` and `bash scripts/test-hooks.sh`
   in full, each with its exit code.
5. Commit.

### Task 2b: the index merge driver keeps the record that describes the merged files

**Rule (design R7).** Both sides may change an entry's verification record (`content_hash`, `code_oids`, `code_commit`, `last_verified`) to different values. The record still comes whole from one side, but the driver no longer just takes the newer side. It takes the side whose `content_hash` and every `code_oids` key equal their own three-way merge: base, ours and theirs, with a key's value taken from the side that changed it. When both sides match, or neither does, the newer side wins, as today. Neither side matching means the doc or its code changed on both sides, so the doc reads stale, which is honest.

**Why.** A pull request edited a doc or its code and re-recorded it. Main then re-recorded the same entry later, for its own reasons. The newer record, main's, won and described main's doc and code, not the merged files. So the merge left the pull request's own docs stale.

**Files:**
- Modify: `scripts/merge-doc-index.sh` (`merge_fields`, and its header comment's record rule)
- Test: `scripts/test-merge-driver.sh`

**Steps:**
1. Write the failing tests, synthetic, in the driver's existing fixture style:
   - (a) The head changes a ref's content and re-records; the base re-records later with that ref unchanged. The merged entry is the head's record, and `check-freshness` on the merged tree reads it current.
   - (b) The same, with the head changing the doc's text (`content_hash`) instead.
   - (c) Both sides change the same ref differently. The newer side's record wins, as today.
   - (d) Only the base re-records, and the head does not change the record. The base's record wins (pick3), unchanged.
   - (e) Both records match the three-way merge. The newer side wins.
2. Run them: red, with the exit code.
3. Change `merge_fields`.
4. Run them: green. Then `bash scripts/test-merge-driver.sh`, `bash scripts/test-doc-pr-release.sh` and `bash scripts/test-hooks.sh` in full, each with its exit code.
5. Commit.

### Task 3: the step's documents

**Files:**
- Modify: `scripts/hooks/ci/doc-superpowers-steps/index-resolve.sh` (its header comment)
- Modify: `references/hooks.md` (the `doc-index-resolve` consent row and section)
- Modify: `docs/` pages that describe the step, where one names its conditions (found with
  `rg -l index-resolve docs`)

**Steps:**
1. Write the new rule, its refusals and its `last_verified` choice in each page.
2. Check: `bash scripts/doc-tools.sh writing check <file>` on each page, and `check-freshness`.
   Re-record with `update-index` each indexed page read against its code.
3. Commit.

---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: release
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-9
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/hooks/ci/doc-pr-release.yml
  - scripts/hooks/ci/doc-release.yml
  - scripts/hooks/ci/doc-pr-release/extract-context.sh
  - scripts/hooks/ci/doc-pr-release/update-pr-body.sh
  - scripts/hooks/ci/doc-pr-release/commit-and-push.sh
  - scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md
  - scripts/test-doc-pr-release.sh
  - scripts/test-doc-tools.sh
  - skills/doc-superpowers/SKILL.md
screenshots: null
axiom-agent: null
branch: null
design-doc: docs/plans/2026-05-12-pr-release-fragment-producer-and-consumer.md
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-9 — Release-notes fragment pipeline: lossy consumer, force-push-unsafe producer, wrong "released" test

> Cluster **I-9** of sweep run `05ea982`, ranked #10 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S7, S2). Fix:
> **Task 10** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md).

## Summary

The producer (`doc-pr-release.yml` + helpers) drafts `RELEASE-NOTES.next/PR-<N>.md` on each push.
The consumer (`doc-tools.sh fragments merge` + the `release` action) folds fragments into
`RELEASE-NOTES.md` and deletes them.

The consumer deletes fragments whose content it partly or wholly failed to merge. It assumes
positional marker lines and never checks them.

The producer can restore commits a human force-pushed away. Its "new commits" range includes other
PRs' commits after "Update branch".

"Already released" is judged by the ancestry of the *oldest* commit that touched the fragment.
Consumption, though, is recorded by *deleting* the fragment. A fragment merged after a release
branch was cut is therefore neither released nor deleted.

## Incorrect assumption

- "Lines 1–2 are always the markers."
- "Ancestry of the oldest touching commit == released."
- "The last commit touching the fragment == last integrated."
- "Prose in the agent prompt enforces the hash protocol and 'never overwrite human edits'."

## Verified evidence (measured unless noted)

- [P1] `doc-tools.sh:1571-1601`; `RELEASE-NOTES.next.README.md:60-61`:
  - the consumer drops lines 1–2 without checking they are markers;
  - it drops text before the first heading;
  - it still lists the fragment for deletion;
  - the "required" line-1 marker is checked nowhere in the consumer.
- [P1] `doc-tools.sh:1571,1601,1603-1605`: a fragment's last line is dropped when it has no trailing
  newline, yet the fragment is still listed in `--paths-out` (→ `git rm`).
- [P1] `doc-tools.sh:1565-1605`: text that is not under a `### ` heading is discarded, and the
  fragment is still consumed. A hash-valid fragment with no heading gives empty output and no
  warning.
- [P1] `commit-and-push.sh:72,62-93` can silently undo a force-push. Root cause not named in the
  Phase-5 draft; added after Phase-4 review.
  - Scenario: a human force-pushes away commits between checkout and push.
  - Both the fast-forward push *and* the rebase retry restore them. Measured with a "committed
    secret" commit.
  - Fix: a compare-and-swap.
- [P1] `extract-context.sh:133`: the new-commits range does not exclude the base. After "Update
  branch", other PRs' commits are copied into this PR's fragment. Root cause not named in the
  Phase-5 draft; added after Phase-4 review.
- [P1] `doc-tools.sh:1495-1507`; `SKILL.md:449-481`: released-detection. A fragment merged after a
  release branch was cut, with the tag on main, is never released and never deleted.
- [P1] `doc-pr-release.yml:227-236,274-305`: "will not overwrite human edits" and the hash check are
  enforced only by the LLM. The verify step passes on a rejected push and on a wrong hash.
- [P1, provisional: structural + needs-runtime] `doc-release.yml:33-34`:
  `!contains(head_commit.message,'[doc-superpowers]')` skips the release job when the branch is cut
  at a squash commit that lists the bot's sync commits. Fix: match the exact bot subject instead.
- [P2] `doc-tools.sh:1363,1572,1539-1545`: headings and markers are not trimmed of trailing space or
  CR. This gives duplicate sections, and CRLF fragments fail validation silently.
- [P2] `doc-tools.sh:1593,1620`: dedupe works per *line*, so shared sub-bullets and fence lines
  vanish from later bullets.
- [P2] Further gaps:
  - the watermark is the last commit touching the fragment, so pushes made mid-run are never
    integrated;
  - `update-pr-body.sh:58-75,101-117` does not check marker order or fences, so an END-before-START
    pair deletes human sections;
  - the "skipped" sentinel still runs later steps (`'' != '0'`);
  - the section vocabulary differs between the README, the prompt and SKILL.md;
  - there is no deterministic opt-out or re-seal.
- [P3] Smaller defects:
  - an invalid range ref is swallowed;
  - `--paths-out` is recognised only as the exact 4th argument in `=` form;
  - the consumed-list path is a fixed `/tmp` path;
  - the fragment reader follows symlinks;
  - `PR_NUMBER` is unvalidated.

## Follow-up pass FU1 (L-PERF, L-TESTS mutation, L-CONTRACT vs the design plan; verified by V-FU1)

The Phase-4 critic found that three things were missing from the earlier passes:
- no L-PERF pass on this surface;
- no mapping from the verified fragment P1s to test gaps;
- no comparison with the design plan `docs/plans/2026-05-12-pr-release-fragment-producer-and-consumer.md`.

The follow-up closes all three. The verifier dropped seven items as duplicates or as having no
observable effect.

- [P2] `extract-context.sh:136-147` (+`:72-80`) passes every payload to `jq` as a single argv
  string.
  - Linux caps a single argument at 128 KiB (`MAX_ARG_STRLEN`), so any larger payload makes jq
    fail with E2BIG: rc 126 and an empty `context.json`.
  - This also makes the 1 MiB "oversized → corrupt" cap dead code.
  - Measured triggers:
    - 400 commits with bodies (139 KB);
    - 850 subject-only commits;
    - a 132,945 B fragment;
    - a 50,000-character CJK PR body.
  - In CI the step goes red on every push to that PR and later steps are skipped. The failure is
    loud and corrupts nothing.
  - `update-pr-body.sh:137` already avoids argv for this reason. Pass the payloads on stdin.
- [P3, downgraded from P2] `doc-tools.sh:1486-1507`: `fragments merge` is O(F×H). Each fragment
  gets its own full-history `git log --reverse`, two `is-ancestor` calls and a `validate`.
  - Measured: 10.46 s at H=5k, F=200; the one-pass `log` alone takes 14 ms.
  - **Fix-shape correction:** the one-pass
    `git log --diff-filter=A <s>..<e> -- RELEASE-NOTES.next/` is **not** equivalent as written.
    - It misses renamed fragments. Add `--no-renames`.
    - It misses fragments added in merge commits. That needs a merge policy:
      `--diff-merges=first-parent` also re-adds fragments that a back-merge brings in.
  - This replaces the earlier unverified carry-over.
- [P3, downgraded] `doc-release.yml:7-10` + `SKILL.md:441,478-490`: consumption runs on
  `release/**`, and nothing requires the release commit to reach `main`. If it doesn't, `main` keeps
  the fragment and lacks the release entry, and the next release **consumes it again** (measured).
  Needs-runtime, because exposure depends on how the release commit reaches `main`.
- [P3] `doc-release.yml:48-61`: the precheck takes the nearest tag *of any name* as "last release".
  For example, a `deploy-marker` tag at HEAD skips the job. Use `--match 'v[0-9]*'`, consistent
  with `SKILL.md:441`.
- [P3] `doc-tools.sh:1486-1504`: candidates come from the worktree and the walk is rooted at HEAD,
  but membership is tested against `<range-end>`. This is latent while every caller passes HEAD.
- [P3] `extract-context.sh:112-134`: `full_commits` includes the bot's own `[doc-superpowers] sync`
  commits. This only adds noise to the agent's context.
- [P3] `RELEASE-NOTES.next.README.md:44-45`; `SKILL.md:470-475`: the advice "pass `--from=<tag>~1`"
  re-releases a fragment that the tagged release already consumed.
- [P3, new at verification] `SKILL.md:441,459-461`: a first release, with no tag, has no valid
  `<range-start>`.
  - The date fallback is not a ref.
  - The tests pass the empty-tree hash, which only works because invalid refs are swallowed.
  - Fixing "validate both refs" therefore breaks 3 tests. Needs a root sentinel.
- [P3] Design plan vs code:
  - The plan's `git log --all` ancestry test and its force-push "sharp edge" were never shipped.
    The code is right; with `--all`, a squash-merged fragment would be skipped.
  - The plan contradicts itself, and its text is stale.
- Test gaps are recorded in I-13: 16 of 17 spot-checked mutants survive. The one other was killed
  only by a crash (rc 126, no Results line).
- Clean (verified):
  - fragments sort by N;
  - hash payload;
  - inclusion of drifted fragments;
  - `update-pr-body` marker checks;
  - `concurrency` is `false`;
  - deletion is scoped to `--paths-out`.
  - The plan's other alternatives (glob deletion, `cancel-in-progress: true`) would have been worse
    than the code.


## Proposed fix (fix plan Task 10)

**Consumer:**
- Validate the line-1/line-2 markers against the filename.
- Merge losslessly, or *exclude the fragment from `--paths-out`* with a warning.
- Dedupe per bullet block, not per line.
- Trim CR and trailing blanks.
- "Unreleased" = present at the end of the range.
- Validate both refs; accept both `--paths-out F` and `--paths-out=F`.

**Producer:**
- `commit-and-push` writes the hash line itself, uses compare-and-swap semantics (ancestry check,
  else exit) and commits only the fragment path.
- `extract-context` excludes base-branch commits and uses the sentinel SHA as its watermark.
- `update-pr-body` refuses END-before-START and ignores fenced markers.

**Workflows:**
- `doc-release.yml` skips only on the exact bot subject.

**Docs and prompt:**
- One section vocabulary.
- SKILL.md `release` runs `fragments merge` before drafting, and adds a commit step before
  `git tag`.

## Acceptance criteria

See fix plan Task 10, Step 1. Every lossy case is either merged losslessly or excluded from deletion
with a warning. A force-pushed branch is never restored.

## Related

- The design intent is in `docs/plans/2026-05-12-pr-release-fragment-producer-and-consumer.md`. The
  Phase-4 critic noted no pass had compared it with the implementation; a follow-up pass covers it
  (see the findings index, Phase 4).

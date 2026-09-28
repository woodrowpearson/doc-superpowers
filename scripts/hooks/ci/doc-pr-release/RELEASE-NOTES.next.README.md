# Per-PR Release Notes Fragments

Each open PR may carry a draft release-notes entry at `RELEASE-NOTES.next/PR-<N>.md`,
written and updated automatically by `.github/workflows/doc-pr-release.yml` on every
push to the PR branch.

## Lifecycle

```
PR opened/synchronize           Release cut (release/** branch)
        |                                  |
        v                                  v
RELEASE-NOTES.next/PR-104.md  ----->  RELEASE-NOTES.md (## v0.3.0)
RELEASE-NOTES.next/PR-105.md  -----/         (fragments deleted)
RELEASE-NOTES.next/PR-107.md  ----/
```

1. **Producer (`doc-pr-release.yml`)**: writes/updates one fragment per PR. The
   agent drafts it; the workflow's commit step (`commit-and-push.sh`) seals it
   (writes the line-2 hash), commits only that file, and pushes it only while
   the PR branch is still at the commit the run checked out. Someone else's
   push during the run supersedes it (nothing is pushed; that push starts a
   newer run); a force-push is never undone. A fragment a human edited is
   never overwritten.
2. **Consumer (`/doc-superpowers release`)**: when the maintainer cuts a release
   (pushes to `release/**`, or runs the action), it
   - runs `doc-tools.sh fragments merge <range-start> HEAD` **before** drafting.
     `<range-start>` is the previous release's tag, or `ROOT` for the first
     release. The output is the merged sections; every fragment it could not
     merge is named on stderr, with the reason, and stays for the next release;
   - folds that output into the new `## vX.Y.Z` entry;
   - deletes **only** the consumed fragments, in the same commit as the entry:
     `doc-tools.sh fragments merge <range-start> HEAD --remove` (same arguments)
     `git rm`s exactly them. Never glob `RELEASE-NOTES.next/PR-*.md` — a
     fragment the merge skipped must survive.

**A fragment is unreleased while it is present.** Consumption is recorded
only by deleting the fragment in the release commit, so `fragments merge`
takes every fragment present at `<range-end>`, whenever it was added — also
one merged to `main` after the release branch was cut. There is no `~1`
adjustment to make on `<range-start>`: pass the previous release's tag.

**The release commit must reach `main`.** Tag the release on its release
commit (or a later commit of the release branch), then merge the release
branch into `main` — or cherry-pick the release commit. Until then `main`
still holds the fragments that release consumed, and `fragments merge`
refuses — exit 3, naming them and the release (1 is any other failure) —
rather than release them a second time: it checks `<range-start>`, and every `v*` tag cut from this
history after `<range-start>` that `<range-end>` does not contain.
`doc-release.yml`'s precheck runs the same check, so the release job fails
before drafting.

## Fragment Format

```markdown
<!-- doc-superpowers:fragment PR-<N> -->
<!-- doc-superpowers:hash <sha256> -->
### Added
- **Feature title**: one-paragraph description with links to relevant code or
  specs in `docs/specs/`.

### Fixed
- **Bug title**: description.
```

- **Line 1** — `<!-- doc-superpowers:fragment PR-<N> -->`, where `<N>` is the
  number in the file's name. **Required**: it is the consumer's key for deleting
  the file; a fragment without it (or naming another PR) is never consumed.
- **Line 2** — `<!-- doc-superpowers:hash <sha256> -->`: the lowercase hex
  SHA-256 of the file's bytes from line 3 on (everything after the two marker
  lines). The workflow writes it; the agent writes `<!-- doc-superpowers:hash -->`.
- **Line 3 on** — the notes, under `### ` section headings (below). No
  `## vX.Y.Z` header: the version is decided at release time.

### Sections: one vocabulary

Write these, in this order; the consumer prints them in this order:

| Section | Also accepted (folded onto it, case-insensitive) | Heading in a Features/Fixes-style RELEASE-NOTES.md |
|---|---|---|
| `### Added` | `Features` | Features |
| `### Changed` | `Changes` | Features (or Changes) |
| `### Deprecated` | | Deprecated |
| `### Removed` | | Breaking Changes (when it breaks users) |
| `### Fixed` | `Fixes`, `Bug Fixes` | Fixes |
| `### Security` | | Security |
| `### Dependencies` | | Dependencies |

Any other `### ` heading (e.g. `### Breaking Changes`, `### Notes`) is kept as
written and printed after these, in first-seen order. The release step writes
the entry in the headings the project's `RELEASE-NOTES.md` already uses; the
last column is how the vocabulary maps onto the Features / Fixes / Breaking
Changes style.

### What the consumer does with a fragment

It is merged **losslessly or not at all**:

- **Merged, with a warning** — a missing or drifted line-2 hash: a human edited
  the notes; human edits are authoritative.
- **Skipped, named on stderr, left for the next release** (never consumed):
  line 1 missing or naming another PR; text before the first `### ` heading; a
  `#` or `##` heading; an unclosed code fence; no notes at all; a name that is
  not `PR-<number>.md`; a symbolic link (never read); an empty file. Fix it and
  commit; the next release takes it.
- Trailing `\r` (CRLF files) and trailing blanks are dropped; a file without a
  final newline keeps its last line.
- Notes are merged as **units**. A unit starts at a list item (`-`, `*`, `+`
  or `1.` at column 0) or at a column-0 line after a blank line (a paragraph),
  and takes every line up to the next such start: indented lines (sub-bullets,
  continuation paragraphs, code fences), and a column-0 line that follows
  without a blank line (a wrapped sentence). A unit identical to one already
  in the same section is merged once; a sub-bullet or sentence two different
  notes share stays in both. List items print as a tight list; a paragraph
  gets a blank line on each side.
- Fragments are processed in ascending integer order of `<N>` (PR-99 before
  PR-101).

### No release notes

A PR with nothing to announce says so explicitly — its notes are only:

```markdown
<!-- doc-superpowers:fragment PR-<N> -->
<!-- doc-superpowers:hash <sha256> -->
<!-- doc-superpowers:no-notes -->
```

The consumer consumes (deletes) it and prints nothing. The bot writes this for
a PR with no user-facing change and replaces it when later work needs notes.
**To opt a PR out** for good, write it by hand and do not re-seal it: the
workflow never drafts over a hand-written no-notes fragment (and never
overwrites any hand-edited fragment). An empty fragment is not this state —
it is skipped as "no notes".

## Manual edits and re-sealing

Maintainers may edit fragment files by hand. The PR workflow detects the edit
through the line-2 hash and **will not overwrite** the fragment: the agent posts
a PR comment asking for the edit to be reconciled with the new commits, and the
commit step refuses to commit over it.

After reconciling, re-seal the fragment so the workflow maintains it again —
put the hash of the bytes from line 3 on onto line 2 (if you deleted the hash
line, first put a `<!-- doc-superpowers:hash -->` line back as line 2):

```bash
f=RELEASE-NOTES.next/PR-<N>.md
h=$(tail -n +3 "$f" | sha256sum | cut -d' ' -f1)     # macOS: shasum -a 256
{ head -n 1 "$f"; echo "<!-- doc-superpowers:hash $h -->"; tail -n +3 "$f"; } > "$f.new" && mv "$f.new" "$f"
```

Check it with `doc-tools.sh fragments validate "$f"` (exit 0: valid).
`doc-tools.sh fragments list` shows every fragment's hash state, sections, and
the problem that would keep a release from consuming it.

## For scripts: the consumed list

`--remove` is the supported way to delete what was merged. A script that needs
the list itself writes it with `--paths-out` to a private temporary file and
keeps only fragment paths:

```bash
consumed=$(mktemp) && paths=$(mktemp)
doc-tools.sh fragments merge "$start" HEAD --paths-out="$consumed" > sections.md
if grep -E '^RELEASE-NOTES\.next/PR-[0-9]+\.md$' "$consumed" > "$paths"; then
  git rm -q --pathspec-from-file="$paths"
fi
rm -f "$consumed" "$paths"
```

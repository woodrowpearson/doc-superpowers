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
   fragment uses the same section format as `RELEASE-NOTES.md` entries
   (the canonical Keep-a-Changelog set: `### Added`, `### Changed`,
   `### Deprecated`, `### Removed`, `### Fixed`, `### Security`, plus
   `### Dependencies` which this project also uses) but **omits** the
   version header (`## vX.Y.Z - YYYY-MM-DD`). The version is decided at
   release time. The set is **not closed** — any `### ` heading is accepted;
   canonical sections emit first in the order above, and non-canonical
   sections emit after them in first-seen order.
2. **Consumer (`/doc-superpowers release`)**: when the maintainer cuts a release
   (pushes to `release/**`), they run `/doc-superpowers release`. That action:
   - Enumerates fragments via
     `doc-tools.sh fragments merge <range-start> <range-end> --paths-out=<file>`,
     which writes the list of fragments it actually consumed
   - Merges each fragment's sections into the new version entry (dedupe within
     sections, preserve fragment order = ascending integer value of `<N>`,
     e.g., PR-99 before PR-101)
   - Deletes **only** the paths listed in `--paths-out`, in the same commit.
     Do not glob `RELEASE-NOTES.next/PR-*.md` — fragments outside the release
     range belong to still-open PRs and must survive.
   - Skips fragments whose PR has not landed in the commit range being released.
     The range is half-open, like `git log A..B`. The consumer finds the commit
     that introduced the fragment file
     (`git log --format=%H --reverse -- RELEASE-NOTES.next/PR-N.md | head -n 1`)
     and includes the fragment only when that commit is an ancestor of
     `<range-end>` **and not** an ancestor of `<range-start>`. A fragment
     introduced exactly at `<range-start>` was part of the previous release and
     is excluded; pass `--from=<tag>~1` to pull it in deliberately.

## Fragment Format

```markdown
<!-- doc-superpowers:fragment PR-<N> -->
<!-- doc-superpowers:hash <sha> -->
### Added
- **Feature title**: one-paragraph description with links to relevant code or
  specs in `docs/specs/`.

### Fixed
- **Bug title**: description.
```

The `<!-- doc-superpowers:fragment PR-<N> -->` marker on line 1 is **required**
— `/doc-superpowers release` keys off it for safe deletion at merge time.

## Manual edits

Maintainers may edit fragment files by hand. The PR workflow detects manual
edits via a content hash stored as `<!-- doc-superpowers:hash <sha> -->` on
line 2 (where `<sha>` is the lowercase hex SHA-256 of the file bytes from
line 3 onwards — i.e., everything after the two marker lines) and **will not
overwrite** a fragment whose hash has been broken by a human edit — it adds
a PR comment requesting the edit be reconciled with the new commits instead.

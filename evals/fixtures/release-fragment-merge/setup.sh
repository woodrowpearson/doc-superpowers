#!/usr/bin/env bash
# Fixture for eval "release-fragment-merge": the release-draft history plus
# four per-PR fragments — PR-7 sealed (merged), PR-8 no-notes (consumed,
# prints nothing), PR-9 malformed (text before the first ###: skipped, must
# stay), PR-10 hand-edited after sealing (merged as written, with a warning).
. "$(dirname "$0")/../lib.sh"
fx_init "$0"
fx_release_base

mkdir -p RELEASE-NOTES.next
cp "$FX_ROOT/scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md" RELEASE-NOTES.next/README.md
fx_write RELEASE-NOTES.next/PR-7.md <<'MD'
<!-- doc-superpowers:fragment PR-7 -->
<!-- doc-superpowers:hash -->
### Added
- **Export command**: `csvtool export` writes rows back to CSV.
MD
fx_write RELEASE-NOTES.next/PR-8.md <<'MD'
<!-- doc-superpowers:fragment PR-8 -->
<!-- doc-superpowers:hash -->
<!-- doc-superpowers:no-notes -->
MD
fx_write RELEASE-NOTES.next/PR-9.md <<'MD'
<!-- doc-superpowers:fragment PR-9 -->
<!-- doc-superpowers:hash -->
Some prose before any section.
### Fixed
- **Empty input**: the parser returns no rows for an empty file.
MD
fx_write RELEASE-NOTES.next/PR-10.md <<'MD'
<!-- doc-superpowers:fragment PR-10 -->
<!-- doc-superpowers:hash -->
### Fixed
- **Help text**: the original wording.
MD
for n in 7 8 9 10; do fx_seal "RELEASE-NOTES.next/PR-$n.md"; done
fx_commit "chore: fragments for #7, #8, #9, #10"
sed 's/the original wording/`--help` lists every command (human-edited wording)/' RELEASE-NOTES.next/PR-10.md > PR-10.tmp
mv PR-10.tmp RELEASE-NOTES.next/PR-10.md
fx_commit "docs: reword the PR-10 notes by hand"

out=$(dt fragments merge v1.2.0 HEAD 2>merge.err) || fx_die "fragments merge failed: $(cat merge.err)"
err=$(cat merge.err)
rm -f merge.err
fx_expect "PR-7 merges" grep -q "Export command" <<<"$out"
fx_expect "PR-10 merges as written" grep -q "human-edited wording" <<<"$out"
fx_expect "PR-9 is skipped and named" grep -q "PR-9.md: not merged" <<<"$err"
fx_expect "PR-10 is reported hand-edited" grep -q "PR-10.md: hand-edited" <<<"$err"
fx_expect "four fragments are present" test "$(dt fragments list | jq length)" = 4

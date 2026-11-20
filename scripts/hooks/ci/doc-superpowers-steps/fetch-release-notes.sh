#!/usr/bin/env bash
# The doc-security-schedule workflow's fetch: the newest doc-superpowers
# release's RELEASE-NOTES.md, as data, from <repository URL> into <out file>.
#
# The newest release is the highest vX.Y.Z tag `git ls-remote --tags` lists
# (each part 1-9 digits, compared as numbers; any other tag name is ignored).
# That one tag is fetched alone (--depth 1, --no-tags) into a bare scratch
# repository with hooks off, and `git show <tag>:RELEASE-NOTES.md` writes at
# most 2,000,000 bytes of it to <out file>. Nothing fetched runs: no checkout,
# no hook, no script of the release; the next step reads the file's headings.
#
# Usage: fetch-release-notes.sh <repository URL> <out file>
#
# Env:
#   RUNNER_TEMP    where the scratch repository goes (default: a new mktemp -d)
#   GITHUB_OUTPUT  when set, the step output tag=X.Y.Z (the tag chosen, which
#                  security-floor.sh checks the notes' first heading against)
#
# Exit codes: 0 the notes written · 1 with an ::error:: when the URL is empty,
# its tags cannot be listed, it has no release tag, the tag cannot be fetched
# or holds no RELEASE-NOTES.md · 2 bad usage.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <repository URL> <out file>" >&2
  exit 2
fi
URL=$1 OUT=$2
NOTES_MAX=2000000

err() {
  echo "::error::doc-superpowers: $*"
  exit 1
}

[ -n "$URL" ] || err "no repository to read the release notes from: re-run install --ci with --marketplace-url <git URL>"

tags=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs -- "$URL" 'refs/tags/v*' </dev/null 2>/dev/null) \
  || err "cannot list the release tags at $URL"
tag=$(printf '%s\n' "$tags" | awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' \
  | { grep -xE 'v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}' || true; } \
  | sed 's/^v//' | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ -n "$tag" ] || err "$URL has no release tag (vX.Y.Z)"

tmp=${RUNNER_TEMP:-}
[ -n "$tmp" ] || tmp=$(mktemp -d)
repo="$tmp/doc-superpowers-releases.git"
rm -rf "$repo"
git init -q --bare --template= "$repo"
GIT_TERMINAL_PROMPT=0 git -C "$repo" -c core.hooksPath=/dev/null fetch --quiet --no-tags --depth 1 -- \
  "$URL" "refs/tags/v$tag:refs/tags/v$tag" </dev/null \
  || err "cannot fetch tag v$tag from $URL"
git -C "$repo" cat-file -e "refs/tags/v$tag:RELEASE-NOTES.md" 2>/dev/null \
  || err "tag v$tag at $URL has no RELEASE-NOTES.md"
# git stops on the closed pipe once head has its bytes.
{ git -C "$repo" show "refs/tags/v$tag:RELEASE-NOTES.md" 2>/dev/null || true; } \
  | head -c "$NOTES_MAX" > "$OUT"
echo "doc-superpowers: release notes of v$tag from $URL"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tag=$tag" >> "$GITHUB_OUTPUT"
fi

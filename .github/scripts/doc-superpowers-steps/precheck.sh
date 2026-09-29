#!/usr/bin/env bash
# doc-release.yml step "Check for unreleased commits".
#
# Writes `skip=true` to $GITHUB_OUTPUT when there is nothing to release:
#   - HEAD is doc-superpowers' own release-notes commit, by its exact subject
#     however its pull request was merged: "[doc-superpowers] draft release
#     notes" (rebase), "... (#<n>)" (squash) or "Merge pull request #<n> from
#     <owner>/doc-superpowers/release-notes-<run id>[-<attempt>]" (merge
#     commit). Never a substring match: a squash commit that merely lists the
#     bot's "[doc-superpowers] sync …" commits is a release like any other;
#   - HEAD is the last release: nothing after the range start below.
# Otherwise `skip=false` — including the first release.
#
# The range start is the one references/release.md step 2 uses: the latest
# version in RELEASE-NOTES.md (its first "## vX.Y.Z" heading outside code
# fences) — its tag vX.Y.Z when that exists, else the commit that introduced
# the heading (`git log -1 -S '## vX.Y.Z' -- RELEASE-NOTES.md`: an untagged
# release is still a release); with no version entry, the nearest release tag
# (`v[0-9]*` — another tag, such as a deploy marker, is not a release); with
# none, ROOT (the first release). The nearest tag alone took an untagged
# release's commits for unreleased, or the whole history.
#
# Before `skip=false` it runs `doc-tools.sh fragments merge <start> HEAD`,
# which refuses (exit 3) when a release consumed fragments that are still
# here — that release's commit never reached this branch, and drafting now
# would release them twice. This step then fails with an ::error:: saying so
# (merge the release branch into this one, or cherry-pick its release commit,
# then push again); any other non-zero exit of the tool fails it with the
# tool's own message.
#
# Env:
#   GITHUB_OUTPUT  step-output file (set by the runner)
#   DOC_TOOLS      default .github/scripts/doc-tools.sh (the vendored copy)
#
# Exit codes: 0; 1 when the check above refuses or fails (or git fails).
#
# Runs under `set -e`, the runner's default for an unannotated `run:`.
set -e

DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"

subject=$(git log -1 --format=%s)
if printf '%s\n' "$subject" | grep -qE \
  '^(\[doc-superpowers\] draft release notes( \(#[0-9]+\))?|Merge pull request #[0-9]+ from [^ ]+/doc-superpowers/release-notes-[0-9]+(-[0-9]+)?)$'; then
  echo "HEAD is doc-superpowers' own release-notes commit ($subject) — nothing to draft."
  echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# The latest version in RELEASE-NOTES.md: its first "## vX.Y.Z" heading,
# outside code fences (``` / ~~~).
version=""
if [ -f RELEASE-NOTES.md ]; then
  version=$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    !fence && (/^## v[0-9]+\.[0-9]+\.[0-9]+$/ || /^## v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]/) {
      v = substr($0, 5); sub(/[[:space:]].*/, "", v); print v; exit }' RELEASE-NOTES.md)
fi
start="" label=""
if [ -n "$version" ]; then
  if git rev-parse -q --verify "refs/tags/v$version^{commit}" >/dev/null; then
    start="v$version" label="v$version"
  else
    start=$(git log -1 --format=%H -S "## v$version" -- RELEASE-NOTES.md)
    [ -z "$start" ] || label="v$version (untagged; its release commit ${start:0:12})"
  fi
fi
if [ -z "$start" ]; then
  start=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "")
  label="$start"
fi
if [ -n "$start" ]; then
  commit_count=$(git rev-list "${start}..HEAD" --count)
  if [ "$commit_count" -eq 0 ]; then
    echo "No unreleased commits since $label. Skipping."
    echo "skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "$commit_count commits since $label."
else
  echo "No release found (no version entry in RELEASE-NOTES.md, no release tag) — first release."
fi

if [ ! -x "$DOC_TOOLS" ]; then
  echo "::error::$DOC_TOOLS is missing or not executable (re-run the doc-superpowers installer: install --ci)"
  exit 1
fi
rc=0
"$DOC_TOOLS" fragments merge "${start:-ROOT}" HEAD > /dev/null || rc=$?
if [ "$rc" -eq 3 ]; then
  echo "::error::doc-superpowers: an earlier release has not reached this branch (fragments merge refused, above). Merge that release's branch into this one, or cherry-pick its release commit, then push again."
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "::error::doc-superpowers: doc-tools.sh fragments merge failed (exit $rc, its message is above)."
  exit 1
fi
echo "skip=false" >> "$GITHUB_OUTPUT"

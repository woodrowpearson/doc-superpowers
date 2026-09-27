#!/usr/bin/env bash
# doc-release.yml step "Check for unreleased commits".
#
# Writes `skip=true` to $GITHUB_OUTPUT when HEAD is the last tag (nothing to
# release), else `skip=false` — including the first release, when there is no
# tag at all.
#
# Env:
#   GITHUB_OUTPUT  step-output file (set by the runner)
#
# Exit codes: 0 (unless git or the output write fails).
#
# Extracted verbatim from the workflow's inline `run:` body so it can be
# tested; runs under `set -e`, the runner's default for an unannotated `run:`.
set -e

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$last_tag" ]; then
  echo "No tags found — first release."
  echo "skip=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
commit_count=$(git rev-list "${last_tag}..HEAD" --count)
if [ "$commit_count" -eq 0 ]; then
  echo "No unreleased commits since $last_tag. Skipping."
  echo "skip=true" >> "$GITHUB_OUTPUT"
else
  echo "$commit_count commits since $last_tag."
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi

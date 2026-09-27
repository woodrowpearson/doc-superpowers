#!/usr/bin/env bash
# doc-pr-release.yml step "Extract context".
#
# Runs doc-pr-release/extract-context.sh into
# .doc-pr-release/context.json and writes `new_commits_len=<n>` to
# $GITHUB_OUTPUT. Later steps skip the agent when that length is 0.
#
# Env:
#   PR_NUMBER, BASE_REF, GH_TOKEN  passed through to extract-context.sh
#   GITHUB_OUTPUT                  step-output file (set by the runner)
#
# Exit codes: non-zero if extract-context.sh or jq fails (the step goes red).
#
# Extracted from the workflow's inline `run:` body so it can be tested; runs
# under `set -e`, the runner's default for an unannotated `run:`. The only
# change is locating extract-context.sh relative to this script
# (../doc-pr-release/), which is the same file as its installed path
# .github/scripts/doc-pr-release/extract-context.sh once installed.
set -e

mkdir -p .doc-pr-release
"$(dirname "$0")/../doc-pr-release/extract-context.sh" > .doc-pr-release/context.json
new_len=$(jq '.new_commits | length' .doc-pr-release/context.json)
echo "new_commits_len=$new_len" >> "$GITHUB_OUTPUT"

#!/usr/bin/env bash
# doc-pr-release.yml step "Extract context".
#
# Runs extract-context.sh (this script's sibling) into
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
# change is locating extract-context.sh next to this script rather than by its
# installed path, which is the same file once installed.
set -e

mkdir -p .doc-pr-release
"$(dirname "$0")/extract-context.sh" > .doc-pr-release/context.json
new_len=$(jq '.new_commits | length' .doc-pr-release/context.json)
echo "new_commits_len=$new_len" >> "$GITHUB_OUTPUT"

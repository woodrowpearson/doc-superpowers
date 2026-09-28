#!/usr/bin/env bash
# doc-pr-release.yml step "Extract context".
#
# Runs doc-pr-release/extract-context.sh into
# .doc-pr-release/context.json and writes to $GITHUB_OUTPUT:
#   new_commits_len=<n>
#   run=true|false   every later step runs only on run == 'true' — a
#                    positive gate, so a skipped step (the sentinel skip,
#                    whose outputs are all '') never runs them
# run=false when there are no new commits since the last fragment sync, or
# when the PR opted out: its fragment is a hand-written (not sealed)
# <!-- doc-superpowers:no-notes --> — the bot's own sealed no-notes fragment
# is not an opt-out, since new work may need notes.
#
# Env:
#   PR_NUMBER, BASE_REF, GH_TOKEN  passed through to extract-context.sh
#   GITHUB_OUTPUT                  step-output file (set by the runner)
#
# Exit codes: non-zero if extract-context.sh or jq fails (the step goes red,
# and nothing is written to $GITHUB_OUTPUT).
#
# Runs under `set -e`, the runner's default for an unannotated `run:`.
# extract-context.sh is located relative to this script (../doc-pr-release/),
# which is the same file as its installed path
# .github/scripts/doc-pr-release/extract-context.sh once installed.
set -e

mkdir -p .doc-pr-release
"$(dirname "$0")/../doc-pr-release/extract-context.sh" > .doc-pr-release/context.json
new_len=$(jq '.new_commits | length' .doc-pr-release/context.json)
why=$(jq -r '
  if (.new_commits | length) == 0 then "no new commits since the last fragment sync"
  elif .existing_fragment != null and .existing_fragment_no_notes and (.existing_fragment_hash_valid | not)
  then "the PR opted out: \(.fragment_path) is a hand-written <!-- doc-superpowers:no-notes --> fragment"
  else "" end' .doc-pr-release/context.json)
if [ -n "$why" ]; then
  run=false
  echo "Nothing to draft: $why."
else
  run=true
fi
printf 'new_commits_len=%s\nrun=%s\n' "$new_len" "$run" >> "$GITHUB_OUTPUT"

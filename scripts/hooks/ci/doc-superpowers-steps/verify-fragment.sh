#!/usr/bin/env bash
# doc-pr-release.yml step "Verify fragment was produced".
#
# Defense against an agent silent-skip: after the Claude step, require EITHER
# a fresh sync commit at HEAD (and its fragment on disk) OR an existing
# fragment (the agent no-op'd because it was current, or detected a human edit
# and posted a PR comment instead). Anything else fails the job.
#
# Env:
#   PR_NUMBER  the pull request number
#
# Exit codes:
#   0  sync commit with its fragment, or a pre-existing fragment
#   1  sync commit without its fragment, or no fragment and no sync commit
#
# Extracted verbatim from the workflow's inline `run:` body so it can be
# tested.
set -euo pipefail
fragment="RELEASE-NOTES.next/PR-${PR_NUMBER}.md"
head_subject=$(git log -1 --format=%s)
if printf '%s' "$head_subject" | grep -qE '^\[doc-superpowers\] sync PR-[0-9]+ release notes'; then
  echo "::notice::doc-pr-release: fragment commit created — $head_subject"
  if [ ! -f "$fragment" ]; then
    echo "::error::Sync commit present but $fragment is missing on disk." >&2
    exit 1
  fi
  exit 0
fi
# No new sync commit. Acceptable cases:
#   (a) Fragment already current (hash matches existing); agent no-op'd.
#   (b) Human-edit detected; agent posted a PR comment instead.
if [ ! -f "$fragment" ]; then
  echo "::error::No fragment at $fragment and no sync commit produced. The agent appears to have silently skipped writing the fragment." >&2
  exit 1
fi
echo "::notice::doc-pr-release: no new fragment commit (fragment unchanged or human-edited)."

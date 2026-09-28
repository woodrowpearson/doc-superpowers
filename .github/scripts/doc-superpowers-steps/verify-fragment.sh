#!/usr/bin/env bash
# doc-pr-release.yml step "Verify fragment was produced".
#
# Defense against an agent silent-skip: after the commit step, require
#   - a superseded run (someone pushed during it: the commit step committed
#     nothing, and the newer run drafts), or
#   - a fresh sync commit at HEAD whose fragment is on disk with this PR's
#     line-1 marker and a line-2 hash that matches its notes, or
#   - an existing fragment (the agent no-op'd because it was current, or it
#     detected a human edit and posted a PR comment instead).
# Anything else fails the job.
#
# Env:
#   PR_NUMBER   the pull request number
#   SUPERSEDED  the commit step's `superseded` output ("true" or empty)
#
# Exit codes:
#   0  superseded; a sync commit with its sealed fragment; or a pre-existing
#      fragment
#   1  a sync commit whose fragment is missing or not sealed, or no fragment
#      and no sync commit
set -euo pipefail
lib="$(dirname "$0")/../doc-pr-release/fragment-lib.sh"
if [ ! -f "$lib" ]; then
  echo "::error::$lib is missing (re-run the doc-superpowers installer: install --ci)" >&2
  exit 1
fi
# The fragment line rules (frag_marker, frag_sealed), shared with commit-and-push.sh.
# shellcheck source=scripts/hooks/ci/doc-pr-release/fragment-lib.sh
. "$lib"
fragment="RELEASE-NOTES.next/PR-${PR_NUMBER}.md"
if [ "${SUPERSEDED:-}" = "true" ]; then
  echo "::notice::doc-pr-release: superseded — the branch received new commits during this run; the run they started drafts the fragment."
  exit 0
fi
head_subject=$(git log -1 --format=%s)
if printf '%s' "$head_subject" | grep -qE '^\[doc-superpowers\] sync PR-[0-9]+ release notes'; then
  echo "::notice::doc-pr-release: fragment commit created — $head_subject"
  if [ ! -f "$fragment" ] || [ -L "$fragment" ]; then
    echo "::error::Sync commit present but $fragment is missing on disk." >&2
    exit 1
  fi
  if ! frag_sealed "$fragment" || [ "$FRAG_L1" != "$(frag_marker "$PR_NUMBER")" ]; then
    echo "::error::Sync commit present but $fragment is not sealed (line 1 must be this PR's marker, line 2 the sha256 of the bytes from line 3)." >&2
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

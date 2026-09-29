#!/usr/bin/env bash
# doc-review-pr.yml's comment job, before the agent: an @claude comment runs
# the agent only on a same-repository pull request. The issue_comment event
# does not carry the head repository, so the API is asked. (A fork's code
# must not run under this repository's secrets.)
#
# Env:
#   PR_NUMBER          the pull request the comment is on
#   GITHUB_REPOSITORY  owner/repo (set by the runner)
#   GH_TOKEN           for gh api
#   GITHUB_OUTPUT      step-output file (set by the runner)
#
# Outputs: same_repo=true|false
#
# Exit codes: 0; 1 (with an ::error::) for a bad PR number or a failed API call.
set -euo pipefail

[ -n "${GITHUB_OUTPUT:-}" ] || { echo "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)" >&2; exit 2; }
REPO="${GITHUB_REPOSITORY:-}"
if ! [[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::doc-superpowers: '${PR_NUMBER:-}' is not a pull request number."
  exit 1
fi
if [ -z "$REPO" ] || ! head_repo=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq '.head.repo.full_name // ""'); then
  echo "::error::doc-superpowers: cannot read pull request #$PR_NUMBER of '$REPO' (gh api)."
  exit 1
fi
if [ -n "$head_repo" ] && [ "$head_repo" = "$REPO" ]; then
  echo "same_repo=true" >> "$GITHUB_OUTPUT"
else
  echo "::notice::doc-superpowers: #$PR_NUMBER comes from ${head_repo:-a deleted repository}; @claude answers only on pull requests from $REPO."
  echo "same_repo=false" >> "$GITHUB_OUTPUT"
fi

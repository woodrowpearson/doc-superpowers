#!/usr/bin/env bash
# Stage the per-PR fragment, commit (if changes exist), and push to the PR
# branch. Designed to be safe to run multiple times in the same workflow run.
#
# Args:
#   $1  PR number (used in commit message)
#
# Env:
#   FRAGMENT_PATH   Path to the fragment file (default: RELEASE-NOTES.next/PR-<N>.md)
#   GIT_USER_NAME   Override commit author name  (default: github-actions[bot])
#   GIT_USER_EMAIL  Override commit author email (default: 41898282+github-actions[bot]@users.noreply.github.com)
#   DOC_PR_RELEASE_PUSH_RETRIES  Number of rebase-and-retry attempts on
#                                non-fast-forward push rejection (default: 2).
#
# Exit codes:
#   0  committed and pushed, OR no changes staged (no-op)
#   1  git error (including push rejected after all retries)
#   2  bad arguments
set -euo pipefail

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <pr-number>" >&2
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "PR_NUMBER must be a positive integer, got: $PR_NUMBER" >&2
  exit 2
fi

FRAGMENT_PATH="${FRAGMENT_PATH:-RELEASE-NOTES.next/PR-${PR_NUMBER}.md}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

if [ ! -f "$FRAGMENT_PATH" ]; then
  echo "No fragment at $FRAGMENT_PATH — nothing to commit."
  exit 0
fi

git add "$FRAGMENT_PATH"

if git diff --cached --quiet -- "$FRAGMENT_PATH"; then
  echo "Fragment unchanged — no commit."
  exit 0
fi

SHORT_SHA=$(git rev-parse --short HEAD)
git \
  -c "user.name=${GIT_USER_NAME}" \
  -c "user.email=${GIT_USER_EMAIL}" \
  commit -m "[doc-superpowers] sync PR-${PR_NUMBER} release notes (${SHORT_SHA})"

# Push to the PR branch. GITHUB_HEAD_REF is set by pull_request events.
BRANCH="${GITHUB_HEAD_REF:-}"
if [ -z "$BRANCH" ]; then
  echo "GITHUB_HEAD_REF is unset; refusing to guess the push target." >&2
  echo "Set GITHUB_HEAD_REF to the PR branch name (the workflow does this automatically for pull_request events)." >&2
  exit 1
fi

# Push with retry on non-fast-forward rejection. A human (or another workflow)
# may have pushed to the PR branch between checkout and now. Rebase our single
# fragment commit onto the new tip and retry. We deliberately do NOT use
# `--force-with-lease`: the goal is to preserve the human's work, not overwrite
# it. If the rebase itself conflicts (extremely unlikely — we only touch one
# fragment file the bot exclusively manages), we fail loudly rather than
# guessing how to resolve.
PUSH_RETRIES="${DOC_PR_RELEASE_PUSH_RETRIES:-2}"
attempt=0
while :; do
  if git push origin "HEAD:${BRANCH}"; then
    break
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -gt "$PUSH_RETRIES" ]; then
    echo "Push to origin/${BRANCH} rejected after ${PUSH_RETRIES} retries." >&2
    exit 1
  fi
  echo "Push rejected (non-fast-forward?); fetching and rebasing attempt ${attempt}/${PUSH_RETRIES}." >&2
  if ! git fetch origin "$BRANCH"; then
    echo "git fetch origin ${BRANCH} failed." >&2
    exit 1
  fi
  if ! git \
    -c "user.name=${GIT_USER_NAME}" \
    -c "user.email=${GIT_USER_EMAIL}" \
    rebase "origin/${BRANCH}"; then
    echo "Rebase onto origin/${BRANCH} failed (conflict in fragment?); aborting." >&2
    git rebase --abort 2>/dev/null || true
    exit 1
  fi
done

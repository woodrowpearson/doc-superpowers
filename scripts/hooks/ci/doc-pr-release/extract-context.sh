#!/usr/bin/env bash
# Emit a single JSON document on stdout describing the context the Claude
# Code Action needs to update a PR's release-notes fragment.
#
# Env (all required when not running under GitHub Actions):
#   PR_NUMBER  The pull request number.
#   BASE_REF   The base branch ref (e.g., "main").
#
# Under GitHub Actions, defaults are taken from the `pull_request` event
# payload at $GITHUB_EVENT_PATH.
#
# Output: one JSON object. Schema:
# {
#   "pr_number":         integer,
#   "head_ref":          string,
#   "base_ref":          string,
#   "head_sha":          string,
#   "base_sha":          string,
#   "pr_body":           string,
#   "existing_fragment": string | null,
#   "fragment_path":     string,
#   "new_commits":       [{"sha": str, "subject": str, "body": str}],
#   "full_commits":      [{"sha": str, "subject": str, "body": str}]
# }
set -euo pipefail

# Resolve PR number / base ref from env or event payload.
if [ -z "${PR_NUMBER:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  PR_NUMBER=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
fi
if [ -z "${BASE_REF:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  BASE_REF=$(jq -r '.pull_request.base.ref // "main"' "$GITHUB_EVENT_PATH")
fi
BASE_REF="${BASE_REF:-main}"

if [ -z "${PR_NUMBER:-}" ]; then
  echo "PR_NUMBER not set and not derivable from event payload" >&2
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "PR_NUMBER must be a positive integer, got: $PR_NUMBER" >&2
  exit 2
fi

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,body,headRefName,baseRefName)
PR_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')
HEAD_REF=$(printf '%s' "$PR_JSON" | jq -r '.headRefName')

HEAD_SHA=$(git rev-parse HEAD)
# Use merge-base so we get the divergence point, not a stale base tip.
if git rev-parse --verify "origin/$BASE_REF" >/dev/null 2>&1; then
  BASE_SHA=$(git merge-base "origin/$BASE_REF" HEAD)
else
  BASE_SHA=$(git merge-base "$BASE_REF" HEAD)
fi

FRAGMENT_PATH="RELEASE-NOTES.next/PR-${PR_NUMBER}.md"
EXISTING_FRAGMENT_JSON="null"
if [ -f "$FRAGMENT_PATH" ]; then
  EXISTING_FRAGMENT_JSON=$(jq -Rs '.' <"$FRAGMENT_PATH")
fi

# Find the last commit on this branch that touched the fragment file.
# That commit's children (i.e., everything strictly after it) is the "new" range.
LAST_FRAG_COMMIT=""
if [ -f "$FRAGMENT_PATH" ]; then
  LAST_FRAG_COMMIT=$(git log -n 1 --format="%H" -- "$FRAGMENT_PATH")
fi
NEW_RANGE_START="${LAST_FRAG_COMMIT:-$BASE_SHA}"

# Emit commits in $1..HEAD range as a JSON array. Each element is
# {sha, subject, body}. Uses git log --format='%H%x1F%s%x1F%b%x1E' so we
# get Unit-Separator-separated fields and Record-Separator-separated records,
# then slurps the stream through jq for robust JSON encoding (handles any
# unicode, embedded newlines in body, etc.).
emit_commits_json() {
  local range="$1"
  # If range is empty (e.g., HEAD..HEAD), emit []
  local count
  count=$(git rev-list --count "$range")
  if [ "$count" -eq 0 ]; then
    echo "[]"
    return 0
  fi
  git log --reverse --no-merges --format=$'%H\x1F%s\x1F%b\x1E' "$range" \
    | jq -Rs '
        split("")
        | map(ltrimstr("
"))
        | map(select(length > 0 and contains("")))
        | map(split(""))
        | map({sha: .[0], subject: .[1], body: (.[2] // "")})
        | map(.body |= rtrimstr("\n"))
      '
}

NEW_COMMITS_JSON=$(emit_commits_json "${NEW_RANGE_START}..${HEAD_SHA}")
FULL_COMMITS_JSON=$(emit_commits_json "${BASE_SHA}..${HEAD_SHA}")

jq -n \
  --argjson pr_number "$PR_NUMBER" \
  --arg head_ref "$HEAD_REF" \
  --arg base_ref "$BASE_REF" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg pr_body "$PR_BODY" \
  --argjson existing_fragment "$EXISTING_FRAGMENT_JSON" \
  --arg fragment_path "$FRAGMENT_PATH" \
  --argjson new_commits "$NEW_COMMITS_JSON" \
  --argjson full_commits "$FULL_COMMITS_JSON" \
  '{
    pr_number: $pr_number,
    head_ref: $head_ref,
    base_ref: $base_ref,
    head_sha: $head_sha,
    base_sha: $base_sha,
    pr_body: $pr_body,
    existing_fragment: $existing_fragment,
    fragment_path: $fragment_path,
    new_commits: $new_commits,
    full_commits: $full_commits
  }'

#!/usr/bin/env bash
# scripts/adapters/ledger-pr-gh.sh — the work ledger's reference PR adapter
# (design §G; config "adapters": {"pr": "doc-superpowers:ledger-pr-gh"}):
# the repository's pull requests from the GitHub CLI.
#
#   ledger-pr-gh.sh list
#     Two calls, run in the current directory (the ledger runs adapters
#     from the work tree's top level, so gh finds the repository from its
#     remotes), each `--json number,headRefName,state,url,mergeCommit,
#     isCrossRepository`:
#       gh pr list --state open --limit 1000    (every open PR: in review)
#       gh pr list --state merged --limit 500   (the newest merged PRs)
#     Closed (unmerged) PRs are not asked for: no derived status reads them.
#     When the open call returns as many PRs as its limit, the list may be
#     cut: exit 2 ("could not list completely"), never a silent truncation
#     (a cut merged list only drops the oldest merged PRs, whose trailer
#     claims the base's history carries anyway). Output: one compact JSON
#     line per PR, the open ones first —
#       {"number": <n>, "head": <headRefName>, "state": "open"|"merged",
#        "url": <url>, "merge_commit": <mergeCommit.oid>|null,
#        "cross": <isCrossRepository>}
#     ("cross": the head is a fork's branch — the ledger never resolves it
#     through a same-named branch of its own remote).
#
# Exit: 0 listed · 2 could not list — gh missing, gh failing (its stderr is
# passed through), output that is not gh's JSON list, or the open list at
# its limit · 3 usage. The ledger caches the list (cache.remote_ttl_minutes;
# scripts/ledger/adapters.sh _lg_remote_cache), so gh runs at most once per
# TTL.
#
# bash 3.2 + jq >= 1.6.
set -euo pipefail

case "${1:-}" in
  list) ;;
  *)
    echo "usage: ledger-pr-gh.sh list" >&2
    exit 3 ;;
esac
if [ "$#" -ne 1 ]; then
  echo "usage: ledger-pr-gh.sh list" >&2
  exit 3
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ledger-pr-gh: gh (the GitHub CLI) is not on PATH — install it and run 'gh auth login'" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ledger-pr-gh: jq is not on PATH" >&2
  exit 2
fi

OPEN_LIMIT=1000
MERGED_LIMIT=500
FIELDS=number,headRefName,state,url,mergeCommit,isCrossRepository

# gh_list <state> <limit>: gh's JSON list (its stderr goes straight
# through) normalised to the output lines.
# shellcheck disable=SC2016  # jq source
gh_list() {
  local json=""
  if ! json=$(gh pr list --state "$1" --limit "$2" --json "$FIELDS" < /dev/null); then
    echo "ledger-pr-gh: gh pr list --state $1 failed" >&2
    return 2
  fi
  if ! printf '%s\n' "$json" | jq -c --argjson limit "$2" --arg st "$1" '
      if type != "array" then error("gh pr list did not print a JSON list")
      elif $st == "open" and length >= $limit then error("could not list completely: \(length) open PRs ≥ limit \($limit)")
      else .[] end
      | {number: .number,
         head: .headRefName,
         state: ((.state // "") | ascii_downcase | if . == "open" or . == "merged" then . else "closed" end),
         url: .url,
         merge_commit: (.mergeCommit | if type == "object" then (.oid // null) else null end),
         cross: (.isCrossRepository == true)}'; then
    echo "ledger-pr-gh: cannot use gh's output for --state $1" >&2
    return 2
  fi
}

out=$(gh_list open "$OPEN_LIMIT") || exit 2
merged=$(gh_list merged "$MERGED_LIMIT") || exit 2
if [ -n "$out" ]; then printf '%s\n' "$out"; fi
if [ -n "$merged" ]; then printf '%s\n' "$merged"; fi

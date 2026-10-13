#!/usr/bin/env bash
# scripts/adapters/ledger-pr-gh.sh — the work ledger's reference PR adapter
# (design §G; config "adapters": {"pr": "doc-superpowers:ledger-pr-gh"}):
# the repository's pull requests from the GitHub CLI.
#
#   ledger-pr-gh.sh list
#     `gh pr list --state all --limit 500 --json
#     number,headRefName,state,url,mergeCommit`, run in the current
#     directory (the ledger runs adapters from the work tree's top level, so
#     gh finds the repository from its remotes), as one compact JSON line
#     per pull request:
#       {"number": <n>, "head": <headRefName>, "state": "open"|"merged"|"closed",
#        "url": <url>, "merge_commit": <mergeCommit.oid>|null}
#     (gh's OPEN / MERGED / CLOSED, lowercased; any other state reads as
#     closed). Nothing for a repository without pull requests.
#
# Exit: 0 listed · 2 could not list — gh missing, gh failing (its stderr is
# passed through), or output that is not gh's JSON list · 3 usage.
# The ledger caches the list (cache.remote_ttl_minutes; scripts/ledger/
# adapters.sh _lg_remote_cache), so gh runs at most once per TTL.
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

# gh's stderr goes straight through; its stdout is the JSON list.
json=""
if ! json=$(gh pr list --state all --limit 500 --json number,headRefName,state,url,mergeCommit < /dev/null); then
  echo "ledger-pr-gh: gh pr list failed" >&2
  exit 2
fi

# shellcheck disable=SC2016  # jq source
if ! printf '%s\n' "$json" | jq -c '
    if type != "array" then error("gh pr list did not print a JSON list") else .[] end
    | {number: .number,
       head: .headRefName,
       state: ((.state // "") | ascii_downcase | if . == "open" or . == "merged" then . else "closed" end),
       url: .url,
       merge_commit: (.mergeCommit | if type == "object" then (.oid // null) else null end)}'; then
  echo "ledger-pr-gh: cannot read gh's output as its JSON list" >&2
  exit 2
fi

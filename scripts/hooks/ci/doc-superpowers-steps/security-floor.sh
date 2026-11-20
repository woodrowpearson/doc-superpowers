#!/usr/bin/env bash
# The doc-security-schedule workflow's check: does the project's doc-search
# floor (the "requires" of docs/search/config.json, ">=X.Y.Z") meet the newest
# doc-superpowers security release? A release is a security release when its
# "## vX.Y.Z (YYYY-MM-DD)" section of RELEASE-NOTES.md holds a "### Security"
# heading; the vendored `doc-tools.sh tools security-floor` reads that marker
# (fenced text never counts, and no security release newer than the notes'
# own first release heading counts). The notes are data: only that verb's awk
# program reads them, and nothing in them runs.
#
# Usage: security-floor.sh <release-notes file> <docs/search/config.json>
#
# Env:
#   DOC_TOOLS  default .github/scripts/doc-tools.sh (the vendored copy)
#
# Exit codes: 0 requires meets the newest security release, or the notes
# hold none; also 0 with a ::warning:: when the config is absent or sets no
# requires (there is no floor to check) · 1 with an ::error:: when requires is
# below it, is not ">=X.Y.Z", or the notes or the config cannot be read · 2
# bad usage.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <release-notes file> <docs/search/config.json>" >&2
  exit 2
fi
NOTES=$1 CONFIG=$2
DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"

err() {
  echo "::error::doc-superpowers: $*"
  exit 1
}

if [ ! -f "$CONFIG" ]; then
  echo "::warning::doc-superpowers: no $CONFIG, so no requires floor to check against the newest security release"
  exit 0
fi
requires=$(jq -r 'if type == "object" then (.requires // "") else error("not an object") end' "$CONFIG" 2>/dev/null) \
  || err "$CONFIG is not a JSON object jq can read"
if [ -z "$requires" ]; then
  echo "::warning::doc-superpowers: $CONFIG sets no requires, so no floor to check against the newest security release (set \"requires\": \">=X.Y.Z\")"
  exit 0
fi
floor=${requires#>=}
if [ "$floor" = "$requires" ] || ! [[ "$floor" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ ]]; then
  err "$CONFIG sets requires to '$(printf '%s' "$requires" | LC_ALL=C tr -d '\000-\037\177' | cut -c 1-40)', not \">=X.Y.Z\""
fi
[ -f "$NOTES" ] && [ -r "$NOTES" ] || err "the release notes $NOTES cannot be read"

rc=0
out=$("$DOC_TOOLS" tools security-floor --floor "$floor" "$NOTES" 2>&1) || rc=$?
newest=$(printf '%s\n' "$out" | sed -n 's/^newest-security //p')
first=$(printf '%s\n' "$out" | sed -n 's/^first //p' | LC_ALL=C tr -d '\000-\037\177' | cut -c 1-40)
case "$rc" in
  0)
    if [ -n "$newest" ]; then
      echo "doc-superpowers: requires >=$floor meets the newest security release, $newest (release notes v${first:-unknown})"
    else
      echo "doc-superpowers: the release notes (v${first:-unknown}) name no security release; requires >=$floor stands"
    fi
    ;;
  1)
    err "requires >=$floor in $CONFIG is below doc-superpowers security release $newest (release notes v${first:-unknown}): upgrade doc-superpowers (bash \"\$DOC_SUPERPOWERS_ROOT/scripts/hooks/install.sh\" upgrade, or claude plugin update doc-superpowers), then raise requires to \">=$newest\""
    ;;
  *)
    printf '%s\n' "$out" >&2
    err "doc-tools.sh tools security-floor could not read $NOTES (exit $rc, above)"
    ;;
esac

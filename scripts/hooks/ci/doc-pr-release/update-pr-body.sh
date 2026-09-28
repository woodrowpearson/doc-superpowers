#!/usr/bin/env bash
# Update a PR body by replacing the content between
# <!-- doc-superpowers:start --> and <!-- doc-superpowers:end -->.
#
# Usage:
#   echo "new managed section content" | update-pr-body.sh <pr-number>
#
# Env:
#   DOC_SUPERPOWERS_DRY_RUN=1    Print proposed new body to stdout, skip `gh pr edit`.
#   DOC_SUPERPOWERS_EXISTING_BODY  Override the existing body source (testing only).
#                                  When unset, falls back to `gh pr view --json body`.
#
# Exit codes:
#   0  success (edit applied, or no-op because content unchanged)
#   1  malformed markers in existing body
#   2  bad arguments / missing dependencies
set -euo pipefail

START_MARKER='<!-- doc-superpowers:start -->'
END_MARKER='<!-- doc-superpowers:end -->'

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <pr-number>" >&2
  exit 2
fi

# Read new content from stdin.
NEW_SECTION="$(cat)"

# Reject marker injection: new section content must not contain either marker literally.
if printf '%s' "$NEW_SECTION" | grep -qF "$START_MARKER"; then
  echo "ERROR: new section content contains literal start marker — refusing to write" >&2
  exit 1
fi
if printf '%s' "$NEW_SECTION" | grep -qF "$END_MARKER"; then
  echo "ERROR: new section content contains literal end marker — refusing to write" >&2
  exit 1
fi

# Resolve existing body.
if [ -n "${DOC_SUPERPOWERS_EXISTING_BODY+x}" ]; then
  EXISTING_BODY="$DOC_SUPERPOWERS_EXISTING_BODY"
else
  command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 2; }
  EXISTING_BODY="$(gh pr view "$PR_NUMBER" --json body --jq '.body // ""')"
fi

# Normalize line endings to LF (handles bodies edited via Windows web UI).
EXISTING_BODY="${EXISTING_BODY//$'\r'/}"

# One pass over the body finds the managed section and checks its markers.
# A marker counts only as a line on its own outside a code fence (``` or ~~~,
# any indent): a fenced example of the markers is prose, left as it is, and
# never the section. Inside the section only its END marker is looked for.
# Refused (exit 1, the body untouched): a marker inside a line (outside a
# fence), a second START or END, an END before the START, a START without
# an END, or no section and a body that ends inside an unclosed fence (an
# appended section would be code, never found again). A section found
# before an unclosed fence is replaced as usual. Passes NEW_SECTION via
# ENVIRON (avoids -v multiline issues on BSD awk).
# shellcheck disable=SC2016
FENCED_AWK='
# --- fence parser (the same text in scripts/doc-tools.sh _FRAG_AWK and
# --- scripts/hooks/ci/doc-pr-release/update-pr-body.sh FENCED_AWK; keep them
# --- identical: scripts/test-doc-pr-release.sh diffs them and feeds both the
# --- same fence fixtures)
# A code fence opens with 3+ backticks or tildes (any indent) and closes with
# at least as many of the same character and nothing else.
function fence_open(l,   t, c, k) {
  t = l; sub(/^[ \t]+/, "", t)
  c = substr(t, 1, 1)
  if (c != "`" && c != "~") return 0
  k = 0; while (substr(t, k + 1, 1) == c) k++
  if (k < 3) return 0
  if (c == "`" && index(substr(t, k + 1), "`") > 0) return 0
  fc = c; fl = k
  return 1
}
function fence_close(l,   t, k) {
  t = l; sub(/^[ \t]+/, "", t)
  k = 0; while (substr(t, k + 1, 1) == fc) k++
  if (k < fl) return 0
  return (substr(t, k + 1) ~ /^[ \t]*$/)
}
# --- end fence parser
BEGIN { state = "out"; found = 0; err = 0 }
{
  if (state == "fence") { out = out $0 "\n"; if (fence_close($0)) state = "out"; next }
  if (state == "block") {
    if ($0 == end) { state = "out"; next }
    if ($0 == start) { err = 4; exit }
    next
  }
  if ($0 == start) {
    if (found) { err = 4; exit }
    found = 1; state = "block"
    out = out start "\n" ENVIRON["NEW_SECTION"] "\n" end "\n"
    next
  }
  if ($0 == end) { err = (found ? 4 : 6); exit }
  if (index($0, start) || index($0, end)) { err = 3; exit }
  if (fence_open($0)) state = "fence"
  out = out $0 "\n"
}
END {
  if (err) exit err
  if (state == "block") exit 5
  # Appending after an unclosed fence would land inside the code block:
  # never found again, one more section per run.
  if (!found && state == "fence") exit 8
  if (!found) exit 7
  printf "%s", out
}'

rc=0
NEW_BODY=$(NEW_SECTION="$NEW_SECTION" awk -v start="$START_MARKER" -v end="$END_MARKER" "$FENCED_AWK" <<<"$EXISTING_BODY") || rc=$?
case "$rc" in
  0) ;;
  7)
    # No managed section yet — append.
    if [ -z "$EXISTING_BODY" ]; then
      NEW_BODY="${START_MARKER}
${NEW_SECTION}
${END_MARKER}"
    else
      # Strip any trailing newlines from the existing body before adding the
      # blank-line separator, so we don't end up with 3+ blank lines if the
      # body already ended with whitespace.
      existing_stripped="${EXISTING_BODY}"
      while [ "${existing_stripped: -1}" = $'\n' ]; do
        existing_stripped="${existing_stripped%$'\n'}"
      done
      NEW_BODY="${existing_stripped}

${START_MARKER}
${NEW_SECTION}
${END_MARKER}"
    fi
    ;;
  3) echo "ERROR: doc-superpowers marker found outside of a line on its own — refusing to edit" >&2; exit 1 ;;
  4) echo "ERROR: duplicate doc-superpowers markers in PR body" >&2; exit 1 ;;
  5) echo "ERROR: unmatched doc-superpowers markers (a start marker with no end marker after it)" >&2; exit 1 ;;
  6) echo "ERROR: the doc-superpowers end marker comes before the start marker — refusing to edit" >&2; exit 1 ;;
  8) echo "ERROR: the PR body ends inside an unclosed code fence, so a doc-superpowers section appended after it would be part of the code block — refusing to edit (close the fence)" >&2; exit 1 ;;
  *) echo "ERROR: parsing the PR body failed (awk exit $rc)" >&2; exit 1 ;;
esac

# No-op check. Normalize trailing newlines on both sides: `gh pr view --jq` may
# emit a trailing \n that `$()` strips, while the awk-built NEW_BODY does not.
existing_trim="${EXISTING_BODY%$'\n'}"
new_trim="${NEW_BODY%$'\n'}"
if [ "$new_trim" = "$existing_trim" ]; then
  if [ "${DOC_SUPERPOWERS_DRY_RUN:-0}" = "1" ]; then
    printf '%s' "$existing_trim"
  fi
  exit 0
fi

# Emit or apply.
if [ "${DOC_SUPERPOWERS_DRY_RUN:-0}" = "1" ]; then
  printf '%s' "$NEW_BODY"
  exit 0
fi

# Real edit. Use a tempfile to avoid argv length limits and quoting issues.
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
printf '%s' "$NEW_BODY" >"$TMPFILE"
gh pr edit "$PR_NUMBER" --body-file "$TMPFILE"

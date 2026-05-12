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

# Validate marker pairing. We count lines where the marker is the ENTIRE line
# (`grep -cFx`), matching the awk replace below which uses `$0 == start`. An
# `grep -oF | wc -l` (any-substring) count would over-accept: a stray
# mid-line `<!-- doc-superpowers:start -->` in user prose would pass validation
# but awk would not replace it, leaving an orphan marker after fresh-append.
# `grep -c` exits 1 on zero matches; with `pipefail` set we allow that.
start_count=$( { printf '%s\n' "$EXISTING_BODY" | grep -cFx "$START_MARKER" || true; } | tr -d ' \n')
end_count=$( { printf '%s\n' "$EXISTING_BODY" | grep -cFx "$END_MARKER" || true; } | tr -d ' \n')
# Belt-and-suspenders: catch ANY occurrence (including same-line dupes or stray
# mid-line markers). A non-line-anchored hit means a malformed body.
any_start=$( { printf '%s\n' "$EXISTING_BODY" | grep -oF "$START_MARKER" || true; } | wc -l | tr -d ' ')
any_end=$( { printf '%s\n' "$EXISTING_BODY" | grep -oF "$END_MARKER" || true; } | wc -l | tr -d ' ')
if [ "$any_start" -ne "$start_count" ] || [ "$any_end" -ne "$end_count" ]; then
  echo "ERROR: doc-superpowers marker found outside of a line on its own — refusing to edit" >&2
  exit 1
fi
if [ "$start_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
  echo "ERROR: duplicate doc-superpowers markers in PR body" >&2
  exit 1
fi
if [ "$start_count" -ne "$end_count" ]; then
  echo "ERROR: unmatched doc-superpowers markers (start=$start_count, end=$end_count)" >&2
  exit 1
fi

# Build the new body.
if [ "$start_count" -eq 0 ]; then
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
else
  # Replace existing section. Pass NEW_SECTION via ENVIRON (avoids -v multiline issues on BSD awk).
  # shellcheck disable=SC2016
  NEW_BODY=$(NEW_SECTION="$NEW_SECTION" awk -v start="$START_MARKER" -v end="$END_MARKER" '
    BEGIN { in_block = 0 }
    {
      if ($0 == start) {
        print start
        print ENVIRON["NEW_SECTION"]
        print end
        in_block = 1
        next
      }
      if ($0 == end) {
        in_block = 0
        next
      }
      if (!in_block) print $0
    }
  ' <<<"$EXISTING_BODY")
fi

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

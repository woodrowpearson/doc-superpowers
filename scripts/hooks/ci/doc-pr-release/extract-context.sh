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
#   "existing_fragment":            string | null,
#   "existing_fragment_corrupt":    bool,
#   "existing_fragment_hash_valid": bool,
#   "existing_fragment_no_notes":   bool,
#   "fragment_path":                string,
#   "new_since":                    string,
#   "new_commits":                  [{"sha": str, "subject": str, "body": str}],
#   "full_commits":                 [{"sha": str, "subject": str, "body": str}]
# }
#
# existing_fragment_corrupt: a fragment file exists but is not one to
#   auto-edit — a symbolic link or over 1 MiB (neither is read:
#   existing_fragment stays null), a wrong line-1 marker, no hash marker on
#   line 2, or nothing after it. The agent posts a PR comment instead.
# existing_fragment_hash_valid: line 2's hash is the sha256 of the bytes from
#   line 3 on. False = a human edited it (or it is corrupt): never overwritten.
# existing_fragment_no_notes: its notes are only <!-- doc-superpowers:no-notes -->.
#   A hand-written one (hash not valid) opts the PR out (write-context.sh).
# new_since: the commit new_commits start after — the checkout the newest
#   sync commit recorded (its Doc-Superpowers-Drafted-From: trailer, or the
#   short SHA in its subject), else that commit's parent, else base_sha.
# new_commits / full_commits: the PR's own work since new_since / the base,
#   oldest first — never a base-branch commit (merged in by "Update branch"),
#   a merge commit, a commit that only touches RELEASE-NOTES.next/, or one of
#   doc-superpowers' own [doc-superpowers] commits.
#
# Every payload reaches jq through a file, never argv: one argument is capped
# at 128 KiB on Linux (argv + env at ~1 MiB on macOS).
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

lib="$(dirname "$0")/fragment-lib.sh"
[ -f "$lib" ] || { echo "$lib is missing (re-run the doc-superpowers installer: install --ci)" >&2; exit 1; }
# The fragment line rules: frag_marker, frag_lines, frag_is_hash_line, frag_stored, frag_sha256.
# shellcheck source=scripts/hooks/ci/doc-pr-release/fragment-lib.sh
. "$lib"

T=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-context.XXXXXX") || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

gh pr view "$PR_NUMBER" --json number,body,headRefName,baseRefName > "$T/pr.json"
HEAD_REF=$(jq -r '.headRefName // ""' "$T/pr.json")

HEAD_SHA=$(git rev-parse HEAD)
# The base branch's tip — `origin/$BASE_REF` in CI (fetch-depth: 0), the bare
# name in a manual run. Everything it reaches is the base's, not this PR's.
if git rev-parse --verify --quiet "origin/$BASE_REF^{commit}" >/dev/null; then
  BASE_TIP="origin/$BASE_REF"
else
  BASE_TIP="$BASE_REF"
fi
BASE_SHA=$(git merge-base "$BASE_TIP" HEAD)

FRAGMENT_PATH="RELEASE-NOTES.next/PR-${PR_NUMBER}.md"
# Never read into memory past this: 1 MiB is ~5000 lines of release notes.
FRAGMENT_MAX_BYTES=1048576
HAS_FRAGMENT=false
CORRUPT=false
HASH_VALID=false
NO_NOTES=false
FRAGMENT_FILE=/dev/null
if [ -L "$FRAGMENT_PATH" ]; then
  echo "Existing fragment $FRAGMENT_PATH is a symbolic link; not read, marking corrupt." >&2
  CORRUPT=true
elif [ -f "$FRAGMENT_PATH" ]; then
  frag_bytes=$(wc -c <"$FRAGMENT_PATH" | tr -d ' ')
  if [ "$frag_bytes" -gt "$FRAGMENT_MAX_BYTES" ]; then
    echo "Existing fragment is ${frag_bytes} bytes (>${FRAGMENT_MAX_BYTES}); marking corrupt." >&2
    CORRUPT=true
  else
    HAS_FRAGMENT=true
    FRAGMENT_FILE="$FRAGMENT_PATH"
    # The notes start after a hash line, else after line 1 (a hand edit).
    frag_notes "$FRAGMENT_PATH" "$T/notes"
    l1="$FRAG_L1"
    stored=$(frag_stored "$FRAG_L2")
    tail -n +3 "$FRAGMENT_PATH" > "$T/payload"
    actual=$(frag_sha256 < "$T/payload")
    if [ -n "$stored" ] && [ "$stored" = "$actual" ]; then
      HASH_VALID=true
    fi
    if awk '{ sub(/\r$/, "") } /^[ \t]*$/ { next } { n++ } /^[ \t]*<!-- doc-superpowers:no-notes -->[ \t]*$/ { m++ }
            END { exit !(n == 1 && m == 1) }' "$T/notes"; then
      NO_NOTES=true
    fi
    if [ "$l1" != "$(frag_marker "$PR_NUMBER")" ] || [ -z "$stored" ] \
       || ! grep -q . "$T/payload"; then
      CORRUPT=true
    fi
  fi
fi

# The watermark: the checkout the newest sync commit of this PR recorded.
NEW_SINCE="$BASE_SHA"
sync_re="^\\[doc-superpowers\\] sync PR-${PR_NUMBER} release notes( \\(([0-9a-f]{7,64})\\))?\$"
trailer_re='^Doc-Superpowers-Drafted-From: ([0-9a-f]{40,64})$'
while IFS=$'\037' read -r sync_sha subject; do
  [[ $subject =~ $sync_re ]] || continue
  recorded="${BASH_REMATCH[2]}"
  while IFS= read -r line; do
    if [[ $line =~ $trailer_re ]]; then
      recorded="${BASH_REMATCH[1]}"
    fi
  done < <(git log -1 --format=%b "$sync_sha")
  NEW_SINCE=""
  if [ -n "$recorded" ] && full=$(git rev-parse --verify --quiet "$recorded^{commit}") \
     && git merge-base --is-ancestor "$full" HEAD; then
    NEW_SINCE="$full"
  fi
  # No usable record (a rewritten branch): what came before the sync commit.
  [ -n "$NEW_SINCE" ] || NEW_SINCE=$(git rev-parse --verify --quiet "$sync_sha^1") || NEW_SINCE="$BASE_SHA"
  break
done < <(git log -E --grep="^\\[doc-superpowers\\] sync PR-${PR_NUMBER} release notes" \
           --format='%H%x1f%s' HEAD "^$BASE_TIP")

# emit_commits <out-file> <revision args…>: the PR's own commits, oldest first.
emit_commits() {
  local out="$1"
  shift
  git log --reverse --no-merges --full-history --format='%H%x1f%s%x1f%b%x1e' "$@" \
    -- ':/' ':(top,exclude)RELEASE-NOTES.next/' \
    | jq -Rs '
        split("\u001e")
        | map(ltrimstr("\n"))
        | map(select(length > 0 and contains("\u001f")))
        | map(split("\u001f"))
        | map({sha: .[0], subject: .[1], body: ((.[2] // "") | rtrimstr("\n"))})
        | map(select(.subject | startswith("[doc-superpowers]") | not))
      ' > "$out"
}

emit_commits "$T/new.json" HEAD "^$NEW_SINCE" "^$BASE_TIP"
emit_commits "$T/full.json" HEAD "^$BASE_TIP"

jq -n \
  --argjson pr_number "$PR_NUMBER" \
  --arg head_ref "$HEAD_REF" \
  --arg base_ref "$BASE_REF" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --slurpfile pr "$T/pr.json" \
  --rawfile fragment "$FRAGMENT_FILE" \
  --argjson has_fragment "$HAS_FRAGMENT" \
  --argjson corrupt "$CORRUPT" \
  --argjson hash_valid "$HASH_VALID" \
  --argjson no_notes "$NO_NOTES" \
  --arg fragment_path "$FRAGMENT_PATH" \
  --arg new_since "$NEW_SINCE" \
  --slurpfile new_commits "$T/new.json" \
  --slurpfile full_commits "$T/full.json" \
  '{
    pr_number: $pr_number,
    head_ref: $head_ref,
    base_ref: $base_ref,
    head_sha: $head_sha,
    base_sha: $base_sha,
    pr_body: ($pr[0].body // ""),
    existing_fragment: (if $has_fragment then $fragment else null end),
    existing_fragment_corrupt: $corrupt,
    existing_fragment_hash_valid: $hash_valid,
    existing_fragment_no_notes: $no_notes,
    fragment_path: $fragment_path,
    new_since: $new_since,
    new_commits: $new_commits[0],
    full_commits: $full_commits[0]
  }'

#!/usr/bin/env bash
# doc-pr-release.yml's commit step, after the agent (never run by it): seal
# this PR's fragment, commit it — only that path — and push it to the PR
# branch only while the branch is still at the checkout.
#
#   1. The fragment as the agent wrote it: line 1 must be this PR's marker
#      and notes must follow. Line 2 may be a hash marker (with any value, or
#      none) or be left out: this step writes the hash itself, the sha256 of
#      the bytes from line 3 on (RELEASE-NOTES.next/README.md).
#   2. The same notes as HEAD's fragment (byte for byte, from the line after
#      the markers): nothing to commit, and the file is left alone — so a
#      fragment a human edited is never re-sealed.
#   3. HEAD's fragment edited by hand (its hash no longer matches, or its
#      markers are broken) while the agent changed it: refused, exit 1. The
#      workflow never overwrites a human's edit; the agent posts a comment.
#   4. Compare-and-swap. The branch at origin is no longer the checkout:
#      commit-changes.sh's moved() decides (sourced — one implementation):
#      someone else pushed → superseded, exit 0, nothing committed or pushed
#      (their push starts a newer run, which drafts from the new tip); moved
#      only by doc-superpowers commits, or reset / force-pushed behind the
#      checkout → exit 1. What someone else did to the branch always stands.
#   5. Commit only the fragment (`git commit -- <fragment>`: anything else
#      staged stays staged), as "[doc-superpowers] sync PR-<N> release notes
#      (<short checkout>)" with the trailer "Doc-Superpowers-Drafted-From:
#      <checkout>", which extract-context.sh reads as its watermark.
#   6. Push with --force-with-lease=refs/heads/<branch>:<checkout>: it lands
#      only while origin's branch is exactly the checkout, and what lands is
#      the checkout plus this one commit — a fast-forward, never a rewrite. A
#      rejected push goes back to step 4's rule.
#
# Args:
#   $1  PR number
#
# Env:
#   GITHUB_HEAD_REF  the PR branch (required once there is a fragment)
#   GITHUB_OUTPUT    step outputs (default: none): committed=true|false,
#                    sha=<commit> when pushed, superseded=true
#   FRAGMENT_PATH    default RELEASE-NOTES.next/PR-<N>.md
#   GIT_USER_NAME    commit author name  (default: github-actions[bot])
#   GIT_USER_EMAIL   commit author email (default: 41898282+github-actions[bot]@users.noreply.github.com)
#
# Exit codes:
#   0  committed and pushed; nothing to commit (no fragment, or unchanged);
#      superseded; or the branch is gone
#   1  refused (a malformed fragment, a hand-edited one, the branch moved in
#      a way that is not someone else's push) or git failed
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
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
MARKER="<!-- doc-superpowers:fragment PR-${PR_NUMBER} -->"
FRAGMENT_MAX_BYTES=1048576

lib="$(dirname "$0")/../doc-superpowers-steps/commit-changes.sh"
if [ ! -f "$lib" ]; then
  echo "::error::doc-superpowers: $lib is missing (re-run the doc-superpowers installer: install --ci)"
  exit 1
fi
# err, out, g, remote_tip, moved.
# shellcheck source=scripts/hooks/ci/doc-superpowers-steps/commit-changes.sh
. "$lib"

if [ ! -e "$FRAGMENT_PATH" ] && [ ! -L "$FRAGMENT_PATH" ]; then
  echo "No fragment at $FRAGMENT_PATH — nothing to commit."
  out committed false
  exit 0
fi

BRANCH="${GITHUB_HEAD_REF:-}"
if [ -z "$BRANCH" ]; then
  echo "GITHUB_HEAD_REF is unset; refusing to guess the push target." >&2
  echo "Set GITHUB_HEAD_REF to the PR branch name (the workflow does this automatically for pull_request events)." >&2
  exit 1
fi
PUSH_TO="$BRANCH"

[ ! -L "$FRAGMENT_PATH" ] || err "$FRAGMENT_PATH is a symbolic link; it is never read or committed. Nothing was committed or pushed."
[ -f "$FRAGMENT_PATH" ] || err "$FRAGMENT_PATH is not a regular file. Nothing was committed or pushed."
bytes=$(wc -c < "$FRAGMENT_PATH" | tr -d ' ')
[ "$bytes" -le "$FRAGMENT_MAX_BYTES" ] \
  || err "$FRAGMENT_PATH is $bytes bytes (over $FRAGMENT_MAX_BYTES). Nothing was committed or pushed."

head=$(g rev-parse --verify HEAD 2>/dev/null) || err "no checkout here (git rev-parse HEAD failed)"

T=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-fragment.XXXXXX") || err "cannot create a temporary directory"
trap 'rm -rf "$T"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    err "neither sha256sum nor shasum is installed"
  fi
}

# A marker line as written, less a trailing CR and blanks.
trimmed() {
  local l="${1%$'\r'}"
  while :; do
    case "$l" in
      *[' '$'\t']) l="${l%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$l"
}

# split <file> <body-out>: set L1 / L2 (trimmed) and write the notes — the
# bytes after line 2 when line 2 is a hash marker, else after line 1.
split_fragment() {
  local l1="" l2=""
  { IFS= read -r l1 || true; IFS= read -r l2 || true; } < "$1"
  L1=$(trimmed "$l1")
  L2=$(trimmed "$l2")
  case "$L2" in
    '<!-- doc-superpowers:hash'*'-->') tail -n +3 "$1" > "$2" ;;
    *) tail -n +2 "$1" > "$2" ;;
  esac
}

split_fragment "$FRAGMENT_PATH" "$T/body"
[ "$L1" = "$MARKER" ] \
  || err "line 1 of $FRAGMENT_PATH must be $MARKER (it is '$L1'). Nothing was committed or pushed."
grep -q '[^[:space:]]' "$T/body" \
  || err "$FRAGMENT_PATH holds no notes under its markers (a PR with nothing to announce says <!-- doc-superpowers:no-notes -->). Nothing was committed or pushed."

if g cat-file -e "HEAD:$FRAGMENT_PATH" 2>/dev/null; then
  g cat-file blob "HEAD:$FRAGMENT_PATH" > "$T/head.md" || err "cannot read $FRAGMENT_PATH at HEAD"
  split_fragment "$T/head.md" "$T/head.body"
  if cmp -s "$T/body" "$T/head.body"; then
    echo "Fragment unchanged — no commit."
    out committed false
    exit 0
  fi
  stored="" re='^<!-- doc-superpowers:hash ([0-9a-f]+) -->$'
  if [[ $L2 =~ $re ]]; then
    stored="${BASH_REMATCH[1]}"
  fi
  actual=$(tail -n +3 "$T/head.md" | sha256) || err "cannot hash $FRAGMENT_PATH at HEAD"
  if [ "$L1" != "$MARKER" ] || [ -z "$stored" ] || [ "$stored" != "${actual%% *}" ]; then
    err "$FRAGMENT_PATH at HEAD was edited by hand (its line-2 hash does not match its notes, or its markers are broken); the workflow never overwrites it. Nothing was committed or pushed — reconcile it by hand, then re-seal it (RELEASE-NOTES.next/README.md)."
  fi
fi

# Compare-and-swap, before anything is written.
tip=$(remote_tip) || err "cannot ask origin for $PUSH_TO (git ls-remote failed). Nothing was committed or pushed."
if [ -z "$tip" ]; then
  out committed false
  echo "::notice::doc-superpowers: $PUSH_TO no longer exists at origin (deleted since the checkout); it is not recreated. Nothing was committed or pushed."
  exit 0
elif [ "$tip" != "$head" ]; then
  moved "Nothing was committed or pushed."
fi

hash=$(sha256 < "$T/body") || err "cannot hash $FRAGMENT_PATH"
{
  printf '%s\n' "$MARKER"
  printf '<!-- doc-superpowers:hash %s -->\n' "${hash%% *}"
  cat "$T/body"
} > "$T/sealed" || err "cannot write the sealed fragment"
cat "$T/sealed" > "$FRAGMENT_PATH" || err "cannot write $FRAGMENT_PATH"

g --literal-pathspecs add -- "$FRAGMENT_PATH" || err "git add $FRAGMENT_PATH failed"
g --literal-pathspecs -c "user.name=${GIT_USER_NAME}" -c "user.email=${GIT_USER_EMAIL}" \
  commit -q -m "[doc-superpowers] sync PR-${PR_NUMBER} release notes (${head:0:7})" \
  -m "Doc-Superpowers-Drafted-From: $head" -- "$FRAGMENT_PATH" || err "git commit failed"
sha=$(g rev-parse HEAD)

if ! g push --force-with-lease="refs/heads/$PUSH_TO:$head" origin "HEAD:refs/heads/$PUSH_TO"; then
  tip=$(remote_tip) || err "the push to $PUSH_TO failed and origin cannot be asked why (git ls-remote failed). Nothing was pushed."
  if [ -z "$tip" ]; then
    out committed false
    echo "::notice::doc-superpowers: $PUSH_TO was deleted at origin during this run; it is not recreated. Nothing was pushed."
    exit 0
  elif [ "$tip" != "$head" ]; then
    moved "Nothing was pushed."
  fi
  err "the push to $PUSH_TO failed while the branch was still at the checkout (see git's message above). Nothing was forced."
fi
out committed true
out sha "$sha"
echo "Committed and pushed $sha (PR-${PR_NUMBER} release notes) to $PUSH_TO."

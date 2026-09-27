#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code Stop hook
# DO NOT EDIT — managed by doc-superpowers hooks installer
#
# Stop fires every time Claude finishes a response, not when the session ends
# (SessionEnd output reaches no one, so the reminder stays here). The hook is
# therefore scoped to what is in progress: the paths changed in the working
# tree (tracked, against HEAD, and untracked), judged as the working tree holds
# them. A clean tree costs two git calls and prints nothing. Docs this turn
# left stale are named in ONE JSON object on stdout (systemMessage, shown to
# the user); the hook always exits 0 and never blocks the stop.
# It only reports: it never runs update-index, which would record docs as
# verified that nobody read.
# The check gets BUDGET seconds; past that it is killed (with everything it
# started) and a one-line note says so. The skill or the doc-index being absent
# is silent; the check failing (jq missing, a corrupt index) is said in one
# line. DOC_SUPERPOWERS_QUIET=1 silences it; DOC_SUPERPOWERS_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# The Stop event on stdin is not needed; read it so the writer never blocks.
IFS= read -r -d '' _ || true

BUDGET=2

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
DOC_TOOLS="${DOC_TOOLS:-$(printf '%s\n' __DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1)}"
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f docs/.doc-index.json ]] || exit 0

[[ "${DOC_SUPERPOWERS_QUIET:-}" == "1" ]] && exit 0

# What changed in the working tree: both sides of a rename, and untracked
# files (not ignored). Nothing yet committed (no HEAD): nothing to compare.
changed=$({
  git -c core.quotePath=false diff --name-only --no-renames HEAD \
    && git -c core.quotePath=false ls-files --others --exclude-standard
} 2>/dev/null) || exit 0
[[ -z "$changed" ]] && exit 0

have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0

# _emit <systemMessage>
_emit() {
  if [[ "$have_jq" == 1 ]]; then
    jq -cn --arg m "$1" '{systemMessage: $m}'
  else
    # Only this hook's own fixed text (no quote or backslash) comes here.
    printf '{"systemMessage":"%s"}\n' "$1"
  fi
}

# The check could not run: one line, on stderr and (as Claude Code shows an
# exit-0 hook's stderr to no one) as a systemMessage.
_fail() {
  local line="doc-superpowers: cannot check the docs your changes affect: $1 — check skipped"
  echo "$line" >&2
  _emit "$line"
  exit 0
}

[[ "$have_jq" == 1 ]] || _fail "jq not found on PATH"

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-stop.XXXXXX") || _fail "mktemp failed"
trap 'rm -rf "$work"' EXIT

# The working tree as a tree object: git's index copied to a private one
# (git's own is never touched), every change staged into it with add -A. Like
# git stash, this writes objects for new content; nothing references them.
_check() {
  local idx="$work/index" real tree
  real=$(git rev-parse --git-path index) || return 1
  if [[ -f "$real" ]]; then
    cp "$real" "$idx" || return 1
  fi
  GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1 || { echo "ERROR: cannot stage the working tree into a private index" >&2; return 1; }
  tree=$(GIT_INDEX_FILE="$idx" git write-tree) || return 1
  printf '%s\n' "$changed" | "$DOC_TOOLS" check-freshness --tree "$tree" --code-refs-from -
}

# Run _check in its own process group with a watchdog that kills the whole
# group after BUDGET seconds. Neither job keeps this hook's stdout open.
# Returns _check's status, or 124 when the watchdog fired.
_bounded() {
  local pid wd rc=0
  set -m
  _check >"$work/out" 2>"$work/err" </dev/null &
  pid=$!
  ( sleep "$BUDGET"; kill -TERM -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  wd=$!
  set +m
  wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$wd" 2>/dev/null; then
    kill -TERM -- "-$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
  elif [[ "$rc" -gt 128 ]]; then
    rc=124
  fi
  return "$rc"
}

rc=0
_bounded || rc=$?
if [[ "$rc" == 124 ]]; then
  _emit "doc-superpowers: doc freshness summary skipped — the check took longer than ${BUDGET}s (run 'doc-tools.sh check-freshness' to see it)."
  exit 0
fi
if [[ "$rc" != 0 ]]; then
  why=$(awk 'NF { print; exit }' "$work/err")
  why="${why#ERROR: }"
  why="${why%.}"
  _fail "${why:-doc-tools.sh check-freshness failed}"
fi

summary=$(jq -r '
  [.docs | to_entries[] | select(.value.status == "stale") | .key] as $s
  | [.docs | to_entries[] | select(.value.status == "missing") | .key] as $m
  | [if ($s | length) > 0 then "\($s | length) doc(s) cite code changed in the working tree and are not re-verified: \($s | join(", "))" else empty end,
     if ($m | length) > 0 then "\($m | length) indexed doc(s) missing from disk: \($m | join(", "))" else empty end]
  | if length > 0 then "doc-superpowers: " + join("; ") + ". Update them (/doc-superpowers update) and re-verify each one you reviewed (doc-tools.sh update-index <doc>)." else "" end
' "$work/out" 2>/dev/null) || _fail "cannot read the freshness report"

[[ -z "$summary" ]] && exit 0
_emit "$summary"
exit 0

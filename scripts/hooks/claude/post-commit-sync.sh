#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code PostToolUse (Bash)
# DO NOT EDIT — managed by doc-superpowers hooks installer
#
# Input: the PostToolUse event as JSON on stdin; the Bash command is
# .tool_input.command. After a `git commit`, reports the docs the commit left
# stale as ONE JSON object on stdout (hookSpecificOutput.additionalContext for
# Claude, systemMessage for the user); always exits 0, the commit is made.
# It only reports: it never runs update-index, which would record docs as
# verified that nobody read.
# The skill or the doc-index being absent is silent; the check failing (jq
# missing, a corrupt index) is said in one line.
# DOC_SUPERPOWERS_QUIET=1 silences it; DOC_SUPERPOWERS_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Most Bash calls are not commits: decide that before starting any process.
IFS= read -r -d '' input || true
case "$input" in
  *commit*) ;;
  *) exit 0 ;;
esac

# `git [-C <dir> | -c <key=value>]… commit`, as a POSIX ERE.
re_commit='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'

have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0
if [[ "$have_jq" == 1 ]]; then
  command_str=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
else
  # Without jq the event cannot be parsed, but its raw text still holds the
  # command.
  command_str="$input"
fi
[[ $command_str =~ $re_commit ]] || exit 0

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
DOC_TOOLS="${DOC_TOOLS:-$(printf '%s\n' __DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1)}"
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f docs/.doc-index.json ]] || exit 0

[[ "${DOC_SUPERPOWERS_QUIET:-}" == "1" ]] && exit 0

# _emit <systemMessage> <additionalContext> — either may be empty.
_emit() {
  if [[ "$have_jq" == 1 ]]; then
    jq -cn --arg m "$1" --arg c "$2" '
      (if $m != "" then {systemMessage: $m} else {} end)
      + (if $c != "" then {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}} else {} end)'
  else
    # Only this hook's own fixed text (no quote or backslash) comes here.
    printf '{"systemMessage":"%s"}\n' "$1"
  fi
}

# The check could not run: one line, on stderr and (as Claude Code shows an
# exit-0 hook's stderr to no one) as a systemMessage.
_fail() {
  local line="doc-superpowers: cannot check the docs this commit affects: $1 — check skipped"
  echo "$line" >&2
  _emit "$line" ""
  exit 0
}

[[ "$have_jq" == 1 ]] || _fail "jq not found on PATH"

# The files the commit changed, both sides of a rename. A root commit has no
# HEAD~1: diff-tree --root compares it with the empty tree.
committed=$(git -c core.quotePath=false diff --name-only --no-renames HEAD~1 HEAD 2>/dev/null) \
  || committed=$(git -c core.quotePath=false diff-tree --root -r --no-commit-id --name-only --no-renames HEAD 2>/dev/null) \
  || exit 0
[[ -z "$committed" ]] && exit 0

_check() { printf '%s\n' "$committed" | "$DOC_TOOLS" check-freshness --code-refs-from -; }
if ! result=$(_check 2>/dev/null); then
  why=$(_check 2>&1 >/dev/null | awk 'NF { print; exit }')
  why="${why#ERROR: }"
  why="${why%.}"
  _fail "${why:-doc-tools.sh check-freshness failed}"
fi

# Line 1: "<stale> <missing>"; line 2: the one-line summary; then the report.
report=$(jq -r --arg move "  Run 'doc-tools.sh move-entry <old> <new>' if it was renamed, or 'remove-entry'/'deprecate-entry' to clean up." '
  [.docs | to_entries[] | select(.value.status == "stale")] as $s
  | [.docs | to_entries[] | select(.value.status == "missing")] as $m
  | "\($s | length) \($m | length)",
    ([if ($s | length) > 0 then "this commit left \($s | length) doc(s) stale: \([$s[].key] | join(", "))" else empty end,
      if ($m | length) > 0 then "\($m | length) indexed doc(s) missing from disk: \([$m[].key] | join(", "))" else empty end]
     | "doc-superpowers: " + join("; ")),
    (if ($s | length) > 0 then
       "doc-superpowers: \($s | length) doc(s) affected by this commit are stale (their code changed since they were verified)",
       ($s[] | "  \(.key) — \(.value.reason // "stale")"
         + (if ((.value.code_refs_changed // []) | length) > 0 then ": \(.value.code_refs_changed | join(", "))" else "" end))
     else empty end),
    (if ($m | length) > 0 then
       "doc-superpowers: \($m | length) indexed doc(s) missing from disk",
       ($m[] | "  \(.key)"),
       $move
     else empty end)
' <<<"$result" 2>/dev/null) || _fail "cannot read the freshness report"

counts=${report%%$'\n'*}
[[ "$counts" == "0 0" ]] && exit 0
report=${report#*$'\n'}
summary=${report%%$'\n'*}
report=${report#*$'\n'}

_emit "$summary" "$report
  Run '/doc-superpowers update' to refresh stale documentation, then re-verify each doc you reviewed (doc-tools.sh update-index <doc>)."
exit 0

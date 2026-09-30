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
# Every list is capped and every string held under Claude Code's 10,000-char
# hook-output limit (hook-lib.sh, sourced from beside this script). The check
# gets BUDGET seconds, under the 10 s the installer registers; past that it is
# killed (with everything it started) and a one-line note says so.
# The skill or the doc-index being absent is silent; the check failing (jq
# missing, a corrupt index) is said in one line.
# DOC_SUPERPOWERS_QUIET=1 silences it; DOC_SUPERPOWERS_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# The event carries the command's whole output (tool_response), so read it
# with cat, not bash's byte-at-a-time `read` (about 0.5 s per MB). A terminal
# on stdin (a hand run) is not waited on. Most Bash calls are not commits:
# decide that before anything else runs.
if [ -t 0 ]; then
  input=""
else
  input=$(cat)
fi
case "$input" in
  *commit*) ;;
  *) exit 0 ;;
esac

# `git [-C <dir> | -c <key=value>]… commit` where the shell would run it, as
# a POSIX ERE (bash =~): at the start, or after a newline, ; & | ( { ` $( or
# then/do/else, past VAR=value assignments and a /path/to/ prefix. So
# `echo git commit`, `grep "git commit -m" .` and `legit commit` are not
# commits. Kept byte-identical in pre-commit-gate.sh and post-commit-sync.sh
# (test-hooks.sh pins it); `;` stays last in the bracket (a bash-4 guard
# pattern matches the two bytes semicolon-ampersand).
re_commit='(^|[&|({`'$'\n'';]|\$\(|(then|do|else)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]&|;]*/)?git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'

have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0
if [[ "$have_jq" == 1 ]]; then
  command_str=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
else
  # Without jq the event cannot be parsed, but its raw text still holds the
  # command: take everything after "command":", with \n escapes unfolded.
  command_str=""
  re_field='"command"[[:space:]]*:[[:space:]]*"(.*)'
  if [[ $input =~ $re_field ]]; then
    command_str="${BASH_REMATCH[1]}"
    command_str="${command_str//\\n/$'\n'}"
  fi
fi
[[ $command_str =~ $re_commit ]] || exit 0

HOOK_EVENT=PostToolUse
BUDGET=7
# The shared library beside this script, as an absolute path: the cd below
# would break a relative one.
case "${BASH_SOURCE[0]}" in
  /*) _lib="${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  */*) _lib="$PWD/${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  *) _lib="$PWD/hook-lib.sh" ;;
esac

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
[[ -n "${DOC_TOOLS:-}" ]] || DOC_TOOLS=$(__DOC_TOOLS_RESOLVE__)
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f docs/.doc-index.json ]] || exit 0

[[ "${DOC_SUPERPOWERS_QUIET:-}" == "1" ]] && exit 0

# Without the library nothing can be reported but that.
# shellcheck source=scripts/hooks/claude/hook-lib.sh
if ! . "$_lib" 2>/dev/null; then
  printf '%s\n' '{"systemMessage":"doc-superpowers: hook-lib.sh is missing beside the post-commit-sync hook, so it cannot report; re-run install.sh install --claude"}'
  exit 0
fi

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

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-sync.XXXXXX") || _fail "mktemp failed"
trap 'rm -rf "$work"' EXIT

# shellcheck disable=SC2329  # run by _bounded
_check() { printf '%s\n' "$committed" | "$DOC_TOOLS" check-freshness --code-refs-from -; }
rc=0
_bounded _check || rc=$?
if [[ "$rc" == 124 ]]; then
  line=$(_budget_line)
  echo "$line" >&2
  _emit "$line" ""
  exit 0
fi
if [[ "$rc" != 0 ]]; then
  why=$(_why)
  _fail "${why:-doc-tools.sh check-freshness failed}"
fi

# Line 1: "<stale> <missing>"; line 2: the one-line summary; then the report.
# Every list is capped (hook-lib.sh: dsp_list, dsp_lines, dsp_refs).
# shellcheck disable=SC2016  # jq program, not shell expansion
report=$(_report_jq '
  [.docs | to_entries[] | select(.value.status == "stale")] as $s
  | [.docs | to_entries[] | select(.value.status == "missing")] as $m
  | "\($s | length) \($m | length)",
    ([if ($s | length) > 0 then "this commit left \($s | length) doc(s) stale: \([$s[].key] | dsp_list | join(", "))" else empty end,
      if ($m | length) > 0 then "\($m | length) indexed doc(s) missing from disk: \([$m[].key] | dsp_list | join(", "))" else empty end]
     | "doc-superpowers: " + join("; ")),
    (if ($s | length) > 0 then
       "doc-superpowers: \($s | length) doc(s) affected by this commit are stale (their code changed since they were verified)",
       ($s | dsp_lines("  \(.key) — \(.value.reason // "stale")" + dsp_refs))
     else empty end),
    (if ($m | length) > 0 then
       "doc-superpowers: \($m | length) indexed doc(s) missing from disk",
       ($m | dsp_lines("  \(.key)")),
       $move
     else empty end)
' -r --arg move "  Run 'doc-tools.sh move-entry <old> <new>' if it was renamed, or 'remove-entry'/'deprecate-entry' to clean up." \
  < "$work/out" 2>/dev/null) || _fail "cannot read the freshness report"

# Split with read, not ${report%%…}: bash's pattern removal is quadratic on
# a long string.
{ IFS= read -r counts; IFS= read -r summary; report=$(cat); } <<<"$report"
[[ "$counts" == "0 0" ]] && exit 0

_emit "$summary" "$report
  Run '/doc-superpowers update' to refresh stale documentation, then re-verify each doc you reviewed (doc-tools.sh update-index <doc>)."
exit 0

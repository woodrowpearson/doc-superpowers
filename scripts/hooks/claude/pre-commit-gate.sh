#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code PreToolUse (Bash)
# DO NOT EDIT — managed by doc-superpowers hooks installer
#
# Input: the PreToolUse event as JSON on stdin; the Bash command is
# .tool_input.command. Output, only for a `git commit` that leaves a doc stale:
#   - ONE JSON object on stdout and exit 0: hookSpecificOutput.additionalContext
#     is read by Claude, systemMessage is shown to the user;
#   - DOC_SUPERPOWERS_STRICT=1: exit 2 with the reason on stderr, which Claude
#     Code hands to Claude and the commit does not run.
# The check runs on the staged tree, the commit's content, scoped to the staged
# paths plus every entry the staged doc-index adds; an indexed doc the commit
# leaves out is "not in this commit" when it is on disk (git add it), "missing
# from disk" when it is gone. A command that stages as it commits (`git add … && git commit`, `commit -a`, a pathspec) has
# no such tree yet: the gate defers to the git pre-commit hook, which runs on
# the real one, and says so.
# Every list is capped and every string held under Claude Code's 10,000-char
# hook-output limit (hook-lib.sh, sourced from beside this script). The check
# gets BUDGET seconds, under the 10 s the installer registers (a hook that runs
# past it is killed and gates nothing): past that it is killed (with everything
# it started) and says so — "check skipped (budget)", or a block under STRICT.
# The skill or the doc-index being absent is silent. The check failing (jq
# missing, a corrupt index, the budget) is said, and blocks only under STRICT.
# DOC_SUPERPOWERS_QUIET=1 silences the advisory output, never a block's
# reason or the exit code; DOC_SUPERPOWERS_SKIP=1 turns the hook off.

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Most Bash calls are not commits: decide that before starting any process.
IFS= read -r -d '' input || true
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
# Something in the command that changes what is staged before the commit
# snapshots it: another index-changing git command, or update-index…
re_stages='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+(add|rm|mv|stage|apply|restore|reset|checkout|switch|stash|merge|pull|cherry-pick|revert|rebase|am|read-tree|update-index)([[:space:]]|$)|(^|[^[:alnum:]_-])update-index([[:space:]]|$)'
# …or the commit's own staging options (-a/--all, -i, -o, -p, a -- pathspec).
re_commit_stages='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit[[:space:]]([^&|;]*[[:space:]])?(-[a-zA-Z]*[aiop][a-zA-Z]*|--all|--include|--only|--interactive|--patch|--)([[:space:]]|=|$)'

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

HOOK_EVENT=PreToolUse
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

_quiet() { [[ "${DOC_SUPERPOWERS_QUIET:-}" == "1" ]]; }
_strict() { [[ "${DOC_SUPERPOWERS_STRICT:-}" == "1" ]]; }

# Without the library the check cannot run: said, and a block under STRICT.
# shellcheck source=scripts/hooks/claude/hook-lib.sh
if ! . "$_lib" 2>/dev/null; then
  _m="doc-superpowers: hook-lib.sh is missing beside the pre-commit-gate hook, so it cannot check this commit; re-run install.sh install --claude"
  if _strict; then
    echo "$_m — blocked by DOC_SUPERPOWERS_STRICT=1 (DOC_SUPERPOWERS_SKIP=1 bypasses)" >&2
    exit 2
  fi
  _quiet && exit 0
  printf '{"systemMessage":"%s"}\n' "$_m"
  exit 0
fi
# The full list is the staged tree's.
HOOK_FULL_LIST="run 'doc-tools.sh check-freshness --tree \$(git write-tree)' for the full list"

# The check could not run. Claude Code shows an exit-0 hook's stderr to no one,
# so the line also goes out as a systemMessage. STRICT blocks, and a block's
# stderr is Claude's only feedback, so QUIET never silences it.
_fail() {
  local line="doc-superpowers: cannot check doc freshness before this commit: $1"
  if _strict; then
    echo "$line — blocked by DOC_SUPERPOWERS_STRICT=1 (DOC_SUPERPOWERS_SKIP=1 bypasses)" >&2
    exit 2
  fi
  _quiet && exit 0
  echo "$line — check skipped" >&2
  _emit "$line — check skipped" ""
  exit 0
}

[[ "$have_jq" == 1 ]] || _fail "jq not found on PATH"

if [[ $command_str =~ $re_stages || $command_str =~ $re_commit_stages ]]; then
  _quiet && exit 0
  note="doc-superpowers: this command stages changes as it commits (git add … && git commit, commit -a, a pathspec), so the tree it will commit does not exist yet and this gate cannot judge it."
  # The git pre-commit checks this commit only when git runs it (executable,
  # where --git-path puts it) and it is the doc-superpowers hook, or holds the
  # current integration block (the pre-3.0 one dropped the exit code) with
  # the local copy it runs. A mere mention of doc-superpowers is not a check.
  hk="$(git rev-parse --git-path hooks 2>/dev/null)/pre-commit"
  if [[ -x "$hk" ]] && { head -5 "$hk" 2>/dev/null | grep -q 'doc-superpowers hook v[0-9]' \
    || { grep -qxF 'if [ -f "$DOC_SP_HOOK" ]; then bash "$DOC_SP_HOOK" "$@" || exit $?; fi' "$hk" \
      && [[ -f "${hk%/*}/.doc-superpowers-pre-commit" ]]; }; }; then
    _emit "" "$note The doc-superpowers git pre-commit hook checks the staged tree when git runs it."
  else
    note="$note And no doc-superpowers git pre-commit hook is installed, so nothing checks this commit's docs (install the git tier: /doc-superpowers hooks install --git)."
    if _strict; then
      _emit "doc-superpowers: DOC_SUPERPOWERS_STRICT=1 cannot hold for this commit: it stages as it commits, and no doc-superpowers git pre-commit hook is installed." "$note"
    else
      _emit "" "$note"
    fi
  fi
  exit 0
fi

staged=$(git -c core.quotePath=false diff --cached --name-only --no-renames 2>/dev/null) \
  || _fail "git diff --cached failed"
[[ -z "$staged" ]] && exit 0
# The staged tree, written from a private copy of git's index: outside a git
# command, `git write-tree` would rewrite git's own (its cache-tree). A split
# index cannot be copied alone; then git's own index is used.
work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-gate.XXXXXX") || _fail "mktemp failed"
trap 'rm -rf "$work"' EXIT
idx="$work/index"
cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || _fail "cannot copy git's index"
tree=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) \
  || tree=$(git write-tree 2>/dev/null) \
  || _fail "git write-tree failed"

# The whole check, run under the watchdog (hook-lib.sh: _bounded): the report
# on stdout, a failure's reason on stderr.
# shellcheck disable=SC2329  # run by _bounded
_check() {
  local result added wide
  # Each run's stderr is passed on only when that run fails, so the reason
  # _why reads is the failing run's.
  result=$(printf '%s\n' "$staged" | "$DOC_TOOLS" check-freshness --tree "$tree" --code-refs-from - 2>"$work/err.scoped") \
    || { cat "$work/err.scoped" >&2; return 1; }
  # The scope reaches a doc through its code refs only, so the entries the
  # staged index adds (its keys minus HEAD's) are judged unscoped, and their
  # verdicts join the scoped ones — the git pre-commit hook's rule.
  if grep -qxF docs/.doc-index.json <<<"$staged"; then
    added=$( { git cat-file blob "$tree:docs/.doc-index.json" \
      && { git cat-file blob HEAD:docs/.doc-index.json 2>/dev/null || echo '{}'; }; } 2>/dev/null \
      | jq -cs '((.[0].docs // {}) | keys) - ((.[1].docs // {}) | keys)' 2>/dev/null) || added='[]'
    if [[ -n "$added" && "$added" != "[]" ]]; then
      wide=$("$DOC_TOOLS" check-freshness --tree "$tree" 2>"$work/err.wide") \
        || { cat "$work/err.wide" >&2; return 1; }
      result=$(printf '%s\n%s\n%s\n' "$added" "$result" "$wide" | jq -cs '
        (reduce .[0][] as $k ({}; .[$k] = true)) as $a
        | .[2].docs as $w
        | .[1] | .docs += ($w | with_entries(select($a[.key])))' 2>/dev/null) \
        || { echo "ERROR: cannot read the freshness report" >&2; return 1; }
    fi
  fi
  printf '%s\n' "$result"
}
rc=0
_bounded _check || rc=$?
if [[ "$rc" == 124 ]]; then
  # Under STRICT a check that cannot finish blocks, as one that cannot run.
  _strict && _fail "the check took longer than its ${BUDGET}s budget"
  _quiet && exit 0
  line=$(_budget_line)
  echo "$line" >&2
  _emit "$line" "$line"
  exit 0
fi
if [[ "$rc" != 0 ]]; then
  why=$(_why)
  _fail "${why:-doc-tools.sh check-freshness failed}"
fi
result=$(cat "$work/out")

# The docs the commit leaves out: on disk (unstaged) or gone. (A JSON list on
# stdin, never argv: it can be index-sized.)
ondisk=""
while IFS= read -r doc; do
  [[ -n "$doc" && -e "$doc" ]] && ondisk+="$doc"$'\n'
done < <(jq -r '.docs | to_entries[] | select(.value.status == "missing") | .key' <<<"$result" 2>/dev/null)
ondisk=$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$ondisk" 2>/dev/null) || _fail "cannot read the freshness report"

# Line 1: "<stale> <unstaged> <gone>"; line 2: the one-line summary; then the report.
# Every list is capped (hook-lib.sh: dsp_list, dsp_lines, dsp_refs).
# shellcheck disable=SC2016  # jq program, not shell expansion
report=$(printf '%s\n%s\n' "$result" "$ondisk" | _report_jq '
  (reduce .[1][] as $k ({}; .[$k] = true)) as $d
  | .[0]
  | [.docs | to_entries[] | select(.value.status == "stale")] as $s
  | [.docs | to_entries[] | select(.value.status == "missing" and $d[.key])] as $u
  | [.docs | to_entries[] | select(.value.status == "missing" and ($d[.key] | not))] as $m
  | "\($s | length) \($u | length) \($m | length)",
    ([if ($s | length) > 0 then "\($s | length) stale doc(s) in this commit: \([$s[].key] | dsp_list | join(", "))" else empty end,
      if ($u | length) > 0 then "\($u | length) indexed doc(s) not in this commit: \([$u[].key] | dsp_list | join(", "))" else empty end,
      if ($m | length) > 0 then "\($m | length) indexed doc(s) missing from disk: \([$m[].key] | dsp_list | join(", "))" else empty end]
     | "doc-superpowers: " + join("; ")),
    (if ($s | length) > 0 then
       "doc-superpowers: \($s | length) stale doc(s) in this commit (their code changed since they were verified)",
       ($s | dsp_lines("  \(.key) — \(.value.reason // "stale")" + dsp_refs
         + (if ((.value.commits_behind // 0) > 0) then " (\(.value.commits_behind) commits behind)" else "" end)))
     else empty end),
    (if ($u | length) > 0 then
       "doc-superpowers: \($u | length) indexed doc(s) not in this commit (on disk, but not staged)",
       ($u | dsp_lines("  \(.key)")),
       $add
     else empty end),
    (if ($m | length) > 0 then
       "doc-superpowers: \($m | length) indexed doc(s) missing from disk",
       ($m | dsp_lines("  \(.key)")),
       $move
     else empty end)
' -rs --arg move "  Run 'doc-tools.sh move-entry <old> <new>' if it was renamed, or 'remove-entry'/'deprecate-entry' to clean up." \
  --arg add "  The index this commit records lists them: stage each with 'git add <doc>'." 2>/dev/null) || _fail "cannot read the freshness report"

# Split with read, not ${report%%…}: bash's pattern removal is quadratic on
# a long string.
{ IFS= read -r counts; IFS= read -r summary; report=$(cat); } <<<"$report"
[[ "$counts" == "0 0 0" ]] && exit 0

# A block's stderr is Claude's feedback: QUIET silences the advisory only.
# The report is held under the limit with room for that last line.
if _strict; then
  _clip "$report" $((HOOK_MAX_CHARS - 400)) >&2
  echo "  Commit blocked by DOC_SUPERPOWERS_STRICT=1: update the docs ('/doc-superpowers update') and re-verify them (doc-tools.sh update-index <doc>), or set DOC_SUPERPOWERS_SKIP=1 to bypass." >&2
  exit 2
fi
_quiet && exit 0
_emit "$summary" "$report
  Consider running '/doc-superpowers update' before committing."
exit 0

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
# The check runs on the staged tree, the commit's content. A command that
# stages as it commits (`git add … && git commit`, `commit -a`, a pathspec) has
# no such tree yet: the gate defers to the git pre-commit hook, which runs on
# the real one, and says so.
# The skill or the doc-index being absent is silent. The check failing (jq
# missing, a corrupt index) is said, and blocks only under STRICT.
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

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
DOC_TOOLS="${DOC_TOOLS:-$(printf '%s\n' __DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1)}"
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f docs/.doc-index.json ]] || exit 0

_quiet() { [[ "${DOC_SUPERPOWERS_QUIET:-}" == "1" ]]; }
_strict() { [[ "${DOC_SUPERPOWERS_STRICT:-}" == "1" ]]; }

# _emit <systemMessage> <additionalContext> — either may be empty.
_emit() {
  if [[ "$have_jq" == 1 ]]; then
    jq -cn --arg m "$1" --arg c "$2" '
      (if $m != "" then {systemMessage: $m} else {} end)
      + (if $c != "" then {hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}} else {} end)'
  else
    # Only this hook's own fixed text (no quote or backslash) comes here.
    printf '{"systemMessage":"%s"}\n' "$1"
  fi
}

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
  if grep -q 'doc-superpowers' "$(git rev-parse --git-path hooks 2>/dev/null)/pre-commit" 2>/dev/null; then
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
idx=$(mktemp "${TMPDIR:-/tmp}/doc-sp-gate.XXXXXX") || _fail "mktemp failed"
trap 'rm -f "$idx"' EXIT
cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || _fail "cannot copy git's index"
tree=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) \
  || tree=$(git write-tree 2>/dev/null) \
  || _fail "git write-tree failed"

_check() { printf '%s\n' "$staged" | "$DOC_TOOLS" check-freshness --tree "$tree" --code-refs-from -; }
if ! result=$(_check 2>/dev/null); then
  why=$(_check 2>&1 >/dev/null | awk '/^ERROR: / { print; e = 1; exit } NF && !/^NOTE: / && o == "" { o = $0 } END { if (!e) print o }')
  why="${why#ERROR: }"
  why="${why%.}"
  _fail "${why:-doc-tools.sh check-freshness failed}"
fi

# Line 1: "<stale> <missing>"; line 2: the one-line summary; then the report.
report=$(jq -r --arg move "  Run 'doc-tools.sh move-entry <old> <new>' if it was renamed, or 'remove-entry'/'deprecate-entry' to clean up." '
  [.docs | to_entries[] | select(.value.status == "stale")] as $s
  | [.docs | to_entries[] | select(.value.status == "missing")] as $m
  | "\($s | length) \($m | length)",
    ([if ($s | length) > 0 then "\($s | length) stale doc(s) in this commit: \([$s[].key] | join(", "))" else empty end,
      if ($m | length) > 0 then "\($m | length) indexed doc(s) missing from disk: \([$m[].key] | join(", "))" else empty end]
     | "doc-superpowers: " + join("; ")),
    (if ($s | length) > 0 then
       "doc-superpowers: \($s | length) stale doc(s) in this commit (their code changed since they were verified)",
       ($s[] | "  \(.key) — \(.value.reason // "stale")"
         + (if ((.value.code_refs_changed // []) | length) > 0 then ": \(.value.code_refs_changed | join(", "))" else "" end)
         + (if ((.value.commits_behind // 0) > 0) then " (\(.value.commits_behind) commits behind)" else "" end))
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

# A block's stderr is Claude's feedback: QUIET silences the advisory only.
if _strict; then
  printf '%s\n' "$report" >&2
  echo "  Commit blocked by DOC_SUPERPOWERS_STRICT=1: update the docs ('/doc-superpowers update') and re-verify them (doc-tools.sh update-index <doc>), or set DOC_SUPERPOWERS_SKIP=1 to bypass." >&2
  exit 2
fi
_quiet && exit 0
_emit "$summary" "$report
  Consider running '/doc-superpowers update' before committing."
exit 0

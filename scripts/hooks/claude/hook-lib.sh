# shellcheck shell=bash disable=SC2016,SC2154  # jq programs; HOOK_EVENT, have_jq, BUDGET and work are the sourcing hook's
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — shared by the Claude Code hooks
# DO NOT EDIT — managed by doc-superpowers hooks installer
#
# (The install date is on line 2, as in the hooks: install.sh status compares
# every line but that one.)
# Sourced, never run, by pre-commit-gate.sh, post-commit-sync.sh,
# session-summary.sh and the work ledger's ledger-session-notices.sh, which
# set HOOK_EVENT, have_jq and (for _bounded) BUDGET and work first. One copy,
# so they cannot drift apart. (ledger-state-watch.sh does not source it.)
# The "shared hook settings" region at its end (_hook_conf, _advice,
# _hook_budget, _bounded, _why) is also carried, byte for byte, by every git
# hook, which must run without this library (the git tier ships alone).
#
# Claude Code keeps each hook string (systemMessage, additionalContext, the
# stderr of a blocking exit 2) inline only up to 10,000 characters; past that
# the model gets a 2,000-character preview of a saved file
# (https://code.claude.com/docs/en/hooks). Every report is therefore bounded
# twice:
#   - its lists (_report_jq's dsp_list, dsp_lines, dsp_refs): the first
#     HOOK_LIST_MAX paths of a one-line summary, HOOK_LINES_MAX lines of a
#     report section, HOOK_REFS_MAX changed refs per doc, each list also held
#     to HOOK_SECTION_CHARS, then "…and M more" with the pointer to the full
#     list — so every section keeps its count line whatever the stale count;
#   - each string, whatever builds it (_emit, _clip): HOOK_MAX_CHARS, cut at
#     a line end, then the pointer. A backstop: the list caps keep a report
#     well under it.

HOOK_MAX_CHARS=9000
HOOK_SECTION_CHARS=2500
HOOK_LIST_MAX=10
HOOK_LINES_MAX=15
HOOK_REFS_MAX=3
HOOK_FULL_LIST="run 'doc-tools.sh check-freshness' for the full list"

# jq definitions every report and string bound uses (with _report_jq's args).
HOOK_JQ_DEFS='
  def dsp_more($n): "…and \($n) more (" + $full + ")";
  # The longest prefix of at most $n entries whose lengths, plus a 2-char
  # separator each, fit in $section chars.
  def dsp_take($n):
    reduce .[0:$n][] as $x ({k: [], c: 0, full: false};
      if .full or .c + ($x | length) + 2 > $section then .full = true
      else .k += [$x] | .c += ($x | length) + 2 end)
    | .k;
  # A list of paths for a one-line summary: that prefix, then "…and M more".
  def dsp_list: length as $all | dsp_take($short) | . + (if $all > length then [dsp_more($all - length)] else [] end);
  # A report section: f turns each entry into its line; that prefix, then
  # "  …and M more".
  def dsp_lines(f): length as $all | [.[] | f] | dsp_take($long)
    | .[], (if $all > length then "  " + dsp_more($all - length) else empty end);
  # A stale doc entry'\''s changed refs, as ": a, b, c, …and M more" ("" if none).
  def dsp_refs: (.value.code_refs_changed // [])
    | if length == 0 then ""
      else length as $all | ": " + (.[0:$refs] | join(", "))
        + (if $all > $refs then ", …and \($all - $refs) more" else "" end) end;
  # A string held to $n chars: cut at the last line end that fits (or
  # mid-line when there is none), then a line saying so, with the pointer.
  # (split, not rindex: jq 1.6 rindex counts bytes, slicing codepoints.)
  def dsp_clip_to($n):
    if length <= $n then .
    else ("…cut to stay under Claude Code'\''s hook-output limit; " + $full) as $tail
      | .[0:($n - ($tail | length) - 1)] as $head
      | ($head | split("\n")) as $l
      | (if ($l | length) > 1 then $l[0:-1] | join("\n") else $head end) + "\n" + $tail
    end;
  def dsp_clip: dsp_clip_to($max);
'

# _report_jq <program> [jq options…]: jq on stdin with the definitions above.
_report_jq() {
  local prog="$1"
  shift
  jq --arg full "$HOOK_FULL_LIST" --argjson max "$HOOK_MAX_CHARS" \
    --argjson section "$HOOK_SECTION_CHARS" --argjson short "$HOOK_LIST_MAX" \
    --argjson long "$HOOK_LINES_MAX" --argjson refs "$HOOK_REFS_MAX" "$@" "$HOOK_JQ_DEFS$prog"
}

# _clip <text> [max]: <text> held to [max] (default HOOK_MAX_CHARS) chars.
_clip() {
  _report_jq '$t | dsp_clip_to($n)' -rn --arg t "$1" --argjson n "${2:-$HOOK_MAX_CHARS}"
}

# _emit <systemMessage> [additionalContext] — either may be empty; each is
# held to HOOK_MAX_CHARS. The context goes out as HOOK_EVENT's
# hookSpecificOutput.
_emit() {
  if [[ "$have_jq" == 1 ]]; then
    _report_jq '
      (if $m != "" then {systemMessage: ($m | dsp_clip)} else {} end)
      + (if $c != "" then {hookSpecificOutput: {hookEventName: $e, additionalContext: ($c | dsp_clip)}} else {} end)' \
      -cn --arg m "$1" --arg c "${2:-}" --arg e "$HOOK_EVENT"
  else
    # Only the hooks' own fixed text (no quote or backslash) comes here.
    printf '{"systemMessage":"%s"}\n' "$1"
  fi
}

# The line a hook emits when its check ran out of time.
_budget_line() {
  printf '%s' "doc-superpowers: check skipped (budget): the doc freshness check took longer than ${BUDGET}s (run 'doc-tools.sh check-freshness' to see it)"
}

# >>> shared hook settings: one text in every git hook and in hook-lib.sh (test-hooks.sh pins the copies) >>>
# _hook_conf <key>: <key>'s value in .claude/doc-superpowers/hooks.conf (a
# "key = value" file: # comments, the last line for a key wins), "" when
# unset. Read by awk, never sourced; relative to the repository top, where
# every hook runs. No file, no process.
_hook_conf() {
  [ -f .claude/doc-superpowers/hooks.conf ] || return 0
  awk -v k="$1" '
    /^[ \t]*#/ { next }
    { i = index($0, "="); if (i == 0) next
      key = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t\r]+$/, "", key)
      if (key != k) next
      v = substr($0, i + 1); gsub(/^[ \t]+|[ \t\r]+$/, "", v); val = v; seen = 1 }
    END { if (seen) print val }' .claude/doc-superpowers/hooks.conf 2>/dev/null
}

# _advice <action>: the command the hooks' advice names for <action>:
# '/doc-superpowers <action>' by default; "" when DOC_SUPERPOWERS_ADVICE
# (else hooks.conf's advice key) is off; any other value is a template, its
# every {action} replaced by <action> (on or default: the default).
_advice() {
  local t="${DOC_SUPERPOWERS_ADVICE:-}"
  [ -n "$t" ] || t=$(_hook_conf advice)
  t="${t//[$'\n\r']/ }"
  case "$t" in
    "" | on | default) printf '/doc-superpowers %s' "$1" ;;
    off) ;;
    *) printf '%s' "${t//\{action\}/$1}" ;;
  esac
}

# _hook_budget: the git hooks' freshness-check budget in seconds:
# DOC_SUPERPOWERS_HOOK_BUDGET, else hooks.conf's hook_budget, else 20; 0 is
# no budget, and a value that is not digits reads as the default. Past a day
# (86400) — more than six digits once leading zeros are dropped, or a value
# sleep cannot take — it reads as 0, no budget: never a watchdog that fires
# at once.
_hook_budget() {
  local b="${DOC_SUPERPOWERS_HOOK_BUDGET:-}"
  [ -n "$b" ] || b=$(_hook_conf hook_budget)
  case "$b" in
    "" | *[!0-9]*) b=20 ;;
  esac
  b="${b#"${b%%[!0]*}"}"
  if [ -z "$b" ] || [ "${#b}" -gt 6 ] || [ "$b" -gt 86400 ]; then
    b=0
  fi
  printf '%s' "$b"
}

# _bounded <function>: run <function> in its own process group, its stdout to
# $work/out and stderr to $work/err, with a watchdog that, after BUDGET
# seconds, first leaves a marker and then kills the whole group. Neither job
# keeps the hook's stdout open. The watchdog is always killed and reaped
# before the verdict: whether it fired is read from the marker, never from
# whether it is still alive (it can be alive between its kill and its exit).
# A watchdog whose sleep fails never fires. Returns <function>'s status, or
# 124 when it was cut short. BUDGET 0: no watchdog. The hook interrupted
# (INT, TERM, HUP) while the check runs kills both groups (the check's own
# group is out of reach of the terminal's ^C), then dies of that signal
# (128+n).
_bounded() {
  local pid="" wd="" rc=0
  if [ "${BUDGET:-0}" = 0 ]; then
    "$1" >"$work/out" 2>"$work/err" </dev/null || rc=$?
    return "$rc"
  fi
  trap '_bounded_stop HUP 1' HUP
  trap '_bounded_stop INT 2' INT
  trap '_bounded_stop TERM 15' TERM
  set -m
  "$1" >"$work/out" 2>"$work/err" </dev/null &
  pid=$!
  ( sleep "$BUDGET" && { : > "$work/timedout"; kill -TERM -- "-$pid" 2>/dev/null; } ) >/dev/null 2>&1 </dev/null &
  wd=$!
  set +m
  wait "$pid" 2>/dev/null || rc=$?
  trap - HUP INT TERM
  kill -TERM -- "-$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  # A check that finished cleanly is used even if the watchdog fired after it.
  if [[ "$rc" != 0 && -e "$work/timedout" ]]; then
    rc=124
  fi
  return "$rc"
}

# _bounded_stop <signal> <number>: _bounded's handler: kill the check's and
# the watchdog's groups (_bounded's pid and wd), then re-raise the signal
# (the EXIT trap still runs), exiting 128+<number> should it return.
# shellcheck disable=SC2329  # run by _bounded's traps
_bounded_stop() {
  trap - HUP INT TERM
  [ -z "${pid:-}" ] || kill -TERM -- "-$pid" 2>/dev/null
  [ -z "${wd:-}" ] || kill -TERM -- "-$wd" 2>/dev/null
  kill -s "$1" "$$"
  exit $((128 + $2))
}

# Why a check failed: the first ERROR: line of $work/err, else its first
# other non-NOTE line, without the ERROR: prefix or a final period.
_why() {
  local why
  why=$(awk '/^ERROR: / { print; e = 1; exit } NF && !/^NOTE: / && o == "" { o = $0 } END { if (!e) print o }' "$work/err")
  why="${why#ERROR: }"
  printf '%s' "${why%.}"
}
# <<< shared hook settings <<<

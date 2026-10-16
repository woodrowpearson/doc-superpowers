# shellcheck shell=bash
# scripts/ledger/hooks.sh — the hook modes of the ledger verbs (Task 16c
# U4): `ledger notices --hook` (Claude Code SessionStart) and `ledger
# state-watch --hook` (PostToolUse, Write|Edit), stable entry points beside
# doc-tools.sh that a host can register in its committed
# .claude/settings.json; the installed hooks
# (scripts/hooks/claude/ledger-session-notices.sh, ledger-state-watch.sh)
# are thin wrappers over them. Sourced by lib.sh; uses lib.sh's _lg_init,
# _lg_usage, _lg_out, _lg_mark_emitted and doc-tools.sh's _exit_ok.
#
# A hook mode prints one hook object — {"systemMessage", "hookSpecificOutput":
# {"hookEventName", "additionalContext"}}, each string held to 9,000
# characters as hook-lib.sh's _emit holds it — or nothing, and always exits
# 0 (doc-tools.sh: _lg_prescan sets _LG_HOOK; _on_exit then ends the run 0
# whatever happened, a usage error, a run outside a repository and the
# inert check included, and those print nothing on stdout). The event on
# stdin (nothing is read from a terminal) must be empty or one JSON object:
# anything else ends the run silently.

_LG_HOOK_MAX_CHARS=9000   # hook-lib.sh HOOK_MAX_CHARS
_LG_HOOK_LINES_MAX=15     # hook-lib.sh HOOK_LINES_MAX
_LG_HOOK_FULL_DEFAULT="run 'doc-tools.sh check-freshness' for the full list"
_LG_HOOK_PAYLOAD=""

# hook-lib.sh's dsp_clip_to and _emit's object, verbatim in effect ($full:
# the pointer a cut string ends with; $max: the bound).
# shellcheck disable=SC2016  # jq source
_LG_JQ_HOOK_DEFS='
def dsp_clip_to($n):
  if length <= $n then .
  else ("…cut to stay under Claude Code'"'"'s hook-output limit; " + $full) as $tail
    | .[0:($n - ($tail | length) - 1)] as $head
    | ($head | split("\n")) as $l
    | (if ($l | length) > 1 then $l[0:-1] | join("\n") else $head end) + "\n" + $tail
  end;
def lg_hook_obj($m; $c; $e):
  (if $m != "" then {systemMessage: ($m | dsp_clip_to($max))} else {} end)
  + (if $c != "" then {hookSpecificOutput: {hookEventName: $e, additionalContext: ($c | dsp_clip_to($max))}} else {} end);
'

# _lg_hook_done: end a hook-mode run, its output (if any) printed: exit 0.
_lg_hook_done() {
  _lg_mark_emitted 0
  _exit_ok
}

# _lg_hook_payload → _LG_HOOK_PAYLOAD: the event on stdin, in a scratch
# file (a terminal is not read); empty or a JSON object, else the run ends
# silently.
_lg_hook_payload() {
  _LG_HOOK_PAYLOAD="$_SCRATCH/lg-hook-event.json"
  if [ -t 0 ]; then
    : > "$_LG_HOOK_PAYLOAD" || _lg_hook_done
  else
    cat > "$_LG_HOOK_PAYLOAD" 2>/dev/null || _lg_hook_done
  fi
  if [ -s "$_LG_HOOK_PAYLOAD" ] && ! jq -e 'type == "object"' "$_LG_HOOK_PAYLOAD" > /dev/null 2>&1; then
    _lg_hook_done
  fi
}

# _lg_hook_emit <event> <systemMessage> <additionalContext> [pointer]: the
# hook object on the run's stdout (either string may be empty; both empty:
# nothing).
_lg_hook_emit() {
  local o
  [ -n "$2" ] || [ -n "$3" ] || return 0
  o=$(jq -cn --arg e "$1" --arg m "$2" --arg c "$3" --arg full "${4:-$_LG_HOOK_FULL_DEFAULT}" \
    --argjson max "$_LG_HOOK_MAX_CHARS" "$_LG_JQ_HOOK_DEFS"'lg_hook_obj($m; $c; $e)') || return 0
  _lg_out "$o"
}

# --- ledger notices --hook ---------------------------------------------------------

_LG_NOTICES_FULL="run 'doc-tools.sh ledger notices' for the full list"

# _lg_notices_hook_fail <message>: _LG_HOOK_FAIL's handler (doc-tools.sh
# _lg_fail) once the notices are being computed — the one line the
# SessionStart hook has always given for a check that failed.
_lg_notices_hook_fail() {
  local m="$1"
  _lg_hook_emit SessionStart "ledger: cannot list the in-flight notices: ${m%.} (run doc-tools.sh ledger notices)" ""
}

# _lg_notices_hook_out <notice-lines>: the SessionStart object for the
# notices that ask for action — stop, then heads-up (info is left to
# `ledger notices`): a count line, then at most _LG_HOOK_LINES_MAX - 1
# lines (past that, the first _LG_HOOK_LINES_MAX - 2 and "…and M more"
# with the pointer to the full list), as systemMessage and
# additionalContext. None: nothing.
_lg_notices_hook_out() {
  local o
  # shellcheck disable=SC2016  # jq source
  o=$(jq -R -n -c --arg full "$_LG_NOTICES_FULL" --argjson max "$_LG_HOOK_MAX_CHARS" \
      --argjson lines "$_LG_HOOK_LINES_MAX" "$_LG_JQ_HOOK_DEFS"'
    [inputs] as $L
    | [$L[] | select(startswith("stop "))] as $S
    | [$L[] | select(startswith("heads-up "))] as $H
    | ($S | length) as $ns | ($H | length) as $nh | ($ns + $nh) as $n
    | if $n == 0 then empty
      else ($lines - 1) as $k
        | (if $n > $k then $k - 1 else $k end) as $keep
        | ((($S + $H)[0:$keep] | join("\n"))
           + (if $n > $keep then "\n  …and \($n - $keep) more (\($full))" else "" end)) as $body
        | ("ledger: \($n) in-flight notice(s) on this branch (\($ns) stop, \($nh) heads-up): act on each before the next chunk, or ack one with a commit trailer '"'"'Ledger-Ack: <id> — <clause>'"'"'\n" + $body
           | dsp_clip_to($max)) as $msg
        | lg_hook_obj($msg; $msg; "SessionStart")
      end' < "$1") || return 0
  [ -z "$o" ] || _lg_out "$o"
}

# --- ledger state-watch --hook -----------------------------------------------------

# The PostToolUse (Write|Edit) state-watch program (Task 16 R2's, moved
# here from ledger-state-watch.sh): the event on stdin; --arg home ($HOME,
# "" when unset), top (git's top level), proj ($CLAUDE_PROJECT_DIR), and
# their canonical spellings phome, ptop, pproj (no symbolic link left in
# them; "" when one does not resolve) and pfile (the written file's, from
# its deepest existing directory); --slurpfile cfg (docs/ledger/config.json
# as the host wrote it); --rawfile reg (the registry, "" without one). The
# file matches an entry when either spelling of it lies under either
# spelling of the entry: a symbolic link on one side only (macOS's /var →
# /private/var, a symlinked checkout or $HOME) does not hide it. Prints the
# advisory line or nothing.
# shellcheck disable=SC2016  # jq source
_LG_JQ_STATE_WATCH='
  # An entry as a regex: "*" is any run within a segment, all else literal.
  def glob_re: gsub("(?<c>[.+?()\\[\\]{}^$|\\\\])"; "\\\(.c)") | gsub("\\*"; "[^/]*");
  # An entry'"'"'s absolute spellings ("" and "/" name nothing, nor does "~/…"
  # with HOME empty or unset: it would read as a path from the root).
  def spellings($home; $top; $proj):
    sub("/+$"; "") as $e
    | if $e == "" then empty
      elif ($e | startswith("~/")) then (if $home == "" then empty else $home + ($e | .[1:]) end)
      elif ($e | startswith("/")) then $e
      else ([$top, $proj] | map(select(. != "")) | unique | .[]) + "/" + $e
      end;
  ($cfg[0] // {}) as $c
  | (($c | if type == "object" then .state_watch else null end) // {}) as $sw0
  | (if ($sw0 | type) == "object" then $sw0 else {} end) as $sw
  | ((.tool_input // {}) | if type == "object" then . else {} end) as $in
  | ($in.file_path // "") as $raw
  | select(($raw | type) == "string" and $raw != "")
  | (if ($raw | startswith("/")) then $raw else ((.cwd // $top) + "/" + $raw) end) as $p
  | ([$p, $pfile] | map(select(. != "")) | unique) as $ps
  | [($sw.paths // [])[]? | strings | (spellings($home; $top; $proj), spellings($phome; $ptop; $pproj))]
  | unique | map(glob_re) as $res
  | select(any($res[]; . as $r | any($ps[]; test("^" + $r + "(/|$)"))))
  | ([$in.content, $in.new_string, (($in.edits // []) | .[]? | .new_string?)] | map(strings) | join("\n")) as $text
  | ($text | ascii_downcase) as $lc
  | select(any(($sw.patterns // [])[]? | strings | select(. != "") | ascii_downcase; . as $pt | $lc | contains($pt)))
  | (if $reg == "" then null else (try ($reg | fromjson | [.ledgers[]? | .id? | strings]) catch null) end) as $ids0
  | (if $ids0 == null then null else $ids0 + [($c.legacy_ids // [])[]? | strings] end) as $ids
  | [$text | scan("(?<![a-z0-9-])[a-z0-9-]{1,16}-[1-9][0-9]*(?![a-z0-9-])")
     | select($ids == null or (sub("-[1-9][0-9]*$"; "") as $l | $ids | index([$l]) != null))]
  | reduce .[] as $k ([]; if index([$k]) != null then . else . + [$k] end)
  | select(length > 0)
  | "ledger: this write to \($raw) records state for \(.[0:5] | join(", "))\(if length > 5 then ", …" else "" end): keep it in the ledger, its one home — doc-tools.sh ledger note \(.[0]) \"…\" (--kind ruling for a ruling)"'

# _lg_phys_dir <dir>: <dir> with no symbolic link left in it (cd -P); ""
# when it is empty or does not resolve.
_lg_phys_dir() {
  [ -n "$1" ] || return 0
  (cd -P -- "$1" 2>/dev/null && pwd -P) || true
}

# _lg_phys_path <absolute path>: the path with its deepest existing
# directory canonical (_lg_phys_dir), the rest — what does not exist yet,
# and the file's own name — appended as given.
_lg_phys_path() {
  local d="${1%/*}" rest="/${1##*/}" r
  while [ -n "$d" ]; do
    if [ -d "$d" ]; then
      r=$(_lg_phys_dir "$d")
      if [ -n "$r" ]; then
        [ "$r" != / ] || r=""
        printf '%s%s' "$r" "$rest"
        return 0
      fi
    fi
    rest="/${d##*/}$rest"
    d=${d%/*}
  done
  printf '%s' "$rest"
}

# ledger state-watch --hook: `ledger note` is the one home for an item's
# state. When Claude writes a file under one of config state_watch.paths
# (the host's agent-memory and scratch directories) and what it wrote —
# Write's content, Edit's new_string, MultiEdit's edits — names an item key
# (<ledger>-<n>, the ledger one the registry or config legacy_ids holds; any
# key-shaped word without a registry) and holds one of state_watch.patterns
# (any case), one PostToolUse object (additionalContext, for Claude)
# suggests `doc-tools.sh ledger note <key> "…"` instead. A paths entry:
# a leading "~/" is $HOME (HOME empty or unset: the entry names nothing), an
# absolute one is itself, any other is under the top level or
# $CLAUDE_PROJECT_DIR; "*" matches within one segment and every other
# character — a space, a "~" anywhere else, "?", "[" — is itself; an entry
# matches the file and anything below it. Paths compare canonically: the
# directories that exist are resolved (cd -P), so a symbolic link in either
# spelling does not hide a match; no glob is ever expanded against the disk
# and nothing is word-split. Advisory only: anything it cannot read prints
# nothing.
# shellcheck disable=SC2154  # _ARGS, _OPT_* are set by _parse_args
cmd_ledger_state_watch() {
  local reg line="" f pfile="" ptop phome pproj
  _lg_init state-watch
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  [ -n "${_OPT_hook:-}" ] || _lg_usage "state-watch is the PostToolUse hook: give --hook (the event on stdin)"
  _lg_hook_payload
  [ -s "$_LG_HOOK_PAYLOAD" ] || _lg_hook_done
  reg=docs/ledger/ledgers.json
  [ -f "$reg" ] || reg=/dev/null
  # The written file's path as the program reads it, and every spelling
  # canonical (the program compares both sides both ways).
  # shellcheck disable=SC2016  # jq source
  f=$(jq -r --arg top "$PWD" '((.tool_input // {}) | if type == "object" then .file_path else null end) as $raw
    | select(($raw | type) == "string" and $raw != "")
    | if ($raw | startswith("/")) then $raw else ((.cwd // $top) + "/" + $raw) end' < "$_LG_HOOK_PAYLOAD" 2>/dev/null) || f=""
  case "$f" in
    /*) pfile=$(_lg_phys_path "$f") ;;
  esac
  ptop=$(_lg_phys_dir "$PWD")
  phome=$(_lg_phys_dir "${HOME:-}")
  pproj=$(_lg_phys_dir "${CLAUDE_PROJECT_DIR:-}")
  line=$(jq -r --arg home "${HOME:-}" --arg top "$PWD" --arg proj "${CLAUDE_PROJECT_DIR:-}" \
    --arg phome "$phome" --arg ptop "$ptop" --arg pproj "$pproj" --arg pfile "$pfile" \
    --slurpfile cfg docs/ledger/config.json --rawfile reg "$reg" "$_LG_JQ_STATE_WATCH" < "$_LG_HOOK_PAYLOAD" 2>/dev/null) || line=""
  [ -z "$line" ] || _lg_hook_emit PostToolUse "" "$line"
  _lg_hook_done
}

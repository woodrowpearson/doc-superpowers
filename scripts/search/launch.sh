#!/bin/sh
# doc-search launcher v3.10.0
# doc-search launcher (POSIX sh): runs the doc-search CLI / MCP server through
# uv, from wherever doc-superpowers is installed.
#
#   sh .claude/doc-superpowers/search-mcp.sh serve     (what .mcp.json runs)
#   sh .claude/doc-superpowers/search-mcp.sh check     (the readiness probe)
#   sh "$(git rev-parse --show-toplevel)/.claude/doc-superpowers/search-mcp.sh" \
#     gate session-start|prompt|tool                   (what the client hooks run)
#
# install.sh install --search copies this file to
# .claude/doc-superpowers/search-mcp.sh and registers it in .mcp.json. The copy
# holds no machine path: the doc-superpowers root is found at run time, in this
# order:
#   1. $DOC_SUPERPOWERS_ROOT, when it has search/pyproject.toml
#   2. the repository this is run in, when it is doc-superpowers itself
#      (search/pyproject.toml and scripts/doc-tools.sh)
#   3. ${CODEX_HOME:-$HOME/.codex}/doc-superpowers, the Codex install, when it
#      has search/pyproject.toml
#   4. the newest numeric X.Y.Z directory under
#      ${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}/*/doc-superpowers/
#      that has search/pyproject.toml
#
# Line 2 is the version stamp, the plugin's version: doc-tools.sh bump-version
# writes it and check-version checks it.
#
# Extras: --extra cloud when docs/search/config.json (at the repository top)
# has a non-null "cloud"; --extra local-transformer (after cloud) when its
# docs.model is a string starting "transformer:"; none otherwise. Without jq
# the config cannot be parsed: --all-extras --no-extra local-transformer
# (onnxruntime has no wheel for older macOS or glibc, so a static config must
# not need it), or --all-extras when grep finds a "model" key whose value
# starts "transformer:". --no-dev: the dev group (pytest) is never installed
# for a user.
#
# The per-user env hook: a POSIX sh file sourced before anything else, so the
# variables it sets reach doc-search and the launcher itself (SEMBLE_CACHE_LOCATION,
# DOC_SEARCH_CACHE_LOCATION, HF_HOME, PATH, DOC_SUPERPOWERS_ROOT, …). It is read
# at every launch, so it can decide them then: a cache on a volume that is not
# always mounted, say. An MCP client starts the server without the user's shell
# profile, so this is where such a choice reaches it. $DOC_SEARCH_ENV_FILE names
# the file (empty is unset), else ${XDG_CONFIG_HOME:-$HOME/.config}/doc-search/env.sh.
# A missing file is skipped; one that does not parse is skipped with one stderr
# line, so a broken hook never keeps doc-search from starting. Its output goes
# to stderr (stdout is the MCP stream). It runs in this shell: it should only
# set variables, and an `exit` in it ends the launcher.
#
# The client's working directory (serve only): an MCP client may start the
# server outside the worktree its session works in. The Claude desktop app, for
# one, starts project servers in the main checkout (--project-config-root)
# while the session runs in a worktree. The server makes the worktree holding
# $DOC_SEARCH_CLIENT_CWD its default, when it is one of this repository's
# (references/search.md -> worktree). The client is this process's parent
# ($PPID: true for `sh <launcher> serve`, and for an `sh -c` wrapper that
# `exec`s it; a wrapper that does not exec is the parent itself): its cwd from
# /proc, else lsof (-b: never block on a dead network mount). A value already
# set is kept; none found leaves it unset, and the default is then the launch
# worktree.
#
# check and gate (the readiness probe and the client hooks' entry) are answered
# here where doc-search cannot run, and exec it otherwise. In this order, after
# the env hook:
#   - gate with DOC_SEARCH_GATE=0 (blanks ignored): exit 0, no output;
#   - outside a git work tree: check prints "not in force: not a git work
#     tree" and exits 4; gate is silent;
#   - no root: check prints "not in force: doc-superpowers is not installed for
#     this developer" and exits 4; gate is silent (session-start and prompt
#     remove the verdict file);
#   - no uv, where the raw text of docs/search/config.json (at the repository
#     top) matches "required"\s*:\s*true, across lines, as doc-search's own
#     test does: check prints "not ready: uv not found" and exits 1; gate
#     session-start and prompt write the verdict file as doc-search gate does,
#     then prompt blocks the prompt and session-start adds the line as
#     context, in doc-search gate's words;
#   - no uv otherwise: check prints "not in force: uv not found" and exits 4;
#     gate session-start and prompt remove the verdict file and are silent.
# The verdict file, $(git rev-parse --git-path doc-search-gate), is kept by
# gate session-start and prompt (doc-search's, or this file's where it
# answers): two LF lines while not ready, line 1 not-ready and line 2
# "<reason>; fix: <fix>", written to a temp file beside it and moved over it;
# absent otherwise. gate tool never runs uv: it reads that file. Unless line 1
# is not-ready (one trailing CR ignored) it is silent. While it is, a Bash call
# whose whole command matches GATE_ALLOWED_PLAIN or GATE_ALLOWED_QUOTED (the
# fix commands) is allowed and every other tool call is denied, line 2 (one
# trailing CR dropped) in the reason. Without jq the call cannot be read, so
# every one is denied, with a fixed reason.
# check's answer goes to stdout, as doc-search's does: the line, or with
# --format json one object (see check_answer). gate prints one JSON object or
# nothing and exits 0 (3 for an unknown event). It never echoes the event,
# and it drains stdin it does not read, so the client's write never blocks.
#
# Other failures are one stderr line and exit 2.

fail() {
  echo "doc-search: $*" >&2
  exit 2
}

# drain: discard the hook event on stdin, unless stdin is a terminal.
drain() {
  [ -t 0 ] || cat >/dev/null
}

# gate_silent: drain, then exit 0 with no output (the client goes on).
gate_silent() {
  drain
  exit 0
}

# config_required: the raw config text says "required": true (it may not parse).
config_required() {
  if [ -z "$TOP" ] || [ ! -f "$TOP/docs/search/config.json" ]; then
    return 1
  fi
  # tr turns the ASCII whitespace (\t \n \v \f \r) into spaces, so " *" spans
  # lines as Python's \s does; the Unicode spaces \s also matches are not covered.
  tr '\t\n\v\f\r' '     ' 2>/dev/null <"$TOP/docs/search/config.json" | grep -Eq '"required" *: *true'
}

# gate_keep <line 2>: write the verdict file as not-ready, atomically (a temp
# file beside it, then mv over it). A failure leaves it as it was.
gate_keep() {
  VERDICT=$(git rev-parse --git-path doc-search-gate 2>/dev/null) || VERDICT=""
  [ -n "$VERDICT" ] || return 0
  if ! (printf 'not-ready\n%s\n' "$1" >"$VERDICT.tmp.$$" && mv -f "$VERDICT.tmp.$$" "$VERDICT") 2>/dev/null; then
    rm -f "$VERDICT.tmp.$$" 2>/dev/null
  fi
  return 0
}

# gate_forget: remove the verdict file (not in force); a missing one is fine.
gate_forget() {
  VERDICT=$(git rev-parse --git-path doc-search-gate 2>/dev/null) || VERDICT=""
  if [ -n "$VERDICT" ]; then rm -f "$VERDICT" 2>/dev/null; fi
  return 0
}

# gate_tool: the PreToolUse decision, from the verdict file and the event.
gate_tool() {
  VERDICT=$(git rev-parse --git-path doc-search-gate 2>/dev/null) || VERDICT=""
  if [ -z "$VERDICT" ] || [ ! -f "$VERDICT" ]; then
    gate_silent
  fi
  # Line 1, one trailing CR dropped: a CRLF file still denies (fail closed).
  LINE1=$(sed -n 1p "$VERDICT" 2>/dev/null) || LINE1=""
  LINE1=${LINE1%"$(printf '\r')"}
  if [ "$LINE1" != not-ready ]; then
    gate_silent
  fi
  if ! command -v jq >/dev/null 2>&1; then
    drain
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$GATE_NOT_READY, and this hook cannot read the tool call without jq. $GATE_STOP\"}}"
    exit 0
  fi
  if [ -t 0 ]; then EVENT=""; else EVENT=$(cat); fi
  # A newline anywhere is refused: jq's $ also matches before a final newline.
  if printf '%s' "$EVENT" | jq -e --arg plain "$GATE_ALLOWED_PLAIN" --arg quoted "$GATE_ALLOWED_QUOTED" '
    .tool_name == "Bash"
    and (.tool_input.command | type) == "string"
    and (.tool_input.command | test("[\n\r]") | not)
    and (.tool_input.command | test($plain) or test($quoted))' >/dev/null 2>&1; then
    exit 0
  fi
  REASON=$(sed -n 2p "$VERDICT" 2>/dev/null) || REASON=""
  REASON=${REASON%"$(printf '\r')"}
  if [ -n "$REASON" ]; then
    REASON="$GATE_NOT_READY: $REASON. $GATE_STOP"
  else
    REASON="$GATE_NOT_READY. $GATE_STOP"
  fi
  printf '%s' "$REASON" |
    jq -Rsc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: .}}' 2>/dev/null ||
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$GATE_NOT_READY. $GATE_STOP\"}}"
  exit 0
}

# check_answer <state> <exit> <reason> [fix]: check's answer, then exit
# <exit>. Text: "doc-search: <state, dashes as spaces>: <reason>". With
# --format json: {"state", "exit", "reason", "fix"} (fix null when none), the
# names doc-search's own verdict uses; without jq the fixed strings are
# printed as they are (none holds a quote or a backslash).
check_answer() {
  if [ "$FORMAT" = json ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg state "$1" --argjson exit "$2" --arg reason "$3" --arg fix "${4:-}" \
        '{state: $state, exit: $exit, reason: $reason, fix: (if $fix == "" then null else $fix end)}'
    else
      FIX_JSON=null
      if [ -n "${4:-}" ]; then FIX_JSON="\"$4\""; fi
      printf '{"state": "%s", "exit": %s, "reason": "%s", "fix": %s}\n' "$1" "$2" "$3" "$FIX_JSON"
    fi
  else
    echo "doc-search: $(printf '%s' "$1" | tr '-' ' '): $3"
  fi
  exit "$2"
}

# answer_check_gate <verb> [event] …: answer check or gate here where
# doc-search cannot run (see above); return to exec it otherwise.
answer_check_gate() {
  # Set here, after the env hook, so nothing it sets can change them.
  UV_MISSING="uv not found (https://docs.astral.sh/uv/)"
  GATE_NOT_READY="doc-search is required here and not ready"
  GATE_STOP="Stop and report this to the user; do not work around it."
  # doc-search gate's sentence where the fix is not one the agent may run.
  GATE_USER_ONLY="Only the user can run this fix; you may run only sh .claude/doc-superpowers/search-mcp.sh index, status or check."
  # The fix commands allowed while not ready, whole: the launcher path holds
  # only [A-Za-z0-9_./-], and spaces too when double-quoted, so no shell
  # syntax (substitution, redirection, a second command) can ride along. The
  # final $ is outside the quotes: this file's POSIX check refuses a dollar
  # sign right before a single quote (bash's ANSI-C quoting).
  GATE_ALLOWED_PLAIN='^sh ([A-Za-z0-9_./-]*/)?\.claude/doc-superpowers/search-mcp\.sh (index|status|check)( --format (text|json))?'\$
  GATE_ALLOWED_QUOTED='^sh "([A-Za-z0-9_. /-]*/)?\.claude/doc-superpowers/search-mcp\.sh" (index|status|check)( --format (text|json))?'\$
  VERB=$1
  EVENT_NAME=""
  FORMAT=text
  if [ "$VERB" = check ]; then
    # check's --format, as argparse reads it (the last one wins).
    PREV=""
    for ARG in "$@"; do
      if [ "$PREV" = --format ]; then FORMAT=$ARG; fi
      case $ARG in
        --format=*) FORMAT=${ARG#--format=} ;;
      esac
      PREV=$ARG
    done
  fi
  if [ "$VERB" = gate ]; then
    EVENT_NAME=${2:-}
    case $EVENT_NAME in
      session-start | prompt | tool) ;;
      *)
        drain
        echo "doc-search: usage: gate session-start|prompt|tool" >&2
        exit 3
        ;;
    esac
    if [ "$(printf '%s' "${DOC_SEARCH_GATE:-}" | tr -d '[:space:]')" = 0 ]; then
      gate_silent
    fi
  fi
  if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    if [ "$VERB" = gate ]; then gate_silent; fi
    check_answer not-in-force 4 "not a git work tree"
  fi
  if [ -z "$ROOT" ]; then
    if [ "$VERB" = gate ]; then
      if [ "$EVENT_NAME" != tool ]; then gate_forget; fi
      gate_silent
    fi
    check_answer not-in-force 4 "doc-superpowers is not installed for this developer"
  fi
  if [ "$EVENT_NAME" = tool ]; then
    gate_tool
  fi
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  if config_required; then
    case $EVENT_NAME in
      session-start)
        drain
        gate_keep "$UV_MISSING; fix: install uv"
        printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"$GATE_NOT_READY: $UV_MISSING. Fix: install uv. $GATE_USER_ONLY Do no work until it is ready: tell the user this line and stop.\"}}"
        exit 0
        ;;
      prompt)
        drain
        gate_keep "$UV_MISSING; fix: install uv"
        printf '%s\n' "{\"decision\":\"block\",\"reason\":\"$GATE_NOT_READY: $UV_MISSING. Fix: install uv — then send your message again. (Set DOC_SEARCH_GATE=0 to turn the gate off for yourself.)\"}"
        exit 0
        ;;
    esac
    check_answer not-ready 1 "$UV_MISSING" "install uv"
  fi
  if [ "$VERB" = gate ]; then
    gate_forget
    gate_silent
  fi
  check_answer not-in-force 4 "$UV_MISSING"
}

ENV_HOOK=${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/doc-search/env.sh}
case $ENV_HOOK in
  */*) ;;
  *) ENV_HOOK=./$ENV_HOOK ;; # `.` searches PATH for a bare name
esac
if [ -f "$ENV_HOOK" ] && [ -r "$ENV_HOOK" ]; then
  if sh -n "$ENV_HOOK" 2>/dev/null; then
    # shellcheck disable=SC1090  # the per-user hook; its path is known only at run time
    . "$ENV_HOOK" >&2
  else
    echo "doc-search: ignoring the env hook $ENV_HOOK (it does not parse)" >&2
  fi
fi

if [ "${1:-}" = serve ] && [ -z "${DOC_SEARCH_CLIENT_CWD:-}" ]; then
  CLIENT_CWD=$(readlink "/proc/$PPID/cwd" 2>/dev/null) || CLIENT_CWD=""
  if [ -z "$CLIENT_CWD" ]; then
    LSOF=$(command -v lsof 2>/dev/null) || LSOF=/usr/sbin/lsof
    if [ -x "$LSOF" ]; then
      CLIENT_CWD=$("$LSOF" -b -w -a -p "$PPID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
    fi
  fi
  if [ -n "$CLIENT_CWD" ]; then
    DOC_SEARCH_CLIENT_CWD=$CLIENT_CWD
    export DOC_SEARCH_CLIENT_CWD
  fi
fi

# The repository top (empty outside a repository): where the config lives.
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""

ROOT=""
if [ -n "${DOC_SUPERPOWERS_ROOT:-}" ] && [ -f "$DOC_SUPERPOWERS_ROOT/search/pyproject.toml" ]; then
  ROOT=$DOC_SUPERPOWERS_ROOT
fi

if [ -z "$ROOT" ] && [ -n "$TOP" ] && [ -f "$TOP/search/pyproject.toml" ] && [ -f "$TOP/scripts/doc-tools.sh" ]; then
  ROOT=$TOP
fi

if [ -z "$ROOT" ]; then
  CODEX=${CODEX_HOME:-$HOME/.codex}/doc-superpowers
  if [ -f "$CODEX/search/pyproject.toml" ]; then
    ROOT=$CODEX
  fi
fi

if [ -z "$ROOT" ]; then
  CACHE=${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}
  # One "<version> <dir>" line per candidate, across every marketplace.
  CANDIDATES=""
  for dir in "$CACHE"/*/doc-superpowers/*; do
    [ -f "$dir/search/pyproject.toml" ] || continue
    version=${dir##*/}
    printf '%s\n' "$version" | grep -Ex "[0-9]+[.][0-9]+[.][0-9]+" >/dev/null 2>&1 || continue
    CANDIDATES="$CANDIDATES$version $dir
"
  done
  if [ -n "$CANDIDATES" ]; then
    ROOT=$(printf '%s' "$CANDIDATES" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f2-)
  fi
fi

case ${1:-} in
  check | gate) answer_check_gate "$@" ;;
esac

[ -n "$ROOT" ] || fail "cannot find doc-superpowers (set DOC_SUPERPOWERS_ROOT)"
command -v uv >/dev/null 2>&1 || fail "uv not found (https://docs.astral.sh/uv/)"

EXTRAS=""
if command -v jq >/dev/null 2>&1; then
  if jq -e '.cloud != null' "${TOP:-.}/docs/search/config.json" >/dev/null 2>&1; then
    EXTRAS="--extra cloud"
  fi
  if jq -e '(.docs.model | type) == "string" and (.docs.model | startswith("transformer:"))' "${TOP:-.}/docs/search/config.json" >/dev/null 2>&1; then
    EXTRAS="${EXTRAS:+$EXTRAS }--extra local-transformer"
  fi
elif grep -Eq '"model"[^",]*:[^",]*"transformer:' "${TOP:-.}/docs/search/config.json" 2>/dev/null; then
  EXTRAS="--all-extras"
else
  EXTRAS="--all-extras --no-extra local-transformer"
fi

# shellcheck disable=SC2086  # $EXTRAS is a fixed flag list: empty, up to two --extra pairs, or --all-extras [--no-extra local-transformer]
exec uv run --project "$ROOT/search" --frozen --no-dev $EXTRAS doc-search "$@"

#!/bin/sh
# doc-search launcher v3.9.0
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
#     this developer" and exits 4; gate is silent;
#   - no uv, where the raw text of docs/search/config.json (at the repository
#     top) matches "required"\s*:\s*true, across lines, as doc-search's own
#     test does: check prints "not ready: uv not found" and exits 1, gate
#     prompt blocks the prompt and gate session-start adds the line as context;
#   - no uv otherwise: check prints "not in force: uv not found" and exits 4;
#     gate session-start and prompt are silent.
# gate tool never runs uv. It reads the verdict file doc-search gate keeps,
# $(git rev-parse --git-path doc-search-gate): line 1 the verdict, line 2 the
# reason and fix. Unless line 1 is not-ready it is silent. While it is, a Bash
# call whose whole command matches GATE_ALLOWED (the fix commands) is allowed
# and every other tool call is denied, line 2 in the reason. Without jq the
# call cannot be read, so every one is denied, with a fixed reason.
# check's line goes to stdout, as doc-search's does. gate prints one JSON
# object or nothing and exits 0 (3 for an unknown event). It never echoes the
# event, and it drains stdin it does not read, so the client's write never
# blocks.
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
  # Every ASCII blank becomes a space, so " *" is Python's \s across lines.
  tr '\t\n\v\f\r' '     ' 2>/dev/null <"$TOP/docs/search/config.json" | grep -Eq '"required" *: *true'
}

# gate_tool: the PreToolUse decision, from the verdict file and the event.
gate_tool() {
  VERDICT=$(git rev-parse --git-path doc-search-gate 2>/dev/null) || VERDICT=""
  if [ -z "$VERDICT" ] || [ ! -f "$VERDICT" ] || [ "$(sed -n 1p "$VERDICT" 2>/dev/null)" != not-ready ]; then
    gate_silent
  fi
  if ! command -v jq >/dev/null 2>&1; then
    drain
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$GATE_NOT_READY, and this hook cannot read the tool call without jq. $GATE_STOP\"}}"
    exit 0
  fi
  if [ -t 0 ]; then EVENT=""; else EVENT=$(cat); fi
  # A newline anywhere is refused: jq's $ also matches before a final newline.
  if printf '%s' "$EVENT" | jq -e --arg re "$GATE_ALLOWED" '
    .tool_name == "Bash"
    and (.tool_input.command | type) == "string"
    and (.tool_input.command | test("[\n\r]") | not)
    and (.tool_input.command | test($re))' >/dev/null 2>&1; then
    exit 0
  fi
  REASON=$(sed -n 2p "$VERDICT" 2>/dev/null) || REASON=""
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

# answer_check_gate <verb> [event] …: answer check or gate here where
# doc-search cannot run (see above); return to exec it otherwise.
answer_check_gate() {
  # Set here, after the env hook, so nothing it sets can change them. The
  # final $ is outside the quotes: this file's POSIX check refuses a dollar
  # sign right before a single quote (bash's ANSI-C quoting).
  UV_MISSING="uv not found (https://docs.astral.sh/uv/)"
  GATE_NOT_READY="doc-search is required here and not ready"
  GATE_STOP="Stop and report this to the user; do not work around it."
  GATE_ALLOWED='^sh (\"?[^ ;&|]*/)?\.claude/doc-superpowers/search-mcp\.sh\"? (index|status|check)( --format (text|json))?'\$
  VERB=$1
  EVENT_NAME=""
  if [ "$VERB" = gate ]; then
    EVENT_NAME=${2:-}
    case $EVENT_NAME in
      session-start | prompt | tool) ;;
      *)
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
    echo "doc-search: not in force: not a git work tree"
    exit 4
  fi
  if [ -z "$ROOT" ]; then
    if [ "$VERB" = gate ]; then gate_silent; fi
    echo "doc-search: not in force: doc-superpowers is not installed for this developer"
    exit 4
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
        printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"$GATE_NOT_READY: $UV_MISSING. Fix: install uv. Do no work until it is ready: tell the user this line and stop.\"}}"
        exit 0
        ;;
      prompt)
        drain
        printf '%s\n' "{\"decision\":\"block\",\"reason\":\"$GATE_NOT_READY: $UV_MISSING. Run: install uv — then send your message again. (Set DOC_SEARCH_GATE=0 to turn the gate off for yourself.)\"}"
        exit 0
        ;;
    esac
    echo "doc-search: not ready: $UV_MISSING"
    exit 1
  fi
  if [ "$VERB" = gate ]; then gate_silent; fi
  echo "doc-search: not in force: $UV_MISSING"
  exit 4
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

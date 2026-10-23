#!/usr/bin/env bash
# doc-superpowers setup: the per-harness doc-search MCP entries. Sourced by
# lib-probe.sh (which reads what is in place), and so by setup.sh and the
# tests; lib-exec.sh's writers (_exec_write, _exec_writable) are what the
# add and remove functions use, so those run in the executor (from TOP).
#
#   harness_file <h>             the harness's project file, relative to the
#                                repository top: claude-code .mcp.json, codex
#                                .codex/config.toml, cursor .cursor/mcp.json,
#                                opencode opencode.json, gemini
#                                .gemini/settings.json
#   harness_entry_state <h>      registered | different | absent | unreadable
#                                (reads TOP/<file>)
#   harness_entry_present <h>    setup's entry is in place: the Codex block
#                                (whatever it holds), or a JSON harness's
#                                "doc-search" entry exactly as setup writes
#                                it. Anything else that defines doc-search (an
#                                unmarked Codex definition, a JSON entry that
#                                differs) is the user's, not setup's
#   harness_entry_check add|remove <h>
#                                0, or 1 with HARNESS_ERROR: the refusals
#                                (what a step's opcheck_ runs, before any
#                                step has run)
#   harness_entry_add <h>        writes the entry; 1 with HARNESS_ERROR on a
#                                refusal
#   harness_entry_remove <h>     removes it; the same
#
# claude-code is install.sh's --search (".mcp.json" is its own): state reads
# install.sh status, add and remove run install and uninstall --search.
#
# The JSON harnesses (Cursor, Gemini CLI, OpenCode) are merged with jq: every
# other key stays (in jq's layout). Refused untouched: a file that is not a
# JSON object (comments included), a server table that is not an object, and
# a "doc-search" entry that setup did not write (one that differs from the
# entry setup writes: it is the user's). A new opencode.json gets "$schema";
# an existing one does not. Removal takes out the "doc-search" key of a
# registered entry and nothing else: never the server table, never the file
# or its directory, even when setup created them.
#
# Codex: TOML has no jq, so the entry is setup's marked block, appended after
# the file's own lines. The block is replaced in place when it differs and
# removed exactly: every other byte stays, the file's own ending included (a
# file without a final newline gets the block after one newline and no
# newline of its own, so removal gives the original bytes back). A line
# outside the block that defines doc-search is refused (TOML allows a
# definition once): a [mcp_servers.doc-search] (or quoted, or a subtable)
# header, a doc-search key (dotted keys too) under [mcp_servers], a top-level
# mcp_servers.doc-search key, or a top-level mcp_servers = {…} inline table
# (which no later table may extend). Markers that do not form one block are
# refused too. Nothing else of the file is read.

HARNESS_ERROR=""
HARNESS_CODEX_BEGIN="# doc-superpowers setup:begin doc-search"
HARNESS_CODEX_END="# doc-superpowers setup:end doc-search"
HARNESS_OPENCODE_SCHEMA="https://opencode.ai/config.json"

harness_file() {
  case "$1" in
    claude-code) printf '%s\n' .mcp.json ;;
    codex) printf '%s\n' .codex/config.toml ;;
    cursor) printf '%s\n' .cursor/mcp.json ;;
    opencode) printf '%s\n' opencode.json ;;
    gemini) printf '%s\n' .gemini/settings.json ;;
    *) return 1 ;;
  esac
}

# _harness_abs <h>: the file's path under TOP (relative when TOP is not set).
_harness_abs() {
  local f
  f=$(harness_file "$1") || return 1
  printf '%s\n' "${TOP:+$TOP/}$f"
}

# _harness_key <h>: the JSON object holding the servers.
_harness_key() {
  case "$1" in
    opencode) printf '%s\n' mcp ;;
    *) printf '%s\n' mcpServers ;;
  esac
}

# _harness_entry <h>: the JSON entry (references/search.md, Other clients).
# shellcheck disable=SC2016  # JSON text: ${workspaceFolder} and \" are not shell
_harness_entry() {
  case "$1" in
    cursor) printf '%s\n' '{"command":"sh","args":["-c","cd \"$1\" && exec sh .claude/doc-superpowers/search-mcp.sh serve","sh","${workspaceFolder}"]}' ;;
    gemini) printf '%s\n' '{"command":"sh","args":[".claude/doc-superpowers/search-mcp.sh","serve"]}' ;;
    opencode) printf '%s\n' '{"type":"local","command":["sh",".claude/doc-superpowers/search-mcp.sh","serve"],"timeout":60000}' ;;
    *) return 1 ;;
  esac
}

# _harness_codex_block: setup's block, exactly (design §8): the server starts
# in Codex's launch directory, so it changes to the repository top first.
# shellcheck disable=SC2016  # TOML text: $(…) and \" are not shell
_harness_codex_block() {
  printf '%s\n' "$HARNESS_CODEX_BEGIN" \
    '[mcp_servers.doc-search]' \
    'command = "sh"' \
    'args = ["-c", "cd \"$(git rev-parse --show-toplevel)\" && exec sh .claude/doc-superpowers/search-mcp.sh serve"]' \
    'startup_timeout_sec = 60' \
    "$HARNESS_CODEX_END"
}

# _harness_codex_scan <file>: _HC_NB (blocks), _HC_UN (definitions of
# doc-search outside a block, see the top) and _HC_BAD (0; 1 a second begin
# marker; 2 an end marker with no begin; 3 a begin marker with no end).
# Names are compared without spaces and quotes; the current table is the last
# header line seen (a comment or blank line defines nothing).
_harness_codex_scan() {
  local out
  _HC_NB=0 _HC_UN=0 _HC_BAD=0
  [ -f "$1" ] || return 0
  out=$(awk -v b="$HARNESS_CODEX_BEGIN" -v e="$HARNESS_CODEX_END" '
    function norm(s) { gsub(/[[:space:]]/, "", s); gsub(/"/, "", s); gsub(q, "", s); return s }
    function starts(s, p) { return index(s, p) == 1 }
    BEGIN { q = sprintf("%c", 39); tbl = "" }
    $0 == b { if (inb || nb) bad = 1; inb = 1; nb++; next }
    $0 == e { if (!inb) { bad = 2 } else { inb = 0 }; next }
    inb { next }
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*\[/ {
      line = $0
      sub(/^[[:space:]]*\[+/, "", line)
      sub(/\].*$/, "", line)
      tbl = norm(line)
      if (tbl == "mcp_servers.doc-search" || starts(tbl, "mcp_servers.doc-search.")) un++
      next
    }
    /=/ {
      key = $0
      sub(/=.*$/, "", key)
      key = norm(key)
      if (tbl == "mcp_servers" && (key == "doc-search" || starts(key, "doc-search."))) un++
      if (tbl == "" && (key == "mcp_servers" || key == "mcp_servers.doc-search" || starts(key, "mcp_servers.doc-search."))) un++
    }
    END { if (inb && !bad) bad = 3; print nb + 0, un + 0, bad + 0 }' "$1" 2>/dev/null) || out="0 0 3"
  read -r _HC_NB _HC_UN _HC_BAD <<<"$out"
}

# _harness_codex_why <file>: HARNESS_ERROR for a bad scan.
_harness_codex_why() {
  case "$_HC_BAD" in
    3) HARNESS_ERROR="$1 has setup's begin marker ($HARNESS_CODEX_BEGIN) but no end marker ($HARNESS_CODEX_END): fix it by hand" ;;
    *) HARNESS_ERROR="$1: setup's markers ($HARNESS_CODEX_BEGIN, $HARNESS_CODEX_END) do not form one block: fix it by hand" ;;
  esac
}

# _harness_codex_split <text>: the text around its one block: _HS_PRE (before
# the begin line), _HS_POST (after the end line and its newline) and _HS_NOEOL
# (1 when the end line is the last and has no newline). Returns 1 when it
# finds no block. The begin line is the first line that IS the marker.
_harness_codex_split() {
  local cur="$1" nl=$'\n' b="$HARNESS_CODEX_BEGIN" e="$HARNESS_CODEX_END" rest tail after
  _HS_PRE="" _HS_POST="" _HS_NOEOL=0
  if [[ "$cur" == "$b$nl"* || "$cur" == "$b" ]]; then
    rest="${cur#"$b"}"
  else
    tail="$cur"
    while :; do
      [[ "$tail" == *"$nl$b"* ]] || return 1
      after="${tail#*"$nl$b"}"
      _HS_PRE="$_HS_PRE${tail%%"$nl$b"*}$nl"
      if [[ -z "$after" || "$after" == "$nl"* ]]; then
        rest="$after"
        break
      fi
      _HS_PRE="$_HS_PRE$b"
      tail="$after"
    done
  fi
  if [[ "$rest" == *"$nl$e$nl"* ]]; then
    _HS_POST="${rest#*"$nl$e$nl"}"
  elif [[ "$rest" == *"$nl$e" ]]; then
    _HS_NOEOL=1
  else
    return 1
  fi
}

# _harness_json_state <h>: _HJ_STATE (absent | registered | different |
# unreadable) and _HJ_WHY (why unreadable).
_harness_json_state() {
  local f key entry
  f=$(_harness_abs "$1") || return 1
  key=$(_harness_key "$1")
  entry=$(_harness_entry "$1")
  _HJ_STATE=absent _HJ_WHY=""
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    _HJ_STATE=unreadable
    _HJ_WHY="is not a JSON object (setup merges into a JSON object, and cannot read comments or other syntax)"
  elif ! jq -e --arg k "$key" '(.[$k] == null) or (.[$k] | type == "object")' "$f" >/dev/null 2>&1; then
    _HJ_STATE=unreadable
    _HJ_WHY="has a \"$key\" that is not an object"
  elif jq -e --arg k "$key" --argjson e "$entry" '.[$k]["doc-search"] == $e' "$f" >/dev/null 2>&1; then
    _HJ_STATE=registered
  elif jq -e --arg k "$key" '.[$k]["doc-search"] != null' "$f" >/dev/null 2>&1; then
    _HJ_STATE=different
  fi
}

# _harness_claude_state: install.sh's verdict on the .mcp.json entry.
_harness_claude_state() {
  local out v
  if ! out=$(cd "$TOP" && "$BASH" "$ROOT/scripts/hooks/install.sh" status --search --json </dev/null 2>/dev/null); then
    echo unreadable
    return 0
  fi
  v=$(jq -r '.tiers.search.mcp_entry // "absent"' <<<"$out" 2>/dev/null) || v=""
  case "$v" in
    registered) echo registered ;;
    different-command) echo different ;;
    "") echo unreadable ;;
    *) echo absent ;;
  esac
}

harness_entry_state() {
  local f block
  case "$1" in
    claude-code) _harness_claude_state ;;
    codex)
      f=$(_harness_abs codex)
      if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        echo absent
        return 0
      fi
      _harness_codex_scan "$f"
      if [ "$_HC_BAD" != 0 ]; then
        echo unreadable
      elif [ "$_HC_NB" = 0 ]; then
        if [ "$_HC_UN" = 0 ]; then echo absent; else echo different; fi
      else
        block=$(awk -v b="$HARNESS_CODEX_BEGIN" -v e="$HARNESS_CODEX_END" '$0 == b { on = 1 } on { print } $0 == e { exit }' "$f")
        if [ "$_HC_UN" = 0 ] && [ "$block" = "$(_harness_codex_block)" ]; then echo registered; else echo different; fi
      fi
      ;;
    cursor | opencode | gemini)
      _harness_json_state "$1"
      echo "$_HJ_STATE"
      ;;
    *) return 1 ;;
  esac
}

# harness_entry_present <h>: setup's entry is in place: the Codex block
# (registered, or edited), or a JSON entry exactly as setup writes it. What
# an untick removes.
harness_entry_present() {
  local f
  case "$1" in
    codex)
      f=$(_harness_abs codex)
      [ -f "$f" ] || return 1
      _harness_codex_scan "$f"
      [ "$_HC_BAD" = 0 ] && [ "$_HC_NB" = 1 ]
      ;;
    claude-code | cursor | opencode | gemini)
      [ "$(harness_entry_state "$1")" = registered ]
      ;;
    *) return 1 ;;
  esac
}

# harness_entry_check add|remove <h>: the refusals, 0 or 1 with HARNESS_ERROR.
# Runs from TOP (the paths are relative).
harness_entry_check() {
  local op="$1" h="$2" f
  HARNESS_ERROR=""
  case "$h" in
    claude-code) return 0 ;;
    codex | cursor | opencode | gemini) ;;
    *)
      HARNESS_ERROR="unknown harness '$h'"
      return 1
      ;;
  esac
  f=$(harness_file "$h")
  if ! _exec_writable "$f"; then
    HARNESS_ERROR="$EXEC_ERROR"
    return 1
  fi
  if [ "$h" = codex ]; then
    _harness_codex_scan "$f"
    if [ "$_HC_BAD" != 0 ]; then
      _harness_codex_why "$f"
      return 1
    fi
    if [ "$op" = add ] && [ "$_HC_UN" != 0 ]; then
      HARNESS_ERROR="$f already defines [mcp_servers.doc-search] outside setup's block (or defines mcp_servers as an inline table); TOML allows it once, and setup edits only what it wrote: move it into a block between '$HARNESS_CODEX_BEGIN' and '$HARNESS_CODEX_END', or remove it, and run setup again"
      return 1
    fi
    return 0
  fi
  _harness_json_state "$h"
  if [ "$_HJ_STATE" = unreadable ]; then
    HARNESS_ERROR="$f $_HJ_WHY"
    return 1
  fi
  if [ "$op" = add ] && [ "$_HJ_STATE" = different ]; then
    HARNESS_ERROR="$f has a \"doc-search\" entry under \"$(_harness_key "$h")\" that is not the one setup writes (references/search.md, Other clients): setup does not replace an entry it did not write; remove it or make it match, and run setup again"
    return 1
  fi
  return 0
}

# _harness_check_json / _harness_check_toml <temp file>: _exec_write's check
# of what is about to replace the file.
_harness_check_json() {
  if jq -e 'type == "object"' "$1" >/dev/null 2>&1; then return 0; fi
  EXEC_ERROR="the result is not a JSON object"
  return 1
}
_harness_check_toml() {
  _harness_codex_scan "$1"
  if [ "$_HC_BAD" = 0 ] && [ "$_HC_NB" -le 1 ] && [ "$_HC_UN" = 0 ]; then return 0; fi
  EXEC_ERROR="the result does not hold exactly one doc-search table"
  return 1
}

# _harness_read <file>: _HR_CUR, the file's bytes with trailing newlines.
_harness_read() {
  _HR_CUR=$(cat "$1" && printf x) || return 1
  _HR_CUR="${_HR_CUR%x}"
}

_harness_codex_add() {
  local f block new nl=$'\n'
  f=$(harness_file codex)
  block=$(_harness_codex_block)
  if [ ! -e "$f" ]; then
    new="$block$nl"
  else
    _harness_read "$f" || {
      HARNESS_ERROR="cannot read $f"
      return 1
    }
    _harness_codex_scan "$f"
    if [ "$_HC_NB" = 1 ]; then
      _harness_codex_split "$_HR_CUR" || {
        HARNESS_ERROR="cannot find setup's block in $f"
        return 1
      }
      if [ "$_HS_NOEOL" = 1 ]; then
        new="$_HS_PRE$block"
      else
        new="$_HS_PRE$block$nl$_HS_POST"
      fi
    else
      case "$_HR_CUR" in
        "" | *"$nl") new="$_HR_CUR$block$nl" ;;
        *) new="$_HR_CUR$nl$block" ;;
      esac
    fi
  fi
  _exec_write "$f" "$new" _harness_check_toml exact
}

_harness_codex_remove() {
  local f new nl=$'\n'
  f=$(harness_file codex)
  [ -f "$f" ] || return 0
  _harness_codex_scan "$f"
  [ "$_HC_NB" = 1 ] || return 0
  _harness_read "$f" || {
    HARNESS_ERROR="cannot read $f"
    return 1
  }
  _harness_codex_split "$_HR_CUR" || {
    HARNESS_ERROR="cannot find setup's block in $f"
    return 1
  }
  if [ "$_HS_NOEOL" = 1 ]; then
    new="${_HS_PRE%"$nl"}"
  else
    new="$_HS_PRE$_HS_POST"
  fi
  _exec_write "$f" "$new" _harness_check_toml exact
}

_harness_json_add() {
  local h="$1" f key entry new
  f=$(harness_file "$h")
  key=$(_harness_key "$h")
  entry=$(_harness_entry "$h")
  _harness_json_state "$h"
  [ "$_HJ_STATE" != registered ] || return 0
  if [ -e "$f" ]; then
    new=$(jq --arg k "$key" --argjson e "$entry" '.[$k] = ((.[$k] // {}) | .["doc-search"] = $e)' "$f") || {
      HARNESS_ERROR="cannot update $f"
      return 1
    }
  elif [ "$h" = opencode ]; then
    new=$(jq -n --arg s "$HARNESS_OPENCODE_SCHEMA" --arg k "$key" --argjson e "$entry" '{"$schema": $s, ($k): {"doc-search": $e}}') || return 1
  else
    new=$(jq -n --arg k "$key" --argjson e "$entry" '{($k): {"doc-search": $e}}') || return 1
  fi
  _exec_write "$f" "$new" _harness_check_json
}

# The "doc-search" key of a registered entry, and nothing else.
_harness_json_remove() {
  local h="$1" f key new
  f=$(harness_file "$h")
  key=$(_harness_key "$h")
  _harness_json_state "$h"
  [ "$_HJ_STATE" = registered ] || return 0
  new=$(jq --arg k "$key" 'del(.[$k]["doc-search"])' "$f") || {
    HARNESS_ERROR="cannot update $f"
    return 1
  }
  _exec_write "$f" "$new" _harness_check_json
}

harness_entry_add() {
  HARNESS_ERROR=""
  harness_entry_check add "$1" || return 1
  case "$1" in
    claude-code) _exec_installer install --search ;;
    codex) _harness_codex_add ;;
    *) _harness_json_add "$1" ;;
  esac
}

harness_entry_remove() {
  # shellcheck disable=SC2034  # HARNESS_ERROR is the interface read by lib-exec.sh's op_ wrappers
  HARNESS_ERROR=""
  harness_entry_check remove "$1" || return 1
  case "$1" in
    claude-code) _exec_installer uninstall --search ;;
    codex) _harness_codex_remove ;;
    *) _harness_json_remove "$1" ;;
  esac
}

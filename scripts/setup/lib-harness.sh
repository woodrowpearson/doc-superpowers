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
#   harness_entry_present <h>    setup's entry is there: the Codex block, or
#                                the "doc-search" key of a JSON harness (an
#                                unmarked Codex table is not setup's)
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
# other key stays (in jq's layout); a file that is not a JSON object, or
# whose server table is not an object, is refused untouched. A new
# opencode.json gets "$schema"; an existing one does not. Removal takes out
# the entry, then the server table when it is left empty, and the file when
# nothing but setup's own is left (and its directory, when empty).
#
# Codex: TOML has no jq, so the entry is setup's marked block, appended after
# the file's own lines (a missing final newline gets one first). The block is
# replaced in place when it differs, removed exactly (every other byte stays;
# a file left empty goes). An [mcp_servers.doc-search] table outside the
# block is refused (TOML forbids a duplicate table), and so are markers that
# do not form one block; nothing else of the file is read.

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

# _harness_codex_scan <file>: _HC_NB (blocks), _HC_UN (doc-search tables
# outside a block) and _HC_BAD (0; 1 a second begin marker; 2 an end marker
# with no begin; 3 a begin marker with no end).
_harness_codex_scan() {
  local out
  _HC_NB=0 _HC_UN=0 _HC_BAD=0
  [ -f "$1" ] || return 0
  out=$(awk -v b="$HARNESS_CODEX_BEGIN" -v e="$HARNESS_CODEX_END" '
    $0 == b { if (inb || nb) bad = 1; inb = 1; nb++; next }
    $0 == e { if (!inb) { bad = 2 } else { inb = 0 }; next }
    inb { next }
    /^[[:space:]]*\[[[:space:]]*mcp_servers[[:space:]]*\.[[:space:]]*("doc-search"|doc-search)[[:space:]]*\][[:space:]]*(#.*)?$/ { un++ }
    END { if (inb && !bad) bad = 3; print nb + 0, un + 0, bad + 0 }' "$1" 2>/dev/null) || out="0 0 3"
  read -r _HC_NB _HC_UN _HC_BAD <<<"$out"
}

# _harness_codex_why: HARNESS_ERROR for a bad scan.
_harness_codex_why() {
  case "$_HC_BAD" in
    3) HARNESS_ERROR="$1 has setup's begin marker ($HARNESS_CODEX_BEGIN) but no end marker ($HARNESS_CODEX_END): fix it by hand" ;;
    *) HARNESS_ERROR="$1: setup's markers ($HARNESS_CODEX_BEGIN, $HARNESS_CODEX_END) do not form one block: fix it by hand" ;;
  esac
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

# harness_entry_present <h>: setup's entry is in place (registered, or
# different: edited by hand or an older one), which an untick removes.
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
      case "$(harness_entry_state "$1")" in
        registered | different) return 0 ;;
      esac
      return 1
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
      HARNESS_ERROR="$f already defines [mcp_servers.doc-search] outside setup's block (TOML allows a table once, and setup edits only what it wrote): move it into a block between '$HARNESS_CODEX_BEGIN' and '$HARNESS_CODEX_END', or remove it, and run setup again"
      return 1
    fi
    return 0
  fi
  _harness_json_state "$h"
  if [ "$_HJ_STATE" = unreadable ]; then
    HARNESS_ERROR="$f $_HJ_WHY"
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

# _harness_delete <file>: the file, and its directory when that is left empty.
_harness_delete() {
  local d
  rm -f "$1"
  d=$(dirname "$1")
  [ "$d" = . ] || rmdir "$d" 2>/dev/null || true
}

_harness_codex_add() {
  local f block new cur
  f=$(harness_file codex)
  block=$(_harness_codex_block)
  if [ ! -e "$f" ]; then
    new="$block"
  else
    _harness_read "$f" || {
      HARNESS_ERROR="cannot read $f"
      return 1
    }
    cur="$_HR_CUR"
    _harness_codex_scan "$f"
    if [ "$_HC_NB" = 1 ]; then
      new=$(HBLK="$block" awk -v b="$HARNESS_CODEX_BEGIN" -v e="$HARNESS_CODEX_END" '
        $0 == b { if (!done) { print ENVIRON["HBLK"]; done = 1 }; skip = 1; next }
        skip { if ($0 == e) skip = 0; next }
        { print }' "$f" && printf x) || {
        HARNESS_ERROR="cannot edit $f"
        return 1
      }
      new="${new%x}"
      new="${new%$'\n'}"
    else
      case "$cur" in
        "" | *$'\n') ;;
        *) cur="$cur"$'\n' ;;
      esac
      new="$cur$block"
    fi
  fi
  _exec_write "$f" "$new" _harness_check_toml
}

_harness_codex_remove() {
  local f new
  f=$(harness_file codex)
  [ -f "$f" ] || return 0
  _harness_codex_scan "$f"
  [ "$_HC_NB" = 1 ] || return 0
  new=$(awk -v b="$HARNESS_CODEX_BEGIN" -v e="$HARNESS_CODEX_END" '
    $0 == b { skip = 1; next }
    skip { if ($0 == e) skip = 0; next }
    { print }' "$f" && printf x) || {
    HARNESS_ERROR="cannot edit $f"
    return 1
  }
  new="${new%x}"
  if [ -z "$new" ]; then
    _harness_delete "$f"
    return 0
  fi
  _exec_write "$f" "${new%$'\n'}" _harness_check_toml
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

_harness_json_remove() {
  local h="$1" f key new
  f=$(harness_file "$h")
  key=$(_harness_key "$h")
  _harness_json_state "$h"
  case "$_HJ_STATE" in
    registered | different) ;;
    *) return 0 ;;
  esac
  new=$(jq --arg k "$key" 'del(.[$k]["doc-search"]) | if (.[$k] | type) == "object" and (.[$k] | length) == 0 then del(.[$k]) else . end' "$f") || {
    HARNESS_ERROR="cannot update $f"
    return 1
  }
  # Nothing but setup's own left: the file goes.
  if jq -e --arg s "$HARNESS_OPENCODE_SCHEMA" 'length == 0 or ($s as $u | . == {"$schema": $u})' <<<"$new" >/dev/null 2>&1; then
    _harness_delete "$f"
    return 0
  fi
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

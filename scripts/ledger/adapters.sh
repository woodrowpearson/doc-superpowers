# shellcheck shell=bash
# scripts/ledger/adapters.sh — the ledger's adapters (design §G): executables
# named in config "adapters" that read a host's systems for the ledger.
# Sourced by lib.sh; uses lib.sh's _lg_cfg, _LG_ROOT and parse.sh's
# _lg_scratch_name; doc-tools.sh's SCRIPT_DIR (the scripts/ directory of the
# running copy — the plugin's, or a vendored copy's).
#
# _lg_adapter <name> <args…>: run adapters.<name> with <args>, from the top
# level, stdin closed. The value is
#   - an absolute path,
#   - a path relative to the top level of the work tree, or
#   - "doc-superpowers:<adapter>" → $SCRIPT_DIR/adapters/<adapter>.sh, the
#     adapter shipped beside this copy of doc-tools.sh (<adapter>:
#     [a-z0-9_-]+, nothing that leaves the directory).
# Absent (null, "" or no such key) → rc 0, no output. A value that is not a
# string, a file that is missing or not executable, a non-zero exit, or
# output that breaks the adapter's contract → rc 2, with one message on
# stderr that carries the adapter's own stderr (its first lines). Otherwise
# the output, one JSON object per line, compact, on stdout (rc 0).
#
# The contract a list output is checked against (_LG_ADAPTER_REQ: every line
# one JSON object holding these fields):
#   contracts list   "id" a contract id (<kind>:<name>), "ledger" a string
#                    or null, "defined_in" a list of strings; "title", when
#                    present, a string or null
#   pr list          "number", "head", "state", "url"
# Other subcommands (contracts resolve <id>: exit 0/1) are not checked: the
# caller reads the exit status (_lg_adapter_rc).

# _lg_adapter_path <name>: the executable adapters.<name> names into
# _LG_ADP ("" when the config names none); rc 2 with a message in
# _LG_ADP_ERR when the value cannot be one.
_lg_adapter_path() {
  local name="$1" v
  _LG_ADP=""
  _LG_ADP_ERR=""
  v=$(_lg_cfg ".adapters[\"$name\"] // null | if . == null then \"\" elif type == \"string\" then \"s\" + . else \"!\" + tojson end")
  case "$v" in
    '') return 0 ;;
    s) return 0 ;;
    '!'*) _LG_ADP_ERR="config adapters.$name is not a path: ${v#!}"; return 2 ;;
  esac
  v=${v#s}
  case "$v" in
    doc-superpowers:*)
      local a=${v#doc-superpowers:}
      case "$a" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
          _LG_ADP_ERR="config adapters.$name: '$v' does not name a doc-superpowers adapter ([a-z0-9_-]+)"
          return 2 ;;
      esac
      _LG_ADP="$SCRIPT_DIR/adapters/$a.sh" ;;
    /*) _LG_ADP=$v ;;
    *) _LG_ADP="$_LG_ROOT/$v" ;;
  esac
  if [ ! -f "$_LG_ADP" ]; then
    _LG_ADP_ERR="adapter $name: no such file: $_LG_ADP (config adapters.$name '$v')"
    return 2
  fi
  if [ ! -x "$_LG_ADP" ]; then
    _LG_ADP_ERR="adapter $name: not executable: $_LG_ADP"
    return 2
  fi
  return 0
}

# The required fields of a list output, per adapter (jq: true when the line
# — an object — keeps the contract).
# shellcheck disable=SC2016  # jq source
_LG_ADAPTER_REQ_contracts='(.id | type == "string" and test("\\A[a-z][a-z0-9_-]*:[^[:space:]]+\\z"))
  and has("ledger") and (.ledger == null or (.ledger | type) == "string")
  and (.defined_in | type == "array" and all(.[]; type == "string"))
  and ((has("title") | not) or .title == null or (.title | type) == "string")'
# shellcheck disable=SC2016  # jq source
_LG_ADAPTER_REQ_pr='has("number") and has("head") and has("state") and has("url")'

_lg_adapter() {
  local name="$1" s rc=0 req=""
  shift
  _lg_adapter_path "$name" || { printf '%s\n' "$_LG_ADP_ERR" >&2; return 2; }
  [ -n "$_LG_ADP" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  ( cd "$_LG_ROOT" && "$_LG_ADP" "$@" ) < /dev/null > "$s.aout" 2> "$s.aerr" || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'adapter %s (%s %s) exited %s: %s\n' "$name" "$_LG_ADP" "$*" "$rc" \
      "$(head -n 5 "$s.aerr" | tr '\n' ' ' | tr -d '\000-\010\013-\037')" >&2
    return 2
  fi
  if [ "${1:-}" = list ]; then
    case "$name" in
      contracts) req=$_LG_ADAPTER_REQ_contracts ;;
      pr) req=$_LG_ADAPTER_REQ_pr ;;
    esac
  fi
  [ -n "$req" ] || { cat -- "$s.aout"; return 0; }
  # Each line on its own (fromjson per raw line), so the message names the
  # first line that breaks the contract; empty lines are skipped.
  if ! jq -R -r "
      (input_line_number) as \$n
      | if test(\"^\\\\s*\$\") then empty
        else (try fromjson catch null) as \$o
          | if (\$o | type) == \"object\" and (\$o | $req) then \$o | tojson
            else error(\"line \\(\$n): \\(.[0:200])\") end
        end" "$s.aout" > "$s.aok" 2> "$s.ajq"; then
    printf 'adapter %s (%s %s): output breaks the %s contract — %s%s\n' "$name" "$_LG_ADP" "$*" "$name" \
      "$(sed -n 's/^jq: error ([^)]*): //p; s/^jq: error: //p' "$s.ajq" | head -n 1 | tr -d '\000-\010\013-\037')" \
      "$(if [ -s "$s.aerr" ]; then printf ' (stderr: %s)' "$(head -n 3 "$s.aerr" | tr '\n' ' ' | tr -d '\000-\010\013-\037')"; fi)" >&2
    return 2
  fi
  cat -- "$s.aok"
}

# _lg_adapter_rc <name> <args…>: run the adapter for its exit status (0/1
# answers, e.g. contracts resolve <id>); absent → 1; any other status, or an
# adapter that cannot run → 2 with the message on stderr.
_lg_adapter_rc() {
  local name="$1" rc=0
  shift
  _lg_adapter_path "$name" || { printf '%s\n' "$_LG_ADP_ERR" >&2; return 2; }
  [ -n "$_LG_ADP" ] || return 1
  ( cd "$_LG_ROOT" && "$_LG_ADP" "$@" ) < /dev/null > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
  esac
  printf 'adapter %s (%s %s) exited %s\n' "$name" "$_LG_ADP" "$*" "$rc" >&2
  return 2
}

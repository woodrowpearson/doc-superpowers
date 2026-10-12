# shellcheck shell=bash
# scripts/ledger/lib.sh — the work ledger's core, sourced by doc-tools.sh
# (_lg_enter) only when a ledger verb runs in a repository that has
# docs/ledger/config.json. Not executable on its own: it uses doc-tools.sh's
# globals and helpers (_SCRATCH, _scratch_init, _exit_ok, and the verdict
# printers _lg_json_str, _lg_out, _lg_mark_emitted, _lg_fail, which live in
# doc-tools.sh so its exit paths work before — or without — this file).
#
# bash 3.2 + jq >= 1.6 (see the global constraints in doc-tools.sh).

_LG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LG_CFG=""           # the merged config (a file in $_SCRATCH): _lg_init
_LG_ROOT=""          # the work tree's top level
_LG_CACHE=""         # $(git rev-parse --git-common-dir)/doc-superpowers/ledger
                     # (absolute; created by whoever first writes to it)

# _lg_die <message>: the run could not run — exit 2, with the verdict object
# in --format json (exactly once, inside $(…) too: the marker file tells the
# EXIT trap a verdict was printed).
_lg_die() {
  _lg_fail 2 "$*"
}

# _lg_usage <message>: a ledger command-line error found by a verb (an
# argument _parse_args cannot judge) — exit 3, with its object.
_lg_usage() {
  _lg_fail 3 "ledger $_LG_VERB: $*" "ledger $_LG_VERB"
}

# _lg_init <sub>: scratch dir, top level, cache path, the merged config.
# Call in the main shell (never inside $(…)), first thing in a handler.
# doc-tools.sh has already established that docs/ledger/config.json exists.
_lg_init() {
  local host cfg common
  _LG_VERB="$1"
  _scratch_init
  _LG_ROOT=$(git rev-parse --show-toplevel) || _lg_die "cannot resolve the work tree's top level"
  common=$(git rev-parse --git-common-dir) || _lg_die "cannot resolve the git common dir"
  case "$common" in
    /*) ;;
    *) common="$PWD/$common" ;;
  esac
  _LG_CACHE="$common/doc-superpowers/ledger"

  host="$_SCRATCH/lg-config-host.json"
  cfg="$_SCRATCH/lg-config.json"
  cat -- docs/ledger/config.json > "$host" 2>/dev/null \
    || _lg_die "cannot read docs/ledger/config.json"
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$host" >/dev/null 2>&1; then
    _lg_die "docs/ledger/config.json is not one JSON object"
  fi
  # config.jq reads the host object as $h (a config is small: the command
  # line holds it).
  jq -nc --argjson h "$(cat "$host")" -f "$_LG_LIB/config.jq" > "$cfg" \
    || _lg_die "cannot merge docs/ledger/config.json with the defaults (scripts/ledger/config.jq)"
  _LG_CFG="$cfg"

  # Test-only hooks (scripts/test-ledger.sh), inert unless the variable is
  # set: a verdict printed inside $(…), and a crash no emitter sees.
  # shellcheck disable=SC2154  # _lg_selftest_unset: unset on purpose
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    die-in-subst) _lg_selftest_x=$(_lg_die boom) || exit "$?" ;;
    unset-var) unset _lg_selftest_unset; : "$_lg_selftest_unset" ;;
  esac
}

# _lg_cfg <jq-filter>: the filter's result over the merged config, compact
# (strings raw). Dies (2) when jq fails.
_lg_cfg() {
  jq -c -r "$1" "$_LG_CFG" || _lg_die "jq failed (config: $1)"
}

# _lg_emit <sub> <rc> [payload-json-file]: end the run with its verdict.
# --format json: one object {"verb":"ledger <sub>","enabled":true,"exit":rc}
# plus the payload object's other keys. Text mode: the verb has already
# printed its lines (with _lg_out); nothing more is printed. Exits <rc>.
_lg_emit() {
  local sub="$1" rc="$2" payload="${3:-}" line
  case "$rc" in
    0|1|2|3) ;;
    *) _lg_die "internal: _lg_emit got exit code '$rc'" ;;
  esac
  if [ "$_LG_FORMAT" = json ]; then
    if [ -n "$payload" ]; then
      line=$(jq -c --arg verb "ledger $sub" --argjson rc "$rc" \
        '{verb: $verb, enabled: true, exit: $rc} + (. | del(.verb, .enabled, .exit))' "$payload") \
        || _lg_die "jq failed (verdict payload)"
    else
      line=$(jq -nc --arg verb "ledger $sub" --argjson rc "$rc" '{verb: $verb, enabled: true, exit: $rc}') \
        || _lg_die "jq failed (verdict)"
    fi
    _lg_mark_emitted "$rc"
    _lg_out "$line"
  else
    _lg_mark_emitted "$rc"
  fi
  if [ "$rc" = 0 ]; then _exit_ok; fi
  exit "$rc"
}

# _lg_doc_index: print the path of a private copy of docs/.doc-index.json
# (shape-checked like _index_load), or of an empty {"docs":{}} when the repo
# has none. A present but invalid index dies with 2 — never _index_load's
# exit 1, which a ledger verb would report as findings. Needs _lg_init.
_lg_doc_index() {
  local snap
  snap=$(mktemp "$_SCRATCH/lg-doc-index.XXXXXX") || _lg_die "mktemp failed"
  if [ ! -e "$INDEX_FILE" ] && [ ! -L "$INDEX_FILE" ]; then
    printf '%s\n' '{"docs":{}}' > "$snap" || _lg_die "cannot write $snap"
    printf '%s\n' "$snap"
    return 0
  fi
  cp -- "$INDEX_FILE" "$snap" 2>/dev/null || _lg_die "cannot read $INDEX_FILE"
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"' \
      "$snap" >/dev/null 2>&1; then
    _lg_die "$INDEX_FILE is not a valid doc-index (expected one JSON object with a \"docs\" object)"
  fi
  printf '%s\n' "$snap"
}

# --- Handlers ------------------------------------------------------------------
#
# One per verb-table row (doc-tools.sh "ledger <sub>|cmd_ledger_<sub>|…").
# A verb not yet built loads the config and says so (exit 2); the task that
# builds it replaces its line here with the module that defines it.
_lg_stub() {
  _lg_init "$_LG_VERB"
  _lg_die "not implemented"
}
cmd_ledger_show() { _lg_stub "$@"; }
cmd_ledger_ls() { _lg_stub "$@"; }
cmd_ledger_find() { _lg_stub "$@"; }
cmd_ledger_related() { _lg_stub "$@"; }
cmd_ledger_sweep() { _lg_stub "$@"; }
cmd_ledger_recheck() { _lg_stub "$@"; }
cmd_ledger_inflight() { _lg_stub "$@"; }
cmd_ledger_notices() { _lg_stub "$@"; }
cmd_ledger_new() { _lg_stub "$@"; }
cmd_ledger_assign() { _lg_stub "$@"; }
cmd_ledger_link() { _lg_stub "$@"; }
cmd_ledger_note() { _lg_stub "$@"; }
cmd_ledger_view() { _lg_stub "$@"; }
cmd_ledger_validate() { _lg_stub "$@"; }
cmd_ledger_publish() { _lg_stub "$@"; }
cmd_ledger_finalize() { _lg_stub "$@"; }
cmd_ledger_init() { _lg_stub "$@"; }

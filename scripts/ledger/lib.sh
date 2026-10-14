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
_LG_IX_NEED_CONTRACTS=""  # 1: the verb shows relations — a failing contracts
                          # adapter is fatal (index.sh _lg_ix_adapter_contracts)
_LG_CACHE=""         # $(git rev-parse --git-common-dir)/doc-superpowers/ledger
                     # (absolute; created by whoever first writes to it:
                     # mkdir -p — the parse cache, parse.sh, is the first)

# The modules. Each defines functions only.
# shellcheck source=scripts/ledger/parse.sh
. "$_LG_LIB/parse.sh"
# shellcheck source=scripts/ledger/glob.sh
. "$_LG_LIB/glob.sh"
# shellcheck source=scripts/ledger/validate.sh
. "$_LG_LIB/validate.sh"
# shellcheck source=scripts/ledger/index.sh
. "$_LG_LIB/index.sh"
# shellcheck source=scripts/ledger/keys.sh
. "$_LG_LIB/keys.sh"
# shellcheck source=scripts/ledger/query.sh
. "$_LG_LIB/query.sh"
# shellcheck source=scripts/ledger/views.sh
. "$_LG_LIB/views.sh"
# shellcheck source=scripts/ledger/adapters.sh
. "$_LG_LIB/adapters.sh"
# shellcheck source=scripts/ledger/relations.sh
. "$_LG_LIB/relations.sh"
# shellcheck source=scripts/ledger/inflight.sh
. "$_LG_LIB/inflight.sh"
# shellcheck source=scripts/ledger/init.sh
. "$_LG_LIB/init.sh"

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
# doc-tools.sh has already established that docs/ledger/config.json exists
# — except for init, which runs on the default config ({}) without one.
_lg_init() {
  local host common
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
  if [ "$1" = init ] && [ ! -e docs/ledger/config.json ] && [ ! -L docs/ledger/config.json ]; then
    printf '{}\n' > "$host" || _lg_die "cannot write $host"
  else
    cat -- docs/ledger/config.json > "$host" 2>/dev/null \
      || _lg_die "cannot read docs/ledger/config.json"
  fi
  _lg_cfg_merge "$host" "$_SCRATCH/lg-config.json" "docs/ledger/config.json"

  # Test-only hooks (scripts/test-ledger.sh), inert unless the variable is
  # set: a verdict printed inside $(…), and a crash no emitter sees.
  # shellcheck disable=SC2154  # _lg_selftest_unset: unset on purpose
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    die-in-subst) _lg_selftest_x=$(_lg_die boom) || exit "$?" ;;
    unset-var) unset _lg_selftest_unset; : "$_lg_selftest_unset" ;;
    die-twice) _lg_selftest_x=$(_lg_die first) || true; _lg_die second ;;
    emit-after-error) _lg_selftest_x=$(_lg_die first) || true; _lg_emit "$1" 0 ;;
  esac
}

# _lg_cfg_merge <host-file> <out> <name>: check that <host-file> is one
# JSON object (<name> in the message), merge it over the defaults
# (config.jq) into <out>, and make <out> the run's config (_LG_CFG).
_lg_cfg_merge() {
  local host="$1" out="$2" name="$3"
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$host" >/dev/null 2>&1; then
    _lg_die "$name is not one JSON object"
  fi
  # config.jq reads the host object as $h (a config is small: the command
  # line holds it).
  jq -nc --argjson h "$(cat "$host")" -f "$_LG_LIB/config.jq" > "$out" \
    || _lg_die "cannot merge $name with the defaults (scripts/ledger/config.jq)"
  _LG_CFG="$out"
}

# _lg_cfg_from_rev <commit>: make the commit's docs/ledger/config.json the
# run's config (ledger publish renders a base with its own config). Dies
# (2) when the commit has none or it is not one JSON object.
_lg_cfg_from_rev() {
  local host="$_SCRATCH/lg-config-rev-host.json"
  _lg_src_cat "$1" docs/ledger/config.json "$host" \
    || _lg_die "$1 has no docs/ledger/config.json"
  _lg_cfg_merge "$host" "$_SCRATCH/lg-config-rev.json" "docs/ledger/config.json at $1"
}

# _lg_cfg <jq-filter>: the filter's result over the merged config, compact
# (strings raw). Dies (2) when jq fails.
_lg_cfg() {
  jq -c -r "$1" "$_LG_CFG" || _lg_die "jq failed (config: $1)"
}

# _lg_emit <sub> <rc> [payload-json-file]: end the run with its verdict.
# --format json: one object {"verb":"ledger <sub>","enabled":true,"exit":rc}
# plus the payload object's other keys ("enabled" is false only for init
# run without docs/ledger/config.json). Text mode: the verb has already
# printed its lines (with _lg_out); nothing more is printed. Exits <rc>.
# .verb comes from _LG_VERB — the verb every error object of this run names
# — and <sub> must match it (a mismatch is an internal error, rc 2).
_lg_emit() {
  local sub="$1" rc="$2" payload="${3:-}" line verb enabled=true
  if [ "$sub" != "$_LG_VERB" ]; then
    _lg_die "internal: _lg_emit for 'ledger $sub' in a 'ledger $_LG_VERB' run"
  fi
  case "$rc" in
    0|1|2|3) ;;
    *) _lg_die "internal: _lg_emit got exit code '$rc'" ;;
  esac
  # An error verdict was printed already (a producer that failed inside
  # $(…) and was run past): no second object — the run ends with its code.
  if [ -n "$_SCRATCH" ] && [ -e "$_SCRATCH/lg-emitted" ]; then
    # (No trailing newline: read assigns, then returns 1.)
    line=""
    { IFS= read -r line < "$_SCRATCH/lg-emitted"; } 2>/dev/null || true
    case "$line" in 1|2|3) exit "$line" ;; esac
  fi
  if [ "$_LG_FORMAT" = json ]; then
    _lg_verb_json
    verb=$_LG_JS
    if [ ! -e docs/ledger/config.json ] && [ ! -L docs/ledger/config.json ]; then enabled=false; fi
    if [ -n "$payload" ]; then
      line=$(jq -c --argjson verb "$verb" --argjson rc "$rc" --argjson en "$enabled" \
        '{verb: $verb, enabled: $en, exit: $rc} + (. | del(.verb, .enabled, .exit))' "$payload") \
        || _lg_die "jq failed (verdict payload)"
    else
      line=$(jq -nc --argjson verb "$verb" --argjson rc "$rc" --argjson en "$enabled" '{verb: $verb, enabled: $en, exit: $rc}') \
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

# _lg_src_cat <src> <path> <out>: the file <path> as <src> holds it, into
# <out>. <src>: "worktree" (the working copy), ":" (the index, stage 0) or
# a commit id. Returns 1 when <src> has no such file; dies (2) when it has
# one that cannot be read.
_lg_src_cat() {
  local src="$1" p="$2" out="$3" spec
  case "$src" in
    worktree)
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 1; fi
      cat -- "$p" > "$out" 2>/dev/null || _lg_die "cannot read $p"
      ;;
    *)
      # ":0:<path>", not ":<path>": ":/…" and ":!…" are not paths.
      if [ "$src" = : ]; then spec=":0:$p"; else spec="$src:$p"; fi
      git cat-file -e "$spec" 2>/dev/null || return 1
      git cat-file blob "$spec" > "$out" 2>/dev/null \
        || _lg_die "cannot read $p from $(if [ "$src" = : ]; then echo "the index"; else echo "$src"; fi)"
      ;;
  esac
}

# _lg_doc_index [src]: print the path of a private copy of
# docs/.doc-index.json — the working copy's, or as [src] holds it (see
# _lg_src_cat) — shape-checked like _index_load, or of an empty
# {"docs":{}} when there is none. A present but invalid index dies with 2 —
# never _index_load's exit 1, which a ledger verb would report as findings.
# Needs _lg_init.
_lg_doc_index() {
  local src="${1:-worktree}" snap
  snap=$(mktemp "$_SCRATCH/lg-doc-index.XXXXXX") || _lg_die "mktemp failed"
  if ! _lg_src_cat "$src" "$INDEX_FILE" "$snap"; then
    printf '%s\n' '{"docs":{}}' > "$snap" || _lg_die "cannot write $snap"
    printf '%s\n' "$snap"
    return 0
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"' \
      "$snap" >/dev/null 2>&1; then
    _lg_die "$INDEX_FILE is not a valid doc-index (expected one JSON object with a \"docs\" object)"
  fi
  printf '%s\n' "$snap"
}

# _lg_out_file <file>: the file's lines as the run's output (fd 9, as
# _lg_out). A failed write must not change the exit status.
_lg_out_file() {
  if { : >&9; } 2>/dev/null; then
    cat -- "$1" >&9 || true
  else
    cat -- "$1" || true
  fi
}

# _lg_registry_ok <file> [schema]: rc 0 when <file> is one JSON object whose
# "ledgers" (absent: []) is a list of objects — with "schema", its "schema"
# must also be "ledger-registry/1" (init --registry); else rc 1.
_lg_registry_ok() {
  jq -e -s --arg strict "${2:-}" 'length == 1 and (.[0] | type) == "object"
    and ($strict == "" or .[0].schema == "ledger-registry/1")
    and ((.[0].ledgers // []) | type == "array" and all(.[]; type == "object"))' "$1" >/dev/null 2>&1
}

# _lg_registry [src]: print the path of a private copy of
# docs/ledger/ledgers.json — the working copy's, or as [src] holds it (see
# _lg_src_cat) — or of {"schema":"ledger-registry/1","ledgers":[]} when
# there is none. Dies (2) unless the file is one JSON object whose
# "ledgers" (absent: []) is a list of objects — what every reader of the
# registry relies on. Everything else (schema value, ids, statuses, kinds,
# contracts, globs, ownership) is `validate --registry`'s to report. The
# copy always has "ledgers". Needs _lg_init.
_lg_registry() {
  local src="${1:-worktree}" reg=docs/ledger/ledgers.json snap
  snap=$(mktemp "$_SCRATCH/lg-registry.XXXXXX") || _lg_die "mktemp failed"
  if ! _lg_src_cat "$src" "$reg" "$snap.raw"; then
    printf '%s\n' '{"schema":"ledger-registry/1","ledgers":[]}' > "$snap" || _lg_die "cannot write $snap"
    printf '%s\n' "$snap"
    return 0
  fi
  if ! _lg_registry_ok "$snap.raw"; then
    _lg_die "$reg is not a ledger registry (expected one JSON object with a \"ledgers\" list of objects)"
  fi
  jq -c '.ledgers = (.ledgers // [])' "$snap.raw" > "$snap" || _lg_die "jq failed (registry)"
  printf '%s\n' "$snap"
}

# --- Handlers ------------------------------------------------------------------
#
# One per verb-table row (doc-tools.sh "ledger <sub>|cmd_ledger_<sub>|…"),
# each in the module that defines it: show, ls, find, link, note: query.sh.
# new, assign, finalize: keys.sh. view, publish: views.sh. related, sweep,
# recheck: relations.sh. inflight, notices: inflight.sh. validate:
# validate.sh. init: init.sh.

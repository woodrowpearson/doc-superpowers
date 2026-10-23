#!/usr/bin/env bash
# doc-superpowers setup: the entry point of `doc-superpowers setup [flags]`
# (scripts/doc-superpowers runs it as "$BASH" scripts/setup/setup.sh). It acts
# on the repository holding the current directory, at its top level (a linked
# worktree is its own top level); outside a work tree it exits 1.
#
#   --list              print every item: <id>=<value> TAB <scope> TAB <label>
#                       TAB <options> TAB <disabled reason>
#   --set <id>=<value>  change one item (repeatable; --set=<id>=<value> too)
#   --dry-run --yes --apply --build --for-team --link-bin --no-link-bin
#   --plain             not implemented yet (exit 3)
#
# The layers (design §5): lib-model.sh (the catalog, the selection, --set and
# requires) and lib-probe.sh (installer status, the records, what is
# installed). Exit codes: 0 done; 1 refused, nothing written; 2 a step
# failed; 3 usage.
set -euo pipefail
unset CDPATH

# The plugin root: this file's directory's grandparent, taken with a logical
# pwd (as the dispatcher takes its own), so a plugin-cache directory reached
# through a symlink keeps its own path.
_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$_setup_dir")")"

# shellcheck source=scripts/setup/lib-model.sh
source "$ROOT/scripts/setup/lib-model.sh"
# shellcheck source=scripts/setup/lib-probe.sh
source "$ROOT/scripts/setup/lib-probe.sh"

die() {
  echo "setup: $1" >&2
  exit "${2:-1}"
}
usage_error() {
  echo "setup: $1" >&2
  exit 3
}
not_yet() {
  echo "setup: $1: not implemented yet" >&2
  exit 3
}

MODE=""
SETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) MODE=list ;;
    --set)
      [ "$#" -ge 2 ] || usage_error "--set needs <id>=<value>"
      SETS+=("$2")
      shift
      ;;
    --set=*) SETS+=("${1#--set=}") ;;
    --dry-run) not_yet --dry-run ;;
    --yes) not_yet --yes ;;
    --apply) not_yet --apply ;;
    --build) not_yet --build ;;
    --for-team) not_yet --for-team ;;
    --link-bin) not_yet --link-bin ;;
    --no-link-bin) not_yet --no-link-bin ;;
    --plain) not_yet --plain ;;
    *) usage_error "unknown flag '$1' (doc-superpowers help setup lists the flags)" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is needed (1.6 or later); nothing was changed"
model_load_catalog "$ROOT/scripts/setup/catalog.json" || die "$MODEL_ERROR" 2

# Every --set is checked against the catalog before anything is read.
for _s in ${SETS[@]+"${SETS[@]}"}; do
  case "$_s" in
    *=*) ;;
    *) usage_error "--set $_s: expected <id>=<value>" ;;
  esac
  model_check "${_s%%=*}" "${_s#*=}" || usage_error "--set $_s: $MODEL_ERROR"
done

[ "$MODE" = list ] || not_yet "interactive mode"

_top=$(git rev-parse --show-toplevel 2>/dev/null) || _top=""
[ -n "$_top" ] || die "not a git repository (run setup inside a repository's work tree)"
cd "$_top"

probe_run || die "$PROBE_ERROR"
[ -z "$PROBE_RECORD_ERROR" ] || die "$PROBE_RECORD_ERROR; nothing was changed"
model_base_init || die "$MODEL_ERROR; nothing was changed"
for _s in ${SETS[@]+"${SETS[@]}"}; do
  model_set "${_s%%=*}" "${_s#*=}" || die "--set $_s: $MODEL_ERROR"
done

# --list: one line per item, in catalog order. A reason is one line.
_i=0
while [ "$_i" -lt "$CAT_N" ]; do
  _reason="${DISABLED[_i]//$'\t'/ }"
  _reason="${_reason//$'\n'/ }"
  printf '%s=%s\t%s\t%s\t%s\t%s\n' "${CAT_ID[_i]}" "${SEL[_i]}" "${CAT_SCOPE[_i]}" "${CAT_LABEL[_i]}" \
    "${CAT_OPTIONS[_i]}" "$_reason"
  _i=$((_i + 1))
done

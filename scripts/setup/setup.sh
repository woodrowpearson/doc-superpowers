#!/usr/bin/env bash
# doc-superpowers setup: the entry point of `doc-superpowers setup [flags]`
# (scripts/doc-superpowers runs it as "$BASH" scripts/setup/setup.sh). It acts
# on the repository holding the current directory, at its top level (a linked
# worktree is its own top level); outside a work tree it exits 1.
#
#   --list              print every item: <id>=<value> TAB <scope> TAB <label>
#                       TAB <options> TAB <disabled reason>
#   --set <id>=<value>  change one item (repeatable; --set=<id>=<value> too)
#   --dry-run           print the summary, a blank line, then the review (the
#                       plan's steps, what they write, the network, the
#                       downloads, the git add line); write nothing; exit 0
#   --yes               apply the selection (the base and --set) without
#                       asking: the plan's steps, as the review lists them,
#                       then the git add line of the team's paths that
#                       changed, or "nothing to do". Write only: nothing
#                       downloads
#   --build             with --dry-run: the review includes the build
#   --for-team          with --dry-run: the per-user values are the team's
#   --apply --link-bin --no-link-bin --plain, and --build or --for-team
#                       without --dry-run: not implemented yet (exit 3)
# --list, --dry-run and --yes are modes: one at a time.
#
# The layers (design §5): lib-model.sh (the catalog, the selection, --set and
# requires), lib-probe.sh (installer status, the records, what is installed),
# lib-plan.sh (the selection against what is installed: the steps, the
# summary and the review) and lib-exec.sh (running the steps). Exit codes: 0
# done, or nothing to do; 1 refused, nothing written; 2 a step failed (the
# steps that ran are listed; re-running finishes the job); 3 usage.
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
# shellcheck source=scripts/setup/lib-plan.sh
source "$ROOT/scripts/setup/lib-plan.sh"
# shellcheck source=scripts/setup/lib-exec.sh
source "$ROOT/scripts/setup/lib-exec.sh"

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
BUILD=0
FOR_TEAM=0
SETS=()
# set_mode <mode>: one mode per run (--dry-run --yes would otherwise write).
set_mode() {
  [ -z "$MODE" ] || [ "$MODE" = "$1" ] || usage_error "--$MODE and --$1 cannot be used together"
  MODE="$1"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) set_mode list ;;
    --set)
      [ "$#" -ge 2 ] || usage_error "--set needs <id>=<value>"
      SETS+=("$2")
      shift
      ;;
    --set=*) SETS+=("${1#--set=}") ;;
    --dry-run) set_mode dry-run ;;
    --yes) set_mode yes ;;
    --apply) not_yet --apply ;;
    --build) BUILD=1 ;;
    --for-team) FOR_TEAM=1 ;;
    --link-bin) not_yet --link-bin ;;
    --no-link-bin) not_yet --no-link-bin ;;
    --plain) not_yet --plain ;;
    *) usage_error "unknown flag '$1' (doc-superpowers help setup lists the flags)" ;;
  esac
  shift
done
# --build is the download consent of --yes and --apply (later tasks); with
# --dry-run it shows the build in the review.
[ "$BUILD" = 0 ] || [ "$MODE" = dry-run ] || not_yet --build
# --for-team makes the per-user values the team's (the --yes flow is a later
# task's); with --dry-run the review shows that plan.
[ "$FOR_TEAM" = 0 ] || [ "$MODE" = dry-run ] || not_yet --for-team

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

case "$MODE" in
  list | dry-run | yes) ;;
  *) not_yet "interactive mode" ;;
esac

_top=$(git rev-parse --show-toplevel 2>/dev/null) || _top=""
[ -n "$_top" ] || die "not a git repository (run setup inside a repository's work tree)"
cd "$_top"

probe_run || die "$PROBE_ERROR"
[ -z "$PROBE_RECORD_ERROR" ] || die "$PROBE_RECORD_ERROR; nothing was changed"
model_base_init || die "$MODEL_ERROR; nothing was changed"
for _s in ${SETS[@]+"${SETS[@]}"}; do
  model_set "${_s%%=*}" "${_s#*=}" || die "--set $_s: $MODEL_ERROR"
done

# --dry-run: the summary, a blank line, the review; nothing written.
if [ "$MODE" = dry-run ]; then
  PLAN_BUILD_REQUESTED="$BUILD"
  PLAN_FOR_TEAM="$FOR_TEAM"
  plan_build || die "$PLAN_ERROR; nothing was changed"
  plan_render_summary
  echo ""
  plan_render_review
  if plan_is_empty; then echo "nothing to do"; fi
  exit 0
fi

# --yes: the plan's steps (Write only), then the git add line.
if [ "$MODE" = yes ]; then
  PLAN_BUILD_REQUESTED=0
  PLAN_FOR_TEAM=0
  plan_build || die "$PLAN_ERROR; nothing was changed"
  _rc=0
  exec_plan || _rc=$?
  exit "$_rc"
fi

# --list: one line per item, in catalog order. A reason is one line.
_i=0
while [ "$_i" -lt "$CAT_N" ]; do
  _reason="${DISABLED[_i]//$'\t'/ }"
  _reason="${_reason//$'\n'/ }"
  printf '%s=%s\t%s\t%s\t%s\t%s\n' "${CAT_ID[_i]}" "${SEL[_i]}" "${CAT_SCOPE[_i]}" "${CAT_LABEL[_i]}" \
    "${CAT_OPTIONS[_i]}" "$_reason"
  _i=$((_i + 1))
done

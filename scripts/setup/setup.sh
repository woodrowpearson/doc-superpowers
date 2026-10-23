#!/usr/bin/env bash
# doc-superpowers setup: the entry point of `doc-superpowers setup [flags]`
# (scripts/doc-superpowers runs it as "$BASH" scripts/setup/setup.sh). It acts
# on the repository holding the current directory, at its top level (a linked
# worktree is its own top level); outside a work tree it exits 1.
#
#   --list              print every item: <id>=<value> TAB <scope> TAB <label>
#                       TAB <options> TAB <disabled reason: the host's, for an
#                       item ("<reason>") or for an option ("<option>:
#                       <reason>"), or "(locked: <reason>)" for the ledger and
#                       spec claims while their switch exists> TAB <hint>
#   --set <id>=<value>  change one item (repeatable; --set=<id>=<value> too)
#   --dry-run           print the summary, a blank line, then the review (the
#                       plan's steps, what they write, the network, the
#                       downloads, the git add line); write nothing; exit 0
#   --yes               apply the selection (the base and --set) without
#                       asking: the plan's steps, as the review lists them,
#                       then the git add line of the team's paths that
#                       changed, or "nothing to do". Write only: nothing
#                       downloads
#   --apply             reproduce the recorded team setup (the team record,
#                       your local overrides, .tiers.ci's workflows and
#                       choices) without asking: the per-user installs and
#                       any missing team file; never the team record. Exit 1
#                       with "no team setup recorded: run doc-superpowers
#                       setup" when installed.json has no .setup (a CI-only
#                       record included). An item this host's checks disable
#                       is skipped: "skipped: <id>: <reason>", printed last,
#                       and the run still exits 0. The writes outside the
#                       repository are listed under "Local to you (outside
#                       the repository):". With --dry-run: what --apply
#                       would do, nothing written. Takes no --set and no
#                       --for-team (exit 3)
#   --build             the download consent: with --yes or --apply,
#                       doc-search's first index build runs last (through
#                       uv; refused with exit 1, nothing written, when the
#                       host has no uv); with --dry-run, the review includes
#                       it
#   --for-team          with --dry-run or --yes: the per-user values (git,
#                       claude, the ledger's hook sets) this run sets are the
#                       team's, in the team record (any other override of
#                       yours stays yours); without it, once a team record
#                       exists, they are yours (installed.local.json)
#   --link-bin --no-link-bin --plain, and --build or --for-team with no mode
#   (the interactive UI): not implemented yet (exit 3)
# --list, --dry-run, --yes and --apply are modes: one at a time, except
# --apply --dry-run.
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
APPLY=0
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
    --apply) APPLY=1 ;;
    --build) BUILD=1 ;;
    --for-team) FOR_TEAM=1 ;;
    --link-bin) not_yet --link-bin ;;
    --no-link-bin) not_yet --no-link-bin ;;
    --plain) not_yet --plain ;;
    *) usage_error "unknown flag '$1' (doc-superpowers help setup lists the flags)" ;;
  esac
  shift
done
# --apply: the recorded setup as it is, so no --set and no --for-team; a
# mode of its own, which --dry-run previews.
if [ "$APPLY" = 1 ]; then
  [ "${#SETS[@]}" -eq 0 ] || usage_error "--apply reproduces the recorded team setup: it takes no --set (run setup --yes --set … to change it)"
  [ "$FOR_TEAM" = 0 ] || usage_error "--apply never changes the team record: it takes no --for-team"
  case "$MODE" in
    "") MODE=apply ;;
    dry-run) ;;
    *) usage_error "--apply and --$MODE cannot be used together" ;;
  esac
fi
# --build is the download consent of --yes and --apply; with --dry-run it
# shows the build in the review.
case "$MODE" in
  dry-run | yes | apply) ;;
  *) [ "$BUILD" = 0 ] || not_yet --build ;;
esac
# --for-team makes the per-user values the team's (--yes), or shows that
# plan (--dry-run).
case "$MODE" in
  dry-run | yes) ;;
  list) [ "$FOR_TEAM" = 0 ] || usage_error "--for-team does not apply to --list" ;;
  *) [ "$FOR_TEAM" = 0 ] || not_yet --for-team ;;
esac

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
  list | dry-run | yes | apply) ;;
  *) not_yet "interactive mode" ;;
esac

_top=$(git rev-parse --show-toplevel 2>/dev/null) || _top=""
[ -n "$_top" ] || die "not a git repository (run setup inside a repository's work tree)"
cd "$_top"

probe_run || die "$PROBE_ERROR"
[ -z "$PROBE_RECORD_ERROR" ] || die "$PROBE_RECORD_ERROR; nothing was changed"
# --apply reproduces a recorded team setup: a CI-only record holds none.
[ "$APPLY" = 0 ] || [ -n "$PROBE_TEAM" ] || die "no team setup recorded: run doc-superpowers setup"
model_base_init || die "$MODEL_ERROR; nothing was changed"
for _s in ${SETS[@]+"${SETS[@]}"}; do
  model_set "${_s%%=*}" "${_s#*=}" || die "--set $_s: $MODEL_ERROR"
done
# The items this host's checks disable: with --apply, skipped (left as they
# are); otherwise the options the base fell back from (a hooks mode this host
# cannot offer), listed with the reason; named last.
if [ "$APPLY" = 1 ]; then model_apply_skips; else model_host_skips; fi
print_skipped() {
  local e
  for e in ${MODEL_SKIPPED[@]+"${MODEL_SKIPPED[@]}"}; do
    printf 'skipped: %s: %s\n' "${e%%$'\t'*}" "${e#*$'\t'}"
  done
}
PLAN_APPLY="$APPLY"
# --for-team promotes the per-user values this run names, not every one.
PLAN_FOR_TEAM_IDS=""
for _s in ${SETS[@]+"${SETS[@]}"}; do PLAN_FOR_TEAM_IDS="$PLAN_FOR_TEAM_IDS ${_s%%=*}"; done

# --dry-run: the summary, a blank line, the review; nothing written.
if [ "$MODE" = dry-run ]; then
  PLAN_BUILD_REQUESTED="$BUILD"
  PLAN_FOR_TEAM="$FOR_TEAM"
  plan_build || die "$PLAN_ERROR; nothing was changed"
  plan_render_summary
  echo ""
  plan_render_review
  if plan_is_empty; then echo "nothing to do"; fi
  # The summary says why an option is off here; --apply names what it skipped.
  if [ "$APPLY" = 1 ]; then print_skipped; fi
  exit 0
fi

# --yes and --apply: the plan's steps (Write only; with --build, the build
# last), then the git add line (--apply: the writes outside the repository
# first, and the skipped items last).
if [ "$MODE" = yes ] || [ "$MODE" = apply ]; then
  PLAN_BUILD_REQUESTED="$BUILD"
  PLAN_FOR_TEAM="$FOR_TEAM"
  plan_build || die "$PLAN_ERROR; nothing was changed"
  EXEC_SHOW_OUTSIDE="$APPLY"
  _rc=0
  exec_plan || _rc=$?
  [ "$_rc" = 1 ] || print_skipped
  exit "$_rc"
fi

# --list: one line per item, in catalog order. A reason is one line.
_i=0
while [ "$_i" -lt "$CAT_N" ]; do
  _reason="${DISABLED[_i]}"
  if [ -z "$_reason" ] && [ -n "$DISABLED_OPT" ]; then
    while IFS= read -r _line; do
      case "$_line" in
        "${CAT_ID[_i]}="*)
          _line="${_line#*=}"
          _reason="${_reason:+$_reason; }${_line%%$'\t'*}: ${_line#*$'\t'}"
          ;;
      esac
    done <<<"$DISABLED_OPT"
  fi
  [ -n "$_reason" ] || [ -z "${LOCKED[_i]}" ] || _reason="(locked: ${LOCKED[_i]})"
  _reason="${_reason//$'\t'/ }"
  _reason="${_reason//$'\n'/ }"
  _hint="${HINT[_i]//$'\t'/ }"
  _hint="${_hint//$'\n'/ }"
  printf '%s=%s\t%s\t%s\t%s\t%s\t%s\n' "${CAT_ID[_i]}" "${SEL[_i]}" "${CAT_SCOPE[_i]}" "${CAT_LABEL[_i]}" \
    "${CAT_OPTIONS[_i]}" "$_reason" "$_hint"
  _i=$((_i + 1))
done

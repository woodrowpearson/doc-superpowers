#!/usr/bin/env bash
# doc-superpowers setup: the executor. Sourced by setup.sh after lib-plan.sh;
# probe_run, model_base_init and plan_build run first. ROOT is the plugin
# root, TOP the repository top.
#
# exec_plan runs PLAN (lib-plan.sh's steps, in its order) from TOP: each op
# line "<op>TAB<field>…" runs as op_<op with - as _> <field>…. Before the
# first step it checks every step, and refuses (returns 1, one line on
# stderr, nothing written) when:
#   - a step has no op_ function yet: "setup: <op>: not implemented yet";
#   - a step's opcheck_ function refuses (EXEC_ERROR says why): a file setup
#     writes itself is a symbolic link or is reached through one;
#   - a path the review lists as committed for the team or local to you
#     (W_TEAM, W_LOCAL: the installer's too) is a symbolic link or is reached
#     through one. The installer would refuse it as well, but only at its
#     own step, after the steps before it had run.
# Then it runs the steps, printing "<n>. <the review's text>" before each;
# the installer's own output passes through. A step that fails stops the run:
# "setup: step <n> (<op>) failed; done: <ops>; re-run to finish" on stderr,
# return 2 (each step is idempotent: a re-run plans and finishes the rest).
# At the end: "Then commit:" and the git add line of the team's paths the run
# changed (W_TEAM, those whose content changed), or "  (nothing)". An empty
# plan prints "nothing to do" and returns 0.
#
# The steps (Tasks 5-7 add the rest of lib-plan.sh's ops):
#   git-install <hooks|merge-driver>    install --git [--merge-driver-only]
#   git-uninstall <hooks|merge-driver>  uninstall --git [--merge-driver-only]
#   claude-install / claude-uninstall   install / uninstall --claude
#   exclude-local                       setup's own block in git's info/exclude
#   record-team                         installed.json's .setup = PLAN_TEAM_SETUP
#   record-local                        installed.local.json = PLAN_LOCAL_RECORD
# The installer runs as "$BASH" install.sh, under the interpreter running
# setup, with stdin from /dev/null. A file setup writes itself goes through
# _exec_write: a temp file beside it, then mv; never through a symbolic link;
# not at all when its content would not change (its mtime is kept).

EXEC_ERROR=""
EXEC_WROTE=0
_EXEC_TMP="" _EXEC_N=0 _EXEC_OP="" _EXEC_DONE=""

# _exec_installer <args…>: install.sh, under the interpreter running setup.
_exec_installer() {
  "$BASH" "$ROOT/scripts/hooks/install.sh" "$@" </dev/null
}

# _exec_file_mode <file>: its permission bits (GNU stat, then BSD stat).
_exec_file_mode() {
  local m=""
  m=$(stat -c '%a' "$1" 2>/dev/null) || m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=""
  case "$m" in
    [0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) printf '%s' "$m" ;;
    *) return 1 ;;
  esac
}

# _exec_no_link <path>: neither <path> nor a directory on its way from the top
# is a symbolic link (a path relative to TOP, or under it; an absolute path
# elsewhere, git's own in a linked worktree: the file and its directory). Else
# EXEC_ERROR says which, and it returns 1.
_exec_no_link() {
  local p="$1" stop=""
  case "$p" in
    "$TOP"/*) p="${p#"$TOP"/}" ;;
    /*)
      stop="${p%/*}"
      stop="${stop%/*}"
      ;;
  esac
  while [ -n "$p" ] && [ "$p" != "$stop" ] && [ "$p" != / ] && [ "$p" != . ]; do
    if [ -L "$p" ]; then
      EXEC_ERROR="$p is a symbolic link$([ "$p" = "$1" ] || printf ' (on the way to %s)' "$1"): setup never writes through a link, which could point anywhere"
      return 1
    fi
    case "$p" in
      */*) p="${p%/*}" ;;
      *) p="" ;;
    esac
  done
  return 0
}

# _exec_writable <path>: setup may write <path> itself: no link on its way
# (_exec_no_link), and a regular file or nothing.
_exec_writable() {
  _exec_no_link "$1" || return 1
  if [ -e "$1" ] && [ ! -f "$1" ]; then
    EXEC_ERROR="$1 is not a regular file"
    return 1
  fi
  return 0
}

# _exec_write <path> <content>: <path> holds <content> and a newline: a temp
# file beside it, then mv (an existing file keeps its mode, a new one is
# 644); refused through a link; skipped when the content is the same.
# EXEC_WROTE is 1 when it wrote.
# shellcheck disable=SC2034  # EXEC_WROTE is the writers' interface, read by their callers
_exec_write() {
  local f="$1" dir mode=644 m
  EXEC_WROTE=0
  if ! _exec_writable "$f"; then
    echo "setup: $EXEC_ERROR" >&2
    return 1
  fi
  if [ -f "$f" ] && printf '%s\n' "$2" | cmp -s - "$f"; then
    return 0
  fi
  dir=$(dirname "$f")
  if ! mkdir -p "$dir"; then
    echo "setup: cannot create $dir" >&2
    return 1
  fi
  if [ -f "$f" ] && m=$(_exec_file_mode "$f"); then mode="$m"; fi
  if ! _EXEC_TMP=$(mktemp "$dir/.${f##*/}.XXXXXX"); then
    _EXEC_TMP=""
    echo "setup: cannot create a temp file beside $f" >&2
    return 1
  fi
  if printf '%s\n' "$2" > "$_EXEC_TMP" && chmod "$mode" "$_EXEC_TMP" && mv -f "$_EXEC_TMP" "$f"; then
    _EXEC_TMP=""
    EXEC_WROTE=1
    return 0
  fi
  rm -f "$_EXEC_TMP"
  _EXEC_TMP=""
  echo "setup: cannot write $f" >&2
  return 1
}

# _exec_exclude_file: git's info/exclude for this work tree (relative to TOP,
# or absolute in a linked worktree).
_exec_exclude_file() {
  git rev-parse --git-path info/exclude 2>/dev/null
}

# --- The installer's steps --------------------------------------------------------

op_git_install() {
  case "$1" in
    hooks) _exec_installer install --git ;;
    merge-driver) _exec_installer install --git --merge-driver-only ;;
    *)
      echo "setup: git-install: unknown mode '$1'" >&2
      return 1
      ;;
  esac
}

# uninstall --git removes the hooks and the merge driver; --merge-driver-only
# the driver alone.
op_git_uninstall() {
  case "$1" in
    hooks) _exec_installer uninstall --git ;;
    merge-driver) _exec_installer uninstall --git --merge-driver-only ;;
    *)
      echo "setup: git-uninstall: unknown mode '$1'" >&2
      return 1
      ;;
  esac
}

op_claude_install() {
  _exec_installer install --claude
}

op_claude_uninstall() {
  _exec_installer uninstall --claude
}

# --- The files setup writes itself ------------------------------------------------

# exclude-local: the local record kept out of git by setup's own block in
# git's info/exclude, "# doc-superpowers setup:begin" … ":end" around its
# path. Not the Claude tier's "# doc-superpowers:begin" block, which install
# --claude rewrites whole and uninstall --claude removes: a line there would
# go with it. Appended once, after the file's own lines.
opcheck_exclude_local() {
  local f
  if ! f=$(_exec_exclude_file) || [ -z "$f" ]; then
    EXEC_ERROR="git rev-parse --git-path info/exclude failed"
    return 1
  fi
  _exec_writable "$f"
}
op_exclude_local() {
  local f cur="" sep=""
  if ! f=$(_exec_exclude_file) || [ -z "$f" ]; then
    echo "setup: git rev-parse --git-path info/exclude failed" >&2
    return 1
  fi
  if [ -f "$f" ]; then
    if grep -qxF "$PLAN_EXCLUDE_BEGIN" "$f"; then return 0; fi
    # Its bytes as they are, trailing newlines included.
    cur=$(cat "$f" && printf x) || return 1
    cur="${cur%x}"
    case "$cur" in
      "" | *$'\n') ;;
      *) sep=$'\n' ;;
    esac
  fi
  _exec_write "$f" "$cur$sep$PLAN_EXCLUDE_BEGIN
$PROBE_LOCAL_FILE
$PLAN_EXCLUDE_END"
}

# record-team: installed.json's .setup becomes PLAN_TEAM_SETUP, set with jq
# in the current file: every other key kept as it is (.tiers.ci, written by
# install --ci, and schema_version among them), in jq's layout, the
# installer's own. A new file is {"schema_version": 2, "setup": …}.
opcheck_record_team() {
  _exec_writable "$PROBE_STATE_FILE"
}
op_record_team() {
  local f="$PROBE_STATE_FILE" new
  if ! _exec_writable "$f"; then
    echo "setup: $EXEC_ERROR" >&2
    return 1
  fi
  if [ -e "$f" ]; then
    new=$(jq --argjson s "$PLAN_TEAM_SETUP" '.setup = $s' "$f") || {
      echo "setup: cannot update $f" >&2
      return 1
    }
  else
    new=$(jq -n --argjson s "$PLAN_TEAM_SETUP" '{schema_version: 2, setup: $s}') || {
      echo "setup: cannot build $f" >&2
      return 1
    }
  fi
  _exec_write "$f" "$new"
}

# record-local: installed.local.json becomes PLAN_LOCAL_RECORD (the plan
# merged it with the current file), in jq's layout.
opcheck_record_local() {
  _exec_writable "$PROBE_LOCAL_FILE"
}
op_record_local() {
  local new
  new=$(jq . <<<"$PLAN_LOCAL_RECORD") || {
    echo "setup: cannot build $PROBE_LOCAL_FILE" >&2
    return 1
  }
  _exec_write "$PROBE_LOCAL_FILE" "$new"
}

# --- The run ----------------------------------------------------------------------

# _exec_fp <path>: a line that changes when the path's content does (a
# directory: every file and link under it).
_exec_fp() {
  if [ -L "$1" ]; then
    printf 'L %s\n' "$(readlink "$1")"
  elif [ -d "$1" ]; then
    find "$1" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
    find "$1" -type l -print 2>/dev/null | LC_ALL=C sort
  elif [ -f "$1" ]; then
    printf 'F %s %s\n' "$(cksum <"$1")" "$([ ! -x "$1" ] || echo x)"
  else
    echo -
  fi
}

# _exec_op_fields <op line>: _EXEC_F, the line's fields (TAB-separated).
_exec_op_fields() {
  _EXEC_F=()
  IFS="$_PLAN_T" read -r -a _EXEC_F <<<"$1"
}

_exec_interrupted() {
  [ -z "$_EXEC_TMP" ] || rm -f "$_EXEC_TMP"
  trap - INT TERM
  echo "" >&2
  echo "setup: interrupted at step $_EXEC_N ($_EXEC_OP); done: ${_EXEC_DONE:-nothing}; re-run to finish" >&2
  exit "$1"
}

# exec_plan: run PLAN (see the top of this file). Returns 0 (done, or nothing
# to do), 1 (refused before the first step: nothing written) or 2 (a step
# failed).
exec_plan() {
  local line op fn e p i paths="" all=""
  local -a fps
  if ! cd "$TOP"; then
    echo "setup: cannot enter $TOP; nothing was changed" >&2
    return 1
  fi
  if plan_is_empty; then
    echo "nothing to do"
    return 0
  fi
  # Every step, before the first one runs.
  for line in "${PLAN[@]}"; do
    _exec_op_fields "$line"
    op="${_EXEC_F[0]}"
    if ! declare -F "op_${op//-/_}" >/dev/null; then
      echo "setup: $op: not implemented yet" >&2
      return 1
    fi
    fn="opcheck_${op//-/_}"
    if declare -F "$fn" >/dev/null && ! "$fn" "${_EXEC_F[@]:1}"; then
      echo "setup: $EXEC_ERROR; nothing was changed" >&2
      return 1
    fi
  done
  # Every path a step writes in the repository or in git's directory, as the
  # review lists it (a directory as itself): the installer refuses a link
  # too, but only at its own step, after the earlier steps have run.
  for e in ${W_TEAM[@]+"${W_TEAM[@]}"} ${W_LOCAL[@]+"${W_LOCAL[@]}"}; do
    p="${e%%"$_PLAN_T"*}"
    [ "$p" = / ] || p="${p%/}"
    if ! _exec_no_link "$p"; then
      echo "setup: $EXEC_ERROR; nothing was changed" >&2
      return 1
    fi
  done
  # The team's paths as they are now: the git add line names those that change.
  fps=()
  for e in ${W_TEAM[@]+"${W_TEAM[@]}"}; do
    fps+=("$(_exec_fp "${e%%"$_PLAN_T"*}")")
  done

  _EXEC_N=0 _EXEC_OP="" _EXEC_DONE=""
  trap '_exec_interrupted 130' INT
  trap '_exec_interrupted 143' TERM
  for line in "${PLAN[@]}"; do
    _exec_op_fields "$line"
    op="${_EXEC_F[0]}"
    _EXEC_N=$((_EXEC_N + 1))
    _EXEC_OP="$op"
    printf '%d. %s\n' "$_EXEC_N" "$(_plan_op_text "$line")"
    if ! "op_${op//-/_}" "${_EXEC_F[@]:1}"; then
      trap - INT TERM
      echo "setup: step $_EXEC_N ($op) failed; done: ${_EXEC_DONE:-nothing}; re-run to finish" >&2
      return 2
    fi
    _EXEC_DONE="${_EXEC_DONE:+$_EXEC_DONE, }$op"
  done
  trap - INT TERM

  # The git add line, as the review prints it: a path that is gone goes on it
  # only when git tracks it (then -A stages the deletion).
  i=0
  for e in ${W_TEAM[@]+"${W_TEAM[@]}"}; do
    p="${e%%"$_PLAN_T"*}"
    if [ "$(_exec_fp "$p")" != "${fps[i]}" ]; then
      if [ -e "$p" ] || [ -L "$p" ]; then
        paths="$paths $(_plan_shell_word "$p")"
      elif git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
        paths="$paths $(_plan_shell_word "$p")"
        all=" -A"
      fi
    fi
    i=$((i + 1))
  done
  echo ""
  echo "Then commit:"
  if [ -z "$paths" ]; then
    echo "  (nothing)"
  else
    printf '  git add%s --%s\n' "$all" "$paths"
  fi
  return 0
}

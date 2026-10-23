#!/usr/bin/env bash
# doc-superpowers setup: the plain-prompt UI (design §5.6). Sourced by
# setup.sh after lib-exec.sh; probe_run, model_base_init and any --set run
# first. Used when stdin or stdout is not a TTY, when TERM is dumb, or with
# --plain: numbered line prompts over the same model the TUI uses.
#
# prompt_run reads its answers from fd 3, one line each (setup.sh runs it as
# `prompt_run 3<&0 </dev/null`, so no command it starts can read an answer),
# changes SEL through model_set only, and sets PROMPT_RESULT:
#   write  "Write only": setup.sh plans and runs the steps
#   build  "Write and build", confirmed: the same, with the build last
#   quit   q, or the end of input at any prompt: nothing is written
# PLAN_FOR_TEAM and PLAN_FOR_TEAM_IDS hold the answer to the per-user
# question for setup.sh's plan_build. It writes no file.
#
# The screens:
#   summary   plan_render_summary, then "[a]pply  [c]ustomize  [s]how details
#             [q]uit": a opens the review, c the groups, s prints help setup
#   groups    the groups, numbered in GROUPS order (plan_group_line); a
#             number opens one
#   items     a group's items, numbered in catalog order, as
#             "n) [x] <label>[: <value>] -- <scope>", then " (changed)",
#             " (locked)" or " (off here)": a number toggles a toggle, or
#             asks for a choice, a multi's options or a value; "d <n>" shows
#             the item's details, scope, writes, undo and reasons
#   review    with a team record and a per-user item changed, first "Save
#             the per-user changes for: [y]ou only  [t]he team" (default y);
#             then plan_render_review and "[w]rite and build  [o] write only
#             [b]ack" (w only when something builds); w asks "This downloads
#             <what>. Continue? [y/N]" (n, or an empty answer: write only)
# An empty line goes up one level. A refusal of the model (a locked or
# disabled item, an invalid value) prints its reason; a value is asked again.

PROMPT_RESULT=""
_PR_LINE="" _PR_NEXT="" _PR_EOF=0 _PR_GROUP="" _PR_N=""

# _prompt_read [prompt]: _PR_LINE, the next answer (fd 3), spaces around it
# and a CR dropped; the prompt is "> " unless given. Returns 1 at the end of
# input (a last line without a newline is still an answer).
_prompt_read() {
  local s=""
  printf '%s' "${1:-> }"
  if [ "$_PR_EOF" = 1 ]; then
    echo ""
    return 1
  fi
  if ! IFS= read -r s <&3; then
    _PR_EOF=1
    if [ -z "$s" ]; then
      echo ""
      return 1
    fi
  fi
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  _PR_LINE="$s"
  return 0
}

# _prompt_number <answer> <max>: the answer is a number from 1 to <max>;
# _PR_N is its value in decimal. Leading zeros are dropped first (bash
# reads 08 as octal in an index), and an answer longer than <max> is refused
# before any numeric test (no "integer expression expected" for a huge one).
_prompt_number() {
  local v
  _PR_N=""
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
  esac
  v="${1#"${1%%[!0]*}"}"
  [ -n "$v" ] && [ "${#v}" -le "${#2}" ] || return 1
  [ "$v" -ge 1 ] && [ "$v" -le "$2" ] || return 1
  _PR_N="$v"
}

# _prompt_item_line <n> <i>: "  n) [x] <label>[: <value>] -- <scope>" and
# its marks (plan_item_box, plan_item_marks).
_prompt_item_line() {
  local i="$2" line
  plan_item_box "$i"
  plan_item_marks "$i"
  line="  $1) $PLAN_BOX ${CAT_LABEL[i]}"
  [ "${CAT_KIND[i]}" = toggle ] || line="$line: ${SEL[i]}"
  printf '%s -- %s%s\n' "$line" "$(plan_scope_text "$i")" "$PLAN_MARKS"
}

# _prompt_set <id> <value>: model_set, or its reason printed. Returns its rc.
_prompt_set() {
  model_set "$1" "$2" && return 0
  printf '  %s\n' "$MODEL_ERROR"
  return 1
}

# _prompt_multi <i>: a multi's options, ticked and unticked by number.
_prompt_multi() {
  local i="$1" n o opts
  while :; do
    echo ""
    printf '%s: a number ticks or unticks one; an empty line goes back.\n' "${CAT_LABEL[i]}"
    n=0
    for o in ${CAT_OPTIONS[i]//,/ }; do
      n=$((n + 1))
      if _model_csv_has "${SEL[i]}" "$o"; then printf '  %d) [x] %s' "$n" "$o"; else printf '  %d) [ ] %s' "$n" "$o"; fi
      if model_option_disabled "${CAT_ID[i]}" "$o"; then printf ' (off here)'; fi
      echo ""
    done
    _prompt_read || return 1
    [ -n "$_PR_LINE" ] || return 0
    if ! _prompt_number "$_PR_LINE" "$n"; then
      printf '  answer a number from 1 to %d, or an empty line\n' "$n"
      continue
    fi
    opts=()
    for o in ${CAT_OPTIONS[i]//,/ }; do opts+=("$o"); done
    plan_multi_toggle "$i" "${opts[_PR_N - 1]}"
    _prompt_set "${CAT_ID[i]}" "$PLAN_VALUE" || true
  done
}

# _prompt_choice <i>: one of a choice's options, by number; an empty line
# keeps the current one.
_prompt_choice() {
  local i="$1" n o opts
  while :; do
    echo ""
    printf '%s: a number chooses one; an empty line keeps %s.\n' "${CAT_LABEL[i]}" "${SEL[i]}"
    n=0 opts=()
    for o in ${CAT_OPTIONS[i]//,/ }; do
      n=$((n + 1))
      opts+=("$o")
      if [ "${SEL[i]}" = "$o" ]; then printf '  %d) (*) %s' "$n" "$o"; else printf '  %d) ( ) %s' "$n" "$o"; fi
      if model_option_disabled "${CAT_ID[i]}" "$o"; then printf ' (off here)'; fi
      echo ""
    done
    _prompt_read || return 1
    [ -n "$_PR_LINE" ] || return 0
    if ! _prompt_number "$_PR_LINE" "$n"; then
      printf '  answer a number from 1 to %d, or an empty line\n' "$n"
      continue
    fi
    _prompt_set "${CAT_ID[i]}" "${opts[_PR_N - 1]}" && return 0
  done
}

# _prompt_value <i>: a value item, read as a line; an invalid one says why
# and is asked again; an empty line keeps the current value.
_prompt_value() {
  local i="$1"
  echo ""
  printf '%s (%s; now %s): type a value, or an empty line to keep it.\n' \
    "${CAT_LABEL[i]}" "${CAT_OPTIONS[i]//,/ or }" "${SEL[i]}"
  while :; do
    _prompt_read || return 1
    [ -n "$_PR_LINE" ] || return 0
    _prompt_set "${CAT_ID[i]}" "$_PR_LINE" && return 0
  done
}

# _prompt_item <i>: act on a chosen item.
_prompt_item() {
  local i="$1" v=on
  case "${CAT_KIND[i]}" in
    toggle)
      [ "${SEL[i]}" != on ] || v=off
      _prompt_set "${CAT_ID[i]}" "$v" || true
      ;;
    multi) _prompt_multi "$i" || return 1 ;;
    choice) _prompt_choice "$i" || return 1 ;;
    *) _prompt_value "$i" || return 1 ;;
  esac
  return 0
}

_prompt_summary() {
  plan_build_preview
  echo ""
  plan_render_summary
  echo ""
  echo "[a]pply  [c]ustomize  [s]how details  [q]uit"
  while :; do
    _prompt_read || return 1
    case "$_PR_LINE" in
      a | A) _PR_NEXT=review ;;
      c | C) _PR_NEXT=groups ;;
      s | S)
        echo ""
        cat "$ROOT/scripts/help/setup.txt"
        _PR_NEXT=summary
        ;;
      q | Q) _PR_NEXT=quit ;;
      "") continue ;;
      *)
        echo "  answer a, c, s or q"
        continue
        ;;
    esac
    return 0
  done
}

_prompt_groups() {
  local g n
  plan_build_preview
  echo ""
  echo "Customize: a number opens a group; an empty line goes back."
  n=0
  for g in "${GROUPS[@]}"; do
    n=$((n + 1))
    plan_group_line "$g" || continue
    printf '  %d) %s\n' "$n" "$PLAN_GROUP_LINE"
  done
  while :; do
    _prompt_read || return 1
    if [ -z "$_PR_LINE" ]; then
      _PR_NEXT=summary
      return 0
    fi
    if _prompt_number "$_PR_LINE" "${#GROUPS[@]}"; then
      _PR_GROUP="${GROUPS[_PR_N - 1]}"
      _PR_NEXT=items
      return 0
    fi
    printf '  answer a group number from 1 to %d, or an empty line\n' "${#GROUPS[@]}"
  done
}

_prompt_items() {
  local n k
  plan_group_items "$_PR_GROUP"
  echo ""
  printf '%s: a number toggles an item or asks for its value; d <n> shows its details; an empty line goes back.\n' "$_PR_GROUP"
  n=0
  for k in "${PLAN_ITEMS[@]}"; do
    n=$((n + 1))
    _prompt_item_line "$n" "$k"
  done
  while :; do
    _prompt_read || return 1
    case "$_PR_LINE" in
      "")
        _PR_NEXT=groups
        return 0
        ;;
      "d "* | "D "*)
        k="${_PR_LINE#??}"
        k="${k#"${k%%[![:space:]]*}"}"
        if _prompt_number "$k" "$n"; then
          echo ""
          plan_item_details "${PLAN_ITEMS[_PR_N - 1]}"
          _PR_NEXT=items
          return 0
        fi
        ;;
      *)
        if _prompt_number "$_PR_LINE" "$n"; then
          _prompt_item "${PLAN_ITEMS[_PR_N - 1]}" || return 1
          _PR_NEXT=items
          return 0
        fi
        ;;
    esac
    printf '  answer an item number from 1 to %d, d <n>, or an empty line\n' "$n"
  done
}

_prompt_review() {
  local build=0
  if plan_peruser_changes; then
    plan_peruser_text
    echo ""
    printf '%s\n' "$PLAN_PERUSER_TEXT"
    echo "Save the per-user changes for: [y]ou only  [t]he team"
    while :; do
      _prompt_read || return 1
      case "$_PR_LINE" in
        "" | y | Y) plan_for_team 0 ;;
        t | T) plan_for_team 1 ;;
        *)
          echo "  answer y or t"
          continue
          ;;
      esac
      break
    done
  else
    plan_for_team 0
  fi
  if ! plan_review_build; then
    printf '  %s\n' "$PLAN_ERROR"
    [ "$PLAN_NEEDS_TEAM" = 0 ] || echo "  (here: answer t, the team, when the review asks whose the per-user changes are)"
    _PR_NEXT=summary
    return 0
  fi
  echo ""
  plan_render_review
  if plan_is_empty; then echo "nothing to do"; fi
  echo ""
  if plan_can_build; then
    build=1
    echo "[w]rite and build  [o] write only  [b]ack"
  else
    [ -z "$PLAN_NO_BUILD" ] || printf 'Write and build is off here: %s\n' "$PLAN_NO_BUILD"
    echo "[o] write only  [b]ack"
  fi
  while :; do
    _prompt_read || return 1
    case "$_PR_LINE" in
      o | O)
        _PR_NEXT="write"
        return 0
        ;;
      b | B | "")
        _PR_NEXT=summary
        return 0
        ;;
      w | W)
        if [ "$build" = 1 ]; then
          _prompt_confirm_build || return 1
          return 0
        fi
        ;;
    esac
    if [ "$build" = 1 ]; then echo "  answer w, o or b"; else echo "  answer o or b"; fi
  done
}

# _prompt_confirm_build: "This downloads <what>. Continue? [y/N]": y builds,
# n or an empty answer writes only (plan_build_question).
_prompt_confirm_build() {
  plan_build_question
  while :; do
    _prompt_read "$PLAN_BUILD_QUESTION " || return 1
    case "$_PR_LINE" in
      y | Y | yes | YES | Yes) _PR_NEXT=build ;;
      "" | n | N | no | NO | No) _PR_NEXT="write" ;;
      *)
        echo "  answer y or n"
        continue
        ;;
    esac
    return 0
  done
}

# prompt_run: the prompt UI, from the summary to a result (PROMPT_RESULT).
# shellcheck disable=SC2034  # PROMPT_RESULT is the UI's result, read by setup.sh
prompt_run() {
  local screen=summary
  PROMPT_RESULT=quit _PR_EOF=0 _PR_GROUP=""
  while :; do
    _PR_NEXT=""
    case "$screen" in
      summary) _prompt_summary || return 0 ;;
      groups) _prompt_groups || return 0 ;;
      items) _prompt_items || return 0 ;;
      review) _prompt_review || return 0 ;;
    esac
    case "$_PR_NEXT" in
      write | build | quit)
        PROMPT_RESULT="$_PR_NEXT"
        return 0
        ;;
    esac
    screen="$_PR_NEXT"
  done
}

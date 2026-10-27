#!/usr/bin/env bash
# doc-superpowers setup: the TUI (design §5.5), the tree-and-details front
# end over the model and plan the prompt UI (lib-prompt.sh) uses, through the
# same calls (lib-plan.sh's "For the interactive UIs"), so that both make the
# plan --yes --set would. Sourced by setup.sh after lib-prompt.sh; probe_run,
# model_base_init and any --set run first.
#
# tui_run reads its keys from fd 3 (setup.sh runs it as `tui_run 3<&0
# </dev/null`, so no command it starts can read a key), draws on stdout,
# changes SEL through model_set only, and sets TUI_RESULT:
#   write  Write only: setup.sh plans and runs the steps
#   build  Write and build, confirmed: the same, with the build last
#   quit   q, Cancel, ^C or the end of input: nothing is written
# PLAN_FOR_TEAM and PLAN_FOR_TEAM_IDS hold the answer to the per-user
# question (plan_for_team). It writes no file.
#
# The layers:
#   tui_read_key  KEY: up down left right enter space esc eof other, or
#                 char:<c>. Bytes are read with `IFS= read -rsn1`. After an
#                 ESC, one more byte within a moment: off a terminal `read
#                 -rsn1 -t 1` (bash 3.2's read takes whole seconds); on a
#                 terminal `stty min 0 time 1` and dd, which return after
#                 100 ms (bash's own read -n sets min 1 time 0 while it
#                 reads, so stty cannot shorten it). "[" or "O", then A B C
#                 D, is an arrow; any other byte is queued as the next key.
#                 k and j are up and down, b is esc.
#   tui_key       the reducer: KEY over UI_SCREEN (summary tree review
#                 confirm scope help), UI_CUR (the cursor's index on that
#                 screen), UI_OPEN (the open groups, a CSV of their names),
#                 UI_TOP (the first line or row shown) and SEL (model_set).
#   tui_render    one frame from that state. Off a terminal (the tests) a
#                 frame starts with a line holding a form feed; on one, the
#                 cursor goes home and each line clears its rest.
#   tui_run       the loop, and the terminal: on a real terminal only (fd 3
#                 and stdout), it saves `stty -g`, enters the alternate
#                 screen and hides the cursor, and restores all three on
#                 return and on EXIT, INT, TERM and HUP (exit 130, 143, 129;
#                 the signals exit, and the EXIT trap restores: see
#                 _tui_signal). The EXIT, INT, TERM and HUP traps it found are
#                 put back on return (the EXIT one chained while it runs).
#                 stty is never touched off a terminal.
#
# The screens and their keys (q quits from any screen, the end of input too):
#   summary  plan_render_summary; Apply these (the per-user question first
#            when plan_peruser_changes, then the review), Customize... (the
#            tree), Show what each does (help setup), Cancel. The cursor
#            starts on Apply these. up/down move, enter chooses.
#   tree     the groups, collapsible, and the highlighted row's details
#            (plan_item_details): beside the tree at 80 columns or more,
#            under it below that. Rows: a group (its summary line), its
#            items, a choice's or multi's options. up/down move; space
#            toggles (a group or item; a choice item takes its next option;
#            an option is ticked, or chosen); enter or right opens a group,
#            or acts as space; left closes the group; e edits a value item
#            (a cooked-mode line read on the bottom line); ? shows the row's
#            details in full; esc or b goes back to the summary, where the
#            groups changed say (changed).
#   scope    "Save the per-user changes for:" You only (the cursor; y) or
#            The team (t); then the review. esc goes back to the summary.
#   review   plan_render_review, scrolled with up/down; the actions Write and
#            build (only when plan_can_build), Write only (the cursor: a build
#            is never the default) and Back, chosen with left/right and enter.
#            A refusal (R9: the merge driver as yours) goes back to the
#            summary, saying why.
#   confirm  "This downloads <what>. Continue? [y/N]": y builds; n or enter
#            writes only; esc goes back to the review.
#   help     a text, scrolled with up/down; esc, b or enter goes back.
#
# tui_size (TUI_COLS, TUI_LINES) and tui_fits (60x16 at least) are setup.sh's
# too: below that it runs the prompt UI after one line, TUI_SMALL. Frames are
# ASCII only unless LC_ALL, else LC_CTYPE, else LANG names UTF-8; colour only
# when TERM is not dumb and NO_COLOR is empty.
#
# DOC_SP_SETUP_DEBUG=1 is for the tests only: one stderr line per key read,
# "tui: key=<KEY> screen=<UI_SCREEN> cur=<UI_CUR>", after the key acted.

TUI_RESULT=""
TUI_SMALL=""
TUI_TTY=0 TUI_COLS=80 TUI_LINES=24 TUI_UTF8=0 TUI_COLOR=0 TUI_LINE=""
KEY=""
UI_SCREEN=summary UI_CUR=0 UI_OPEN="" UI_TOP=0 UI_MSG="" UI_BACK=summary UI_TITLE=""
UI_ROWS=() UI_ACTS=() UI_BODY=() UI_TEXT="" UI_ASIS=wrap
_TUI_PEND="" _TUI_HAS_PEND=0 _TUI_STTY="" _TUI_ACTIVE=0 _TUI_SIG=0 _TUI_PREV_TRAPS="" _TUI_PREV_EXIT="" _TUI_DONE=0 _TUI_DIRTY=1 _TUI_TREE_CUR=0
_TUI_TB="" _TUI_TC="" _TUI_TP="" _TUI_HL="" _TUI_RL="" _TUI_MN=0 _TUI_REPO="" _TUI_I=0 _TUI_O="" _TUI_G=""
_TUI_WR=() _TUI_F=()
_TUI_SP="                                                                                "
_TUI_SP="$_TUI_SP$_TUI_SP$_TUI_SP$_TUI_SP$_TUI_SP"
_G_OPEN="" _G_SHUT="" _G_V="" _G_H="" _G_TL="" _G_TR="" _G_BL="" _G_BR="" _G_TT="" _G_BT=""
_G_SEP="" _G_ELL="" _G_CUT="" _G_UD="" _G_LR=""

# --- The terminal ------------------------------------------------------------

# tui_size: TUI_COLS and TUI_LINES: COLUMNS and LINES when they are numbers,
# else tput's when TERM names a terminal (never decided on tput's exit status:
# TERM=dumb tput cols succeeds), else 80 and 24.
tui_size() {
  local c="${COLUMNS:-}" l="${LINES:-}"
  case "$c" in "" | *[!0-9]*) c="" ;; esac
  case "$l" in "" | *[!0-9]*) l="" ;; esac
  if [ -z "$c" ] || [ -z "$l" ]; then
    case "${TERM:-dumb}" in
      dumb) ;;
      *)
        [ -n "$c" ] || c=$(tput cols 2>/dev/null || true)
        [ -n "$l" ] || l=$(tput lines 2>/dev/null || true)
        ;;
    esac
  fi
  case "$c" in "" | *[!0-9]* | ?????*) c=80 ;; esac
  case "$l" in "" | *[!0-9]* | ?????*) l=24 ;; esac
  TUI_COLS=$((10#$c))
  TUI_LINES=$((10#$l))
  [ "$TUI_COLS" -le 400 ] || TUI_COLS=400
  [ "$TUI_LINES" -le 200 ] || TUI_LINES=200
}

# tui_fits: 0 when the terminal is 60x16 or larger (tui_size first); else 1,
# with TUI_SMALL, the one line setup.sh prints before the prompt UI.
# shellcheck disable=SC2034  # TUI_SMALL is setup.sh's to print
tui_fits() {
  [ "$TUI_COLS" -ge 60 ] && [ "$TUI_LINES" -ge 16 ] && return 0
  TUI_SMALL="terminal too small (${TUI_COLS}x${TUI_LINES}; the full-screen UI needs 60x16): plain prompts instead"
  return 1
}

# _tui_style: the glyphs (UTF-8, or ASCII) and whether to use colour.
_tui_style() {
  local lc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  TUI_UTF8=0
  case "$lc" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) TUI_UTF8=1 ;;
  esac
  if [ "$TUI_UTF8" = 1 ]; then
    _G_OPEN=$'\342\226\276' _G_SHUT=$'\342\226\270' _G_V=$'\342\224\202' _G_H=$'\342\224\200'
    _G_TL=$'\342\224\214' _G_TR=$'\342\224\220' _G_BL=$'\342\224\224' _G_BR=$'\342\224\230'
    _G_TT=$'\342\224\254' _G_BT=$'\342\224\264' _G_SEP=$' \302\267 ' _G_ELL=$'\342\200\246'
    _G_CUT=$'\342\200\246' _G_UD=$'\342\206\221\342\206\223' _G_LR=$'\342\206\220\342\206\222'
  else
    _G_OPEN=- _G_SHUT=+ _G_V="|" _G_H=- _G_TL=+ _G_TR=+ _G_BL=+ _G_BR=+ _G_TT=+ _G_BT=+
    _G_SEP=" - " _G_ELL="..." _G_CUT="..." _G_UD="up/down" _G_LR="left/right"
  fi
  TUI_COLOR=0
  if [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then TUI_COLOR=1; fi
}

# _tui_enter: on a real terminal, save stty, then keys unechoed and one at a
# time, the alternate screen, the cursor hidden.
_tui_enter() {
  [ "$TUI_TTY" = 1 ] || return 0
  _TUI_STTY=$(stty -g <&3 2>/dev/null) || _TUI_STTY=""
  [ -n "$_TUI_STTY" ] || return 0
  _TUI_ACTIVE=1
  stty -echo -icanon min 1 time 0 <&3 2>/dev/null || true
  printf '\033[?1049h\033[?25l'
}

# _tui_restore: undo _tui_enter (once): the cursor, the main screen, stty.
_tui_restore() {
  [ "$_TUI_ACTIVE" = 1 ] || return 0
  _TUI_ACTIVE=0
  printf '\033[?25h\033[?1049l' 2>/dev/null || true
  stty "$_TUI_STTY" <&3 2>/dev/null || stty "$_TUI_STTY" </dev/tty 2>/dev/null || true
}

# _tui_signal <exit code>: INT, TERM or HUP: stop; the EXIT trap restores the
# terminal. Not here: a signal that comes during `read -n` runs this trap
# inside the read, and the read, unwinding, then puts back the settings it
# saved (ours, keys one at a time), after anything done here.
_tui_signal() {
  _TUI_SIG=1
  trap - INT TERM HUP
  exit "$1"
}

# _tui_on_exit: the EXIT trap while the TUI runs: restore the terminal, say
# that nothing was written when a signal stopped it, then run the EXIT trap
# the TUI found in place (chained, not lost).
_tui_on_exit() {
  _tui_restore
  [ "$_TUI_SIG" = 0 ] || echo "setup: interrupted: nothing was written" >&2
  [ -z "$_TUI_PREV_EXIT" ] || eval "$_TUI_PREV_EXIT"
}

# _tui_trap_cmd -- <command> EXIT: _TUI_PREV_EXIT = <command>, from one line
# of `trap -p EXIT` (run as "_tui_trap_cmd" plus the line minus its "trap").
_tui_trap_cmd() {
  _TUI_PREV_EXIT="$2"
}

# _tui_save_traps: the EXIT, INT, TERM and HUP traps in place before the TUI
# (_TUI_PREV_TRAPS, as `trap -p` prints them; _TUI_PREV_EXIT, the EXIT trap's
# command), which tui_run puts back on return.
_tui_save_traps() {
  local p
  _TUI_PREV_TRAPS=$(trap -p EXIT INT TERM HUP)
  _TUI_PREV_EXIT=""
  p=$(trap -p EXIT)
  [ -z "$p" ] || eval "_tui_trap_cmd ${p#trap }"
}

# --- Keys --------------------------------------------------------------------

# _tui_queue <byte>: the next key's first byte ("" is a newline).
_tui_queue() {
  _TUI_PEND="$1"
  _TUI_HAS_PEND=1
}

# _tui_byte: _TUI_TB, the next byte (a queued one first; "" is a newline).
# Returns 1 at the end of input.
_tui_byte() {
  local b=""
  if [ "$_TUI_HAS_PEND" = 1 ]; then
    _TUI_HAS_PEND=0
    _TUI_TB="$_TUI_PEND"
    return 0
  fi
  IFS= read -rsn1 b <&3 || return 1
  _TUI_TB="$b"
}

# _tui_esc_byte: _TUI_TB, a byte that follows an ESC at once. Returns 1 when
# none comes (a bare Esc), or at the end of input.
_tui_esc_byte() {
  local b=""
  if [ "$TUI_TTY" = 1 ]; then
    stty min 0 time 1 <&3 2>/dev/null || true
    b=$(dd bs=1 count=1 <&3 2>/dev/null; echo x)
    stty min 1 time 0 <&3 2>/dev/null || true
    b="${b%x}"
    [ -n "$b" ] || return 1
    [ "$b" != $'\n' ] || b=""
  else
    IFS= read -rsn1 -t 1 b <&3 || return 1
  fi
  _TUI_TB="$b"
}

# tui_read_key: KEY, the next key (see the header).
tui_read_key() {
  local c
  if ! _tui_byte; then
    KEY=eof
    return 0
  fi
  c="$_TUI_TB"
  case "$c" in
    "" | $'\r') KEY=enter ;;
    " ") KEY=space ;;
    k) KEY=up ;;
    j) KEY=down ;;
    b) KEY=esc ;;
    $'\033') _tui_read_esc ;;
    *) KEY="char:$c" ;;
  esac
}

# _tui_read_esc: after an ESC: an arrow, a bare Esc (the byte after it
# queued), or another sequence (KEY=other, ignored).
_tui_read_esc() {
  local c n=0
  if ! _tui_esc_byte; then
    KEY=esc
    return 0
  fi
  c="$_TUI_TB"
  case "$c" in
    "[" | O) ;;
    *)
      KEY=esc
      _tui_queue "$c"
      return 0
      ;;
  esac
  if ! _tui_esc_byte; then
    KEY=esc
    _tui_queue "$c"
    return 0
  fi
  case "$_TUI_TB" in
    A) KEY=up ;;
    B) KEY=down ;;
    C) KEY=right ;;
    D) KEY=left ;;
    [0-9])
      # A longer sequence (Delete is ESC [ 3 ~): read up to its last byte.
      KEY=other
      while [ "$n" -lt 8 ] && _tui_esc_byte; do
        case "$_TUI_TB" in
          [0-9] | ";") n=$((n + 1)) ;;
          *) break ;;
        esac
      done
      ;;
    *) KEY=other ;;
  esac
}

# _tui_read_line <prompt>: TUI_LINE, a line typed in cooked mode on the bottom
# line (spaces around it dropped). Returns 1 at the end of input.
_tui_read_line() {
  local s="" pre=""
  if [ "$_TUI_HAS_PEND" = 1 ]; then
    _TUI_HAS_PEND=0
    if [ -z "$_TUI_PEND" ]; then
      TUI_LINE=""
      return 0
    fi
    pre="$_TUI_PEND"
  fi
  if [ "$_TUI_ACTIVE" = 1 ]; then
    _tui_cut "$1" $((TUI_COLS - 20))
    printf '\033[%d;1H\033[2K%s\033[?25h' "$TUI_LINES" "$_TUI_TC"
    stty "$_TUI_STTY" <&3 2>/dev/null || true
  else
    printf '%s\n' "$1"
  fi
  if ! IFS= read -r s <&3 && [ -z "$s" ]; then
    _tui_raw_again
    return 1
  fi
  _tui_raw_again
  s="$pre${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  TUI_LINE="$s"
}

_tui_raw_again() {
  [ "$_TUI_ACTIVE" = 1 ] || return 0
  stty -echo -icanon min 1 time 0 <&3 2>/dev/null || true
  printf '\033[?25l'
}

# --- Text --------------------------------------------------------------------

# _tui_cut <text> <width>: _TUI_TC, the text cut to <width> characters (the
# cut marked).
_tui_cut() {
  local k
  if [ "${#1}" -le "$2" ]; then
    _TUI_TC="$1"
    return 0
  fi
  k=$(($2 - ${#_G_CUT}))
  if [ "$k" -lt 1 ]; then
    _TUI_TC="${1:0:$2}"
  else
    _TUI_TC="${1:0:k}$_G_CUT"
  fi
}

# _tui_pad <text> <width>: _TUI_TP, the text cut or padded to <width>.
_tui_pad() {
  _tui_cut "$1" "$2"
  _TUI_TP="$_TUI_TC${_TUI_SP:0:$(($2 - ${#_TUI_TC}))}"
}

# _tui_wrap <text> <width>: _TUI_WR, the text's lines wrapped at <width>: a
# line keeps its indent, and an indented line's continuations are indented two
# more; a word longer than the width is split.
_tui_wrap() {
  local text="$1" w="$2" para ind cont line word has k more=1 words
  _TUI_WR=()
  [ "$w" -ge 8 ] || w=8
  while [ "$more" = 1 ]; do
    case "$text" in
      *$'\n'*)
        para="${text%%$'\n'*}"
        text="${text#*$'\n'}"
        ;;
      *)
        para="$text"
        more=0
        ;;
    esac
    para="${para//$'\t'/  }"
    if [ "${#para}" -le "$w" ]; then
      _TUI_WR+=("$para")
      continue
    fi
    ind="${para%%[! ]*}"
    [ "${#ind}" -le $((w / 2)) ] || ind=""
    cont="$ind"
    [ -z "$ind" ] || cont="$ind  "
    line="$ind" has=0 words=()
    read -r -a words <<<"$para"
    for word in ${words[@]+"${words[@]}"}; do
      if [ "$has" = 1 ] && [ $((${#line} + 1 + ${#word})) -le "$w" ]; then
        line="$line $word"
        continue
      fi
      if [ "$has" = 1 ]; then
        _TUI_WR+=("$line")
        line="$cont"
      fi
      while [ $((${#line} + ${#word})) -gt "$w" ]; do
        k=$((w - ${#line}))
        [ "$k" -ge 1 ] || k=1
        _TUI_WR+=("$line${word:0:k}")
        word="${word:k}"
        line="$cont"
      done
      line="$line$word"
      has=1
    done
    _TUI_WR+=("$line")
  done
}

# _tui_lines <text>: _TUI_WR, the text's lines as they are.
_tui_lines() {
  local l
  _TUI_WR=()
  while IFS= read -r l; do _TUI_WR+=("$l"); done <<<"$1"
}

# --- Frames ------------------------------------------------------------------

# _tui_add <line> [hl]: one frame line, cut to the width; hl 1: the cursor's
# (reverse video with colour), 2: a title (bold), 3: a key hint (dim).
_tui_add() {
  _tui_cut "$1" "$TUI_COLS"
  _tui_hl "$_TUI_TC" "${2:-0}"
  _TUI_F+=("$_TUI_HL")
}

# _tui_hl <text> <0|1|2|3>: _TUI_HL, the text, highlighted when colour is on.
_tui_hl() {
  _TUI_HL="$1"
  [ "$TUI_COLOR" = 1 ] || return 0
  case "$2" in
    1) _TUI_HL=$'\033[7m'"$1"$'\033[0m' ;;
    2) _TUI_HL=$'\033[1m'"$1"$'\033[0m' ;;
    3) _TUI_HL=$'\033[2m'"$1"$'\033[0m' ;;
  esac
}

# _tui_msg_lines <max>: _TUI_WR, UI_MSG wrapped (at most <max> lines).
_tui_msg_lines() {
  _TUI_WR=()
  [ -n "$UI_MSG" ] || return 0
  _tui_wrap "$UI_MSG" "$TUI_COLS"
  while [ "${#_TUI_WR[@]}" -gt "$1" ]; do unset "_TUI_WR[${#_TUI_WR[@]}-1]"; done
}

# _tui_tail <hint>: the message (if any) and the key hint, the frame's last
# lines.
_tui_tail() {
  local l
  _tui_msg_lines 4
  for l in ${_TUI_WR[@]+"${_TUI_WR[@]}"}; do _tui_add "$l"; done
  _tui_add "$1" 3
}

# _tui_msg_n: _TUI_MN, how many lines the message takes.
_tui_msg_n() {
  _tui_msg_lines 4
  _TUI_MN=${#_TUI_WR[@]}
}

# _tui_flush: print the frame.
_tui_flush() {
  local out l n=0 last=${#_TUI_F[@]}
  if [ "$last" -gt "$TUI_LINES" ] && [ "$_TUI_ACTIVE" = 1 ]; then last=$TUI_LINES; fi
  if [ "$_TUI_ACTIVE" = 1 ]; then
    out=$'\033[H'
    for l in "${_TUI_F[@]}"; do
      n=$((n + 1))
      [ "$n" -le "$last" ] || break
      if [ "$n" -lt "$last" ]; then out="$out$l"$'\033[K\n'; else out="$out$l"$'\033[K\033[J'; fi
    done
  else
    out=$'\f\n'
    for l in "${_TUI_F[@]}"; do out="$out$l"$'\n'; done
  fi
  if [ "$TUI_UTF8" = 1 ]; then
    printf '%s' "$out"
  else
    printf '%s' "$out" | LC_ALL=C tr '\200-\377' '?'
  fi
}

# _tui_window <n lines> <height>: UI_TOP clamped so that a window of
# <height> lines shows as much as it can.
_tui_window() {
  local max=$(($1 - $2))
  [ "$max" -ge 0 ] || max=0
  [ "$UI_TOP" -le "$max" ] || UI_TOP=$max
  [ "$UI_TOP" -ge 0 ] || UI_TOP=0
}

# _tui_preview: the plan behind the summary's marks, rebuilt after a change.
_tui_preview() {
  [ "$_TUI_DIRTY" = 1 ] || return 0
  plan_build_preview
  _TUI_DIRTY=0
}

_tui_frame_summary() {
  local body=() l n k avail labels mark fixed hl
  _tui_preview
  _tui_lines "$(plan_render_summary)"
  body=(${_TUI_WR[@]+"${_TUI_WR[@]}"})
  labels=("Apply these" "Customize$_G_ELL" "Show what each does" "Cancel")
  _tui_msg_n
  fixed=$((9 + _TUI_MN))
  avail=$((TUI_LINES - fixed))
  [ "$avail" -ge 2 ] || avail=2
  _tui_add "doc-superpowers setup$_G_SEP$_TUI_REPO" 2
  _tui_add ""
  n=${#body[@]}
  k=0
  for l in ${body[@]+"${body[@]}"}; do
    if [ "$n" -gt "$avail" ] && [ "$k" -ge $((avail - 1)) ]; then
      _tui_add "  $_G_ELL $((n - k)) more lines (Customize$_G_ELL shows every group)"
      break
    fi
    _tui_add "$l"
    k=$((k + 1))
  done
  _tui_add ""
  k=0
  for l in "${labels[@]}"; do
    mark="  " hl=0
    if [ "$k" = "$UI_CUR" ]; then mark="> " hl=1; fi
    _tui_add "$mark$l" "$hl"
    k=$((k + 1))
  done
  _tui_add ""
  _tui_tail "$_G_UD move${_G_SEP}enter choose${_G_SEP}q quit"
}

# _tui_set_body <text> [wrap|asis]: the text a body frame shows (UI_TEXT),
# wrapped to the width at each frame, or each line as it is (cut).
_tui_set_body() {
  UI_TEXT="$1"
  UI_ASIS="${2:-wrap}"
}

# _tui_body_frame <title> <hint> <after...>: UI_TEXT, as UI_BODY, scrolled,
# under a title, then the given lines and the hint.
_tui_body_frame() {
  local title="$1" hint="$2" h n k l
  shift 2
  if [ "$UI_ASIS" = asis ]; then _tui_lines "$UI_TEXT"; else _tui_wrap "$UI_TEXT" "$TUI_COLS"; fi
  UI_BODY=(${_TUI_WR[@]+"${_TUI_WR[@]}"})
  n=${#UI_BODY[@]}
  _tui_msg_n
  h=$((TUI_LINES - 4 - $# - _TUI_MN))
  [ "$h" -ge 1 ] || h=1
  _tui_window "$n" "$h"
  [ "$n" -le "$h" ] || hint="$hint${_G_SEP}lines $((UI_TOP + 1))-$((UI_TOP + h > n ? n : UI_TOP + h)) of $n"
  _tui_add "$title" 2
  _tui_add ""
  k=0
  for l in ${UI_BODY[@]+"${UI_BODY[@]}"}; do
    if [ "$k" -ge "$UI_TOP" ] && [ "$k" -lt $((UI_TOP + h)) ]; then _tui_add "$l"; fi
    k=$((k + 1))
  done
  _tui_add ""
  for l in "$@"; do _tui_add "$l"; done
  _tui_tail "$hint"
}

_tui_frame_review() {
  local k line="" a
  k=0
  for a in "${UI_ACTS[@]}"; do
    case "$a" in
      build) a="Write and build" ;;
      write) a="Write only" ;;
      *) a="Back" ;;
    esac
    if [ "$k" = "$UI_CUR" ]; then line="$line> $a"; else line="$line  $a"; fi
    [ "$k" -ge $((${#UI_ACTS[@]} - 1)) ] || line="$line    "
    k=$((k + 1))
  done
  _tui_body_frame "Review$_G_SEP$_TUI_REPO" \
    "$_G_LR choose${_G_SEP}$_G_UD scroll${_G_SEP}enter ok${_G_SEP}esc back${_G_SEP}q quit" "$line"
}

_tui_frame_help() {
  _tui_body_frame "$UI_TITLE" "$_G_UD scroll${_G_SEP}esc back${_G_SEP}q quit"
}

_tui_frame_confirm() {
  _tui_body_frame "Write and build$_G_SEP$_TUI_REPO" "y or n${_G_SEP}esc back${_G_SEP}q quit" \
    "y: write and build    n or enter: write only    esc: back to the review"
}

_tui_frame_scope() {
  local you="  You only" team="  The team" hy=0 ht=0 l
  if [ "$UI_CUR" = 0 ]; then you="> You only" hy=1; else team="> The team" ht=1; fi
  _tui_add "Whose changes$_G_SEP$_TUI_REPO" 2
  _tui_add ""
  _tui_wrap "$PLAN_PERUSER_TEXT" "$TUI_COLS"
  for l in "${_TUI_WR[@]}"; do _tui_add "$l"; done
  _tui_add ""
  _tui_add "Save the per-user changes for:"
  _tui_add "$you" "$hy"
  _tui_add "$team" "$ht"
  _tui_add ""
  _tui_tail "$_G_UD move${_G_SEP}enter choose${_G_SEP}y you only${_G_SEP}t the team${_G_SEP}esc back${_G_SEP}q quit"
}

# --- The tree ----------------------------------------------------------------

_tui_is_open() {
  case ",$UI_OPEN," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# _tui_toggle_open <group> [open|close]: open or close a group.
_tui_toggle_open() {
  local g="$1" want="${2:-}" o out=""
  if _tui_is_open "$g"; then
    [ "$want" != open ] || return 0
    IFS=, read -r -a o <<<"$UI_OPEN"
    for want in ${o[@]+"${o[@]}"}; do
      [ "$want" = "$g" ] || out="${out:+$out,}$want"
    done
    UI_OPEN="$out"
  else
    [ "$want" != close ] || return 0
    UI_OPEN="${UI_OPEN:+$UI_OPEN,}$g"
  fi
}

# _tui_rows: UI_ROWS, the tree's rows: "g:<group>", "i:<item index>",
# "o:<item index>:<option>".
_tui_rows() {
  local g i o
  UI_ROWS=()
  for g in "${GROUPS[@]}"; do
    UI_ROWS+=("g:$g")
    _tui_is_open "$g" || continue
    plan_group_items "$g"
    for i in ${PLAN_ITEMS[@]+"${PLAN_ITEMS[@]}"}; do
      UI_ROWS+=("i:$i")
      case "${CAT_KIND[i]}" in
        multi | choice) for o in ${CAT_OPTIONS[i]//,/ }; do UI_ROWS+=("o:$i:$o"); done ;;
      esac
    done
  done
}

# _tui_row_text <row>: _TUI_TC, the row as the tree shows it.
_tui_row_text() {
  local r="$1" i o t g
  case "$r" in
    g:*)
      g="${r#g:}"
      plan_group_line "$g" || true
      if _tui_is_open "$g"; then t="$_G_OPEN"; else t="$_G_SHUT"; fi
      _TUI_TC="$t $PLAN_GROUP_LINE"
      ;;
    i:*)
      i="${r#i:}"
      plan_item_box "$i"
      plan_item_marks "$i"
      t="    $PLAN_BOX ${CAT_LABEL[i]}"
      [ "${CAT_KIND[i]}" = toggle ] || t="$t: ${SEL[i]//,/, }"
      _TUI_TC="$t$PLAN_MARKS"
      ;;
    o:*)
      r="${r#o:}"
      i="${r%%:*}"
      o="${r#*:}"
      if [ "${CAT_KIND[i]}" = multi ]; then
        t="[ ]"
        if _model_csv_has "${SEL[i]}" "$o"; then t="[x]"; fi
      else
        t="( )"
        if [ "${SEL[i]}" = "$o" ]; then t="(*)"; fi
      fi
      t="        $t $o"
      if model_option_disabled "${CAT_ID[i]}" "$o"; then t="$t (off here)"; fi
      _TUI_TC="$t"
      ;;
  esac
}

# _tui_row_item <row>: _TUI_I, the item a row stands for (a group's: its
# first); _TUI_O, the option (or empty).
_tui_row_item() {
  local r="$1"
  _TUI_O=""
  case "$r" in
    g:*)
      plan_group_items "${r#g:}"
      _TUI_I="${PLAN_ITEMS[0]}"
      ;;
    i:*) _TUI_I="${r#i:}" ;;
    o:*)
      r="${r#o:}"
      _TUI_I="${r%%:*}"
      _TUI_O="${r#*:}"
      ;;
  esac
}

# _tui_details <row>: the row's details text (an option's own line first).
_tui_details() {
  local line
  _tui_row_item "$1"
  if [ -n "$_TUI_O" ]; then
    while IFS= read -r line; do
      case "$line" in
        "$_TUI_O: "*) printf '%s\n' "$line" ;;
      esac
    done <<<"${CAT_DETAILS[_TUI_I]}"
    if model_option_disabled "${CAT_ID[_TUI_I]}" "$_TUI_O"; then
      printf 'Off here: %s\n' "$MODEL_OPT_REASON"
    fi
    echo ""
  fi
  plan_item_details "$_TUI_I"
}

_tui_frame_tree() {
  local n h hd w l r det=() rows=() k mark hl msgn two=0 left right avail
  _tui_preview
  _tui_rows
  n=${#UI_ROWS[@]}
  [ "$UI_CUR" -lt "$n" ] || UI_CUR=$((n - 1))
  _tui_msg_n
  msgn=$_TUI_MN
  [ "$TUI_COLS" -lt 80 ] || two=1
  if [ "$two" = 1 ]; then
    left=$(((TUI_COLS - 3) * 3 / 5))
    right=$((TUI_COLS - 3 - left))
    h=$((TUI_LINES - 4 - msgn))
    [ "$h" -ge 1 ] || h=1
    hd=$h
  else
    left=$TUI_COLS
    right=$TUI_COLS
    avail=$((TUI_LINES - 3 - msgn))
    [ "$avail" -ge 2 ] || avail=2
    h=$((avail * 3 / 5))
    [ "$h" -ge 1 ] || h=1
    [ "$h" -le "$n" ] || h=$n
    hd=$((avail - h))
    [ "$hd" -ge 1 ] || hd=1
  fi
  # The cursor in view.
  [ "$UI_CUR" -ge "$UI_TOP" ] || UI_TOP=$UI_CUR
  [ "$UI_CUR" -lt $((UI_TOP + h)) ] || UI_TOP=$((UI_CUR - h + 1))
  _tui_window "$n" "$h"
  k=0
  for r in "${UI_ROWS[@]}"; do
    if [ "$k" -ge "$UI_TOP" ] && [ "$k" -lt $((UI_TOP + h)) ]; then
      _tui_row_text "$r"
      mark="  "
      [ "$k" != "$UI_CUR" ] || mark="> "
      _tui_pad "$mark$_TUI_TC" "$left"
      rows+=("$_TUI_TP")
    fi
    k=$((k + 1))
  done
  _tui_wrap "$(_tui_details "${UI_ROWS[UI_CUR]}")" "$((right - 1))"
  det=(${_TUI_WR[@]+"${_TUI_WR[@]}"})
  _tui_add "Customize$_G_SEP$_TUI_REPO" 2
  if [ "$two" = 1 ]; then
    _tui_rule "$left"
    l="$_TUI_RL"
    _tui_rule "$right"
    _tui_add "$_G_TL$l$_G_TT$_TUI_RL$_G_TR"
    k=0
    while [ "$k" -lt "$h" ]; do
      l="${rows[k]:-}"
      [ -n "$l" ] || l="${_TUI_SP:0:left}"
      hl=0
      [ $((UI_TOP + k)) != "$UI_CUR" ] || hl=1
      _tui_pad " ${det[k]:-}" "$right"
      _tui_hl "$l" "$hl"
      _TUI_F+=("$_G_V$_TUI_HL$_G_V$_TUI_TP$_G_V")
      k=$((k + 1))
    done
    _tui_rule "$left"
    l="$_TUI_RL"
    _tui_rule "$right"
    _tui_add "$_G_BL$l$_G_BT$_TUI_RL$_G_BR"
  else
    k=0
    for l in ${rows[@]+"${rows[@]}"}; do
      hl=0
      [ $((UI_TOP + k)) != "$UI_CUR" ] || hl=1
      _tui_cut "${l%"${l##*[! ]}"}" "$TUI_COLS"
      _tui_hl "$_TUI_TC" "$hl"
      _TUI_F+=("$_TUI_HL")
      k=$((k + 1))
    done
    _tui_rule "$TUI_COLS"
    _tui_add "$_TUI_RL"
    k=0
    for l in ${det[@]+"${det[@]}"}; do
      [ "$k" -lt "$hd" ] || break
      _tui_add "$l"
      k=$((k + 1))
    done
  fi
  _tui_tail "space toggle${_G_SEP}enter open${_G_SEP}e edit${_G_SEP}? help${_G_SEP}esc done${_G_SEP}q quit"
}

# _tui_rule <n>: _TUI_RL, <n> horizontal rule characters.
_tui_rule() {
  local k=0
  _TUI_RL=""
  while [ "$k" -lt "$1" ]; do
    _TUI_RL="$_TUI_RL$_G_H"
    k=$((k + 1))
  done
}

# tui_render: one frame of the state.
tui_render() {
  _TUI_F=()
  case "$UI_SCREEN" in
    summary) _tui_frame_summary ;;
    tree) _tui_frame_tree ;;
    review) _tui_frame_review ;;
    confirm) _tui_frame_confirm ;;
    scope) _tui_frame_scope ;;
    help) _tui_frame_help ;;
  esac
  _tui_flush
}

# --- The reducer -------------------------------------------------------------

_tui_done() {
  TUI_RESULT="$1"
  _TUI_DONE=1
}

# _tui_set <id> <value>: model_set, or its reason in the message line.
_tui_set() {
  _TUI_DIRTY=1
  model_set "$1" "$2" && return 0
  UI_MSG="$MODEL_ERROR"
  return 1
}

# _tui_flip <i>: toggle item i: a toggle flips; a multi goes to none, or from
# none to what its children require (else its default, else its first
# option); a choice with an off option goes off, or from off to its default;
# another choice takes its next option this host offers.
_tui_flip() {
  local i="$1" v="" k o opts=() n cur=0
  case "${CAT_KIND[i]}" in
    toggle)
      v=on
      [ "${SEL[i]}" != on ] || v=off
      ;;
    multi)
      if model_is_on "${CAT_ID[i]}"; then
        v=none
      else
        k=0
        while [ "$k" -lt "$CAT_N" ]; do
          case "${CAT_REQUIRES[k]}" in
            "${CAT_ID[i]}="*)
              v="${CAT_REQUIRES[k]#*=}"
              break
              ;;
          esac
          k=$((k + 1))
        done
        [ -n "$v" ] || [ "${CAT_DEFAULT[i]}" = none ] || v="${CAT_DEFAULT[i]}"
        [ -n "$v" ] || v="${CAT_OPTIONS[i]%%,*}"
      fi
      ;;
    choice)
      if _model_csv_has "${CAT_OPTIONS[i]}" off; then
        if [ "${SEL[i]}" != off ]; then
          v=off
        else
          v="${CAT_DEFAULT[i]}"
          [ "$v" != off ] || v="${CAT_OPTIONS[i]%%,*}"
        fi
      else
        for o in ${CAT_OPTIONS[i]//,/ }; do opts+=("$o"); done
        n=${#opts[@]}
        k=0
        while [ "$k" -lt "$n" ]; do
          [ "${opts[k]}" != "${SEL[i]}" ] || cur=$k
          k=$((k + 1))
        done
        k=1
        while [ "$k" -lt "$n" ]; do
          o="${opts[(cur + k) % n]}"
          if ! model_option_disabled "${CAT_ID[i]}" "$o"; then
            v="$o"
            break
          fi
          k=$((k + 1))
        done
        if [ -z "$v" ]; then
          UI_MSG="${CAT_LABEL[i]}: no other option is offered here"
          return 0
        fi
      fi
      ;;
    *)
      UI_MSG="${CAT_LABEL[i]} is a value: press e to edit it"
      return 0
      ;;
  esac
  _tui_set "${CAT_ID[i]}" "$v" || true
}

# _tui_edit <i>: a value item, read as a line; an empty line keeps it.
_tui_edit() {
  local i="$1"
  if [ "${CAT_KIND[i]}" != value ]; then
    UI_MSG="e edits a value (${CAT_LABEL[i]} is not one): space toggles it"
    return 0
  fi
  if ! _tui_read_line "${CAT_LABEL[i]} (${CAT_OPTIONS[i]//,/ or }; now ${SEL[i]}; empty keeps it): "; then
    _tui_done quit
    return 0
  fi
  [ -z "$TUI_LINE" ] || _tui_set "${CAT_ID[i]}" "$TUI_LINE" || true
}

# _tui_act <row>: space (or enter) on a row.
_tui_act() {
  local r="$1"
  _tui_row_item "$r"
  case "$r" in
    o:*)
      if [ "${CAT_KIND[_TUI_I]}" = multi ]; then
        plan_multi_toggle "$_TUI_I" "$_TUI_O"
        _tui_set "${CAT_ID[_TUI_I]}" "$PLAN_VALUE" || true
      else
        _tui_set "${CAT_ID[_TUI_I]}" "$_TUI_O" || true
      fi
      ;;
    *) _tui_flip "$_TUI_I" ;;
  esac
}

# _tui_cur_to <row>: the cursor on that row.
_tui_cur_to() {
  local k=0 r
  for r in "${UI_ROWS[@]}"; do
    if [ "$r" = "$1" ]; then
      UI_CUR=$k
      return 0
    fi
    k=$((k + 1))
  done
}

# _tui_group_of <row>: _TUI_G, the group the row is in.
_tui_group_of() {
  case "$1" in
    g:*) _TUI_G="${1#g:}" ;;
    *)
      _tui_row_item "$1"
      _TUI_G="${CAT_GROUP[_TUI_I]}"
      ;;
  esac
}

_tui_key_tree() {
  local r n
  _tui_rows
  n=${#UI_ROWS[@]}
  r="${UI_ROWS[UI_CUR]}"
  case "$KEY" in
    up) [ "$UI_CUR" -le 0 ] || UI_CUR=$((UI_CUR - 1)) ;;
    down) [ "$UI_CUR" -ge $((n - 1)) ] || UI_CUR=$((UI_CUR + 1)) ;;
    space) _tui_act "$r" ;;
    enter | right)
      case "$r" in
        g:*)
          if [ "$KEY" = enter ]; then _tui_toggle_open "${r#g:}"; else _tui_toggle_open "${r#g:}" open; fi
          ;;
        i:*)
          _tui_row_item "$r"
          if [ "${CAT_KIND[_TUI_I]}" = value ]; then _tui_edit "$_TUI_I"; else _tui_act "$r"; fi
          ;;
        *) _tui_act "$r" ;;
      esac
      ;;
    left)
      _tui_group_of "$r"
      _tui_toggle_open "$_TUI_G" close
      _tui_rows
      _tui_cur_to "g:$_TUI_G"
      ;;
    char:e)
      _tui_row_item "$r"
      _tui_edit "$_TUI_I"
      ;;
    "char:?")
      _tui_row_item "$r"
      UI_BACK=tree
      _tui_go_help "${CAT_LABEL[_TUI_I]}" "$(_tui_details "$r")"
      ;;
    esc)
      _TUI_TREE_CUR=$UI_CUR
      _tui_go_summary
      ;;
  esac
}

_tui_go_summary() {
  UI_SCREEN=summary UI_CUR=0 UI_TOP=0 _TUI_DIRTY=1
}

# _tui_go_help <title> <text> [wrap|asis]: the help screen (UI_BACK is where
# esc goes): the text wrapped (prose), or as it is, each line cut to the width
# (help setup, laid out in columns of its own).
_tui_go_help() {
  UI_TITLE="$1"
  _tui_set_body "$2" "${3:-wrap}"
  UI_SCREEN=help UI_TOP=0
}

# _tui_apply: Apply these: whose the per-user changes are first, when a team
# record exists and one changed; then the review.
_tui_apply() {
  if plan_peruser_changes; then
    plan_peruser_text
    UI_SCREEN=scope UI_CUR=0
    return 0
  fi
  plan_for_team 0
  _tui_go_review
}

# _tui_go_review: the review, or back to the summary saying why the plan was
# refused.
_tui_go_review() {
  local text
  if ! plan_review_build; then
    UI_MSG="$PLAN_ERROR"
    [ "$PLAN_NEEDS_TEAM" = 0 ] || UI_MSG="$UI_MSG (here: answer The team when asked whose the per-user changes are)"
    _tui_go_summary
    return 0
  fi
  text=$(plan_render_review)
  if plan_is_empty; then text="$text"$'\n'"nothing to do"; fi
  if plan_can_build; then
    UI_ACTS=(build write back)
    UI_CUR=1
  else
    [ -z "$PLAN_NO_BUILD" ] || text="$text"$'\n'"Write and build is off here: $PLAN_NO_BUILD"
    UI_ACTS=(write back)
    UI_CUR=0
  fi
  _tui_set_body "$text"
  UI_SCREEN=review UI_TOP=0
}

_tui_key_summary() {
  case "$KEY" in
    up) [ "$UI_CUR" -le 0 ] || UI_CUR=$((UI_CUR - 1)) ;;
    down) [ "$UI_CUR" -ge 3 ] || UI_CUR=$((UI_CUR + 1)) ;;
    enter | right)
      case "$UI_CUR" in
        0) _tui_apply ;;
        1)
          UI_SCREEN=tree UI_CUR=$_TUI_TREE_CUR UI_TOP=0
          ;;
        2)
          UI_BACK=summary
          _tui_go_help "Help$_G_SEP""doc-superpowers help setup" "$(cat "$ROOT/scripts/help/setup.txt" 2>/dev/null || echo "help setup: not found")" asis
          ;;
        *) _tui_done quit ;;
      esac
      ;;
  esac
}

_tui_key_scope() {
  case "$KEY" in
    up | left) UI_CUR=0 ;;
    down | right) UI_CUR=1 ;;
    char:y | char:Y) UI_CUR=0 ;;
    char:t | char:T) UI_CUR=1 ;;
    esc)
      _tui_go_summary
      return 0
      ;;
  esac
  case "$KEY" in
    enter | char:[yYtT])
      plan_for_team "$UI_CUR"
      _tui_go_review
      ;;
  esac
}

_tui_key_review() {
  local n=${#UI_ACTS[@]}
  case "$KEY" in
    left) [ "$UI_CUR" -le 0 ] || UI_CUR=$((UI_CUR - 1)) ;;
    right) [ "$UI_CUR" -ge $((n - 1)) ] || UI_CUR=$((UI_CUR + 1)) ;;
    up) [ "$UI_TOP" -le 0 ] || UI_TOP=$((UI_TOP - 1)) ;;
    down) UI_TOP=$((UI_TOP + 1)) ;;
    esc) _tui_go_summary ;;
    enter)
      case "${UI_ACTS[UI_CUR]}" in
        build)
          plan_build_question
          _tui_set_body "$PLAN_BUILD_QUESTION"
          UI_SCREEN=confirm UI_TOP=0
          ;;
        write) _tui_done write ;;
        *) _tui_go_summary ;;
      esac
      ;;
  esac
}

_tui_key_confirm() {
  case "$KEY" in
    char:y | char:Y) _tui_done build ;;
    char:n | char:N | enter) _tui_done write ;;
    esc) _tui_go_review ;;
  esac
}

_tui_key_help() {
  case "$KEY" in
    up) [ "$UI_TOP" -le 0 ] || UI_TOP=$((UI_TOP - 1)) ;;
    down | space) UI_TOP=$((UI_TOP + 1)) ;;
    esc | enter | left)
      if [ "$UI_BACK" = tree ]; then
        UI_SCREEN=tree UI_TOP=0
      else
        _tui_go_summary
        UI_CUR=2
      fi
      ;;
  esac
}

# tui_key: the reducer: KEY over the state.
tui_key() {
  UI_MSG=""
  case "$KEY" in
    eof | char:q | char:Q)
      _tui_done quit
      return 0
      ;;
  esac
  case "$UI_SCREEN" in
    summary) _tui_key_summary ;;
    tree) _tui_key_tree ;;
    scope) _tui_key_scope ;;
    review) _tui_key_review ;;
    confirm) _tui_key_confirm ;;
    help) _tui_key_help ;;
  esac
}

# tui_run: the TUI, from the summary to a result (TUI_RESULT).
# shellcheck disable=SC2034  # TUI_RESULT is the UI's result, read by setup.sh
tui_run() {
  TUI_RESULT=quit _TUI_DONE=0 _TUI_SIG=0 _TUI_DIRTY=1 _TUI_HAS_PEND=0 _TUI_PEND="" _TUI_TREE_CUR=0
  UI_SCREEN=summary UI_CUR=0 UI_OPEN="" UI_TOP=0 UI_MSG="" UI_BACK=summary
  TUI_TTY=0
  if [ -t 3 ] && [ -t 1 ]; then TUI_TTY=1; fi
  _tui_style
  _TUI_REPO="${TOP:-$PWD}"
  _TUI_REPO="${_TUI_REPO##*/}"
  tui_size
  _tui_save_traps
  trap '_tui_on_exit' EXIT
  trap '_tui_signal 130' INT
  trap '_tui_signal 143' TERM
  trap '_tui_signal 129' HUP
  _tui_enter
  while [ "$_TUI_DONE" = 0 ]; do
    tui_size
    tui_render
    tui_read_key
    tui_key
    if [ "${DOC_SP_SETUP_DEBUG:-}" = 1 ]; then
      printf 'tui: key=%s screen=%s cur=%s\n' "$KEY" "$UI_SCREEN" "$UI_CUR" >&2
    fi
  done
  _tui_restore
  trap - EXIT INT TERM HUP
  [ -z "$_TUI_PREV_TRAPS" ] || eval "$_TUI_PREV_TRAPS"
}

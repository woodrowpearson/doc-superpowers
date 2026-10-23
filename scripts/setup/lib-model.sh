#!/usr/bin/env bash
# doc-superpowers setup: the model. Sourced by setup.sh (bash 3.2: indexed
# arrays only, every state a global).
#
# The catalog (scripts/setup/catalog.json) is read once, by one jq call, into
# parallel arrays of length CAT_N (index i is the item's catalog position):
#   CAT_ID CAT_GROUP CAT_KIND (toggle|choice|multi|value) CAT_OPTIONS (a CSV:
#   the values of a toggle, choice or multi; a description for a value)
#   CAT_DEFAULT CAT_SCOPE (team|local|mixed|outside) CAT_PERUSER (0|1)
#   CAT_LABEL CAT_DETAILS (the item's text, then one "<option>: <text>" line
#   per option that has its own) CAT_UNDO CAT_WRITES (a CSV of
#   <team|local|outside>:<path>) CAT_REQUIRES (<parent>=<value>, or empty)
# and GROUPS (the group names, in order; bash's own GROUPS, the user's group
# ids, is unset first). DISABLED[i] (a reason, or empty) and HINT[i] (a hint,
# or empty) start empty: the host checks and the scan hints fill them.
#
# The selection: BASE[i], what the run starts from (model_base_init, design
# §5.2), and SEL[i], BASE plus the user's changes (model_set); both are the
# defaults until model_base_init. Values:
#   toggle  on | off
#   choice  one of its options
#   multi   a CSV of its options, in catalog order, or none
#   value   search.cache: host or an absolute path; ci.base_branch: a branch
#           name (install.sh's valid_branch); ci.cron: 5 cron fields
#           (install.sh's valid_cron)
# requires: an item with CAT_REQUIRES = <parent>=<value> is a child. Setting
# a child (to anything but off) while its parent is off (off, or none for a
# multi) sets the parent to <value>; setting a parent off resets its children
# to their defaults.
# One more rule: while search is on, harness holds claude-code, since
# install --search always registers the Claude Code entry in .mcp.json.
#
# Every function that can refuse returns 1 with MODEL_ERROR set, and then has
# changed nothing.

_MODEL_US=$'\037'
_MODEL_RS=$'\036'

CAT_N=0
MODEL_ERROR=""
MODEL_VALUE=""

# One jq pass: the groups line, then one line per item, fields separated by
# US; a newline inside a text becomes RS, and any other control character is
# dropped (so no field can hold the separator).
# shellcheck disable=SC2016  # jq program, not shell expansions
_MODEL_CATALOG_JQ='
  def s: tostring | gsub("\n"; "\u001e") | gsub("[\u0000-\u001d\u001f]"; "");
  (.groups | map(s) | join("\u001f")),
  (.items[]
   | (.option_details // {}) as $od
   | [ .id, .group, .kind, (.options | map(s) | join(",")), .default, .scope,
       (if .per_user then "1" else "0" end), .label,
       (.details + ([.options[] | select($od[.] != null) | "\n" + . + ": " + $od[.]] | join(""))),
       .undo,
       ([.writes[] | .scope + ":" + .path] | join(",")),
       (.requires // "")
     ] | map(s) | join("\u001f"))'

# model_load_catalog <file>: fill the CAT_* arrays, GROUPS, and an empty
# DISABLED[i] and HINT[i] per item.
model_load_catalog() {
  local out items="" line i=0 f_id f_group f_kind f_opts f_def f_scope f_pu f_label f_det f_undo f_writes f_req
  if ! out=$(jq -r "$_MODEL_CATALOG_JQ" "$1" 2>&1); then
    MODEL_ERROR="cannot read the catalog $1: ${out%%$'\n'*}"
    return 1
  fi
  case "$out" in
    *$'\n'*) items="${out#*$'\n'}" ;;
  esac
  CAT_ID=() CAT_GROUP=() CAT_KIND=() CAT_OPTIONS=() CAT_DEFAULT=() CAT_SCOPE=()
  CAT_PERUSER=() CAT_LABEL=() CAT_DETAILS=() CAT_UNDO=() CAT_WRITES=() CAT_REQUIRES=()
  DISABLED=() HINT=() BASE=() SEL=()
  # GROUPS is a bash special variable (the user's group ids): an assignment to
  # it has no effect until it is unset.
  unset GROUPS
  IFS="$_MODEL_US" read -r -a GROUPS <<<"${out%%$'\n'*}"
  # shellcheck disable=SC2034  # the catalog interface: setup.sh and the other libs read these arrays
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$_MODEL_US" read -r f_id f_group f_kind f_opts f_def f_scope f_pu f_label f_det f_undo f_writes f_req <<<"$line"
    CAT_ID[i]="$f_id"
    CAT_GROUP[i]="$f_group"
    CAT_KIND[i]="$f_kind"
    CAT_OPTIONS[i]="$f_opts"
    CAT_DEFAULT[i]="$f_def"
    CAT_SCOPE[i]="$f_scope"
    CAT_PERUSER[i]="$f_pu"
    CAT_LABEL[i]="$f_label"
    CAT_DETAILS[i]="${f_det//$_MODEL_RS/$'\n'}"
    CAT_UNDO[i]="$f_undo"
    CAT_WRITES[i]="$f_writes"
    CAT_REQUIRES[i]="$f_req"
    DISABLED[i]=""
    HINT[i]=""
    BASE[i]="$f_def"
    SEL[i]="$f_def"
    i=$((i + 1))
  done <<<"$items"
  CAT_N=$i
  if [ "$CAT_N" -eq 0 ]; then
    MODEL_ERROR="the catalog $1 holds no item"
    return 1
  fi
  return 0
}

# _model_i <id>: _MI = its index (no subshell), or return 1.
_model_i() {
  _MI=0
  while [ "$_MI" -lt "$CAT_N" ]; do
    [ "${CAT_ID[_MI]}" != "$1" ] || return 0
    _MI=$((_MI + 1))
  done
  return 1
}

# model_idx <id>: echo its index, or return 1.
model_idx() {
  _model_i "$1" || return 1
  echo "$_MI"
}

# model_get <id>: echo SEL of <id>, or return 1.
model_get() {
  _model_i "$1" || return 1
  printf '%s\n' "${SEL[_MI]}"
}

# model_changed <id>: 0 when SEL differs from BASE.
model_changed() {
  _model_i "$1" || return 1
  [ "${SEL[_MI]}" != "${BASE[_MI]}" ]
}

# _model_csv_has <csv> <name>
_model_csv_has() {
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _model_is_off <i> <value>: the value that leaves item i unticked (off; none
# for a multi). A value item, or a choice without off, is never off.
_model_is_off() {
  case "${CAT_KIND[$1]}" in
    multi) [ "$2" = none ] ;;
    toggle) [ "$2" = off ] ;;
    choice) [ "$2" = off ] && _model_csv_has "${CAT_OPTIONS[$1]}" off ;;
    *) return 1 ;;
  esac
}

# _model_norm_multi <i> <raw>: MODEL_VALUE = the names of <raw> (a CSV,
# spaces around names ignored, repeats dropped) in catalog order, or none.
_model_norm_multi() {
  local i="$1" raw="$2" n opts="${CAT_OPTIONS[$1]}" o out="" seen="," IFS_save="$IFS"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [ -z "$raw" ] || [ "$raw" = none ]; then
    MODEL_VALUE=none
    return 0
  fi
  IFS=','
  set -f
  # shellcheck disable=SC2086  # split on commas, globbing off
  set -- $raw
  set +f
  IFS="$IFS_save"
  for n in "$@"; do
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    [ -n "$n" ] || continue
    if ! _model_csv_has "$opts" "$n"; then
      MODEL_ERROR="${CAT_ID[i]} has no option '$n' (options: $opts, or none)"
      return 1
    fi
    seen="$seen$n,"
  done
  IFS=','
  set -f
  # shellcheck disable=SC2086  # split on commas, globbing off
  set -- $opts
  set +f
  IFS="$IFS_save"
  for o in "$@"; do
    case "$seen" in
      *",$o,"*) out="${out:+$out,}$o" ;;
    esac
  done
  MODEL_VALUE="${out:-none}"
}

# The value items' rules. Branch names and cron fields are checked as
# install.sh checks them (valid_branch, valid_cron), so a value setup takes is
# one the installer takes.
_model_valid_branch() {
  local re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
  [[ "$1" =~ $re ]] && git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}
_model_valid_cron() {
  local re='^[A-Za-z0-9*,/-]+([[:space:]]+[A-Za-z0-9*,/-]+){4}$'
  [[ "$1" =~ $re ]]
}

# model_check <id> <value>: validate <value> against the item's kind and
# options, without changing anything. MODEL_VALUE = the value normalised; or
# return 1 with MODEL_ERROR.
model_check() {
  local id="$1" v="$2" i
  MODEL_ERROR="" MODEL_VALUE=""
  if ! _model_i "$id"; then
    MODEL_ERROR="no item '$id' (doc-superpowers setup --list lists them)"
    return 1
  fi
  i=$_MI
  case "${CAT_KIND[i]}" in
    multi)
      _model_norm_multi "$i" "$v" || return 1
      return 0
      ;;
    toggle | choice)
      if [ -z "$v" ] || ! _model_csv_has "${CAT_OPTIONS[i]}" "$v"; then
        MODEL_ERROR="$id takes ${CAT_OPTIONS[i]//,/ | }, not '$v'"
        return 1
      fi
      ;;
    value)
      case "$v" in
        *[[:cntrl:]]*)
          MODEL_ERROR="$id: '$v' holds a control character"
          return 1
          ;;
      esac
      case "$id" in
        search.cache)
          case "$v" in
            host | /*) ;;
            *)
              MODEL_ERROR="$id takes host or an absolute path, not '$v'"
              return 1
              ;;
          esac
          ;;
        ci.base_branch)
          if ! _model_valid_branch "$v"; then
            MODEL_ERROR="$id takes a branch name git accepts, not '$v'"
            return 1
          fi
          ;;
        ci.cron)
          if ! _model_valid_cron "$v"; then
            MODEL_ERROR="$id takes 5 cron fields (as in '0 9 * * 1'), not '$v'"
            return 1
          fi
          ;;
        *)
          [ -n "$v" ] || {
            MODEL_ERROR="$id takes a value"
            return 1
          }
          ;;
      esac
      ;;
    *)
      MODEL_ERROR="$id has an unknown kind '${CAT_KIND[i]}' in the catalog"
      return 1
      ;;
  esac
  MODEL_VALUE="$v"
}

# model_set <id> <value>: change SEL of <id>, applying requires (a child turns
# its parent on; a parent turned off resets its children) and the claude-code
# rule. Refuses (1, MODEL_ERROR) an invalid value, a disabled item (unless
# the value leaves it unticked or unchanged), a child of a disabled parent,
# and a harness set without claude-code while search is on.
model_set() {
  local id="$1" i v pid="" pval pi j
  model_check "$id" "$2" || return 1
  v="$MODEL_VALUE"
  _model_i "$id"
  i=$_MI
  if [ -n "${DISABLED[i]}" ] && [ "$v" != "${SEL[i]}" ] && ! _model_is_off "$i" "$v"; then
    MODEL_ERROR="$id: ${DISABLED[i]}"
    return 1
  fi
  # A child ticked or given a value turns its parent on; one set off does not.
  if [ -n "${CAT_REQUIRES[i]}" ] && ! _model_is_off "$i" "$v"; then
    pid="${CAT_REQUIRES[i]%%=*}"
    pval="${CAT_REQUIRES[i]#*=}"
    if ! _model_i "$pid"; then
      MODEL_ERROR="$id requires '$pid', which the catalog does not hold"
      return 1
    fi
    pi=$_MI
    if _model_is_off "$pi" "${SEL[pi]}"; then
      if [ -n "${DISABLED[pi]}" ]; then
        MODEL_ERROR="$id needs $pid, which is disabled here: ${DISABLED[pi]}"
        return 1
      fi
    else
      pid=""
    fi
  fi
  if [ "$id" = harness ] && [ "$(model_get search)" = on ] && ! _model_csv_has "$v" claude-code; then
    MODEL_ERROR="harness: claude-code stays on while doc-search is on (install --search always registers the Claude Code entry in .mcp.json); keep claude-code in '$v', or set search=off first"
    return 1
  fi
  # Every check passed: change the selection.
  if [ -n "$pid" ]; then
    model_set "$pid" "$pval" || return 1
  fi
  SEL[i]="$v"
  if _model_is_off "$i" "$v"; then
    j=0
    while [ "$j" -lt "$CAT_N" ]; do
      case "${CAT_REQUIRES[j]}" in
        "$id="*) SEL[j]="${CAT_DEFAULT[j]}" ;;
      esac
      j=$((j + 1))
    done
  fi
  if [ "$id" = search ] && [ "$v" = on ] && _model_i harness && ! _model_csv_has "${SEL[_MI]}" claude-code; then
    j=$_MI
    if [ "${SEL[j]}" = none ]; then
      SEL[j]=claude-code
    else
      _model_norm_multi "$j" "claude-code,${SEL[j]}"
      SEL[j]="$MODEL_VALUE"
    fi
  fi
  return 0
}

# _model_union <i> <installed>: the default of item i together with what is
# installed, so that a run from the base removes nothing. A toggle is on when
# either is; a multi is both sets; a choice whose options hold off is
# ordered by what it includes (git: hooks includes the merge driver), so the
# earlier option wins; any other choice, and a value, is what is installed
# (probe_installed gives the default when nothing is).
_model_union() {
  local i="$1" inst="$2" d="${CAT_DEFAULT[$1]}" o
  MODEL_VALUE="$d"
  case "${CAT_KIND[i]}" in
    toggle)
      [ "$inst" != on ] || MODEL_VALUE=on
      ;;
    multi)
      [ "$d" != none ] || d=""
      [ "$inst" != none ] || inst=""
      _model_norm_multi "$i" "$d,$inst"
      ;;
    choice)
      if _model_csv_has "${CAT_OPTIONS[i]}" off; then
        for o in ${CAT_OPTIONS[i]//,/ }; do
          if [ "$o" = "$d" ] || [ "$o" = "$inst" ]; then
            MODEL_VALUE="$o"
            break
          fi
        done
      else
        MODEL_VALUE="$inst"
      fi
      ;;
    *) MODEL_VALUE="$inst" ;;
  esac
}

# _model_apply_lines <what> <lines>: set BASE of each "<id>=<value>" line
# (values checked as --set checks them).
_model_apply_lines() {
  local what="$1" line id
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%%=*}"
    if ! model_check "$id" "${line#*=}"; then
      MODEL_ERROR="$what: $MODEL_ERROR"
      return 1
    fi
    _model_i "$id"
    BASE[_MI]="$MODEL_VALUE"
  done <<<"$2"
  return 0
}

# model_base_init: BASE and SEL per design §5.2 (needs probe_run first).
#   A team record (PROBE_TEAM): the record — its values (PROBE_TEAM_VALUES),
#     what it does not hold (CI, which stays in .tiers.ci; the cache path; the
#     terminal command) as installed — then this user's local overrides
#     (PROBE_LOCAL_VALUES).
#   No team record: the defaults together with what is installed.
model_base_init() {
  local i inst
  MODEL_ERROR=""
  i=0
  while [ "$i" -lt "$CAT_N" ]; do
    inst=$(probe_installed "${CAT_ID[i]}") || inst="${CAT_DEFAULT[i]}"
    if [ -n "$PROBE_TEAM" ]; then
      BASE[i]="$inst"
    else
      _model_union "$i" "$inst"
      BASE[i]="$MODEL_VALUE"
    fi
    i=$((i + 1))
  done
  if [ -n "$PROBE_TEAM" ]; then
    _model_apply_lines ".claude/doc-superpowers/installed.json (.setup)" "$PROBE_TEAM_VALUES" || return 1
    _model_apply_lines ".claude/doc-superpowers/installed.local.json (overrides)" "$PROBE_LOCAL_VALUES" || return 1
  fi
  # The claude-code rule holds in the base too (a record may say otherwise:
  # install --search registers the Claude Code entry whatever it says).
  if _model_i search && [ "${BASE[_MI]}" = on ] && _model_i harness && ! _model_csv_has "${BASE[_MI]}" claude-code; then
    i=$_MI
    if [ "${BASE[i]}" = none ]; then
      BASE[i]=claude-code
    else
      _model_norm_multi "$i" "claude-code,${BASE[i]}"
      BASE[i]="$MODEL_VALUE"
    fi
  fi
  i=0
  while [ "$i" -lt "$CAT_N" ]; do
    SEL[i]="${BASE[i]}"
    i=$((i + 1))
  done
  return 0
}

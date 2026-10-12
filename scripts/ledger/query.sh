# shellcheck shell=bash
# scripts/ledger/query.sh — the read verbs over the index (index.sh):
# `ledger show`, `ledger ls`, `ledger find`. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, index.sh's _lg_index
# and parse.sh's _lg_scratch_name. One jq process reads the index per run
# (a 3,000-item index is a few MB: one parse, one pass).
#
# Text is what agents read, so every line is one line (control characters
# become spaces) and long values are cut ("…"):
#   show  ≤ 25 lines: "<key|path>  <ledger>  <severity>  <status>", the
#         summary, then path/status/date, spec·plan·handoff,
#         changes·consumes·relates, and — when present — files, aliases,
#         superseded by, owed, the first resolution line (a terminal item:
#         fixed / closed / won't fix class; "(none)" when it has none) and
#         the first frontmatter error. Lists show 3 entries and "+N more".
#   ls    "<key|path stem>  <severity>  <status>  <summary>" per item,
#         columns padded to the widest value shown, the status cut at 24
#         characters and the summary at 72; sorted by severity_order (case-
#         insensitive; a value outside it after, no severity last), then
#         date (oldest first), then path.
#   find  "<score>  <key|path stem>  <severity>  <status>  <summary>", the
#         top 15, then "… N more matches" when there are more.
# The status shown is design §E.1's display of the index's derived status:
# "superseded → <key>", "merged · owed: <owed>", "in review #<pr>",
# "on branch <b>", else the bare label.
#
# show <ref>: <ref> is a key (case-insensitive), a path from the top level
# ("./" allowed) or — the first column ls prints for an item without a key —
# a path stem. Unknown → rc 1 with one line; a ref several items match →
# rc 3 naming them (Task 6's _lg_resolve replaces this resolution and adds
# aliases, "L 14" / "L #14" and legacy refs).
#
# find <words…>: per item, the sum over the distinct words (lowercased,
# split on whitespace) of 3 when the word occurs in "<key> <summary>", 2 in
# "<H1> <file-name stem>", 1 in the first paragraph (substring matches,
# case-insensitive); score 0 is no match. Ties: severity, date, path.

_LG_STATUS_LABELS='["superseded","won'"'"'t fix","closed","shipped","merged","in review","on branch","planned","spec'"'"'d","not started"]'

# shellcheck disable=SC2016  # jq source
_LG_JQ_QUERY_DEFS='
def lg_q_one: if type == "string" and test("[[:cntrl:]]") then gsub("[[:cntrl:]]+"; " ") else . end;
def lg_q_cut($n): if length > $n then .[0:($n - 1)] + "…" else . end;
def lg_q_pad($w): (($w - length) as $k | if $k > 0 then . + (" " * $k) else . end);
# The jq builtins ascii_downcase / ascii_upcase / sub cost ~0.05–0.16 s per
# 3,000 strings (they are jq-defined); split, endswith, slices and
# test(re; "i") do not.
def lg_q_stem: .path | split("/") | last | if endswith(".md") then .[0:-3] else . end;
# lg_q_re: the string as a regex matching it literally.
def lg_q_re: gsub("(?<c>[.\\[\\]\\\\^$|?*+(){}])"; "\\\(.c)");
def lg_q_id: (.key // lg_q_stem) | lg_q_one;
def lg_q_display:
  .derived as $d | ($d.detail // null) as $x
  | (if $d.status == "superseded" then "superseded → \($x // "?")"
     elif $d.status == "merged" then (if $x == null then "merged" else "merged · owed: \($x)" end)
     elif $d.status == "in review" then "in review #\($x // "?")"
     elif $d.status == "on branch" then "on branch \($x // "?")"
     else ($d.status // "?") end)
  | lg_q_one;
def lg_q_cluster: (.changes[0] // .consumes[0] // null);
# lg_q_rank($R; $n): the place of the severity in severity_order ($R:
# {SEV: i}, case-insensitive); a value outside it $n, none $n + 1.
def lg_q_rank($R; $n):
  .severity as $s
  | if ($s | type) != "string" then $n + 1 else ($R[$s] // $R[$s | ascii_upcase] // $n) end;
def lg_q_ranks($c):
  ([($c.severity_order // [])[] | strings | ascii_upcase]) as $ord
  | {R: ($ord | to_entries | map({key: .value, value: .key}) | from_entries), n: ($ord | length)};
# lg_q_rows($lead): text rows {lead?, id, sev, d, s} → padded lines.
def lg_q_lines:
  if length == 0 then empty else
    (map(.lead | length) | max) as $wl
    | (map(.id | length) | max) as $wi
    | (map(.sev | length) | max) as $ws
    | (map(.d | length) | max) as $wd
    | .[]
    | (if $wl > 0 then (.lead | lg_q_pad($wl)) + "  " else "" end)
      + (.id | lg_q_pad($wi)) + "  " + (.sev | lg_q_pad($ws)) + "  "
      + (if .s == "" then .d else (.d | lg_q_pad($wd)) + "  " + .s end)
  end;
def lg_q_row($lead):
  {lead: $lead, id: lg_q_id, sev: ((.severity // "—") | lg_q_one),
   d: (lg_q_display | lg_q_cut(24)), s: ((.summary // "") | lg_q_one | lg_q_cut(72))};
'

# _lg_q_status_label <value>: the derived-status label <value> names (case,
# spaces, apostrophes, "-" and "_" ignored) into _LG_QSTATUS; "" when none.
_lg_q_status_label() {
  _LG_QSTATUS=$(jq -nr --arg v "$1" --argjson labels "$_LG_STATUS_LABELS" '
    def n: ascii_downcase | gsub("[\\s'"'"'\u2019_-]"; "");
    ($v | n) as $k | first($labels[] | select(n == $k)) // ""') \
    || _lg_die "jq failed (--status)"
}

# _lg_q_run <program> <out> [jq args…]: run a query program over the index
# (raw output into <out>); its first line is "ok" or "<problem>\t<detail>",
# which is left in _LG_QHEAD — the rest of <out> stays.
_lg_q_run() {
  local prog="$1" out="$2" ix
  shift 2
  ix=$(_lg_index)
  jq -r --slurpfile c "$_LG_CFG" "$@" "$_LG_JQ_QUERY_DEFS$prog" "$ix" > "$out.all" \
    || _lg_die "jq failed (ledger $_LG_VERB)"
  IFS= read -r _LG_QHEAD < "$out.all" || _LG_QHEAD=""
  tail -n +2 "$out.all" > "$out" || _lg_die "cannot write $out"
}

# _lg_q_finish <out>: print <out> as the run's output — the verdict object
# in --format json (the program printed the payload as one line), the lines
# in text mode — and end the run with rc 0.
_lg_q_finish() {
  local out="$1"
  if [ "$_LG_FORMAT" = json ]; then
    _lg_emit "$_LG_VERB" 0 "$out"
  fi
  _lg_out_file "$out"
  _lg_emit "$_LG_VERB" 0
}

# --- show ------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq source
_LG_JQ_SHOW='
def lg_q_list($n):
  [.[] | strings | lg_q_one]
  | if length == 0 then "—" else (.[0:$n] | join(", ")) + (if length > $n then " +\(length - $n) more" else "" end) end;
($ref | if startswith("./") then sub("^(\\./)+"; "") else . end) as $p
| ("^" + ($ref | lg_q_re) + "$") as $kre
| [.items[] | select(.path == $p)] as $byp
| (if $byp != [] then $byp
   else [.items[] | select(.key == $ref)] as $byk
   | if $byk != [] then $byk
     else [.items[] | select((.key | type) == "string" and (.key | test($kre; "i")))] as $byi
     | if $byi != [] then $byi else [.items[] | select(lg_q_stem == $p)] end
     end
   end) as $m
| if ($m | length) == 0 then "none", (if $mode == "json" then ({item: null, ref: $ref} | tojson) else empty end)
  elif ($m | length) > 1 then "ambiguous\t\($m | map(.path) | join(", "))"
  else $m[0] as $it
  | "ok",
    (if $mode == "json" then ({item: $it, display: ($it | lg_q_display)} | tojson)
     else $it
     | "\(.key // .path | lg_q_one)  \(.ledger // "—" | lg_q_one)  \(.severity // "—" | lg_q_one)  \(lg_q_display)",
       (.summary // "(no summary)" | lg_q_one),
       "path: \(.path | lg_q_one)\(if .archived then " (archived)" else "" end) · status: \(.status // "—" | lg_q_one) (\(.class)) · date: \(.date // "—")",
       (if (.h1 | type) == "string" and .h1 != .summary then "title: \(.h1 | lg_q_one | lg_q_cut(160))" else empty end),
       "spec: \(.docs.spec | lg_q_list(3)) · plan: \(.docs.plan | lg_q_list(3)) · handoff: \(.docs.handoff | lg_q_list(3))",
       "changes: \(.changes | lg_q_list(3)) · consumes: \(.consumes | lg_q_list(3)) · relates: \([.relates[] | if .kind == null then .key else "\(.kind):\(.key)" end] | lg_q_list(3))",
       (if .paths != [] then "files: \(.paths | lg_q_list(3))" else empty end),
       (if .aliases != [] then "aliases: \(.aliases | lg_q_list(3))" else empty end),
       (if .superseded_by != null and .derived.status != "superseded" then "superseded by: \(.superseded_by | lg_q_one)" else empty end),
       (if .owed != null then "owed: \(.owed | lg_q_one | lg_q_cut(160))" else empty end),
       (if .class == "fixed" or .class == "closed" or .class == "wontfix"
        then "resolution: \(.resolution // "(none)" | lg_q_one | lg_q_cut(200))" else empty end),
       (if .fm_errors != [] then "frontmatter: \(.fm_errors[0] | lg_q_one | lg_q_cut(160))\(if (.fm_errors | length) > 1 then " (+\((.fm_errors | length) - 1) more)" else "" end)" else empty end)
     end)
  end
'

# shellcheck disable=SC2154  # _ARGS is set by _parse_args
cmd_ledger_show() {
  local s
  _lg_init show
  [ "${#_ARGS[@]}" = 1 ] || _lg_usage "give one item: a key or a path"
  [ -n "${_ARGS[0]}" ] || _lg_usage "the item is empty"
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_SHOW" "$s.out" --arg ref "${_ARGS[0]}" --arg mode "$_LG_FORMAT"
  case "$_LG_QHEAD" in
    ok) _lg_q_finish "$s.out" ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then _lg_emit show 1 "$s.out"; fi
      printf "no item matches '%s'\n" "${_ARGS[0]}" | tr -d '\000-\010\013-\037' | head -n 1 > "$s.msg"
      _lg_out_file "$s.msg"
      _lg_emit show 1
      ;;
    ambiguous*) _lg_usage "'${_ARGS[0]}' matches several items: ${_LG_QHEAD#*	}" ;;
    *) _lg_die "internal: ledger show: unexpected query result '$_LG_QHEAD'" ;;
  esac
}

# --- ls --------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq source
_LG_JQ_LS='
. as $ix
| lg_q_ranks($c[0]) as $K
| ($sev | split(",") | map(gsub("\\s"; "")) | map(select(. != ""))) as $sevs
| ("^(" + ($sevs | map(lg_q_re) | join("|")) + ")$") as $sevre
| ("^" + ($ledger | lg_q_re) + "$") as $lre
| if $ledger != "" and ([$ix.ledgers[]? | .id | strings] + ["unassigned"] + [$ix.items[] | .ledger | strings]
                        | any(.[]; test($lre; "i")) | not)
  then "unknown-ledger\t\([$ix.ledgers[]? | .id | strings] | join(", "))"
  else
    [ $ix.items[]
      | select($ledger == "" or .ledger == $ledger or ((.ledger | type) == "string" and (.ledger | test($lre; "i"))))
      | select($open == "" or .class == "open")
      | select($status == "" or .derived.status == $status)
      | lg_q_cluster as $cl
      | select($cluster == "" or ($cluster == "unclustered" and $cl == null) or $cl == $cluster)
      | select($sevs == [] or ((.severity | type) == "string" and (.severity | test($sevre; "i"))))
      | {key, path, ledger, severity, status, class, derived, display: lg_q_display, date, summary,
         cluster: $cl, archived, _r: lg_q_rank($K.R; $K.n)} ]
    | sort_by(._r, (.date // "9999-99-99"), .path)
    | map(del(._r))
    | "ok", (if $mode == "json" then ({items: .} | tojson) else (map(lg_q_row("")) | lg_q_lines) end)
  end
'

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_ls() {
  local s status=""
  _lg_init ls
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  if [ -n "$_OPT_status" ]; then
    _lg_q_status_label "$_OPT_status"
    status=$_LG_QSTATUS
    if [ -z "$status" ]; then
      _lg_usage "--status '$_OPT_status' is not a status: $(jq -r 'join(", ")' <<<"$_LG_STATUS_LABELS")"
    fi
  fi
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_LS" "$s.out" --arg mode "$_LG_FORMAT" --arg ledger "$_OPT_ledger" --arg sev "$_OPT_sev" \
    --arg open "$_OPT_open" --arg status "$status" --arg cluster "$_OPT_cluster"
  case "$_LG_QHEAD" in
    ok) _lg_q_finish "$s.out" ;;
    unknown-ledger*) _lg_usage "--ledger '$_OPT_ledger' is not a ledger (registry: ${_LG_QHEAD#*	})" ;;
    *) _lg_die "internal: ledger ls: unexpected query result '$_LG_QHEAD'" ;;
  esac
}

# --- find ------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq source
_LG_JQ_FIND='
lg_q_ranks($c[0]) as $K
| ($words | ascii_downcase | [splits("\\s+")] | map(select(. != "")) | unique | map(lg_q_re)) as $W
| [ .items[]
    | . as $it
    | lg_q_stem as $stem
    | ([$W[] | . as $re
        | (if (($it.key // "") | test($re; "i")) or (($it.summary // "") | test($re; "i")) then 3 else 0 end)
          + (if (($it.h1 // "") | test($re; "i")) or ($stem | test($re; "i")) then 2 else 0 end)
          + (if (($it.first_para // "") | test($re; "i")) then 1 else 0 end)] | add // 0) as $score
    | select($score > 0)
    | {score: $score, key, path, ledger, severity, derived, display: lg_q_display, date, summary,
       _r: lg_q_rank($K.R; $K.n)} ]
| sort_by(-.score, ._r, (.date // "9999-99-99"), .path)
| map(del(._r))
| length as $total
| .[0:15]
| "ok",
  (if $mode == "json" then ({matches: $total, items: .} | tojson)
   elif $total == 0 then "no items match"
   else (map(lg_q_row(.score | tostring)) | lg_q_lines),
        (if $total > 15 then "… \($total - 15) more matches" else empty end)
   end)
'

# shellcheck disable=SC2154  # _ARGS is set by _parse_args
cmd_ledger_find() {
  local s words="" a
  _lg_init find
  for a in ${_ARGS[@]+"${_ARGS[@]}"}; do
    words="$words $a"
  done
  case "$words" in
    *[![:space:]]*) ;;
    *) _lg_usage "give the words to look for" ;;
  esac
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_FIND" "$s.out" --arg mode "$_LG_FORMAT" --arg words "$words"
  case "$_LG_QHEAD" in
    ok) _lg_q_finish "$s.out" ;;
    *) _lg_die "internal: ledger find: unexpected query result '$_LG_QHEAD'" ;;
  esac
}

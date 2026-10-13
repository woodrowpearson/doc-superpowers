# shellcheck shell=bash
# scripts/ledger/query.sh — the read verbs over the index (index.sh):
# `ledger show`, `ledger ls`, `ledger find`, and `ledger link`, which writes
# a confirmed relation into an item. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, index.sh's _lg_index
# and parse.sh's _lg_scratch_name. One jq process reads the index per run
# (a 3,000-item index is a few MB: one parse, one pass).
#
# Text is what agents read, so every line is one line (control characters
# become spaces) and long values are cut ("…"):
#   show  ≤ 25 lines: "<key|path>  <ledger>  <severity>  <status>", the
#         summary, then path/status/date, spec·plan·handoff,
#         changes·consumes·relates, and — when present — the neighbours
#         ("upstream: <key> (<via>), …", downstream, siblings; relations.sh),
#         the re-check markers ("re-check: <key> landed, <contract>
#         changed"), the in-flight claims ("in flight: <branch>
#         (<sources>[@<host>], PR #<n>|no PR)", inflight.sh), files, aliases,
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
# "on branch <b>", else the bare label. show and ls take --refresh: the PR
# list (config adapters.pr) is fetched now, not read from a copy younger
# than cache.remote_ttl_minutes (index.sh, adapters.sh _lg_remote_cache);
# its failure is exit 2. Without it a failing adapter is one stderr line
# and exit 0.
#
# show <ref>: whatever keys.sh's lg_resolve accepts — a path from the top
# level ("./" allowed), a key or an alias (case-insensitive; "L 14" and
# "L #14" too, as one argument or several words), a provisional key that was
# finalized, a legacy ref ("<old>#<n>", "<old> row <n>", "<old> ledger row
# <n>"), or — the first column ls prints for an item without a key — a path
# stem; resolution and display are one jq pass over the index. Unknown → rc 1
# with one line; a ref several items match → rc 3 naming them; a legacy row
# that was archived → "archived: <anchor>", rc 0.
#
# find <words…>: per item, the sum over the distinct words (lowercased,
# split on whitespace) of 3 when the word occurs in "<key> <summary>", 2 in
# "<H1> <file-name stem>", 1 in the first paragraph (substring matches,
# case-insensitive); score 0 is no match. Ties: severity, date, path.

# The display helpers (lg_q_*, lg_status_labels) live in defs.jq, shared
# with the renderers; every program here starts with _LG_JQ_INCLUDE and
# runs as `jq -L "$_LG_LIB"`.
_LG_JQ_QUERY_DEFS="$_LG_JQ_INCLUDE"

# _lg_q_status_label <value>: the derived-status label <value> names (case,
# spaces, apostrophes, "-" and "_" ignored) into _LG_QSTATUS; "" when none.
_lg_q_status_label() {
  _LG_QSTATUS=$(jq -L "$_LG_LIB" -nr --arg v "$1" "$_LG_JQ_INCLUDE"'
    def n: ascii_downcase | gsub("[\\s'"'"'\u2019_-]"; "");
    ($v | n) as $k | first(lg_status_labels[] | select(n == $k)) // ""') \
    || _lg_die "jq failed (--status)"
}

# _lg_q_run <program> <out> [jq args…]: run a query program over the index
# (raw output into <out>); its first line is "ok" or "<problem>\t<detail>",
# which is left in _LG_QHEAD — the rest of <out> stays. With in-flight
# awareness on (inflight.sh), the scan runs beside the index build (its
# notes join the index's one stderr note) and the overlay is applied to
# the index in the same jq pass (defs.jq lg_ifl_apply) — the index itself
# never depends on a branch tip.
_lg_q_run() {
  local prog="$1" out="$2" ix
  shift 2
  _lg_ifl_prepare_bg
  ix=$(_lg_index)
  _lg_ifl_prepare_wait
  _lg_ifl_index_note
  _lg_ifl_overlay "$ix"
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" --slurpfile ifl "${_LG_IFL_OV:-/dev/null}" "$@" \
    "$_LG_JQ_QUERY_DEFS"'lg_ifl_apply($ifl[0]) | '"$prog" "$ix" > "$out.all" \
    || _lg_die "jq failed (ledger $_LG_VERB)"
  IFS= read -r _LG_QHEAD < "$out.all" || _LG_QHEAD=""
  tail -n +2 "$out.all" > "$out" || _lg_die "cannot write $out"
}

# _lg_pr_data_into <payload-file>: add "pr_data" (the index build's PR data
# state, $_SCRATCH/lg-pr.json — index.sh _lg_ix_pr_prepare) to the JSON
# payload, so a stale or missing PR list never reads as a clean answer;
# nothing when no worktree or rev index was built this run.
_lg_pr_data_into() {
  [ -s "$_SCRATCH/lg-pr.json" ] || return 0
  if ! jq -c --slurpfile pd "$_SCRATCH/lg-pr.json" '. + {pr_data: $pd[0]}' "$1" > "$1.pd" || ! mv -f -- "$1.pd" "$1"; then
    _lg_die "jq failed (pr_data)"
  fi
}

# _lg_q_finish <out>: print <out> as the run's output — the verdict object
# in --format json (the program printed the payload as one line), the lines
# in text mode — and end the run with rc 0.
_lg_q_finish() {
  local out="$1"
  if [ "$_LG_FORMAT" = json ]; then
    _lg_pr_data_into "$out"
    _lg_emit "$_LG_VERB" 0 "$out"
  fi
  _lg_out_file "$out"
  _lg_emit "$_LG_VERB" 0
}

# --- show ------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq source
_LG_JQ_SHOW="$_LG_JQ_RESOLVE_DEFS"'
def lg_q_list($n):
  [.[] | strings | lg_q_one]
  | if length == 0 then "—" else (.[0:$n] | join(", ")) + (if length > $n then " +\(length - $n) more" else "" end) end;
lg_resolve($ref; $c[0]) as $R
| (if $R.r == "item" then [.items[] | select(.path == $R.v)] else [] end) as $m
| if $R.r == "archived" then
    "archived",
    (if $mode == "json" then ({item: null, ref: $ref, archived: $R.v} | tojson) else "archived: \($R.v | lg_q_one)" end)
  elif $R.r == "ambiguous" then "ambiguous\t\($R.v | join(", "))"
  elif ($m | length) == 0 then "none", (if $mode == "json" then ({item: null, ref: $ref} | tojson) else empty end)
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
       ((.neighbours // {}) as $n
        | (if ($n.upstream // []) != [] then "upstream: \($n.upstream | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end),
          (if ($n.downstream // []) != [] then "downstream: \($n.downstream | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end),
          (if ($n.siblings // []) != [] then "siblings: \($n.siblings | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end)),
       (lg_r_recheck_text | if . != "" then (lg_q_one | lg_q_cut(200)) else empty end),
       (lg_ifl_lines | if . != [] then "in flight: \(lg_q_list(3))" else empty end),
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
  local s ref a
  _lg_init show
  [ "${#_ARGS[@]}" -ge 1 ] || _lg_usage "give one item: a key, an alias, a legacy ref or a path"
  ref=${_ARGS[0]}
  if [ "${#_ARGS[@]}" -gt 1 ]; then
    # Several words: one of the spaced forms ("L 14", "<old> row <n>", …).
    for a in "${_ARGS[@]:1}"; do ref="$ref $a"; done
    _lg_k_multiword "$ref" || _lg_usage "give one item: a key, an alias, a legacy ref or a path (got ${#_ARGS[@]} arguments)"
  fi
  [ -n "$ref" ] || _lg_usage "the item is empty"
  _LG_IX_NEED_CONTRACTS=1
  if [ -n "$_OPT_refresh" ]; then _LG_REMOTE_FORCE=1; fi
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_SHOW" "$s.out" --arg ref "$ref" --arg mode "$_LG_FORMAT"
  case "$_LG_QHEAD" in
    ok|archived) _lg_q_finish "$s.out" ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then _lg_emit show 1 "$s.out"; fi
      printf "no item matches '%s'\n" "$ref" | tr -d '\000-\010\013-\037' | head -n 1 > "$s.msg"
      _lg_out_file "$s.msg"
      _lg_emit show 1
      ;;
    ambiguous*) _lg_usage "'$ref' matches several items: ${_LG_QHEAD#*	}" ;;
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
      _lg_usage "--status '$_OPT_status' is not a status: $(jq -L "$_LG_LIB" -nr "$_LG_JQ_INCLUDE"'[lg_status_labels[]] | join(", ")')"
    fi
  fi
  if [ -n "$_OPT_refresh" ]; then _LG_REMOTE_FORCE=1; fi
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

# --- link ------------------------------------------------------------------------

# ledger link <ref> [--consumes C] [--changes C] [--relates <kind>:<item>]:
# validate every value first — a contract must be one the index knows
# (registry or contracts adapter); a relates kind is root-cause, depends-on
# or sibling (case-insensitive) and names, as show resolves, one other item
# that has a key — then add them to the item's frontmatter lists in one
# write (parse.sh _lg_fm_op_list_add; a value already there stays). The
# field is the first configured candidate name (config fields) the file
# has, else the first candidate. A relates value is written "<kind>:<key>"
# with the target's key as the item spells it. Text: "<item>  <field>:
# <value>  (added | already there)" per value. Any bad value: one "link:
# <problem>" line each, exit 1, nothing written. JSON: {path, key, added:
# [{field, value}], present: [{field, value}]} or {problems: [...]}.

# shellcheck disable=SC2016  # jq source
_LG_JQ_LINK="$_LG_JQ_RESOLVE_DEFS"'
. as $ix
| lg_resolve($ref; $c[0]) as $R
| if $R.r == "ambiguous" then "ambiguous\t\($R.v | join(", "))"
  elif $R.r == "archived" then "archived\t\($R.v)"
  elif $R.r != "item" then "none"
  else
    first($ix.items[] | select(.path == $R.v)) as $I
    | [($ix.contracts // [])[] | .id] as $ids
    | [ ($ops[] | select(.f == "consumes" or .f == "changes") | . as $o
         | if ($ids | index([$o.v])) != null then {f: $o.f, v: $o.v}
           else {p: "--\($o.f) \($o.v | tojson) is not a contract (registry or contracts adapter)"} end),
        ($ops[] | select(.f == "relates") | . as $o
         | ($o.v | capture("^(?<k>[^:]*):(?<t>.+)$") // null) as $m
         | if $m == null then {p: "--relates \($o.v | tojson) is not <kind>:<item>"}
           elif (lg_rel_kinds | index([$m.k | ascii_downcase])) == null
           then {p: "--relates kind \($m.k | tojson) is not root-cause, depends-on or sibling"}
           else ($ix | lg_resolve($m.t; $c[0])) as $T
             | if $T.r == "ambiguous" then {p: "--relates \($m.t | tojson) matches several items: \($T.v | join(", "))"}
               elif $T.r != "item" then {p: "--relates \($m.t | tojson) is not an item"}
               elif $T.v == $I.path then {p: "--relates \($m.t | tojson) is the item itself"}
               else first($ix.items[] | select(.path == $T.v)) as $Y
                 | if ($Y.key | type) != "string" then {p: "--relates \($m.t | tojson) (\($Y.path)) has no key"}
                   else {f: "relates", v: "\($m.k | ascii_downcase):\($Y.key)"} end
               end
           end) ] as $V
    | ($V | map(select(has("p")) | .p)) as $P
    | if $P != [] then "bad", $P[]
      else "ok", ($I.key // ""), ($V[] | "\(.f)\t\(.v)") end
  end
'

# _lg_link_names <file>: the frontmatter names of changes, consumes and
# relates for <file> (the first configured candidate the file has, else the
# first candidate) into _LG_LN_changes, _LG_LN_consumes, _LG_LN_relates.
_lg_link_names() {
  local d
  _lg_parse_prep
  d=$(mktemp "$_SCRATCH/lg-ln.XXXXXX") || _lg_die "mktemp failed"
  LC_ALL=C awk -v path=x "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" < "$1" > "$d.rec" \
    || _lg_die "cannot parse $1"
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F | (.fm // {}) as $fm
    | ("changes", "consumes", "relates") as $l
    | ($F[$l] // []) as $cs
    | (first($cs[] | select(. as $n | $fm | has($n))) // $cs[0] // $l)' "$d.rec" > "$d" \
    || _lg_die "jq failed (field names of $1)"
  { IFS= read -r _LG_LN_changes; IFS= read -r _LG_LN_consumes; IFS= read -r _LG_LN_relates; } < "$d" \
    || _lg_die "cannot read the field names of $1"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_link() {
  local s ref a ops f v key path n field status
  _lg_init link
  [ "${#_ARGS[@]}" -ge 1 ] || _lg_usage "give one item: a key, an alias, a legacy ref or a path"
  ref=${_ARGS[0]}
  if [ "${#_ARGS[@]}" -gt 1 ]; then
    for a in "${_ARGS[@]:1}"; do ref="$ref $a"; done
    _lg_k_multiword "$ref" || _lg_usage "give one item: a key, an alias, a legacy ref or a path (got ${#_ARGS[@]} arguments)"
  fi
  [ -n "$ref" ] || _lg_usage "the item is empty"
  if [ -z "$_OPTSEEN_consumes$_OPTSEEN_changes$_OPTSEEN_relates" ]; then
    _lg_usage "give --consumes <contract>, --changes <contract> or --relates <kind>:<item>"
  fi
  for v in "$_OPT_consumes" "$_OPT_changes" "$_OPT_relates"; do
    case "$v" in *[$'\n\r']*) _lg_usage "a value cannot hold a line break" ;; esac
  done
  ops=$(jq -nc --arg cs "$_OPT_consumes" --arg ch "$_OPT_changes" --arg rl "$_OPT_relates" \
    --arg scs "$_OPTSEEN_consumes" --arg sch "$_OPTSEEN_changes" --arg srl "$_OPTSEEN_relates" '
    [(if $scs == "1" then {f: "consumes", v: $cs} else empty end),
     (if $sch == "1" then {f: "changes", v: $ch} else empty end),
     (if $srl == "1" then {f: "relates", v: $rl} else empty end)]') || _lg_die "jq failed (link values)"
  _LG_IX_NEED_CONTRACTS=1
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_LINK" "$s.out" --arg ref "$ref" --argjson ops "$ops"
  case "$_LG_QHEAD" in
    ok) ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then
        jq -nc --arg r "$ref" '{item: null, ref: $r}' > "$s.json" || _lg_die "jq failed (payload)"
        _lg_emit link 1 "$s.json"
      fi
      printf "no item matches '%s'\n" "$ref" | tr -d '\000-\010\013-\037' | head -n 1 > "$s.msg"
      _lg_out_file "$s.msg"
      _lg_emit link 1 ;;
    bad)
      if [ "$_LG_FORMAT" = json ]; then
        jq -R -n -c '{problems: [inputs]}' "$s.out" > "$s.json" || _lg_die "jq failed (payload)"
        _lg_emit link 1 "$s.json"
      fi
      sed 's/^/link: /' "$s.out" | tr -d '\000-\010\013-\037' > "$s.msg"
      _lg_out_file "$s.msg"
      _lg_emit link 1 ;;
    ambiguous*) _lg_usage "'$ref' matches several items: ${_LG_QHEAD#*	}" ;;
    archived*) _lg_usage "'$ref' is an archived legacy row (${_LG_QHEAD#*	}): there is no item to link" ;;
    *) _lg_die "internal: ledger link: unexpected query result '$_LG_QHEAD'" ;;
  esac
  _lg_resolve_into "$ref"
  [ "$_LG_RES_KIND" = item ] || _lg_die "internal: ledger link: '$ref' no longer resolves"
  path=$_LG_RES
  [ -f "$path" ] || _lg_die "the item '$path' is not in the working tree"
  { IFS= read -r key; cat > "$s.ops"; } < "$s.out"
  _lg_link_names "$path"
  # One write: every value queued, then applied.
  _lg_fm_ops_reset
  : > "$s.res"
  while IFS="$(printf '\t')" read -r f v; do
    case "$f" in
      changes) field=$_LG_LN_changes ;;
      consumes) field=$_LG_LN_consumes ;;
      relates) field=$_LG_LN_relates ;;
      *) _lg_die "internal: ledger link field '$f'" ;;
    esac
    n=$_LG_FMO_N
    _lg_fm_op_list_add "$path" "$field" "$v"
    if [ "$_LG_FMO_N" -gt "$n" ]; then status=added; else status=present; fi
    printf '%s\t%s\t%s\n' "$status" "$field" "$v" >> "$s.res"
  done < "$s.ops"
  # Queued list adds read the file as it is now: two adds to one field
  # would each rewrite the list from the same start — one op per field
  # (the values of one field are never more than one per run).
  _lg_fm_ops_apply "$path"
  if [ "$_LG_FORMAT" = json ]; then
    jq -R -n -c --arg p "$path" --arg k "$key" '
      [inputs | split("\t") | {s: .[0], field: .[1], value: .[2]}] as $r
      | {path: $p, key: (if $k == "" then null else $k end),
         added: [$r[] | select(.s == "added") | {field, value}],
         present: [$r[] | select(.s == "present") | {field, value}]}' "$s.res" > "$s.json" \
      || _lg_die "jq failed (payload)"
    _lg_emit link 0 "$s.json"
  fi
  LC_ALL=C awk -F '\t' -v id="${key:-$path}" '{ print id "  " $2 ": " $3 "  (" ($1 == "added" ? "added" : "already there") ")" }' \
    "$s.res" | tr -d '\000-\010\013-\037' > "$s.lines"
  _lg_out_file "$s.lines"
  _lg_emit link 0
}

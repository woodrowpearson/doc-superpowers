# shellcheck shell=bash
# scripts/ledger/query.sh — the read verbs over the index (index.sh):
# `ledger show`, `ledger ls`, `ledger find`; `ledger link`, which writes a
# confirmed relation into an item, and `ledger note`, which writes a dated
# line or what an item owes (below). Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, index.sh's _lg_index
# and parse.sh's _lg_scratch_name. One jq process reads the index per run
# (a 3,000-item index is a few MB: one parse, one pass).
#
# Text is what agents read, so every line is one line (control characters
# become spaces) and long values are cut ("…"):
#   show  ≤ 25 lines: "<key|path>  <ledger>  <severity>  <status>", the
#         summary, then path/status/date, the url of a hosted item (config
#         items.adapter: its path is the adapter's ref), spec·plan·handoff,
#         changes·consumes·relates, and — when present — the neighbours
#         ("upstream: <key> (<via>), …", downstream, siblings; relations.sh),
#         the re-check markers ("re-check: <key> landed, <contract>
#         changed"), the in-flight claims ("in flight: <branch>
#         (<sources>[@<host>], PR #<n>|no PR)", inflight.sh), files, aliases,
#         superseded by, owed, the first resolution line (a terminal file
#         item: fixed / closed / won't fix class; "(none)" when it has none;
#         a hosted item's reason lives on the issue) and
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
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    ifl-index-delay) sleep 1 ;;
  esac
  ix=$(_lg_index) || exit "$?"
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
# nothing when no worktree or rev index was built this run. With config
# items.adapter, "items_data" too (the hosted items' copy: index.sh
# _lg_ix_items_prepare).
_lg_pr_data_into() {
  if [ -s "$_SCRATCH/lg-pr.json" ]; then
    if ! jq -c --slurpfile pd "$_SCRATCH/lg-pr.json" '. + {pr_data: $pd[0]}' "$1" > "$1.pd" || ! mv -f -- "$1.pd" "$1"; then
      _lg_die "jq failed (pr_data)"
    fi
  fi
  if [ -s "$_SCRATCH/lg-items.json" ]; then
    if ! jq -c --slurpfile hd "$_SCRATCH/lg-items.json" '. + {items_data: $hd[0]}' "$1" > "$1.pd" || ! mv -f -- "$1.pd" "$1"; then
      _lg_die "jq failed (items_data)"
    fi
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
       (if (.url | type) == "string" then "url: \(.url | lg_q_one | lg_q_cut(200))" else empty end),
       (if (.h1 | type) == "string" and .h1 != .summary then "title: \(.h1 | lg_q_one | lg_q_cut(160))" else empty end),
       "spec: \(.docs.spec | lg_q_list(3)) · plan: \(.docs.plan | lg_q_list(3)) · handoff: \(.docs.handoff | lg_q_list(3))",
       "changes: \(.changes | lg_q_list(3)) · consumes: \(.consumes | lg_q_list(3)) · relates: \([.relates[] | if .kind == null then .key else "\(.kind):\(.key)" end] | lg_q_list(3))",
       ((.neighbours // {}) as $n
        | (if ($n.upstream // []) != [] then "upstream: \($n.upstream | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end),
          (if ($n.downstream // []) != [] then "downstream: \($n.downstream | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end),
          (if ($n.siblings // []) != [] then "siblings: \($n.siblings | map("\(.key) (\(.via))") | lg_q_list(3))" else empty end)),
       (lg_r_recheck_text | if . != "" then (lg_q_one | lg_q_cut(200)) else empty end),
       (lg_ifl_lines | if . != [] then "in flight: \(lg_q_list(3))" else empty end),
       (lg_r_claims_text(" · ") | if . != "" then . else empty end),
       (if .paths != [] then "files: \(.paths | lg_q_list(3))" else empty end),
       (if .aliases != [] then "aliases: \(.aliases | lg_q_list(3))" else empty end),
       (if .superseded_by != null and .derived.status != "superseded" then "superseded by: \(.superseded_by | lg_q_one)" else empty end),
       (if .owed != null then "owed: \(.owed | lg_q_one | lg_q_cut(160))" else empty end),
       (if (.class == "fixed" or .class == "closed" or .class == "wontfix") and (.url | type) != "string"
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

# ledger link <ref> [--consumes C[,C…]] [--changes C[,C…]]
# [--relates <kind>:<item>[,…]] | --relations none:
# validate every value first — a contract must be one the index knows
# (registry or contracts adapter); a relates kind is root-cause, depends-on
# or sibling (case-insensitive) and names, as show resolves, one other item
# that has a key — then add them to the item's frontmatter lists in one
# write (parse.sh _lg_fm_op_list_add; a value already there stays). The
# field is the first configured candidate name (config fields) the file
# has, else the first candidate. A relates value is written "<kind>:<key>"
# with the target's key as the item spells it.
# Several values (3.4.0): a flag's value that is not itself one valid value
# and holds a comma is a comma list — each piece, trimmed of surrounding
# blanks, is a value (an empty piece is a bad value); a single value reads
# as it did before. A value given twice in one run is one value.
# --relations none (3.4.0; any case) writes "relations: none" — the opt-out
# validate.require_relations reads — and nothing else: refused (a bad
# value) beside another relation flag, or when the item already names a
# changes, consumes or relates value. A link that writes a relation drops
# a relations: none marker in the same write.
# Text: "<item>  <field>: <value>  (added | already there)" per value,
# then "<item>  relations: none  (removed)" when a marker was dropped. Any
# bad value: one "link: <problem>" line each, exit 1, nothing written.
# JSON: {path, key, added: [{field, value}], present: [{field, value}]}
# (+ removed: [{field: "relations", value: "none"}] when a marker was
# dropped) or {problems: [...]}. The index is read once per run (the
# resolution of the item and every target happen in one jq pass).

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
    | def check($f; $v):
        if $f == "consumes" or $f == "changes" then
          if ($ids | index([$v])) != null then {f: $f, v: $v}
          else {p: "--\($f) \($v | tojson) is not a contract (registry or contracts adapter)"} end
        else
          ($v | capture("^(?<k>[^:]*):(?<t>.+)$") // null) as $m
          | if $m == null then {p: "--relates \($v | tojson) is not <kind>:<item>"}
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
            end
        end;
      def values($f; $v):
        check($f; $v) as $w
        | if ($w | has("p")) and ($v | contains(",")) then
            ($v | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $ps
            | if any($ps[]; . == "") then [{p: "--\($f) \($v | tojson) holds an empty value"}]
              else [$ps[] | check($f; .)] end
          else [$w] end;
      ([$ops[] | select(.f != "relations")] | length) as $nrel
    | [ ($ops[] | select(.f != "relations") | values(.f; .v)[]),
        ($ops[] | select(.f == "relations") | .v as $v
         | if ($v | ascii_downcase | gsub("^\\s+|\\s+$"; "")) != "none" then {p: "--relations takes none (got \($v | tojson))"}
           elif $nrel > 0 then {p: "--relations none cannot be given with --changes, --consumes or --relates"}
           elif ((($I.changes // []) | length) + (($I.consumes // []) | length) + (($I.relates // []) | length)) > 0
           then {p: "--relations none: \(($I.key // $I.path)) already names relations (changes, consumes or relates)"}
           else {f: "relations", v: "none"} end) ] as $V
    | ($V | map(select(has("p")) | .p)) as $P
    | if $P != [] then "bad", $P[]
      else "ok", ($I.key // ""), $I.path,
        ($V | reduce .[] as $x ([]; if index([$x]) != null then . else . + [$x] end) | .[] | "\(.f)\t\(.v)") end
  end
'

# _lg_link_names <file>: the frontmatter names of changes, consumes and
# relates for <file> (the first configured candidate the file has, else the
# first candidate) into _LG_LN_changes, _LG_LN_consumes, _LG_LN_relates;
# _LG_LN_none: 1 when the file says relations: none (any case), else 0.
_lg_link_names() {
  local d
  _lg_parse_prep
  d=$(mktemp "$_SCRATCH/lg-ln.XXXXXX") || _lg_die "mktemp failed"
  LC_ALL=C awk -v path=x "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" < "$1" > "$d.rec" \
    || _lg_die "cannot parse $1"
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F | (.fm // {}) as $fm
    | (("changes", "consumes", "relates") as $l
       | ($F[$l] // []) as $cs
       | (first($cs[] | select(. as $n | $fm | has($n))) // $cs[0] // $l)),
      (if ($fm.relations | type) == "string" and ($fm.relations | ascii_downcase | gsub("^\\s+|\\s+$"; "")) == "none"
       then "1" else "0" end)' "$d.rec" > "$d" \
    || _lg_die "jq failed (field names of $1)"
  { IFS= read -r _LG_LN_changes; IFS= read -r _LG_LN_consumes; IFS= read -r _LG_LN_relates; IFS= read -r _LG_LN_none; } < "$d" \
    || _lg_die "cannot read the field names of $1"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_link() {
  local s ref a ops f v key path field st linked=0 vals
  _lg_init link
  [ "${#_ARGS[@]}" -ge 1 ] || _lg_usage "give one item: a key, an alias, a legacy ref or a path"
  ref=${_ARGS[0]}
  if [ "${#_ARGS[@]}" -gt 1 ]; then
    for a in "${_ARGS[@]:1}"; do ref="$ref $a"; done
    _lg_k_multiword "$ref" || _lg_usage "give one item: a key, an alias, a legacy ref or a path (got ${#_ARGS[@]} arguments)"
  fi
  [ -n "$ref" ] || _lg_usage "the item is empty"
  if [ -z "$_OPTSEEN_consumes$_OPTSEEN_changes$_OPTSEEN_relates$_OPTSEEN_relations" ]; then
    _lg_usage "give --consumes <contract>, --changes <contract>, --relates <kind>:<item> or --relations none"
  fi
  for v in "$_OPT_consumes" "$_OPT_changes" "$_OPT_relates" "$_OPT_relations"; do
    case "$v" in *[$'\n\r']*) _lg_usage "a value cannot hold a line break" ;; esac
  done
  ops=$(jq -nc --arg cs "$_OPT_consumes" --arg ch "$_OPT_changes" --arg rl "$_OPT_relates" --arg rn "$_OPT_relations" \
    --arg scs "$_OPTSEEN_consumes" --arg sch "$_OPTSEEN_changes" --arg srl "$_OPTSEEN_relates" --arg srn "$_OPTSEEN_relations" '
    [(if $scs == "1" then {f: "consumes", v: $cs} else empty end),
     (if $sch == "1" then {f: "changes", v: $ch} else empty end),
     (if $srl == "1" then {f: "relates", v: $rl} else empty end),
     (if $srn == "1" then {f: "relations", v: $rn} else empty end)]') || _lg_die "jq failed (link values)"
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
  # The item's key and path came with the check (one index read per run).
  { IFS= read -r key; IFS= read -r path; cat > "$s.ops"; } < "$s.out"
  [ -n "$path" ] || _lg_die "internal: ledger link: no path for '$ref'"
  [ -f "$path" ] || _lg_not_file_die "$path" link
  _lg_link_names "$path"
  # One write: every value queued, then applied. The values of one field go
  # in one _lg_fm_op_list_add call (queued adds each carry the list so far).
  _lg_fm_ops_reset
  : > "$s.res"
  for f in changes consumes relates; do
    case "$f" in
      changes) field=$_LG_LN_changes ;;
      consumes) field=$_LG_LN_consumes ;;
      relates) field=$_LG_LN_relates ;;
    esac
    vals=()
    while IFS="$(printf '\t')" read -r a v; do
      if [ "$a" = "$f" ]; then vals+=("$v"); fi
    done < "$s.ops"
    [ "${#vals[@]}" -gt 0 ] || continue
    linked=1
    _lg_fm_op_list_add "$path" "$field" "${vals[@]}"
    printf '%s\n' "$_LG_FMO_LA" > "$s.st"
    for v in "${vals[@]}"; do
      IFS= read -r st
      printf '%s\t%s\t%s\n' "$st" "$field" "$v"
    done < "$s.st" > "$s.res.$f"
  done
  # The results in the order the values were given.
  while IFS="$(printf '\t')" read -r a v; do
    case "$a" in
      changes|consumes|relates)
        LG_LKV="$v" LC_ALL=C awk -F '\t' '$3 == ENVIRON["LG_LKV"] { print; exit }' "$s.res.$a" >> "$s.res" ;;
      relations)
        if [ "$_LG_LN_none" = 1 ]; then st=present; else st=added; _lg_fm_op set relations none; fi
        printf '%s\trelations\tnone\n' "$st" >> "$s.res" ;;
      *) _lg_die "internal: ledger link field '$a'" ;;
    esac
  done < "$s.ops"
  # A relation written: the relations: none marker goes in the same write.
  if [ "$linked" = 1 ] && [ "$_LG_LN_none" = 1 ]; then
    _lg_fm_op del relations
    printf 'removed\trelations\tnone\n' >> "$s.res"
  fi
  _lg_fm_ops_apply "$path"
  if [ "$_LG_FORMAT" = json ]; then
    jq -R -n -c --arg p "$path" --arg k "$key" '
      [inputs | split("\t") | {s: .[0], field: .[1], value: .[2]}] as $r
      | {path: $p, key: (if $k == "" then null else $k end),
         added: [$r[] | select(.s == "added") | {field, value}],
         present: [$r[] | select(.s == "present") | {field, value}]}
      + ([$r[] | select(.s == "removed") | {field, value}] | if . == [] then {} else {removed: .} end)' "$s.res" > "$s.json" \
      || _lg_die "jq failed (payload)"
    _lg_emit link 0 "$s.json"
  fi
  LC_ALL=C awk -F '\t' -v id="${key:-$path}" '{ print id "  " $2 ": " $3 "  (" ($1 == "added" ? "added" : ($1 == "removed" ? "removed" : "already there")) ")" }' \
    "$s.res" | tr -d '\000-\010\013-\037' > "$s.lines"
  _lg_out_file "$s.lines"
  _lg_emit link 0
}

# _lg_not_file_die <path> <verb>: <path> is not a file of the working tree —
# die (2), naming a hosted item (config items.adapter) as one: <verb>
# writes item files only.
_lg_not_file_die() {
  local ix
  ix=$(_lg_index) || exit "$?"
  if jq -e --arg p "$1" 'any(.items[]; .path == $p and (.url | type) == "string")' "$ix" > /dev/null 2>&1; then
    _lg_die "$1 is a hosted item (config items.adapter): ledger $2 writes item files only — change it on its host"
  fi
  _lg_die "the item '$1' is not in the working tree"
}

# --- note ------------------------------------------------------------------------

# ledger note <item> <text> [--kind log|ruling|owed] (design §C; controller
# rulings R1, R2): the one deterministic home for an item's state. <item> is
# what show takes (several words: the spaced forms "L 14", "L #14"); <text>
# is the last argument, one line.
# A file item, written in place (a temp file beside it, then mv: every other
# byte kept — the BOM, the line endings, the final newline or its absence;
# nothing staged or committed):
#   log (the default)  "- <YYYY-MM-DD> <text>" (the local date) under config
#       log_heading;
#   ruling  "- <YYYY-MM-DD> RULING: <text>" under "## Rulings" —
#       after the section's last non-blank line, before the next heading of
#       the same or a higher level (a heading in a fenced block or in the
#       frontmatter never counts; the first such heading is the section); a
#       file without it gets the heading at its end, after one blank line; a
#       written line takes the file's line ending (CRLF when its first line
#       ends in CR);
#   owed  fields.owed (its first candidate name) set through fm-write.awk;
#       empty text removes it (every candidate name); no log line.
# A hosted item (config items.adapter; ruling R2): log → the adapter's
# `note <ref> <text>` (a comment carries its own time: no date), ruling →
# `note <ref> "RULING: <text>"`, owed → `write <ref> owed <text>` (empty
# clears it; a text holding "-->" or "--!>", which would close the issue's
# metadata comment, is usage: 3). The adapter failing or absent, or
# DOC_TOOLS_LEDGER_OFFLINE=1: exit 2, the reason named, no clean result. A
# write that succeeded marks the cached list expired (adapters.sh
# _lg_remote_expire): the next read fetches it.
# Text: "<key|path>  <line>" ("<key|path>  comment: <text>" for a hosted
# log or ruling; "<key|path>  owed: <text>" or "… owed: (cleared)"). JSON:
# {ref, path, kind, line}; owed: {ref, path, kind, owed: <text>|null}. An
# unknown item: exit 1 ({ref, path: null}); several: 3; an archived legacy
# row: 3; the text missing, holding a line break, or blank (log, ruling): 3.

# The placement (awk, after frontmatter.awk run with mode=lib: its trim,
# fence_open, fence_close). -v head (the heading line), bom. Prints
# "<found 0|1> <line to insert after> <lines> <crlf 0|1> <last line blank
# 0|1>".
# shellcheck disable=SC2016  # awk source
_LG_AWK_NOTE='
BEGIN {
  H = trim(head); HL = 0
  if (H ~ /^#+([ \t]|$)/) { match(H, /^#+/); HL = RLENGTH }
  st = 0; found = 0; ins = 0; done = 0; cr = -1; nf = 0; last = ""
}
{
  l = $0
  if (NR == 1 && bom != "" && substr(l, 1, length(bom)) == bom) l = substr(l, length(bom) + 1)
  if (cr < 0) cr = (l ~ /\r$/) ? 1 : 0
  sub(/\r$/, "", l)
  last = l
  if (NR == 1 && l ~ /^---[ \t]*$/) { st = 1; next }
  if (st == 1) { if (l ~ /^---[ \t]*$/) st = 2; next }
  if (done) next
  if (nf) { if (fence_close(l)) nf = 0; if (found) ins = NR; next }
  if (fence_open(l)) { nf = 1; if (found) ins = NR; next }
  lvl = 0
  if (l ~ /^ ? ? ?#+([ \t]|$)/) { h = l; sub(/^ +/, "", h); match(h, /^#+/); if (RLENGTH <= 6) lvl = RLENGTH }
  if (found) {
    if (lvl > 0 && (HL == 0 || lvl <= HL)) { done = 1; next }
    if (l ~ /[^ \t]/) ins = NR
    next
  }
  if (trim(l) == H) { found = 1; ins = NR }
}
END { printf "%d %d %d %d %d\n", found, ins, NR, (cr > 0 ? 1 : 0), (last ~ /[^ \t]/ ? 0 : 1) }
'

# _lg_note_append <file> <heading> <line>: <line> under <heading> (see the
# header), installed with _replace_file. Call in the main shell.
_lg_note_append() {
  local file="$1" hd="$2" line="$3" s found=0 ins=0 nr=0 cr=0 lastblank=0 eol=$'\n' finalnl=1
  _lg_scratch_name
  s=$_LG_SN
  printf '%s\n' "$_LG_AWK_NOTE" > "$s.awk" || _lg_die "cannot write $s.awk"
  _lg_awkv "$hd"
  LC_ALL=C awk -v mode=lib -v head="$_LG_AV" -v bom="$_LG_BOM" -f "$_LG_LIB/frontmatter.awk" -f "$s.awk" < "$file" > "$s.pos" 2> "$s.err" \
    || _lg_die "cannot read $file: $(head -n 1 "$s.err")"
  read -r found ins nr cr lastblank < "$s.pos" || _lg_die "internal: no placement for $file"
  if [ "$cr" = 1 ]; then eol=$'\r\n'; fi
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then finalnl=0; fi
  _tmp_beside "$file"
  {
    if [ "$found" = 1 ]; then
      if [ "$ins" -lt "$nr" ]; then
        head -n "$ins" "$file" && printf '%s%s' "$line" "$eol" && tail -n +"$((ins + 1))" "$file"
      elif [ "$finalnl" = 1 ]; then
        cat -- "$file" && printf '%s%s' "$line" "$eol"
      else
        cat -- "$file" && printf '%s%s' "$eol" "$line"
      fi
    else
      cat -- "$file"
      if [ "$nr" -gt 0 ]; then
        if [ "$finalnl" = 0 ]; then printf '%s' "$eol"; fi
        if [ "$lastblank" = 0 ]; then printf '%s' "$eol"; fi
      fi
      printf '%s%s%s' "$hd" "$eol" "$line"
      if [ "$finalnl" = 1 ]; then printf '%s' "$eol"; fi
    fi
  } > "$_TMP" || _lg_die "cannot write $_TMP"
  _replace_file "$_TMP" "$file"
}

# _lg_note_owed <file> <text>: fields.owed's first candidate set to <text>,
# or — <text> empty — every candidate removed (one fm-write.awk pass).
_lg_note_owed() {
  local file="$1" v="$2" s n first=""
  _lg_scratch_name
  s=$_LG_SN
  _lg_cfg '.fields.owed | if type == "array" then .[] elif type == "string" then . else empty end | strings | select(. != "")' > "$s.on"
  { IFS= read -r first; } < "$s.on" 2>/dev/null || true
  if [ -z "$first" ]; then first=owed; printf 'owed\n' > "$s.on"; fi
  _lg_fm_ops_reset
  if [ -n "$v" ]; then
    _lg_fm_op set "$first" "$v"
  else
    while IFS= read -r n; do _lg_fm_op del "$n"; done < "$s.on"
  fi
  _lg_fm_ops_apply "$file"
}

# shellcheck disable=SC2016  # jq source
_LG_JQ_NOTE="$_LG_JQ_RESOLVE_DEFS"'
lg_resolve($ref; $c[0]) as $R
| if $R.r == "item" then
    (first(.items[] | select(.path == $R.v)) as $I
     | {r: "item", path: $I.path, key: ($I.key // ""), hosted: (($I.url | type) == "string")})
  elif $R.r == "ambiguous" then {r: "ambiguous", v: ($R.v | join(", "))}
  elif $R.r == "archived" then {r: "archived", v: $R.v}
  else {r: "none"} end
'

# shellcheck disable=SC2154  # _OPT_*, _OPTSEEN_* and _ARGS are set by _parse_args
cmd_ledger_note() {
  local s n ref text kind a ix r hosted key v path id line="" today
  _lg_init note
  n=${#_ARGS[@]}
  [ "$n" -ge 2 ] || _lg_usage "give an item and the text: ledger note <item> \"<text>\" [--kind log|ruling|owed]"
  text=${_ARGS[$((n - 1))]}
  ref=${_ARGS[0]}
  if [ "$n" -gt 2 ]; then
    # Several words before the text: one of the spaced forms ("L 14").
    for a in "${_ARGS[@]:1:$((n - 2))}"; do ref="$ref $a"; done
    _lg_k_multiword "$ref" || _lg_usage "give one item and one text (got $n arguments: quote the text)"
  fi
  [ -n "$ref" ] || _lg_usage "the item is empty"
  kind=log
  if [ -n "${_OPTSEEN_kind:-}" ]; then kind=$_OPT_kind; fi
  case "$kind" in
    log|ruling|owed) ;;
    *) _lg_usage "--kind '$kind' is not log, ruling or owed" ;;
  esac
  case "$text" in
    *[$'\n\r']*) _lg_usage "the text cannot hold a line break" ;;
  esac
  case "$text" in
    *[![:space:]]*) ;;
    *)
      [ "$kind" = owed ] || _lg_usage "the text is empty"
      text="" ;;
  esac
  _lg_scratch_name
  s=$_LG_SN
  ix=$(_lg_index) || exit "$?"
  jq -c --arg ref "$ref" --slurpfile c "$_LG_CFG" "$_LG_JQ_NOTE" "$ix" > "$s.res" || _lg_die "jq failed (resolving '$ref')"
  jq -r '.r, (.hosted // false), (.key // ""), (.v // "")' "$s.res" > "$s.f" || _lg_die "jq failed (resolving '$ref')"
  { IFS= read -r r; IFS= read -r hosted; IFS= read -r key; IFS= read -r v; } < "$s.f" || true
  case "$r" in
    item) ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then
        jq -nc --arg r "$ref" --arg k "$kind" '{ref: $r, path: null, kind: $k}' > "$s.json" || _lg_die "jq failed (payload)"
        _lg_emit note 1 "$s.json"
      fi
      printf "no item matches '%s'\n" "$ref" | tr -d '\000-\010\013-\037' | head -n 1 > "$s.msg"
      _lg_out_file "$s.msg"
      _lg_emit note 1 ;;
    ambiguous) _lg_usage "'$ref' matches several items: $v" ;;
    archived) _lg_usage "'$ref' is an archived legacy row ($v): there is no item to note" ;;
    *) _lg_die "internal: ledger note: unexpected resolution '$r'" ;;
  esac
  path=$(jq -j '.path + "."' "$s.res") || _lg_die "jq failed (resolving '$ref')"
  path=${path%.}
  id=${key:-$path}
  if [ "$hosted" = true ]; then
    # A hosted item: through its adapter (ruling R2).
    _lg_adapter_path items || _lg_die "hosted item $path: $_LG_ADP_ERR"
    [ -n "$_LG_ADP" ] || _lg_die "hosted item $path: no items adapter (config items.adapter)"
    case "$kind:$text" in
      owed:*'-->'*|owed:*'--!>'*)
        _lg_usage "a hosted item's owed cannot hold '-->' or '--!>' (it would close the issue's metadata comment)" ;;
    esac
    if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
      _lg_die "hosted item $path: offline (DOC_TOOLS_LEDGER_OFFLINE=1): nothing written"
    fi
    case "$kind" in
      log) line=$text; set -- note "$path" "$line" ;;
      ruling) line="RULING: $text"; set -- note "$path" "$line" ;;
      owed) set -- write "$path" owed "$text" ;;
    esac
    _lg_adapter items "$@" > "$s.aout" 2> "$s.aerr" || _lg_die "hosted item $path: $(head -n 1 "$s.aerr")"
    # What the cached list holds just changed on the host: expired.
    a=$(_lg_cfg '.keys.remote | if type == "string" and . != "" then . else "origin" end') || exit "$?"
    _lg_ix_items_km "$a"
    _lg_remote_expire items "$_LG_IX_KM"
  else
    [ -f "$path" ] || _lg_die "the item '$path' is not in the working tree"
    case "$kind" in
      log|ruling)
        today=$(date +%Y-%m-%d) || _lg_die "date failed"
        if [ "$kind" = log ]; then
          a=$(_lg_cfg '.log_heading | if type == "string" and (test("\\S")) and (test("[\\n\\r]") | not) then . else "## Log" end') || exit "$?"
          line="- $today $text"
        else
          a="## Rulings"
          line="- $today RULING: $text"
        fi
        _lg_note_append "$path" "$a" "$line" ;;
      owed) _lg_note_owed "$path" "$text" ;;
    esac
  fi
  if [ "$_LG_FORMAT" = json ]; then
    jq -nc --arg r "$ref" --arg p "$path" --arg k "$kind" --arg l "$line" --arg o "$text" \
      '{ref: $r, path: $p, kind: $k} + (if $k == "owed" then {owed: (if $o == "" then null else $o end)} else {line: $l} end)' \
      > "$s.json" || _lg_die "jq failed (payload)"
    _lg_emit note 0 "$s.json"
  fi
  if [ "$kind" = owed ]; then
    if [ -n "$text" ]; then line="owed: $text"; else line="owed: (cleared)"; fi
  elif [ "$hosted" = true ]; then
    line="comment: $line"
  fi
  printf '%s  %s\n' "$id" "$line" | tr -d '\000-\010\013-\037' > "$s.lines" || _lg_die "cannot write $s.lines"
  _lg_out_file "$s.lines"
  _lg_emit note 0
}

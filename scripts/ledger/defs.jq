# scripts/ledger/defs.jq — the jq definitions every ledger program shares:
# the derived-status labels (design §E.1), the display helpers the read
# verbs (query.sh) and the renderers (render-md.jq, render-html.jq) print
# with, so a status reads the same in `ls`, `show` and every view.
#
# Loaded as a jq module: `jq -L "$_LG_LIB" 'include "defs"; …'` (index.sh's
# _LG_JQ_INCLUDE) or, in a -f program file, an `include "defs";` first line.
# Definitions only (a module has no main expression), and jq 1.6 syntax.

# The derived-status labels (design §E.1), the one definition: the index
# writes them (index.sh lg_item) and the readers display or accept them.
def lg_status_labels:
  {superseded: "superseded", wontfix: "won't fix", closed: "closed", shipped: "shipped", merged: "merged",
   in_review: "in review", on_branch: "on branch", planned: "planned", specd: "spec'd", not_started: "not started"};

# lg_obj(s): the single-key objects s yields as one object (a later key
# wins). lg_lists(s): s yields {k, v}; {k: [v…]} in s order. Both build in
# one pass of C (add / group_by): a reduce that sets one key per step
# copies the growing object each time (quadratic on 3,000 items).
def lg_obj(s): [s] | add // {};
def lg_lists(s): [s] | group_by(.k) | map({(.[0].k): map(.v)}) | add // {};
# lg_lower: ascii_downcase, skipped when there is nothing to lower (it is
# jq-defined and slow; test is C).
def lg_lower: if test("[A-Z]") then ascii_downcase else . end;

# --- Display (query.sh, the renderers) ----------------------------------------

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
# lg_q_display: the item's derived status as shown — "superseded → <key>",
# "merged · owed: <owed>", "in review #<pr>", "on branch <b>", else the
# bare label.
def lg_q_display:
  .derived as $d | ($d.detail // null) as $x | lg_status_labels as $SL
  | (if $d.status == $SL.superseded then "\($SL.superseded) → \($x // "?")"
     elif $d.status == $SL.merged then (if $x == null then $SL.merged else "\($SL.merged) · owed: \($x)" end)
     elif $d.status == $SL.in_review then "\($SL.in_review) #\($x // "?")"
     elif $d.status == $SL.on_branch then "\($SL.on_branch) \($x // "?")"
     else ($d.status // "?") end)
  | lg_q_one;
# lg_q_cluster: the item's primary contract — the first of changes, else
# the first of consumes; null when it names none.
def lg_q_cluster: (.changes[0] // .consumes[0] // null);
# lg_q_rank($R; $n): the place of the severity in severity_order ($R:
# {SEV: i}, case-insensitive); a value outside it $n, none $n + 1.
def lg_q_rank($R; $n):
  .severity as $s
  | if ($s | type) != "string" then $n + 1 else ($R[$s] // $R[$s | ascii_upcase] // $n) end;
def lg_q_ranks($c):
  ([($c.severity_order // [])[] | strings | ascii_upcase]) as $ord
  | {R: ($ord | to_entries | map({key: .value, value: .key}) | from_entries), n: ($ord | length)};
# lg_q_lines: text rows {lead?, id, sev, d, s} → padded lines.
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

# --- In flight (inflight.sh's overlay, applied at query time) ------------------
#
# lg_ifl_apply($ov), applied to the index: $ov the overlay object
# ({branches: [{branch, name, host, own, sources, oid, pr, …}], claims:
# {<item path>: [branch index…]}}; null or anything else: the index as it
# is). Each claimed item gets .inflight [{branch, name, host (null: this
# host's), sources, oid, pr (number|null)}] by branch; an open (or
# unknown-class) item whose derived status ranks below "on branch"
# (planned, spec'd, not started) becomes "in review #<n>" when a claiming
# branch has an open PR (the highest number; .pr set when it was null),
# else "on branch <b>" (the first claiming branch: <name>, or
# <name>@<host> for another host's).
def lg_ifl_apply($ov):
  if ($ov | type) != "object" or (($ov.claims // {}) | length) == 0 then .
  else
    ($ov.branches // []) as $B
    | $ov.claims as $C
    | lg_status_labels as $SL
    | .items |= map(
        ($C[.path] // null) as $ix
        | if $ix == null then .
          else
            ([$ix[] | $B[.] | {branch, name, host: (if .own then null else .host end), sources, oid, pr: (.pr.number // null)}]
             | sort_by(.branch)) as $IF
            | .inflight = $IF
            | if (.class == "open" or .class == "unknown")
                 and (.derived.status == $SL.planned or .derived.status == $SL.specd or .derived.status == $SL.not_started)
              then
                ([$ix[] | $B[.].pr | objects] | sort_by(.number) | last) as $p
                | if $p != null then .derived = {status: $SL.in_review, detail: ($p.number | tostring)} | .pr = (.pr // $p)
                  else .derived = {status: $SL.on_branch, detail: $IF[0].branch} end
              else . end
          end)
  end;
# lg_ifl_lines: an item's in-flight claims as text, "<branch> (<sources>
# [@<host>], PR #<n>|no PR)" each.
def lg_ifl_lines:
  [(.inflight // [])[] | "\(.branch) (\(.sources | join(","))\(if .host == null then "" else "@\(.host)" end), \(if .pr == null then "no PR" else "PR #\(.pr)" end))"];

# --- Related work (index.sh, relations.sh, query.sh, the renderers) ------------
#
# Design §F.1. Through contracts: A is upstream of B when A.changes ∩
# B.consumes ≠ ∅ (via the contract); siblings share a contract on one side
# (both change it, or both consume it). Directly: an item's relates entries
# "<kind>:<key>" (kind root-cause | depends-on | sibling, case-insensitive;
# no kind: sibling; any other kind is no edge) whose key or alias names
# another item: the named item is upstream of the item for root-cause /
# depends-on (and the item downstream of it), a sibling for sibling (both
# ways). An edge is {key, via}: the other item's key (its path when it has
# none) and the contract id or the relates kind (a contract id holds ":", a
# kind never).

def lg_rel_kinds: ["root-cause", "depends-on", "sibling"];
# lg_rel_terminal: the class ends the work (re-check sources).
def lg_rel_terminal: .class == "fixed" or .class == "closed" or .class == "wontfix";

# lg_relations($its; $contracts): {nb, tab} over the index items $its
# (index.sh). nb: {path: neighbours}, neighbours = {upstream, downstream,
# siblings}: [{key, via}], sorted by key then via (each contract's edge list
# is built once and shared by every item naming the contract). tab: the
# re-check input lines relations.sh _lg_ix_recheck reads (fields \u0002,
# lists \u0003, a newline or separator in a name \u0001):
#   O path consumes sources n — an open (or unknown-class) item that
#     consumes a contract (the ids without whitespace) or has re-check
#     sources (the paths of its contract upstream and of the items its own
#     relates name); n: its place in $its (0-based)
#   S path key-or-path terminal(1|0) — each source
#   G contract glob — the defined_in globs of each consumed contract.
def lg_relations($its; $contracts):
  lg_obj($its[] | {(.path): (.key // .path)}) as $K
  | lg_obj([$its[] | .path as $p | ([.key] + (.aliases // []) | .[] | strings | lg_lower) | {($p): .}] | reverse[]
           | to_entries[0] | {(.value): .key}) as $KM
  | lg_lists($its[] | .path as $p | ((.changes // []) | unique)[] | {k: ., v: $p}) as $CHP
  | lg_lists($its[] | .path as $p | ((.consumes // []) | unique)[] | {k: ., v: $p}) as $COP
  | ($CHP | with_entries(.key as $c | .value |= (map({key: $K[.], via: $c}) | sort_by(.key)))) as $CHE
  | ($COP | with_entries(.key as $c | .value |= (map({key: $K[.], via: $c}) | sort_by(.key)))) as $COE
  | [ $its[] | .path as $f | (.relates // [])[] | ((.kind // "sibling") | ascii_downcase) as $k
      | select(lg_rel_kinds | index([$k]) != null)
      | ($KM[(.key // "") | lg_lower] // null) as $t
      | select($t != null and $t != $f) | {f: $f, t: $t, k: $k} ] as $RS
  | lg_lists($RS[] | select(.k != "sibling") | {k: .f, v: {key: $K[.t], via: .k}}) as $OU
  | lg_lists($RS[] | select(.k == "sibling") | {k: .f, v: {key: $K[.t], via: "sibling"}}) as $OS
  | lg_lists($RS[] | select(.k != "sibling") | {k: .t, v: {key: $K[.f], via: .k}}) as $ID
  | lg_lists($RS[] | select(.k == "sibling") | {k: .t, v: {key: $K[.f], via: "sibling"}}) as $IS
  | lg_lists($RS[] | {k: .f, v: .t}) as $OT
  # nbm($me): the lists as one, sorted by key then via, each edge once,
  # without the item (always add | unique: a relates list is in the order
  # written and may name an item twice).
  | def nbm($me): (add // []) | unique
      | if length == 0 or (any(.[]; .key == $me) | not) then . else map(select(.key != $me)) end;
    {nb: lg_obj($its[] | .path as $p | $K[$p] as $me
       | ((.changes // []) | unique) as $ch | ((.consumes // []) | unique) as $co
       | {($p): {
           upstream: ([($co[] | $CHE[.] // []), ($OU[$p] // [])] | nbm($me)),
           downstream: ([($ch[] | $COE[.] // []), ($ID[$p] // [])] | nbm($me)),
           siblings: ([($ch[] | $CHE[.] // []), ($co[] | $COE[.] // []), ($OS[$p] // []), ($IS[$p] // [])] | nbm($me))}}),
     tab: ([ $its | to_entries[] | .key as $n | .value | select(.class == "open" or .class == "unknown") | .path as $p
             | ((.consumes // []) | map(select(test("^\\S+$"))) | unique) as $co
             | {n: $n, p: $p, c: $co, s: ([$co[] | ($CHP[.] // [])[] | select(. != $p)] + ($OT[$p] // []) | unique)}
             | select((.c | length) > 0 or (.s | length) > 0) ] as $open
           | ([$open[].s[]] | unique) as $SRC
           | lg_obj($its[] | select(lg_rel_terminal) | {(.path): true}) as $T
           | lg_obj(($contracts // [])[] | {(.id): (.defined_in // [])}) as $DEF
           # One test over every name first: a name holding a separator is rare.
           | ([$its[] | .path, (.key // ""), ((.consumes // [])[])] | join("") | test("[\n\u0002\u0003]")) as $SEP
           | def f: if $SEP and test("[\n\u0002\u0003]") then gsub("[\n\u0002\u0003]"; "\u0001") else . end;
             [ ($open[] | "O\u0002\(.p | f)\u0002\(.c | map(f) | join("\u0003"))\u0002\(.s | map(f) | join("\u0003"))\u0002\(.n)"),
               ($SRC[] | "S\u0002\(f)\u0002\($K[.] | f)\u0002\(if $T[.] then 1 else 0 end)"),
               (([$open[].c[]] | unique)[] as $k | ($DEF[$k] // [])[] | select(test("[[:cntrl:]]") | not)
                | "G\u0002\($k)\u0002\(.)") ])};

# lg_path_contracts($its; $cre): {file: [contract ids]} — for every file an
# item lists in paths, the contracts whose defined_in matches it. $cre:
# [{id, dir, re}] — each defined_in glob as glob.sh's ERE, filed under its
# literal directory (a file is tried only against the globs filed under one
# of its own directories).
def lg_path_contracts($its; $cre):
  lg_lists($cre[] | {k: .dir, v: .}) as $GD
  | lg_obj(([$its[] | (.paths // [])[]] | unique)[] as $f
      | ($f | split("/")) as $parts
      | ([""] + [range(1; $parts | length) as $n | ($parts[0:$n] | join("/")) + "/"]) as $dirs
      | ([$dirs[] as $d | ($GD[$d] // [])[] | select(.re as $re | $f | test($re)) | .id] | unique) as $ids
      | if ($ids | length) > 0 then {($f): $ids} else empty end);

# lg_r_maps($ix): lookups over the index:
#   P   {file: [item paths listing it in paths]}
#   S   {spec: [item paths whose docs.spec has it]}
#   C   {contract: [item paths naming it in changes or consumes]}
#   D   {file: [contracts whose defined_in matches it]} (path_contracts)
#   DI  {contract: [{p, f}]}: items whose file f the contract's defined_in matches
#   BYP {path: item}, K2P {key or path: path} (a neighbour's key → its item)
def lg_r_maps($ix):
  ($ix.path_contracts // {}) as $D
  | lg_lists($ix.items[] | .path as $p | ((.paths // []) | unique)[] | {k: ., v: $p}) as $P
  | {P: $P,
     S: lg_lists($ix.items[] | .path as $p | (((.docs // {}).spec // []) | unique)[] | {k: ., v: $p}),
     C: lg_lists($ix.items[] | .path as $p | ([(.changes // [])[], (.consumes // [])[]] | unique)[] | {k: ., v: $p}),
     D: $D,
     DI: lg_lists($D | to_entries[] | .key as $f | .value[] | {k: ., v: (($P[$f] // [])[] | {p: ., f: $f})}),
     BYP: lg_obj($ix.items[] | {(.path): .}),
     # A key names the first item (by path) that has it; a path names its item.
     K2P: (lg_obj($ix.items[] | {(.path): .path}) + lg_obj([$ix.items[] | {(.key // .path): .path}] | reverse[]))};

# lg_r_candidates($I; $M): the items related to $I by evidence only (design
# §F.1 candidates; never asserted) — [{p, reasons}], by path; $I left out,
# nothing else (the caller drops confirmed and closed ones):
#   ≥ 2 files both list ("shares N files: a, b");
#   a spec both are linked from ("same spec: s");
#   a file of the other matching the defined_in of a contract $I names
#   ("its file f defines C"), or a file of $I matching the defined_in of a
#   contract the other names ("names C, defined in f (a file <I> lists)").
def lg_r_candidates($I; $M):
  (($I.paths // []) | unique) as $ip
  | ([($I.changes // [])[], ($I.consumes // [])[]] | unique) as $ic
  | ($I.key // $I.path) as $iid
  | [ ([$ip[] as $f | ($M.P[$f] // [])[] | select(. != $I.path) | {p: ., f: $f}]
       | group_by(.p) | map(select(length >= 2) | {p: .[0].p, r: "shares \(length) files: \(map(.f) | join(", "))"}) | .[]),
      (((($I.docs // {}).spec // []) | unique)[] as $s | ($M.S[$s] // [])[] | select(. != $I.path) | {p: ., r: "same spec: \($s)"}),
      ($ic[] as $k | ($M.DI[$k] // [])[] | select(.p != $I.path) | {p: .p, r: "its file \(.f) defines \($k)"}),
      ($ip[] as $f | ($M.D[$f] // [])[] as $k | ($M.C[$k] // [])[] | select(. != $I.path)
       | {p: ., r: "names \($k), defined in \($f) (a file \($iid) lists)"}) ]
  | group_by(.p) | map({p: .[0].p, reasons: (map(.r) | unique)});

# lg_r_recheck_text: an item's re-check markers (recheck_after) as shown —
# "<key> landed" for an item that reached a terminal class, "<contract>
# changed" for a contract change; "" when none.
def lg_r_recheck_text:
  (.recheck_after // []) | if length == 0 then ""
  else "re-check: " + (map(if test(":") then "\(.) changed" else "\(.) landed" end) | join(", ")) end;

# --- Trackers (spec claims; work-ledger design §I) ------------------------------
#
# A spec claim's `tracker` names an item when it is an item's path, exactly,
# or its key or one of its aliases (any case; a provisional key that
# finalized.json maps on resolves to the finalized key's item) carried by
# exactly one item — what lg_resolve takes as a key or a path. Its looser
# forms (a file stem, "L 14", a legacy row) are no tracker: a tracker is a
# written field, not a command-line reference.

# lg_track_map($items; $fin): the lookup tables, built once: P {path: true},
# K {lower-case key or alias: [paths]}, F the finalized map.
def lg_track_map($items; $fin):
  {P: lg_obj($items[] | {(.path): true}),
   K: lg_lists($items[] | .path as $p | ((.key | strings), ((.aliases // [])[] | strings)) | {k: lg_lower, v: $p}),
   F: ($fin | if type == "object" then . else {} end)};
# lg_track($M; $t): the item path tracker $t names, or null.
def lg_track($M; $t):
  def one($k): (($M.K[$k | lg_lower] // []) | unique) as $m | if ($m | length) == 1 then $m[0] else null end;
  def any_of($k): (($M.K[$k | lg_lower] // []) | length) > 0;
  if ($t | type) != "string" or $t == "" then null
  elif $M.P[$t] == true then $t
  elif any_of($t) then one($t)
  else ($M.F[$t] // $M.F[$t | lg_lower] // null) as $to
    | if ($to | type) == "string" then one($to) else null end
  end;
# lg_claims_counts($rows; $M): {path: {diverged, unbuilt}} over claim rows
# {t: tracker, s: status} (diverged / unbuilt only), by the item each
# tracker names.
def lg_claims_counts($rows; $M):
  lg_lists($rows[] | lg_track($M; .t) as $p | select($p != null) | {k: $p, v: .s})
  | map_values({diverged: (map(select(. == "diverged")) | length), unbuilt: (map(select(. == "unbuilt")) | length)});
# lg_r_claims_text: the spec claims an item tracks (.claims), as shown —
# "claims: 1 diverged, 2 unbuilt" ($sep between the counts); "" when none.
def lg_r_claims_text($sep):
  (.claims // {}) as $c
  | [(if ($c.diverged // 0) > 0 then "\($c.diverged) diverged" else empty end),
     (if ($c.unbuilt // 0) > 0 then "\($c.unbuilt) unbuilt" else empty end)]
  | if length == 0 then "" else "claims: " + join($sep) end;

# --- Views (render-md.jq, render-html.jq) ---------------------------------------
#
# Both renderers read the same model, lg_v_model, so the markdown pages and
# the HTML file group, count and order alike. Pure: the result depends only
# on the index, the config and $gen ("generated": the header facts, the
# recency cutoff, the per-path last-touched dates) — never on the order of
# .items or on the clock.

# lg_v_active: the item belongs on the cluster tables — open work: an open
# (or unrecognised) status, or fixed with something still owed.
def lg_v_active: .class == "open" or .class == "unknown" or (.class == "fixed" and .owed != null);
# lg_v_superseded: closed with a replacement.
def lg_v_superseded: .class == "closed" and .superseded_by != null;
# lg_v_recent($gen): the item was last touched (git, $gen.touched; else its
# date) on or after $gen.cutoff (YYYY-MM-DD).
def lg_v_recent($gen):
  ((($gen.touched // {})[.path]) // .date // "") as $d
  | ($d | type) == "string" and $d >= ($gen.cutoff // "");
# lg_v_sevs($c): the severity labels counted, in order (severity_order).
def lg_v_sevs($c): [($c.severity_order // [])[] | strings];
# lg_v_counts($sevs): [{sev, n}] over an item list, one per severity label
# (case-insensitive).
def lg_v_counts($sevs):
  . as $its
  | [$sevs[] as $s | {sev: $s, n: ([$its[] | select((.severity | type) == "string" and (.severity | ascii_upcase) == ($s | ascii_upcase))] | length)}];
# lg_v_inflight: the distinct in-flight branches an item list names
# (Task 11 fills .inflight; [] until then).
def lg_v_inflight:
  [.[] | (.inflight // [])[] | if type == "object" then (.branch // .name // tojson) else tostring end] | unique;
# lg_v_sort($K): items by severity (severity_order), then date (oldest
# first), then path.
def lg_v_sort($K): sort_by(lg_q_rank($K.R; $K.n), (.date // "9999-99-99"), .path);
# lg_v_titles($ix): {contract-id: title} — the index's contracts (Task 9),
# else the registry's ledgers[].contracts[] titles.
def lg_v_titles($ix):
  reduce ((($ix.contracts // []) | if type == "array" then .[] else empty end),
          (($ix.ledgers // [])[] | (.contracts // []) | if type == "array" then .[] else empty end))
         as $k ({};
           if ($k | type) == "object" and ($k.id | type) == "string" and ($k.title | type) == "string"
              and $k.title != "" and (has($k.id) | not)
           then .[$k.id] = $k.title else . end);
# lg_v_id: a ledger id a page can be named after (^[a-z0-9-]{1,16}$, the
# registry's grammar; "unassigned" too; never "readme", reserved for
# README.md).
def lg_v_id: type == "string" and test("^[a-z0-9-]{1,16}$") and . != "readme";
# lg_v_ledgers($ix): the ledgers the views show, in order: the registry's
# (retired ones only when they hold items), then every other ledger id
# the items carry ("unassigned" and unregistered ids), sorted. Each
# {id, title, scope, retired}. A value that is not an id has no page.
def lg_v_ledgers($ix):
  ([$ix.items[] | .ledger | select(lg_v_id)] | unique) as $used
  | [($ix.ledgers // [])[] | select(.id | lg_v_id)
     | select(.status != "retired" or (.id as $i | $used | index([$i]) != null))
     | {id, title: ((.title // .id) | tostring), scope: ((.scope // "") | tostring), retired: (.status == "retired")}] as $reg
  | ($reg | map(.id)) as $ids
  | $reg + [$used[] | select(. as $u | $ids | index([$u]) == null)
            | {id: ., title: (if . == "unassigned" then "Unassigned" else . end), scope: "", retired: false}];
# lg_v_status: the derived status as the views show it — the display, then
# " · re-check: …" when the item carries re-check markers, then " · claims:
# …" when spec claims it tracks are diverged or unbuilt.
def lg_v_status:
  lg_r_recheck_text as $r | lg_r_claims_text(", ") as $k
  | lg_q_display + (if $r == "" then "" else " · " + $r end) + (if $k == "" then "" else " · " + $k end);
# lg_v_suggest($U; $M): the top candidate cluster of an unclustered item —
# {contract, reason} or null: a contract whose defined_in matches a file it
# lists (2 points), the cluster of an active candidate item (1 point each,
# design §F.1 candidates); the highest total, then the contract id.
def lg_v_suggest($U; $M):
  [ ((($U.paths // []) | unique)[] as $f | ($M.D[$f] // [])[] | {c: ., s: 2, r: "its file \($f) defines it"}),
    (lg_r_candidates($U; $M)[] | $M.BYP[.p] as $Y | ($Y | lg_q_cluster) as $k
     | select($k != null and ($Y | lg_v_active))
     | {c: $k, s: 1, r: "\(.reasons[0]) (\($Y.key // $Y.path))"}) ]
  | if length == 0 then null
    else group_by(.c) | map({contract: .[0].c, score: (map(.s) | add), reason: .[0].r})
      | sort_by(-.score, .contract) | .[0] | {contract, reason} end;
# lg_v_model($ix; $c; $gen): every ledger's page model —
#   {id, title, scope, retired, counts: [{sev, n}], open, inflight: [branches],
#    clusters: [{contract, title, items, counts, up: [..], down: [..]}],
#    unclustered: [items + {suggest: lg_v_suggest}], closed: [items],
#    superseded: [items]}
# plus .unplaced (the items on no page: no ledger, or not an id) and
# .inflight (every in-flight branch the items name). Clusters by severity counts
# (severity_order, most severe first) descending, then title, then
# contract; items by lg_v_sort. up/down: the clusters' neighbours in other
# ledgers ({key, via, ledger, display}), de-duplicated (a neighbour without
# a key is named by its path).
def lg_v_model($ix; $c; $gen):
  lg_q_ranks($c) as $K
  | lg_v_sevs($c) as $sevs
  | lg_v_titles($ix) as $T
  | ($ix.items | sort_by(.path)) as $all
  # Keys → items over the path-sorted list (a duplicate key resolves to its
  # last path, whatever the input order).
  # A neighbour without a key is named by its path.
  | (lg_obj($all[] | {(.path): .}) + lg_obj($all[] | ((.key // "") | lg_lower) as $k | select($k != "") | {($k): .})) as $BYKEY
  | lg_r_maps($ix) as $M
  | lg_v_ledgers($ix) as $LS
  | ($LS | map(.id)) as $pages
  | {ledgers: [$LS[] as $L
      | [$all[] | select(.ledger == $L.id)] as $its
      | [$its[] | select(lg_v_active)] as $act
      | ([$act[] | select(lg_q_cluster != null)] | group_by(lg_q_cluster)
         | map((.[0] | lg_q_cluster) as $k
               | {contract: $k, title: ($T[$k] // null), items: lg_v_sort($K), counts: lg_v_counts($sevs),
                  up: ([.[] | .neighbours | objects | (.upstream // [])[] | objects]
                       | map(. + {item: ($BYKEY[(.key // "") | ascii_downcase] // $BYKEY[.key // ""])})
                       | map(select(.item != null and .item.ledger != $L.id))
                       | map({key: .key, via: (.via // null), ledger: .item.ledger, display: (.item | lg_q_display)})
                       | unique_by([.key, .via])),
                  down: ([.[] | .neighbours | objects | (.downstream // [])[] | objects]
                         | map(. + {item: ($BYKEY[(.key // "") | ascii_downcase] // $BYKEY[.key // ""])})
                         | map(select(.item != null and .item.ledger != $L.id))
                         | map({key: .key, via: (.via // null), ledger: .item.ledger, display: (.item | lg_q_display)})
                         | unique_by([.key, .via]))})
         | sort_by((.counts | map(0 - .n)), (.title // .contract), .contract)) as $clusters
      | $L + {counts: ($act | lg_v_counts($sevs)), open: ($act | length), inflight: ($its | lg_v_inflight),
              clusters: $clusters,
              unclustered: ([$act[] | select(lg_q_cluster == null)] | lg_v_sort($K) | map(. + {suggest: lg_v_suggest(.; $M)})),
              closed: ([$its[] | select((lg_v_active | not) and (lg_v_superseded | not) and .class != "wontfix" and lg_v_recent($gen))] | lg_v_sort($K)),
              superseded: ([$its[] | select((lg_v_superseded or .class == "wontfix") and lg_v_recent($gen))] | lg_v_sort($K))}],
     unplaced: [$all[] | select(.ledger as $l | $pages | index([$l]) == null)],
     inflight: ($all | lg_v_inflight)};
# lg_v_header($gen): the generated-from line (no markup), then the PR data
# note when there is one ($gen.pr_note: "PR data as of …" / "PR data: —").
def lg_v_header($gen):
  "Generated from \($gen.source // "?") + \($gen.inflight // 0) in-flight branches at \($gen.at // "?") by doc-superpowers ledger. Do not edit — edit the item."
  + (($gen.pr_note // "") | if type == "string" and . != "" then " · " + . else "" end);
# lg_v_url($gen): the item path as a link target — $gen.link (a prefix,
# already encoded) + each path segment percent-encoded; an http(s) URL (a
# hosted item's url: index.sh) as it is, with ")", " " and "|" encoded (a
# file path never starts with a scheme: git paths hold no "//").
def lg_v_url($gen):
  if test("^https?://") then lg_q_one | gsub("\\)"; "%29") | gsub(" "; "%20") | gsub("\\|"; "%7C")
  else ($gen.link // "") + (split("/") | map(@uri) | join("/")) end;
# lg_v_newest: the newest of a list of doc paths (by file name: date-led
# names sort by date), or null.
def lg_v_newest: if length == 0 then null else sort_by(split("/") | last) | last end;
def lg_v_docstem: split("/") | last | if endswith(".md") then .[0:-3] else . end;
# lg_v_resolution: the first non-empty line (not only whitespace) of the
# item's resolution (design §E.2), cut to 200 characters — before any
# escaping, so a cut never splits one; "(no resolution)" when there is none.
def lg_v_resolution:
  ((.resolution // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | .[0]) // "(no resolution)"
  | lg_q_one | lg_q_cut(200);
# lg_v_pr_url: the PR's url when it is http(s), else null (never a
# javascript: or other scheme in a link).
def lg_v_pr_url: .pr | if type == "object" and (.url | type) == "string" and (.url | test("^https?://")) then .url else null end;
# lg_v_sev($c): the severity as severity_order spells it (case-insensitive
# match), else as written; null when none.
def lg_v_sev($c):
  .severity as $s
  | if ($s | type) != "string" then null
    else first(lg_v_sevs($c)[] | select(ascii_upcase == ($s | ascii_upcase))) // $s end;

# shellcheck shell=bash
# scripts/ledger/validate.sh — `ledger validate`. Sourced by lib.sh; uses
# lib.sh's _lg_init, _lg_registry, _lg_emit, _lg_out_file, _lg_src_cat,
# glob.sh's _lg_owner_map / _lg_registry_globs / _lg_glob_dirs /
# _LG_AWK_GLOB, parse.sh's _LG_AWK_JS, _lg_scratch_name, _lg_parse_prep,
# _lg_parse_finish / _lg_parse_batch and frontmatter.awk (its functions,
# mode=lib), index.sh's _lg_index, _lg_ix_json_obj and _LG_JQ_INDEX_DEFS,
# and keys.sh's _lg_k_cfg / _lg_provisional_in_range.
#
# Modes (one of them; --registry may join any): --staged, --all, --plan
# <plan> [--strict], --pushed <a>..<b> (their findings below, "Item
# checks"), and --registry alone:
#
# --registry: the registry docs/ledger/ledgers.json against the tracked
# files (the index). Findings ({"class","detail"}), each blocking (rc 1):
#   schema              .schema is not "ledger-registry/1"
#   shape               paths / residual_paths / defined_in / read_by not a
#                       list of strings; contracts not a list of objects
#   id                  a ledger id not [a-z0-9-]{1,16}, or "unassigned" or
#                       "readme" (reserved: the views write README.md)
#   duplicate-id        an id two ledgers carry
#   status              not "active" | "retired"
#   kind                not "service" | "platform"
#   contract-id         a contract id not <kind>:<name>
#   duplicate-contract  a contract id declared twice (any ledgers)
#   glob                a glob the grammar (glob.sh) rejects
#   overlap             a tracked file two ledgers claim (glob.sh's
#                       ownership: ordinary paths first, then residual;
#                       a retired ledger claims nothing)
#   unowned             a tracked file outside docs/ no ledger claims —
#                       only when some active ledger declares paths or
#                       residual_paths
# Text: "registry <class> <detail>" per finding. JSON: {"findings":[…]}.

# The contract id form: a lowercase kind, ":", a name without whitespace.
# \A … \z: jq's "$" also matches before a trailing newline.
_LG_CONTRACT_RE='\A[a-z][a-z0-9_-]*:[^[:space:]]+\z'

# _lg_registry_findings <registry> <tracked-nul> <out.jsonl>: the registry's
# findings, one JSON object per line, in the order listed above (overlap
# and unowned in path order).
_lg_registry_findings() {
  local reg="$1" tracked="$2" out="$3" s declares rc=0
  _lg_scratch_name
  s=$_LG_SN
  jq -c --arg cre "$_LG_CONTRACT_RE" '
    def strlist: type == "array" and all(.[]; type == "string");
    def f($c; $d): {class: $c, detail: $d};
    def name($i): if (.id | type) == "string" then .id else "ledgers[\($i)]" end;
    (if .schema != "ledger-registry/1"
     then f("schema"; "expected \"ledger-registry/1\", got \(.schema | tojson)") else empty end),
    (.ledgers | to_entries[] | .key as $i | .value | name($i) as $n
     | (if (.id | type) != "string" or (.id | test("\\A[a-z0-9-]{1,16}\\z") | not)
        then f("id"; "ledgers[\($i)]: \(.id | tojson) is not a ledger id ([a-z0-9-]{1,16})")
        elif .id == "unassigned" then f("id"; "ledgers[\($i)]: \"unassigned\" is reserved")
        elif .id == "readme" then f("id"; "ledgers[\($i)]: \"readme\" is reserved (the views write README.md)")
        else empty end),
       (if .status == "active" or .status == "retired" then empty
        else f("status"; "\($n): \(.status | tojson) is not active | retired") end),
       (if .kind == "service" or .kind == "platform" then empty
        else f("kind"; "\($n): \(.kind | tojson) is not service | platform") end),
       (("paths", "residual_paths") as $k
        | if has($k) and (.[$k] | strlist | not)
          then f("shape"; "\($n): \($k) is not a list of strings") else empty end),
       (if has("contracts") and (.contracts | type) != "array"
        then f("shape"; "\($n): contracts is not a list")
        else (.contracts // [])[]
          | if type != "object" then f("shape"; "\($n): a contract is not an object")
            else (if (.id | type) != "string" or (.id | test($cre) | not)
                  then f("contract-id"; "\($n): \(.id | tojson) is not <kind>:<name>") else empty end),
                 (if has("defined_in") and (.defined_in | strlist | not)
                  then f("shape"; "\($n): \(.id | tojson) defined_in is not a list of strings") else empty end),
                 (if has("read_by") and (.read_by | strlist | not)
                  then f("shape"; "\($n): \(.id | tojson) read_by is not a list of strings") else empty end)
            end
        end),
       ([(.paths, .residual_paths, ((.contracts | arrays | .[] | objects | (.defined_in, .read_by))))
         | arrays | .[] | strings | select(explode | any(. < 32))][]
        | f("glob"; "\($n): \(tojson) holds a control character"))),
    ([.ledgers[] | .id | strings] | group_by(.) | map(select(length > 1))[]
     | f("duplicate-id"; "\(.[0]) is the id of \(length) ledgers")),
    ([.ledgers[] | (.id | tostring) as $l | .contracts | arrays | .[] | objects
      | .id | strings | {id: ., l: $l}]
     | group_by(.id) | map(select(length > 1))[]
     | f("duplicate-contract"; "\(.[0].id) is declared by \(map(.l) | join(", "))"))
  ' "$reg" > "$out" || _lg_die "jq failed (registry checks)"

  # Globs the grammar rejects (every list, defined_in and read_by included).
  _lg_registry_globs "$reg" "$s.globs"
  LC_ALL=C awk "$_LG_AWK_JS$_LG_AWK_GLOB"'
    BEGIN { js_init() }
    {
      split($0, f, "\t")
      if (glob_ere(f[5]) == "") {
        g = (f[4] == "1") ? "!" f[5] : f[5]
        print "{\"class\":\"glob\",\"detail\":" js(f[2] ": " g ": " GLOB_ERR) "}"
      }
    }' "$s.globs" >> "$out" || _lg_die "cannot check the registry globs"

  # Ownership: overlap always; unowned (outside docs/) only when declared.
  declares=$(jq -r '[.ledgers[] | select(.status != "retired") | ((.paths, .residual_paths) | if type == "array" then length else 0 end)]
    | add // 0 | if . > 0 then 1 else 0 end' "$reg") || _lg_die "jq failed (registry paths)"
  _lg_owner_map "$tracked" "$s.own" "$reg"
  LC_ALL=C awk -v declares="$declares" "$_LG_AWK_JS"'
    BEGIN { js_init() }
    {
      t = 0; r = $0
      while ((i = index(r, "\t")) > 0) { t += i; r = substr(r, i + 1) }
      p = rep(substr($0, 1, t - 1), SOH, "\n"); o = r
      if (o ~ /^multi:/) {
        print "{\"class\":\"overlap\",\"detail\":" js(p " is claimed by " rep(substr(o, 7), ",", ", ")) "}"
      } else if (o == "-" && declares == 1 && substr(p, 1, 5) != "docs/") {
        print "{\"class\":\"unowned\",\"detail\":" js(p) "}"
      }
    }' "$s.own" >> "$out" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot read the ownership map (awk rc $rc)"
}

# _lg_validate_registry: `validate --registry` — prints the findings, ends
# the run (rc 1 on any finding).
_lg_validate_registry() {
  local reg s rc=0
  reg=$(_lg_registry) || exit "$?"
  _lg_scratch_name
  s=$_LG_SN
  git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
    || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
  _lg_registry_findings "$reg" "$s.tracked" "$s.findings"
  [ ! -s "$s.findings" ] || rc=1
  if [ "$_LG_FORMAT" = json ]; then
    jq -s -c '{findings: .}' "$s.findings" > "$s.payload" || _lg_die "jq failed (findings)"
    _lg_emit validate "$rc" "$s.payload"
  fi
  jq -r '"registry \(.class) \(.detail)"' "$s.findings" > "$s.text" || _lg_die "jq failed (findings text)"
  _lg_out_file "$s.text"
  _lg_emit validate "$rc"
}


# --- Item checks: --staged, --all ------------------------------------------------
#
# A finding: {"class","severity":"block"|"advisory","path","key","detail"}.
# Text: "<class> <path|key> <detail>", " (advisory)" after an advisory's
# detail; a path, key or detail holding a control character is printed
# JSON-quoted, so every finding is one line. Blocking findings first, then
# by path. rc 1 when any finding blocks.
#
# Classes (design §B, §J):
#   bad-key               a key that is neither <ledger>-<n> nor <ledger>-~<4–8 hex>
#   duplicate-key         a key or alias another item carries as its key or an
#                         alias (case-insensitive)
#   unknown-ledger        ledger is not a registered id (nor unassigned, nor a
#                         config legacy_ids value)
#   retired-ledger        ledger is a retired ledger (it takes no new items)
#   legacy-ledger-id      ledger is a config legacy_ids value ("ledger assign")
#   missing-ledger / missing-summary / missing-key
#   missing-resolution    a closed / won't-fix item without a resolution line
#   superseded-dangling   superseded_by names no item (keys, aliases, and the
#                         provisional keys docs/ledger/finalized.json maps)
#   superseded-cycle      following superseded_by comes back to an item
#   superseded-chain      (advisory) superseded_by leads through more than
#                         one link (or a later link does not resolve — the
#                         detail says where it breaks): point it at the
#                         chain's end, its last resolvable item
#   superseded-dead-end   (advisory) the chain ends at a closed or won't-fix
#                         item: nothing in effect replaces this one
#   superseded-not-closed superseded_by on an item whose class is not closed
#   parse-error           the item's frontmatter has errors (advisory)
#   no-relations          (config validate.require_relations "new"; off by
#                         default) an open item naming no changes, consumes
#                         or relates, without the opt-out relations: none —
#                         --staged: an added item, blocking; --all: an item
#                         new since adoption, advisory (_lg_v_rr_all)
#   --all only (advisory): weak-summary (< 20 characters), unassigned-open,
#   no-contract (an open item with neither changes nor consumes), config
#   (docs/ledger/config.json: state_watch.paths set while state_watch.patterns
#   names nothing — the state-watch hook never fires)
#   registry              (--staged with the registry staged, or --registry
#                         beside a mode) a `validate --registry` finding:
#                         "registry <class> <detail>"
#   --plan: unmarked, bad-mark, no-related-work · --pushed: provisional-key
#   (_lg_validate_plan, _lg_validate_pushed)
#
# --staged severities. An added item (a rename from outside the item globs
# counts as added) is held to everything. A modified item (a rename within
# them included, compared with its old path) never blocks on what it already
# was at HEAD: a finding blocks only when the field it is about changed in
# this commit — a duplicate when the colliding key or alias is new to either
# side; a bad key or an unknown ledger when the value changed; a missing
# resolution when the status moved into closed / won't fix; a dangling
# superseded_by or a cycle when that move happened or superseded_by changed
# (and superseded-not-closed when superseded_by or the status class
# changed). Otherwise the finding is advisory. A retired or legacy ledger
# blocks an added item only; missing ledger / summary block an added item
# only; missing-key, parse-error, superseded-chain and superseded-dead-end
# are always advisory.
#
# --all: every item of the working-tree index, the blocking classes block;
# retired-ledger is reported (advisory) only for open / unknown-class items;
# missing-resolution is advisory, "terminal before adoption", on an item
# from before the ledger was adopted (the index's pre_adoption: config base
# has no commit adding docs/ledger/config.json yet, or the base holds the
# item and no commit after the first that added it touched it; Task 16c
# U11).
# The index holds the hosted items too (config items.adapter, through the
# items cache — fresh or stale, the run's note says which; no copy and the
# adapter failing: exit 2; controller ruling R4): key and alias uniqueness
# spans both kinds, and a hosted item gets every check whose data its
# adapter supplies — not missing-resolution (a hosted item's reason lives
# on the issue). --staged never calls the adapter.

# shellcheck disable=SC2016  # jq source
_LG_JQ_VALIDATE_DEFS='
def lg_v_ctl: type == "string" and (explode | any(. < 32 or . == 127));
def lg_v_tok: if lg_v_ctl then tojson else . end;
def lg_v_f($c; $sev; $p; $k; $d): {class: $c, severity: $sev, path: $p, key: $k, detail: $d};
def lg_v_sev($b): if $b then "block" else "advisory" end;
def lg_v_term: . == "closed" or . == "wontfix";
def lg_v_keyform:
  type == "string" and (test("\\A[a-z0-9-]{1,16}-[1-9][0-9]*\\z") or test("\\A[a-z0-9-]{1,16}-~[0-9a-f]{4,8}\\z"));
def lg_v_present: . != null and . != "" and . != [];
# The relations opt-out (config validate.require_relations): frontmatter
# relations: none, in any case.
def lg_v_none: type == "string" and (ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")) == "none";
def lg_v_norel_detail:
  "a new open item names no relation (config validate.require_relations \"new\"): "
  + "declare what it changes, consumes or relates to (ledger link <item> --changes C | --consumes C | --relates kind:key), "
  + "or opt out with relations: none (ledger link <item> --relations none)";
# A parse record → the fields the checks read.
def lg_v_rinfo($F; $CT; $EX):
  (.fm // {}) as $fm
  | (($fm | lg_fv($F; "status")) | lg_str) as $st
  | {path: .path,
     keyraw: ($fm | lg_fv($F; "key")),
     key: (($fm | lg_fv($F; "key")) | lg_str),
     aliases: (($fm | lg_fv($F; "aliases")) | lg_list),
     ledgerraw: ($fm | lg_fv($F; "ledger")),
     ledger: (($fm | lg_fv($F; "ledger")) | lg_str),
     class: ($st | lg_class($CT; $EX)),
     sup: (($fm | lg_fv($F; "superseded_by")) | lg_str),
     summary: (($fm | lg_fv($F; "summary")) | lg_str),
     resolution: (.resolution | if type == "string" and test("\\S") then . else null end),
     errors: (.fm_errors // []),
     changes: (($fm | lg_fv($F; "changes")) | lg_list),
     consumes: (($fm | lg_fv($F; "consumes")) | lg_list),
     relates: (($fm | lg_fv($F; "relates")) | lg_list),
     optout: ($fm.relations | lg_v_none)};
# An index item → the same fields (hosted: a hosted item — config
# items.adapter — whose adapter supplies no resolution).
def lg_v_iinfo:
  {path, keyraw: .key, key, aliases, ledgerraw: .ledger, ledger, class, sup: .superseded_by, summary,
   resolution: (.resolution | if type == "string" and test("\\S") then . else null end),
   errors: (.fm_errors // []), changes, consumes, hosted: ((.url | type) == "string"),
   pre: (.pre_adoption == true)};
# The tokens (key and aliases, lower case) of an info, with their roles.
def lg_v_toks:
  ((.key // null) | if type == "string" then ascii_downcase else null end) as $k
  | ([if $k != null then {t: $k, role: "key"} else empty end]
     + [.aliases[] | ascii_downcase | select(. != $k) | {t: ., role: "alias"}]) | unique_by(.t);
def lg_v_tokset: [lg_v_toks[] | .t];
# {token: [{p, role}]} over infos.
def lg_v_R($infos):
  reduce ($infos[] | .path as $p | lg_v_toks[] | {t, p: $p, role}) as $x ({}; .[$x.t] += [{p: $x.p, role: $x.role}]);
# The paths a superseded_by value names (key or alias; else a provisional
# key finalized.json maps to a key).
def lg_v_res($R; $fin; $v):
  ($v | ascii_downcase) as $l
  | ([($R[$l] // [])[] | .p] | unique) as $m
  | if $m != [] then $m
    else (($fin | if type == "object" then (.[$v] // .[$l] // null) else null end)) as $to
      | if ($to | type) == "string" then [($R[$to | ascii_downcase] // [])[] | .p] | unique else [] end
    end;
# The supersession verdict of the item at path $S. $M: {path: {sup, class,
# key}}. {k: "dangling"} (its own target resolves to nothing), {k:
# "ambiguous", v} (to several items), {k: "cycle", path} (following
# superseded_by comes back to an item it passed), else {k: "ok", path
# (from $S to the end), hops, end, brk}: the chain is followed while each
# link resolves to one item; end is the last item reached, brk (or null)
# {at, v, why} where a later link stops resolving.
def lg_v_chain($M; $R; $fin; $S):
  lg_v_res($R; $fin; $M[$S].sup) as $t1
  | if ($t1 | length) == 0 then {k: "dangling"}
    elif ($t1 | length) > 1 then {k: "ambiguous", v: $t1}
    elif $t1[0] == $S then {k: "cycle", path: [$S, $S]}
    else
      {cur: $t1[0], seen: [$S, $t1[0]], hops: 1, r: null}
      | until(.r != null;
          ($M[.cur].sup) as $s
          | if $s == null then .r = {k: "end", brk: null}
            else lg_v_res($R; $fin; $s) as $t
            | if ($t | length) == 0 then .r = {k: "end", brk: {at: .cur, v: $s, why: "names no item"}}
              elif ($t | length) > 1 then .r = {k: "end", brk: {at: .cur, v: $s, why: "names several items"}}
              elif (.seen | index([$t[0]])) != null then .r = {k: "cycle", path: (.seen + [$t[0]])}
              else .cur = $t[0] | .seen += [$t[0]] | .hops += 1 end
            end)
      | if .r.k == "cycle" then .r else {k: "ok", path: .seen, hops, end: .cur, brk: .r.brk} end
    end;
def lg_v_name($M; $p): ($M[$p].key // null) | if type == "string" then . else ($p | lg_v_tok) end;
# The supersession findings of info $i: a dangling or ambiguous target and a
# cycle take the severity $b; a chain (more than one link, or a later link
# that does not resolve: point superseded_by at the end) and a dead end (the
# chain ends at a closed or wontfix-class item) are advisory.
def lg_v_sup_f($i; $M; $R; $fin; $b):
  if $i.sup == null then empty
  else lg_v_chain($M; $R; $fin; $i.path) as $c
    | if $c.k == "dangling" then
        lg_v_f("superseded-dangling"; lg_v_sev($b); $i.path; $i.key; "superseded_by \($i.sup | lg_v_tok) names no item")
      elif $c.k == "ambiguous" then
        lg_v_f("superseded-dangling"; lg_v_sev($b); $i.path; $i.key;
          "superseded_by \($i.sup | lg_v_tok) names several items: \($c.v | map(lg_v_tok) | join(", "))")
      elif $c.k == "cycle" then
        lg_v_f("superseded-cycle"; lg_v_sev($b); $i.path; $i.key;
          "superseded_by goes round: \([$c.path[] | lg_v_name($M; .)] | join(" → "))")
      else
        (if $c.hops > 1 or $c.brk != null then
           lg_v_f("superseded-chain"; "advisory"; $i.path; $i.key;
             "superseded_by leads on: \([$c.path[1:][] | lg_v_name($M; .)] | join(" → "))"
             + (if $c.brk != null
                then "; the chain breaks at \(lg_v_name($M; $c.brk.at)): superseded_by \($c.brk.v | lg_v_tok) \($c.brk.why)"
                else "" end)
             + (if $c.hops > 1 then "; point it at \(lg_v_name($M; $c.end))" else "" end))
         else empty end),
        (if ($M[$c.end].class | lg_v_term) then
           lg_v_f("superseded-dead-end"; "advisory"; $i.path; $i.key;
             "the chain ends at \(lg_v_name($M; $c.end)), which is \($M[$c.end].class): nothing in effect replaces this item")
         else empty end)
      end
  end;
# The ledger findings of info $i. $mode: "added" | "modified" | "all";
# $changed: the ledger value changed in this commit.
def lg_v_ledger_f($i; $RG; $LEG; $mode; $changed):
  $i.ledger as $l
  | if $l == null then empty
    elif ($i.ledgerraw | type) != "string" then
      lg_v_f("unknown-ledger"; lg_v_sev($mode != "modified" or $changed); $i.path; $i.key; "ledger is not one id: \($i.ledgerraw | tojson)")
    elif $l == "unassigned" or ($RG.active | index([$l])) != null then empty
    elif ($RG.retired | index([$l])) != null then
      (if $mode == "all" and ($i.class == "open" or $i.class == "unknown" | not) then empty
       else lg_v_f("retired-ledger"; lg_v_sev($mode == "added"); $i.path; $i.key;
         "ledger \($l | lg_v_tok) is retired: it takes no new items (ledger assign <item> <ledger>)") end)
    elif ($LEG | index([$l])) != null then
      lg_v_f("legacy-ledger-id"; lg_v_sev($mode == "added"); $i.path; $i.key;
        "ledger \($l | lg_v_tok) is a legacy id: run ledger assign <item> <ledger>")
    else
      lg_v_f("unknown-ledger"; lg_v_sev($mode != "modified" or $changed); $i.path; $i.key;
        "ledger \($l | lg_v_tok) is not a registered ledger (nor unassigned)")
    end;
# The duplicate findings of info $i. $had: {path: [tokens]} — the tokens
# each staged item had at HEAD ([] when added); an item it does not list is
# unchanged (--all passes {}: every token is new). A duplicate blocks when
# its token is new to either side.
def lg_v_dup_f($i; $R; $had):
  $i | lg_v_toks[] as $x
  | [($R[$x.t] // [])[] | select(.p != $i.path)] as $o
  | if $o == [] then empty
    else
      ($had[$i.path] == null or ($had[$i.path] | index([$x.t])) == null
       or any($o[]; . as $y | $had[$y.p] != null and ($had[$y.p] | index([$x.t])) == null)) as $b
      | lg_v_f("duplicate-key"; lg_v_sev($b); $i.path; $i.key;
          "\($x.t | lg_v_tok) (its \($x.role)) is also \($o | map("the \(.role) of \(.p | lg_v_tok)") | join(", "))")
    end;
def lg_v_registry_sets($reg):
  {active: [$reg.ledgers[] | select(.status != "retired") | .id | strings],
   retired: [$reg.ledgers[] | select(.status == "retired") | .id | strings]};
def lg_v_text:
  .class
  + (if (.path | type) == "string" then " " + (.path | lg_v_tok)
     elif (.key | type) == "string" then " " + (.key | lg_v_tok) else "" end)
  + " " + (.detail | lg_v_tok)
  + (if .severity == "advisory" then " (advisory)" else "" end);
'

# The --staged join. Inputs (slurped): $c config, $reg the staged registry,
# $fin the staged finalized map, $map the key map (records of every staged
# item file, from git grep), $new the staged items' records, $old their
# records at HEAD (by old path), $meta {"p","st":"A"|"M","old"}; --arg rr
# config validate.require_relations ("" off, "new").
# shellcheck disable=SC2016  # jq source
_LG_JQ_VALIDATE_STAGED='
$c[0] as $cfg
| lg_fields($cfg) as $F
| lg_class_terms($cfg) as $CT
| (reduce ($CT | reverse)[] as $x ({}; .[$x.t] = $x.c)) as $EX
| lg_v_registry_sets($reg[0]) as $RG
| [($cfg.legacy_ids // []) | .[]? | strings] as $LEG
| $fin[0] as $FIN
| [$new[] | lg_v_rinfo($F; $CT; $EX)] as $NEW
| (reduce $NEW[] as $n ({}; .[$n.path] = $n)) as $NEWBY
| (reduce ($old[] | lg_v_rinfo($F; $CT; $EX)) as $o ({}; .[$o.path] = $o)) as $OLD
| (reduce $meta[] as $m ({}; .[$m.p] = $m)) as $META
| ([$map[] | select($NEWBY[.path] == null) | lg_v_rinfo($F; $CT; $EX)] + $NEW) as $ALL
| lg_v_R($ALL) as $R
| (reduce $ALL[] as $i ({}; .[$i.path] = {sup: $i.sup, class: $i.class, key: $i.key})) as $M
# The tokens each staged item had at HEAD (an added item: none, so every
# token is new to it).
| (reduce $NEW[] as $n ({};
     ($META[$n.path]) as $m
     | .[$n.path] = (if $m.st == "M" and $OLD[$m.old] != null then ($OLD[$m.old] | lg_v_tokset) else [] end))) as $HAD
| [ $NEW[] | . as $i
    | ($META[$i.path]) as $m
    | ($m.st == "A") as $added
    | (if $added then null else ($OLD[$m.old] // {}) end) as $o
    | (if $added then "added" else "modified" end) as $mode
    | ($added or ($o.class | lg_v_term | not)) as $wasopen
    | (($i.class | lg_v_term) and $wasopen) as $into
    | ($added or $o.sup != $i.sup) as $supch
    | (if ($i.keyraw | lg_v_present) and ($i.keyraw | lg_v_keyform | not) then
         lg_v_f("bad-key"; lg_v_sev($added or $o.keyraw != $i.keyraw); $i.path; $i.key;
           "key \($i.keyraw | tojson | lg_v_tok) is not <ledger>-<n> or <ledger>-~<4–8 hex>")
       else empty end),
      lg_v_dup_f($i; $R; $HAD),
      lg_v_ledger_f($i; $RG; $LEG; $mode; $added or $o.ledgerraw != $i.ledgerraw),
      (if $i.ledger == null then lg_v_f("missing-ledger"; lg_v_sev($added); $i.path; $i.key;
         "no ledger: name its ledger, or unassigned") else empty end),
      (if $i.summary == null then lg_v_f("missing-summary"; lg_v_sev($added); $i.path; $i.key;
         "no summary (why it matters, at most 140 characters)") else empty end),
      (if $i.key == null and $i.ledger != null and $i.ledger != "unassigned" and ($i.ledgerraw | type) == "string" then
         lg_v_f("missing-key"; "advisory"; $i.path; null; "no key: run ledger new --file <item> --ledger \($i.ledger | lg_v_tok)")
       else empty end),
      (if ($i.class | lg_v_term) and $i.resolution == null then
         lg_v_f("missing-resolution"; lg_v_sev($into); $i.path; $i.key;
           "status \($i.class) needs a resolution (a line under the resolution heading)")
       else empty end),
      lg_v_sup_f($i; $M; $R; $FIN; $into or $supch),
      (if $i.sup != null and $i.class != "closed" then
         lg_v_f("superseded-not-closed"; lg_v_sev($supch or $o.class != $i.class); $i.path; $i.key;
           "superseded_by \($i.sup | lg_v_tok) on an item whose status is not closed (\($i.class))")
       else empty end),
      (if $rr == "new" and $added and $i.class == "open" and $i.changes == [] and $i.consumes == [] and $i.relates == []
          and ($i.optout | not) then
         lg_v_f("no-relations"; "block"; $i.path; $i.key; lg_v_norel_detail)
       else empty end),
      (if $i.errors != [] then lg_v_f("parse-error"; "advisory"; $i.path; $i.key; ($i.errors | join("; "))) else empty end)
  ][]
'

# The --all program over the index: every item, the blocking classes block.
# shellcheck disable=SC2016  # jq source
_LG_JQ_VALIDATE_ALL='
$c[0] as $cfg
| lg_v_registry_sets(.) as $RG
| [($cfg.legacy_ids // []) | .[]? | strings] as $LEG
| (.finalized // {}) as $FIN
| [.items[] | lg_v_iinfo] as $ALL
| lg_v_R($ALL) as $R
| (reduce $ALL[] as $i ({}; .[$i.path] = {sup: $i.sup, class: $i.class, key: $i.key})) as $M
| $ALL[] | . as $i
| (if ($i.keyraw | lg_v_present) and ($i.keyraw | lg_v_keyform | not) then
     lg_v_f("bad-key"; "block"; $i.path; $i.key; "key \($i.keyraw | tojson | lg_v_tok) is not <ledger>-<n> or <ledger>-~<4–8 hex>")
   else empty end),
  lg_v_dup_f($i; $R; {}),
  lg_v_ledger_f($i; $RG; $LEG; "all"; true),
  (if $i.ledger == null then lg_v_f("missing-ledger"; "advisory"; $i.path; $i.key; "no ledger: name its ledger, or unassigned")
   else empty end),
  (if $i.summary == null then lg_v_f("missing-summary"; "advisory"; $i.path; $i.key; "no summary (why it matters, at most 140 characters)")
   elif ($i.summary | length) < 20 then lg_v_f("weak-summary"; "advisory"; $i.path; $i.key;
     "the summary is \($i.summary | length) characters: say why it matters (20 or more)")
   else empty end),
  (if $i.key == null and $i.ledger != null and $i.ledger != "unassigned" then
     lg_v_f("missing-key"; "advisory"; $i.path; null;
       if $i.hosted then "no key: a hosted item takes one in its metadata (its adapter: write <ref> key <key>)"
       else "no key: run ledger new --file <item> --ledger \($i.ledger | lg_v_tok)" end)
   else empty end),
  (if $i.ledger == "unassigned" and $i.class == "open" then
     lg_v_f("unassigned-open"; "advisory"; $i.path; $i.key; "open and unassigned: give it a home (ledger assign <item> <ledger>)")
   else empty end),
  (if $i.class == "open" and $i.changes == [] and $i.consumes == [] then
     lg_v_f("no-contract"; "advisory"; $i.path; $i.key; "open, and names no contract it changes or consumes")
   else empty end),
  (if ($i.class | lg_v_term) and $i.resolution == null and ($i.hosted | not) then
     lg_v_f("missing-resolution"; lg_v_sev($i.pre | not); $i.path; $i.key;
       "status \($i.class) needs a resolution (a line under the resolution heading)"
       + (if $i.pre then " — terminal before adoption" else "" end))
   else empty end),
  lg_v_sup_f($i; $M; $R; $FIN; true),
  (if $i.sup != null and $i.class != "closed" then
     lg_v_f("superseded-not-closed"; "block"; $i.path; $i.key;
       "superseded_by \($i.sup | lg_v_tok) on an item whose status is not closed (\($i.class))")
   else empty end),
  (if $i.errors != [] then lg_v_f("parse-error"; "advisory"; $i.path; $i.key; ($i.errors | join("; "))) else empty end)
'

# The key map's program (awk, after frontmatter.awk run with mode=lib — it
# then defines its parser and runs none of its own rules — and glob.sh's
# _LG_AWK_GLOB). Input: `git grep -z -n` output passed through
# tr '\n\000' '\001\n': line 1 is the first path; then a line number, then
# "<text>\001<next path>", and so on (text holds no newline, a path may —
# as \001 — so each path is read whole; a name holding a newline is left
# out, with one note per name to -v notes). Lines: the "---" lines, the
# wanted fields' lines and the list lines. For each path whose line 1 is
# "---" and whose frontmatter closes, a document made of its frontmatter
# lines git grep found: the "---" lines, the wanted fields' lines, and the
# list lines that follow one of those without a gap. A list line after a
# gap (a blank or comment line inside a block list — git grep does not
# list those — or a list under a field not grepped) makes the file
# ambiguous: the document may not be what the parser reads.
# Then, from the tokens (-v toks: a file, one lower-case token per line):
# each item file (-v globs: "i\t<glob>" / "a\t<glob>" lines) whose grepped
# frontmatter lines hold a token (case-insensitive substring: a superset)
# is parsed with frontmatter.awk's own functions and its record printed —
# an ambiguous one is named in -v amb instead (the caller parses its whole
# index blob); its superseded_by (-v supn: the candidate names) becomes a
# token too — through -v fin ("<provisional>\t<key>" lines) when
# docs/ledger/finalized.json maps it — until no new token appears, so every
# item a chain reaches is read.
# shellcheck disable=SC2016  # awk source
_LG_AWK_VALIDATE_MAP='
BEGIN {
  SOHC = sprintf("%c", 1)
  while ((getline vm_l < toks) > 0) vm_add(vm_l)
  close(toks)
  while ((getline vm_l < fin) > 0) { vm_i = index(vm_l, "\t"); if (vm_i) VM_FIN[substr(vm_l, 1, vm_i - 1)] = substr(vm_l, vm_i + 1) }
  close(fin)
  vm_nsn = split(supn, VM_SN, " ")
  vm_k = 0
  while ((getline vm_l < globs) > 0) {
    vm_k++
    if (!gx_add(vm_k, substr(vm_l, 3))) { print "bad glob \047" substr(vm_l, 3) "\047: " GLOB_ERR > "/dev/stderr"; VM_BAD = 1; exit 2 }
  }
  close(globs)
  printf "" > amb; printf "" > notes
  vm_nf = 0; vm_state = 0; vm_n = 0; vm_last = -1; vm_cur = ""; vm_raw = ""; vm_amb = 0
}
function vm_add(t) {
  if (t != "" && !(t in VM_TS)) { VM_TS[t] = 1; VM_TL[++VM_NT] = t }
}
function vm_flush(   i) {
  if (vm_cur != "" && vm_state == 2) {
    vm_nf++
    VM_P[vm_nf] = vm_cur
    VM_DN[vm_nf] = vm_n
    for (i = 1; i <= vm_n; i++) VM_DL[vm_nf, i] = vm_L[i]
    VM_LOW[vm_nf] = tolower(vm_raw)
    if (vm_amb) VM_AMB[vm_nf] = 1
  }
  vm_n = 0; vm_state = 0; vm_last = -1; vm_raw = ""; vm_amb = 0
}
function vm_emit(f,   i, j, nm, v, r) {
  VM_DONE[f] = 1
  gx_match(VM_P[f])
  if (GX_MN == 0) return
  doc_begin()
  for (i = 1; i <= VM_DN[f]; i++) doc_line(VM_DL[f, i])
  r = doc_end()
  if (f in VM_AMB) print VM_P[f] > amb
  else print "{\"path\":" js(VM_P[f]) "," substr(r, 2)
  for (j = 1; j <= vm_nsn; j++) {
    nm = VM_SN[j]
    if (!(nm in FV)) continue
    v = FV[nm]
    if (v ~ /^".*"$/) {
      v = substr(v, 2, length(v) - 2)
      v = rep(v, "\\\"", "\""); v = rep(v, "\\\\", "\\")
      v = tolower(v)
      vm_add(v)
      if (v in VM_FIN) vm_add(VM_FIN[v])
    }
    break
  }
}
# One grepped line: path p, line number no, text t.
function vm_line(p, no, t) {
  if (index(p, SOHC)) {
    if (!(p in VM_NLN)) {
      VM_NLN[p] = 1
      print "ledger: " js(rep(p, SOHC, "\n")) " holds a newline in its name: left out of the key map" > notes
    }
    return
  }
  if (p != vm_cur) { vm_flush(); vm_cur = p }
  if (vm_state >= 2) return
  if (no == 1 && bom != "" && substr(t, 1, length(bom)) == bom) t = substr(t, length(bom) + 1)
  sub(/\r$/, "", t)
  if (vm_state == 0) {
    if (no == 1 && t ~ /^---[ \t]*$/) { vm_state = 1; vm_L[++vm_n] = "---" }
    else vm_state = 3
    return
  }
  if (t ~ /^---[ \t]*$/) { vm_L[++vm_n] = "---"; vm_state = 2; return }
  vm_raw = vm_raw "\n" t
  if (t ~ /^[ \t]*-([ \t]|$)/) {
    if (no == vm_last + 1) { vm_L[++vm_n] = t; vm_last = no }
    else vm_amb = 1
    return
  }
  vm_L[++vm_n] = t; vm_last = no
}
NR == 1 { vm_np = $0; vm_want = 0; next }
vm_want == 0 { vm_lno = $0 + 0; vm_want = 1; next }
{
  vm_i = index($0, SOHC)
  if (vm_i) { vm_t = substr($0, 1, vm_i - 1); vm_nx = substr($0, vm_i + 1) } else { vm_t = $0; vm_nx = "" }
  vm_line(vm_np, vm_lno, vm_t)
  vm_np = vm_nx; vm_want = 0
}
END {
  if (VM_BAD) exit 2
  vm_flush()
  vm_lo = 1
  while (vm_lo <= VM_NT) {
    vm_hi = VM_NT
    for (vm_f = 1; vm_f <= vm_nf; vm_f++) {
      if (vm_f in VM_DONE) continue
      for (vm_t = vm_lo; vm_t <= vm_hi; vm_t++) if (index(VM_LOW[vm_f], VM_TL[vm_t])) { vm_emit(vm_f); break }
    }
    vm_lo = vm_hi + 1
  }
}
'

# _lg_v_item_globs <out>: "i\t<glob>" per items.globs entry, "a\t<glob>"
# per items.archive_globs entry (the order gx_add numbers them in).
_lg_v_item_globs() {
  _lg_cfg '((.items.globs // [])[]? | strings | select(. != "") | "i\t" + .),
           ((.items.archive_globs // [])[]? | strings | select(. != "") | "a\t" + .)' > "$1"
}

# _lg_v_keymap <tokens> <fin.tsv> <globs> <out.jsonl>: the key map — the
# full parser's records (frontmatter fields key / aliases / status /
# superseded_by / ledger; other fields absent) of every staged item file
# whose frontmatter names one of <tokens> or a superseded_by target reached
# from them (see _LG_AWK_VALIDATE_MAP): every item a staged key or alias
# could collide with, and every link of a supersession chain. One
# `git grep --cached` over the item globs' directories reads the index; no
# walk over the items. A file whose grepped lines cannot be trusted to
# rebuild its frontmatter (a list line after a gap) is parsed whole, from
# its index blob (_lg_parse_blobs :). Known deviation from parsing the
# whole file: a plain value folded onto an indented continuation line keeps
# its first line only. A name holding a newline is left out (a note on
# stderr), as the parser leaves it unparsed.
_lg_v_keymap() {
  local toks="$1" fin="$2" globs="$3" out="$4" s names supn d rc=0
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  : > "$out"
  [ -s "$toks" ] || return 0
  # The field names (every candidate) as an ERE alternation; superseded_by's
  # candidates in order.
  _lg_cfg '([.fields | (.key, .aliases, .status, .superseded_by, .ledger)
        | if type == "array" then .[] else . end | strings | select(test("\\A[[:alnum:]_][[:alnum:]_.-]*\\z"))]
        | unique | map(gsub("\\."; "\\.")) | join("|")),
       ([.fields.superseded_by | if type == "array" then .[] else . end | strings
        | select(test("\\A[[:alnum:]_][[:alnum:]_.-]*\\z"))] | join(" "))' > "$s.names"
  { IFS= read -r names; IFS= read -r supn; } < "$s.names" || true
  [ -n "$names" ] || return 0
  LC_ALL=C awk '{ print substr($0, 3) }' "$globs" > "$s.globs"
  : > "$s.dirs"
  [ ! -s "$s.globs" ] || _lg_glob_dirs "$s.globs" "$s.dirs"
  while IFS= read -r d; do
    specs+=("$d")
  done < "$s.dirs"
  # Exit 1 is "no line matched".
  GIT_LITERAL_PATHSPECS=1 LC_ALL=C git -c grep.column=false -c grep.lineNumber=true -c grep.fullName=true \
      grep --cached -I -z -n --no-color -E \
      -e "^($_LG_BOM)?---[[:space:]]*\$" -e "^($names)[[:space:]]*:" -e '^[[:space:]]*-([[:space:]]|$)' \
      -- ${specs[@]+"${specs[@]}"} > "$s.grep" 2> "$s.err" || rc=$?
  case "$rc" in
    0|1) ;;
    *) _lg_die "git grep failed: $(head -n 3 "$s.err" 2>/dev/null)" ;;
  esac
  [ -s "$s.grep" ] || return 0
  tr '\n\000' '\001\n' < "$s.grep" > "$s.lines" || _lg_die "cannot read the git grep output"
  printf '%s\n%s\n' "$_LG_AWK_GLOB" "$_LG_AWK_VALIDATE_MAP" > "$s.awk" || _lg_die "cannot write $s.awk"
  rc=0
  LC_ALL=C awk -v mode=lib -v toks="$toks" -v fin="$fin" -v globs="$globs" -v supn="$supn" \
      -v amb="$s.amb" -v notes="$s.notes" "${_LG_PARSE_ARGS[@]}" \
    -f "$_LG_LIB/frontmatter.awk" -f "$s.awk" "$s.lines" > "$out" 2> "$s.err" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot build the key map: $(head -n 3 "$s.err" 2>/dev/null)"
  if [ -s "$s.notes" ]; then cat -- "$s.notes" >&2 || true; fi
  # The ambiguous files: their whole index blobs, through the parse cache.
  if [ -s "$s.amb" ]; then
    tr '\n' '\000' < "$s.amb" > "$s.ambz" || _lg_die "cannot write $s.ambz"
    _lg_parse_blobs : "$s.ambz" "$s.ambrecs"
    cat -- "$s.ambrecs" >> "$out" || _lg_die "cannot write $out"
  fi
}

# _lg_v_staged_list <prefix>: the staged item files, from one
# `git diff --cached --raw -M` (blob ids from the index and HEAD — nothing
# listed or looked up per path). Writes <prefix>.meta ({"p","st","old"} per
# staged item: "A" — added, copied, or moved in from outside the item
# globs — or "M" — modified, type-changed, or renamed from an item path,
# <old> naming it), and the parse manifests of the staged blobs
# (<prefix>.nman, error records in <prefix>.nerr) and of the HEAD blobs of
# the modified ones (<prefix>.oman / .oerr), in _lg_parse_finish's format.
# Deleted and unmerged entries are not staged items. Sets _LG_V_REGISTRY=1
# when docs/ledger/ledgers.json is among the staged paths.
_lg_v_staged_list() {
  local p="$1" map rc=0
  git diff --cached -z --raw --no-abbrev -M --no-color --no-ext-diff > "$p.diff" 2> "$p.err" \
    || _lg_die "git diff --cached failed: $(head -n 3 "$p.err" 2>/dev/null)"
  _lg_v_item_globs "$p.globs"
  map="$_LG_CACHE/blob-sha256.tsv"
  [ -f "$map" ] || map=/dev/null
  _lg_awkv "$map"
  # Records: ":<mode> <mode> <oid> <oid> <status>", then one path (two for
  # R and C: old, new); paths' newlines as \001.
  tr '\n\000' '\001\n' < "$p.diff" | LC_ALL=C awk -v globs="$p.globs" -v map="$_LG_AV" \
      -v reg=docs/ledger/ledgers.json -v regf="$p.reg" \
      -v nman="$p.nman" -v nerr="$p.nerr" -v oman="$p.oman" -v oerr="$p.oerr" "$_LG_AWK_JS$_LG_AWK_GLOB"'
    function arch(q,   j) { for (j = 1; j <= GX_MN; j++) if (GX_M[j] in ARCHK) return 1; return 0 }
    function entry(q, mode, oid, man, err, where,   k, h, a) {
      if (index(q, SOH)) { print err_record(q, "the path holds a newline: not parsed") > err; return }
      if (mode == "160000") { print err_record(q, "a submodule (gitlink) at " where ": not parsed") > err; return }
      if (mode == "120000") { print err_record(q, "a symbolic link at " where ": not parsed") > err; return }
      if (mode !~ /^100/) { print err_record(q, "not a file (mode " mode ") at " where) > err; return }
      gx_match(q); a = arch(q)
      k = "b-" oid
      if (oid in H) { h = H[oid]; sub(/^sha256:/, "", h); k = "c-" h "|" k }
      printf "%s\t%s\t%s\t%s\n", k, oid, a, q > man
    }
    BEGIN {
      js_init()
      while ((getline l < map) > 0) {
        t = index(l, "\t")
        if (t && substr(l, t + 1) ~ /^sha256:[0123456789abcdef]+$/) H[substr(l, 1, t - 1)] = substr(l, t + 1)
      }
      k = 0
      while ((getline l < globs) > 0) {
        k++
        if (!gx_add(k, substr(l, 3))) { print "bad glob \047" substr(l, 3) "\047: " GLOB_ERR > "/dev/stderr"; bad = 1; exit 2 }
        if (substr(l, 1, 1) == "a") ARCHK[k] = 1
      }
      printf "" > regf; printf "" > nman; printf "" > nerr; printf "" > oman; printf "" > oerr
      need = 0
    }
    need == 0 {
      if (substr($0, 1, 1) != ":") { print "unexpected git diff --raw output: " $0 > "/dev/stderr"; bad = 1; exit 2 }
      split(substr($0, 2), h, " ")
      sm = h[1]; dm = h[2]; so = h[3]; dn = h[4]; st = substr(h[5], 1, 1)
      need = (st == "R" || st == "C") ? 2 : 1; np = 0
      next
    }
    {
      P[++np] = $0; need--
      if (need > 0) next
      q = P[np]; o = P[1]
      if (q == reg || o == reg) print "1" > regf
      if (st != "A" && st != "M" && st != "T" && st != "R" && st != "C") next
      gx_match(q); if (GX_MN == 0) next
      kind = "M"
      if (st == "A" || st == "C") kind = "A"
      else if (st == "R") { gx_match(o); if (GX_MN == 0) kind = "A" }
      entry(q, dm, dn, nman, nerr, "the index")
      if (kind == "M") entry(o, sm, so, oman, oerr, "HEAD")
      print "{\"p\":" js(rep(q, SOH, "\n")) ",\"st\":\"" kind "\",\"old\":" (kind == "M" ? js(rep(o, SOH, "\n")) : "null") "}"
    }
    END { if (bad) exit 2; if (need != 0) { print "git diff --raw output cut short" > "/dev/stderr"; exit 2 } }' \
    > "$p.meta" 2> "$p.aerr" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot list the staged items: $(head -n 3 "$p.aerr" 2>/dev/null)"
  _LG_V_REGISTRY=""
  [ ! -s "$p.reg" ] || _LG_V_REGISTRY=1
}

# _lg_v_registry_into <registry> <tracked-nul> <out.jsonl>: the registry's
# findings as item-check findings (class "registry", detail
# "<registry class> <detail>"), appended to <out>.
_lg_v_registry_into() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  _lg_registry_findings "$1" "$2" "$s.rf"
  jq -c '{class: "registry", severity: "block", path: null, key: null, detail: "\(.class) \(.detail)"}' "$s.rf" >> "$3" \
    || _lg_die "jq failed (registry findings)"
}

# _lg_validate_staged <findings.jsonl>: --staged's findings. Never builds the
# index: the staged items (and, for the modified ones, their HEAD blobs) are
# parsed through the parse cache; everything they could collide with or
# point at comes from the key map.
# shellcheck disable=SC2154  # _OPT_* are set by _parse_args
_lg_validate_staged() {
  local out="$1" s reg
  _lg_v_rr
  _lg_scratch_name
  s=$_LG_SN
  _lg_parse_prep
  _lg_v_staged_list "$s"
  : > "$out"
  reg=$(_lg_registry :) || exit "$?"
  if [ "$_LG_V_REGISTRY" = 1 ] || [ "$_OPT_registry" = 1 ]; then
    git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
      || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
    _lg_v_registry_into "$reg" "$s.tracked" "$out"
  fi
  [ -s "$s.meta" ] || return 0
  _lg_parse_finish "$s.nman" "$s.nerr" "$s.new" _lg_parse_batch "$s.n"
  _lg_parse_finish "$s.oman" "$s.oerr" "$s.old" _lg_parse_batch "$s.o"
  _lg_ix_json_obj : docs/ledger/finalized.json "$s.fin" "finalized map"
  # The tokens: the staged items' keys, aliases and superseded_by targets
  # (lower case; a provisional target finalized.json maps adds its key).
  jq -L "$_LG_LIB" -n -r --slurpfile c "$_LG_CFG" --slurpfile fin "$s.fin" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F
    | ($fin[0] | if type == "object" then [to_entries[] | select(.value | type == "string")
        | {key: (.key | ascii_downcase), value: (.value | ascii_downcase)}] | from_entries else {} end) as $FIN
    | [inputs | (.fm // {})
       | ((lg_fv($F; "key") | lg_str), (lg_fv($F; "aliases") | lg_list[]), (lg_fv($F; "superseded_by") | lg_str))
       | strings | ascii_downcase] as $t
    | ($t + [$t[] | $FIN[.] // empty]) | unique[] | select(test("[\\n\\r]") | not)' "$s.new" > "$s.toks" \
    || _lg_die "jq failed (staged tokens)"
  jq -r 'if type == "object" then to_entries[] | select(.value | type == "string")
      | "\(.key | ascii_downcase)\t\(.value | ascii_downcase)" | select(test("\n") | not) else empty end' \
    "$s.fin" > "$s.fintsv" || _lg_die "jq failed (finalized map)"
  _lg_v_keymap "$s.toks" "$s.fintsv" "$s.globs" "$s.map"
  jq -L "$_LG_LIB" -n -c --slurpfile c "$_LG_CFG" --slurpfile reg "$reg" --slurpfile fin "$s.fin" \
      --slurpfile map "$s.map" --slurpfile new "$s.new" --slurpfile old "$s.old" --slurpfile meta "$s.meta" --arg rr "$_LG_V_RR" \
      "$_LG_JQ_INDEX_DEFS$_LG_JQ_VALIDATE_DEFS$_LG_JQ_VALIDATE_STAGED" >> "$out" \
    || _lg_die "jq failed (validate --staged)"
}

# _lg_validate_all <findings.jsonl>: --all's findings, over the working-tree
# index.
# shellcheck disable=SC2154  # _OPT_* are set by _parse_args
_lg_validate_all() {
  local out="$1" ix reg
  _lg_v_rr
  # Hosted items (config items.adapter) through the items cache, fresh or
  # stale — the run's note says which; with no copy and the adapter
  # failing, exit 2 (index.sh _lg_ix_items_prepare).
  _LG_IX_NEED_ITEMS=1
  ix=$(_lg_index) || exit "$?"
  _LG_IX_NEED_ITEMS=""
  : > "$out"
  if [ "$_OPT_registry" = 1 ]; then
    local s
    _lg_scratch_name
    s=$_LG_SN
    git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
      || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
    reg=$(_lg_registry) || exit "$?"
    _lg_v_registry_into "$reg" "$s.tracked" "$out"
  fi
  jq -L "$_LG_LIB" -c --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS$_LG_JQ_VALIDATE_DEFS$_LG_JQ_VALIDATE_ALL" "$ix" >> "$out" \
    || _lg_die "jq failed (validate --all)"
  [ "$_LG_V_RR" != new ] || _lg_v_rr_all "$ix" "$out"
  _lg_v_config_findings "$out"
}

# _lg_v_rr → _LG_V_RR: config validate.require_relations — "" (null or
# absent: off, the default) or "new". Any other value, or a validate that is
# not an object, is a config error (exit 2).
_lg_v_rr() {
  local v
  v=$(_lg_cfg '(.validate // {}) | if type != "object" then "!validate is \(tojson), not an object"
      else (.require_relations | if . == null then "-" elif . == "new" then "new" else "!\(tojson)" end) end') || exit "$?"
  case "$v" in
    -) _LG_V_RR="" ;;
    new) _LG_V_RR=new ;;
    *) _lg_die "config validate.require_relations must be \"new\" or null (got ${v#!})" ;;
  esac
}

# _lg_v_rr_all <index> <findings.jsonl>: --all's no-relations findings
# (config validate.require_relations "new"; advisory, as --all reports a
# missing ledger or summary): an open file item (not hosted) whose changes,
# consumes and relates are empty, whose frontmatter does not say
# relations: none, and that is new since adoption — its path is neither in
# the adoption commit's tree (_lg_adoption_commit: the first commit on
# config base to add docs/ledger/config.json) nor the new path of a rename
# from a file there (git diff -M from that commit to the working tree;
# untracked files are new). Config base with no adoption commit yet: no item
# is new. Fails closed — every such item counts — when config base does not
# resolve or the adoption commit cannot be known (a shallow boundary).
_lg_v_rr_all() {
  local ix="$1" out="$2" s base A all=0 d
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  base=$(jq -r '.built.base // ""' "$ix") || _lg_die "jq failed (the index's base)"
  : > "$s.old"
  if [ -z "$base" ]; then
    all=1
  else
    _lg_adoption_commit "$base"
    A=$_LG_ADOPTC
    case "$A" in
      "") return 0 ;;
      "?") all=1 ;;
      *)
        _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$s.globs"
        _lg_glob_dirs "$s.globs" "$s.dirs"
        while IFS= read -r d; do
          specs+=("$d")
        done < "$s.dirs"
        if ! GIT_LITERAL_PATHSPECS=1 git ls-tree -r -z --name-only "$A" -- ${specs[@]+"${specs[@]}"} > "$s.at" 2> "$s.err" \
            || ! GIT_LITERAL_PATHSPECS=1 git diff -M -z --name-status --no-color --no-ext-diff --diff-filter=R "$A" \
              -- ${specs[@]+"${specs[@]}"} > "$s.ren" 2>> "$s.err"; then
          _lg_die "git failed (the items at the adoption commit): $(head -n 3 "$s.err" 2>/dev/null)"
        fi
        # The old paths, one per line (a newline in a name as \001): the
        # adoption tree's, then each rename's new path (status, old, new).
        { tr '\n\000' '\001\n' < "$s.at"
          tr '\n\000' '\001\n' < "$s.ren" | LC_ALL=C awk 'NR % 3 == 0'; } > "$s.old" \
          || _lg_die "cannot list the items at the adoption commit"
        ;;
    esac
  fi
  # The candidates (NUL-terminated paths), then their opt-outs from the
  # working copies (the index carries no relations field).
  # shellcheck disable=SC2016  # jq source
  jq -c --rawfile old "$s.old" --argjson all "$all" '
    (reduce ($old | split("\n")[] | select(. != "") | gsub("\u0001"; "\n")) as $p ({}; .[$p] = true)) as $O
    | reduce (.items[] | select((.url | type) != "string" and .class == "open" and .changes == [] and .consumes == []
        and ((.relates // []) | length) == 0 and ($all == 1 or ($O[.path] | not)))) as $i ({}; .[$i.path] = $i.key)' \
    "$ix" > "$s.cand" || _lg_die "jq failed (no-relations candidates)"
  jq -r -j 'keys_unsorted[] | . + "\u0000"' "$s.cand" > "$s.candz" || _lg_die "jq failed (no-relations candidates)"
  [ -s "$s.candz" ] || return 0
  _lg_parse_worktree "$s.candz" "$s.recs"
  # shellcheck disable=SC2016  # jq source
  jq -c --slurpfile k "$s.cand" "$_LG_JQ_VALIDATE_DEFS"'select((.fm // {}).relations | lg_v_none | not)
    | lg_v_f("no-relations"; "advisory"; .path; $k[0][.path]; lg_v_norel_detail)' \
    "$s.recs" >> "$out" || _lg_die "jq failed (no-relations findings)"
}

# _lg_v_config_findings <findings.jsonl>: --all's config findings
# (advisory): state_watch.paths names an entry while state_watch.patterns
# names none (absent, null, not a list, or only empty strings) — the
# state-watch hook never fires (3.3.1, an adopter finding: patterns
# defaults to []).
_lg_v_config_findings() {
  # shellcheck disable=SC2016  # jq source
  jq -c '(.state_watch // {}) | if type == "object" then . else {} end
    | select(([.paths | arrays | .[] | strings | select(. != "")] | length) > 0
        and ([.patterns | arrays | .[] | strings | select(. != "")] | length) == 0)
    | {class: "config", severity: "advisory", path: "docs/ledger/config.json", key: null,
       detail: "state_watch.paths is set but state_watch.patterns names nothing: the state-watch hook never fires (add phrases such as \"next:\" or \"approved\"; a write must hold one)"}' \
    "$_LG_CFG" >> "$1" || _lg_die "jq failed (config findings)"
}

# --- --plan, --pushed ---------------------------------------------------------------

# _lg_validate_plan <plan> <findings.jsonl>: the plan's "Related work"
# section (a heading of any level named "Related work", case-insensitive, to
# the next heading of the same or a higher level; fenced blocks skipped):
# each table's data rows (after its header and separator rows) need a mark
# in the column headed "Mark" (else the last column): "include", or
# "exclude: <reason>" (case-insensitive; surrounding backticks, * and _
# ignored). Findings (advisory; --strict: blocking): unmarked (empty),
# bad-mark (anything else, or exclude without a reason), no-related-work
# (no such section). Path: the plan; key: the row's first cell.
# shellcheck disable=SC2154  # _OPT_* are set by _parse_args
_lg_validate_plan() {
  local plan="$1" out="$2" s sev=advisory
  _lg_scratch_name
  s=$_LG_SN
  case "$plan" in -*) plan="./$plan" ;; esac
  [ -f "$plan" ] || _lg_die "cannot read the plan '$1': not a file"
  cat -- "$plan" > "$s.plan" 2>/dev/null || _lg_die "cannot read the plan '$1'"
  if [ "$_OPT_strict" = 1 ]; then sev=block; fi
  _lg_awkv "$1"
  LC_ALL=C awk -v plan="$_LG_AV" -v sev="$sev" "$_LG_AWK_JS"'
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function f(c, k, d) {
      print "{\"class\":\"" c "\",\"severity\":\"" sev "\",\"path\":" js(plan) ",\"key\":" (k == "" ? "null" : js(k)) ",\"detail\":" js(d) "}"
    }
    function cells(line,   n, i, c, r) {
      gsub(/\\\|/, "\001", line)
      line = trim(line)
      if (substr(line, 1, 1) == "|") line = substr(line, 2)
      if (substr(line, length(line), 1) == "|") line = substr(line, 1, length(line) - 1)
      n = 0
      while ((i = index(line, "|")) > 0) { C[++n] = trim(rep(substr(line, 1, i - 1), "\001", "|")); line = substr(line, i + 1) }
      C[++n] = trim(rep(line, "\001", "|"))
      return n
    }
    BEGIN { js_init(); insec = 0; found = 0; fence = ""; row = 0 }
    {
      sub(/\r$/, "")
      line = $0
      if (fence != "") { if (index(trim(line), fence) == 1) fence = ""; next }
      if (match(trim(line), /^(```|~~~)/)) { fence = substr(trim(line), 1, 3); tbl = 0; next }
      if (match(line, /^#+[ \t]/)) {
        lvl = RLENGTH - 1
        h = tolower(trim(substr(line, RLENGTH + 1))); sub(/[ \t]*#*[ \t]*$/, "", h)
        if (insec && lvl <= seclvl) insec = 0
        if (!insec && h == "related work") { insec = 1; found = 1; seclvl = lvl }
        tbl = 0
        next
      }
      if (!insec) next
      if (line !~ /^[ \t]*\|/) { tbl = 0; next }
      tbl++
      n = cells(line)
      if (tbl == 1) {
        mc = n
        for (i = 1; i <= n; i++) if (tolower(C[i]) == "mark") { mc = i; break }
        next
      }
      if (tbl == 2 && line ~ /^[ \t]*\|?[ \t]*:?-+/) next
      item = C[1]; m = (mc <= n) ? C[mc] : ""
      while (m ~ /^[`*_]/) m = substr(m, 2)
      while (m ~ /[`*_]$/) m = substr(m, 1, length(m) - 1)
      m = trim(m); lm = tolower(m)
      if (m == "") f("unmarked", item, "line " NR ": " item ": no mark (include | exclude: <reason>)")
      else if (lm == "include") ;
      else if (substr(lm, 1, 8) == "exclude:" && trim(substr(m, 9)) != "") ;
      else if (substr(lm, 1, 7) == "exclude") f("bad-mark", item, "line " NR ": " item ": exclude needs a reason (exclude: <reason>)")
      else f("bad-mark", item, "line " NR ": " item ": " js(m) " is not include | exclude: <reason>")
    }
    END {
      if (!found) {
        printf "{\"class\":\"no-related-work\",\"severity\":\"%s\",\"path\":%s,\"key\":null,\"detail\":%s}\n", sev, js(plan),
          js("no \"Related work\" section (ledger sweep --plan <plan> writes one)")
      }
    }' "$s.plan" > "$out" || _lg_die "cannot read the plan '$1'"
}

# _lg_validate_pushed <range> <findings.jsonl>: keys.mode cas — each
# provisional key the commits of <a>..<b> introduce (_lg_provisional_in_range;
# only the keys the branch adds since its merge-base with config base — <a>
# all zeros (a new branch) or not; every provisional key at <b> for a new
# branch when there is no base to compare) blocks — the
# detail names `ledger finalize --all` for a key the base carries too; merge
# mode — none (provisional keys may reach the base). For pre-push hooks.
_lg_validate_pushed() {
  local range="$1" out="$2" s
  _lg_scratch_name
  s=$_LG_SN
  case "$range" in
    *...*|*..*..*) _lg_usage "--pushed takes one <a>..<b> range (got '$range')" ;;
    *..*) ;;
    *) _lg_usage "--pushed takes a range <a>..<b> (got '$range')" ;;
  esac
  : > "$out"
  _lg_k_cfg
  [ "$_LG_K_MODE" = cas ] || return 0
  _lg_provisional_in_range "$range" > "$s.prov"
  # shellcheck disable=SC2016  # jq source
  jq -R -c --arg base "$_LG_K_BASE" 'split("\t") | (.[0]) as $k | (.[1]) as $w | (.[2:] | join("\t")) as $p
    | ($k | if (explode | any(. < 32 or . == 127)) then tojson else . end) as $ks
    | {class: "provisional-key", severity: "block", path: $p, key: $k,
       detail: (if $w == "base" then "\($ks) is provisional and on the base (\($base)) too: run doc-tools.sh ledger finalize --all before pushing (keys.mode cas)"
                elif $w == "nobase" then "\($ks) is provisional: run doc-tools.sh ledger finalize before pushing (keys.mode cas; config base \($base | tojson) does not resolve here, so keys already on the base count too: ledger finalize --all replaces those)"
                else "\($ks) is provisional: run doc-tools.sh ledger finalize before pushing (keys.mode cas)" end)}' \
    "$s.prov" > "$out" || _lg_die "jq failed (provisional keys)"
}

# _lg_v_finish <findings.jsonl>: print the findings (sorted: the registry's,
# then blocking, then by path, class) and end the run — rc 1 when any blocks.
_lg_v_finish() {
  local f="$1" s rc
  _lg_scratch_name
  s=$_LG_SN
  # Line 1: the exit code; then the payload (JSON) or the text lines.
  jq -s -r --arg fmt "$_LG_FORMAT" "$_LG_JQ_VALIDATE_DEFS"'
    sort_by([(if .class == "registry" then 0 else 1 end), (if .severity == "block" then 0 else 1 end),
             (.path // .key // ""), .class, .detail])
    | (if any(.[]; .severity == "block") then 1 else 0 end),
      (if $fmt == "json" then {findings: .} | tojson else .[] | lg_v_text end)' "$f" > "$s.res" \
    || _lg_die "jq failed (findings)"
  IFS= read -r rc < "$s.res" || _lg_die "jq failed (findings)"
  tail -n +2 "$s.res" > "$s.out" || _lg_die "cannot write $s.out"
  if [ "$_LG_FORMAT" = json ]; then _lg_emit validate "$rc" "$s.out"; fi
  _lg_out_file "$s.out"
  _lg_emit validate "$rc"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_validate() {
  local n=0 f reg
  _lg_init validate
  [ "$_OPT_staged" != 1 ] || n=$((n + 1))
  [ "$_OPT_all" != 1 ] || n=$((n + 1))
  [ -z "$_OPT_plan" ] || n=$((n + 1))
  [ -z "$_OPT_pushed" ] || n=$((n + 1))
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  [ "$n" -le 1 ] || _lg_usage "give one of --staged, --all, --plan <plan>, --pushed <range>"
  [ "$_OPT_strict" != 1 ] || [ -n "$_OPT_plan" ] || _lg_usage "--strict goes with --plan <plan>"
  if [ "$n" = 0 ]; then
    [ "$_OPT_registry" = 1 ] || _lg_usage "give --staged, --all, --registry, --plan <plan> or --pushed <range>"
    _lg_validate_registry
  fi
  f="$_SCRATCH/lg-validate.findings"
  if [ "$_OPT_staged" = 1 ]; then
    _lg_validate_staged "$f"
  elif [ "$_OPT_all" = 1 ]; then
    _lg_validate_all "$f"
  elif [ -n "$_OPT_plan" ]; then
    _lg_validate_plan "$_OPT_plan" "$f"
  else
    _lg_validate_pushed "$_OPT_pushed" "$f"
  fi
  if [ "$_OPT_registry" = 1 ] && [ -n "$_OPT_plan$_OPT_pushed" ]; then
    local s
    _lg_scratch_name
    s=$_LG_SN
    git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
      || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
    reg=$(_lg_registry) || exit "$?"
    _lg_v_registry_into "$reg" "$s.tracked" "$f"
  fi
  _lg_v_finish "$f"
}

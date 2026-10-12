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
# lg_v_model($ix; $c; $gen): every ledger's page model —
#   {id, title, scope, retired, counts: [{sev, n}], open, inflight: [branches],
#    clusters: [{contract, title, items, counts, up: [..], down: [..]}],
#    unclustered: [items], closed: [items], superseded: [items]}
# plus .unplaced (the items on no page: no ledger, or not an id) and
# .inflight (every in-flight branch the items name). Clusters by severity counts
# (severity_order, most severe first) descending, then title, then
# contract; items by lg_v_sort. up/down: the clusters' neighbours in other
# ledgers ({key, via, ledger, display}), de-duplicated — only when the
# index has computed neighbours (Task 9; null until then).
def lg_v_model($ix; $c; $gen):
  lg_q_ranks($c) as $K
  | lg_v_sevs($c) as $sevs
  | lg_v_titles($ix) as $T
  | ($ix.items | sort_by(.path)) as $all
  # Keys → items over the path-sorted list (a duplicate key resolves to its
  # last path, whatever the input order).
  | ([$all[] | {key: ((.key // "") | ascii_downcase), v: .}] | map(select(.key != ""))
     | reduce .[] as $x ({}; .[$x.key] = $x.v)) as $BYKEY
  | lg_v_ledgers($ix) as $LS
  | ($LS | map(.id)) as $pages
  | {ledgers: [$LS[] as $L
      | [$all[] | select(.ledger == $L.id)] as $its
      | [$its[] | select(lg_v_active)] as $act
      | ([$act[] | select(lg_q_cluster != null)] | group_by(lg_q_cluster)
         | map((.[0] | lg_q_cluster) as $k
               | {contract: $k, title: ($T[$k] // null), items: lg_v_sort($K), counts: lg_v_counts($sevs),
                  up: ([.[] | .neighbours | objects | (.upstream // [])[] | objects]
                       | map(. + {item: $BYKEY[(.key // "") | ascii_downcase]})
                       | map(select(.item != null and .item.ledger != $L.id))
                       | map({key: .key, via: (.via // null), ledger: .item.ledger, display: (.item | lg_q_display)})
                       | unique_by([.key, .via])),
                  down: ([.[] | .neighbours | objects | (.downstream // [])[] | objects]
                         | map(. + {item: $BYKEY[(.key // "") | ascii_downcase]})
                         | map(select(.item != null and .item.ledger != $L.id))
                         | map({key: .key, via: (.via // null), ledger: .item.ledger, display: (.item | lg_q_display)})
                         | unique_by([.key, .via]))})
         | sort_by((.counts | map(0 - .n)), (.title // .contract), .contract)) as $clusters
      | $L + {counts: ($act | lg_v_counts($sevs)), open: ($act | length), inflight: ($its | lg_v_inflight),
              clusters: $clusters,
              unclustered: ([$act[] | select(lg_q_cluster == null)] | lg_v_sort($K)),
              closed: ([$its[] | select((lg_v_active | not) and (lg_v_superseded | not) and .class != "wontfix" and lg_v_recent($gen))] | lg_v_sort($K)),
              superseded: ([$its[] | select((lg_v_superseded or .class == "wontfix") and lg_v_recent($gen))] | lg_v_sort($K))}],
     unplaced: [$all[] | select(.ledger as $l | $pages | index([$l]) == null)],
     inflight: ($all | lg_v_inflight)};
# lg_v_header($gen): the generated-from line (no markup).
def lg_v_header($gen):
  "Generated from \($gen.source // "?") + \($gen.inflight // 0) in-flight branches at \($gen.at // "?") by doc-superpowers ledger. Do not edit — edit the item.";
# lg_v_url($gen): the item path as a link target — $gen.link (a prefix,
# already encoded) + each path segment percent-encoded.
def lg_v_url($gen): ($gen.link // "") + (split("/") | map(@uri) | join("/"));
# lg_v_newest: the newest of a list of doc paths (by file name: date-led
# names sort by date), or null.
def lg_v_newest: if length == 0 then null else sort_by(split("/") | last) | last end;
def lg_v_docstem: split("/") | last | if endswith(".md") then .[0:-3] else . end;
# lg_v_resolution: the first line of the item's resolution (design §E.2),
# cut to 200 characters — before any escaping, so a cut never splits one.
def lg_v_resolution: (.resolution // "(no resolution)") | gsub("\r"; "") | split("\n")[0] | lg_q_one | lg_q_cut(200);
# lg_v_pr_url: the PR's url when it is http(s), else null (never a
# javascript: or other scheme in a link).
def lg_v_pr_url: .pr | if type == "object" and (.url | type) == "string" and (.url | test("^https?://")) then .url else null end;
# lg_v_sev($c): the severity as severity_order spells it (case-insensitive
# match), else as written; null when none.
def lg_v_sev($c):
  .severity as $s
  | if ($s | type) != "string" then null
    else first(lg_v_sevs($c)[] | select(ascii_upcase == ($s | ascii_upcase))) // $s end;

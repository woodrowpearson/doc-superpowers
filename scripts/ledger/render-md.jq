include "defs";
# scripts/ledger/render-md.jq — a ledger page (design §E.2) or the views
# README, as markdown. Pure: the output depends only on the index (input),
# the config ($c[0]), $ledger, $mode and $generated — never on the order
# of .items or the clock (the timestamp is $generated.at).
#
#   jq -r -L scripts/ledger --slurpfile c <config> --arg ledger <id> \
#      --arg mode page|readme|files --argjson generated <obj> -f render-md.jq <index>
#
# $generated: {source: "<base>@<sha>" (the header's "Generated from"),
#   inflight: <n branches>, at: "<UTC>", cutoff: "YYYY-MM-DD" (closed items
#   last touched before it drop off), touched: {path: "YYYY-MM-DD"} (the
#   last commit touching each recently touched item), link: "<prefix>"
#   (prepended, already encoded, to every repository path a link names)}.
#
# page: "# <title> (`<id>`)", the header quote, "<scope> · Open: <sev> n …
#   · In flight: n branches", then per cluster "## <title> — `<contract>`
#   (n)" (no title: "## `<contract>` (n)") and its table, then its ↳
#   neighbour lines (only when the index has neighbours), "## Unclustered
#   (n)", "## Recently closed (<recent_days> days)" and "## Superseded /
#   won't fix (<recent_days> days)" ("<key> → <superseded_by>: <first
#   resolution line>"). The model (grouping, counts, order) is defs.jq's
#   lg_v_model, shared with render-html.jq.
# files: the pages as "<name>\u0001<content>\u0001…" (jq -j) — <id>.md for
#   $ledger, or for every ledger and README.md when $ledger is "all".
# readme: one table row per ledger (open counts by severity, in-flight
#   branches), the count of items on no ledger page, then the open items of
#   the first two severities across ledgers.

# gen: $generated — an object (--argjson), or one wrapped in an array
# (--slurpfile, which views.sh uses: the touched map can outgrow an
# argument).
def gen: $generated | if type == "array" then .[0] else . end;
def md: lg_q_one | gsub("\\|"; "\\|") | gsub("<"; "&lt;");
def md_text: md | gsub("\\["; "\\[") | gsub("\\]"; "\\]");
def md_code: lg_q_one | gsub("`"; "'") | "`" + . + "`";
def link($text; $path): "[\($text | md_text)](\($path | lg_v_url(gen)))";
def none: "—";
def doc_cell($list): if ($list | length) == 0 then none
  else link("✓"; $list[0]) + (if ($list | length) > 1 then " +\(($list | length) - 1)" else "" end) end;
def pr_cell: .pr as $p | lg_v_pr_url as $u
  | if ($p | type) == "object" and ($p.number != null) then
      (if $u != null then "[#\($p.number | tostring | md_text)](\($u | lg_q_one | gsub("\\)"; "%29") | gsub(" "; "%20")))"
       else "#\($p.number | tostring | md)" end)
    else none end;
def handoff_cell: (.docs.handoff // []) | lg_v_newest | if . == null then none else link(lg_v_docstem | lg_q_cut(40); .) end;
def header_row: "| Key | Issue | Why it matters | Sev | Spec | Plan | PR | Latest handoff | Status |",
                "|---|---|---|---|---|---|---|---|---|";
def row:
  "| \((.key // none) | md) | \(link(lg_q_stem | lg_q_cut(48); .path)) | \((.summary // none) | md) | \((.severity // none) | md)"
  + " | \(doc_cell(.docs.spec // [])) | \(doc_cell(.docs.plan // [])) | \(pr_cell) | \(handoff_cell) | \(lg_q_display | md) |";
def table($items): header_row, ($items[] | row);
def blank: "";
def counts_text($counts): [$counts[] | "\(.sev | md) \(.n)"] | join(" · ");
def recent_days: ($c[0].views.recent_days // 14) | tostring;

def neighbour_lines($cl):
  ($cl.up | map("↳ Upstream: \(.key | md) (\(.ledger | md))"
                + (if .via != null then " changes \(.via | md_code)" else "" end)
                + " — \(.display | md)")[]),
  ($cl.down | group_by(.via) | map(
     (if .[0].via != null then "↳ Downstream (consumes \(.[0].via | md_code)): " else "↳ Downstream: " end)
     + (map("\(.key | md) (\(.ledger | md))") | join(", ")))[]);

def page($L):
  "# \($L.title | md) (\($L.id | md_code))",
  blank,
  "> \(lg_v_header(gen) | md)",
  blank,
  ([(if $L.scope != "" then ($L.scope | md) else empty end),
    (if $L.retired then "Retired" else empty end),
    "Open: \(counts_text($L.counts))",
    "In flight: \($L.inflight | length) branches"] | join(" · ")),
  ($L.clusters[] as $cl
   | blank,
     "## \(if $cl.title != null then "\($cl.title | md) — " else "" end)\($cl.contract | md_code) (\($cl.items | length))",
     blank,
     table($cl.items),
     (neighbour_lines($cl) | blank, .)),
  blank,
  "## Unclustered (\($L.unclustered | length))",
  blank,
  (if ($L.unclustered | length) == 0 then "None." else table($L.unclustered) end),
  blank,
  "## Recently closed (\(recent_days) days)",
  blank,
  (if ($L.closed | length) == 0 then "None."
   else $L.closed[] | "- \(link(lg_q_id; .path)) — \((.summary // none) | md) · \(lg_q_display | md)" end),
  blank,
  "## Superseded / won't fix (\(recent_days) days)",
  blank,
  (if ($L.superseded | length) == 0 then "None."
   else $L.superseded[]
     | "- \(lg_q_id | md) → \(if lg_v_superseded then (.superseded_by | md) else "won't fix" end): \(lg_v_resolution | md)"
   end);

def readme($M):
  lg_q_ranks($c[0]) as $K
  | (lg_v_sevs($c[0])[0:2]) as $top
  | "# Work ledger",
    blank,
    "> \(lg_v_header(gen) | md)",
    blank,
    "| Ledger | Open | \(lg_v_sevs($c[0]) | map(md) | join(" | ")) | In flight |",
    "|---|---|\(lg_v_sevs($c[0]) | map("---|") | join(""))---|",
    ($M.ledgers[]
     | "| [\(.title | md_text) (\(.id | md_code))](\(.id | @uri).md)\(if .retired then " (retired)" else "" end) | \(.open) | \(.counts | map(.n | tostring) | join(" | ")) | \(.inflight | length) |"),
    (if ($M.unplaced | length) > 0
     then blank, "\($M.unplaced | length) items are on no ledger page (no ledger, or not a ledger id) — `ledger validate --all` lists them."
     else empty end),
    blank,
    (([$M.ledgers[] | .clusters[].items[], .unclustered[]
      | select((.severity | type) == "string" and ((.severity | ascii_upcase) as $s | $top | map(ascii_upcase) | index([$s]) != null))]
     | lg_v_sort($K)) as $roll
    | "## Open \($top | map(md) | join("/")) (\($roll | length))",
      blank,
      (if ($roll | length) == 0 then "None."
       else "| Key | Ledger | Issue | Why it matters | Sev | Status |", "|---|---|---|---|---|---|",
            ($roll[] | "| \((.key // none) | md) | \(.ledger | md) | \(link(lg_q_stem | lg_q_cut(48); .path)) | \((.summary // none) | md) | \(.severity | md) | \(lg_q_display | md) |")
       end));

lg_v_model(.; $c[0]; gen) as $M
| if $mode == "readme" then [readme($M)] | join("\n")
  elif $mode == "files" then
    # name \u0001 content \u0001 … (views.sh splits it): every page
    # $ledger names ("all": every ledger, and README.md). No rendered
    # text holds a control character (md, md_code and lg_v_url drop or
    # encode them), so \u0001 cannot occur inside a page.
    ([$M.ledgers[] | select($ledger == "all" or .id == $ledger) | "\(.id).md\u0001\([page(.)] | join("\n"))\n\u0001"]
     | join(""))
    + (if $ledger == "all" then "README.md\u0001\([readme($M)] | join("\n"))\n\u0001" else "" end)
  else (first($M.ledgers[] | select(.id == $ledger))
        // {id: $ledger, title: $ledger, scope: "", retired: false, counts: [], open: 0, inflight: [],
            clusters: [], unclustered: [], closed: [], superseded: []}) as $L
       | [page($L)] | join("\n")
  end

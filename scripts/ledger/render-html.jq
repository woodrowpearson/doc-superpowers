include "defs";
# scripts/ledger/render-html.jq — every ledger in one self-contained HTML
# document (design §E.3): the cluster layout of render-md.jq (the same
# model, defs.jq lg_v_model), inline CSS (light and dark through
# prefers-color-scheme) and inline JS — no network: no external script,
# stylesheet, font or image. Client-side filters: ledger, severity, status
# class, in flight; a search box over key, summary, file name and H1.
# Pure, like render-md.jq.
#
#   jq -r -L scripts/ledger --slurpfile c <config> --arg ledger <id|all> \
#      --argjson generated <obj> -f render-html.jq <index>
#
# $ledger: the ledger the ledger filter starts on ("all": none). $generated:
# as render-md.jq.

# gen: $generated — an object (--argjson), or one wrapped in an array
# (--slurpfile, which views.sh uses: the touched map can outgrow an
# argument).
def gen: $generated | if type == "array" then .[0] else . end;
def h: tostring | lg_q_one | @html;
def none: "<span class=\"no\">—</span>";
def href($path): $path | lg_v_url(gen) | @html;
def link($text; $path): "<a href=\"\(href($path))\">\($text | h)</a>";
def recent_days: ($c[0].views.recent_days // 14) | tostring;
def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-");

def sev_chip($K):
  if (.severity | type) == "string"
  then "<span class=\"chip sev sev-\(lg_q_rank($K.R; $K.n))\">\(.severity | h)</span>"
  else none end;
def status_chip:
  "<span class=\"chip st st-\((.derived.status // "unknown") | slug)\">\(lg_q_display | h)</span>";
def doc_cell($list):
  if ($list | length) == 0 then none
  else "<a class=\"yes\" href=\"\(href($list[0]))\" title=\"\($list[0] | h)\">✓</a>"
       + (if ($list | length) > 1 then " <span class=\"note\">+\(($list | length) - 1)</span>" else "" end) end;
def pr_cell: .pr as $p | lg_v_pr_url as $u
  | if ($p | type) == "object" and ($p.number != null) then
      (if $u != null then "<a href=\"\($u | h)\">#\($p.number | h)</a>" else "#\($p.number | h)" end)
    else none end;
def handoff_cell: (.docs.handoff // []) | lg_v_newest | if . == null then none else link(lg_v_docstem | lg_q_cut(40); .) end;
# Case kept: the page's script folds both sides (toLowerCase) when it matches.
def search_text: [.key, .summary, lg_q_stem, .h1] | map(strings | lg_q_one) | join(" ");
def row($K):
  "<tr data-ledger=\"\(.ledger | h)\" data-sev=\"\((lg_v_sev($c[0]) // "-") | h)\" data-class=\"\(.class | h)\""
  + " data-inflight=\"\((.inflight // []) | length)\" data-q=\"\(search_text | @html)\">"
  + "<td class=\"key\">\((.key // "—") | h)</td>"
  + "<td>\(link(lg_q_stem | lg_q_cut(48); .path))</td>"
  + "<td>\((.summary // "—") | h)</td>"
  + "<td>\(sev_chip($K))</td>"
  + "<td>\(doc_cell(.docs.spec // []))</td>"
  + "<td>\(doc_cell(.docs.plan // []))</td>"
  + "<td>\(pr_cell)</td>"
  + "<td>\(handoff_cell)</td>"
  + "<td>\(status_chip)"
  + (if lg_v_superseded or .class == "wontfix"
     then "<div class=\"res\">\(lg_v_resolution | h)</div>" else "" end)
  + "</td></tr>";
def table($items; $K):
  if ($items | length) == 0 then "<p class=\"note\">None.</p>"
  else "<div class=\"scroll\"><table><thead><tr><th>Key</th><th>Issue</th><th>Why it matters</th><th>Sev</th><th>Spec</th><th>Plan</th><th>PR</th><th>Latest handoff</th><th>Status</th></tr></thead><tbody>"
       + ([$items[] | row($K)] | join(""))
       + "</tbody></table></div>" end;
def xrefs($cl):
  ($cl.up | map("<p class=\"xref\">↳ <b>Upstream</b>: \(.key | h) (\(.ledger | h))"
                + (if .via != null then " changes <code>\(.via | h)</code>" else "" end)
                + " — \(.display | h)</p>") | join("")),
  ($cl.down | group_by(.via) | map("<p class=\"xref\">↳ <b>Downstream</b>"
     + (if .[0].via != null then " (consumes <code>\(.[0].via | h)</code>)" else "" end)
     + ": \(map("\(.key | h) (\(.ledger | h))") | join(", "))</p>") | join(""));
def counts_text($counts): [$counts[] | "\(.sev | h) \(.n)"] | join(" · ");

def section($L; $K):
  "<section class=\"ledger\" data-ledger=\"\($L.id | h)\">",
  "<h2>\($L.title | h) <code>\($L.id | h)</code>\(if $L.retired then " <span class=\"note\">retired</span>" else "" end)</h2>",
  "<p class=\"meta\">\([(if $L.scope != "" then ($L.scope | h) else empty end), "Open: \(counts_text($L.counts))", "In flight: \($L.inflight | length) branches"] | join(" · "))</p>",
  ($L.clusters[] as $cl
   | "<div class=\"group\"><h3>\(if $cl.title != null then "\($cl.title | h) — " else "" end)<code>\($cl.contract | h)</code> (\($cl.items | length))</h3>"
     + table($cl.items; $K) + ([xrefs($cl)] | join("")) + "</div>"),
  "<div class=\"group\"><h3>Unclustered (\($L.unclustered | length))</h3>\(table($L.unclustered; $K))</div>",
  "<div class=\"group\"><h3>Recently closed (\(recent_days) days)</h3>\(table($L.closed; $K))</div>",
  "<div class=\"group\"><h3>Superseded / won't fix (\(recent_days) days)</h3>\(table($L.superseded; $K))</div>",
  "</section>";

def css: "
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --border: #d0d7de; --head: #f6f8fa;
  --link: #0969da; --code: #afb8c133; --xref: #8250df; --row: #f6f8fa80; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --head: #151b23;
    --link: #4493f8; --code: #656c7633; --xref: #ab7df8; --row: #151b2380; }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--fg);
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif; }
header.top { position: sticky; top: 0; z-index: 1; background: var(--bg); border-bottom: 1px solid var(--border); padding: 12px 16px 8px; }
main { padding: 0 16px 32px; max-width: 1400px; }
h1 { font-size: 20px; margin: 0 0 2px; }
h2 { font-size: 17px; margin: 28px 0 4px; padding-bottom: 4px; border-bottom: 1px solid var(--border); }
h3 { font-size: 14px; margin: 18px 0 6px; }
a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
code { font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: var(--code); padding: 0 4px; border-radius: 4px; }
.meta { color: var(--muted); font-size: 12px; margin: 2px 0 8px; }
.note { color: var(--muted); font-size: 12px; }
.filters { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; font-size: 13px; }
.filters select, .filters input[type=search] { font: inherit; color: var(--fg); background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: 3px 6px; }
.filters input[type=search] { min-width: 16em; flex: 1 1 16em; max-width: 28em; }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; margin: 4px 0 6px; }
th, td { border: 1px solid var(--border); padding: 4px 6px; text-align: left; vertical-align: top; }
th { background: var(--head); font-weight: 600; white-space: nowrap; }
tbody tr:nth-child(even) { background: var(--row); }
td.key { white-space: nowrap; font-weight: 600; }
.chip { display: inline-block; font-size: 11px; padding: 0 7px; border-radius: 10px; border: 1px solid #8886; white-space: nowrap; }
.sev-0 { background: #cf222e26; border-color: #cf222e80; }
.sev-1 { background: #d1242f1a; border-color: #d1242f66; }
.sev-2 { background: #bf870026; border-color: #bf870080; }
.sev-3 { background: #8c959f26; }
.st-not-started { background: #8c959f1a; }
.st-spec-d { background: #0969da1a; border-color: #0969da55; }
.st-planned, .st-merged { background: #1a7f371a; border-color: #1a7f3755; }
.st-on-branch, .st-in-review { background: #8250df22; border-color: #8250df66; }
.st-shipped { background: #1a7f3726; border-color: #1a7f3766; }
.st-closed, .st-superseded, .st-won-t-fix { opacity: .75; }
.yes { color: #1a7f37; font-weight: 600; } .no { opacity: .45; }
.res { font-size: 12px; color: var(--muted); margin-top: 2px; }
.xref { font-size: 12px; margin: 2px 0 6px; padding: 4px 8px; border-left: 3px solid var(--xref); background: #8250df0d; }
";

def js: "
(function () {
  var byId = function (id) { return document.getElementById(id); };
  var rows = Array.prototype.slice.call(document.querySelectorAll('tr[data-ledger]'));
  var groups = Array.prototype.slice.call(document.querySelectorAll('.group'));
  var sections = Array.prototype.slice.call(document.querySelectorAll('section.ledger'));
  var f = { ledger: byId('f-ledger'), sev: byId('f-sev'), cls: byId('f-class'), fly: byId('f-inflight'), q: byId('f-q') };
  function apply() {
    var l = f.ledger.value, s = f.sev.value, c = f.cls.value, fly = f.fly.checked;
    var words = f.q.value.toLowerCase().split(/\\s+/).filter(function (w) { return w !== ''; });
    var filtering = !!(s || c || fly || words.length);
    var shown = 0;
    rows.forEach(function (r) {
      var d = r.dataset, ok = (!l || d.ledger === l) && (!s || d.sev === s) && (!c || d['class'] === c) && (!fly || d.inflight !== '0');
      var text = d.q.toLowerCase();
      for (var i = 0; ok && i < words.length; i++) { if (text.indexOf(words[i]) < 0) { ok = false; } }
      r.hidden = !ok;
      if (ok) { shown++; }
    });
    groups.forEach(function (g) { g.hidden = filtering && !g.querySelector('tr[data-ledger]:not([hidden])'); });
    sections.forEach(function (sec) {
      sec.hidden = (l && sec.dataset.ledger !== l) || (filtering && !sec.querySelector('tr[data-ledger]:not([hidden])'));
    });
    byId('f-count').textContent = shown + ' of ' + rows.length + ' items';
    byId('f-none').hidden = shown !== 0;
  }
  [f.ledger, f.sev, f.cls, f.fly].forEach(function (e) { e.addEventListener('change', apply); });
  f.q.addEventListener('input', apply);
  apply();
}());
";

lg_q_ranks($c[0]) as $K
| lg_v_model(.; $c[0]; gen) as $M
| lg_v_sevs($c[0]) as $sevs
| [ "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<meta name=\"generator\" content=\"doc-superpowers ledger\">",
    "<title>Work ledger</title>",
    "<style>\(css)</style>",
    "</head>",
    "<body>",
    "<header class=\"top\">",
    "<h1>Work ledger</h1>",
    "<p class=\"meta\">\(lg_v_header(gen) | h)\(if ($M.unplaced | length) > 0 then " · \($M.unplaced | length) items are on no ledger page (no ledger, or not a ledger id)" else "" end)</p>",
    "<div class=\"filters\" role=\"search\">",
    "<label>Ledger <select id=\"f-ledger\"><option value=\"\">All</option>"
      + ([$M.ledgers[] | "<option value=\"\(.id | h)\"\(if .id == $ledger then " selected" else "" end)>\(.title | h) (\(.id | h))</option>"] | join(""))
      + "</select></label>",
    "<label>Severity <select id=\"f-sev\"><option value=\"\">All</option>"
      + ([$sevs[] | "<option value=\"\(h)\">\(h)</option>"] | join("")) + "<option value=\"-\">none</option></select></label>",
    "<label>Status <select id=\"f-class\"><option value=\"\">All</option><option value=\"open\">open</option><option value=\"fixed\">fixed</option><option value=\"closed\">closed</option><option value=\"wontfix\">won't fix</option><option value=\"unknown\">unrecognised</option></select></label>",
    "<label><input type=\"checkbox\" id=\"f-inflight\"> In flight</label>",
    "<input type=\"search\" id=\"f-q\" placeholder=\"Search key, summary, file, title\" aria-label=\"Search\">",
    "<span id=\"f-count\" class=\"meta\"></span>",
    "</div>",
    "</header>",
    "<main>",
    ($M.ledgers[] | section(.; $K)),
    "<p id=\"f-none\" class=\"note\" hidden>No items match.</p>",
    "</main>",
    "<script>\(js)</script>",
    "</body>",
    "</html>" ]
| join("\n")

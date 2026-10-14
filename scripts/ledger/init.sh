# shellcheck shell=bash
# scripts/ledger/init.sh — `ledger init` (design §K): bootstrap the ledger of
# a repository that already has docs. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_die, _lg_usage, _lg_emit, _lg_cfg, _lg_registry, _lg_out,
# glob.sh's _LG_AWK_GLOB / _lg_owner_map, parse.sh's _LG_AWK_JS, _LG_BOM,
# _lg_scratch_name, validate.sh's _lg_registry_findings, index.sh's
# _lg_index / _lg_ix_items_km, adapters.sh's _lg_adapter_path / _lg_adapter
# / _lg_remote_cache and doc-tools.sh's _hash_one / _opt_seen.
#
# init runs without docs/ledger/config.json (doc-tools.sh _lg_enter exempts
# it from the inert check): on the default config ({}). One mode per run:
#   --report <file>     (this module) writes <file>, <file>.decisions.tsv and
#                       docs/ledger/ledgers.proposed.json — nothing else
#   --accept <tsv>      applies the decisions (see "--accept" below)
#   --import            hosted items → file items, once (see "--import")
#
# --report, in order:
# 1. Sources. files: the item globs (items.globs, archive_globs), and a
#    suggestion (never added) for each tracked directory holding >= 3 *.md
#    files, item files aside, whose frontmatter has a status: line. github
#    (--sources github, or by default when items.adapter is set): the
#    hosted items come from items.adapter, else
#    doc-superpowers:ledger-items-gh, through the remote cache; for the
#    reference adapter (only), gh must be present and authenticated and
#    `gh repo view --json hasIssuesEnabled` true. A failed
#    check or list: exit 2 when asked for explicitly, else reported and
#    skipped. Hand-written ledgers: tracked *.md files with a table whose
#    header row has a "#" column and in which a cell links to an item file
#    (a match of the item globs; links resolved from the file's directory,
#    "/" from the top level, anchors and queries dropped), plus every file
#    config legacy_ledgers names — tracked or not; each with its legacy id
#    (legacy_ledgers, else the file stem minus a trailing "-ledger") and its
#    rows, keyed by the "#" cell (its ordinal in the file when empty).
# 2. The registry: --registry <file> (ledger-registry/1, else exit 2), else
#    docs/ledger/ledgers.json, else a proposal (docs/ledger/ledgers.proposed
#    .json, jq -S): one ledger per top-level directory holding code — a
#    tracked file not under docs/ and not .md/.markdown/.rst/.txt; dot-dirs
#    left out but the CI dirs — and, when the largest holds more than 40 %
#    of the code files, one per second-level directory of it plus a ledger
#    of its own with residual_paths ["<dir>/**"]. Kind platform for docs,
#    the CI dirs, scripts and test dirs; ids slugged from the directory
#    name ([a-z0-9-], 16 chars; "-2", "-3" on a collision, top-level dirs
#    first); contracts from the contracts adapter whose defined_in all fall
#    in one ledger. Hints (item component/area values, hosted labels,
#    hand-written ledger ids) are listed per ledger whose id or title they
#    slug to. The registry's validate --registry findings join the report.
# 3. Assignment (a registry is needed; else no decisions file): per item,
#    first match — its ledger value, when registered (ledger-field); a row
#    of a hand-written ledger whose legacy id is registered
#    (legacy:<file>#<row>); the plurality owner of its paths
#    (paths:<ledger> <n>/<m>: n of the m non-hub paths; a tie is no
#    suggestion; a hub is a path more than 5 % of the items cite, and at
#    least two); a single registered "ledger:<id>" label (label); else
#    unassigned (none). A decisions file from an earlier run: each filled-in
#    decision carries over by path while it is a registered id or
#    "unassigned" (the others are dropped and named in the report) — but a
#    terminal row whose decision equals its suggestion is the pre-fill, and
#    is recomputed; the old file is kept as <decisions>.bak.
# Writes: each file through a temp file beside it, then mv; the report
# last. The report and decisions paths never resolve (spelling, symbolic
# links) to ledgers.json, config.json, the legacy map, the proposal or the
# --registry file (_lg_init_guard: exit 3).
#
# Cost: one git ls-files, the index (cached), one awk pass over the tracked
# *.md files (item files: their frontmatter only), one owner-map awk; jq
# programs per join, never per item.

_LG_INIT_CI='[".github", ".circleci", ".gitlab", ".buildkite"]'
_LG_INIT_GH_ADAPTER="doc-superpowers:ledger-items-gh"
_LG_INIT_TAB=$'\t'
_LG_INIT_NL=$'\n'
_LG_LEX=""           # _lg_init_lex's result
_LG_CANON=""         # _lg_init_canon's result

# _lg_init_lex <absolute path>: "." and empty segments dropped, ".." applied
# (never above /), into _LG_LEX.
_lg_init_lex() {
  local p="$1/" out="" seg
  while [ -n "$p" ]; do
    seg=${p%%/*}
    p=${p#*/}
    case "$seg" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  _LG_LEX=${out:-/}
}

# _lg_init_canon <path>: the file <path> names, as an absolute path — from
# the top level, ".", ".." and "//" resolved, the symbolic links of its
# existing directories and of the file itself followed — into _LG_CANON.
_lg_init_canon() {
  local p="$1" d b rest l n=0
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while :; do
    _lg_init_lex "$p"
    p=$_LG_LEX
    d=${p%/*}
    b=${p##*/}
    [ -n "$d" ] || d=/
    rest=""
    while [ "$d" != / ] && [ ! -d "$d" ]; do
      rest="/${d##*/}$rest"
      d=${d%/*}
      [ -n "$d" ] || d=/
    done
    d=$(cd -P -- "$d" 2>/dev/null && pwd -P) || d=${p%/*}
    p="${d%/}$rest/$b"
    if [ -z "$rest" ] && [ -L "$p" ] && [ "$n" -lt 16 ]; then
      l=$(readlink -- "$p") || break
      case "$l" in /*) p=$l ;; *) p="${d%/}/$l" ;; esac
      n=$((n + 1))
      continue
    fi
    break
  done
  _LG_CANON=$p
}

# _lg_init_guard <report> <decisions> <proposal> [<registry>]: exit 3 when
# the report or its decisions file is — under any spelling, through any
# symbolic link, and (when both exist) any name of the same file: another
# case on a case-insensitive file system, a hard link — docs/ledger/
# ledgers.json, docs/ledger/config.json, the legacy map (config "legacy";
# docs/ledger/legacy.json), the proposal or the --registry file.
_lg_init_guard() {
  local report="$1" dec="$2" t w c lg
  local targets=()
  lg=$(_lg_cfg '.legacy // "" | strings') || exit "$?"
  targets=(docs/ledger/ledgers.json docs/ledger/config.json docs/ledger/legacy.json "$3")
  [ -z "$lg" ] || targets+=("$lg")
  [ -z "${4:-}" ] || targets+=("$4")
  for w in "$report" "$dec"; do
    _lg_init_canon "$w"
    c=$_LG_CANON
    for t in "${targets[@]}"; do
      _lg_init_canon "$t"
      if [ "$c" = "$_LG_CANON" ]; then
        _lg_usage "--report $report: $w would overwrite $t"
      fi
      # The same file under another spelling the canonical form cannot see:
      # a case-insensitive file system (LEDGERS.json), a hard link.
      if [ -e "$w" ] && [ -e "$t" ] && [ "$w" -ef "$t" ]; then
        _lg_usage "--report $report: $w would overwrite $t (the same file)"
      fi
    done
  done
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_init() {
  local n=0
  _lg_init init
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  [ -z "$_OPT_report" ] || n=$((n + 1))
  [ -z "$_OPT_accept" ] || n=$((n + 1))
  [ "$_OPT_import" != 1 ] || n=$((n + 1))
  [ "$n" -gt 0 ] || _lg_usage "give --report <file>, --accept <decisions.tsv> or --import"
  [ "$n" = 1 ] || _lg_usage "give one of --report <file>, --accept <decisions.tsv>, --import"
  if [ -z "$_OPT_accept" ] && [ "$_OPT_dry_run" = 1 ]; then _lg_usage "--dry-run goes with --accept"; fi
  if [ -z "$_OPT_report" ]; then
    if [ -n "$_OPT_registry" ] || _opt_seen sources; then _lg_usage "--registry and --sources go with --report"; fi
    if [ -n "$_OPT_accept" ]; then _lg_init_accept "$_OPT_accept"; fi
    _lg_init_import
  fi
  _lg_init_report "$_OPT_report"
}

# _lg_init_gh_check <scratch-prefix>: is GitHub a usable source? rc 0, or 1
# with the reason in _LG_INIT_GH_WHY.
_lg_init_gh_check() {
  local s="$1" rc=0
  _LG_INIT_GH_WHY=""
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    _LG_INIT_GH_WHY="offline: DOC_TOOLS_LEDGER_OFFLINE=1"
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    _LG_INIT_GH_WHY="gh (the GitHub CLI) is not installed"
    return 1
  fi
  ( cd "$_LG_ROOT" && gh repo view --json hasIssuesEnabled ) < /dev/null > "$s.ghv" 2> "$s.ghe" || rc=$?
  if [ "$rc" != 0 ]; then
    _LG_INIT_GH_WHY="gh repo view failed (rc $rc): $(head -n 3 "$s.ghe" | tr '\n' ' ' | tr -d '\000-\010\013-\037')"
    return 1
  fi
  case "$(jq -r '.hasIssuesEnabled | tostring' "$s.ghv" 2>/dev/null)" in
    true) return 0 ;;
    false) _LG_INIT_GH_WHY="issues are disabled on the GitHub repository (gh repo view: hasIssuesEnabled false)" ;;
    *) _LG_INIT_GH_WHY="gh repo view printed no hasIssuesEnabled: $(head -c 200 "$s.ghv" | tr -d '\000-\037')" ;;
  esac
  return 1
}

# The awk scan of the tracked *.md files (and the legacy_ledgers files).
# Input lines "<flag>\t<path>" (flag T tracked, L named by legacy_ledgers);
# -v globs: the item globs, one per line. Output: one JSON object per line —
#   {"t":"S","path","dir"}           a non-item file whose frontmatter has a
#                                    status: line
#   {"t":"H","path","k","v"}         an item file's component / area value
#   {"t":"R","file","row","state","bold","text","cells"}
#                                    a data row of a "#"-headed table (row:
#                                    its "#" cell, else "n<ordinal in the
#                                    file>"; state: the cell of the first
#                                    column headed state… or status… — ""
#                                    without one; bold: the row's first
#                                    **…** span, ""; text: the line, trimmed;
#                                    cells: the other cells, in order)
#   {"t":"K","file","row","to","item"}  a link in such a row (to: the path it
#                                    resolves to; item: it is an item file)
#   {"t":"M","file"}                 a legacy_ledgers file that cannot be read
# Item files are read through their frontmatter only.
# shellcheck disable=SC2016  # awk source
_LG_AWK_INIT_SCAN='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function dirof(p,   i, d) {
  d = ""
  while ((i = index(p, "/")) > 0) { d = d substr(p, 1, i); p = substr(p, i + 1) }
  return d
}
function norm(p,   n, a, i, k, out) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k == 0) return ""; k--; continue }
    ST[++k] = a[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") ST[i]
  return out
}
function target(t, base,   c) {
  t = trim(t)
  if (substr(t, 1, 1) == "<") {
    c = index(t, ">"); if (c == 0) return ""
    t = substr(t, 2, c - 2)
  } else sub(/[ \t].*$/, "", t)
  if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return ""
  sub(/#.*$/, "", t); sub(/[?].*$/, "", t)
  if (t == "") return ""
  t = rep(t, "%20", " ")
  if (substr(t, 1, 1) == "/") return norm(substr(t, 2))
  return norm(base t)
}
# cells(line): the cells of a table line into C[1..n]; returns n.
function cells(line,   n, i) {
  line = trim(line)
  line = rep(line, "\\|", ESC)
  if (substr(line, 1, 1) == "|") line = substr(line, 2)
  if (line != "" && substr(line, length(line), 1) == "|") line = substr(line, 1, length(line) - 1)
  n = split(line, C, "|")
  for (i = 1; i <= n; i++) C[i] = trim(rep(C[i], ESC, "|"))
  return n
}
function issep(line) {
  return index(line, "-") > 0 && line ~ /^[ \t]*[|]?[ \t]*:?-+:?[ \t]*([|][ \t]*:?-+:?[ \t]*)*[|]?[ \t]*$/
}
# bold(line): the text of the first **…** span ("" when none).
function bold(line,   i, j) {
  i = index(line, "**"); if (i == 0) return ""
  line = substr(line, i + 2)
  j = index(line, "**"); if (j == 0) return ""
  return trim(substr(line, 1, j - 1))
}
function rowid(c, ord) {
  c = rep(rep(c, "~~", ""), "*", "")
  c = trim(c)
  return (c == "") ? "n" ord : c
}
# A cell value of a frontmatter line "<key>: <value>".
function fmval(line) {
  sub(/^[^:]*:[ \t]*/, "", line)
  return trim(line)
}
function scan(p, flag,   line, n, infm, isitem, fence, prev, intable, hcol, scol, nc, i, j, ord, rid, rest, t, base, st, sc, cl) {
  gx_match(p)
  isitem = (GX_MN > 0)
  base = dirof(p)
  n = 0; infm = 0; fence = ""; prev = ""; intable = 0; ord = 0; st = 0
  while ((r = (getline line < p)) > 0) {
    n++
    sub(/\r$/, "", line)
    if (n == 1 && bom != "" && substr(line, 1, length(bom)) == bom) line = substr(line, length(bom) + 1)
    if (n == 1 && line ~ /^---[ \t]*$/) { infm = 1; continue }
    if (infm) {
      if (line ~ /^(---|[.][.][.])[ \t]*$/ || n > 400) { infm = 0; if (isitem) break; continue }
      if (line ~ /^status[ \t]*:/ && fmval(line) != "") st = 1
      if (isitem && line ~ /^(component|area)[ \t]*:/) {
        k = line; sub(/[ \t]*:.*$/, "", k)
        print "{\"t\":\"H\",\"path\":" js(p) ",\"k\":" js(k) ",\"v\":" js(fmval(line)) "}"
      }
      continue
    }
    if (isitem) break
    if (fence != "") {
      if (index(trim(line), fence) == 1) fence = ""
      continue
    }
    if (line ~ /^[ \t]*(```|~~~)/) {
      fence = substr(trim(line), 1, 3); intable = 0; prev = ""
      continue
    }
    if (intable) {
      if (index(line, "|") == 0 || trim(line) == "") { intable = 0 }
      else {
        nc = cells(line)
        ord++
        rid = rowid(C[hcol], ord)
        sc = (scol > 0 && scol <= nc) ? C[scol] : ""
        cl = ""
        for (i = 1; i <= nc; i++) if (i != hcol && i != scol) cl = cl (cl == "" ? "" : ",") js(C[i])
        print "{\"t\":\"R\",\"file\":" js(p) ",\"row\":" js(rid) ",\"state\":" js(sc) ",\"bold\":" js(bold(line)) ",\"text\":" js(trim(line)) ",\"cells\":[" cl "]}"
        for (i = 1; i <= nc; i++) {
          rest = C[i]
          while ((j = index(rest, "](")) > 0) {
            rest = substr(rest, j + 2)
            j = index(rest, ")")
            if (j == 0) break
            t = target(substr(rest, 1, j - 1), base)
            rest = substr(rest, j + 1)
            if (t == "") continue
            gx_match(t)
            print "{\"t\":\"K\",\"file\":" js(p) ",\"row\":" js(rid) ",\"to\":" js(t) ",\"item\":" (GX_MN > 0 ? "true" : "false") "}"
          }
        }
        continue
      }
    }
    if (prev != "" && index(prev, "|") > 0 && issep(line)) {
      nc = cells(prev); hcol = 0; scol = 0
      for (i = 1; i <= nc; i++) {
        if (hcol == 0 && C[i] == "#") hcol = i
        if (scol == 0 && tolower(C[i]) ~ /^(state|status)/) scol = i
      }
      if (hcol > 0) intable = 1
      prev = ""
      continue
    }
    prev = line
  }
  if (r < 0 && flag == "L") print "{\"t\":\"M\",\"file\":" js(p) "}"
  close(p)
  if (st && !isitem) print "{\"t\":\"S\",\"path\":" js(p) ",\"dir\":" js(substr(base, 1, length(base) - 1)) "}"
}
BEGIN {
  js_init()
  ESC = sprintf("%c", 2)
  while ((getline g < globs) > 0) gx_add(++gk, g)
  close(globs)
}
{
  t = index($0, "\t")
  scan(substr($0, t + 1), substr($0, 1, t - 1))
}
'

# _lg_init_md_scan <scratch-prefix>: the awk scan (_LG_AWK_INIT_SCAN) of the
# tracked *.md files (<prefix>.tracked: git ls-files -z) and the
# legacy_ledgers files, the item globs read from <prefix>.iglobs, into
# <prefix>.scan.
_lg_init_md_scan() {
  local s="$1" rc=0
  _lg_cfg '.legacy_ledgers | if type == "object" then to_entries[] | .value | select(type == "string" and . != "") else empty end' \
    > "$s.legacy" || exit "$?"
  tr '\n\000' '\001\n' < "$s.tracked" | LC_ALL=C awk -v legacy="$s.legacy" '
    BEGIN { SOH = sprintf("%c", 1); while ((getline l < legacy) > 0) if (!(l in L)) { L[l] = 1; O[++n] = l } }
    index($0, SOH) || index($0, "\t") { next }
    /[.]md$/ && !($0 in L) { print "T\t" $0 }
    END { for (i = 1; i <= n; i++) if (!index(O[i], "\t")) print "L\t" O[i] }' > "$s.mdlist" \
    || _lg_die "cannot list the markdown files"
  LC_ALL=C awk -v globs="$s.iglobs" -v bom="$_LG_BOM" "$_LG_AWK_JS$_LG_AWK_GLOB$_LG_AWK_INIT_SCAN" "$s.mdlist" > "$s.scan" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot scan the markdown files (awk rc $rc)"
}

# The shared jq definitions of the init programs.
# shellcheck disable=SC2016  # jq source
_LG_JQ_INIT_DEFS='
def lg_slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | .[0:16] | sub("-+$"; "");
def lg_gesc: gsub("(?<c>[\\\\*?{}])"; "\\\(.c)") | if startswith("!") then "\\" + . else . end;
def lg_np: sub("^\\./"; "") | sub("#.*$"; "") | sub(":[0-9]+(-[0-9]+)?$"; "");
def lg_cited: [(.paths // []) | if type == "array" then .[] else . end | strings | lg_np | select(. != "")] | unique;
def lg_rowkey: if test("^[0-9]+$") then [0, tonumber, .] else [1, 0, .] end;
'

# _lg_init_report <file>: the --report mode (see the header).
# shellcheck disable=SC2154  # _OPT_* are set by _parse_args
_lg_init_report() {
  local report="$1" s dec prop=docs/ledger/ledgers.proposed.json files=1 gh=off ghreq="" ghwhy="" src
  local reg="" regpath="" regsrc="" regsha="" ad cfgad hosted="" ix di rc=0 ok
  _lg_scratch_name
  s=$_LG_SN
  dec="$report.decisions.tsv"
  case "$report" in
    */|.|..) _lg_usage "--report needs a file name (got '$report')" ;;
  esac
  if [ -d "$report" ]; then _lg_die "--report $report is a directory"; fi

  # --- Sources -----------------------------------------------------------------
  cfgad=$(_lg_cfg '.items.adapter // "" | if type == "string" then . else tojson end') || exit "$?"
  if _opt_seen sources; then
    files=0
    case ",$_OPT_sources," in
      *,,*) _lg_usage "--sources: an empty entry in '$_OPT_sources' (give files, github or files,github)" ;;
    esac
    while IFS= read -r src; do
      case "$src" in
        files) files=1 ;;
        github) gh=on; ghreq=explicit ;;
        *) _lg_usage "--sources: unknown source '$src' (give files, github or files,github)" ;;
      esac
    done <<EOS
$(printf '%s\n' "$_OPT_sources" | tr ',' '\n')
EOS
  else
    if [ -n "$cfgad" ]; then gh=on; ghreq=default; fi
  fi

  # The registry (before the network): --registry, ledgers.json, or none.
  if [ -n "$_OPT_registry" ]; then
    regpath=$_OPT_registry
    regsrc=option
    case "$regpath" in
      *"$_LG_INIT_TAB"*|*"$_LG_INIT_NL"*)
        _lg_usage "--registry: a path holding a tab or a newline cannot be named in the decisions file" ;;
    esac
  fi
  _lg_init_guard "$report" "$dec" "$prop" "$regpath"
  if [ -n "$regpath" ]; then
    if [ ! -f "$regpath" ]; then _lg_die "--registry $regpath: no such file"; fi
    if ! _lg_registry_ok "$regpath" schema; then
      _lg_die "--registry $regpath is not a ledger-registry/1 file (one JSON object, \"schema\": \"ledger-registry/1\", a \"ledgers\" list of objects)"
    fi
    reg="$s.reg"
    jq -c '.ledgers = (.ledgers // [])' "$regpath" > "$reg" || _lg_die "jq failed (registry)"
  elif [ -e docs/ledger/ledgers.json ] || [ -L docs/ledger/ledgers.json ]; then
    regpath=docs/ledger/ledgers.json
    regsrc="file"
    reg=$(_lg_registry) || exit "$?"
  fi
  if [ -n "$regpath" ]; then
    _hash_one "$regpath"
    regsha=${_HASH#sha256:}
  fi

  # GitHub: the check, then the hosted list (main shell: its labels).
  ad=""
  if [ "$gh" = on ]; then
    ok=1
    # The gh probe: for the reference adapter (or none, which means it);
    # a custom items.adapter is listed through itself.
    if [ -z "$cfgad" ] || [ "$cfgad" = "$_LG_INIT_GH_ADAPTER" ]; then
      _lg_init_gh_check "$s" || ok=0
    fi
    if [ "$ok" = 1 ]; then
      ad=${cfgad:-$_LG_INIT_GH_ADAPTER}
      jq -c --arg ad "$ad" '.items.adapter = $ad' "$_LG_CFG" > "$s.cfg-gh" || _lg_die "jq failed (config)"
      _LG_CFG="$s.cfg-gh"
      if ! _lg_adapter_path items; then
        ok=0
        _LG_INIT_GH_WHY=$_LG_ADP_ERR
      else
        _lg_ix_items_km "$(_lg_cfg '.keys.remote // "origin"')"
        rc=0
        _lg_remote_cache items "$_LG_IX_KM" _lg_adapter items list || rc=$?
        if [ "$rc" != 0 ] || [ "$_LG_RSTATE" != fresh ]; then
          ok=0
          _LG_INIT_GH_WHY="the items adapter ($ad) failed: ${_LG_RERR:-exit $rc}"
        else
          hosted="$s.hosted"
          tail -n +2 "$_LG_RSNAP" > "$hosted" || _lg_die "cannot read the hosted items"
        fi
      fi
    fi
    if [ "$ok" = 0 ]; then
      if [ "$ghreq" = explicit ]; then _lg_die "GitHub source (--sources github): $_LG_INIT_GH_WHY"; fi
      gh=skipped
      ghwhy=$_LG_INIT_GH_WHY
      ad=""
    fi
  fi
  [ -n "$hosted" ] || { hosted="$s.hosted"; : > "$hosted"; }
  # The run's config: items.adapter only when GitHub is on; no item globs
  # without the files source.
  jq -c --arg ad "$ad" --argjson files "$files" '
    .items.adapter = (if $ad == "" then null else $ad end)
    | if $files == 1 then . else .items.globs = [] | .items.archive_globs = [] end' "$_LG_CFG" > "$s.cfg" \
    || _lg_die "jq failed (config)"
  # The item globs as the config gives them (hand-written ledgers link
  # item files whatever the sources).
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | select(type == "string" and . != "")' > "$s.iglobs"
  _LG_CFG="$s.cfg"

  # --- The tracked files, the index, the markdown scan --------------------------
  git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
    || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
  ix=$(_lg_index) || exit "$?"
  di=$(_lg_doc_index) || exit "$?"

  _lg_init_md_scan "$s"

  # The contracts adapter (a proposal's initial contracts).
  : > "$s.contracts"
  : > "$s.cerr"
  if [ -z "$reg" ]; then
    _lg_adapter contracts list > "$s.contracts" 2> "$s.cerr" || { : > "$s.contracts"; [ -s "$s.cerr" ] || echo "the contracts adapter failed" > "$s.cerr"; }
  fi

  # --- Sources, hand-written ledgers, hints: one join ---------------------------
  # shellcheck disable=SC2016  # jq source
  jq -n -c --slurpfile scan "$s.scan" --slurpfile c "$_LG_CFG" --slurpfile ix "$ix" \
      --slurpfile di "$di" --rawfile hosted "$hosted" --rawfile iglobs "$s.iglobs" \
      --argjson files "$files" --arg gh "$gh" --arg ghreq "$ghreq" --arg ghwhy "$ghwhy" --arg ad "$ad" "$_LG_JQ_INIT_DEFS"'
    ($c[0]) as $c
    | ($hosted | split("\n") | map(select(. != "") | fromjson)) as $H
    | (($c.legacy_ledgers // {}) | if type == "object" then to_entries | map(select(.value | type == "string")) else [] end) as $LL
    | ($LL | reduce .[] as $e ({}; if has($e.value) then . else .[$e.value] = $e.key end)) as $legid
    | ($c.doc_columns // {}) as $dc
    | (def dtypes($k): ($dc[$k] // []) | if type == "array" then . elif type == "object" then (.doc_types // []) else [] end;
       {plan: dtypes("plan"), spec: dtypes("spec")}) as $DT
    | ($di[0].docs // {}) as $docs
    | def kind($p): ($docs[$p].doc_type // null) as $t
        | if $t != null and ($DT.plan | index([$t])) then "plan"
          elif $t != null and ($DT.spec | index([$t])) then "spec"
          elif ($p | test("(^|/)plans?/")) then "plan"
          elif ($p | test("(^|/)(specs?|adrs?|decisions)/")) then "spec"
          else null end;
    ($scan | map(select(.t == "R" or .t == "K" or .t == "M"))) as $T
    | ([$T[] | select(.t == "K" and .item) | .file] | unique) as $withitems
    | ([$LL[].value] | unique) as $legfiles
    | (($withitems + $legfiles) | unique) as $lfiles
    | [ $lfiles[] as $f
        | ([$T[] | select(.file == $f and .t == "R") | .row]) as $rows
        | ([$T[] | select(.file == $f and .t == "K")]) as $links
        | ([$links[] | select(.item) | .row] | unique) as $irows
        | ([$links[] | select(.item | not) | select(kind(.to) == "plan") | .row] | unique) as $prows
        | ([$links[] | select(.item | not) | select(kind(.to) == "spec") | .row] | unique) as $srows
        | {file: $f,
           id: ($legid[$f] // ($f | split("/") | last | sub("\\.md$"; "") | sub("-ledger$"; ""))),
           configured: ($legfiles | index([$f]) != null),
           missing: any($T[]; .t == "M" and .file == $f),
           rows: ($rows | length), items: ($irows | length), plans: ($prows | length), specs: ($srows | length),
           members: ([$links[] | select(.item) | {row, item: .to}] | unique)} ] as $ledgers
    | ($ix[0].items | map(select(has("url") | not)) | length) as $nfile
    | ([$scan[] | select(.t == "S")] | group_by(.dir) | map(select(length >= 3)
        | {dir: .[0].dir, glob: ((if .[0].dir == "" then "" else (.[0].dir | lg_gesc) + "/" end) + "*.md"), files: length})) as $sugg
    | def vals: if startswith("[") then ltrimstr("[") | rtrimstr("]") | split(",") | map(gsub("^\\s+|\\s+$"; "")) else [.] end
        | map(gsub("^[\"\u0027]|[\"\u0027]$"; "")) | map(select(. != ""));
    ( [$scan[] | select(.t == "H") | {k, item: .path} + (.v | vals[] | {v: .})]
      + [$H[] | .ref as $r | (.fields // {}) | to_entries[] | select(.key == "component" or .key == "area")
         | {k: .key, item: $r} + (.value | if type == "array" then .[] else . end | strings | {v: .})]
      + [$H[] | .ref as $r | (.labels // [])[] | select(startswith("sev:") | not) | {k: "label", item: $r, v: ltrimstr("ledger:")}]
      + [$ledgers[] | {k: "hand-written ledger", item: null, v: .id, file}] ) as $hints
    | {sources: {files: {on: ($files == 1), globs: (if $files == 1 then $c.items.globs else [] end),
                         archive_globs: (if $files == 1 then $c.items.archive_globs else [] end),
                         items: (if $files == 1 then $nfile else 0 end), suggested: $sugg},
                 github: {state: $gh, requested: (if $ghreq == "" then null else $ghreq end),
                          reason: (if $ghwhy == "" then null else $ghwhy end),
                          adapter: (if $ad == "" then null else $ad end), items: ($H | length)},
                 ledgers: [$ledgers[] | {file, id, configured, missing, rows, items, plans, specs}]},
       ledgers: $ledgers, hints: $hints}' > "$s.facts" || _lg_die "jq failed (sources)"

  # --- The registry: the one given, or the proposal ------------------------------
  if [ -z "$reg" ]; then
    reg="$s.proposed"
    # shellcheck disable=SC2016  # jq source
    tr '\n\000' '\001\n' < "$s.tracked" | jq -R -s -c --argjson ci "$_LG_INIT_CI" --slurpfile ct "$s.contracts" \
        "$_LG_JQ_INIT_DEFS"'
      (split("\n") | map(select(. != "" and (startswith("docs/") | not)
         and (ascii_downcase | test("\\.(md|markdown|rst|txt)$") | not)))) as $code
      | ($code | length) as $N
      | def platform: . as $d | (["docs", "scripts", "test", "tests", "spec", "__tests__", "e2e"] + $ci) | index([$d]) != null;
      [$code[] | select(contains("/")) | split("/")
       | select(.[0] as $t | ($t | startswith(".") | not) or ($ci | index([$t]) != null))] as $parts
      | ($parts | group_by(.[0]) | map({dir: .[0][0], n: length, subs: ([.[] | select(length > 2) | .[1]] | unique)})) as $tops
      | ($tops | sort_by(-.n, .dir) | first) as $big
      | (if $big != null and $big.n * 100 > 40 * $N and ($big.subs | length) > 0 then $big.dir else null end) as $split
      | ( [$tops[] | {dir, name: .dir, sub: false, residual: (.dir == $split)}]
        + [$tops[] | select(.dir == $split) | .dir as $t | .subs[] | {dir: ($t + "/" + .), name: ., sub: true, residual: false}] ) as $L0
      # Ids: top-level dirs first, then the second-level ones, each in path order.
      | (reduce ($L0 | sort_by((if .sub then 1 else 0 end), .dir))[] as $l
           ({taken: {"unassigned": true, "readme": true}, out: []};
            (($l.name | lg_slug) | if . == "" then "dir" else . end) as $b
            | (. as $st
               | if ($st.taken[$b] | not) then $b
                 else first(range(2; 100000) as $k
                            | (($b[0:(15 - ($k | tostring | length))] | sub("-+$"; "")) + "-\($k)")
                            | select($st.taken[.] | not))
                 end) as $id
            | .taken[$id] = true
            | .out += [$l + {id: $id}])).out | sort_by(.dir) as $L
      | [$L[] | {id, title: .name, kind: (if (.name | platform) then "platform" else "service" end), status: "active",
                 paths: (if .residual then [] else [(.dir | lg_gesc) + "/**"] end),
                 residual_paths: (if .residual then [(.dir | lg_gesc) + "/**"] else [] end), dir, sub}] as $P
      # Contracts: every defined_in glob in one ledger (the deepest dir that
      # prefixes it: a second-level ledger before its residual parent).
      | def owner($g): [$P[] | select(.dir as $d | $g | startswith($d + "/"))] | sort_by(-(.dir | length)) | (first // null) | if . == null then null else .id end;
      ([$ct[] | objects | select((.defined_in | type) == "array" and (.defined_in | length) > 0)
        | {id, defined_in, owners: ([.defined_in[] | owner(.)] | unique)}]) as $C
      | {proposal: {schema: "ledger-registry/1",
                    ledgers: [$P[] | .id as $i | del(.dir, .sub)
                              + {contracts: [$C[] | select(.owners == [$i]) | {id, defined_in}] | unique_by(.id)}]},
         unplaced: [$C[] | select((.owners | length) != 1 or .owners[0] == null) | {id, defined_in}],
         code_files: $N, split: $split}' > "$s.prop" || _lg_die "jq failed (the registry proposal)"
    jq -S '.proposal' "$s.prop" > "$reg" || _lg_die "jq failed (the registry proposal)"
  fi

  # --- Registry findings ------------------------------------------------------------
  _lg_registry_findings "$reg" "$s.tracked" "$s.findings"

  # --- Assignment ----------------------------------------------------------------
  # A decisions file from an earlier run: its filled-in decisions carry over.
  : > "$s.rows"
  : > "$s.prevdec"
  printf '{}\n' > "$s.assign"
  if [ -n "$regpath" ]; then
    if [ -f "$dec" ]; then cp -- "$dec" "$s.prevdec" || _lg_die "cannot read $dec"; fi
    # The paths the items cite (normalised), their owners in one awk.
    # shellcheck disable=SC2016  # jq source
    jq -r "$_LG_JQ_INIT_DEFS"'[.items[] | lg_cited[] | select(contains("\n") | not)] | unique | .[]' "$ix" > "$s.cited" \
      || _lg_die "jq failed (cited paths)"
    tr '\n' '\000' < "$s.cited" > "$s.citedz" || _lg_die "cannot write $s.citedz"
    _lg_owner_map "$s.citedz" "$s.own" "$reg"
    # shellcheck disable=SC2016  # jq source
    jq -n -c --slurpfile ix "$ix" --slurpfile reg "$reg" --slurpfile f "$s.facts" --rawfile own "$s.own" \
        --rawfile hosted "$hosted" --rawfile prev "$s.prevdec" "$_LG_JQ_INIT_DEFS"'
      ([$reg[0].ledgers[] | .id | strings]) as $ids
      | ($ids | map({(.): true}) | add // {}) as $isreg
      | ($own | split("\n") | map(select(. != "") | split("\t") | {key: (.[0:-1] | join("\t") | gsub("\u0001"; "\n")), value: .[-1]}) | from_entries) as $O
      | ($hosted | split("\n") | map(select(. != "") | fromjson | {key: .ref, value: (.labels // [])}) | from_entries) as $LB
      | ($prev | split("\n") | map(sub("\r$"; "") | select(. != "" and (startswith("#") | not)) | split("\t")
         | select(length >= 5 and .[4] != "")
         # A terminal row whose decision is its suggestion is the pre-fill:
         # recomputed, never carried over (the registry may have grown).
         | select(. as $r | ((["fixed", "closed", "wontfix"] | index([$r[1]])) != null and $r[4] == $r[2]) | not)
         | {path: .[0], v: .[4]})) as $PV
      | ($ix[0].items) as $I
      | ($I | length) as $N
      | ([$f[0].ledgers[] | select($isreg[.id]) | .id as $lid | .file as $file | .members[] | {item, file: $file, row, id: $lid}]
         | group_by(.item)
         | map({key: .[0].item, value: (sort_by(.file, (.row | lg_rowkey)) | first | {id, src: "\(.file)#\(.row)"})}) | from_entries) as $MEM
      | ([$I[] | lg_cited[]] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $CITE
      | ($CITE | to_entries | map(select(.value >= 2 and .value * 100 > 5 * $N)) | from_entries) as $HUB
      | ([$I[] | .path] | map({(.): true}) | add // {}) as $isitem
      | ($PV | map(select($isitem[.path] and (.v == "unassigned" or $isreg[.v]))) | map({(.path): .v}) | add // {}) as $KEEP
      | [$PV[] | select($KEEP[.path] == null)
         | . + {why: (if $isitem[.path] | not then "no longer an item" else "not a registered ledger id" end)}] as $DROP
      | [$I[] | . as $it
         | (.class // "unknown") as $cl
         | (lg_cited | map(select($HUB[.] | not))) as $ps
         | ([$ps[] | $O[.] // "-" | select(. != "-" and (startswith("multi:") | not))]
            | group_by(.) | map({l: .[0], n: length}) | sort_by(-.n)) as $votes
         | ([(($LB[$it.path] // [])[] | select(startswith("ledger:")) | ltrimstr("ledger:") | select($isreg[.]))] | unique) as $lab
         | (if (.ledger | type) == "string" and $isreg[.ledger] then {s: .ledger, r: "ledger-field"}
            elif $MEM[.path] then {s: $MEM[.path].id, r: "legacy:\($MEM[.path].src)"}
            elif ($votes | length) > 0 and (($votes | length) == 1 or $votes[0].n > $votes[1].n)
              then {s: $votes[0].l, r: "paths:\($votes[0].l) \($votes[0].n)/\($ps | length)"}
            elif ($lab | length) == 1 then {s: $lab[0], r: "label"}
            else {s: "unassigned", r: "none"} end) as $sg
         | {path, class: $cl, suggestion: $sg.s, reason: $sg.r,
            decision: ($KEEP[.path] // (if ["fixed", "closed", "wontfix"] | index([$cl]) then $sg.s else "" end))}] as $rows
      | {rows: ($rows | sort_by(.path)),
         hubs: ($HUB | to_entries | sort_by(-.value, .key) | map({path: .key, items: .value})),
         kept: ($KEEP | length), dropped: ($DROP | sort_by(.path)), previous: ($prev != ""),
         items: $N}' > "$s.assign" || _lg_die "jq failed (assignment)"
    jq -r '.rows[] | select((.path | test("[\t\n]")) | not) | [.path, .class, .suggestion, .reason, .decision] | join("\t")' \
      "$s.assign" > "$s.rows" || _lg_die "jq failed (decision rows)"
  fi

  _lg_init_write "$report" "$dec" "$prop" "$s" "$reg" "$regpath" "$regsrc" "$regsha" "$ix"
}

# _lg_init_put <src> <target>: <target> becomes a copy of <src> atomically
# (a temp file in <target>'s directory, then mv), with the mode a new file
# gets under the umask (mktemp's 0600 would survive the mv).
_lg_init_put() {
  local tmp mode
  tmp=$(mktemp "$(dirname -- "$2")/.lg-init.XXXXXX") || _lg_die "cannot create a temp file beside $2"
  mode=$(printf '%o' $(( 0666 & ~0$(umask) ))) || mode=644
  if ! cp -- "$1" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$2"; then
    rm -f -- "$tmp"
    _lg_die "cannot write $2"
  fi
}

# _lg_init_write <report> <decisions> <proposed> <scratch> <registry>
# <registry-path> <registry-source> <registry-sha> <index>: render the report
# and the payload, write the files, print, end the run.
_lg_init_write() {
  local report="$1" dec="$2" prop="$3" s="$4" reg="$5" regpath="$6" regsrc="$7" regsha="$8" ix="$9" d
  if [ -n "$regpath" ]; then printf '{}\n' > "$s.prop" || _lg_die "cannot write $s.prop"; fi
  jq -s -c . "$s.findings" > "$s.fd" || _lg_die "jq failed (findings)"
  # One object of facts: the rendering's input and the JSON payload.
  # shellcheck disable=SC2016  # jq source
  jq -n -c --slurpfile f "$s.facts" --slurpfile a "$s.assign" --slurpfile ix "$ix" --slurpfile reg "$reg" \
      --slurpfile pp "$s.prop" --slurpfile fd "$s.fd" --rawfile cerr "$s.cerr" \
      --arg report "$report" --arg dec "$dec" --arg prop "$prop" --arg regpath "$regpath" --arg regsrc "$regsrc" \
      --arg regsha "$regsha" "$_LG_JQ_INIT_DEFS"'
    $f[0] as $F | $a[0] as $A | $reg[0] as $R | $pp[0] as $P
    | ($regpath != "") as $hasreg
    | {report: $report,
       decisions: (if $hasreg then $dec else null end),
       proposed: (if $hasreg then null else $prop end),
       registry: (if $hasreg then {path: $regpath, source: $regsrc, sha256: $regsha} else {path: $prop, source: "proposal", sha256: null} end),
       sources: $F.sources,
       counts: {items: ($ix[0].items | length),
                hosted: ($ix[0].items | map(select(has("url"))) | length),
                ledgers: ($R.ledgers | length),
                findings: ($fd[0] | length),
                by_suggestion: (if $hasreg then ($A.rows | group_by(.suggestion) | map({key: .[0].suggestion, value: length}) | from_entries) else null end),
                by_reason: (if $hasreg then ($A.rows | group_by(.reason | sub("[:].*$"; "")) | map({key: (.[0].reason | sub("[:].*$"; "")), value: length}) | from_entries) else null end),
                by_class: (if $hasreg then ($A.rows | group_by(.class) | map({key: .[0].class, value: length}) | from_entries) else null end),
                kept: (if $hasreg then $A.kept else null end),
                dropped: (if $hasreg then ($A.dropped | length) else null end)},
       previous: ($A.previous // false), dropped: ($A.dropped // []),
       ledgers_reg: [$R.ledgers[] | {id: (.id | tostring), title: (.title // null), kind: (.kind // null),
                                    paths: (.paths // []), residual_paths: (.residual_paths // []),
                                    contracts: [(.contracts // [])[] | objects | .id]}],
       hints: $F.hints, hand: $F.ledgers, findings: $fd[0],
       unplaced: ($P.unplaced // []), contracts_error: ($cerr | sub("\n+$"; "") | if . == "" then null else . end),
       hubs: ($A.hubs // []), unwritten: [($A.rows // [])[] | select(.path | test("[\t\n]")) | .path]}' > "$s.out" \
    || _lg_die "jq failed (the report's facts)"

  # The report (markdown).
  # shellcheck disable=SC2016  # jq source
  jq -r "$_LG_JQ_INIT_DEFS"'
    def code: "`" + . + "`";
    def plural($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
    . as $o
    | "# Ledger init report",
      "",
      "Written by `doc-tools.sh ledger init --report \($o.report)`. It wrote this report"
        + (if $o.decisions then ", " + ($o.decisions | code) else "" end)
        + (if $o.proposed then ", " + ($o.proposed | code) else "" end)
        + " and nothing else.",
      "",
      "## Sources",
      "",
      (if $o.sources.files.on
       then "- Files: on — item globs \($o.sources.files.globs | map(code) | join(", ")); archive globs \($o.sources.files.archive_globs | map(code) | join(", ") | if . == "" then "none" else . end); \(plural($o.sources.files.items; "item"))."
       else "- Files: off (--sources)." end),
      (if ($o.sources.files.suggested | length) == 0 then "- Suggested item globs: none."
       else "- Suggested item globs (not added: add them to items.globs in docs/ledger/config.json to take those files as items):",
            ($o.sources.files.suggested[] | "  - \(.glob | code) — \(plural(.files; "file")) with a status: frontmatter line") end),
      (if $o.sources.github.state == "on" then "- GitHub: on — \(plural($o.sources.github.items; "hosted item")) through \($o.sources.github.adapter | code)."
       elif $o.sources.github.state == "skipped" then "- GitHub: skipped — \($o.sources.github.reason). (Reached through items.adapter; pass --sources github to make this an error.)"
       else "- GitHub: off — not asked for (--sources files,github, or set items.adapter)." end),
      "",
      "## Hand-written ledgers",
      "",
      (if ($o.hand | length) == 0 then "None found (a tracked *.md table with a \"#\" column linking item files, or a file config legacy_ledgers names)."
       else ($o.hand[] | "- \(.file | code) — \(.id | code): \(.rows) rows; \(.items) link items, \(.plans) plans, \(.specs) specs"
                         + (if .configured then " (legacy_ledgers)" else "" end)
                         + (if .missing then " — cannot be read" else "" end)) end),
      "",
      "## Registry",
      "",
      (if $o.registry.source == "proposal"
       then "Proposed: \($o.proposed | code) — \(plural($o.counts.ledgers; "ledger")) (there is no docs/ledger/ledgers.json and no --registry). Edit it, then re-run with --registry \($o.proposed). It is never installed as docs/ledger/ledgers.json by this step."
       else "Used: \($o.registry.path | code) (\(if $o.registry.source == "option" then "--registry" else "docs/ledger/ledgers.json" end); sha256 \($o.registry.sha256)) — \(plural($o.counts.ledgers; "ledger"))." end),
      "",
      "| id | kind | paths | residual_paths | contracts |",
      "|---|---|---|---|---|",
      ($o.ledgers_reg[] | "| \(.id) | \(.kind // "—") | \(.paths | map(code) | join(", ")) | \(.residual_paths | map(code) | join(", ")) | \(.contracts | map(code) | join(", ")) |"),
      "",
      "Hints (they never change the registry):",
      ( ($o.ledgers_reg | map({id, s: [.id, ((.title // "") | lg_slug)]})) as $LS
        | ($o.hints | map(. + {to: ((.v | lg_slug) as $v | [$LS[] | select(.s | index([$v])) | .id] | first // null)})) as $HS
        | def show: group_by([.k, .v]) | map(if .[0].k == "hand-written ledger" then "hand-written ledger \"\(.[0].v)\" (\(.[0].file))"
                                             else "\(.[0].k) \"\(.[0].v)\" (\(plural(map(.item) | unique | length; "item")))" end) | join("; ");
        ($LS[] | .id as $i | [$HS[] | select(.to == $i)] | select(length > 0) | "- \($i | code): " + show),
        ([$HS[] | select(.to == null)] | select(length > 0) | "- other: " + show),
        (if ($HS | length) == 0 then "- none" else empty end)),
      (if ($o.unplaced | length) > 0
       then "", "Contracts left out (their defined_in does not fall in one ledger): " + ($o.unplaced | map("\(.id | code) (\(.defined_in | join(", ")))") | join("; "))
       else empty end),
      (if $o.contracts_error then "", "The contracts adapter failed, so the proposal has no initial contracts: \($o.contracts_error)" else empty end),
      "",
      "## Registry findings",
      "",
      (if ($o.findings | length) == 0 then "None: `ledger validate --registry` finds nothing in \($o.registry.path | code)."
       else "`ledger validate --registry` on \($o.registry.path | code) (\(plural($o.findings | length; "finding"))):", "",
            ($o.findings[] | "- \(.class) \(.detail)") end),
      "",
      "## Assignment summary",
      "",
      (if $o.decisions == null
       then "No assignment yet: it needs a registry. Edit \($o.proposed | code), then re-run `doc-tools.sh ledger init --report \($o.report) --registry \($o.proposed)`."
       else "\(plural($o.counts.items; "item")) (\($o.counts.by_class | to_entries | map("\(.value) \(.key)") | join(", "))) → \($o.decisions | code).",
            "",
            "| suggestion | items |", "|---|---|",
            ($o.counts.by_suggestion | to_entries | sort_by(-.value, .key)[] | "| \(.key) | \(.value) |"),
            "",
            "| reason | items |", "|---|---|",
            ($o.counts.by_reason | to_entries | sort_by(-.value, .key)[] | "| \(.key) | \(.value) |"),
            (if $o.previous then "", "Decisions carried over from the previous \($o.decisions | code) (kept as \($o.decisions + ".bak" | code)): \($o.counts.kept) kept, \($o.counts.dropped) dropped."
                 + (if ($o.dropped | length) > 0
                    then " Dropped: " + ($o.dropped | map("\(.path | code) (\(.v | code): \(.why))") | join("; ")) + "."
                    else "" end)
             else empty end),
            (if ($o.hubs | length) > 0 then "", "Hub files (cited by more than 5 % of the items; skipped by the paths rule): " + ($o.hubs | map("\(.path | code) (\(plural(.items; "item")))") | join(", ")) else empty end),
            (if ($o.unwritten | length) > 0 then "", "Not written (a tab or a newline in the path): " + ($o.unwritten | map(tojson) | join(", ")) else empty end)
       end),
      "",
      "## Next steps",
      "",
      (if $o.decisions == null
       then "1. Edit \($o.proposed | code): ids, titles, kinds, paths, contracts; settle the findings above.",
            "2. `doc-tools.sh ledger init --report \($o.report) --registry \($o.proposed)`"
       else "1. Fill in the decision column of \($o.decisions | code) (a registered ledger id or `unassigned`); empty rows are left alone.",
            "2. `doc-tools.sh ledger init --accept \($o.decisions)`"
       end),
      (if ($o.sources.files.suggested | length) > 0 then "3. To take the suggested globs as items, add them to items.globs in docs/ledger/config.json, then re-run the report." else empty end)
  ' "$s.out" > "$s.report" || _lg_die "jq failed (the report)"

  # The summary line (a failure surfaces, never an empty line).
  jq -r '"ledger init: \(.counts.items) items (\(.counts.hosted) hosted), registry \(.registry.path) (\(.counts.ledgers) ledger\(if .counts.ledgers == 1 then "" else "s" end), \(.counts.findings) finding\(if .counts.findings == 1 then "" else "s" end))"
    + (if .decisions then ", decisions \(.decisions)" else "" end)' "$s.out" > "$s.summary" || _lg_die "jq failed (the summary)"
  # Write — each file through a temp file beside it, then mv: the proposal,
  # the previous decisions file as .bak, the decisions file, the report last.
  d=$(dirname -- "$report")
  mkdir -p -- "$d" 2>/dev/null || _lg_die "cannot create $d"
  if [ -z "$regpath" ]; then
    mkdir -p docs/ledger || _lg_die "cannot create docs/ledger"
    _lg_init_put "$reg" "$prop"
  else
    if [ -s "$s.prevdec" ]; then _lg_init_put "$s.prevdec" "$dec.bak"; fi
    { printf '# ledger init decisions\n# registry: %s %s\n# path\tclass\tsuggestion\treason\tdecision\n' "$regpath" "$regsha" \
        && LC_ALL=C sort "$s.rows"; } > "$s.dec" || _lg_die "cannot write $s.dec"
    _lg_init_put "$s.dec" "$dec"
  fi
  _lg_init_put "$s.report" "$report"

  if [ "$_LG_FORMAT" = json ]; then
    jq -c '{report, decisions, proposed, registry, sources, counts}' "$s.out" > "$s.payload" || _lg_die "jq failed (payload)"
    _lg_emit init 0 "$s.payload"
  fi
  _lg_out "wrote $report"
  if [ -z "$regpath" ]; then
    _lg_out "wrote $prop"
  else
    if [ -s "$s.prevdec" ]; then _lg_out "wrote $dec.bak"; fi
    _lg_out "wrote $dec"
  fi
  _lg_out_file "$s.summary"
  _lg_emit init 0
}

# --- --accept ----------------------------------------------------------------------
#
# ledger init --accept <decisions.tsv> [--dry-run] (design §K steps 3-7;
# Task 15 rulings R1-R5). In order:
# 1. Validate, writing nothing. The registry: docs/ledger/ledgers.json when
#    it exists; else the file the header's "# registry: <path> <sha256>"
#    line names (split on its last space), whose sha256 must match ("registry
#    changed since the report": exit 2) — it is installed as ledgers.json.
#    No such line and no ledgers.json: exit 2. Every row with a decision
#    (an empty one is skipped) is checked: five tab-separated columns, the
#    path listed once, the decision a registered (not retired) ledger id or
#    "unassigned", the path an item now, and its key compatible — an
#    unassigned item carries no key, a terminal one none of another ledger,
#    a provisional key of another ledger and a hosted item keyed in another
#    ledger need `ledger assign`. Any failure: exit 1, one finding per row,
#    nothing written. --dry-run stops after printing the plan.
# 2. Writes, each file atomically (_lg_init_put, or fm-write.awk through
#    _replace_file): config.json when absent ({} — plus items.adapter, the
#    reference GitHub adapter, when a decided row is hosted; jq -S);
#    ledgers.json when absent; the keys — ONE _lg_alloc_batch for every
#    open item decided into a registered ledger without a key there and
#    every stub in a registered ledger, numbered per ledger in item-date
#    order (index date; a stub: today; ties by path), offline or keys.mode
#    merge: provisional keys (_lg_alloc_batch's own rules); a key in another
#    ledger is re-homed, the old one appended to aliases; the item fields
#    (files: key, ledger, summary when missing, aliases — one fm-write.awk
#    pass per file; hosted: through the items adapter's write — ledger as a
#    label, key and summary in the metadata block); the stubs; legacy.json;
#    then the views (ledger view all, into $_LG_CACHE/views).
#    Deviation from R1's order (legacy.json third): legacy.json is written
#    after the keys and the stubs, whose keys and hosted refs its entries
#    carry; a run cut short anywhere converges on a re-run.
# Hand-written ledgers (step 4 of §K): every row of every hand-written
# ledger (as --report finds them) gets a legacy.json entry
# "<legacy-id>#<row>": a row linking an item → {"key"} (its key after this
# run) or {"item": <path>} (none); else a done row (its state cell, ~~
# dropped, starts with done/shipped/resolved/closed/superseded/dropped,
# any case) → {"archived": "<file>#<row>"}; else a stub item —
# docs/issues/<today>-<slug>.md (status Open, the row's legacy id as its
# ledger when registered, else unassigned; summary from the row; body
# "Migrated from <file> row <n>." and the row) or, with items.globs [] and
# an items adapter, an issue (adapter create). A stub is found again by its
# first paragraph ("Migrated from <file> row <n>.") or by the row's
# legacy.json entry, never created twice. legacy.json's entries are never
# changed: an entry that resolves elsewhere than the computed one is a
# finding (rc 1), kept.
# Summaries (written only when missing): the item's legacy row's first
# **bold** span, else its H1, else the first sentence of its first
# paragraph — whitespace collapsed, at most 140 characters, cut at a word
# boundary.
# Idempotent: a second run of the same file changes nothing (no write, no
# counter commit).

# The plan (phase 1): decisions, index, scan, registry, legacy map → findings,
# the rows to apply, the legacy rows. jq source.
# shellcheck disable=SC2016  # jq source
_LG_JQ_ACCEPT_DEFS='
def lg_t140:
  gsub("[\\s]+"; " ") | sub("^ +"; "") | sub(" +$"; "")
  | if length <= 140 then . else .[0:141] | (if test(" ") then sub(" [^ ]*$"; "") else .[0:140] end) | sub(" +$"; "") end;
def lg_sent: (capture("^(?<s>.*?[.!?])(\\s|$)") // null) as $m | if $m == null then . else $m.s end;
def lg_unlink: gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)") | gsub("\\*\\*|~~"; "") | lg_t140;
def lg_stubslug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | .[0:50] | sub("-+$"; "") | if . == "" then "item" else . end;
def lg_done: gsub("~~"; "") | sub("^\\s+"; "") | ascii_downcase | test("^(done|shipped|resolved|closed|superseded|dropped)");
def lg_str: if type == "string" and . != "" then . else null end;
'

# shellcheck disable=SC2016  # jq source
_LG_JQ_ACCEPT_PLAN='
($c[0]) as $c
| ($ix[0].items) as $I
| (reduce $I[] as $i ({}; .[$i.path] = $i)) as $IT
| ([$reg[0].ledgers[] | select((.id | type) == "string")]
   | reduce .[] as $l ({}; .[$l.id] = ($l.status | if type == "string" then . else "active" end))) as $RS
| ($lgy[0] | if type == "object" then . else {} end) as $E
| (($c.legacy_ledgers // {}) | if type == "object" then to_entries | map(select(.value | type == "string")) else [] end) as $LL
| ($LL | reduce .[] as $e ({}; if has($e.value) then . else .[$e.value] = $e.key end)) as $legid
| ([$scan[] | select(.t == "R")]) as $R
| ([$scan[] | select(.t == "K")]) as $K
| (([$K[] | select(.item) | .file] + [$LL[].value]) | unique) as $lfiles
| def lid($f): $legid[$f] // ($f | split("/") | last | sub("\\.md$"; "") | sub("-ledger$"; ""));
  def reg($l): $RS[$l] != null and $RS[$l] != "retired" and ($l | test("^[a-z0-9-]{1,16}$"));
# The hand-written rows (the first of a repeated row id).
[ $lfiles[] as $f
  | [$R[] | select(.file == $f)]
  | reduce .[] as $r ({seen: {}, out: []}; if .seen[$r.row] then . else .seen[$r.row] = true | .out += [$r] end) | .out[]
  | . as $r
  | ([$K[] | select(.file == $f and .row == $r.row and .item and ($IT[.to] != null)) | .to] | first) as $it
  | {file: $f, row: $r.row, lid: lid($f), id: "\(lid($f))#\($r.row)", bold: ($r.bold // ""), text: ($r.text // ""),
     cells: ($r.cells // []), item: $it, done: (($r.state // "") | lg_done)} ] as $LR
# An item legacy row bold lead: its first linking row (file, row order) with one.
| (reduce ($LR | map(select(.item != null and .bold != "")) | sort_by(.file, (.row | lg_rowkey)))[] as $x
     ({}; if has($x.item) then . else .[$x.item] = $x.bold end)) as $BOLD
| (reduce ($I[] | select((.first_para | type) == "string" and (.first_para | startswith("Migrated from ")))) as $i
     ({}; .[$i.first_para] = $i.path)) as $MIG
| [ $LR[]
    | ("Migrated from \(.file) row \(.row).") as $mig
    | if .item != null then {id, kind: "item", path: .item}
      elif .done then {id, kind: "archived", archived: "\(.file)#\(.row)"}
      elif $MIG[$mig] != null then {id, kind: "item", path: $MIG[$mig]}
      elif $E[.id] != null then {id, kind: "kept"}
      else {id, kind: "stub",
            stub: {file, row, id,
                   ledger: (if reg(.lid) then .lid else "unassigned" end),
                   summary: ((if .bold != "" then (.bold | lg_unlink) else ([.cells[] | lg_unlink | select(. != "")] | join(" — ") | lg_t140) end)
                             | if . == "" then ("Migrated from \(.file) row \(.row)" | lg_t140) else . end),
                   text: (.text | gsub("[\u0000-\u0008\u000b-\u001f]"; "")), hosted: $hstub}}
        | .stub.slug = (.stub.summary | lg_stubslug)
      end ] as $LEG
# The decision rows.
| ($d[0].rows) as $D
| ([$D[] | select((.bad // false) | not) | select(.decision == "")] | length) as $skipped
| (reduce ($D[] | select((.bad // false) or .decision != "")) as $r ({seen: {}, out: []};
     .out += [$r + {dup: .seen[$r.path]}] | (if $r.bad then . else .seen[$r.path] = $r.line end))).out as $DD
| [ $DD[]
    | . as $r
    | $IT[$r.path] as $it
    | (($it.class // "unknown")) as $cl
    | ($it.key | lg_str) as $ok
    | ($ok | lg_k_split) as $ks
    | ($ok | lg_k_prov) as $kp
    | (if $ks != null then $ks.l elif $kp != null then ($kp | sub("-~[0-9a-f]{4}$"; "")) else null end) as $kl
    | ($it.url != null and $it.url != false) as $hosted
    | if $r.bad then {f: "not five tab-separated columns (path, class, suggestion, reason, decision)"}
      elif $r.dup != null then {f: "listed again (first on line \($r.dup))"}
      elif $r.decision != "unassigned" and $RS[$r.decision] == null then {f: "decision \($r.decision | tojson) is not a registered ledger id or unassigned"}
      elif $RS[$r.decision] == "retired" then {f: "ledger \($r.decision | tojson) is retired: it accepts no items"}
      elif $r.decision != "unassigned" and ($r.decision | test("^[a-z0-9-]{1,16}$") | not) then {f: "\($r.decision | tojson) is registered but is not a ledger id (^[a-z0-9-]{1,16}$; validate --registry)"}
      elif $it == null then {f: ("no longer an item" + (if ($r.path | test("^[a-z][a-z0-9_-]*#")) then " (a hosted item needs config items.adapter)" else "" end))}
      elif $r.decision == "unassigned" and $ok != null then {f: "carries the key \($ok): unassigned carries none (ledger assign moves an item)"}
      elif $cl != "open" and $ok != null and $kl != $r.decision then {f: "carries the key \($ok) of ledger \($kl), not \($r.decision) (ledger assign moves an item)"}
      elif $cl == "open" and $kp != null and $kl != $r.decision then {f: "carries the provisional key \($ok) of ledger \($kl) (ledger assign moves it)"}
      elif $cl == "open" and $hosted and $ks != null and $kl != $r.decision then {f: "a hosted item keyed \($ok) cannot be re-homed here (ledger assign)"}
      else
        ($r.decision != "unassigned" and $cl == "open" and $kl != $r.decision) as $need
        | {a: {path: $r.path, hosted: $hosted, class: $cl, decision: $r.decision,
               date: ($it.date | if type == "string" and . != "" then . else "9999-12-31" end),
               key: $ok, need_key: $need, previous: (if $need and $ks != null then $ok else null end),
               set_ledger: (($it.ledger | if type == "string" then . else null end) != $r.decision),
               aliases: ($it.aliases // []),
               summary: (if ($it.summary | lg_str) != null then null
                         else (($BOLD[$r.path] | lg_str) // ($it.h1 | lg_str) // ($it.first_para | lg_str | if . == null then null else lg_sent end))
                              | if . == null then null else (lg_unlink | lg_str) end end)}}
      end
    | if .f then {finding: {line: $r.line, path: $r.path, decision: ($r.decision // null), detail: .f}} else . end ] as $X
| {findings: [$X[] | .finding | select(. != null)],
   apply: [$X[] | .a | select(. != null)],
   skipped: $skipped, legacy: $LEG}
'

# The final pass (phase 3): with the keys → the edits, the stubs, the legacy
# entries. jq source.
# shellcheck disable=SC2016  # jq source
_LG_JQ_ACCEPT_FINAL='
($c[0]) as $c | $plan[0] as $P | $km[0] as $KM | $sp[0] as $SP
| ($lgy[0] | if type == "object" then . else {} end) as $E
| lg_fields($c) as $F
| (reduce $recs[] as $r ({}; .[$r.path] = ($r.fm // {}))) as $FM
| def nm($fm; $l): (($F[$l] // []) as $cs | first($cs[] | select(. as $n | $fm | has($n))) // $cs[0] // $l);
  def first_nm($l): (($F[$l] // [])[0] // $l);
# The final key per path (new, else the one kept); every key now, by path.
  (reduce $P.apply[] as $a ({}; .[$a.path] = ($KM[$a.path] // $a.key))) as $FK
| (reduce ($ix[0].items[] | select((.key | type) == "string" and .key != "")) as $i ({}; .[$i.path] = $i.key)) as $IK
# Every key and alias after the run → its item.
| (reduce ($ix[0].items[] | . as $i | ((.key // empty), ((.aliases // [])[])) | strings | {k: ascii_downcase, p: $i.path}) as $x ({}; .[$x.k] = $x.p)
   | reduce $P.apply[] as $a (.; if $KM[$a.path] then .[$KM[$a.path] | ascii_downcase] = $a.path else . end)) as $KEYS
| def tgt($e): if ($e | type) != "object" then null
               elif ($e.key | type) == "string" then ($KEYS[$e.key | ascii_downcase] // ("key:" + $e.key))
               elif ($e.item | type) == "string" then $e.item
               elif ($e.archived | type) == "string" then ("archived:" + $e.archived)
               else null end;
  def entry($p): ($FK[$p] // $KM[$p] // $IK[$p] // null) as $k | if $k != null then {key: $k} else {item: $p} end;
# The legacy rows: their stub paths, entries.
  [ $P.legacy[]
    | if .kind == "stub" then .stub.path = ($SP[.id] // null) else . end
    | if .kind == "item" then . + {entry: entry(.path)}
      elif .kind == "archived" then . + {entry: {archived}}
      elif .kind == "stub" and (.stub.hosted | not) then . + {entry: entry(.stub.path)}
      else . end ] as $L
| [ $L[] | select(.entry != null) | . as $x
    | if $E[$x.id] == null then {new: {key: $x.id, value: $x.entry}}
      elif $E[$x.id] == $x.entry or (tgt($E[$x.id]) != null and tgt($E[$x.id]) == tgt($x.entry)) then empty
      else {finding: {id: $x.id, existing: $E[$x.id], computed: $x.entry,
                      detail: "legacy.json \($x.id): \($E[$x.id] | tojson) differs from \($x.entry | tojson) — kept"}} end ] as $LX
| {legacy_new: ([$LX[] | .new | select(. != null)] | from_entries),
   legacy_findings: [$LX[] | .finding | select(. != null)],
   stubs: [$L[] | select(.kind == "stub") | .stub
           | . + {key: ($KM[if .hosted then "\(.file)#\(.row)" else .path end] // null),
                  names: {status: first_nm("status"), key: first_nm("key"), ledger: first_nm("ledger"), summary: first_nm("summary")}}],
   items: [$P.apply[] | . as $a | ($FM[$a.path] // {}) as $fm
           | {path, hosted, key: ($KM[$a.path] // null), previous, ledger: (if .set_ledger then .decision else null end), summary,
              names: {key: nm($fm; "key"), ledger: nm($fm; "ledger"), summary: nm($fm; "summary"), aliases: nm($fm; "aliases")}}
           | select(.key != null or .ledger != null or .summary != null)],
   keys: [$P.apply[] | select($KM[.path] != null) | {path, ledger: .decision, key: $KM[.path], previous}]}
'

# _lg_init_accept <decisions.tsv>: the --accept mode (see above).
# shellcheck disable=SC2154  # _OPT_* are set by _parse_args
_lg_init_accept() {
  local tsv="$1" dry=0 s hdr hp="" hsha="" reg install=0 cfgpath=docs/ledger/config.json host lgpath ix today
  local hstub=false nhosted want id slug hosted p base n taken nl
  [ "$_OPT_dry_run" != 1 ] || dry=1
  _lg_scratch_name
  s=$_LG_SN
  [ -f "$tsv" ] || _lg_die "--accept $tsv: no such file"
  today=$(date +%Y-%m-%d) || _lg_die "date failed"

  # The decisions file: the registry line, the rows.
  # shellcheck disable=SC2016  # jq source
  jq -R -s -c '
    split("\n") | map(sub("\r$"; ""))
    | {reg: (first(.[] | select(startswith("# registry: ")) | ltrimstr("# registry: ")) // null),
       rows: [to_entries[] | select(.value != "" and (.value | startswith("#") | not))
              | (.value | split("\t")) as $f
              | if ($f | length) == 5
                then {line: (.key + 1), path: $f[0], class: $f[1], suggestion: $f[2], reason: $f[3],
                      decision: ($f[4] | gsub("^\\s+|\\s+$"; ""))}
                else {line: (.key + 1), path: $f[0], bad: true, decision: null} end]}' "$tsv" > "$s.dec" \
    || _lg_die "cannot read $tsv"
  hdr=$(jq -r '.reg // ""' "$s.dec") || _lg_die "jq failed (the registry line)"
  if [ -n "$hdr" ]; then
    case "$hdr" in
      *" "*) hp=${hdr% *}; hsha=${hdr##* } ;;
      *) _lg_die "$tsv: the line '# registry: $hdr' does not end in a sha256" ;;
    esac
  fi

  # The registry (R1): ledgers.json, else the report's (sha256 checked).
  if [ -e docs/ledger/ledgers.json ] || [ -L docs/ledger/ledgers.json ]; then
    reg=$(_lg_registry) || exit "$?"
  else
    [ -n "$hp" ] || _lg_die "$tsv has no '# registry: <path> <sha256>' line and there is no docs/ledger/ledgers.json: re-run \`init --report\`"
    [ -f "$hp" ] || _lg_die "the report's registry $hp is gone: registry changed since the report; re-run \`init --report\`"
    _hash_one "$hp"
    [ "${_HASH#sha256:}" = "$hsha" ] || _lg_die "registry changed since the report; re-run \`init --report\` ($hp: sha256 ${_HASH#sha256:}, the report's $hsha)"
    _lg_registry_ok "$hp" schema || _lg_die "the report's registry $hp is not a ledger-registry/1 file"
    reg="$s.reg"
    jq -c '.ledgers = (.ledgers // [])' "$hp" > "$reg" || _lg_die "jq failed (registry)"
    install=1
  fi

  # The run's config: config.json, else {} — plus the reference GitHub
  # adapter when a decided row is hosted (R2).
  nhosted=$(jq '[.rows[] | select((.bad // false) | not) | select(.decision != "" and (.path | test("^[a-z][a-z0-9_-]*#[^/]+$")))] | length' "$s.dec") \
    || _lg_die "jq failed (hosted rows)"
  host="$s.host"
  if [ -e "$cfgpath" ] || [ -L "$cfgpath" ]; then
    cat -- "$cfgpath" > "$host" 2>/dev/null || _lg_die "cannot read $cfgpath"
  else
    if [ "$nhosted" -gt 0 ]; then
      jq -n --arg ad "$_LG_INIT_GH_ADAPTER" '{items: {adapter: $ad}}' > "$host" || _lg_die "jq failed (config)"
    else
      printf '{}\n' > "$host" || _lg_die "cannot write $host"
    fi
  fi
  _lg_cfg_merge "$host" "$s.cfg" "the run's config"
  [ "$nhosted" = 0 ] || _LG_IX_NEED_ITEMS=1
  if [ "$(_lg_cfg '((.items.globs // null) == []) and ((.items.adapter // "") | type == "string" and . != "")')" = true ]; then hstub=true; fi

  # The index, the hand-written ledgers, the legacy map.
  ix=$(_lg_index) || exit "$?"
  git ls-files -z --cached > "$s.tracked" 2> "$s.err" || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | select(type == "string" and . != "")' > "$s.iglobs"
  _lg_init_md_scan "$s"
  lgpath=$(_lg_cfg '.legacy // "" | strings') || exit "$?"
  if [ -n "$lgpath" ] && { [ -e "$lgpath" ] || [ -L "$lgpath" ]; }; then
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$lgpath" > /dev/null 2>&1 \
      || _lg_die "$lgpath is not one JSON object"
    cp -- "$lgpath" "$s.lgy" || _lg_die "cannot read $lgpath"
  else
    printf '{}\n' > "$s.lgy" || _lg_die "cannot write $s.lgy"
  fi

  # Phase 1: validate and plan.
  jq -L "$_LG_LIB" -n -c --slurpfile c "$_LG_CFG" --slurpfile ix "$ix" --slurpfile reg "$reg" --slurpfile d "$s.dec" \
      --slurpfile scan "$s.scan" --slurpfile lgy "$s.lgy" --argjson hstub "$hstub" \
      "$_LG_JQ_INIT_DEFS$_LG_JQ_KEYS_DEFS$_LG_JQ_ACCEPT_DEFS$_LG_JQ_ACCEPT_PLAN" > "$s.plan" \
    || _lg_die "jq failed (the --accept plan)"
  if [ "$(jq '.findings | length' "$s.plan")" != 0 ]; then
    jq -r '.findings[] | "finding: \(.path) (line \(.line)): \(.detail)"' "$s.plan" | tr -d '\000-\010\013-\037' > "$s.lines" \
      || _lg_die "jq failed (findings)"
    printf 'ledger init --accept: %s finding(s) in %s — nothing was written\n' "$(jq '.findings | length' "$s.plan")" "$tsv" >> "$s.lines"
    if [ "$_LG_FORMAT" = json ]; then
      jq -c --arg d "$tsv" --argjson dry "$([ "$dry" = 1 ] && echo true || echo false)" \
        '{decisions: $d, dry_run: $dry, findings: .findings, written: []}' "$s.plan" > "$s.payload" || _lg_die "jq failed (payload)"
      _lg_emit init 1 "$s.payload"
    fi
    _lg_out_file "$s.lines"
    _lg_emit init 1
  fi
  if [ "$hstub" = true ] || [ "$nhosted" -gt 0 ]; then
    if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ] && [ "$dry" = 0 ] \
        && [ "$(jq '[.apply[] | select(.hosted)] + [.legacy[] | select(.kind == "stub" and .stub.hosted)] | length' "$s.plan")" != 0 ]; then
      _lg_die "offline (DOC_TOOLS_LEDGER_OFFLINE=1): hosted items cannot be written — nothing was written"
    fi
  fi

  # Phase 2: the stubs' paths (a collision takes -2, -3, …), the keys.
  : > "$s.stubp"
  taken=$'\n'
  nl=$'\n'
  jq -r '.legacy[] | select(.kind == "stub") | [.id, .stub.slug, (.stub.hosted | tostring)] | @tsv' "$s.plan" > "$s.stubs" \
    || _lg_die "jq failed (stubs)"
  while IFS=$'\t' read -r id slug hosted; do
    [ "$hosted" = false ] || continue
    base="docs/issues/$today-$slug"
    p="$base.md"
    n=2
    while [ -e "$p" ] || [ -L "$p" ] || case "$taken" in *"$nl$p$nl"*) true ;; *) false ;; esac; do
      p="$base-$n.md"
      n=$((n + 1))
    done
    taken="$taken$p$nl"
    printf '%s\t%s\n' "$id" "$p" >> "$s.stubp"
  done < "$s.stubs"
  jq -R -n -c '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' "$s.stubp" > "$s.stubp.json" \
    || _lg_die "jq failed (stub paths)"
  # shellcheck disable=SC2016  # jq source
  jq -r --slurpfile sp "$s.stubp.json" --arg today "$today" '
    ([.apply[] | select(.need_key) | {l: .decision, p: .path, d: .date}]
     + [.legacy[] | select(.kind == "stub" and .stub.ledger != "unassigned") | .stub
        | {l: .ledger, p: (if .hosted then "\(.file)#\(.row)" else $sp[0][.id] end), d: $today}])
    | sort_by(.l, .d, .p)[] | "\(.l)\t\(.p)"' "$s.plan" > "$s.kp" || _lg_die "jq failed (the keys to allocate)"
  want=$(jq -R -n -c '[inputs | split("\t") | .[0]] | group_by(.) | map({key: .[0], value: length}) | from_entries' "$s.kp") \
    || _lg_die "jq failed (the keys to allocate)"
  if [ "$want" = "{}" ]; then
    : > "$s.kk"
  elif [ "$dry" = 1 ]; then
    awk -F '\t' '{ print $1 "\t" $1 "-(new)" }' "$s.kp" > "$s.kk" || _lg_die "cannot write $s.kk"
  fi
  # Writes begin: config.json, ledgers.json, then the keys (one counter
  # commit).
  if [ "$dry" = 0 ]; then
    mkdir -p docs/ledger || _lg_die "cannot create docs/ledger"
    if [ ! -e "$cfgpath" ] && [ ! -L "$cfgpath" ]; then
      jq -S . "$host" > "$s.cfgout" || _lg_die "jq failed (config.json)"
      _lg_init_put "$s.cfgout" "$cfgpath"
      printf 'wrote %s\n' "$cfgpath" >> "$s.written"
    fi
    if [ "$install" = 1 ]; then
      _lg_init_put "$hp" docs/ledger/ledgers.json
      printf 'wrote docs/ledger/ledgers.json (the report'"'"'s registry, %s)\n' "$hp" >> "$s.written"
    fi
    if [ "$want" != "{}" ]; then
      _lg_alloc_batch "$want" "$s.kp" > "$s.kk" || exit "$?"
    fi
  fi
  jq -R -n -c --rawfile kk "$s.kk" '
    [inputs | split("\t")[1]] as $p | ($kk | split("\n") | map(select(. != "") | split("\t")[1])) as $k
    | [range(0; $p | length) | {key: $p[.], value: $k[.]}] | from_entries' "$s.kp" > "$s.km" \
    || _lg_die "jq failed (the keys)"

  # Phase 3: the edits. Field names from the files as they are.
  jq -r '.apply[] | select(.hosted | not) | .path' "$s.plan" | tr '\n' '\000' > "$s.fpaths" || _lg_die "jq failed (paths)"
  : > "$s.recs"
  if [ -s "$s.fpaths" ]; then _lg_parse_worktree "$s.fpaths" "$s.recs"; fi
  jq -L "$_LG_LIB" -n -c --slurpfile c "$_LG_CFG" --slurpfile plan "$s.plan" --slurpfile km "$s.km" \
      --slurpfile sp "$s.stubp.json" --slurpfile lgy "$s.lgy" --slurpfile ix "$ix" --slurpfile recs "$s.recs" \
      "$_LG_JQ_INDEX_DEFS$_LG_JQ_ACCEPT_FINAL" > "$s.final" || _lg_die "jq failed (the --accept edits)"

  _lg_init_accept_apply "$s" "$dry" "$lgpath" "$tsv"
}

# _lg_init_accept_apply <scratch> <dry 0|1> <legacy-path> <tsv>: the item
# writes, the stubs, legacy.json, the views, the output.
_lg_init_accept_apply() {
  local s="$1" dry="$2" lgpath="$3" tsv="$4" rec path hosted key prev ledger summary nk nl ns na what
  local file row id st sk sl ss text body out ref rc=0 views="" vdir nlines a
  vdir="$_LG_CACHE/views"
  [ -e "$s.written" ] || : > "$s.written"
  : > "$s.lines"
  : > "$s.created"
  if [ "$dry" = 1 ]; then
    if [ ! -e docs/ledger/config.json ] && [ ! -L docs/ledger/config.json ]; then echo "would write docs/ledger/config.json" >> "$s.lines"; fi
    if [ ! -e docs/ledger/ledgers.json ] && [ ! -L docs/ledger/ledgers.json ]; then echo "would write docs/ledger/ledgers.json (the report's registry)" >> "$s.lines"; fi
  else
    cat -- "$s.written" >> "$s.lines"
  fi
  # The items: one fm-write.awk pass per file, the adapter for a hosted one.
  jq -r '.items[] | [.path, (.hosted | tostring), (.key // ""), (.previous // ""), (.ledger // ""), (.summary // ""),
      .names.key, .names.ledger, .names.summary, .names.aliases] | map(gsub("[\n\r]"; " ")) | .[]' "$s.final" > "$s.items" \
    || _lg_die "jq failed (the item edits)"
  # Ten lines per item (an empty field is a line of its own).
  while IFS= read -r path && IFS= read -r hosted && IFS= read -r key && IFS= read -r prev && IFS= read -r ledger \
      && IFS= read -r summary && IFS= read -r nk && IFS= read -r nl && IFS= read -r ns && IFS= read -r na; do
    what=""
    [ -z "$key" ] || what="key $key"
    [ -z "$ledger" ] || what="${what:+$what, }ledger $ledger"
    [ -z "$summary" ] || what="${what:+$what, }summary"
    [ -z "$prev" ] || what="$what (was $prev)"
    if [ "$dry" = 1 ]; then
      printf 'would update %s: %s\n' "$path" "$what" >> "$s.lines"
      continue
    fi
    if [ "$hosted" = true ]; then
      [ -z "$ledger" ] || _lg_init_hosted_write "$path" ledger "$ledger"
      [ -z "$summary" ] || _lg_init_hosted_write "$path" summary "$summary"
      [ -z "$key" ] || _lg_init_hosted_write "$path" key "$key"
    else
      _lg_fm_ops_reset
      [ -z "$key" ] || _lg_fm_op set "$nk" "$key"
      [ -z "$ledger" ] || _lg_fm_op set "$nl" "$ledger"
      [ -z "$summary" ] || _lg_fm_op set "$ns" "$summary"
      if [ -n "$prev" ]; then _lg_fm_op_list_add "$path" "$na" "$prev"; fi
      _lg_fm_ops_apply "$path"
    fi
    printf 'updated %s: %s\n' "$path" "$what" >> "$s.lines"
  done < "$s.items"

  # The stubs.
  jq -c '.stubs[]' "$s.final" > "$s.stubrecs" || _lg_die "jq failed (stubs)"
  while IFS= read -r rec; do
    jq -r '[.path // "", (.hosted | tostring), .file, .row, .id, (.key // ""), .ledger, .summary,
        .names.status, .names.key, .names.ledger, .names.summary] | map(gsub("[\n\r]"; " ")) | .[]' <<<"$rec" > "$s.stub1" \
      || _lg_die "jq failed (stub)"
    { IFS= read -r path; IFS= read -r hosted; IFS= read -r file; IFS= read -r row; IFS= read -r id; IFS= read -r key
      IFS= read -r ledger; IFS= read -r summary; IFS= read -r st; IFS= read -r sk; IFS= read -r sl; IFS= read -r ss; } < "$s.stub1" \
      || _lg_die "cannot read the stub record"
    text=$(jq -r '.text' <<<"$rec") || _lg_die "jq failed (stub)"
    what="stub of $file row $row${key:+, key $key}, ledger $ledger"
    if [ "$dry" = 1 ]; then
      if [ "$hosted" = true ]; then
        printf 'would create an issue (items adapter create) "%s": %s\n' "$summary" "$what" >> "$s.lines"
      else
        printf 'would create %s: %s\n' "$path" "$what" >> "$s.lines"
      fi
      continue
    fi
    body="$s.stubbody"
    if [ "$hosted" = true ]; then
      printf 'Migrated from %s row %s.\n\n%s\n' "$file" "$row" "$text" > "$body" || _lg_die "cannot write $body"
      out=$(_lg_adapter items create --title "$summary" --body-file "$body") || _lg_die "the items adapter could not create the stub of $file row $row"
      ref=$(jq -r 'select(type == "object") | .ref | strings' <<<"$out" | head -n 1) || ref=""
      [ -n "$ref" ] || _lg_die "the items adapter's create printed no ref for the stub of $file row $row: $out"
      printf '%s\n' "$id" "$ref" "$key" >> "$s.created"
      _lg_init_hosted_write "$ref" ledger "$ledger"
      _lg_init_hosted_write "$ref" summary "$summary"
      [ -z "$key" ] || _lg_init_hosted_write "$ref" key "$key"
      printf 'created %s: %s\n' "$ref" "$what" >> "$s.lines"
    else
      mkdir -p "$(dirname -- "$path")" || _lg_die "cannot create $(dirname -- "$path")"
      { printf -- '---\n%s: Open\n---\n# %s\n\nMigrated from %s row %s.\n\n%s\n' "$st" "$summary" "$file" "$row" "$text"; } > "$body" \
        || _lg_die "cannot write $body"
      _lg_fm_ops_reset
      [ -z "$key" ] || _lg_fm_op set "$sk" "$key"
      _lg_fm_op set "$sl" "$ledger"
      _lg_fm_op set "$ss" "$summary"
      _lg_fm_ops_apply "$body"
      _lg_init_put "$body" "$path"
      printf 'created %s: %s\n' "$path" "$what" >> "$s.lines"
    fi
  done < "$s.stubrecs"

  # legacy.json: the new entries (and the hosted stubs'), the old ones kept.
  # shellcheck disable=SC2016  # jq source
  jq -R -n -c --slurpfile f "$s.final" '
    [inputs] as $l
    | (reduce range(0; ($l | length) / 3 | floor) as $i ({};
         .[$l[$i * 3]] = (if $l[$i * 3 + 2] != "" then {key: $l[$i * 3 + 2]} else {item: $l[$i * 3 + 1]} end))) as $h
    | $f[0].legacy_new + $h' "$s.created" > "$s.lnew" || _lg_die "jq failed (legacy entries)"
  if [ -n "$lgpath" ] && [ "$(jq 'length' "$s.lnew")" != 0 ]; then
    if [ "$dry" = 1 ]; then
      printf 'would write %s (+%s entries: %s)\n' "$lgpath" "$(jq 'length' "$s.lnew")" "$(jq -r 'keys | join(", ")' "$s.lnew")" >> "$s.lines"
    else
      jq -S -s '.[0] + .[1]' "$s.lgy" "$s.lnew" > "$s.lout" || _lg_die "jq failed (legacy.json)"
      mkdir -p "$(dirname -- "$lgpath")" || _lg_die "cannot create $(dirname -- "$lgpath")"
      _lg_init_put "$s.lout" "$lgpath"
      printf 'wrote %s (+%s entries)\n' "$lgpath" "$(jq 'length' "$s.lnew")" >> "$s.lines"
    fi
  fi
  jq -r '.legacy_findings[] | "finding: \(.detail)"' "$s.final" | tr -d '\000-\010\013-\037' >> "$s.lines" \
    || _lg_die "jq failed (legacy findings)"
  if [ -s "$s.created" ] || [ "$(jq '[.items[] | select(.hosted)] | length' "$s.final")" != 0 ]; then
    a=$(_lg_cfg '.keys.remote | if type == "string" and . != "" then . else "origin" end') || exit "$?"
    _lg_adapter_path items > /dev/null 2>&1 || true
    _lg_ix_items_km "$a"
    _lg_remote_expire items "$_LG_IX_KM"
  fi

  # The views (ledger view all, in its own run: the files written above are
  # its working tree).
  if [ "$dry" = 1 ]; then
    printf 'would render the views to %s\n' "$vdir" >> "$s.lines"
  else
    rc=0
    "$BASH" "$SCRIPT_DIR/doc-tools.sh" ledger view all --out "$vdir" < /dev/null > "$s.vout" 2> "$s.verr" || rc=$?
    [ "$rc" = 0 ] || _lg_die "the files are written, but the views could not be rendered (ledger view all, exit $rc): $(head -n 3 "$s.verr" | tr '\n' ' ')"
    views=$vdir
    printf 'views: %s\n' "$vdir" >> "$s.lines"
  fi
  nlines=$(jq '.legacy_findings | length' "$s.final") || _lg_die "jq failed"
  # shellcheck disable=SC2016  # jq source
  jq -r --slurpfile p "$s.plan" --argjson dry "$dry" '
    "ledger init --accept: \($p[0].apply | length) row(s) applied, \($p[0].skipped) without a decision (left alone)"
    + (if (.keys | length) > 0 then "; \(.keys | length + 0) key(s)" else "" end)
    + (if $dry == 1 then " — dry run: nothing was written" else "; review and commit the files above" end)' "$s.final" >> "$s.lines" \
    || _lg_die "jq failed (summary)"
  if [ "$_LG_FORMAT" = json ]; then
    # shellcheck disable=SC2016  # jq source
    jq -c --slurpfile p "$s.plan" --slurpfile n "$s.lnew" --arg d "$tsv" --argjson dry "$([ "$dry" = 1 ] && echo true || echo false)" \
        --arg views "$views" --arg lg "$lgpath" --rawfile w "$s.written" --rawfile cr "$s.created" '
      ($cr | split("\n") | map(select(. != ""))) as $c
      | {decisions: $d, dry_run: $dry, findings: .legacy_findings,
         written: ($w | split("\n") | map(select(. != "") | sub("^wrote "; "") | sub(" \\(.*$"; ""))),
         keys: (.keys + [range(0; ($c | length) / 3 | floor) as $i | select($c[$i * 3 + 2] != "")
                         | {path: $c[$i * 3 + 1], ledger: null, key: $c[$i * 3 + 2], previous: null}]
                + [.stubs[] | select(.hosted | not) | select(.key != null) | {path, ledger, key, previous: null}]),
         items: [.items[] | {path, key, ledger, summary, previous}],
         stubs: ([.stubs[] | select(.hosted | not) | {path, row: "\(.file)#\(.row)", id, ledger, key, hosted: false}]
                 + [range(0; ($c | length) / 3 | floor) as $i | {path: $c[$i * 3 + 1], id: $c[$i * 3], key: (if $c[$i * 3 + 2] == "" then null else $c[$i * 3 + 2] end), hosted: true}]
                 + (if $dry then [.stubs[] | select(.hosted) | {path: null, row: "\(.file)#\(.row)", id, ledger, key, hosted: true}] else [] end)),
         legacy: {path: (if $lg == "" then null else $lg end), added: ($n[0] | keys)},
         skipped: $p[0].skipped,
         views: (if $views == "" then null else $views end)}' "$s.final" > "$s.payload" || _lg_die "jq failed (payload)"
    _lg_emit init "$([ "$nlines" = 0 ] && echo 0 || echo 1)" "$s.payload"
  fi
  _lg_out_file "$s.lines"
  _lg_emit init "$([ "$nlines" = 0 ] && echo 0 || echo 1)"
}

# _lg_init_hosted_write <ref> <field> <value>: the items adapter's write.
_lg_init_hosted_write() {
  _lg_adapter items write "$1" "$2" "$3" > /dev/null 2> "$_SCRATCH/lg-init-hw.err" \
    || _lg_die "hosted item $1: the items adapter could not write $2: $(head -n 2 "$_SCRATCH/lg-init-hw.err" | tr '\n' ' ')"
}

# --- --import ----------------------------------------------------------------------
#
# ledger init --import (design §K; Task 15 ruling R6): the hosted items
# (config items.adapter's list, read now) become file items, once. Each
# not yet imported — no item file has imported_from: <ref> — is read with
# the adapter's get <ref> and written to docs/issues/<created
# YYYY-MM-DD>-<slug of its title>.md (today without a created date; -2, -3
# … on a collision): frontmatter imported_from, url, then its fields
# (logical names as config fields' first candidates) and status, sorted;
# body "# <title>", then its body. Then the adapter's note <ref> "Imported
# to <path> (doc-superpowers ledger)." links it back; nothing is closed.
# The first failure stops the run: exit 2, what was imported stays, the
# adapter stays configured. When every listed item is imported,
# config.json's items.adapter becomes null (keys are not held twice). An
# adapter without get (it exits 3 to it): exit 2, naming it.

# shellcheck disable=SC2016  # jq source
_LG_JQ_IMPORT_OPS='
($c[0]) as $c | lg_fields($c) as $F
| def v: if type == "string" then gsub("[\r\n]+"; " ") elif type == "array" then . else tojson end;
  ([{k: "imported_from", v: .ref}, {k: "url", v: .url}]
   + ((.fields // {}) + {status: .status} | to_entries | sort_by(.key)
      | map(select(.value != null) | {k: ((($F[.key] // [])[0]) // .key), v: (.value | v)})))[]
| if (.v | type) == "array" then
    [.v[] | if type == "string" then gsub("[\r\n\u0001]+"; " ") else tojson end] as $l
    | "setlist\u0001\(.k)\u0001\($l | length)\u0001\($l | join("\u0001"))\u0000"
  else "set\u0001\(.k)\u0001\(.v)\u0000" end
'

_lg_init_import() {
  local s ad today rc out ref title created path base slug n imported=0 failed="" listed done_n rec op rest name count a
  _lg_scratch_name
  s=$_LG_SN
  _lg_adapter_path items || _lg_die "init --import: $_LG_ADP_ERR"
  [ -n "$_LG_ADP" ] || _lg_die "init --import: no items adapter (config items.adapter): nothing to import"
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then _lg_die "init --import: offline (DOC_TOOLS_LEDGER_OFFLINE=1)"; fi
  ad=$(_lg_cfg '.items.adapter') || exit "$?"
  today=$(date +%Y-%m-%d) || _lg_die "date failed"
  _lg_adapter items list > "$s.list" 2> "$s.lerr" \
    || _lg_die "init --import: the items adapter ($ad) could not list the items: $(head -n 2 "$s.lerr" | tr '\n' ' ')"
  # The refs already imported (imported_from of the item files).
  _lg_item_paths worktree "$s.paths"
  : > "$s.recs"
  if [ -s "$s.paths" ]; then _lg_parse_worktree "$s.paths" "$s.recs"; fi
  jq -r -n --slurpfile r "$s.recs" '[$r[] | .fm.imported_from | strings] | unique | .[]' > "$s.done" \
    || _lg_die "jq failed (imported items)"
  jq -r '.ref' "$s.list" > "$s.refs" || _lg_die "jq failed (the hosted refs)"
  listed=$(grep -c . "$s.refs" || true)
  : > "$s.lines"
  : > "$s.imp"
  done_n=0
  while IFS= read -r ref; do
    if grep -Fqx -- "$ref" "$s.done"; then done_n=$((done_n + 1)); continue; fi
    rc=0
    ( cd "$_LG_ROOT" && "$_LG_ADP" get "$ref" ) < /dev/null > "$s.get" 2> "$s.gerr" || rc=$?
    if [ "$rc" = 3 ]; then
      _lg_die "init --import: the items adapter $ad ($_LG_ADP) has no get <ref> (it exited 3 to get $ref) — --import needs it"
    fi
    if [ "$rc" != 0 ]; then
      failed="$ref: the items adapter's get exited $rc: $(head -n 2 "$s.gerr" | tr '\n' ' ' | tr -d '\000-\010\013-\037')"
      break
    fi
    if ! jq -e -s 'length == 1 and (.[0] | type == "object" and (.ref | type) == "string" and (.title | type) == "string"
        and ((.body // "") | type) == "string" and ((.fields // {}) | type) == "object")' "$s.get" > /dev/null 2>&1; then
      failed="$ref: the items adapter's get printed no {ref, title, body, fields} object"
      break
    fi
    { IFS= read -r title; IFS= read -r created; IFS= read -r slug; } < <(jq -r --arg today "$today" "$_LG_JQ_ACCEPT_DEFS"'
        (.title | gsub("[\r\n]+"; " ")),
        (.created | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") then .[0:10] else $today end),
        (.title | lg_stubslug)' "$s.get") || _lg_die "jq failed (import $ref)"
    base="docs/issues/$created-$slug"
    path="$base.md"
    n=2
    while [ -e "$path" ] || [ -L "$path" ]; do path="$base-$n.md"; n=$((n + 1)); done
    { printf -- '---\n---\n# %s\n' "$title"
      jq -j '(.body // "") | if . == "" then "" else "\n" + sub("\n*$"; "") + "\n" end' "$s.get"; } > "$s.file" \
      || _lg_die "cannot write $s.file"
    jq -L "$_LG_LIB" -j --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS$_LG_JQ_IMPORT_OPS" "$s.get" > "$s.ops" \
      || _lg_die "jq failed (the fields of $ref)"
    _lg_fm_ops_reset
    while IFS= read -r -d '' rec; do
      op=${rec%%$'\001'*}
      rest=${rec#*$'\001'}
      name=${rest%%$'\001'*}
      rest=${rest#*$'\001'}
      case "$op" in
        set) _lg_fm_op set "$name" "$rest" ;;
        setlist) count=${rest%%$'\001'*}; rest=${rest#*$'\001'}; _lg_fm_op setlist "$name" "" "$rest" "$count" ;;
      esac
    done < "$s.ops"
    _lg_fm_ops_apply "$s.file"
    mkdir -p docs/issues || _lg_die "cannot create docs/issues"
    _lg_init_put "$s.file" "$path"
    imported=$((imported + 1))
    printf '%s\t%s\n' "$ref" "$path" >> "$s.imp"
    printf 'imported %s → %s\n' "$ref" "$path" >> "$s.lines"
    if ! _lg_adapter items note "$ref" "Imported to $path (doc-superpowers ledger)." > /dev/null 2> "$s.nerr"; then
      failed="$ref: imported to $path, but the link-back note failed: $(head -n 2 "$s.nerr" | tr '\n' ' ')"
      break
    fi
  done < "$s.refs"
  [ "$done_n" = 0 ] || printf 'already imported: %s item(s) (imported_from)\n' "$done_n" >> "$s.lines"
  # The hosted copy changed (comments): the next read fetches it.
  a=$(_lg_cfg '.keys.remote | if type == "string" and . != "" then . else "origin" end') || exit "$?"
  _lg_ix_items_km "$a"
  _lg_remote_expire items "$_LG_IX_KM"
  printf '{}\n' > "$s.set"
  if [ -z "$failed" ] && [ "$((done_n + imported))" = "$listed" ] && [ -f docs/ledger/config.json ]; then
    jq -S '.items.adapter = null' docs/ledger/config.json > "$s.cfg" || _lg_die "jq failed (config.json)"
    _lg_init_put "$s.cfg" docs/ledger/config.json
    printf '{"items.adapter": null}\n' > "$s.set"
    printf 'set items.adapter to null in docs/ledger/config.json — the items are files now (was %s)\n' "$ad" >> "$s.lines"
  fi
  rc=0
  [ -z "$failed" ] || rc=2
  if [ "$_LG_FORMAT" = json ]; then
    # shellcheck disable=SC2016  # jq source
    jq -R -n -c --slurpfile set "$s.set" --arg f "$failed" --argjson skipped "$done_n" '
      {imported: [inputs | split("\t") | {ref: .[0], path: .[1]}], already_imported: $skipped,
       config_set: $set[0]} + (if $f == "" then {} else {error: $f} end)' "$s.imp" > "$s.payload" \
      || _lg_die "jq failed (payload)"
    _lg_emit init "$rc" "$s.payload"
  fi
  _lg_out_file "$s.lines"
  if [ -n "$failed" ]; then
    printf 'ERROR: init --import stopped at %s — what was imported stays; items.adapter is kept\n' "$failed" >&2
  fi
  _lg_emit init "$rc"
}

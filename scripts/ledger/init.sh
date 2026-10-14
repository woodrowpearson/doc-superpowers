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
#   --accept <tsv>      not implemented yet (exit 2)
#   --import            not implemented yet (exit 2)
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
    if [ -n "$_OPT_accept" ]; then _lg_die "init --accept: not implemented yet"; fi
    _lg_die "init --import: not implemented yet"
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
#   {"t":"R","file","row"}           a data row of a "#"-headed table (row:
#                                    its "#" cell, else "n<ordinal in the file>")
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
function scan(p, flag,   line, n, infm, isitem, fence, prev, intable, hcol, nc, i, j, ord, rid, rest, t, base, st) {
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
        print "{\"t\":\"R\",\"file\":" js(p) ",\"row\":" js(rid) "}"
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
      nc = cells(prev); hcol = 0
      for (i = 1; i <= nc; i++) if (C[i] == "#") { hcol = i; break }
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

  _lg_cfg '.legacy_ledgers | if type == "object" then to_entries[] | .value | select(type == "string" and . != "") else empty end' \
    > "$s.legacy" || exit "$?"
  tr '\n\000' '\001\n' < "$s.tracked" | LC_ALL=C awk -v legacy="$s.legacy" '
    BEGIN { SOH = sprintf("%c", 1); while ((getline l < legacy) > 0) if (!(l in L)) { L[l] = 1; O[++n] = l } }
    index($0, SOH) || index($0, "\t") { next }
    /[.]md$/ && !($0 in L) { print "T\t" $0 }
    END { for (i = 1; i <= n; i++) if (!index(O[i], "\t")) print "L\t" O[i] }' > "$s.mdlist" \
    || _lg_die "cannot list the markdown files"
  rc=0
  LC_ALL=C awk -v globs="$s.iglobs" -v bom="$_LG_BOM" "$_LG_AWK_JS$_LG_AWK_GLOB$_LG_AWK_INIT_SCAN" "$s.mdlist" > "$s.scan" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot scan the markdown files (awk rc $rc)"

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

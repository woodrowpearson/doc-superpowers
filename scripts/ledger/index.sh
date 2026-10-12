# shellcheck shell=bash
# scripts/ledger/index.sh — the ledger index: items joined with the
# registry, the doc-index (specs, plans, handoffs that link an item), git
# dates (renames chained), a local derived status; cached under $_LG_CACHE.
# Sourced by lib.sh; uses lib.sh's _lg_die, _lg_cfg, _lg_registry,
# _lg_doc_index, _lg_src_cat, parse.sh's parsers and helpers, glob.sh's
# _lg_globs_matching / _lg_glob_dirs, validate.sh's _lg_registry_findings
# and doc-tools.sh's _hash_one / _hash_list.
#
# _lg_index [--rev <rev>|--staged] prints the path of the index file
# (schema ledger-index/1, references/ledger-index.schema.json) built from:
#   (default)  the working tree — tracked and untracked item files, the
#              working copies of the registry, doc-index, legacy map and docs
#   --staged   the index (stage 0) — the blobs a commit would record
#   --rev R    the commit R
# The merged config is the run's (docs/ledger/config.json of the working
# tree) in every mode. Dates come from HEAD's history (R's for --rev).
#
# Cache: $_LG_CACHE/index-<sha256>.json, the hash over the schema, the
# code (every file of scripts/ledger/), the mode, HEAD, the base oid, the config, and — never by walking the
# items — the commit's tree (--rev), or git's listing (path, blob id) of
# the directories holding the items, the candidate docs, the registry,
# doc-index, legacy and finalized maps (--staged: the index's; worktree:
# with `git hash-object` ids for modified and untracked files, plus those
# small files' bytes). Registry findings are recorded in built, not fatal;
# an unreadable registry, doc-index, legacy or finalized map is rc 2 (a
# build reads and checks them). A file that does not start with this
# schema or is cut short is rebuilt. The newest 3 are kept. A build
# reuses the per-file parse cache (parse.sh), so a one-item change parses
# one file. DOC_TOOLS_LEDGER_TRACE=1 (or more) prints "index-hit <name>" or
# "index-build <name>", and "dates-hit" / "dates-cold" /
# "dates-extend <oid>", to stderr.
#
# Dates: fields.date when it starts with YYYY-MM-DD, else the date git first
# added the path (the earliest add) — a rename (R) carries the old path's
# date, chained; a path re-added after a rename moved its file away takes
# the later add —
# from `git log --reverse --full-history --date=short --format=%ad
# --name-status -M --diff-filter=AR` over the item globs' directories
# (--full-history: no history simplification, so a TREESAME merge hides no
# side branch from a cold map that an extended one would see), replayed in
# order; the
# events are cached in $_LG_CACHE/dates-<commit>.tsv and a new HEAD extends
# the newest cached ancestor's. A path git never added (uncommitted) takes
# its file's mtime (UTC). The same rename chain lets a link to a former path
# reach the item.
# Order: a cold map replays `git log --reverse HEAD`; an extended one replays
# the ancestor's events, then anc..HEAD — different orders when a side branch
# was merged. Adds at an occupied path take the minimum date, so they agree.
# A rename away from a path and an add at that path on two merged branches
# still depend on that order (vacated before or after the add): accepted.
# Known deviation (cost): the log is limited to the item globs' directories,
# so rename detection sees only moves within them — an item moved into the
# item dirs from elsewhere is dated by the move, and links to its old path
# (outside) are not followed.
#
# Docs: doc-index entries whose doc_type is in doc_columns.<col> (a list of
# doc types, or an object {"doc_types": […], "globs": […]}; globs add the
# matching files) are scanned once (one awk pass): a markdown link
# (inline, <…>, %-encoded, #anchor, reference-style, /root-relative) that
# resolves to an item's path or a former path of it, or the item's key as
# a word, links the doc to the item. A plan is terminal when its doc-index
# entry is deprecated or superseded, it lives under docs/archive/, or its
# status (frontmatter `status:` or a `Status:` line in its first 60 lines)
# starts with a terminal word (_LG_DOC_TERMINAL).

_LG_INDEX_SCHEMA="ledger-index/1"

# The status words that end a plan (leading-word match, case-insensitive).
_LG_DOC_TERMINAL='["implemented","complete","completed","done","shipped","merged","superseded","deprecated","archived","abandoned","cancelled","canceled","closed","obsolete","fixed","resolved","rejected","retired","withdrawn","won'"'"'t fix","wontfix","wont-fix","not planned"]'

_lg_ix_trace() {
  if [ "${DOC_TOOLS_LEDGER_TRACE:-0}" -ge 1 ] 2>/dev/null; then printf '%s\n' "$*" >&2; fi
}

# --- Blob ids --------------------------------------------------------------------

# _lg_ix_blob_ids <:|commit> <paths-lines> <out>: "<oid>\t<path>" per line —
# the blob the index (stage 0) or the commit holds for the path as a
# regular file, else "-". One listing of the paths' directories.
_lg_ix_blob_ids() {
  local src="$1" in="$2" out="$3" s d tree="" imode
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  LC_ALL=C awk -v specs="$s.specs" '
    BEGIN { printf "" > specs }
    index($0, "\001") == 0 {
      d = $0
      if (match(d, /.*\//)) d = substr(d, 1, RLENGTH)
      if (!(d in seen)) { seen[d] = 1; print d > specs }
    }' "$in" || _lg_die "cannot list the directories of $in"
  while IFS= read -r d; do
    specs+=("$d")
  done < "$s.specs"
  : > "$s.lsz"
  if [ "${#specs[@]}" -gt 0 ]; then
    if [ "$src" = : ]; then
      GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- "${specs[@]}" > "$s.lsz" || _lg_die "git ls-files -s failed"
    else
      tree=$(git rev-parse -q --verify "$src^{tree}") || _lg_die "unknown revision: '$src'"
      GIT_LITERAL_PATHSPECS=1 git ls-tree -r -z --full-name "$tree" -- "${specs[@]}" > "$s.lsz" \
        || _lg_die "git ls-tree failed at $src"
    fi
  fi
  _lg_parse_lst "$s.lsz" "$s.ls"
  imode=""
  if [ "$src" = : ]; then imode=1; fi
  LC_ALL=C awk -v ls="$s.ls" -v index_mode="$imode" '
    BEGIN {
      while ((getline l < ls) > 0) {
        t = index(l, "\t"); p = substr(l, t + 1); split(substr(l, 1, t - 1), f, " ")
        if (index_mode) { if (f[3] == "0" && f[1] ~ /^1006[0-9][0-9]$/) OID[p] = f[2] }
        else if (f[2] == "blob" && f[1] ~ /^1006[0-9][0-9]$/) OID[p] = f[3]
      }
    }
    { print (($0 in OID) ? OID[$0] : "-") "\t" $0 }' "$in" > "$out" || _lg_die "cannot list the blob ids"
}

# --- Small inputs ------------------------------------------------------------------

# _lg_ix_json_obj <src> <path> <out> <what>: the JSON object file <path> as
# <src> holds it, compact, into <out>; {} when absent or <path> is empty.
# Anything but one JSON object dies (2).
_lg_ix_json_obj() {
  local src="$1" p="$2" out="$3" what="$4"
  if [ -z "$p" ] || ! _lg_src_cat "$src" "$p" "$out.raw"; then
    printf '{}\n' > "$out" || _lg_die "cannot write $out"
    return 0
  fi
  jq -e -s 'length == 1 and (.[0] | type) == "object"' "$out.raw" >/dev/null 2>&1 \
    || _lg_die "$p is not a valid $what (expected one JSON object)"
  jq -c . "$out.raw" > "$out" || _lg_die "jq failed ($p)"
}

# _lg_ix_candidates <src> <doc-index> <out>: "<column>\t<path>" lines (a
# newline in a name as \001) — the docs the docs join reads.
_lg_ix_candidates() {
  local src="$1" di="$2" out="$3" col g s gsrc
  _lg_scratch_name
  s=$_LG_SN
  jq -r --slurpfile c "$_LG_CFG" '
    ($c[0].doc_columns // {}) as $dc
    | .docs as $d
    | ("spec", "plan", "handoff") as $col
    | ($dc[$col] | if type == "array" then . elif type == "object" then (.doc_types // []) else [] end
       | [.[] | strings]) as $types
    | select($types | length > 0)
    | $d | to_entries[] | select((.value | type) == "object" and ((.value.doc_type // null) as $t | $types | index([$t])))
    | "\($col)\t\(.key | gsub("\n"; "\u0001"))"' "$di" > "$out" || _lg_die "jq failed (doc-index candidates)"
  if [ "$src" = worktree ]; then gsrc=worktree; else gsrc=$src; fi
  for col in spec plan handoff; do
    g=$(_lg_cfg "(.doc_columns.$col // null) | if type == \"object\" then ((.globs // []) | length) else 0 end")
    [ "$g" != 0 ] || continue
    _lg_globs_matching "$gsrc" "$s.$col.z" ".doc_columns.$col.globs"
    tr '\n\000' '\001\n' < "$s.$col.z" | LC_ALL=C awk -v col="$col" '{ print col "\t" $0 }' >> "$out" \
      || _lg_die "cannot list the $col globs"
  done
}

# --- Dates -------------------------------------------------------------------------

# _lg_ix_events <commit> <dirs-file> → _LG_EVENTS: the cached event file of
# <commit> ("A" date path / "R" date old new, one field per line, a newline
# in a name as \001; first line "# ledger-dates/2 <sig>"), built cold or by
# extending the newest cached ancestor's.
_lg_ix_events() {
  local commit="$1" dirs="$2" s sig header f c oid anc="" tmp range first d
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  { printf 'ledger-dates/2\n'; cat "$dirs"; } > "$s.sig" || _lg_die "cannot write $s.sig"
  _hash_one "$s.sig"
  sig=${_HASH#sha256:}
  header="# ledger-dates/2 $sig"
  f="$_LG_CACHE/dates-$commit.tsv"
  first=""
  if [ -f "$f" ]; then IFS= read -r first < "$f" || true; fi
  if [ "$first" = "$header" ]; then
    _lg_ix_trace "dates-hit"
    _LG_EVENTS=$f
    return 0
  fi
  # shellcheck disable=SC2012  # cache names are dates-<hex>.tsv
  ls -t "$_LG_CACHE"/dates-*.tsv 2>/dev/null | head -n 8 > "$s.cached" || true
  while IFS= read -r c; do
    oid=${c##*/dates-}
    oid=${oid%.tsv}
    [ "$oid" != "$commit" ] || continue
    first=""
    IFS= read -r first < "$c" || true
    [ "$first" = "$header" ] || continue
    if git merge-base --is-ancestor "$oid" "$commit" 2>/dev/null; then
      anc=$oid
      break
    fi
  done < "$s.cached"
  while IFS= read -r d; do
    specs+=("$d")
  done < "$dirs"
  tmp=$(mktemp "$_LG_CACHE/.dates.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  if [ -n "$anc" ]; then
    _lg_ix_trace "dates-extend $anc"
    cp -- "$_LG_CACHE/dates-$anc.tsv" "$tmp" || { rm -f "$tmp"; _lg_die "cannot copy the cached dates of $anc"; }
    range="$anc..$commit"
  else
    _lg_ix_trace "dates-cold"
    printf '%s\n' "$header" > "$tmp" || { rm -f "$tmp"; _lg_die "cannot write $tmp"; }
    range=$commit
  fi
  # git log -z: "<date>\0\n<status>\0<path>[\0<path>]\0…"; after tr, one
  # token per line (the first status of a commit led by \001).
  # --full-history: a merge TREESAME to one parent must not hide the other
  # parent's commits — a map extended from that side branch's tip has them.
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --reverse --full-history --date=short \
    --format=%ad --name-status -M --diff-filter=AR -z "$range" -- ${specs[@]+"${specs[@]}"} > "$s.log" 2> "$s.err" \
    || { rm -f "$tmp"; _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"; }
  tr '\n\000' '\001\n' < "$s.log" | LC_ALL=C awk '
    {
      t = $0
      if (st == "") {
        if (substr(t, 1, 1) == "\001") t = substr(t, 2)
        if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { d = t; next }
        if (t == "A") { st = "A"; next }
        if (t ~ /^R[0-9]*$/) { st = "R1"; next }
        next
      }
      if (st == "A") { print "A"; print d; print t; st = ""; next }
      if (st == "R1") { old = t; st = "R2"; next }
      print "R"; print d; print old; print t; st = ""
    }' >> "$tmp" || { rm -f "$tmp"; _lg_die "cannot read the git history of the items"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _lg_die "cannot install $f"; }
  # The newest 5 maps are kept.
  # shellcheck disable=SC2012  # cache names are dates-<hex>.tsv
  ls -t "$_LG_CACHE"/dates-*.tsv 2>/dev/null | tail -n +6 | while IFS= read -r c; do rm -f "$c"; done
  _LG_EVENTS=$f
}

# _lg_ix_dates <commit|""> <items-lines> <mtime 0|1> <out.jsonl> <formers>:
# {"p","d"} per item with a date (git, else the file's mtime when <mtime>
# is 1 and the working copy exists); <formers>: "<former>\n<item>" pairs.
_lg_ix_dates() {
  local commit="$1" items="$2" usemtime="$3" out="$4" formers="$5" s ev n m p e
  _lg_scratch_name
  s=$_LG_SN
  ev=/dev/null
  if [ -n "$commit" ]; then
    _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$s.globs"
    _lg_glob_dirs "$s.globs" "$s.dirs"
    _lg_ix_events "$commit" "$s.dirs"
    ev=$_LG_EVENTS
  fi
  _lg_awkv "$ev"
  LC_ALL=C awk -v ev="$_LG_AV" -v nodate="$s.nodate" -v formers="$formers" "$_LG_AWK_JS"'
    BEGIN {
      js_init()
      # The events in order (oldest first: the cached part, then each
      # extension). A: an occupied path keeps the earliest of its adds (so
      # the order a merged side branch is listed in does not matter); a
      # path renamed away is vacated, and a later add there is a new item
      # with its own date. R: the new path takes the old path date
      # (chained), the old is vacated.
      while ((getline k < ev) > 0) {
        if (k == "A") {
          getline d < ev; getline p < ev
          if (!(p in D) || (p in VAC)) { D[p] = d; delete VAC[p] }
          else if (d < D[p]) D[p] = d
        } else if (k == "R") {
          getline d < ev; getline o < ev; getline p < ev
          D[p] = (o in D && !(o in VAC)) ? D[o] : d
          delete VAC[p]
          if (o != p) VAC[o] = 1
          PREV[p] = PREV[p] SUBSEP o
        }
      }
      printf "" > nodate; printf "" > formers
    }
    {
      p = $0
      if ((p in D) && !(p in VAC)) print "{\"p\":" js(rep(p, SOH, "\n")) ",\"d\":" js(D[p]) "}"
      else print p > nodate
      # The former paths of p: every path a rename chain leads from.
      if (!(p in PREV)) next
      qn = 0; delete SEEN; SEEN[p] = 1; Q[++qn] = p
      for (qi = 1; qi <= qn; qi++) {
        k = split(substr(PREV[Q[qi]], 2), A, SUBSEP)
        for (j = 1; j <= k; j++) {
          o = A[j]
          if (o in SEEN) continue
          SEEN[o] = 1; Q[++qn] = o
          print o > formers; print p > formers
        }
      }
    }' "$items" > "$out" || _lg_die "cannot compute the item dates"
  [ "$usemtime" = 1 ] && [ -s "$s.nodate" ] || return 0
  # mtimes (UTC) of the working copies that exist.
  : > "$s.mt"
  while IFS= read -r p; do
    case "$p" in *$'\001'*) continue ;; esac
    if [ -f "$p" ]; then printf '%s\n' "$p"; fi
  done < "$s.nodate" > "$s.mt"
  [ -s "$s.mt" ] || return 0
  tr '\n' '\000' < "$s.mt" > "$s.mtz" || _lg_die "cannot write $s.mtz"
  # GNU stat -c, else BSD stat -f, in one batch; when the batch does not
  # line up (a file vanished meanwhile), one by one, skipping the vanished
  # (they get no date).
  xargs -0 stat -c %Y -- < "$s.mtz" > "$s.ep" 2>/dev/null || xargs -0 stat -f %m -- < "$s.mtz" > "$s.ep" 2>/dev/null || true
  n=$(wc -l < "$s.mt")
  m=$(wc -l < "$s.ep")
  if [ "$n" -ne "$m" ]; then
    : > "$s.ep"
    : > "$s.mt2"
    while IFS= read -r p; do
      e=$(stat -c %Y -- "$p" 2>/dev/null || stat -f %m -- "$p" 2>/dev/null) || continue
      printf '%s\n' "$e" >> "$s.ep"
      printf '%s\n' "$p" >> "$s.mt2"
    done < "$s.mt"
    mv -f "$s.mt2" "$s.mt" || _lg_die "cannot write $s.mt"
  fi
  LC_ALL=C awk -v ep="$s.ep" "$_LG_AWK_JS"'
    # Days since 1970-01-01 → a civil date (proleptic Gregorian).
    function civil(t,   z, era, doe, yoe, y, doy, mp, dd, mm) {
      z = int(t / 86400) + 719468
      era = int((z >= 0 ? z : z - 146096) / 146097)
      doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400
      doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153)
      dd = doy - int((153 * mp + 2) / 5) + 1
      mm = (mp < 10) ? mp + 3 : mp - 9
      if (mm <= 2) y++
      return sprintf("%04d-%02d-%02d", y, mm, dd)
    }
    BEGIN { js_init() }
    {
      if ((getline e < ep) <= 0 || e !~ /^[0-9]+$/) exit 3
      print "{\"p\":" js($0) ",\"d\":" js(civil(e + 0)) "}"
    }' "$s.mt" >> "$out" || _lg_die "cannot convert the modification times"
}

# --- The docs join -------------------------------------------------------------------

# The awk program: -v keys (lines "<key>\t<path>"), formers (pairs), cands
# ("<col>\t<path>"), mode (files | batch), order (batch: the paths, one per
# blob of the stream on stdin), bom. Prints {"c","d","i"} per link and
# {"s","v"} per doc with a status line.
# shellcheck disable=SC2016  # awk source
_LG_AWK_DOCS='
function hexv(h,   v, i) {
  v = 0
  for (i = 1; i <= 2; i++) v = v * 16 + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
  return v
}
function pdecode(s,   out, i, h, v) {
  out = ""
  while ((i = index(s, "%")) > 0) {
    h = substr(s, i + 1, 2); v = -1
    if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) v = hexv(h)
    if (v > 0) { out = out substr(s, 1, i - 1) sprintf("%c", v); s = substr(s, i + 3) }
    else { out = out substr(s, 1, i); s = substr(s, i + 1) }
  }
  return out s
}
# norm(p): "a/./b/../c" → "a/c"; "" when it climbs above the top.
function norm(p,   n, a, i, k, st, out) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k == 0) return ""; k--; continue }
    st[++k] = a[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") st[i]
  return out
}
function hit(item,   n, a, j, c) {
  n = split(COLS[DOC], a, " ")
  for (j = 1; j <= n; j++) {
    c = a[j]
    if (c == "" || ((c, DOC, item) in OUT)) continue
    OUT[c, DOC, item] = 1
    print "{\"c\":" js(c) ",\"d\":" js(rep(DOC, SOH, "\n")) ",\"i\":" js(rep(item, SOH, "\n")) "}"
  }
}
function link(t,   p) {
  sub(/#.*/, "", t); sub(/[?].*/, "", t)
  if (t == "" || t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return
  if (index(t, "%")) t = pdecode(t)
  if (substr(t, 1, 1) == "/") p = norm(substr(t, 2))
  else p = norm(DIR t)
  if (p == "") return
  if (p in ITEM) hit(p)
  else if (p in FORMER) hit(FORMER[p])
}
function target(t,   j) {
  if (substr(t, 1, 1) == "<") {
    j = index(t, ">")
    return (j > 0) ? substr(t, 2, j - 2) : ""
  }
  if (match(t, /[ \t)]/)) t = substr(t, 1, RSTART - 1)
  return t
}
function scan_links(line,   rest, i) {
  rest = line
  while ((i = index(rest, "](")) > 0) {
    rest = substr(rest, i + 2)
    link(target(rest))
  }
  if (line ~ /^ ? ? ?\[[^\]]*\]:/) {
    rest = line
    sub(/^ *\[[^\]]*\]:[ \t]*/, "", rest)
    link(target(rest))
  }
}
function scan_keys(line,   n, a, j, k, m, b, x) {
  n = split(line, a, /[^A-Za-z0-9_-]+/)
  for (j = 1; j <= n; j++) {
    k = tolower(a[j])
    if (!(k in KEY)) continue
    m = split(substr(KEY[k], 2), b, SUBSEP)
    for (x = 1; x <= m; x++) hit(b[x])
  }
}
function doc_begin(p,   d) {
  DOC = p; LN = 0; FM = 0; STATUS = ""
  d = p
  DIR = match(d, /.*\//) ? substr(d, 1, RLENGTH) : ""
}
function status_of(s,   v) {
  v = s
  sub(/^[^:]*:/, "", v)
  gsub(/[*`]/, "", v)
  sub(/^[ \t_]+/, "", v); sub(/[ \t_]+$/, "", v)
  if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
  return v
}
function doc_line(line,   s) {
  LN++
  if (LN == 1 && substr(line, 1, 3) == bom) line = substr(line, 4)
  sub(/\r$/, "", line)
  if (LN == 1 && line ~ /^---[ \t]*$/) { FM = 1; return }
  if (FM == 1 && line ~ /^(---|[.][.][.])[ \t]*$/) { FM = 2; return }
  if (STATUS == "" && (FM == 1 || LN <= 60)) {
    s = line
    sub(/^[> \t-]*/, "", s)
    if (s ~ /^(\*\*|__)?[Ss][Tt][Aa][Tt][Uu][Ss](\*\*|__)?[ \t]*:/) STATUS = status_of(s)
  }
  if (index(line, "](") || line ~ /^ ? ? ?\[/) scan_links(line)
  if (line ~ /[A-Za-z0-9]-[0-9]/) scan_keys(line)
}
function doc_end() {
  if (STATUS != "") print "{\"s\":" js(rep(DOC, SOH, "\n")) ",\"v\":" js(STATUS) "}"
}
BEGIN {
  js_init()
  while ((getline l < keys) > 0) {
    t = index(l, "\t"); k = substr(l, 1, t - 1); p = substr(l, t + 1)
    ITEM[p] = 1
    if (k != "") KEY[k] = KEY[k] SUBSEP p
  }
  while ((getline o < formers) > 0) {
    if ((getline p < formers) <= 0) break
    if (!(o in FORMER)) FORMER[o] = p
  }
  n = 0
  while ((getline l < cands) > 0) {
    t = index(l, "\t"); c = substr(l, 1, t - 1); p = substr(l, t + 1)
    if (!(p in COLS)) { CP[++n] = p; COLS[p] = "" }
    if (index(" " COLS[p] " ", " " c " ") == 0) COLS[p] = COLS[p] " " c
  }
  if (mode == "files") {
    for (i = 1; i <= n; i++) {
      p = CP[i]
      if (index(p, SOH)) continue
      f = (substr(p, 1, 1) == "/") ? p : "./" p
      doc_begin(p)
      while ((r = (getline line < f)) > 0) doc_line(line)
      close(f)
      if (r == 0) doc_end()
    }
    exit 0
  }
  # batch: "<oid> blob <size>\n<content>\n" per path of order.
  while ((getline hdr) > 0) {
    if ((getline p < order) <= 0) exit 3
    split(hdr, h, " ")
    if (h[2] != "blob") exit 3
    size = h[3] + 0; got = 0
    doc_begin(p)
    while (got < size) {
      if ((getline line) <= 0) exit 3
      got += length(line) + 1
      doc_line(line)
    }
    if (got == size) getline line
    doc_end()
  }
  exit 0
}'

# _lg_ix_docs <src> <cands> <keys> <formers> <out.jsonl>: the docs join.
_lg_ix_docs() {
  local src="$1" cands="$2" keys="$3" formers="$4" out="$5" s rc=0
  _lg_scratch_name
  s=$_LG_SN
  : > "$out"
  [ -s "$cands" ] || return 0
  if [ "$src" = worktree ]; then
    LC_ALL=C awk -v keys="$keys" -v formers="$formers" -v cands="$cands" -v mode=files -v bom="$_LG_BOM" \
      "$_LG_AWK_JS$_LG_AWK_DOCS" < /dev/null > "$out" || rc=$?
    [ "$rc" = 0 ] || _lg_die "cannot scan the docs (awk rc $rc)"
    return 0
  fi
  # The index or a commit: the docs' blobs, one git cat-file --batch.
  LC_ALL=C awk '{ p = substr($0, index($0, "\t") + 1); if (!(p in seen)) { seen[p] = 1; print p } }' "$cands" > "$s.paths" \
    || _lg_die "cannot list the docs"
  _lg_ix_blob_ids "$src" "$s.paths" "$s.ids"
  LC_ALL=C awk -v order="$s.order" 'BEGIN { printf "" > order } $1 != "-" { t = index($0, "\t"); print substr($0, 1, t - 1); print substr($0, t + 1) > order }' \
    "$s.ids" > "$s.oids" || _lg_die "cannot list the doc blobs"
  if [ ! -s "$s.oids" ]; then return 0; fi
  git cat-file --batch < "$s.oids" | tr '\000' '\001' \
    | LC_ALL=C awk -v keys="$keys" -v formers="$formers" -v cands="$cands" -v mode=batch -v order="$s.order" \
        -v bom="$_LG_BOM" "$_LG_AWK_JS$_LG_AWK_DOCS" > "$out" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot scan the docs (git cat-file --batch | awk: rc $rc)"
}

# --- The join ------------------------------------------------------------------------

# jq: the item record → the index item; the index object. Inputs (slurped):
# $c config, $reg registry, $di doc-index, $lgy legacy, $fin finalized,
# $recs parse records, $dates {"p","d"}, $docs {"c","d","i"} / {"s","v"}.
# shellcheck disable=SC2016  # jq source
_LG_JQ_INDEX_DEFS='
# lg_fields($cfg): {logical: [candidate names]} — config "fields", once.
def lg_fields($cfg):
  ($cfg.fields // {}) | with_entries(.value |= (if type == "array" then [.[] | strings] elif type == "string" then [.] else [] end));
# lg_fv($F; $n), applied to a record fm: the first candidate present, or null.
def lg_fv($F; $n):
  ($F[$n] // []) as $cs
  | if ($cs | length) == 1 then .[$cs[0]] else first(.[$cs[]] | values) // null end;
def lg_str:
  if type == "string" then (if . == "" then null else . end)
  elif type == "array" then ([.[] | strings | select(. != "")] | if length == 0 then null else join(", ") end)
  else null end;
def lg_list:
  if type == "array" then [.[] | strings | select(. != "")]
  elif type == "string" then (if . == "" then [] else [.] end)
  else [] end;
def lg_norm:
  ascii_downcase
  | if index("\u2019") then gsub("\u2019"; "'"'"'") else . end
  | if (.[0:1] as $f | $f != "" and (" \t*_`~\"'"'"'" | index($f) != null)) then sub("^[\\s*_`~\"'"'"']+"; "") else . end;
# lg_lead($t): the normalized value starts with the word(s) $t.
def lg_lead($t): . == $t or (startswith($t) and (.[($t | length):] | test("^[^a-z0-9]")));
# lg_class_terms($cfg): [{c, t}] — every status word of every class, the
# longest first (so "won'"'"'t fix" is tried before a shorter word).
def lg_class_terms($cfg):
  [ ("open", "fixed", "closed", "wontfix") as $cl
    | ($cfg.status[$cl] | if type == "array" then .[] elif type == "string" then . else empty end)
    | strings | ascii_downcase | select(. != "") | {c: $cl, t: .} ]
  | sort_by(-(.t | length));
# lg_class($CT; $EX): $EX = {word: class} answers an exact value at once.
def lg_class($CT; $EX):
  if type != "string" then "unknown"
  else lg_norm as $v | $EX[$v] // (first($CT[] | select(.t as $t | $v | lg_lead($t)) | .c) // "unknown")
  end;
def lg_terminal_doc($p; $S; $DI; $terms):
  ($DI[$p] // {}) as $e
  | (($e | type) == "object" and ($e.status == "deprecated" or (($e.superseded_by // "") | type == "string" and . != "")))
    or ($p | startswith("docs/archive/"))
    or (($S[$p] // null) | if type == "string" then (lg_norm as $v | any($terms[]; . as $t | $v | lg_lead($t))) else false end);
def lg_item($F; $CT; $EX; $D; $L; $S; $DI; $terms):
  . as $r
  | ($r.fm // {}) as $fm
  | (($fm | lg_fv($F; "status")) | lg_str) as $status
  | ($status | lg_class($CT; $EX)) as $class
  | (($fm | lg_fv($F; "owed")) | lg_str) as $owed
  | (($fm | lg_fv($F; "superseded_by")) | lg_str) as $sup
  | (($fm | lg_fv($F; "date")) | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ]|$)") then .[0:10] else null end) as $fd
  | ($L[$r.path]) as $l
  | (if $l == null then {spec: [], plan: [], handoff: []}
     else {spec: (($l.spec // []) | unique), plan: (($l.plan // []) | unique), handoff: (($l.handoff // []) | unique)} end) as $docs
  | (if $docs.plan == [] then [] else [$docs.plan[] | select(lg_terminal_doc(.; $S; $DI; $terms) | not)] end) as $open_plans
  | {path: $r.path,
     archived: ($r.archived == true),
     key: (($fm | lg_fv($F; "key")) | lg_str),
     ledger: (($fm | lg_fv($F; "ledger")) | lg_str),
     status: $status,
     class: $class,
     severity: (($fm | lg_fv($F; "severity")) | lg_str),
     date: ($fd // $D[$r.path]),
     summary: (($fm | lg_fv($F; "summary")) | lg_str),
     changes: (($fm | lg_fv($F; "changes")) | lg_list),
     consumes: (($fm | lg_fv($F; "consumes")) | lg_list),
     relates: [($fm | lg_fv($F; "relates")) | lg_list | .[] | split(":") as $p
               | if ($p | length) < 2 then {kind: null, key: .}
                 else {kind: $p[0], key: ($p[1:] | join(":") | ltrimstr(" "))} end],
     superseded_by: $sup,
     owed: $owed,
     aliases: (($fm | lg_fv($F; "aliases")) | lg_list),
     paths: (($fm | lg_fv($F; "paths")) | lg_list),
     h1: $r.h1,
     first_para: $r.first_para,
     resolution: $r.resolution,
     docs: $docs,
     derived: (if $sup != null and $class == "closed" then {status: "superseded", detail: $sup}
               elif $class == "wontfix" then {status: "won'"'"'t fix", detail: null}
               elif $class == "closed" then {status: "closed", detail: null}
               elif $class == "fixed" then
                 (if $owed != null then {status: "merged", detail: $owed} else {status: "shipped", detail: null} end)
               elif ($open_plans | length) > 0 then {status: "planned", detail: $open_plans[0]}
               elif ($docs.spec | length) > 0 then {status: "spec'"'"'d", detail: $docs.spec[0]}
               else {status: "not started", detail: null} end),
     pr: null,
     inflight: [],
     neighbours: null,
     recheck_after: [],
     fm_errors: ($r.fm_errors // [])};
'
# shellcheck disable=SC2016  # jq source
_LG_JQ_INDEX='
$c[0] as $cfg
| lg_fields($cfg) as $F
| lg_class_terms($cfg) as $CT
| (reduce ($CT | reverse)[] as $x ({}; .[$x.t] = $x.c)) as $EX
| ($di[0].docs // {}) as $DI
| (reduce $dates[] as $x ({}; .[$x.p] = $x.d)) as $D
| (reduce ($docs[] | select(has("i"))) as $x ({}; .[$x.i][$x.c] += [$x.d])) as $L
| (reduce ($docs[] | select(has("s"))) as $x ({}; .[$x.s] = $x.v)) as $S
| {schema: $schema,
   built: {head: (if $head == "" then null else $head end),
           base: (if $base == "" then null else $base end),
           inputs_hash: $hash,
           mode: $mode,
           rev: (if $rev == "" then null else $rev end),
           registry_findings: $rf},
   ledgers: $reg[0].ledgers,
   items: ([$recs[] | lg_item($F; $CT; $EX; $D; $L; $S; $DI; $terms)] | sort_by(.path)),
   legacy: $lgy[0],
   finalized: $fin[0]}
'

# _lg_ix_valid <file>: the file is a whole index of this schema.
_lg_ix_valid() {
  local f="$1" pre="" last
  [ -f "$f" ] || return 1
  IFS= read -r -n 27 pre < "$f" 2>/dev/null || true
  [ "$pre" = '{"schema":"ledger-index/1",' ] || return 1
  last=$(tail -c 2 "$f" 2>/dev/null) || return 1
  [ "$last" = "}" ]
}

# --- Pruning -------------------------------------------------------------------------

# _lg_ix_prune: keep the newest 3 index files by mtime (a hit touches its
# file) and their .refs — and any modified in the last 10 minutes; at most
# once a day: sweep parse temp dirs older than an hour, other parsers'
# cache dirs untouched for 14 days, and parse entries older than 14 days
# that no kept index references.
_lg_ix_prune() {
  local stamp="$_LG_CACHE/prune.stamp" s f d
  _lg_scratch_name
  s=$_LG_SN
  # shellcheck disable=SC2012  # cache names are index-<hex>.json
  ls -t "$_LG_CACHE"/index-*.json 2>/dev/null | tail -n +4 > "$s.old" || true
  while IFS= read -r f; do
    # Never one written or used in the last 10 minutes (a concurrent run
    # may be about to read it).
    if [ -n "$(find "$f" -mmin -10 2>/dev/null)" ]; then continue; fi
    rm -f "$f" "${f%.json}.refs"
  done < "$s.old"
  if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then return 0; fi
  : > "$stamp" || return 0
  find "$_LG_CACHE/parse" -mindepth 2 -maxdepth 2 -name '.new.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  find "$_LG_CACHE" -maxdepth 1 \( -name '.index.*' -o -name '.dates.*' -o -name '.blob-sha256.*' \) -mmin +60 \
    -exec rm -f {} + 2>/dev/null || true
  for d in "$_LG_CACHE"/parse/*; do
    [ -d "$d" ] && [ "$d" != "$_LG_PARSE_DIR" ] || continue
    if [ -n "$(find "$d" -maxdepth 0 -mtime +14 2>/dev/null)" ]; then rm -rf "$d"; fi
  done
  cat "$_LG_CACHE"/index-*.refs > "$s.refs" 2>/dev/null || : > "$s.refs"
  ( cd "$_LG_PARSE_DIR" && find . -maxdepth 1 -name '[bc]-*.json' -mtime +14 ) 2>/dev/null \
    | LC_ALL=C awk -v refs="$s.refs" 'BEGIN { while ((getline r < refs) > 0) R[r] = 1 } { n = substr($0, 3); if (!(n in R)) print n }' \
    > "$s.gone" || true
  if [ -s "$s.gone" ]; then
    ( cd "$_LG_PARSE_DIR" && xargs rm -f < "$s.gone" ) || true
  fi
}

# --- The cache key ----------------------------------------------------------------

# _lg_ix_key_specs <doc-index> <legacy-path> <out>: the pathspecs (one per
# line) whose listing the key hashes: the item globs' directories, the
# directories of the doc-index's candidate docs and of the column globs,
# and the small inputs. Empty when a glob has no literal directory (the
# whole tree is listed).
_lg_ix_key_specs() {
  local di="$1" legacy="$2" out="$3" s
  _lg_scratch_name
  s=$_LG_SN
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?,
            ((.doc_columns // {})[] | objects | (.globs // [])[]?)] | .[] | strings | select(. != "")' > "$s.globs"
  : > "$s.dirs"
  if [ -s "$s.globs" ]; then
    _lg_glob_dirs "$s.globs" "$s.dirs"
    if [ ! -s "$s.dirs" ]; then : > "$out"; return 0; fi
  fi
  jq -r --slurpfile c "$_LG_CFG" '
    ([($c[0].doc_columns // {})[] | if type == "array" then .[] elif type == "object" then (.doc_types // [])[]? else empty end
      | strings]) as $types
    | .docs | to_entries[] | select((.value | type) == "object" and ((.value.doc_type // null) as $t | $types | index([$t])))
    | .key | select(test("\n") | not) | if test("/") then sub("[^/]*$"; "") else . end' "$di" > "$s.ddirs" \
    || _lg_die "jq failed (doc-index directories)"
  { cat "$s.dirs" "$s.ddirs"; printf '%s\n' docs/ledger/ledgers.json "$INDEX_FILE" docs/ledger/finalized.json;
    if [ -n "$legacy" ]; then printf '%s\n' "$legacy"; fi; } | LC_ALL=C sort -u > "$out" \
    || _lg_die "cannot write $out"
}

# _lg_ix_key_listing <worktree|staged> <specs> <listing> <dirty-ids>:
# <listing> = `git ls-files -s -z` of the specs (the index's blob ids);
# worktree: <dirty-ids> = "<blob id> <path>" for each modified or untracked
# (not ignored) file under them — the id `git hash-object` gives — or
# "deleted <path>".
_lg_ix_key_listing() {
  local mode="$1" specsf="$2" listing="$3" dirty="$4" s p n m
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  while IFS= read -r p; do
    specs+=("$p")
  done < "$specsf"
  GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- ${specs[@]+"${specs[@]}"} > "$listing" 2> "$s.err" \
    || _lg_die "git ls-files -s failed: $(head -n 3 "$s.err" 2>/dev/null)"
  : > "$dirty"
  [ "$mode" = worktree ] || return 0
  GIT_LITERAL_PATHSPECS=1 git ls-files -m -o --exclude-standard -z -- ${specs[@]+"${specs[@]}"} > "$s.mz" 2> "$s.err" \
    || _lg_die "git ls-files -m -o failed: $(head -n 3 "$s.err" 2>/dev/null)"
  [ -s "$s.mz" ] || return 0
  # Each path once; a name holding a newline cannot reach hash-object
  # --stdin-paths: its \001 form stands in, marked.
  tr '\n\000' '\001\n' < "$s.mz" | LC_ALL=C awk '!seen[$0]++' > "$s.m"
  : > "$s.files"
  while IFS= read -r p; do
    case "$p" in
      *$'\001'*) printf 'unhashable %s\n' "$p" >> "$dirty" ;;
      *) if [ -f "$p" ]; then printf '%s\n' "$p" >> "$s.files"; else printf 'deleted %s\n' "$p" >> "$dirty"; fi ;;
    esac
  done < "$s.m"
  [ -s "$s.files" ] || return 0
  git hash-object --stdin-paths < "$s.files" > "$s.ids" 2> "$s.err" \
    || _lg_die "git hash-object failed: $(head -n 3 "$s.err" 2>/dev/null)"
  n=$(wc -l < "$s.files")
  m=$(wc -l < "$s.ids")
  [ "$n" -eq "$m" ] || _lg_die "git hash-object gave $m ids for $n files"
  paste -d ' ' "$s.ids" "$s.files" >> "$dirty" || _lg_die "cannot write $dirty"
}

# _lg_ix_effective <listing> <dirty-ids> <out>: the working tree's
# "<path>\t<blob id>" set, sorted — the index's ids with each modified or
# untracked file's id put in and deleted files taken out — so staging bytes
# the working tree already has changes nothing.
_lg_ix_effective() {
  local listing="$1" dirty="$2" out="$3" s
  _lg_scratch_name
  s=$_LG_SN
  _lg_parse_lst "$listing" "$s.ls"
  LC_ALL=C awk -v ls="$s.ls" '
    BEGIN {
      while ((getline l < ls) > 0) {
        t = index(l, "\t"); p = substr(l, t + 1); split(substr(l, 1, t - 1), f, " ")
        E[p] = (f[3] == "0") ? f[2] : "unmerged"
      }
    }
    {
      sp = index($0, " "); id = substr($0, 1, sp - 1); p = substr($0, sp + 1)
      if (id == "deleted") delete E[p]
      else E[p] = id
    }
    END { for (p in E) print p "\t" E[p] }' "$dirty" | LC_ALL=C sort > "$out" \
    || _lg_die "cannot compute the working tree listing"
}

# _lg_ix_refs <records> <out>: the parse entries the records were read from
# (pruning spares them), one name per line: a working copy's c-<sha256>; a
# blob's c-<sha256> when the blob id -> sha256 map names one that exists
# (that is the one _lg_parse_emit read first), else its b-<oid>. Non-zero
# on a failure (the caller dies). scripts/bench-ledger.sh times it alone.
_lg_ix_refs() {
  local recs="$1" out="$2" s map
  _lg_scratch_name
  s=$_LG_SN
  jq -r '.blob | strings' "$recs" > "$s.blobs" || return 1
  map="$_LG_CACHE/blob-sha256.tsv"
  [ -f "$map" ] || map=/dev/null
  _lg_awkv "$map"
  map=$_LG_AV
  _lg_awkv "$_LG_PARSE_DIR"
  LC_ALL=C awk -v map="$map" -v dir="$_LG_AV" '
    BEGIN { while ((getline l < map) > 0) { t = index(l, "\t"); if (t) H[substr(l, 1, t - 1)] = substr(l, t + 1) } }
    /^sha256:/ { print "c-" substr($0, 8) ".json"; next }
    {
      if ($0 in H && H[$0] ~ /^sha256:/) {
        c = "c-" substr(H[$0], 8) ".json"
        if ((getline x < (dir "/" c)) > 0) { close(dir "/" c); print c; next }
        close(dir "/" c)
      }
      print "b-" $0 ".json"
    }' "$s.blobs" > "$out"
}

# --- _lg_index ---------------------------------------------------------------------

# _lg_index [--rev <rev>|--staged]: print the path of the index (see the
# header). Dies (2) on an unreadable input (doc-index, registry, legacy or
# finalized map), an unknown revision, or a git failure.
_lg_index() {
  local mode=worktree rev="" src commit="" tree="" head base_ref="" base="" s reg di key name tmp rfn f
  local legacy_path="" dcommit usemtime map
  case "$#" in
    0) ;;
    1) [ "$1" = --staged ] || _lg_die "internal: _lg_index: unknown argument '$1'"; mode=staged ;;
    2) [ "$1" = --rev ] || _lg_die "internal: _lg_index: unknown arguments '$1 $2'"; mode=rev; rev=$2 ;;
    *) _lg_die "internal: _lg_index takes [--rev <rev>|--staged]" ;;
  esac
  _lg_parse_prep
  _lg_scratch_name
  s=$_LG_SN
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  case "$mode" in
    worktree) src=worktree; dcommit=$head; usemtime=1 ;;
    staged) src=:; dcommit=$head; usemtime=1 ;;
    rev)
      case "$rev" in
        -*|'') _lg_die "not a revision: '$rev'" ;;
      esac
      commit=$(git rev-parse -q --verify "$rev^{commit}" 2>/dev/null) || _lg_die "unknown revision: '$rev'"
      tree=$(git rev-parse -q --verify "$commit^{tree}") || _lg_die "cannot read the tree of $rev"
      src=$commit; dcommit=$commit; usemtime=0 ;;
  esac
  # One jq over the config: the base ref, the legacy map's path.
  _lg_cfg '(.base | if type == "string" then . else "" end), (.legacy | if type == "string" then . else "" end)' > "$s.cfgv"
  { IFS= read -r base_ref; IFS= read -r legacy_path; } < "$s.cfgv" || true
  case "$base_ref" in
    -*|'') ;;
    *) base=$(git rev-parse -q --verify "$base_ref^{commit}" 2>/dev/null) || base="" ;;
  esac
  di=$(_lg_doc_index "$src")

  # The key: never a walk over the items. --rev: the commit's tree holds
  # every input. Otherwise git's listing (blob ids) of the directories the
  # items, the candidate docs and the small inputs live in — and, for the
  # working tree, the blob id git would record for each modified or
  # untracked file there (_lg_ix_effective), and the bytes of the small
  # inputs.
  # The code: every file of scripts/ledger/ (sorted by name).
  for f in "$_LG_LIB"/*; do
    if [ -f "$f" ]; then printf '%s\0' "$f"; fi
  done > "$s.hashin"
  printf '%s\0' "$_LG_CFG" >> "$s.hashin"
  : > "$s.dirtyids"
  if [ "$mode" != rev ]; then
    _lg_ix_key_specs "$di" "$legacy_path" "$s.specs"
    _lg_ix_key_listing "$mode" "$s.specs" "$s.lsidx" "$s.dirtyids"
    if [ "$mode" = worktree ]; then
      _lg_ix_effective "$s.lsidx" "$s.dirtyids" "$s.eff"
      printf '%s\0' "$s.eff" >> "$s.hashin"
    else
      printf '%s\0' "$s.lsidx" >> "$s.hashin"
    fi
    if [ "$mode" = worktree ]; then
      # Which are present goes into the key too (s.smalls).
      for f in docs/ledger/ledgers.json "$INDEX_FILE" "$legacy_path" docs/ledger/finalized.json; do
        if [ -n "$f" ] && [ -f "$f" ]; then printf '%s\0' "$f" >> "$s.hashin"; printf 'present %s\n' "$f"; else printf 'absent %s\n' "$f"; fi
      done > "$s.smalls"
    fi
  fi
  [ -f "$s.smalls" ] || : > "$s.smalls"
  _hash_list "$s.hashin" "$s.hashes"
  {
    printf 'schema %s\nmode %s\nhead %s\nrev %s\ntree %s\nbase %s\nlegacy %s\n' \
      "$_LG_INDEX_SCHEMA" "$mode" "$head" "$commit" "$tree" "$base" "$legacy_path"
    cat "$s.smalls"
    printf 'inputs: code (scripts/ledger/*), config[, listing[, the present small files]]\n'
    cat "$s.hashes"
  } > "$s.key" || _lg_die "cannot write the index key"
  _hash_one "$s.key"
  key=${_HASH#sha256:}
  name="$_LG_CACHE/index-$key.json"
  if _lg_ix_valid "$name"; then
    _lg_ix_trace "index-hit index-$key.json"
    # A hit makes the file the newest: pruning keeps the newest by mtime.
    touch -c "$name" "${name%.json}.refs" 2>/dev/null || true
    printf '%s\n' "$name"
    return 0
  fi
  _lg_ix_trace "index-build index-$key.json"

  # The inputs, read and checked.
  reg=$(_lg_registry "$src")
  _lg_ix_json_obj "$src" "$legacy_path" "$s.legacy" "legacy map"
  _lg_ix_json_obj "$src" docs/ledger/finalized.json "$s.finalized" "finalized map"
  case "$mode" in
    worktree) _lg_item_paths worktree "$s.itemz" ;;
    staged) _lg_item_paths : "$s.itemz" ;;
    rev) _lg_item_paths "$commit" "$s.itemz" ;;
  esac
  _lg_parse_lst "$s.itemz" "$s.items"
  _lg_ix_candidates "$src" "$di" "$s.cands"

  # Parse, date, join.
  if [ "$mode" = worktree ]; then
    _lg_parse_worktree "$s.itemz" "$s.recs"
  elif [ "$mode" = staged ]; then
    _lg_parse_blobs : "$s.itemz" "$s.recs"
  else
    _lg_parse_blobs "$commit" "$s.itemz" "$s.recs"
  fi
  jq -n -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F
    | inputs
    | ((.fm // {}) | lg_fv($F; "key") | if type == "string" and (test("[\\t\\n\\r]") | not) then ascii_downcase else "" end) as $k
    | "\($k)\t\(.path | gsub("\n"; "\u0001"))"' "$s.recs" > "$s.keys" || _lg_die "jq failed (item keys)"
  _lg_ix_dates "$dcommit" "$s.items" "$usemtime" "$s.dates" "$s.formers"
  _lg_ix_docs "$src" "$s.cands" "$s.keys" "$s.formers" "$s.docs"
  : > "$s.none"
  _lg_registry_findings "$reg" "$s.none" "$s.rf"
  rfn=$(wc -l < "$s.rf" | tr -d ' ')
  tmp=$(mktemp "$_LG_CACHE/.index.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  if ! jq -n -c \
      --slurpfile c "$_LG_CFG" --slurpfile reg "$reg" --slurpfile di "$di" \
      --slurpfile lgy "$s.legacy" --slurpfile fin "$s.finalized" \
      --slurpfile recs "$s.recs" --slurpfile dates "$s.dates" --slurpfile docs "$s.docs" \
      --arg schema "$_LG_INDEX_SCHEMA" --arg head "$head" --arg base "$base" --arg hash "sha256:$key" \
      --arg mode "$mode" --arg rev "$commit" --argjson rf "$rfn" --argjson terms "$_LG_DOC_TERMINAL" \
      "$_LG_JQ_INDEX_DEFS$_LG_JQ_INDEX" > "$tmp"; then
    rm -f "$tmp"
    _lg_die "jq failed (the index join)"
  fi
  _lg_ix_refs "$s.recs" "${tmp}.refs" || { rm -f "$tmp" "${tmp}.refs"; _lg_die "cannot list the parse references"; }
  if ! mv -f "${tmp}.refs" "$_LG_CACHE/index-$key.refs" || ! mv -f "$tmp" "$name"; then
    rm -f "$tmp" "${tmp}.refs"
    _lg_die "cannot install $name"
  fi
  _lg_ix_prune
  printf '%s\n' "$name"
}

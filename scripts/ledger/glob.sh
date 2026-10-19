# shellcheck shell=bash
# scripts/ledger/glob.sh — the ledger's one glob grammar (item globs,
# registry paths/residual_paths, contracts' defined_in), glob → ERE, path
# filtering, and the registry's ownership map. Sourced by lib.sh; uses
# lib.sh's _lg_die, _lg_cfg and parse.sh's _LG_SN / _lg_scratch_name.
#
# Grammar (a path is matched whole, relative to the top level):
#   **/        zero or more directories (at the start, after "/", "{" or ",")
#   **         anything, "/" included (elsewhere: "src/**", "a**b")
#   *          anything within one path segment (never "/")
#   ?          one character other than "/"
#   {a,b,c}    one of the alternatives (each may hold globs; may nest)
#   \c         the character c itself
# Every other character is itself ("[", "]", "." and "," outside braces
# too). An unbalanced "{" or "}" makes the glob invalid. In a registry's
# paths / residual_paths, a leading "!" makes the glob an exclusion.
#
# Path lists are NUL-terminated files. The awk programs read them as lines
# (a newline inside a name travels as \001, as in parse.sh) and in the C
# locale: bytes, so a unicode name is matched byte by byte.
#
# Speed: each glob is filed under its literal directory prefix (the text
# up to the last "/" before its first wildcard); a path is tried only
# against the globs filed under one of its own ancestor directories. In
# git's sorted order consecutive paths try the same few regexes, which keeps
# BWK awk's compiled-regex cache warm.

# The awk library: glob_ere, glob_dir, gx_add, gx_match.
_LG_AWK_GLOB='
function glob_lit(c) {
  if (c == "\\") return "\\\\"
  if (c == "^") return "\\^"
  if (index(".[]()|$+{}*?", c)) return "[" c "]"
  return c
}
# glob_alt(out): out, closed with "()" when an alternative of a brace is
# empty ("{,a}", "{a,}", "{a,,b}", "{}"): BWK awk rejects "(|a)" / "(a|)"
# ("illegal primary"), and accepts "(()|a)". A literal "(" or "|" is
# written "[(]" / "[|]", so the last character tells.
function glob_alt(out,   c) {
  c = substr(out, length(out), 1)
  return (c == "(" || c == "|") ? out "()" : out
}
# glob_ere(g): the ERE for glob g ("^…$"), or "" with GLOB_ERR set.
function glob_ere(g,   out, i, n, c, depth, prev) {
  GLOB_ERR = ""
  out = ""; n = length(g); depth = 0; prev = "/"
  for (i = 1; i <= n; i++) {
    c = substr(g, i, 1)
    if (c == "*") {
      if (substr(g, i + 1, 1) == "*") {
        if (substr(g, i + 2, 1) == "/" && (prev == "/" || prev == "{" || prev == ",")) {
          out = out "(.*/)?"; i += 2; prev = "/"; continue
        }
        out = out ".*"; i++; prev = "*"; continue
      }
      out = out "[^/]*"; prev = c; continue
    }
    if (c == "?") { out = out "[^/]"; prev = c; continue }
    if (c == "{") { depth++; out = out "("; prev = c; continue }
    if (c == "}") {
      if (depth == 0) { GLOB_ERR = "unbalanced \"}\""; return "" }
      depth--; out = glob_alt(out) ")"; prev = c; continue
    }
    if (c == "," && depth > 0) { out = glob_alt(out) "|"; prev = c; continue }
    if (c == "\\") {
      if (i == n) { GLOB_ERR = "a trailing \"\\\""; return "" }
      i++; c = substr(g, i, 1)
    }
    out = out glob_lit(c); prev = c
  }
  if (depth > 0) { GLOB_ERR = "unbalanced \"{\""; return "" }
  if (g == "") { GLOB_ERR = "empty"; return "" }
  return "^" out "$"
}
# glob_dir(g): the literal directory prefix of g ("" or ending in "/").
function glob_dir(g,   i, n, c, d) {
  n = length(g); d = ""
  for (i = 1; i <= n; i++) {
    c = substr(g, i, 1)
    if (index("*?{}\\", c)) break
    if (c == "/") d = substr(g, 1, i)
  }
  return d
}
# gx_add(k, g): file glob g as number k. 0 (GLOB_ERR set) for a bad glob.
function gx_add(k, g,   re, d) {
  re = glob_ere(g)
  if (re == "") return 0
  d = glob_dir(g)
  GX_RE[k] = re
  GX_N[d]++
  GX_B[d, GX_N[d]] = k
  return 1
}
# gx_match(p): the globs matching path p, as GX_M[1..GX_MN].
function gx_match(p,   d, j, k, n, i) {
  GX_MN = 0
  d = ""
  i = 0
  while (1) {
    n = GX_N[d] + 0
    for (j = 1; j <= n; j++) {
      k = GX_B[d, j]
      if (p ~ GX_RE[k]) GX_M[++GX_MN] = k
    }
    j = index(substr(p, i + 1), "/")
    if (j == 0) break
    i += j
    d = substr(p, 1, i)
  }
}
'

# _lg_glob_ere <glob>: print the glob's ERE ("^…$"). A bad glob dies (2).
_lg_glob_ere() {
  local re
  _lg_awkv "$1"
  re=$(LC_ALL=C awk -v g="$_LG_AV" "$_LG_AWK_GLOB"'
    BEGIN { re = glob_ere(g); if (re == "") { print GLOB_ERR; exit 1 }; print re }') \
    || _lg_die "bad glob '$1': $re"
  printf '%s\n' "$re"
}

# _lg_glob_dirs <globs-file> <out>: the literal directory prefixes of the
# globs (one per line) as git pathspecs, one per line; empty when any glob
# has none (the caller then lists everything). A bad glob dies (2).
_lg_glob_dirs() {
  local msg
  msg=$(LC_ALL=C awk -v out="$2" -v q="'" "$_LG_AWK_GLOB"'
    BEGIN { printf "" > out }
    {
      if (glob_ere($0) == "") { print "bad glob " q $0 q ": " GLOB_ERR; bad = 1; exit 1 }
      d = glob_dir($0)
      if (d == "") all = 1
      else if (!(d in seen)) { seen[d] = 1; D[++n] = d }
    }
    END {
      if (bad) exit 1
      if (!all) for (i = 1; i <= n; i++) print D[i] > out
    }' "$1") || _lg_die "${msg:-cannot read the globs $1}"
}

# _lg_paths_filter <in-nul> <globs-file> <out-nul>: the paths of <in-nul>
# (in order) that match one of the globs (one per line). A bad glob dies.
_lg_paths_filter() {
  local in="$1" globs="$2" out="$3" msg rc=0
  _lg_scratch_name
  tr '\n\000' '\001\n' < "$in" > "$_LG_SN.lst" || _lg_die "cannot read the path list $in"
  msg=$(LC_ALL=C awk -v globs="$globs" -v out="$_LG_SN.hit" -v q="'" "$_LG_AWK_GLOB"'
    BEGIN {
      printf "" > out
      while ((getline g < globs) > 0) {
        if (!gx_add(++k, g)) { print "bad glob " q g q ": " GLOB_ERR; exit 1 }
      }
    }
    { gx_match($0); if (GX_MN) print > out }' "$_LG_SN.lst") || rc=$?
  [ "$rc" = 0 ] || _lg_die "${msg:-cannot match the path list $in}"
  tr '\n\001' '\000\n' < "$_LG_SN.hit" > "$out" || _lg_die "cannot write $out"
}

# --- The ownership map -------------------------------------------------------

# _lg_registry_globs <registry> <out.tsv> [active]: every string glob of the
# registry (with "active": of the ledgers whose status is not "retired")
# as "<ledger-index>\t<ledger-id>\t<list>\t<neg>\t<glob>" — list P (paths),
# R (residual_paths) or D (a contract's defined_in or read_by: validate checks
# both, neither owns anything); neg 1 for a "!"
# exclusion in P or R (the "!" removed). A ledger without a string id (or
# with a control character in it) is shown as "#<index>". Globs holding a control character are left out
# (validate reports them).
_lg_registry_globs() {
  jq -r --arg only "${3:-}" '
    def strs: if type == "array" then .[] | select(type == "string") else empty end;
    def ok: explode | all(. >= 32);
    (.ledgers // []) | to_entries[] | .key as $i | .value
    | select(type == "object")
    | select($only != "active" or .status != "retired")
    | (if (.id | type) == "string" and (.id | ok) then .id else "#\($i)" end) as $id
    | ((.paths | strs | select(ok) | ["P", .]),
       (.residual_paths | strs | select(ok) | ["R", .]),
       (if (.contracts | type) == "array" then .contracts[] | select(type == "object")
          | (.defined_in, .read_by) | strs | select(ok) | ["D", .] else empty end))
    | if .[0] != "D" and (.[1] | startswith("!"))
      then "\($i)\t\($id)\t\(.[0])\t1\t\(.[1][1:])"
      else "\($i)\t\($id)\t\(.[0])\t0\t\(.[1])" end
  ' "$1" > "$2" || _lg_die "jq failed (the registry's globs)"
}

# _lg_owner_map <paths-file> <out.tsv> [registry]: each path of the
# NUL-terminated list (in order) as "path<TAB>owner": a ledger id, "-" for
# none, or "multi:a,b" (registry order) for several. A retired ledger
# (status "retired") claims nothing. Otherwise a ledger claims a path
# that one of its ordinary `paths` globs matches; when no ledger does, the
# `residual_paths` globs are tried the same way. A ledger never claims a
# path one of its own "!" globs (in either list) matches. A newline in a
# path is written as \001. Bad globs are skipped (validate --registry
# reports them). [registry] defaults to _lg_registry's. One awk pass.
_lg_owner_map() {
  local paths="$1" out="$2" reg="${3:-}" rc=0
  if [ -z "$reg" ]; then reg=$(_lg_registry) || exit "$?"; fi
  _lg_scratch_name
  _lg_registry_globs "$reg" "$_LG_SN.globs" active
  tr '\n\000' '\001\n' < "$paths" > "$_LG_SN.lst" || _lg_die "cannot read the path list $paths"
  LC_ALL=C awk -v globs="$_LG_SN.globs" "$_LG_AWK_GLOB"'
    BEGIN {
      FS = "\t"
      while ((getline line < globs) > 0) {
        split(line, f, "\t"); g = f[5]
        if (f[3] == "D") continue
        if (!(f[1] in LID)) { LID[f[1]] = f[2]; ORD[++NL] = f[1] }
        k++
        if (!gx_add(k, g)) continue
        GL[k] = f[1]; GT[k] = (f[4] == "1") ? "N" : f[3]
      }
    }
    {
      gx_match($0)
      # A per-path stamp (NR) instead of clearing the arrays.
      for (j = 1; j <= GX_MN; j++) {
        k = GX_M[j]; l = GL[k]
        if (GT[k] == "N") NEG[l] = NR
        else if (GT[k] == "P") POS[l] = NR
        else RES[l] = NR
      }
      own = ""; n = 0
      for (i = 1; i <= NL; i++) {
        l = ORD[i]
        if (POS[l] == NR && NEG[l] != NR) { own = own (n++ ? "," : "") LID[l] }
      }
      if (n == 0) {
        for (i = 1; i <= NL; i++) {
          l = ORD[i]
          if (RES[l] == NR && NEG[l] != NR) { own = own (n++ ? "," : "") LID[l] }
        }
      }
      if (n == 0) own = "-"
      else if (n > 1) own = "multi:" own
      print $0 "\t" own
    }' "$_LG_SN.lst" > "$out" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot build the ownership map (awk rc $rc)"
}

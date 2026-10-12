# shellcheck shell=bash
# scripts/ledger/parse.sh — item paths, item parsing (working tree, index,
# commit) with a per-file parse cache, the frontmatter writers, and
# _lg_field. Sourced by lib.sh; uses doc-tools.sh's _hash_one, _hash_list,
# _tmp_beside, _replace_file and lib.sh's _lg_cfg, _lg_die.
#
# Paths are relative to the work tree's top level (the cwd: the dispatcher
# runs a ledger verb only there). Path lists are NUL-terminated files.
#
# A record (one JSON line per path):
#   {"path", "blob", "archived", "fm", "fm_errors", "h1", "first_para",
#    "resolution", "log"}
# — frontmatter.awk's record plus "blob" (the working copy's content hash
# "sha256:<hex>", or the git blob id) and "archived" (the path matches
# items.archive_globs). A path that cannot be parsed (missing at the rev,
# unreadable, or a name holding a newline) still gets a record: "blob" null,
# empty fields and one fm_errors entry saying why. One bad file never stops
# the others.
#
# Parse cache: $_LG_CACHE/parse/<sig>/{c-<sha256>|b-<oid>}.json — the
# content part of a record ({"fm",…,"log"}), keyed by the bytes it came
# from, so it is shared by every path, branch and worktree that holds those
# bytes. <sig> covers the parser (frontmatter.awk's own bytes) and the
# headings it reads, so a change to either uses a fresh directory. Entries
# are written to a temp dir and renamed into place (a reader never sees a
# partial one); an entry that does not read back as one record is parsed
# again. DOC_TOOLS_LEDGER_TRACE=1 prints "parse-miss <path>" to stderr for
# each path parsed (not read from the cache).
#
# Globs: items.globs and items.archive_globs are matched by git as
# ":(glob)" pathspecs — "*" stays within one path segment, "**/" spans
# directories.

_LG_BOM=$'\357\273\277'
_LG_PARSE_DIR=""     # $_LG_CACHE/parse/<sig>: _lg_parse_prep
_LG_PARSE_N=0        # scratch-name counter
_LG_AV=""            # _lg_awkv's result

# A JSON string escaper for the inline awk programs below (no gsub with a
# backslash in the replacement — awks disagree on it — and no split() on one
# character, which BWK awk also splits at newlines).
_LG_AWK_JS='
function rep(s, ch, by,   out, i) {
  out = ""
  while ((i = index(s, ch)) > 0) { out = out substr(s, 1, i - 1) by; s = substr(s, i + length(ch)) }
  return out s
}
function js(s,   out, i, k, c) {
  if (index(s, "\\")) s = rep(s, "\\", "\\\\")
  if (index(s, "\"")) s = rep(s, "\"", "\\\"")
  if (s ~ CTLRE) {
    s = rep(s, "\t", "\\t"); s = rep(s, "\n", "\\n"); s = rep(s, "\r", "\\r")
    if (s ~ CTLRE) {
      out = ""; k = length(s)
      for (i = 1; i <= k; i++) { c = substr(s, i, 1); out = out ((c in CTL) ? CTL[c] : c) }
      s = out
    }
  }
  return "\"" s "\""
}
function js_init(   i) {
  for (i = 1; i < 32; i++) CTL[sprintf("%c", i)] = sprintf("\\u%04x", i)
  CTLRE = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]"
  SOH = sprintf("%c", 1)
}
# The record of a path that could not be parsed (SOH in the name stands for
# a newline: see _lg_parse_lst).
function err_record(p, msg) {
  return "{\"path\":" js(rep(p, SOH, "\n")) ",\"blob\":null,\"archived\":false,\"fm\":{},\"fm_errors\":[" js(msg) "],\"h1\":null,\"first_para\":null,\"resolution\":null,\"log\":false}"
}
'

# _lg_awkv <value>: <value> for an awk -v assignment (which processes
# backslash escapes): backslashes doubled, into _LG_AV.
_lg_awkv() {
  _LG_AV=${1//\\/\\\\}
}

# A fresh scratch path prefix for one call.
_lg_scratch_name() {
  _LG_PARSE_N=$((_LG_PARSE_N + 1))
  _LG_SN="$_SCRATCH/lg-parse.$_LG_PARSE_N"
}

# --- Item paths ----------------------------------------------------------------

_LG_TREE_IDX=""      # a private index holding _LG_TREE_IDX_OID (_lg_tree_index)
_LG_TREE_IDX_OID=""

# _lg_tree_oid <rev>: the tree of a commit-ish into _LG_TREE; dies (2) on an
# option-like or unknown rev.
_lg_tree_oid() {
  case "$1" in
    -*|'') _lg_die "not a revision: '$1'" ;;
  esac
  _LG_TREE=$(git rev-parse --verify -q "$1^{tree}") || _lg_die "unknown revision: '$1'"
}

# _lg_tree_index <tree-oid>: a private index file holding that tree (git
# matches ":(glob)" pathspecs in an index, not in ls-tree), into _LG_TREE_IDX.
_lg_tree_index() {
  if [ "$_LG_TREE_IDX_OID" = "$1" ] && [ -n "$_LG_TREE_IDX" ]; then return 0; fi
  _LG_TREE_IDX="$_SCRATCH/lg-tree.index"
  GIT_INDEX_FILE="$_LG_TREE_IDX" git read-tree "$1" || _lg_die "git read-tree $1 failed"
  _LG_TREE_IDX_OID=$1
}

# _lg_globs_matching <src> <out> <config-filter>: the NUL-terminated paths
# at <src> matching the globs the filter yields (a list of strings). <src>:
#   worktree      tracked + untracked, .gitignore'd files left out
#   worktree-all  tracked + untracked, ignored files too (an archived check)
#   :             the index
#   <rev>         a commit-ish
_lg_globs_matching() {
  local src="$1" out="$2" filter="$3" g
  local specs=()
  _lg_scratch_name
  _lg_cfg "[$filter | if type == \"array\" then .[] else empty end | select(type == \"string\" and . != \"\")] | .[]" \
    > "$_LG_SN.globs"
  while IFS= read -r g; do
    specs+=(":(glob)$g")
  done < "$_LG_SN.globs"
  : > "$out"
  [ "${#specs[@]}" -gt 0 ] || return 0
  # git's stderr is kept for the error message: a glob whose directory does
  # not exist makes `--others` warn, which is not a failure.
  case "$src" in
    worktree)
      GIT_LITERAL_PATHSPECS=0 git ls-files -z --cached --others --exclude-standard -- "${specs[@]}" \
        > "$out" 2> "$_LG_SN.err" || _lg_globs_fail ;;
    worktree-all)
      GIT_LITERAL_PATHSPECS=0 git ls-files -z --cached --others -- "${specs[@]}" \
        > "$out" 2> "$_LG_SN.err" || _lg_globs_fail ;;
    :)
      GIT_LITERAL_PATHSPECS=0 git ls-files -z --cached -- "${specs[@]}" \
        > "$out" 2> "$_LG_SN.err" || _lg_globs_fail ;;
    *)
      _lg_tree_oid "$src"
      _lg_tree_index "$_LG_TREE"
      GIT_LITERAL_PATHSPECS=0 GIT_INDEX_FILE="$_LG_TREE_IDX" git ls-files -z --cached -- "${specs[@]}" \
        > "$out" 2> "$_LG_SN.err" || _lg_globs_fail ;;
  esac
}

_lg_globs_fail() {
  _lg_die "git ls-files failed matching the item globs: $(head -n 3 "$_LG_SN.err" 2>/dev/null)"
}

# _lg_item_paths <worktree|:|rev> <out>: the item files (items.globs and
# items.archive_globs), NUL-terminated, each once. worktree: tracked and
# untracked files that exist (a tracked file deleted from the work tree is
# not an item there); ":": the index; else the commit-ish's tree.
_lg_item_paths() {
  local src="$1" out="$2" raw p prev=""
  _lg_scratch_name
  raw="$_LG_SN.raw"
  _lg_globs_matching "$src" "$raw" '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?]'
  while IFS= read -r -d '' p; do
    [ "$p" != "$prev" ] || continue
    prev=$p
    if [ "$src" = worktree ] && [ ! -f "$p" ]; then continue; fi
    printf '%s\0' "$p"
  done < "$raw" > "$out"
}

# --- Parsing -------------------------------------------------------------------

# The parser's -v arguments (headings from the config) into _LG_PARSE_ARGS,
# the cache dir into _LG_PARSE_DIR (created).
_lg_parse_prep() {
  local rh lh sigf sig
  [ -z "$_LG_PARSE_DIR" ] || return 0
  rh=$(_lg_cfg '.resolution_heading // "## Resolution" | tostring')
  lh=$(_lg_cfg '.log_heading // "## Log" | tostring')
  _LG_PARSE_ARGS=()
  _lg_awkv "$rh"
  _LG_PARSE_ARGS+=(-v "resolution_heading=$_LG_AV")
  _lg_awkv "$lh"
  _LG_PARSE_ARGS+=(-v "log_heading=$_LG_AV")
  _LG_PARSE_ARGS+=(-v "bom=$_LG_BOM")
  sigf="$_SCRATCH/lg-parse.sig"
  { printf 'ledger-parse/1\n%s\n%s\n' "$rh" "$lh"; cat "$_LG_LIB/frontmatter.awk"; } > "$sigf" \
    || _lg_die "cannot read $_LG_LIB/frontmatter.awk"
  _hash_one "$sigf"
  [ -n "$_LG_CACHE" ] || _lg_die "internal: the ledger cache path is unset (_lg_init)"
  sig=${_HASH#sha256:}
  _LG_PARSE_DIR="$_LG_CACHE/parse/${sig:0:16}"
  mkdir -p "$_LG_PARSE_DIR" || _lg_die "cannot create the parse cache $_LG_PARSE_DIR"
}

# _lg_parse_lst <paths-file> <out>: the NUL list as lines; a newline inside a
# name becomes \001 (such a path gets an error record, never a parse).
_lg_parse_lst() {
  tr '\n\000' '\001\n' < "$1" > "$2" || _lg_die "cannot read the path list $1"
}

# _lg_parse_emit <manifest> <out> <misses>: one pass over the cache. For each
# manifest line ("<cache-key>\t<blob>\t<archived 0|1>\t<path>") whose entry
# reads back as one record, its record to <out>; the other lines (no entry,
# or one that is not a record) to <misses>.
_lg_parse_emit() {
  LC_ALL=C awk -v dir="$_LG_PARSE_DIR" -v miss="$3" "$_LG_AWK_JS"'
    BEGIN { js_init(); printf "" > miss }
    {
      t1 = index($0, "\t"); key = substr($0, 1, t1 - 1); r = substr($0, t1 + 1)
      t2 = index(r, "\t"); blob = substr(r, 1, t2 - 1); r = substr(r, t2 + 1)
      t3 = index(r, "\t"); arch = substr(r, 1, t3 - 1); p = substr(r, t3 + 1)
      f = dir "/" key ".json"
      e = ""
      if ((getline e < f) <= 0 || e !~ /^\{"fm":\{.*\}$/) { close(f); print > miss; next }
      close(f)
      print "{\"path\":" js(p) ",\"blob\":" js(blob) ",\"archived\":" (arch == "1" ? "true" : "false") "," substr(e, 2)
    }' "$1" > "$2" || _lg_die "cannot read the parse cache ($_LG_PARSE_DIR)"
}

# _lg_parse_finish <manifest> <errors> <out> <parser> <scratch>: the shared
# tail of both parsers. Emits the cached records; parses the misses with
# <parser> <misses> <tmpdir> <scratch> (it writes the entries into <tmpdir>),
# installs them and emits again — every record from the cache, so a warm run
# reads each entry once. Then appends the error records. Order: the
# manifest's, then the errors.
_lg_parse_finish() {
  local man="$1" errs="$2" out="$3" parser="$4" s="$5" tmp
  _lg_parse_emit "$man" "$out" "$s.miss"
  if [ -s "$s.miss" ]; then
    if [ "${DOC_TOOLS_LEDGER_TRACE:-}" = 1 ]; then
      LC_ALL=C awk '{ p = $0; for (i = 1; i <= 3; i++) p = substr(p, index(p, "\t") + 1); print "parse-miss " p }' \
        "$s.miss" >&2 || true
    fi
    tmp=$(mktemp -d "$_LG_PARSE_DIR/.new.XXXXXX") || _lg_die "cannot create a temp dir in $_LG_PARSE_DIR"
    "$parser" "$s.miss" "$tmp" "$s"
    _lg_parse_install "$tmp"
    _lg_parse_emit "$man" "$out" "$s.miss2"
    [ ! -s "$s.miss2" ] || _lg_die "the parse cache lost entries it was just given ($_LG_PARSE_DIR)"
  fi
  cat "$errs" >> "$out" || _lg_die "cannot write $out"
}

# _lg_parse_install <tmpdir>: rename the new entries into the cache dir (each
# rename is atomic: a reader never sees half an entry), then remove <tmpdir>.
_lg_parse_install() {
  local tmp="$1"
  ( cd "$tmp" && ls ) > "$tmp.names" || _lg_die "cannot list $tmp"
  if [ -s "$tmp.names" ]; then
    # Names are <c|b>-<hex>.json: no spaces, no quotes. $0: the cache dir.
    # shellcheck disable=SC2016  # the sh -c script expands its own args
    ( cd "$tmp" && xargs sh -c 'mv -f -- "$@" "$0"/' "$_LG_PARSE_DIR" < "$tmp.names" ) \
      || _lg_die "cannot install parse cache entries in $_LG_PARSE_DIR"
  fi
  rm -rf "$tmp" "$tmp.names"
}

# The working-copy parser for _lg_parse_finish: frontmatter.awk over the
# missed files (xargs: as few awk processes as argv allows).
_lg_parse_files() {
  local miss="$1" tmp="$2" s="$3" rc=0
  LC_ALL=C awk '{ k = substr($0, 1, index($0, "\t") - 1); p = $0; for (i = 1; i <= 3; i++) p = substr(p, index(p, "\t") + 1); print k "\t" p }' \
    "$miss" > "$s.keys" || _lg_die "cannot write $s.keys"
  # Relative names as ./name: awk would read "a=b" as an assignment.
  LC_ALL=C awk '{ p = $0; for (i = 1; i <= 3; i++) p = substr(p, index(p, "\t") + 1); if (substr(p, 1, 1) != "/") p = "./" p; print p }' \
    "$miss" | tr '\n' '\000' > "$s.argz" || _lg_die "cannot write $s.argz"
  LC_ALL=C xargs -0 awk -v mode=files -v keys="$s.keys" -v outdir="$tmp" "${_LG_PARSE_ARGS[@]}" \
    -f "$_LG_LIB/frontmatter.awk" < "$s.argz" || rc=$?
  [ "$rc" = 0 ] || _lg_die "frontmatter.awk failed on the working copies (rc $rc)"
}

# The blob parser for _lg_parse_finish: one git cat-file --batch over the
# missed blob ids. NUL bytes become \001 (the same size), so awk keeps the
# byte counts the headers give.
_lg_parse_batch() {
  local miss="$1" tmp="$2" s="$3" rc=0
  LC_ALL=C awk -F '\t' '!seen[$2]++ { print $2 }' "$miss" > "$s.oids" || _lg_die "cannot write $s.oids"
  git cat-file --batch < "$s.oids" | tr '\000' '\001' \
    | LC_ALL=C awk -v mode=batch -v outdir="$tmp" "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" \
    || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot parse the blobs (git cat-file --batch | frontmatter.awk: rc $rc)"
}

# _lg_parse_worktree <paths-file> <out.jsonl>: the working copies of the
# NUL-terminated paths, parsed (content-hash cache).
_lg_parse_worktree() {
  local paths="$1" out="$2" s
  _lg_parse_prep
  _lg_scratch_name
  s=$_LG_SN
  _lg_parse_lst "$paths" "$s.lst"
  _lg_globs_matching worktree-all "$s.archz" '.items.archive_globs // []'
  _lg_parse_lst "$s.archz" "$s.arch"
  # Readable paths in order (s.ok), error records for the rest (s.err).
  LC_ALL=C awk -v ok="$s.ok" -v err="$s.err" "$_LG_AWK_JS"'
    BEGIN { js_init(); printf "" > ok; printf "" > err }
    {
      if (index($0, SOH)) { print err_record($0, "the path holds a newline: not parsed") > err; next }
      x = ""
      if ((getline x < $0) < 0) { print err_record($0, "cannot read the file") > err; next }
      close($0)
      print > ok
    }' "$s.lst" || _lg_die "cannot check the item files"
  tr '\n' '\000' < "$s.ok" > "$s.okz" || _lg_die "cannot write $s.okz"
  _hash_list "$s.okz" "$s.hash"
  # The manifest: c-<hex>, the blob value, archived, path.
  LC_ALL=C awk -v hashes="$s.hash" -v arch="$s.arch" '
    BEGIN { while ((getline a < arch) > 0) A[a] = 1 }
    {
      if ((getline h < hashes) <= 0) { bad = 1; exit 3 }
      hex = h; sub(/^sha256:/, "", hex)
      printf "c-%s\t%s\t%s\t%s\n", hex, h, (($0 in A) ? 1 : 0), $0
    }
    END { if (bad) exit 3 }' "$s.ok" > "$s.man" || _lg_die "the content hashes do not line up with the paths"
  _lg_parse_finish "$s.man" "$s.err" "$out" _lg_parse_files "$s"
}

# _lg_parse_blobs <rev> <paths-file> <out.jsonl>: the paths as <rev> holds
# them — ":" for the index (stage 0), else a commit-ish — parsed with
# git cat-file --batch (blob-id cache). The blob ids come from one listing
# of the paths' directories (git ls-files -s / git ls-tree -r), not a
# lookup per path: <tree>:<path> scans the directory each time. A path
# <rev> lacks (or holds as a symbolic link, a submodule, or unmerged) gets
# an error record.
_lg_parse_blobs() {
  local rev="$1" paths="$2" out="$3" s where d imode=""
  local specs=()
  _lg_parse_prep
  _lg_scratch_name
  s=$_LG_SN
  if [ "$rev" = : ]; then
    where="the index"
    imode=1
    _lg_globs_matching : "$s.archz" '.items.archive_globs // []'
  else
    _lg_tree_oid "$rev"
    where=$rev
    _lg_globs_matching "$rev" "$s.archz" '.items.archive_globs // []'
  fi
  _lg_parse_lst "$paths" "$s.lst"
  _lg_parse_lst "$s.archz" "$s.arch"
  # The parseable paths (s.ok), error records for the rest (s.err), and the
  # pathspecs to list: each path's directory (a top-level name as itself).
  LC_ALL=C awk -v ok="$s.ok" -v err="$s.err" -v specs="$s.specs" "$_LG_AWK_JS"'
    BEGIN { js_init(); printf "" > ok; printf "" > err; printf "" > specs }
    {
      if (index($0, SOH)) { print err_record($0, "the path holds a newline: not parsed") > err; next }
      print > ok
      d = $0
      if (match(d, /.*\//)) d = substr(d, 1, RLENGTH)
      if (!(d in seen)) { seen[d] = 1; print d > specs }
    }' "$s.lst" || _lg_die "cannot sort the blob paths"
  while IFS= read -r d; do
    specs+=("$d")
  done < "$s.specs"
  : > "$s.lsz"
  if [ "${#specs[@]}" -gt 0 ]; then
    if [ "$rev" = : ]; then
      GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- "${specs[@]}" > "$s.lsz" \
        || _lg_die "git ls-files -s failed"
    else
      GIT_LITERAL_PATHSPECS=1 git ls-tree -r -z --full-name "$_LG_TREE" -- "${specs[@]}" > "$s.lsz" \
        || _lg_die "git ls-tree failed at $rev"
    fi
  fi
  _lg_parse_lst "$s.lsz" "$s.ls"
  _lg_awkv "$where"
  # "<mode> <oid> <stage>\t<path>" (ls-files -s) or "<mode> <type> <oid>\t<path>"
  # (ls-tree): the blob of each path, or why there is none.
  LC_ALL=C awk -v ls="$s.ls" -v arch="$s.arch" -v err="$s.err" -v where="$_LG_AV" -v index_mode="$imode" "$_LG_AWK_JS"'
    BEGIN {
      js_init()
      while ((getline a < arch) > 0) A[a] = 1
      while ((getline l < ls) > 0) {
        t = index(l, "\t"); p = substr(l, t + 1); split(substr(l, 1, t - 1), f, " ")
        if (index_mode) {
          if (f[3] != "0") { if (!(p in OID)) WHY[p] = "unmerged in the index"; continue }
          oid = f[2]; type = "blob"
        } else {
          oid = f[3]; type = f[2]
        }
        if (type != "blob") WHY[p] = "not a file (" type ") at " where
        else if (f[1] == "120000") WHY[p] = "a symbolic link at " where ": not parsed"
        else { OID[p] = oid; delete WHY[p] }
      }
    }
    {
      if ($0 in OID) printf "b-%s\t%s\t%s\t%s\n", OID[$0], OID[$0], (($0 in A) ? 1 : 0), $0
      else print err_record($0, ($0 in WHY) ? WHY[$0] : "not found at " where) >> err
    }' "$s.ok" > "$s.man" || _lg_die "cannot list the blobs at $where"
  _lg_parse_finish "$s.man" "$s.err" "$out" _lg_parse_batch "$s"
}

# --- Fields --------------------------------------------------------------------

# jq definitions for a logical field (config "fields"): lg_cands($cfg; $l)
# is its candidate names; lg_field($cfg; $l), applied to a record, is the
# value of the first candidate its fm has, or null. An unknown logical name
# is a jq error. For one jq program over many records (the index joins).
# shellcheck disable=SC2016  # jq source, not shell
_LG_JQ_FIELD='
def lg_cands($cfg; $l):
  ($cfg.fields[$l]) as $c
  | if $c == null then error("unknown ledger field: \($l)")
    elif ($c | type) == "array" then $c else [$c] end;
def lg_field($cfg; $l):
  . as $r | lg_cands($cfg; $l) as $cands
  | first(($cands[] | select(. as $n | ($r.fm // {}) | has($n)) | $r.fm[.]), null);
'

# _lg_field <logical> <record-json>: the value (compact JSON) of the first
# configured candidate name the record's fm has; null when none. Dies (2) on
# a logical name the config does not define.
_lg_field() {
  jq -nc --arg l "$1" --argjson r "$2" --slurpfile c "$_LG_CFG" \
    "$_LG_JQ_FIELD"' $r | lg_field($c[0]; $l)' 2>/dev/null \
    || _lg_die "cannot read field '$1' (not in the config's fields, or not a record)"
}

# --- Writers -------------------------------------------------------------------

# A frontmatter field name the parser reads back.
_lg_fm_field_ok() {
  case "$1" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
      _lg_die "not a frontmatter field name: '$1'" ;;
    [_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) _lg_die "not a frontmatter field name: '$1'" ;;
  esac
}

# _lg_fm_write <file> <op> <field> [value] [items] [n-items]: fm-write.awk,
# then the body appended byte for byte, installed with _replace_file (mode
# kept) unless nothing changed. Call in the main shell (_tmp_beside).
_lg_fm_write() {
  local file="$1" op="$2" field="$3" value="${4-}" items="${5-}" nitems="${6-0}"
  local st="$_SCRATCH/lg-fmw.status" blk="$_SCRATCH/lg-fmw.block" status="" n
  _lg_fm_field_ok "$field"
  [ -f "$file" ] || _lg_die "cannot edit $file: no such file"
  : > "$st"
  LG_FMW_FIELD="$field" LG_FMW_VALUE="$value" LG_FMW_ITEMS="$items" LG_FMW_NITEMS="$nitems" \
    LC_ALL=C awk -v op="$op" -v status="$st" -v bom="$_LG_BOM" -f "$_LG_LIB/fm-write.awk" \
    < "$file" > "$blk" || _lg_die "cannot edit the frontmatter of $file (fm-write.awk failed)"
  IFS= read -r status < "$st" || true
  case "$status" in
    unchanged) return 0 ;;
    unterminated) _lg_die "cannot edit $file: its frontmatter has no closing --- line" ;;
    "body "*|"prepend "*) ;;
    *) _lg_die "internal: fm-write.awk status '$status'" ;;
  esac
  _tmp_beside "$file"
  n=${status#* }
  case "$status" in
    "body "*) { cat "$blk" && tail -n +"$n" < "$file"; } > "$_TMP" ;;
    *) { cat "$blk" && tail -c +"$((n + 1))" < "$file"; } > "$_TMP" ;;
  esac || _lg_die "cannot write $_TMP"
  if cmp -s "$_TMP" "$file"; then
    rm -f "$_TMP"
    return 0
  fi
  _replace_file "$_TMP" "$file"
}

# _lg_fm_set <file> <field> <value>: set a scalar (a missing field is
# appended as the last frontmatter line; a file without frontmatter gets a
# block).
_lg_fm_set() {
  _lg_fm_write "$1" set "$2" "$3"
}

# _lg_fm_del <file> <field>: drop the field (every occurrence, with its
# list lines). A missing field leaves the file as it is.
_lg_fm_del() {
  _lg_fm_write "$1" del "$2"
}

# _lg_fm_list_add <file> <field> <item>: add <item> to a list field unless it
# is there: a block list gets one more "- item" line; a flow list is
# rewritten with the item last; a scalar becomes [scalar, item]; a missing
# field is appended as [item]. A field the parser rejected (a nested map, a
# duplicate) is not edited: dies (2).
_lg_fm_list_add() {
  local file="$1" field="$2" item="$3" rec res state count joined
  _lg_fm_field_ok "$field"
  [ -f "$file" ] || _lg_die "cannot edit $file: no such file"
  case "$item" in
    *$'\001'*) _lg_die "a list item cannot hold a \\001 byte" ;;
  esac
  _lg_parse_prep
  rec=$(LC_ALL=C awk -v path=x "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" < "$file") \
    || _lg_die "cannot parse $file"
  # state ("present" | "write" | "broken"), the count, the new list joined by
  # \001 — one jq.
  res=$(jq -j --arg f "$field" --arg item "$item" '
    if any(.fm_errors[]; startswith($f + ": ")) then "broken\n0\n"
    else (.fm[$f]) as $v
      | (if $v == null then [] elif ($v | type) == "array" then $v elif $v == "" then [] else [$v] end) as $cur
      | if any($cur[]; . == $item) then "present\n0\n"
        else ($cur + [$item]) as $new
          | "write\n\($new | length)\n" + ($new | join("\u0001"))
        end
    end' <<<"$rec") || _lg_die "cannot read the frontmatter of $file"
  state=${res%%$'\n'*}
  res=${res#*$'\n'}
  count=${res%%$'\n'*}
  joined=${res#*$'\n'}
  case "$state" in
    present) return 0 ;;
    broken) _lg_die "cannot edit $field in $file: the parser rejects it (see its fm_errors)" ;;
    write) ;;
    *) _lg_die "internal: list add state '$state'" ;;
  esac
  _lg_fm_write "$file" add "$field" "$item" "$joined" "$count"
}

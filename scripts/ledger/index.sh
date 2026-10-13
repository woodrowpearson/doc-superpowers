# shellcheck shell=bash
# scripts/ledger/index.sh — the ledger index: items joined with the
# registry, the doc-index (specs, plans, handoffs that link an item), git
# dates (renames chained), a local derived status, the contracts (registry
# + contracts adapter), each item's neighbours and re-check markers
# (relations.sh, defs.jq lg_relations), the PR-derived statuses (in review,
# merged: the PR adapter through the remote cache, the open heads, the
# base's claims); cached under $_LG_CACHE.
# Sourced by lib.sh; uses lib.sh's _lg_die, _lg_cfg, _lg_registry,
# _lg_doc_index, _lg_src_cat, parse.sh's parsers and helpers, glob.sh's
# _lg_globs_matching / _lg_glob_dirs, validate.sh's _lg_registry_findings,
# adapters.sh's _lg_adapter / _lg_adapter_path / _lg_remote_cache,
# relations.sh's _lg_trailers / _lg_msg_claims / _LG_AWK_TRAILER and
# doc-tools.sh's _hash_one / _hash_list.
#
# _lg_index [--rev <rev>|--staged] prints the path of the index file
# (schema ledger-index/1, references/ledger-index.schema.json) built from:
#   (default)  the working tree — tracked and untracked item files, the
#              working copies of the registry, doc-index, legacy map and docs
#   --staged   the index (stage 0) — the blobs a commit would record
#   --rev R    the commit R
# The merged config is the run's (_LG_CFG: docs/ledger/config.json of the
# working tree, unless the caller loaded another — ledger publish loads the
# base commit's with _lg_cfg_from_rev) in every mode. Dates come from HEAD's history (R's for --rev).
#
# The file is one JSON object written one item per line (the head through
# "items":[ on the first line, then each item, then the tail), so the
# re-check markers are written into the item lines without a second parse.
#
# Cache: $_LG_CACHE/index-<sha256>.json ($_LG_CACHE/rev/… for --rev, with
# its own retention), the hash over the schema, the
# code (every file of scripts/ledger/), the contracts adapter's output (or
# its failure: it runs on every call; adapters.sh), the mode, HEAD and the base oid
# (--rev: neither — its base is the commit itself, and HEAD has no part in
# it), the config, the shallow tag (_lg_ix_shallow: a deepened clone
# has more history behind the same commits), and — never by walking the
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
# from `git log --reverse --full-history --date=short --format='%H %ad'
# --name-status -M` over the item globs' directories (the same walk records
# every commit and change: re-check reads the last commit touching an item;
# the walks of the dated commit and of the base start in the background when
# a build begins, _lg_ix_prefetch, and overlap the parse)
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

# _lg_ix_shallow → _LG_SHALLOW: "" in a complete repository; in a shallow
# one (git rev-parse --git-path shallow exists), "s" + the first 16 hex of
# the sha256 of that file. Deepening (fetch --deepen / --unshallow) gives a
# boundary commit its parents, so every cache whose content is a walk of
# the history — the graph, the dates events, the index —
# carries it in its name or key. Once per shell.
_LG_SHALLOW_SET=""
_LG_SHALLOW=""
_lg_ix_shallow() {
  local f
  [ -z "$_LG_SHALLOW_SET" ] || return 0
  _LG_SHALLOW=""
  f=$(git rev-parse --git-path shallow 2>/dev/null) || f=""
  if [ -n "$f" ] && [ -s "$f" ]; then
    _hash_one "$f"
    _LG_SHALLOW="s${_HASH#sha256:}"
    _LG_SHALLOW=${_LG_SHALLOW:0:17}
  fi
  _LG_SHALLOW_SET=1
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
    g=$(_lg_cfg "(.doc_columns.$col // null) | if type == \"object\" then ((.globs // []) | length) else 0 end") || exit "$?"
    [ "$g" != 0 ] || continue
    _lg_globs_matching "$gsrc" "$s.$col.z" ".doc_columns.$col.globs"
    tr '\n\000' '\001\n' < "$s.$col.z" | LC_ALL=C awk -v col="$col" '{ print col "\t" $0 }' >> "$out" \
      || _lg_die "cannot list the $col globs"
  done
}

# --- Dates -------------------------------------------------------------------------

# The walk's output (after tr: one token per line) as event records.
# shellcheck disable=SC2016  # awk source
_LG_AWK_EVENTS='
    {
      t = $0
      if (st == "") {
        if (substr(t, 1, 1) == "\001") t = substr(t, 2)
        if (t == "") next
        if (t ~ /^[0-9a-f][0-9a-f]* [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
          d = substr(t, length(t) - 9); print "@"; print substr(t, 1, length(t) - 11); next
        }
        if (t == "A") { st = "A"; next }
        if (t ~ /^R[0-9]*$/) { st = "R1"; next }
        if (t ~ /^C[0-9]*$/) { st = "C1"; next }
        if (t == "M" || t == "T") { st = "M"; next }
        if (t == "D") { st = "D"; next }
        st = "X"; next
      }
      if (st == "A") { print "A"; print d; print t; st = ""; next }
      if (st == "R1") { old = t; st = "R2"; next }
      if (st == "R2") { print "R"; print d; print old; print t; st = ""; next }
      if (st == "C1") { st = "M"; next }
      if (st == "M") { print "M"; print t; st = ""; next }
      if (st == "D") { print "D"; print t; st = ""; next }
      st = ""
    }'

# _lg_ix_events_header <dirs-file> → _LG_EP_HEADER: the event file's first
# line for these directories.
# _lg_ix_events_plan <commit> <dirs-file>: what _lg_ix_events would do —
# _LG_EP_F (the cache file), _LG_EP_HEADER, _LG_EP_HIT (1: the cache file
# answers), _LG_EP_ANC (the cached ancestor to extend, or "") and
# _LG_EP_RANGE (the git log range).
_lg_ix_events_header() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  _lg_ix_shallow
  { printf 'ledger-dates/3\n'; cat "$1"; printf 'shallow %s\n' "$_LG_SHALLOW"; } > "$s.sig" || _lg_die "cannot write $s.sig"
  _hash_one "$s.sig"
  _LG_EP_HEADER="# ledger-dates/3 ${_HASH#sha256:}"
}
_lg_ix_events_plan() {
  local commit="$1" dirs="$2" s c oid first
  _lg_scratch_name
  s=$_LG_SN
  _lg_ix_events_header "$dirs"
  _LG_EP_F="$_LG_CACHE/dates-$commit.tsv"
  _LG_EP_HIT=0
  _LG_EP_ANC=""
  _LG_EP_RANGE=$commit
  first=""
  if [ -f "$_LG_EP_F" ]; then IFS= read -r first < "$_LG_EP_F" || true; fi
  if [ "$first" = "$_LG_EP_HEADER" ]; then
    _LG_EP_HIT=1
    return 0
  fi
  # shellcheck disable=SC2012  # cache names are dates-<hex>.tsv
  ls -t "$_LG_CACHE"/dates-*.tsv 2>/dev/null | head -n 8 > "$s.cached" || true
  while IFS= read -r c; do
    oid=${c##*/dates-}
    oid=${oid%.tsv}
    [ "$oid" != "$commit" ] || continue
    first=""
    { IFS= read -r first < "$c"; } 2>/dev/null || true
    [ "$first" = "$_LG_EP_HEADER" ] || continue
    if git merge-base --is-ancestor "$oid" "$commit" 2>/dev/null; then
      _LG_EP_ANC=$oid
      _LG_EP_RANGE="$oid..$commit"
      break
    fi
  done < "$s.cached"
}

# The walk itself (git log -z: "<id> <date>\0\n<status>\0<path>[\0<path>]\0…").
# --full-history: a merge TREESAME to one parent must not hide the other
# parent's commits — a map extended from that side branch's tip has them.
# _lg_ix_events_git <range> <dirs-file> <log> <err>
_lg_ix_events_git() {
  local d
  local specs=()
  while IFS= read -r d; do
    specs+=("$d")
  done < "$2"
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --reverse --full-history --date=short \
    --format='%H %ad' --name-status -M -z "$1" -- ${specs[@]+"${specs[@]}"} > "$3" 2> "$4"
}

# _lg_ix_prefetch <commit> <dirs-file>: start, in the background, the walk a
# later _lg_ix_events <commit> <dirs-file> needs (nothing when its cache
# answers), so it overlaps the parse; _lg_ix_events waits for it. Slots:
# _LG_PF_N, _LG_PF_{C,A,R,P,L,E}_<i> (commit, ancestor, range, pid, log, err).
_LG_PF_N=0
_lg_ix_prefetch() {
  local commit="$1" i s
  i=1
  while [ "$i" -le "$_LG_PF_N" ]; do
    eval "[ \"\$_LG_PF_C_$i\" != \"\$commit\" ]" || return 0
    i=$((i + 1))
  done
  _lg_ix_events_plan "$commit" "$2"
  [ "$_LG_EP_HIT" = 0 ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  _LG_PF_N=$((_LG_PF_N + 1))
  i=$_LG_PF_N
  printf -v "_LG_PF_C_$i" '%s' "$commit"
  printf -v "_LG_PF_A_$i" '%s' "$_LG_EP_ANC"
  printf -v "_LG_PF_R_$i" '%s' "$_LG_EP_RANGE"
  printf -v "_LG_PF_L_$i" '%s' "$s.pflog"
  printf -v "_LG_PF_E_$i" '%s' "$s.pferr"
  # Its own stdout and stderr are files: the background shell must not hold
  # the caller's $(…) pipe.
  _lg_ix_events_git "$_LG_EP_RANGE" "$2" "$s.pflog" "$s.pferr" < /dev/null > /dev/null 2>&1 &
  printf -v "_LG_PF_P_$i" '%s' "$!"
}

# _lg_ix_events <commit> <dirs-file> → _LG_EVENTS: the cached event file of
# <commit>, one field per line (a newline in a name as \001), in history
# order (oldest first): "@" <commit id> at each commit, then its changes —
# "A" date path / "R" date old new (the dates) and "M" path (modified, type
# changed, or a copy's new path) / "D" path (the touches: re-check reads the
# last commit touching an item, relations.sh). First line
# "# ledger-dates/3 <sig>". Built cold or by extending the newest cached
# ancestor's (a prefetched walk, _lg_ix_prefetch, is used when there is one).
_lg_ix_events() {
  local commit="$1" dirs="$2" s f tmp range anc="" i pid="" rc=0 log err c
  _lg_scratch_name
  s=$_LG_SN
  log="$s.log"
  err="$s.err"
  i=1
  while [ "$i" -le "$_LG_PF_N" ]; do
    if eval "[ \"\$_LG_PF_C_$i\" = \"\$commit\" ] && [ -n \"\$_LG_PF_P_$i\" ]"; then
      eval "pid=\$_LG_PF_P_$i anc=\$_LG_PF_A_$i range=\$_LG_PF_R_$i log=\$_LG_PF_L_$i err=\$_LG_PF_E_$i"
      printf -v "_LG_PF_P_$i" '%s' ""
      break
    fi
    i=$((i + 1))
  done
  if [ -z "$pid" ]; then
    _lg_ix_events_plan "$commit" "$dirs"
    if [ "$_LG_EP_HIT" = 1 ]; then
      _lg_ix_trace "dates-hit"
      _LG_EVENTS=$_LG_EP_F
      return 0
    fi
    anc=$_LG_EP_ANC
    range=$_LG_EP_RANGE
  else
    # The plan the prefetch ran; the header (the same dirs) for the file.
    _lg_ix_events_header "$dirs"
  fi
  f="$_LG_CACHE/dates-$commit.tsv"
  tmp=$(mktemp "$_LG_CACHE/.dates.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  if [ -n "$anc" ]; then
    _lg_ix_trace "dates-extend $anc"
    cp -- "$_LG_CACHE/dates-$anc.tsv" "$tmp" || { rm -f "$tmp"; _lg_die "cannot copy the cached dates of $anc"; }
  else
    _lg_ix_trace "dates-cold"
    printf '%s\n' "$_LG_EP_HEADER" > "$tmp" || { rm -f "$tmp"; _lg_die "cannot write $tmp"; }
  fi
  if [ -n "$pid" ]; then
    wait "$pid" || rc=$?
  else
    _lg_ix_events_git "$range" "$dirs" "$log" "$err" || rc=$?
  fi
  [ "$rc" = 0 ] || { rm -f "$tmp"; _lg_die "git log failed: $(head -n 3 "$err" 2>/dev/null)"; }
  # After tr, one token per line (the first status of a commit, or the next
  # commit line after one with no changes, led by \001).
  tr '\n\000' '\001\n' < "$log" | LC_ALL=C awk "$_LG_AWK_EVENTS" >> "$tmp" \
    || { rm -f "$tmp"; _lg_die "cannot read the git history of the items"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _lg_die "cannot install $f"; }
  # The newest 5 maps are kept.
  # shellcheck disable=SC2012  # cache names are dates-<hex>.tsv
  ls -t "$_LG_CACHE"/dates-*.tsv 2>/dev/null | tail -n +6 | while IFS= read -r c; do rm -f "$c"; done
  _LG_EVENTS=$f
}

# _lg_ix_graph <commit> → _LG_GRAPH: `git rev-list --parents <commit>`
# ("<id> <parent>…" per commit reachable from it), cached as
# $_LG_CACHE/graph-<commit>[.<shallow>].txt (a fact about the commit — in a
# shallow repository, about the commit and .git/shallow: _lg_ix_shallow;
# the newest 3 kept).
_lg_ix_graph() {
  local c="$1" f tmp s
  _lg_ix_shallow
  f="$_LG_CACHE/graph-$c${_LG_SHALLOW:+.$_LG_SHALLOW}.txt"
  if [ -f "$f" ]; then
    touch -c "$f" 2>/dev/null || true
    _LG_GRAPH=$f
    return 0
  fi
  _lg_scratch_name
  s=$_LG_SN
  mkdir -p -- "$_LG_CACHE" 2>/dev/null || _lg_die "cannot create $_LG_CACHE"
  tmp=$(mktemp "$_LG_CACHE/.graph.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  git rev-list --parents "$c" > "$tmp" 2> "$s.err" || { rm -f "$tmp"; _lg_die "git rev-list failed: $(head -n 3 "$s.err")"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _lg_die "cannot install $f"; }
  # shellcheck disable=SC2012  # cache names are graph-<hex>.txt
  ls -t "$_LG_CACHE"/graph-*.txt 2>/dev/null | tail -n +4 | while IFS= read -r tmp; do rm -f "$tmp"; done
  _LG_GRAPH=$f
}

# _lg_ix_events_base <base> <dirs-file> <dated-commit|""> <graph> →
# _LG_EVENTS: the base's event file. Its cache, or the extension of a cached
# ancestor, as _lg_ix_events; else, when the dated commit (HEAD) has its
# map, derived from it without a second walk of the whole history ("dates-
# derive <commit>"): the dated commit's records of the commits the base
# reaches (<graph>: every commit reachable from the base), then a walk of
# <dated>..<base> only. The records are the same a walk of the base lists
# (whether git lists a commit, and its changes, do not depend on where the
# walk starts); the order is the extension's — the common commits in the
# dated walk's order, then the base's own — which never puts a commit after
# one of its descendants.
_lg_ix_events_base() {
  local B="$1" dirs="$2" H="$3" graph="$4" hf first tmp f s rc=0 c
  _lg_ix_events_plan "$B" "$dirs"
  if [ "$_LG_EP_HIT" = 1 ] || [ -n "$_LG_EP_ANC" ] || [ -z "$H" ] || [ "$H" = "$B" ]; then
    _lg_ix_events "$B" "$dirs"
    return 0
  fi
  hf="$_LG_CACHE/dates-$H.tsv"
  first=""
  if [ -f "$hf" ]; then IFS= read -r first < "$hf" || true; fi
  if [ "$first" != "$_LG_EP_HEADER" ]; then
    _lg_ix_events "$B" "$dirs"
    return 0
  fi
  _lg_ix_trace "dates-derive $H"
  _lg_scratch_name
  s=$_LG_SN
  f="$_LG_CACHE/dates-$B.tsv"
  tmp=$(mktemp "$_LG_CACHE/.dates.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  LC_ALL=C awk -v graph="$graph" '
    BEGIN { while ((getline l < graph) > 0) { t = index(l, " "); G[t ? substr(l, 1, t - 1) : l] = 1 } }
    NR == 1 { print; next }
    {
      if ($0 == "@") { getline c; keep = (c in G); if (keep) { print "@"; print c }; next }
      n = ($0 == "A") ? 2 : ($0 == "R") ? 3 : 1
      k = $0
      if (keep) print k
      for (i = 1; i <= n; i++) { getline x; if (keep) print x }
    }' "$hf" > "$tmp" || { rm -f "$tmp"; _lg_die "cannot derive the base's history from $H"; }
  _lg_ix_events_git "$H..$B" "$dirs" "$s.log" "$s.err" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$tmp"; _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"; }
  tr '\n\000' '\001\n' < "$s.log" | LC_ALL=C awk "$_LG_AWK_EVENTS" >> "$tmp" \
    || { rm -f "$tmp"; _lg_die "cannot read the git history of the items"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _lg_die "cannot install $f"; }
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
        } else if (k == "@" || k == "M" || k == "D") {
          getline x < ev
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

# The shared jq definitions (scripts/ledger/defs.jq: the derived-status
# labels, the display helpers): every program that uses them starts with
# this and runs as `jq -L "$_LG_LIB" …` — the index writes the labels
# (lg_item below), query.sh and the renderers read and display them.
_LG_JQ_INCLUDE='include "defs"; '

# jq: the item record → the index item; the index object. Inputs (slurped):
# $c config, $reg registry, $di doc-index, $lgy legacy, $fin finalized,
# $recs parse records, $dates {"p","d"}, $docs {"c","d","i"} / {"s","v"}.
# shellcheck disable=SC2016  # jq source
_LG_JQ_INDEX_DEFS="$_LG_JQ_INCLUDE"'
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
# lg_item_rel($F; $CT; $EX), applied to a parse record: the fields the
# relations read (defs.jq lg_relations; the background relations pass) —
# lg_item takes the same values from it.
def lg_item_rel($F; $CT; $EX):
  (.fm // {}) as $fm
  | (($fm | lg_fv($F; "status")) | lg_str) as $status
  | {path: .path,
     key: (($fm | lg_fv($F; "key")) | lg_str),
     status: $status,
     class: ($status | lg_class($CT; $EX)),
     changes: (($fm | lg_fv($F; "changes")) | lg_list),
     consumes: (($fm | lg_fv($F; "consumes")) | lg_list),
     relates: [($fm | lg_fv($F; "relates")) | lg_list | .[] | split(":") as $p
               | if ($p | length) < 2 then {kind: null, key: .}
                 else {kind: $p[0], key: ($p[1:] | join(":") | ltrimstr(" "))} end],
     aliases: (($fm | lg_fv($F; "aliases")) | lg_list)};
def lg_item($F; $CT; $EX; $D; $L; $S; $DI; $terms):
  . as $r
  | ($r.fm // {}) as $fm
  | lg_item_rel($F; $CT; $EX) as $R
  | $R.status as $status
  | $R.class as $class
  | (($fm | lg_fv($F; "owed")) | lg_str) as $owed
  | (($fm | lg_fv($F; "superseded_by")) | lg_str) as $sup
  | (($fm | lg_fv($F; "date")) | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ]|$)") then .[0:10] else null end) as $fd
  | ($L[$r.path]) as $l
  | (if $l == null then {spec: [], plan: [], handoff: []}
     else {spec: (($l.spec // []) | unique), plan: (($l.plan // []) | unique), handoff: (($l.handoff // []) | unique)} end) as $docs
  | (if $docs.plan == [] then [] else [$docs.plan[] | select(lg_terminal_doc(.; $S; $DI; $terms) | not)] end) as $open_plans
  | {path: $r.path,
     archived: ($r.archived == true),
     key: $R.key,
     ledger: (($fm | lg_fv($F; "ledger")) | lg_str),
     status: $status,
     class: $class,
     severity: (($fm | lg_fv($F; "severity")) | lg_str),
     date: ($fd // $D[$r.path]),
     summary: (($fm | lg_fv($F; "summary")) | lg_str),
     changes: $R.changes,
     consumes: $R.consumes,
     relates: $R.relates,
     superseded_by: $sup,
     owed: $owed,
     aliases: $R.aliases,
     paths: (($fm | lg_fv($F; "paths")) | lg_list),
     h1: $r.h1,
     first_para: $r.first_para,
     resolution: $r.resolution,
     docs: $docs,
     derived: (lg_status_labels as $SL
               | if $sup != null and $class == "closed" then {status: $SL.superseded, detail: $sup}
               elif $class == "wontfix" then {status: $SL.wontfix, detail: null}
               elif $class == "closed" then {status: $SL.closed, detail: null}
               elif $class == "fixed" then
                 (if $owed != null then {status: $SL.merged, detail: $owed} else {status: $SL.shipped, detail: null} end)
               elif ($open_plans | length) > 0 then {status: $SL.planned, detail: $open_plans[0]}
               elif ($docs.spec | length) > 0 then {status: $SL.specd, detail: $docs.spec[0]}
               else {status: $SL.not_started, detail: null} end),
     pr: null,
     inflight: [],
     neighbours: null,
     recheck_after: [],
     fm_errors: ($r.fm_errors // [])};
# lg_pr_apply($prs; $pcl; $bcl; $fmr), applied to the items (path-sorted):
# the PR-derived statuses and .pr (see "PR data, head claims, base claims"
# above). $prs the lines of the PR adapter; $pcl "<n>\t<kind>\t<value>" lines
# (_lg_ix_pr_claims); $bcl the base claims file ("<kind>\t<value>" after a
# "# " header); $fmr the former-path pairs ("<former>\n<item>", \u0001 for
# a newline in a name). A claims value names keys or aliases (split on
# commas and blanks, case-insensitive); a claims_by_path value or a changed
# name names an item path or a former path ("./" dropped).
def lg_pr_apply($prs; $pcl; $bcl; $fmr):
  . as $its
  | if ($pcl == "") and ($bcl | test("\n[^#\n]") | not) and ($bcl | test("^[^#\n]") | not) then $its
    else
      lg_obj($its[] | .path as $p | ([.key] + (.aliases // []))[] | strings | lg_lower | {(.): $p}) as $KM
      | lg_obj($its[] | {(.path): .path}) as $PM
      | ($fmr | split("\n")) as $F
      | lg_obj(range(0; ($F | length) - 1; 2) as $i | select($F[$i] != "")
               | {($F[$i] | gsub("\u0001"; "\n")): ($F[$i + 1] | gsub("\u0001"; "\n"))}) as $FM
      | def paths($k; $v):
          if $k == "claims" then [$v | splits("[,\\s]+") | select(. != "") | lg_lower | $KM[.] // empty]
          else ($v | gsub("\u0001"; "\n") | ltrimstr("./")) as $q | [$PM[$q] // $FM[$q] // empty] end;
        lg_obj($prs[] | select(.number != null) | {(.number | tostring): .}) as $PRN
        | lg_obj($bcl | split("\n")[] | select(. != "" and (startswith("# ") | not))
                 | index("\t") as $t | select($t != null) | paths(.[0:$t]; .[$t + 1:])[] | {(.): true}) as $BASE
        # A merged PR counts by its trailers only; a changed file claims
        # for an open PR (in review).
        | (lg_lists($pcl | split("\n")[] | select(. != "") | split("\t") | select(length >= 3)
                    | .[0] as $n
                    | select(.[1] != "file" or ($PRN[$n].state // "") == "open")
                    | paths(if .[1] == "file" then "path" else .[1] end; .[2:] | join("\t"))[] | {k: ., v: $n})
           | map_values(unique)) as $PC
        | lg_status_labels as $SL
        | [$its[]
           | ([($PC[.path] // [])[] | $PRN[.] // empty]) as $P
           | ([$P[] | select(.state == "open")] | sort_by(.number | tonumber? // 0) | last) as $op
           | ([$P[] | select(.state == "merged")] | sort_by(.number | tonumber? // 0) | last) as $mp
           | if $op == null and $mp == null and ($BASE[.path] | not) then .
             else
               # .pr names the PR behind the status shown: the merged one
               # for "merged · owed", else the open one, else the merged one.
               ((.class == "open" or .class == "unknown") and ($BASE[.path] or $mp != null)) as $merged
               | .pr = ((if $merged then ($mp // $op) else ($op // $mp) end)
                        | if . == null then null else {number, url, state} end)
               | if .class == "open" or .class == "unknown" then
                   (if $merged then .derived = {status: $SL.merged, detail: (.owed // "closing")}
                    elif $op != null then .derived = {status: $SL.in_review, detail: ($op.number | tostring)}
                    else . end)
                 else . end
             end]
    end;
'
# shellcheck disable=SC2016  # jq source
_LG_JQ_INDEX='
$c[0] as $cfg
| lg_fields($cfg) as $F
| lg_class_terms($cfg) as $CT
| (reduce ($CT | reverse)[] as $x ({}; .[$x.t] = $x.c)) as $EX
| ($di[0].docs // {}) as $DI
| lg_obj($dates[] | {(.p): .d}) as $D
| (lg_lists($docs[] | select(has("i")) | {k: .i, v: {c, d}}) | map_values(lg_lists(.[] | {k: .c, v: .d}))) as $L
| lg_obj($docs[] | select(has("s")) | {(.s): .v}) as $S
| ([$recs[] | lg_item($F; $CT; $EX; $D; $L; $S; $DI; $terms)] | sort_by(.path) | lg_pr_apply($prs; $pcl; $bcl; $fmr)) as $items
| ($ctr[0] // []) as $CTR
| ($cre | split("\n") | map(select(. != "") | split("\t") | select(length == 3) | {id: .[0], dir: .[1], re: .[2]})) as $CRE
# The index, one item per line (index.sh writes the neighbours of each
# item — _LG_JQ_REL, computed meanwhile — and its re-check markers there):
# the head through "items":[, the items, the tail from ],"legacy".
| ({schema: $schema,
    built: {head: (if $head == "" then null else $head end),
            base: (if $base == "" then null else $base end),
            inputs_hash: $hash,
            mode: $mode,
            rev: (if $rev == "" then null else $rev end),
            registry_findings: $rf,
            contracts_error: (if $cerr == "" then null else $cerr end)},
    ledgers: $reg[0].ledgers,
    contracts: $CTR,
    path_contracts: lg_path_contracts($items; $CRE)} | tojson | .[0:-1] + ",\"items\":["),
  ($items | length) as $n
  | ($items | to_entries[] | (.value | tojson) + (if .key < $n - 1 then "," else "" end)),
    ("]," + ({legacy: $lgy[0], finalized: $fin[0]} | tojson | .[1:]))
'

# The relations pass (run in the background beside the dates and docs
# joins): the items' relation fields (lg_item_rel), sorted by path as the
# index sorts them; lg_relations. Prints the re-check input's line count,
# its lines (relations.sh _lg_ix_recheck), then each item's neighbours as
# JSON, one line per item in index order.
# shellcheck disable=SC2016  # jq source
_LG_JQ_REL='
$c[0] as $cfg
| lg_fields($cfg) as $F
| lg_class_terms($cfg) as $CT
| lg_obj(($CT | reverse)[] | {(.t): .c}) as $EX
| ([$recs[] | lg_item_rel($F; $CT; $EX)] | sort_by(.path)) as $its
| lg_relations($its; ($ctr[0] // [])) as $REL
| ($REL.tab | length), $REL.tab[], ($its[] | $REL.nb[.path] | tojson)
'

# The contracts (design §G): the registry's (ledgers[].contracts[], with
# their ledger) and the contracts adapter's list, one per id, sorted by id —
# an id in both is one contract: the registry's ledger, defined_in and
# title win, the adapter's fill only what the registry leaves empty. A
# registry contract whose id is not <kind>:<name> is left out (validate
# --registry reports it). Inputs: $reg (slurped registry), $adc (slurped
# adapter lines), $re (_LG_CONTRACT_RE).
# shellcheck disable=SC2016  # jq source
_LG_JQ_CONTRACTS='
def lg_ct_str: if type == "string" and . != "" then . else null end;
def lg_ct_list: if type == "array" then [.[] | strings | select(. != "")] else [] end;
[ ($reg[0].ledgers // [])[] | objects | (.id | lg_ct_str) as $lid
  | (.contracts // []) | if type == "array" then .[] else empty end | objects
  | select(.id | type == "string" and test($re))
  | {id, ledger: $lid, defined_in: (.defined_in | lg_ct_list), title: (.title | lg_ct_str)} ] as $R
| [ $adc[] | {id, ledger: (.ledger | lg_ct_str), defined_in: (.defined_in | lg_ct_list), title: (.title | lg_ct_str)} ] as $A
| (reduce $A[] as $a ({}; if has($a.id) then . else .[$a.id] = $a end)) as $AM
| (reduce $R[] as $r ({}; if has($r.id) then . else .[$r.id] = $r end)) as $RM
| [ ($RM[] | . as $r | ($AM[$r.id] // {}) as $a
     | {id: $r.id, ledger: ($r.ledger // $a.ledger // null),
        defined_in: (if ($r.defined_in | length) > 0 then $r.defined_in else ($a.defined_in // []) end),
        title: ($r.title // $a.title // null)}),
    ($AM[] | select($RM[.id] == null)) ]
| sort_by(.id)
'

# _lg_ix_adapter_contracts <out> <err>: the contracts adapter's validated
# list (adapters.sh) into <out>; when it fails, its message into <err> and
# <out> empty — fatal (2) when the caller set _LG_IX_NEED_CONTRACTS=1 (a
# verb that shows relations), else recorded in built.contracts_error.
_lg_ix_adapter_contracts() {
  local out="$1" err="$2" rc=0
  : > "$err"
  _lg_adapter contracts list > "$out" 2> "$err" || rc=$?
  case "$rc" in
    0) : > "$err" ;;
    2)
      : > "$out"
      if [ "${_LG_IX_NEED_CONTRACTS:-}" = 1 ]; then _lg_die "$(head -n 1 "$err")"; fi ;;
    *) _lg_die "internal: _lg_adapter rc $rc" ;;
  esac
}

# _lg_ix_contracts <registry> <adapter-lines> <out.json> <cre>: the merged
# contract list (_LG_JQ_CONTRACTS) into <out.json>; <cre>: one
# "<id>\t<dir>\t<ERE>" line per defined_in glob (glob.sh's grammar; a glob
# it rejects, or one holding a control character, is left out — validate
# --registry reports it).
_lg_ix_contracts() {
  local reg="$1" adc="$2" out="$3" cre="$4"
  jq -n -c --slurpfile reg "$reg" --slurpfile adc "$adc" --arg re "$_LG_CONTRACT_RE" "$_LG_JQ_CONTRACTS" > "$out" \
    || _lg_die "jq failed (the contracts)"
  jq -r '.[] | .id as $i | .defined_in[] | select(test("[[:cntrl:]]") | not) | "\($i)\u0001\(.)"' "$out" > "$cre.in" \
    || _lg_die "jq failed (the contract globs)"
  LC_ALL=C awk "$_LG_AWK_GLOB"'
    { t = index($0, "\001"); id = substr($0, 1, t - 1); g = substr($0, t + 1)
      re = glob_ere(g); if (re == "") next
      print id "\t" glob_dir(g) "\t" re }' "$cre.in" > "$cre" || _lg_die "cannot read the contract globs"
}

# _lg_ix_valid <file>: the file is a whole index of this schema — it starts
# with the schema and its last line is the tail (],"legacy":… ending in }),
# so a file cut anywhere, even between two lines, is rebuilt.
_lg_ix_valid() {
  local f="$1" pre="" last
  [ -f "$f" ] || return 1
  IFS= read -r -n 27 pre < "$f" 2>/dev/null || true
  [ "$pre" = '{"schema":"ledger-index/1",' ] || return 1
  last=$(tail -n 1 "$f" 2>/dev/null) || return 1
  # The tail is ],"legacy":{…},"finalized":{…}} — finalized.json maps
  # strings to strings, so a tail cut short never ends in }} again.
  case "$last" in
    '],"legacy":'*',"finalized":'*'}}') return 0 ;;
  esac
  return 1
}

# --- Pruning -------------------------------------------------------------------------

# _lg_ix_prune <dir>: in <dir> ($_LG_CACHE for the working tree and
# --staged, $_LG_CACHE/rev for --rev: each keeps its own newest, so a
# publish never evicts the working tree's index) keep the newest 3 index
# files by mtime (a hit touches its file) and their .refs — and any
# modified in the last 10 minutes; at most
# once a day: sweep parse temp dirs older than an hour, other parsers'
# cache dirs untouched for 14 days, and parse entries older than 14 days
# that no kept index references.
_lg_ix_prune() {
  local ixdir="$1" stamp="$_LG_CACHE/prune.stamp" s f d
  _lg_scratch_name
  s=$_LG_SN
  # shellcheck disable=SC2012  # cache names are index-<hex>.json
  ls -t "$ixdir"/index-*.json 2>/dev/null | tail -n +4 > "$s.old" || true
  while IFS= read -r f; do
    # Never one written or used in the last 10 minutes (a concurrent run
    # may be about to read it).
    if [ -n "$(find "$f" -mmin -10 2>/dev/null)" ]; then continue; fi
    rm -f "$f" "${f%.json}.refs"
  done < "$s.old"
  if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then return 0; fi
  : > "$stamp" || return 0
  find "$_LG_CACHE/parse" -mindepth 2 -maxdepth 2 -name '.new.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  find "$_LG_CACHE" "$_LG_CACHE/rev" -maxdepth 1 \( -name '.index.*' -o -name '.dates.*' -o -name '.graph.*' -o -name '.blob-sha256.*' \) -mmin +60 \
    -exec rm -f {} + 2>/dev/null || true
  for d in "$_LG_CACHE"/parse/*; do
    [ -d "$d" ] && [ "$d" != "$_LG_PARSE_DIR" ] || continue
    if [ -n "$(find "$d" -maxdepth 0 -mtime +14 2>/dev/null)" ]; then rm -rf "$d"; fi
  done
  cat "$_LG_CACHE"/index-*.refs "$_LG_CACHE"/rev/index-*.refs > "$s.refs" 2>/dev/null || true
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

# --- PR data, head claims, base claims (design §E.1, §G) ---------------------------
#
# Derived statuses beyond the item's own fields (lg_pr_apply in the join):
#   merged · owed: <owed>  an open item claimed by a claims or
#       claims-by-path trailer — a message line of a commit the base
#       reaches carries a trailers.claims trailer naming its key or alias,
#       or a trailers.claims_by_path trailer naming its path (or a former
#       path) — or by such a trailer in <base>..<head> of a merged PR whose
#       head ref is still here (a squash merge leaves the branch's own
#       commits off the base). A merged PR's file edits do not count.
#       <owed> is the item's owed field, else "closing" (what is left:
#       closing the item).
#   in review #<n>  an open item that an open PR's head claims: the head is
#       refs/remotes/<keys.remote>/<head> when that ref exists here (index
#       builds never fetch; a head without one is skipped and counted on
#       stderr), and it claims the item when a commit in <base>..<head>
#       carries a claims / claims_by_path line naming it or changes its
#       file. Of several PRs, the highest number. A cross-repository PR
#       ("cross": a fork's branch) is never resolved through a same-named
#       branch of the remote: it is counted on stderr.
# The item's .pr is {number, url, state} of the PR behind the status shown:
# for "merged · owed", the merged PR that claims it (the highest number),
# else the open one; otherwise the open one, else the merged one; else null.
#
# PR data come from config adapters.pr (adapters.sh) through the remote
# cache (_lg_remote_cache, cache.remote_ttl_minutes). Unconfigured: no PR
# data, no warning. The adapter failing: the last good copy, and one
# stderr note "PR data as of <UTC> (<age> old) — …" (views: "PR data as of
# …" in the header); with no copy, no PR-derived state ("—" in views'
# headers, the PR column empty), one stderr warning "PR data unavailable
# …", and the verb still exits 0 — except under _LG_REMOTE_FORCE=1
# (--refresh, publish), where it is exit 2. The key of the index covers
# the PR data (the copy's data, not its fetch time), each open PR head's
# resolved oid (_lg_ix_pr_prepare). DOC_TOOLS_LEDGER_OFFLINE=1: the
# adapter never runs — a copy past its TTL serves ("PR data as of …",
# pr_data.state offline), none is the "—" path; --refresh and publish
# exit 2.

# _lg_ix_pr_note <text>: the run's one note on stderr ("ledger: …"), printed
# once per run however many indexes it builds: <text> (the PR data's), then
# the in-flight scan's ($_SCRATCH/lg-ifl.note, inflight.sh _lg_ifl_note —
# written before the index is built), "; " between.
_lg_ix_pr_note() {
  local x=""
  [ ! -f "$_SCRATCH/lg-pr.noted" ] || return 0
  # Held while the in-flight scan runs beside the build (inflight.sh
  # _lg_ifl_prepare_bg): its wait prints both.
  if [ -n "${_LG_NOTE_DEFER:-}" ]; then
    printf '%s\n' "$1" > "$_SCRATCH/lg-pr.held" || _lg_die "cannot hold the PR note"
    return 0
  fi
  if [ -s "$_SCRATCH/lg-ifl.note" ]; then { IFS= read -r x < "$_SCRATCH/lg-ifl.note"; } 2>/dev/null || true; fi
  [ -n "$1$x" ] || return 0
  : > "$_SCRATCH/lg-pr.noted"
  printf 'ledger: %s\n' "$1${1:+${x:+; }}$x" | tr -d '\000-\010\013-\037' >&2
}

# _lg_ix_pr_lines <pr-lines> <out>: "o\t<n>\t<head>" per open PR, "m\t<n>\t
# <head_oid>" per merged PR that gives its merged head's commit (a merged
# PR is pinned to it: its branch may have moved on since — a merged PR
# without one is left out; a cross-repository one too counts, pinned), "x\t
# <n>" per open cross-repository PR ("cross": true — a fork's branch, never
# resolved through a same-named branch of the remote: only through its
# pull ref, inflight.pull_refs). A head with a tab or newline, or a number
# that is not one, is left out.
_lg_ix_pr_lines() {
  jq -r 'select((.number | type) == "number" or (.number | type) == "string")
    | (.number | tostring) as $n
    | select($n | test("^[0-9]+$"))
    | if .state == "merged" then
        (if (.head_oid | type) == "string" and (.head_oid | test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
         then "m\t\($n)\t\(.head_oid)" else empty end)
      elif .state != "open" then empty
      elif .cross == true then "x\t\($n)"
      elif (.head | type) == "string" and (.head | test("^[^\\t\\n\\r]+$")) then "o\t\($n)\t\(.head)"
      else empty end' "$1" > "$2" 2> "$2.err" || _lg_die "jq failed (the PR list): $(head -n 1 "$2.err")"
}

# _lg_ix_pr_numbers <file> <n>: the first three numbers of <file> (one per
# line, numeric order) as "#a, #b, #c[, …]" (<n> of them in all).
_lg_ix_pr_numbers() {
  local nums
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    die-in-pr-numbers) _lg_die "selftest: a producer inside \$(…) died" ;;
  esac
  nums=$(LC_ALL=C sort -n "$1" | head -n 3 | sed 's/^/#/' | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  if [ "$2" -gt 3 ]; then nums="$nums, …"; fi
  printf '%s' "$nums"
}

# _lg_ix_pr_prepare <base|""> <prefix>: the PR data for an index build
# (worktree or --rev): <prefix>.prl the adapter's lines (from the remote
# cache's snapshot; empty without), <prefix>.prheads "<n>\t<head>\t<oid>\t
# <o|m>" per open PR whose head has a local ref — with inflight.pull_refs
# set, refs/doc-superpowers/pull/<n> (fetched by the in-flight scan,
# inflight.sh; a cross-repository PR's head too, "-" for its head), else
# refs/remotes/<remote>/<head> — and per merged PR whose head_oid this
# clone has ("-" for its head; none when the base does not resolve),
# <prefix>.prkey the key lines (the data's state class, the heads, each
# walked oid). Copies of .prl and .prheads go to $_SCRATCH/lg-pr.prl and
# lg-pr.heads (the in-flight join reads the last build's). $_SCRATCH/lg-pr.mark: the views' header note (stale,
# offline or unavailable data; empty otherwise); $_SCRATCH/lg-pr.json: the
# verbs' pr_data {"state": fresh|stale|offline|none|unconfigured, "as_of":
# <fetch epoch>|null, "error": <reason>|null}. Prints the run's PR note
# (stderr, one line): the data's state, the open heads not fetched, the
# cross-repository open PRs not compared.
_lg_ix_pr_prepare() {
  local base="$1" p="$2" s remote url rc=0 state note="" mark="" missing=0 cross=0 t ol err pull="" nums
  : > "$p.prl"
  : > "$p.prheads"
  : > "$_SCRATCH/lg-pr.mark"
  _lg_scratch_name
  s=$_LG_SN
  if _lg_adapter_path pr; then
    if [ -z "$_LG_ADP" ]; then
      printf 'pr unconfigured\n' > "$p.prkey" || _lg_die "cannot write $p.prkey"
      printf '{"state":"unconfigured","as_of":null,"error":null}\n' > "$_SCRATCH/lg-pr.json" || _lg_die "cannot write the PR state"
      if ! : > "$_SCRATCH/lg-pr.prl" || ! : > "$_SCRATCH/lg-pr.heads"; then _lg_die "cannot write the PR data"; fi
      return 0
    fi
    _lg_cfg '(.keys.remote | if type == "string" and . != "" then . else "origin" end), ('"$_LG_RTTL_JQ"'),
      (.inflight.pull_refs | if type == "string" and . != "" then "1" else "" end)' > "$s.cfg"
    { IFS= read -r remote; IFS= read -r _LG_RTTL; IFS= read -r pull; } < "$s.cfg" || _lg_die "cannot read the config"
    url=$(git config --get "remote.$remote.url" 2>/dev/null) || url=""
    _lg_remote_cache pr "$(printf 'pr\n%s\n%s' "$_LG_ADP" "$url")" _lg_adapter pr list || rc=$?
    _LG_RTTL=""
  else
    remote=$(_lg_cfg '.keys.remote | if type == "string" and . != "" then . else "origin" end') || exit "$?"
    rc=2
    _LG_RSTATE=none
    _LG_RERR=$_LG_ADP_ERR
    _LG_RFETCHED=""
  fi
  state=$_LG_RSTATE
  err=$_LG_RERR
  if [ "$rc" != 0 ]; then
    if [ "${_LG_REMOTE_FORCE:-}" = 1 ]; then
      if [ "$state" = offline ]; then _lg_die "PR data: $err"; fi
      _lg_die "PR data: the pr adapter failed: $err"
    fi
    note="PR data unavailable (—): ${err:-the pr adapter failed}"
    mark="PR data: — (unavailable)"
  else
    tail -n +2 "$_LG_RSNAP" > "$p.prl" || _lg_die "cannot read $_LG_RSNAP"
    if [ "$state" = stale ] || [ "$state" = offline ]; then
      t=$(jq -nr --argjson t "$_LG_RFETCHED" --argjson a "$_LG_RAGE" '
        ($t | strftime("%Y-%m-%d %H:%M UTC")) + " ("
        + (if $a < 3600 then "\($a / 60 | floor) min"
           elif $a < 172800 then "\($a / 3600 | floor) h"
           else "\($a / 86400 | floor) d" end) + " old)"') || _lg_die "jq failed (the PR data age)"
      mark="PR data as of $t"
      if [ "$state" = offline ]; then
        note="PR data as of $t — $err"
        err=""
      else
        note="PR data as of $t — the pr adapter failed: ${err:-?}"
      fi
    fi
  fi
  printf '%s\n' "$mark" > "$_SCRATCH/lg-pr.mark" || _lg_die "cannot write the PR mark"
  jq -nc --arg st "$state" --arg t "${_LG_RFETCHED:-}" --arg e "$err" \
    '{state: $st, as_of: (if $t == "" then null else ($t | tonumber) end), error: (if $e == "" then null else $e end)}' \
    > "$_SCRATCH/lg-pr.json" || _lg_die "cannot write the PR state"
  # The heads ("o|m\t<n>\t<head>", "x\t<n>"), kept beside the cache file as
  # <file>-ol3-<data sha, 16 hex>.ol: named by the snapshot's data hash and
  # by this format's version, so a refresh with new data, or a newer
  # format, finds none. A copy that fails is a miss (parsed again).
  ol=""
  if [ "$rc" = 0 ]; then
    case "$_LG_RDSHA" in
      ????????????????*) ol="${_LG_RCACHE%.json}-ol3-${_LG_RDSHA:0:16}.ol" ;;
    esac
  fi
  if [ -z "$ol" ] || [ ! -f "$ol" ] || ! cp -- "$ol" "$s.pr" 2>/dev/null; then
    _lg_ix_pr_lines "$p.prl" "$s.pr"
    if [ -n "$ol" ]; then
      # Best effort: without it the next run parses the list again.
      rm -f -- "${_LG_RCACHE%.json}"-*.ol 2>/dev/null || true
      if t=$(mktemp "$_LG_CACHE/remote/.ol.XXXXXX"); then
        if ! cp -- "$s.pr" "$t" || ! mv -f -- "$t" "$ol"; then rm -f -- "$t"; fi
      fi
    fi
  fi
  # One pass resolves the heads against `git for-each-ref
  # refs/remotes/<remote>/` (in the adapter's order, which the key's data
  # hash already pins); it writes .prheads, the key's lines, the unfetched
  # open PRs' and the cross-repository open PRs' numbers, and prints how
  # many of each there are.
  : > "$s.refs"
  : > "$s.mchk"
  if [ -s "$s.pr" ] && [ -n "$base" ]; then
    if [ -n "$pull" ]; then set -- "refs/remotes/$remote/" refs/doc-superpowers/pull/; else set -- "refs/remotes/$remote/"; fi
    git for-each-ref --format='%(objectname) %(refname)' "$@" > "$s.refs" 2> "$s.err" \
      || _lg_die "git for-each-ref failed: $(head -n 1 "$s.err")"
    # The merged heads this clone has: one batch check for all of them.
    LC_ALL=C awk -F '\t' '$1 == "m" { print $3 }' "$s.pr" > "$s.moids" || _lg_die "cannot list the merged heads"
    if [ -s "$s.moids" ]; then
      git cat-file --batch-check='%(objectname) %(objecttype)' < "$s.moids" > "$s.mchk" 2> "$s.err" \
        || _lg_die "git cat-file --batch-check failed: $(head -n 1 "$s.err")"
    fi
  fi
  t=$(LC_ALL=C awk -v refs="$s.refs" -v chk="$s.mchk" -v pre="refs/remotes/$remote/" -v miss="$s.miss" -v xs="$s.cross" \
      -v heads="$p.prheads" -v key="$p.prkey" -v state="$(if [ "$rc" != 0 ]; then echo none; else echo data; fi)" \
      -v pull="$pull" '
    BEGIN {
      printf "" > miss; printf "" > xs; printf "" > heads; print "pr " state > key
      while ((getline l < refs) > 0) { t = index(l, " "); R[substr(l, t + 1)] = substr(l, 1, t - 1) }
      while ((getline l < chk) > 0) { split(l, a, " "); if (a[2] == "commit") C[a[1]] = 1 }
      nm = 0; nx = 0
    }
    {
      k = substr($0, 1, 1); l = substr($0, 3); t = index(l, "\t")
      n = t ? substr(l, 1, t - 1) : l; v = t ? substr(l, t + 1) : "-"
      # The pull ref first (inflight.pull_refs): the PR head itself, a
      # fork'"'"'s too.
      if (k != "m" && pull != "" && (("refs/doc-superpowers/pull/" n) in R)) {
        o = R["refs/doc-superpowers/pull/" n]
        print n "\t" v "\t" o "\to" > heads; print "head " n "\t" v "\t" o "\to" > key
        next
      }
      if (k == "x") { print n > xs; nx++; next }
      if (k == "m") {
        if (v in C) { print n "\t-\t" v "\tm" > heads; print "head " n "\t-\t" v "\tm" > key }
      } else if ((pre v) in R) { print n "\t" v "\t" R[pre v] "\t" k > heads; print "head " n "\t" v "\t" R[pre v] "\t" k > key }
      else { print n > miss; nm++ }
    }
    END { print nm " " nx }' "$s.pr") || _lg_die "cannot resolve the PR heads"
  missing=${t%% *}
  cross=${t#* }
  if [ "$missing" -gt 0 ]; then
    nums=$(_lg_ix_pr_numbers "$s.miss" "$missing") || exit "$?"
    if [ -z "$base" ]; then
      t="$missing open PR heads not compared ($nums): the base does not resolve"
    elif [ "$missing" = 1 ]; then
      t="1 open PR head not fetched ($nums; git fetch $remote): not shown in review"
    else
      t="$missing open PR heads not fetched ($nums; git fetch $remote): not shown in review"
    fi
    note="${note:+$note; }$t"
  fi
  if [ "$cross" -gt 0 ]; then
    nums=$(_lg_ix_pr_numbers "$s.cross" "$cross") || exit "$?"
    if [ "$cross" = 1 ]; then
      t="1 cross-repository open PR not compared ($nums)"
    else
      t="$cross cross-repository open PRs not compared ($nums)"
    fi
    note="${note:+$note; }$t"
  fi
  if ! cp -- "$p.prl" "$_SCRATCH/lg-pr.prl" || ! cp -- "$p.prheads" "$_SCRATCH/lg-pr.heads"; then
    _lg_die "cannot copy the PR data"
  fi
  _lg_ix_pr_note "$note"
}

# _lg_ix_claim_trailers <out>: config trailers.claims and claims_by_path as
# "<kind>\t<name>" lines (relations.sh _lg_trailers).
_lg_ix_claim_trailers() {
  _lg_trailers "$1.all"
  LC_ALL=C awk -F '\t' '$1 == "claims" || $1 == "claims_by_path"' "$1.all" > "$1" || _lg_die "cannot read the claims trailers"
}

# _lg_ix_base_claims <base|""> → _LG_BCLAIMS: a private file of "<kind>\t<value>"
# lines (after a "# ledger-claims/1 <sig>" header line) — every claims /
# claims_by_path message line of the commits the base reaches
# (_LG_AWK_TRAILER: any line, bullets included). Cached as
# $_LG_CACHE/claims-<base>.tsv, the signature over the trailer names and
# the shallow tag; a new base extends the newest cached ancestor's (one
# walk of anc..base); the newest 5 kept. No base, or no such trailer
# configured: an empty file. A cached file that vanishes (another run
# prunes it) is a miss — a cold walk, silently. DOC_TOOLS_LEDGER_SELFTEST
# (scripts/test-ledger.sh only): claims-prune-early removes the cached
# files after they are listed, claims-prune the chosen ancestor's before
# it is copied, claims-vanish-current the base's own after its test.
_lg_ix_base_claims() {
  local B="$1" s f first hdr c oid anc="" tmp rc=0
  _lg_scratch_name
  s=$_LG_SN
  _LG_BCLAIMS="$s.bclaims"
  : > "$_LG_BCLAIMS"
  [ -n "$B" ] || return 0
  _lg_ix_claim_trailers "$s.tr"
  [ -s "$s.tr" ] || return 0
  _lg_ix_shallow
  { printf 'ledger-claims/1\n'; cat "$s.tr"; printf 'shallow %s\n' "$_LG_SHALLOW"; } > "$s.sig" || _lg_die "cannot write $s.sig"
  _hash_one "$s.sig"
  hdr="# ledger-claims/1 ${_HASH#sha256:}"
  f="$_LG_CACHE/claims-$B.tsv"
  first=""
  if [ -f "$f" ]; then
    case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
      claims-vanish-current) rm -f -- "$f" ;;
    esac
    # Silent: pruning by another run may remove it after the test — a miss.
    { IFS= read -r first < "$f"; } 2>/dev/null || true
  fi
  # A hit is read from a private copy (pruning may remove the file
  # meanwhile); a copy that fails is a miss.
  if [ "$first" = "$hdr" ] && cp -- "$f" "$s.bclaims" 2>/dev/null; then
    _lg_ix_trace "claims-hit"
    return 0
  fi
  # shellcheck disable=SC2012  # cache names are claims-<hex>.tsv
  ls -t "$_LG_CACHE"/claims-*.tsv 2>/dev/null | head -n 8 > "$s.cached" || true
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    claims-prune-early) while IFS= read -r c; do rm -f "$c"; done < "$s.cached" ;;
  esac
  while IFS= read -r c; do
    oid=${c##*/claims-}
    oid=${oid%.tsv}
    [ "$oid" != "$B" ] || continue
    first=""
    { IFS= read -r first < "$c"; } 2>/dev/null || true
    [ "$first" = "$hdr" ] || continue
    if git merge-base --is-ancestor "$oid" "$B" 2>/dev/null; then anc=$oid; break; fi
  done < "$s.cached"
  mkdir -p -- "$_LG_CACHE" 2>/dev/null || _lg_die "cannot create $_LG_CACHE"
  tmp=$(mktemp "$_LG_CACHE/.claims.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE"
  if [ -n "$anc" ]; then
    _lg_ix_trace "claims-extend $anc"
    case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
      claims-prune) rm -f "$_LG_CACHE/claims-$anc.tsv" ;;
    esac
    if ! cp -- "$_LG_CACHE/claims-$anc.tsv" "$tmp" 2>/dev/null; then
      # A cached file that cannot be read (removed meanwhile, …): a cold walk.
      _lg_ix_trace "claims-cold (cannot read claims-$anc.tsv)"
      anc=""
    fi
  fi
  if [ -n "$anc" ]; then
    _lg_msg_claims "$anc..$B" > "$s.mc" || rc=$?
  else
    _lg_ix_trace "claims-cold"
    printf '%s\n' "$hdr" > "$tmp" || { rm -f "$tmp"; _lg_die "cannot write $tmp"; }
    _lg_msg_claims "$B" > "$s.mc" || rc=$?
  fi
  [ "$rc" = 0 ] || { rm -f "$tmp"; _lg_die "cannot read the base's claims"; }
  LC_ALL=C awk -F '\t' '$2 == "claims" || $2 == "claims_by_path" { print $2 "\t" substr($0, length($1) + length($2) + 3) }' "$s.mc" >> "$tmp" \
    || { rm -f "$tmp"; _lg_die "cannot read the base's claims"; }
  cp -- "$tmp" "$_LG_BCLAIMS" || { rm -f "$tmp"; _lg_die "cannot write $_LG_BCLAIMS"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _lg_die "cannot install $f"; }
  # shellcheck disable=SC2012  # cache names are claims-<hex>.tsv
  ls -t "$_LG_CACHE"/claims-*.tsv 2>/dev/null | tail -n +6 | while IFS= read -r c; do rm -f "$c"; done
}

# The attribution of a walk of <base>..<heads> (awk): stdin the messages
# (`git log --format='%x01%H %P%n%B'`), -v heads ("<n>\t<head>\t<oid>"),
# files (the walk's `--name-only -z` names, tr'd: a commit "\002<id>", a
# name led by \001 or not), tr (the claims trailers). From each head, the
# commits of the walk it reaches (parents within the walk); for each, its
# claims lines and changed names, as "<n>\t<kind>\t<value>" ("file" for a
# name), each once per PR.
# shellcheck disable=SC2016  # awk source
_LG_AWK_PR_CLAIMS='
function emit(n, k, v) { if ((n, k, v) in OUT) return; OUT[n, k, v] = 1; print n "\t" k "\t" v }
BEGIN { tr_load(tr) }
substr($0, 1, 1) == "\001" {
  l = substr($0, 2); t = index(l, " ")
  c = t ? substr(l, 1, t - 1) : l; PAR[c] = t ? substr(l, t + 1) : ""; IN[c] = 1
  next
}
{ tr_match($0); for (i = 1; i <= TRM; i++) { NT[c]++; TK[c, NT[c]] = TRMK[i]; TV[c, NT[c]] = TRMV[i] } }
END {
  fc = ""
  while ((getline t < files) > 0) {
    if (substr(t, 1, 1) == "\002") { fc = substr(t, 2); continue }
    if (substr(t, 1, 1) == "\001") t = substr(t, 2)
    if (t == "" || fc == "") continue
    NN[fc]++; NM[fc, NN[fc]] = t
  }
  while ((getline l < heads) > 0) {
    split(l, h, "\t"); n = h[1]; o = h[3]
    delete SEEN; sp = 0
    if (o in IN) ST[++sp] = o
    while (sp > 0) {
      c = ST[sp--]
      if (c in SEEN) continue
      SEEN[c] = 1
      for (i = 1; i <= NT[c]; i++) emit(n, TK[c, i], TV[c, i])
      for (i = 1; i <= NN[c]; i++) emit(n, "file", NM[c, i])
      k = split(PAR[c], A, " ")
      for (i = 1; i <= k; i++) if ((A[i] in IN) && !(A[i] in SEEN)) ST[++sp] = A[i]
    }
  }
}'

# _lg_ix_pr_claims <base|""> <prheads> <dirs> <out>: what the PRs' heads
# claim, "<n>\t<kind>\t<value>" lines (kind claims, claims_by_path or file;
# a newline in a name as \001): one walk of ^<base> <head oids…> (open and
# merged PRs alike) for the messages and parents, one (limited to <dirs>,
# the item globs' directories) for the changed names, attributed per head
# (_LG_AWK_PR_CLAIMS). lg_pr_apply counts a merged PR's trailers only.
_lg_ix_pr_claims() {
  local B="$1" heads="$2" dirs="$3" out="$4" s d rc=0
  local specs=()
  : > "$out" || _lg_die "cannot write $out"
  [ -s "$heads" ] && [ -n "$B" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  while IFS= read -r d; do
    specs+=("$d")
  done < "$dirs"
  { printf '^%s\n' "$B"; LC_ALL=C awk -F '\t' '{ print $3 }' "$heads" | LC_ALL=C sort -u; } > "$s.revs" \
    || _lg_die "cannot write $s.revs"
  _lg_ix_claim_trailers "$s.tr"
  git -c log.showSignature=false log --no-color --stdin --format='%x01%H %P%n%B' < "$s.revs" > "$s.msg" 2> "$s.err" \
    || _lg_die "git log failed (the PR heads): $(head -n 3 "$s.err")"
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --stdin --full-history --no-renames \
    --format=%x02%H --name-only -z -- ${specs[@]+"${specs[@]}"} < "$s.revs" > "$s.fz" 2> "$s.err" \
    || _lg_die "git log failed (the PR heads' files): $(head -n 3 "$s.err")"
  tr '\n\000' '\001\n' < "$s.fz" > "$s.files" || _lg_die "cannot read the PR heads' files"
  LC_ALL=C awk -v heads="$heads" -v files="$s.files" -v tr="$s.tr" "$_LG_AWK_TRAILER$_LG_AWK_PR_CLAIMS" "$s.msg" >> "$out" \
    || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot attribute the PR heads' commits (awk rc $rc)"
}

# --- _lg_index ---------------------------------------------------------------------

# _lg_index [--rev <rev>|--staged]: print the path of the index (see the
# header). Dies (2) on an unreadable input (doc-index, registry, legacy or
# finalized map), an unknown revision, or a git failure.
_lg_index() {
  local mode=worktree rev="" src commit="" tree="" head base_ref="" base="" s reg di key name tmp rfn f n relpid
  local legacy_path="" dcommit usemtime ixdir
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
  if [ "$mode" = rev ]; then
    # A --rev build is the commit's alone: its base is the commit itself,
    # and HEAD plays no part (neither in the key nor in built).
    head=""
    base=$commit
  fi
  _lg_ix_shallow
  di=$(_lg_doc_index "$src") || exit "$?"
  # The contracts adapter's list (or its failure) is an input like a file:
  # run every time, hashed into the key.
  _lg_ix_adapter_contracts "$s.adc" "$s.ade"

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
  printf '%s\0' "$_LG_CFG" "$s.adc" "$s.ade" >> "$s.hashin"
  # The PR data (worktree and --rev; --staged, which only validate reads,
  # has none): the adapter's list through the remote cache, the open
  # and merged heads' oids — all in the key.
  if [ "$mode" = staged ]; then
    : > "$s.prl"
    : > "$s.prheads"
    printf 'pr skipped\n' > "$s.prkey"
  else
    _lg_ix_pr_prepare "$base" "$s"
  fi
  printf '%s\0' "$s.prkey" "$s.prl" >> "$s.hashin"
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
    printf 'schema %s\nmode %s\nhead %s\nrev %s\ntree %s\nbase %s\nlegacy %s\nshallow %s\n' \
      "$_LG_INDEX_SCHEMA" "$mode" "$head" "$commit" "$tree" "$base" "$legacy_path" "$_LG_SHALLOW"
    cat "$s.smalls"
    printf 'inputs: code (scripts/ledger/*), config, contracts adapter (output, error), PR key, PR data[, listing[, the present small files]]\n'
    cat "$s.hashes"
  } > "$s.key" || _lg_die "cannot write the index key"
  _hash_one "$s.key"
  key=${_HASH#sha256:}
  ixdir=$_LG_CACHE
  if [ "$mode" = rev ]; then
    ixdir="$_LG_CACHE/rev"
    mkdir -p -- "$ixdir" 2>/dev/null || _lg_die "cannot create $ixdir"
  fi
  name="$ixdir/index-$key.json"
  if _lg_ix_valid "$name"; then
    _lg_ix_trace "index-hit index-$key.json"
    # A hit makes the file the newest: pruning keeps the newest by mtime.
    touch -c "$name" "${name%.json}.refs" 2>/dev/null || true
    printf '%s\n' "$name"
    return 0
  fi
  _lg_ix_trace "index-build index-$key.json"
  # The dates walk starts now, in the background, and overlaps the parse.
  # (A base other than the dated commit is derived from its walk:
  # _lg_ix_events_base.)
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$s.pfglobs"
  _lg_glob_dirs "$s.pfglobs" "$s.pfdirs"
  if [ -n "$dcommit" ]; then _lg_ix_prefetch "$dcommit" "$s.pfdirs"; fi

  # The inputs, read and checked.
  reg=$(_lg_registry "$src") || exit "$?"
  _lg_ix_contracts "$reg" "$s.adc" "$s.contracts" "$s.cre"
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
  # The relations (needing only the records and the contracts) run in the
  # background meanwhile.
  jq -L "$_LG_LIB" -n -r --slurpfile c "$_LG_CFG" --slurpfile recs "$s.recs" --slurpfile ctr "$s.contracts" \
    "$_LG_JQ_INDEX_DEFS$_LG_JQ_REL" < /dev/null > "$s.rel" 2> "$s.relerr" &
  relpid=$!
  jq -L "$_LG_LIB" -n -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F
    | inputs
    | ((.fm // {}) | lg_fv($F; "key") | if type == "string" and (test("[\\t\\n\\r]") | not) then ascii_downcase else "" end) as $k
    | "\($k)\t\(.path | gsub("\n"; "\u0001"))"' "$s.recs" > "$s.keys" || _lg_die "jq failed (item keys)"
  _lg_ix_dates "$dcommit" "$s.items" "$usemtime" "$s.dates" "$s.formers"
  _lg_ix_docs "$src" "$s.cands" "$s.keys" "$s.formers" "$s.docs"
  # What the base and the PRs claim (none for --staged).
  if [ "$mode" = staged ]; then
    : > "$s.bcl"
    _LG_BCLAIMS="$s.bcl"
  else
    _lg_ix_base_claims "$base"
  fi
  _lg_ix_pr_claims "$base" "$s.prheads" "$s.pfdirs" "$s.pcl"
  : > "$s.none"
  _lg_registry_findings "$reg" "$s.none" "$s.rf"
  rfn=$(wc -l < "$s.rf" | tr -d ' ')
  tmp=$(mktemp "$ixdir/.index.XXXXXX") || _lg_die "cannot create a temp file in $ixdir"
  if ! jq -L "$_LG_LIB" -n -r \
      --slurpfile c "$_LG_CFG" --slurpfile reg "$reg" --slurpfile di "$di" \
      --slurpfile lgy "$s.legacy" --slurpfile fin "$s.finalized" \
      --slurpfile recs "$s.recs" --slurpfile dates "$s.dates" --slurpfile docs "$s.docs" \
      --slurpfile ctr "$s.contracts" --rawfile cre "$s.cre" --arg cerr "$(head -n 1 "$s.ade")" \
      --slurpfile prs "$s.prl" --rawfile pcl "$s.pcl" --rawfile bcl "$_LG_BCLAIMS" --rawfile fmr "$s.formers" \
      --arg schema "$_LG_INDEX_SCHEMA" --arg head "$head" --arg base "$base" --arg hash "sha256:$key" \
      --arg mode "$mode" --arg rev "$commit" --argjson rf "$rfn" --argjson terms "$_LG_DOC_TERMINAL" \
      "$_LG_JQ_INDEX_DEFS$_LG_JQ_INDEX" > "$tmp.join"; then
    rm -f "$tmp" "$tmp.join"
    _lg_die "jq failed (the index join)"
  fi
  # The relations pass: the re-check input (its count, its lines), then
  # each item's neighbours. The re-check markers (relations.sh; not for
  # --staged, which only validate reads) and the neighbours go into the
  # items' lines.
  wait "$relpid" || { rm -f "$tmp" "$tmp.join"; _lg_die "jq failed (the relations): $(head -n 3 "$s.relerr" 2>/dev/null)"; }
  n=""
  IFS= read -r n < "$s.rel" || true
  case "$n" in ''|*[!0123456789]*) rm -f "$tmp" "$tmp.join"; _lg_die "internal: the relations pass's first line is '$n'" ;; esac
  if ! sed -n "2,$((n + 1))p" "$s.rel" > "$s.rctab" || ! tail -n +"$((n + 2))" "$s.rel" > "$s.nb"; then
    rm -f "$tmp" "$tmp.join"
    _lg_die "cannot split the relations"
  fi
  : > "$s.rcmap"
  case "$mode" in
    worktree) _lg_ix_recheck "$base" "$s.rctab" "$s.eff" "$s.rcmap" "$s.pfdirs" "$dcommit" ;;
    rev) _lg_ix_recheck "$base" "$s.rctab" "" "$s.rcmap" "$s.pfdirs" "$dcommit" ;;
  esac
  # Item n is line n + 2 (after the head line); "neighbours":null and
  # "recheck_after":[] are in it once each (in a string value every quote
  # is escaped).
  if ! LC_ALL=C awk -v nb="$s.nb" -v map="$s.rcmap" '
      BEGIN {
        while ((getline l < map) > 0) { t = index(l, "\t"); M[substr(l, 1, t - 1) + 2] = substr(l, t + 1) }
        while ((getline l < nb) > 0) NB[++n + 1] = l
      }
      (NR in NB) {
        j = index($0, "\"neighbours\":null")
        if (!j) exit 3
        line = substr($0, 1, j + 12) NB[NR] substr($0, j + 17)
        if (NR in M) {
          j = index(line, "\"recheck_after\":[]")
          if (!j) exit 3
          line = substr(line, 1, j + 15) M[NR] substr(line, j + 18)
        }
        print line
        next
      }
      { print }
      END { if (NR - 2 != n && n > 0) exit 4 }' "$tmp.join" > "$tmp"; then
    rm -f "$tmp" "$tmp.join"
    _lg_die "cannot write the neighbours and re-check markers into the index"
  fi
  rm -f "$tmp.join"
  _lg_ix_refs "$s.recs" "${tmp}.refs" || { rm -f "$tmp" "${tmp}.refs"; _lg_die "cannot list the parse references"; }
  if ! mv -f "${tmp}.refs" "$ixdir/index-$key.refs" || ! mv -f "$tmp" "$name"; then
    rm -f "$tmp" "${tmp}.refs"
    _lg_die "cannot install $name"
  fi
  _lg_ix_prune "$ixdir"
  printf '%s\n' "$name"
}

# shellcheck shell=bash
# scripts/ledger/relations.sh — related work (design §F): message trailers,
# the re-check markers the index carries, and the verbs `ledger related`,
# `ledger recheck`, `ledger sweep`. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, _lg_cfg, index.sh's
# _lg_index, _lg_ix_events and _LG_JQ_INDEX_DEFS, keys.sh's
# _LG_JQ_RESOLVE_DEFS, glob.sh's _LG_AWK_GLOB / _lg_glob_dirs, parse.sh's
# parsers. The relations themselves — neighbours, candidates — are jq, in
# defs.jq (lg_relations, lg_r_maps, lg_r_candidates).
#
# Re-check (design §F.2; computed, no state file): an open item X gets
# recheck_after entries when, on the base B (config base; for --rev the
# commit itself),
#   - a re-check source S of X — an item whose changes meet X's consumes,
#     or an item X's own relates names — is in a terminal class (fixed,
#     closed, won't fix) at B: the entry is S's key; its event commit E is
#     the last commit on B touching S's file (where it became terminal);
#   - a commit E on B changed a contract X consumes — it touches a file the
#     contract's defined_in matches, or its message carries a
#     "Contract-Change: <id> …" line: the entry is the contract id;
# and E is in `git rev-list <L>..B`, L the last commit on B touching X's
# file (ancestry, not time). An item that has no commit on B gets none; an
# uncommitted edit clears nothing — a later commit to X on B clears it.
# S's class "at B" is the index's when S's file is the same blob at B, else
# read from B's blob (absent at B: not terminal) — a source closed on a
# branch, or only in the working tree, has not landed. Contract changes are
# looked for in B ^M_k only: M_k the first-parent line commit with k the
# largest, over the open consumers, of their L's index on the line (L off
# the line: the newest line commit its side walk reaches; one that reaches
# none — no bound). M_k is an ancestor of every consumer's L, so B ^M_k
# holds every commit any consumer could count; the decision stays per item
# (anc). One `git log --name-only` over the literal directories of the
# consumed contracts' defined_in globs and one message pass, run by the
# re-check program itself once it knows the bound (one awk pass in all).
#
# Ancestry ("is E an ancestor of L, or L itself"), without a git call per
# pair: from `git rev-list --parents B` (cached by B's id; the first-parent
# line M_0 = B, M_1, … read from it), enter(c) = the largest k with c reachable from
# M_k (ancestors of M_k are exactly the commits with enter ≥ k). For L on
# the line (L = M_k): E is an ancestor iff enter(E) ≥ k. For L off it:
# enter(E) < enter(L) → no; else E is an ancestor iff it is one of the
# commits reachable from L without passing a line commit (a branch's own
# commits, walked once per L), or enter(E) ≥ the smallest index of the line
# commits that walk reaches.

# --- Message trailers -------------------------------------------------------------

# The trailer matcher (awk), shared by _lg_msg_claims and the re-check
# program: tr_load(file) reads "<kind>\t<name>" lines; tr_match(line) sets
# TRM (the number of matches) and TRMK[i] / TRMV[i] (kind, value).
# A claims_by_ref name is a closing keyword (GitHub's form, "Fixes #123"):
# at the line start (after the same blanks / "*" / "-" a trailer may have),
# in any case, then ":" and optional blanks or blanks alone ("Fixes:#12",
# "Fixes: #12", "Fixes #12"; not "Fixes#12"), then #<number> (no leading
# zero: #0 is no issue) ended by the line or a character other than a
# letter, digit or "_" — the value is "#<number>".
# The #N anchor bounds false positives the way GitHub's own keywords do;
# "this fixes #12" (mid-sentence) and "Fixes o/r#12" do not count.
# shellcheck disable=SC2016  # awk source
_LG_AWK_TRAILER='
function tr_load(f,   l, t) {
  while ((getline l < f) > 0) {
    t = index(l, "\t"); TRN++; TRK[TRN] = substr(l, 1, t - 1); TRT[TRN] = substr(l, t + 1); TRL[TRN] = tolower(TRT[TRN])
  }
  close(f)
}
function tr_match(line,   s, i, L, v, ls) {
  TRM = 0
  s = line; sub(/\r$/, "", s); sub(/^[ \t\v\f*-]*/, "", s)
  ls = ""
  for (i = 1; i <= TRN; i++) {
    L = length(TRT[i])
    if (TRK[i] == "claims_by_ref") {
      if (ls == "") ls = tolower(s)
      if (substr(ls, 1, L) != TRL[i]) continue
      v = substr(s, L + 1)
      if (substr(v, 1, 1) == ":") { v = substr(v, 2); if (v !~ /^[ \t\v\f]*#[1-9][0-9]*([^A-Za-z0-9_]|$)/) continue }
      else if (v !~ /^[ \t\v\f]+#[1-9][0-9]*([^A-Za-z0-9_]|$)/) continue
      sub(/^[ \t\v\f]+/, "", v)
      match(v, /^#[1-9][0-9]*/)
      TRM++; TRMK[TRM] = TRK[i]; TRMV[TRM] = substr(v, 1, RLENGTH)
      continue
    }
    if (substr(s, 1, L + 1) != TRT[i] ":") continue
    v = substr(s, L + 2)
    if (v !~ /^[ \t\v\f]+[^ \t\v\f]/) continue
    sub(/^[ \t\v\f]+/, "", v); sub(/[ \t\v\f]+$/, "", v); gsub(/\t/, " ", v)
    TRM++; TRMK[TRM] = TRK[i]; TRMV[TRM] = v
  }
}
'

# _lg_trailers <out> [kind]: config "trailers" as "<kind>\t<name>" lines
# (names without whitespace or ":"), every kind or only [kind].
_lg_trailers() {
  # shellcheck disable=SC2016  # jq source
  jq -r --arg only "${2:-}" '(.trailers // {}) | if type == "object" then to_entries[] else empty end
    | select($only == "" or .key == $only) | .key as $k
    | (.value | if type == "array" then .[] elif type == "string" then . else empty end)
    | strings | select(. != "" and (test("[\\s:[:cntrl:]]") | not)) | "\($k)\t\(.)"' "$_LG_CFG" > "$1" \
    || _lg_die "jq failed (config trailers)"
}

# _lg_msg_claims <rev-args…>: "commit<TAB>kind<TAB>value" for every message
# line (any line: a squash merge carries its commits' messages as body
# text, "* Ledger-Claims: x-3") of the commits `git log <rev-args>` lists,
# that matches ^[[:space:]*-]*<Trailer>:[[:space:]]+(.+)$ for a trailer
# config "trailers" names — kind is its key (claims, claims_by_path,
# claims_by_ref, contract_change, ack); the name matches as configured
# (case-sensitive: prose "fixes: the crash" is no trailer); value is (.+)
# without trailing blanks (a tab inside becomes a space). claims_by_ref
# names are closing keywords instead: "Fixes #12", "closes: #13" (any
# case, ":" optional, #<digits> required; value "#12" — see
# _LG_AWK_TRAILER). In git log order, then line order.
_lg_msg_claims() {
  local s a
  for a in "$@"; do
    case "$a" in -*|'') _lg_die "internal: _lg_msg_claims: not a revision: '$a'" ;; esac
  done
  _lg_scratch_name
  s=$_LG_SN
  _lg_trailers "$s.tr"
  git -c log.showSignature=false log --no-color --format='%x01%H%n%B' "$@" -- > "$s.msg" 2> "$s.err" \
    || _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"
  LC_ALL=C awk -v tr="$s.tr" "$_LG_AWK_TRAILER"'
    BEGIN { tr_load(tr) }
    substr($0, 1, 1) == "\001" { c = substr($0, 2); next }
    { tr_match($0); for (i = 1; i <= TRM; i++) print c "\t" TRMK[i] "\t" TRMV[i] }' "$s.msg"
}

# --- Re-check (index.sh) ------------------------------------------------------------

# The contract-change scan the re-check program runs (system()) once it
# knows its bound: bash <this> <base> <bound|""> <dirs> <clog> <msg> <globs 0|1>
# — the files the consumed contracts' defined_in name, changed in <base>
# ^<bound> (tr'd: one token per line, a commit led by \002), and the
# messages of the same commits.
# shellcheck disable=SC2016  # bash source
_LG_SH_RECHECK_SCAN='set -o pipefail
B=$1 bound=$2 dirs=$3 clog=$4 msg=$5 globs=$6
rng=("$B")
if [ -n "$bound" ]; then rng+=("^$bound"); fi
specs=()
while IFS= read -r d; do specs+=("$d"); done < "$dirs"
: > "$clog"
if [ "$globs" = 1 ]; then
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --full-history --format="%x02%H" \
    --name-only -z "${rng[@]}" -- ${specs[@]+"${specs[@]}"} | tr "\n\000" "\001\n" > "$clog" || exit 1
fi
git -c log.showSignature=false log --no-color --format="%x01%H%n%B" "${rng[@]}" -- > "$msg" || exit 1
'

# The program: -v base, graphf, tab, ev, termf, cg (the consumed contracts'
# globs, "<id>\001<glob>"), trf (the contract_change trailer names), sh,
# scan, dirs, clog, msg, scanerr. One pass: the graph and the touches, the
# bound, the scan (system), the decision. Prints "<n>\t<entry>" per marker
# (n: the item's place, tab's O lines).
# shellcheck disable=SC2016  # awk source
_LG_AWK_RECHECK='
function shq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
# addev(k, c): commit c changed contract k (each pair once).
function addev(k, c) { if ((k, c) in SEENEV) return; SEENEV[k, c] = 1; NEV[k]++; EV[k, NEV[k]] = c }
# side(l): the commits reachable from l without passing a commit of the
# first-parent line (SIDE[l, c]), and the newest line commit it reaches
# (KMIN[l], the smallest index; -1 when none).
function side(l,   sp, c, n, i, A, k) {
  if (l in KMIN) return
  KMIN[l] = -1
  sp = 0; ST[++sp] = l
  while (sp > 0) {
    c = ST[sp--]
    if (c in MIDX) { k = MIDX[c]; if (KMIN[l] < 0 || k < KMIN[l]) KMIN[l] = k; continue }
    if ((l, c) in SIDE) continue
    SIDE[l, c] = 1
    n = split(PAR[c], A, " ")
    for (i = 1; i <= n; i++) ST[++sp] = A[i]
  }
}
# anc(e, l): 1 when e is l or an ancestor of l.
function anc(e, l) {
  if (e == l) return 1
  if (!(e in ENTER) || !(l in ENTER)) return 0
  if (l in MIDX) return (ENTER[e] >= MIDX[l]) ? 1 : 0
  if (ENTER[e] < ENTER[l]) return 0
  side(l)
  if ((l, e) in SIDE) return 1
  return (KMIN[l] >= 0 && ENTER[e] >= KMIN[l]) ? 1 : 0
}
BEGIN {
  while ((getline l < graphf) > 0) {
    t = index(l, " ")
    if (t) PAR[substr(l, 1, t - 1)] = substr(l, t + 1); else PAR[l] = ""
  }
  # The first-parent line, from the base.
  K = -1; c = base
  while (c != "" && !(c in MIDX)) {
    K++; MAIN[K] = c; MIDX[c] = K
    t = index(PAR[c], " "); c = t ? substr(PAR[c], 1, t - 1) : PAR[c]
  }
  # enter: from the oldest line commit to the newest; each commit takes
  # the first (largest) index it is reachable from.
  for (k = K; k >= 0; k--) {
    sp = 0; ST[++sp] = MAIN[k]
    while (sp > 0) {
      c = ST[sp--]
      if (c in ENTER) continue
      ENTER[c] = k
      n = split(PAR[c], A, " ")
      for (i = 1; i <= n; i++) if (!(A[i] in ENTER)) ST[++sp] = A[i]
    }
  }
  while ((getline l < tab) > 0) {
    split(l, f, "\002")
    if (f[1] == "O") {
      no++; OP[no] = f[2]; OC[no] = f[3]; OS[no] = f[4]; ON[no] = f[5]; WANT[f[2]] = 1
      ns = split(f[4], b, "\003"); for (i = 1; i <= ns; i++) WANT[b[i]] = 1
    } else if (f[1] == "S") SK[f[2]] = f[3]
  }
  # The last commit on the base touching each wanted path (history order).
  while ((getline k < ev) > 0) {
    if (k == "@") { getline C < ev; continue }
    if (k == "A") { getline d < ev; getline p < ev; if (p in WANT) LAST[p] = C; continue }
    if (k == "R") {
      getline d < ev; getline o < ev; getline p < ev
      if (o != p && (o in LAST)) delete LAST[o]
      if (p in WANT) LAST[p] = C
      continue
    }
    if (k == "M") { getline p < ev; if (p in WANT) LAST[p] = C; continue }
    if (k == "D") { getline p < ev; if (p in LAST) delete LAST[p]; continue }
  }
  # The bound (one first-parent line commit M_k, an ancestor of the last
  # commit of every consumer): k = the largest of, per consumer, the index
  # of its last commit when on the line, else the newest line commit its
  # side walk reaches; a consumer reaching none → no bound. Excluding
  # ancestors of M_k drops only what no consumer could count; anc() below
  # keeps each item exact.
  kb = -1; nob = 0; cons = 0
  for (i = 1; i <= no; i++) {
    if (OC[i] == "" || !(OP[i] in LAST)) continue
    l = LAST[OP[i]]; cons = 1
    if (!(l in ENTER)) { nob = 1; continue }
    if (l in MIDX) k = MIDX[l]
    else { side(l); k = KMIN[l] }
    if (k < 0) nob = 1
    else if (k > kb) kb = k
  }
  if (cons) {
    bound = (nob || kb < 0) ? "" : MAIN[kb]
    globs = 0
    while ((getline l < cg) > 0) {
      t = index(l, "\001"); g++
      if (gx_add(g, substr(l, t + 1))) { ID[g] = substr(l, 1, t - 1); globs = 1 }
    }
    rc = system(shq(sh) " " shq(scan) " " shq(base) " " shq(bound) " " shq(dirs) " " shq(clog) " " shq(msg) " " globs " 2> " shq(scanerr))
    if (rc != 0) { print "scan failed (rc " rc ")" > "/dev/stderr"; exit 2 }
    # Files under a consumed contract: each distinct file matched once.
    while ((getline t < clog) > 0) {
      while (substr(t, 1, 1) == "\001") t = substr(t, 2)
      if (substr(t, 1, 1) == "\002") { c = substr(t, 2); continue }
      if (t == "" || c == "") continue
      if (!(t in HIT)) {
        gx_match(t); h = ""
        for (i = 1; i <= GX_MN; i++) h = h SUBSEP ID[GX_M[i]]
        HIT[t] = h
      }
      n = split(substr(HIT[t], 2), X, SUBSEP)
      for (i = 1; i <= n; i++) addev(X[i], c)
    }
    # Contract-Change: <id> … lines (the first word is the id).
    tr_load(trf)
    c = ""
    while ((getline t < msg) > 0) {
      if (substr(t, 1, 1) == "\001") { c = substr(t, 2); continue }
      tr_match(t)
      for (i = 1; i <= TRM; i++) { v = TRMV[i]; sub(/[ \t].*/, "", v); if (v != "" && c != "") addev(v, c) }
    }
  }
  while ((getline l < termf) > 0) TERM[l] = 1
  for (i = 1; i <= no; i++) {
    p = OP[i]
    if (!(p in LAST)) continue
    l = LAST[p]
    ns = split(OS[i], b, "\003")
    for (j = 1; j <= ns; j++) {
      q = b[j]
      if ((q in TERM) && (q in LAST) && !anc(LAST[q], l)) print ON[i] "\t" SK[q]
    }
    nc = split(OC[i], cc, "\003")
    for (j = 1; j <= nc; j++) {
      k = cc[j]
      for (x = 1; x <= NEV[k]; x++) if (!anc(EV[k, x], l)) { print ON[i] "\t" k; break }
    }
  }
  exit 0
}'

# _lg_ix_recheck <base-commit|""> <tab> <current-ids|""> <out.tsv> <dirs>
# <dated-commit|"">: the re-check markers (see the header) into <out.tsv>,
# one line per marked item: "<n>\t<[entries] as JSON>", n its place among
# the items (index.sh writes them into the item lines). <tab>:
# lg_relations' tab lines (defs.jq). <current-ids>: the working tree's
# "<path>\t<blob id>" (index.sh _lg_ix_effective); "" when the items are
# B's own (--rev). <dirs>: the item globs' directories (the dates walk's).
# <dated-commit>: the commit the dates walk read (HEAD; B's events are
# derived from its map, index.sh _lg_ix_events_base). No base, or no open
# item to check: empty.
_lg_ix_recheck() {
  local B="$1" tab="$2" cur="$3" out="$4" dirs="$5" H="$6" s
  : > "$out" || _lg_die "cannot write $out"
  [ -n "$B" ] || return 0
  grep -q '^O' "$tab" || return 0
  _lg_scratch_name
  s=$_LG_SN

  # The sources terminal at B (see the header).
  LC_ALL=C awk -v o="$s.src" 'BEGIN { FS = "\002"; printf "" > (o ".p"); printf "" > (o ".t") }
    $1 == "S" { print $2 > (o ".p"); if ($4 == 1) print $2 > (o ".t") }' "$tab" \
    || _lg_die "cannot list the re-check sources"
  : > "$s.term"
  if [ -s "$s.src.p" ]; then
    if [ -z "$cur" ]; then
      cp -- "$s.src.t" "$s.term" || _lg_die "cannot write $s.term"
    else
      _lg_ix_blob_ids "$B" "$s.src.p" "$s.bids"
      LC_ALL=C awk -v cur="$cur" -v tset="$s.src.t" -v diff="$s.diff" '
        BEGIN {
          while ((getline l < cur) > 0) { t = index(l, "\t"); C[substr(l, 1, t - 1)] = substr(l, t + 1) }
          while ((getline l < tset) > 0) T[l] = 1
          printf "" > diff
        }
        {
          t = index($0, "\t"); oid = substr($0, 1, t - 1); p = substr($0, t + 1)
          if (oid == "-") next
          if ((p in C) && C[p] == oid) { if (p in T) print p; next }
          print p > diff
        }' "$s.bids" > "$s.term" || _lg_die "cannot compare the sources with the base"
      if [ -s "$s.diff" ]; then
        # Their class at B, from B's blobs (\001 back to a newline: NUL list).
        tr '\n\001' '\000\n' < "$s.diff" > "$s.diffz" || _lg_die "cannot write $s.diffz"
        _lg_parse_blobs "$B" "$s.diffz" "$s.brecs"
        jq -L "$_LG_LIB" -n -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
          $c[0] as $cfg | lg_fields($cfg) as $F | lg_class_terms($cfg) as $CT
          | lg_obj(($CT | reverse)[] | {(.t): .c}) as $EX
          | inputs
          | select((.fm // {}) | lg_fv($F; "status") | lg_str | lg_class($CT; $EX) | . == "fixed" or . == "closed" or . == "wontfix")
          | .path | gsub("\n"; "\u0001")' "$s.brecs" >> "$s.term" || _lg_die "jq failed (the sources at the base)"
      fi
    fi
  fi

  # B's graph (cached by its id) and touches (derived from the dated
  # walk when B is another commit); the consumed contracts' globs (the
  # ones glob.sh accepts) and their literal directories; the
  # Contract-Change trailer names; the scan script.
  B=$(git rev-parse -q --verify "$B^{commit}") || _lg_die "cannot resolve the base $1"
  _lg_ix_graph "$B"
  _lg_ix_events_base "$B" "$dirs" "$H" "$_LG_GRAPH"
  LC_ALL=C awk 'BEGIN { FS = "\002" } $1 == "G" { print $2 "\001" $3 }' "$tab" | LC_ALL=C awk "$_LG_AWK_GLOB"'
    { t = index($0, "\001"); g = substr($0, t + 1); if (glob_ere(g) != "") print }' > "$s.cg" \
    || _lg_die "cannot read the contract globs"
  : > "$s.cdirs"
  if [ -s "$s.cg" ]; then
    LC_ALL=C awk '{ print substr($0, index($0, "\001") + 1) }' "$s.cg" > "$s.cgl"
    _lg_glob_dirs "$s.cgl" "$s.cdirs"
  fi
  _lg_trailers "$s.trf" contract_change
  printf '%s' "$_LG_SH_RECHECK_SCAN" > "$s.scan" || _lg_die "cannot write $s.scan"
  if ! LC_ALL=C awk -v base="$B" -v graphf="$_LG_GRAPH" -v tab="$tab" -v ev="$_LG_EVENTS" \
      -v termf="$s.term" -v cg="$s.cg" -v trf="$s.trf" -v sh="${BASH:-bash}" -v scan="$s.scan" \
      -v dirs="$s.cdirs" -v clog="$s.clog" -v msg="$s.msg" -v scanerr="$s.scanerr" \
      "$_LG_AWK_GLOB$_LG_AWK_TRAILER$_LG_AWK_RECHECK" < /dev/null > "$s.res"; then
    _lg_die "cannot compute the re-check markers${s:+: $(head -n 3 "$s.scanerr" 2>/dev/null | tr '\n' ' ')}"
  fi
  [ -s "$s.res" ] || return 0
  jq -R -n -r '[inputs | split("\t") | select(length == 2) | {k: .[0], v: (.[1] | gsub("\u0001"; "\n"))}]
    | group_by(.k)[] | "\(.[0].k)\t\(map(.v) | unique | tojson)"' "$s.res" > "$out" \
    || _lg_die "jq failed (re-check markers)"
}

# --- The verbs ------------------------------------------------------------------------

# _lg_r_ref <verb> → _LG_RREF: the item reference from the arguments (one
# argument, or several words of a spaced form, as show takes).
_lg_r_ref() {
  local a
  [ "${#_ARGS[@]}" -ge 1 ] || _lg_usage "give one item: a key, an alias, a legacy ref or a path"
  _LG_RREF=${_ARGS[0]}
  if [ "${#_ARGS[@]}" -gt 1 ]; then
    for a in "${_ARGS[@]:1}"; do _LG_RREF="$_LG_RREF $a"; done
    _lg_k_multiword "$_LG_RREF" || _lg_usage "give one item: a key, an alias, a legacy ref or a path (got ${#_ARGS[@]} arguments)"
  fi
  [ -n "$_LG_RREF" ] || _lg_usage "the item is empty"
}

# _lg_r_finish <verb> <out>: the query's head line decides — ok → the
# output (rc 0); none → "no item matches" (rc 1); ambiguous → rc 3;
# archived → rc 3.
_lg_r_finish() {
  local verb="$1" out="$2" s
  case "$_LG_QHEAD" in
    ok) _lg_q_finish "$out" ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then _lg_emit "$verb" 1 "$out"; fi
      s="$out.msg"
      printf "no item matches '%s'\n" "$_LG_RREF" | tr -d '\000-\010\013-\037' | head -n 1 > "$s"
      _lg_out_file "$s"
      _lg_emit "$verb" 1 ;;
    ambiguous*) _lg_usage "'$_LG_RREF' matches several items: ${_LG_QHEAD#*	}" ;;
    archived*) _lg_usage "'$_LG_RREF' is an archived legacy row (${_LG_QHEAD#*	}): there is no item" ;;
    *) _lg_die "internal: ledger $verb: unexpected query result '$_LG_QHEAD'" ;;
  esac
}

# The shared head of related / recheck: resolve $ref; "ambiguous", "none"
# (+ the JSON payload), "archived" — or, for an item, $I and $M.
# shellcheck disable=SC2016  # jq source
_LG_JQ_REL_HEAD="$_LG_JQ_RESOLVE_DEFS"'
def lg_rr_head($I):
  "\(($I.key // $I.path) | lg_q_one)  \(($I.ledger // "—") | lg_q_one)  \(($I.severity // "—") | lg_q_one)  \($I | lg_q_display) — \(($I.summary // "(no summary)") | lg_q_one | lg_q_cut(100))";
def lg_rr_item($I): {key: $I.key, path: $I.path, ledger: $I.ledger, severity: $I.severity, display: ($I | lg_q_display), summary: $I.summary};
def lg_rr_tail($Y): "\($Y | lg_q_display) · \(($Y.summary // "(no summary)") | lg_q_one | lg_q_cut(72))";
'

# --- related ---------------------------------------------------------------------------

# ledger related <ref> [--depth N]: the item's confirmed neighbours (design
# §F.1), breadth first to depth N (1–3; each item once, at its smallest
# depth, with the kind of the last step and — past depth 1 — the item it
# was reached through), then the candidates: open items (lg_v_active) not
# among them that lg_r_candidates finds — by the number of reasons, then
# severity, then key or path; the first 15 ("… N more candidates").
# Text: the item's line, then "<kind>  <key>  via <via> · <status> ·
# <summary>" per neighbour ("(no confirmed relations)"), "candidate  <key>
# <reasons> · …" per candidate ("(no candidates)"). JSON: {item, depth,
# neighbours: [{kind, key, path, via, depth, through, display, summary}],
# candidates: [{key, path, reasons, display, summary}]}.
# shellcheck disable=SC2016  # jq source
_LG_JQ_RELATED="$_LG_JQ_REL_HEAD"'
lg_resolve($ref; $c[0]) as $R
| . as $ix
| if $R.r == "ambiguous" then "ambiguous\t\($R.v | join(", "))"
  elif $R.r == "archived" then "archived\t\($R.v)"
  elif $R.r != "item" then "none", (if $mode == "json" then ({item: null, ref: $ref} | tojson) else empty end)
  else
    lg_r_maps($ix) as $M
    | lg_q_ranks($c[0]) as $K
    | $M.BYP[$R.v] as $I
    | def nbs($p): ($M.BYP[$p].neighbours // {}) as $n
        | [(($n.upstream // [])[] | . + {kind: "upstream"}), (($n.downstream // [])[] | . + {kind: "downstream"}),
           (($n.siblings // [])[] | . + {kind: "sibling"})];
      (reduce range(1; $depth + 1) as $d ({seen: {($I.path): true}, front: [$I.path], out: []};
         .front as $F
         | .front = []
         | reduce ($F[] as $fp | nbs($fp)[] | . + {from: $fp}) as $e (.;
             ($M.K2P[$e.key] // null) as $tp
             | if $tp == null or .seen[$tp] then .
               else .seen[$tp] = true | .front += [$tp]
                 | .out += [{kind: $e.kind, path: $tp, via: $e.via, depth: $d,
                             through: (if $d == 1 then null else ($M.BYP[$e.from].key // $e.from) end)}]
               end))) as $W
      | [$W.out[] | $M.BYP[.path] as $Y | {kind, key: $Y.key, path, via, depth, through,
          display: ($Y | lg_q_display), summary: $Y.summary}] as $NB
      | [lg_r_candidates($I; $M)[] | select($W.seen[.p] | not) | $M.BYP[.p] as $Y | select($Y | lg_v_active)
         | {key: $Y.key, path: .p, reasons, display: ($Y | lg_q_display), summary: $Y.summary,
            _n: (.reasons | length), _r: ($Y | lg_q_rank($K.R; $K.n))}]
        | sort_by(-._n, ._r, (.key // .path)) | map(del(._n, ._r)) as $CA
      | "ok",
        (if $mode == "json" then ({item: lg_rr_item($I), depth: $depth, neighbours: $NB, candidates: $CA} | tojson)
         else lg_rr_head($I),
           (if $NB == [] then "(no confirmed relations)"
            else $NB[] | $M.BYP[.path] as $Y
              | "\(.kind)\(if .depth > 1 then " (depth \(.depth), through \(.through | lg_q_one))" else "" end)  \((.key // .path) | lg_q_one)  via \(.via | lg_q_one) · \(lg_rr_tail($Y))" end),
           (if $CA == [] then "(no candidates)"
            else ($CA[0:15][] | $M.BYP[.path] as $Y
                  | "candidate  \((.key // .path) | lg_q_one)  \(.reasons | join("; ") | lg_q_one | lg_q_cut(160)) · \(lg_rr_tail($Y))"),
                 (if ($CA | length) > 15 then "… \(($CA | length) - 15) more candidates" else empty end) end)
         end)
  end
'

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_related() {
  local s depth=1
  _lg_init related
  _lg_r_ref
  if [ -n "$_OPT_depth" ]; then
    case "$_OPT_depth" in
      1|2|3) depth=$_OPT_depth ;;
      *) _lg_usage "--depth takes 1, 2 or 3 (got '$_OPT_depth')" ;;
    esac
  fi
  _LG_IX_NEED_CONTRACTS=1
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_RELATED" "$s.out" --arg ref "$_LG_RREF" --arg mode "$_LG_FORMAT" --argjson depth "$depth"
  _lg_r_finish related "$s.out"
}

# --- recheck ---------------------------------------------------------------------------

# ledger recheck <ref>: what to re-check when <ref> resolves or its
# contracts change (design §F.2) — its downstream items (they consume a
# contract it changes; or their relates name it root-cause / depends-on)
# and the items whose relates name it as a sibling (or with no kind): the
# open ones (lg_v_active), by severity then key. One line each: "<key>  via
# <via> · <status> · <summary>  → re-verify | close as superseded by <ref> |
# reshape" ("nothing to re-check for <ref>"). JSON: {item, dependents:
# [{key, path, via, display, summary, actions}]}.
# shellcheck disable=SC2016  # jq source
_LG_JQ_RECHECK="$_LG_JQ_REL_HEAD"'
lg_resolve($ref; $c[0]) as $R
| . as $ix
| if $R.r == "ambiguous" then "ambiguous\t\($R.v | join(", "))"
  elif $R.r == "archived" then "archived\t\($R.v)"
  elif $R.r != "item" then "none", (if $mode == "json" then ({item: null, ref: $ref} | tojson) else empty end)
  else
    lg_r_maps($ix) as $M
    | lg_q_ranks($c[0]) as $K
    | $M.BYP[$R.v] as $I
    | ($I.key // $I.path) as $rid
    | (reduce $ix.items[] as $i ({}; reduce ([$i.key] + ($i.aliases // []) | .[] | strings | ascii_downcase) as $k
         (.; if has($k) then . else .[$k] = $i.path end))) as $KM
    | [ (($I.neighbours.downstream // [])[] | {p: ($M.K2P[.key] // null), via}),
        ($ix.items[] | select(.path != $I.path) | .path as $yp | (.relates // [])[]
         | ((.kind // "sibling") | ascii_downcase) as $k
         | select(lg_rel_kinds | index([$k]) != null)
        | select(($KM[(.key // "") | ascii_downcase] // null) == $I.path) | {p: $yp, via: $k}) ]
      | map(select(.p != null)) | unique_by([.p, .via])
      | map($M.BYP[.p] as $Y | select($Y | lg_v_active)
            | {key: $Y.key, path: .p, via, display: ($Y | lg_q_display), summary: $Y.summary,
               actions: ["re-verify", "close as superseded by \($rid)", "reshape"], _r: ($Y | lg_q_rank($K.R; $K.n))})
      | sort_by(._r, (.key // .path), .via) | map(del(._r)) as $DEP
    | "ok",
      (if $mode == "json" then ({item: lg_rr_item($I), dependents: $DEP} | tojson)
       elif $DEP == [] then "nothing to re-check for \($rid | lg_q_one)"
       else $DEP[] | $M.BYP[.path] as $Y
         | "\((.key // .path) | lg_q_one)  via \(.via | lg_q_one) · \(lg_rr_tail($Y))  → \(.actions | join(" | ") | lg_q_one)"
       end)
  end
'

# shellcheck disable=SC2154  # _ARGS is set by _parse_args
cmd_ledger_recheck() {
  local s
  _lg_init recheck
  _lg_r_ref
  _LG_IX_NEED_CONTRACTS=1
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_RECHECK" "$s.out" --arg ref "$_LG_RREF" --arg mode "$_LG_FORMAT"
  _lg_r_finish recheck "$s.out"
}

# --- sweep -----------------------------------------------------------------------------

# ledger sweep --plan P | --files F… | --contracts C… | --keys K… (any
# together): the planning sweep (design §F.3) — a "## Related work"
# table, `| Item | Why related | Mark |`, one row per item, the Mark empty:
# confirmed rows first, then candidates; each by severity, then key or path.
#   confirmed: an item the input names (a key, or a row of the plan's own
#     Related work table: "named"); the confirmed neighbours of a named item
#     ("upstream of K (via V)", …); an item that changes or consumes an
#     input contract; an item that lists an input file in its paths
#     ("lists F"), or whose spec, plan or handoff links is an input file or
#     the plan ("linked from F");
#   candidates: lg_r_candidates of a named item ("<reason> (K)"); an item
#     whose file an input contract's defined_in matches ("its file f
#     defines C"); an item naming a contract whose defined_in matches an
#     input file ("names C, defined in F").
# Rows other than named items are open work only (lg_v_active). --plan P
# reads the plan: its backticked spans that are existing files of the work
# tree (paths), the contract ids (index contracts) found in its text, the
# words that are a key or alias, and the first cells of its Related work
# table (resolved as show resolves; kept, and listed, even when nothing
# else relates them). --files takes any repository path (a plan may name
# files it will create); --contracts ids must be contracts (registry or
# adapter) and --keys must each resolve to one item (else exit 3). Text:
# the heading, a blank line and the table — nothing else (paste it into the
# plan). JSON: {rows: [{key, path, confirmed, why}], table}.

# _lg_r_plan_scan <plan> <spans-out> <cells-out>: the plan's inline code
# spans (outside fenced blocks), one per line, and the first cells of the
# data rows of its "Related work" tables.
_lg_r_plan_scan() {
  LC_ALL=C awk -v spans="$2" -v cells="$3" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { printf "" > spans; printf "" > cells; fence = "" }
    {
      sub(/\r$/, "")
      line = $0
      if (fence != "") { if (index(trim(line), fence) == 1) fence = ""; next }
      if (match(trim(line), /^(```|~~~)/)) { fence = substr(trim(line), 1, 3); tbl = 0; next }
      rest = line
      while ((i = index(rest, "`")) > 0) {
        rest = substr(rest, i + 1)
        j = index(rest, "`")
        if (j == 0) break
        span = trim(substr(rest, 1, j - 1))
        if (span != "") print span > spans
        rest = substr(rest, j + 1)
      }
      if (match(line, /^#+[ \t]/)) {
        lvl = RLENGTH - 1
        h = tolower(trim(substr(line, RLENGTH + 1))); sub(/[ \t]*#*[ \t]*$/, "", h)
        if (insec && lvl <= seclvl) insec = 0
        if (!insec && h == "related work") { insec = 1; seclvl = lvl }
        tbl = 0
        next
      }
      if (!insec) next
      if (line !~ /^[ \t]*\|/) { tbl = 0; next }
      tbl++
      if (tbl == 1) next
      if (tbl == 2 && line ~ /^[ \t]*\|?[ \t]*:?-+/) next
      c = trim(line)
      if (substr(c, 1, 1) == "|") c = substr(c, 2)
      gsub(/\\\|/, "\001", c)
      k = index(c, "|"); if (k) c = substr(c, 1, k - 1)
      gsub(/\001/, "|", c)
      c = trim(c)
      while (c ~ /^[`*_]/) c = substr(c, 2)
      while (c ~ /[`*_]$/) c = substr(c, 1, length(c) - 1)
      if (c != "") print c > cells
    }' "$1"
}

# _lg_r_file_contracts <index> <files-lines> <out.json>: {file: [contract
# ids]} — the index contracts whose defined_in matches each file.
_lg_r_file_contracts() {
  local ix="$1" files="$2" out="$3" s
  _lg_scratch_name
  s=$_LG_SN
  jq -r '(.contracts // [])[] | .id as $i | (.defined_in // [])[] | select(test("[[:cntrl:]]") | not) | "\($i)\u0001\(.)"' \
    "$ix" > "$s.g" || _lg_die "jq failed (contract globs)"
  LC_ALL=C awk -v globs="$s.g" "$_LG_AWK_GLOB"'
    BEGIN { while ((getline l < globs) > 0) { t = index(l, "\001"); k++; if (gx_add(k, substr(l, t + 1))) ID[k] = substr(l, 1, t - 1) } }
    { gx_match($0); for (i = 1; i <= GX_MN; i++) print $0 "\t" ID[GX_M[i]] }' "$files" > "$s.hits" \
    || _lg_die "cannot match the files against the contracts"
  jq -R -n -c 'reduce (inputs | split("\t")) as $x ({}; .[$x[0]] += [$x[1]]) | map_values(unique)' "$s.hits" > "$out" \
    || _lg_die "jq failed (file contracts)"
}

# shellcheck disable=SC2016  # jq source
_LG_JQ_SWEEP_INPUT="$_LG_JQ_RESOLVE_DEFS"'
# The plan: contract ids in its text, words that are keys, its table cells;
# then each --keys value and each cell resolved. Prints "bad\t<what>" lines
# for --keys / --contracts values that are not items / contracts, else one
# JSON object {keys: [paths], contracts: [ids]}.
. as $ix
| ([($ix.contracts // [])[] | .id]) as $ids
| ($text | if . == "" then [] else [$ids[] as $k | select(test("(^|[^A-Za-z0-9_:./-])" + ($k | lg_q_re) + "($|[^A-Za-z0-9_-])")) | $k] end) as $pc
| (reduce $ix.items[] as $i ({}; reduce ([$i.key] + ($i.aliases // []) | .[] | strings | ascii_downcase) as $k
     (.; if has($k) then . else .[$k] = $i.path end))) as $KM
| ($text | if . == "" then [] else [splits("[^A-Za-z0-9_-]+") | ascii_downcase | select(. != "") | ($KM[.] // empty)] end) as $pk
| [$keys[] as $k | {v: $k, r: ($ix | lg_resolve($k; $c[0]))}] as $KR
| [$cells[] as $k | $ix | lg_resolve($k; $c[0]) | select(.r == "item") | .v] as $ck
| ([$KR[] | select(.r.r != "item") | "bad\t--keys \(.v | tojson) is not one item" + (if .r.r == "ambiguous" then " (several: \(.r.v | join(", ")))" else "" end)]
   + [$contracts[] | select(. as $k | $ids | index([$k]) == null) | "bad\t--contracts \(tojson) is not a contract (registry or contracts adapter)"]) as $bad
| if $bad != [] then $bad[]
  else {keys: ([$KR[].r.v] + $pk + $ck | unique), contracts: ($contracts + $pc | unique)} | tojson end
'

# shellcheck disable=SC2016  # jq source
_LG_JQ_SWEEP='
def ordered_unique: reduce .[] as $x ([]; if index([$x]) != null then . else . + [$x] end);
def cell: lg_q_one | gsub("\\|"; "\\|");
. as $ix
| lg_r_maps($ix) as $M
| lg_q_ranks($c[0]) as $K
| $in[0] as $IN
| ($files + (if $plan == "" then [] else [$plan] end)) as $links
| [ ($IN.keys[] | {p: ., r: "named", c: true}),
    ($IN.keys[] as $kp | $M.BYP[$kp] as $I | ($I.key // $I.path) as $iid | ($I.neighbours // {}) as $n
     | ((($n.upstream // [])[] | {k: .key, r: "upstream of \($iid) (via \(.via))"}),
        (($n.downstream // [])[] | {k: .key, r: "downstream of \($iid) (via \(.via))"}),
        (($n.siblings // [])[] | {k: .key, r: "sibling of \($iid) (via \(.via))"}))
     | {p: ($M.K2P[.k] // null), r, c: true}),
    ($IN.contracts[] as $k | ($M.C[$k] // [])[] as $p | $M.BYP[$p] as $Y
     | {p: $p, r: (if (($Y.changes // []) | index([$k])) != null then "changes \($k)" else "consumes \($k)" end), c: true}),
    ($files[] as $f | ($M.P[$f] // [])[] | {p: ., r: "lists \($f)", c: true}),
    ($ix.items[] | . as $Y | [($Y.docs.spec // [])[], ($Y.docs.plan // [])[], ($Y.docs.handoff // [])[]] as $d
     | $links[] | select(. as $f | $d | index([$f]) != null) | {p: $Y.path, r: "linked from \(.)", c: true}),
    ($IN.keys[] as $kp | $M.BYP[$kp] as $I | ($I.key // $I.path) as $iid
     | lg_r_candidates($I; $M)[] | .p as $p | .reasons[] | {p: $p, r: "\(.) (\($iid))", c: false}),
    ($IN.contracts[] as $k | ($M.DI[$k] // [])[] | {p: .p, r: "its file \(.f) defines \($k)", c: false}),
    ($files[] as $f | ($fc[0][$f] // [])[] as $k | ($M.C[$k] // [])[] | {p: ., r: "names \($k), defined in \($f)", c: false}) ]
| map(select(.p != null and $M.BYP[.p] != null))
| group_by(.p)
| map(.[0].p as $p | $M.BYP[$p] as $Y
      | select(any(.[]; .r == "named") or ($Y | lg_v_active))
      | {key: $Y.key, path: $p, confirmed: any(.[]; .c),
         why: ((map(select(.c)) + map(select(.c | not))) | map(.r) | ordered_unique),
         _r: ($Y | lg_q_rank($K.R; $K.n))})
| sort_by((if .confirmed then 0 else 1 end), ._r, (.key // .path)) | map(del(._r)) as $ROWS
| (["## Related work", "", "| Item | Why related | Mark |", "|---|---|---|"]
   + [$ROWS[] | "| \((.key // .path) | cell) | \(.why | join("; ") | cell) | |"]) as $T
| "ok", (if $mode == "json" then ({rows: $ROWS, table: ($T | join("\n"))} | tojson) else $T[] end)
'

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_sweep() {
  local s ix plan="" f text="" n
  _lg_init sweep
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}' (give --plan, --files, --contracts or --keys)"
  if [ -z "$_OPT_plan" ] && [ "${#_OPTV_files[@]}" = 0 ] && [ "${#_OPTV_contracts[@]}" = 0 ] && [ "${#_OPTV_keys[@]}" = 0 ]; then
    _lg_usage "give --plan <path>, --files <path>…, --contracts <id>… or --keys <key>…"
  fi
  _lg_scratch_name
  s=$_LG_SN
  : > "$s.files"
  : > "$s.spans"
  : > "$s.cells"
  if [ -n "$_OPT_plan" ]; then
    plan=$_OPT_plan
    while :; do case "$plan" in ./*) plan=${plan#./} ;; *) break ;; esac; done
    case "$plan" in -*) plan="./$plan" ;; esac
    [ -f "$plan" ] || _lg_usage "--plan '$_OPT_plan' is not a file"
    text="$s.plan"
    cat -- "$plan" > "$text" 2>/dev/null || _lg_die "cannot read the plan '$_OPT_plan'"
    _lg_r_plan_scan "$text" "$s.spans" "$s.cells" || _lg_die "cannot read the plan '$_OPT_plan'"
    # Backticked spans that are files of the work tree.
    while IFS= read -r f; do
      while :; do case "$f" in ./*) f=${f#./} ;; *) break ;; esac; done
      case "$f" in ''|/*|-*|*'../'*) continue ;; esac
      if [ -f "$f" ]; then printf '%s\n' "$f"; fi
    done < "$s.spans" >> "$s.files"
  fi
  for f in ${_OPTV_files[@]+"${_OPTV_files[@]}"}; do
    while :; do case "$f" in ./*) f=${f#./} ;; *) break ;; esac; done
    case "$f" in *$'\n'*) _lg_usage "--files: a path cannot hold a newline" ;; esac
    [ -n "$f" ] || _lg_usage "--files: an empty path"
    printf '%s\n' "$f" >> "$s.files"
  done
  LC_ALL=C awk '!seen[$0]++' "$s.files" > "$s.files.u" || _lg_die "cannot list the files"
  _LG_IX_NEED_CONTRACTS=1
  ix=$(_lg_index) || exit "$?"
  # The inputs, checked and resolved.
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" \
    --rawfile text "${text:-/dev/null}" \
    --argjson keys "$(jq -nc '$ARGS.positional' --args ${_OPTV_keys[@]+"${_OPTV_keys[@]}"})" \
    --argjson contracts "$(jq -nc '$ARGS.positional' --args ${_OPTV_contracts[@]+"${_OPTV_contracts[@]}"})" \
    --argjson cells "$(jq -R -s -c 'split("\n") | map(select(. != ""))' "$s.cells")" \
    "$_LG_JQ_INCLUDE$_LG_JQ_SWEEP_INPUT" "$ix" > "$s.in" || _lg_die "jq failed (ledger sweep inputs)"
  if grep -q '^bad	' "$s.in"; then
    n=$(grep '^bad	' "$s.in" | head -n 1 | cut -f 2-)
    _lg_usage "$n"
  fi
  _lg_r_file_contracts "$ix" "$s.files.u" "$s.fc"
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" --slurpfile in "$s.in" --slurpfile fc "$s.fc" \
    --argjson files "$(jq -R -s -c 'split("\n") | map(select(. != ""))' "$s.files.u")" \
    --arg plan "$plan" --arg mode "$_LG_FORMAT" \
    "$_LG_JQ_INCLUDE$_LG_JQ_SWEEP" "$ix" > "$s.out.all" || _lg_die "jq failed (ledger sweep)"
  IFS= read -r _LG_QHEAD < "$s.out.all" || _LG_QHEAD=""
  [ "$_LG_QHEAD" = ok ] || _lg_die "internal: ledger sweep: unexpected query result '$_LG_QHEAD'"
  tail -n +2 "$s.out.all" > "$s.out" || _lg_die "cannot write $s.out"
  _lg_q_finish "$s.out"
}

# shellcheck shell=bash
# scripts/ledger/relations.sh — related work (design §F): message trailers,
# the re-check markers the index carries, and the verbs `ledger related`,
# `ledger recheck`, `ledger sweep`, `ledger suggest`. Sourced by lib.sh;
# uses lib.sh's _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, _lg_cfg, index.sh's
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
# Hosted items (config items.adapter; index.sh "Hosted items", controller
# ruling I2) take part by time, the hosted issue being the source of
# truth: a hosted source S is terminal as the index has it and landed at
# its close time ("closed", else "updated"); a hosted X was last touched
# at its "updated" (any update of the issue clears its markers). Pairs
# with a hosted side compare times: S's landing (a file source: its event
# commit E's committer time) against X's touch (a file X: L's committer
# time); a contract change counts for a hosted X when E's committer time
# is after its "updated". Commit times come from one `git log --no-walk
# --stdin` over the commits such pairs need, and from the contract scan
# (%ct); a hosted consumer scans the base's commits since the oldest such
# "updated" (--since-as-filter; git < 2.37: --since) beside the bounded
# scan of the file consumers.
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
# tr_since(file) reads _lg_tr_incl's set ("" or an empty file: no
# cutoff; else "on", then the commits whose claims still count — the since
# commit's descendants); tr_cut(commit), after tr_match, drops the claims,
# claims_by_path and claims_by_ref matches of every other commit —
# contract_change and ack matches stay (Task 16c U12, fix round 1).
# shellcheck disable=SC2016  # awk source
_LG_AWK_TRAILER='
function tr_since(f,   l) {
  if (f == "") return
  if ((getline l < f) > 0 && l == "on") {
    TRON = 1
    while ((getline l < f) > 0) TRI[l] = 1
  }
  close(f)
}
function tr_cut(c,   i, j) {
  if (!TRON || (c in TRI)) return
  j = 0
  for (i = 1; i <= TRM; i++) {
    if (TRMK[i] == "claims" || TRMK[i] == "claims_by_path" || TRMK[i] == "claims_by_ref") continue
    j++; TRMK[j] = TRMK[i]; TRMV[j] = TRMV[i]
  }
  TRM = j
}
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

# _lg_tr_since → _LG_TR_MODE, _LG_TR_SINCE (Task 16c U12; fix round 1):
# config trailers.since, resolved once per run. Claim trailers count only
# in the commits that are descendants of the since commit (not the commit
# itself: "after" it, as U11's adoption point reads `--ancestry-path
# <adoption>..<base>`); in every other commit — its ancestors, and a
# commit on a branch forked before it, merged or still in flight — they
# are ignored.
#   null (the default): _LG_TR_MODE off, _LG_TR_SINCE "" — every claim
#     trailer counts;
#   a commit-ish (an abbreviated id will do): mode commit, its commit;
#   "adoption": the adoption commit (index.sh _lg_adoption_commit: the
#     first commit on config base to add docs/ledger/config.json); while
#     the base has none, mode all, _LG_TR_SINCE "*all" — every commit
#     predates adoption, no claim trailer counts (U11: every terminal item
#     is pre-adoption); a base that does not resolve: off; in a shallow
#     clone whose boundary is where config.json first shows (the real
#     adoption commit is out of reach): dies 2, as a since naming no
#     commit here.
# A value that is not a string, or names no commit here: dies 2.
# _lg_tr_incl builds the per-walk set tr_cut reads.
_LG_TR_SINCE_SET=""
_LG_TR_SINCE=""
_LG_TR_MODE=off
_lg_tr_since() {
  local v="" base_ref="" b c="" s
  [ -z "$_LG_TR_SINCE_SET" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  # shellcheck disable=SC2016  # jq source
  _lg_cfg '(.trailers.since | if . == null then "n" elif type == "string" then "s" + (gsub("[\n\r]"; " ")) else "b" end),
    (.base | if type == "string" then . else "" end)' > "$s.cfg"
  { IFS= read -r v; IFS= read -r base_ref; } < "$s.cfg" || true
  _LG_TR_MODE=off
  case "$v" in
    n) ;;
    b|s) _lg_die "config trailers.since must be a commit, \"adoption\" or null" ;;
    sadoption)
      b=""
      case "$base_ref" in
        -*|'') ;;
        *) b=$(git rev-parse -q --verify "$base_ref^{commit}" 2>/dev/null) || b="" ;;
      esac
      if [ -n "$b" ]; then
        _lg_adoption_commit "$b"
        if [ "$_LG_ADOPTC" = "?" ]; then
          _lg_die "config trailers.since \"adoption\": the adoption commit is beyond this shallow clone's history (config.json first shows at its boundary); deepen it (git fetch --unshallow) or name the commit"
        elif [ -n "$_LG_ADOPTC" ]; then
          c=$_LG_ADOPTC
          _LG_TR_MODE=commit
        else
          c="*all"
          _LG_TR_MODE=all
        fi
      fi ;;
    s-*) _lg_die "config trailers.since names no commit: '${v#s}'" ;;
    s*)
      c=$(git rev-parse -q --verify "${v#s}^{commit}" 2>/dev/null) \
        || _lg_die "config trailers.since names no commit here: '${v#s}' (a shallow clone may lack it)"
      _LG_TR_MODE=commit ;;
    *) _lg_die "internal: trailers.since read as '$v'" ;;
  esac
  _LG_TR_SINCE=$c
  _LG_TR_SINCE_SET=1
}

# _lg_tr_incl <out> <revs-file>: the set tr_since / tr_cut read for one
# walk over <revs-file>'s revisions (one per line, as git log --stdin
# takes them: "^<bottom>", "<a>..<tip>", "<tip>"). Mode off: an empty file
# (nothing cut). Otherwise "on", then — mode commit — the descendants of
# the since commit that the walk's tips reach: one `git rev-list
# --ancestry-path ^<since> <tips>` (no process per commit); mode all:
# "on" alone (every claim cut).
_lg_tr_incl() {
  local out="$1" revs="$2" s
  _lg_tr_since
  : > "$out" || _lg_die "cannot write $out"
  [ "$_LG_TR_MODE" != off ] || return 0
  printf 'on\n' > "$out" || _lg_die "cannot write $out"
  [ "$_LG_TR_MODE" = commit ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  # The tips: "<a>..<tip>" → <tip>; a "^<bottom>" is no tip.
  { printf '^%s\n' "$_LG_TR_SINCE"
    LC_ALL=C awk '/^\^/ || $0 == "" { next } { i = index($0, ".."); print (i ? substr($0, i + 2) : $0) }' "$revs"; } > "$s.revs" \
    || _lg_die "cannot write $s.revs"
  git rev-list --ancestry-path --stdin < "$s.revs" >> "$out" 2> "$s.err" \
    || _lg_die "git rev-list failed (config trailers.since): $(head -n 3 "$s.err" 2>/dev/null)"
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
# _LG_AWK_TRAILER). In git log order, then line order. A commit that is
# no descendant of config trailers.since (_lg_tr_since, _lg_tr_incl)
# prints no claims, claims_by_path or claims_by_ref line.
_lg_msg_claims() {
  local s a
  for a in "$@"; do
    case "$a" in -*|'') _lg_die "internal: _lg_msg_claims: not a revision: '$a'" ;; esac
  done
  _lg_scratch_name
  s=$_LG_SN
  _lg_trailers "$s.tr"
  printf '%s\n' "$@" > "$s.revl" || _lg_die "cannot write $s.revl"
  _lg_tr_incl "$s.tri" "$s.revl"
  git -c log.showSignature=false log --no-color --format='%x01%H%n%B' "$@" -- > "$s.msg" 2> "$s.err" \
    || _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"
  LC_ALL=C awk -v tr="$s.tr" -v trx="$s.tri" "$_LG_AWK_TRAILER"'
    BEGIN { tr_load(tr); tr_since(trx) }
    substr($0, 1, 1) == "\001" { c = substr($0, 2); next }
    { tr_match($0); tr_cut(c); for (i = 1; i <= TRM; i++) print c "\t" TRMK[i] "\t" TRMV[i] }' "$s.msg"
}

# --- Re-check (index.sh) ------------------------------------------------------------

# The contract-change scan the re-check program runs (system()) once it
# knows its bound: bash <this> <base> <bound|""> <dirs> <clog> <msg> <globs 0|1>
# [since] — the files the consumed contracts' defined_in name, changed in
# <base> ^<bound> (tr'd: one token per line, a commit led by \002 and
# followed by " <committer time>"), and the messages of the same commits
# ("\001<commit> <committer time>"); [since]: only the commits committed
# then or later (the hosted consumers' scan).
# shellcheck disable=SC2016  # bash source
_LG_SH_RECHECK_SCAN='set -o pipefail
B=$1 bound=$2 dirs=$3 clog=$4 msg=$5 globs=$6 since=${7:-}
rng=("$B")
if [ -n "$bound" ]; then rng+=("^$bound"); fi
if [ -n "$since" ]; then
  if git log -1 --since-as-filter=2000-01-01T00:00:00Z --format=%H "$B" -- > /dev/null 2>&1; then
    rng+=("--since-as-filter=$since")
  else
    rng+=("--since=$since")
  fi
fi
specs=()
while IFS= read -r d; do specs+=("$d"); done < "$dirs"
: > "$clog"
if [ "$globs" = 1 ]; then
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --full-history --format="%x02%H %ct" \
    --name-only -z "${rng[@]}" -- ${specs[@]+"${specs[@]}"} | tr "\n\000" "\001\n" > "$clog" || exit 1
fi
git -c log.showSignature=false log --no-color --format="%x01%H %ct%n%B" "${rng[@]}" -- > "$msg" || exit 1
'

# The program: -v base, graphf, tab, ev, termf, cg (the consumed contracts'
# globs, "<id>\001<glob>"), trf (the contract_change trailer names), sh,
# scan, dirs, clog, msg, scanerr, hostf (the hosted items' times,
# index.sh; /dev/null without), needf / ctf (the commit-time lookup's
# input and output). One pass: the graph and the touches, the bound, the
# scans (system), the commit times a hosted pair needs (system), the
# decision. Prints "<n>\t<entry>" per marker (n: the item's place, tab's
# O lines).
# shellcheck disable=SC2016  # awk source
_LG_AWK_RECHECK='
function shq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
# addev(k, c): commit c changed contract k (each pair once).
function addev(k, c) { if ((k, c) in SEENEV) return; SEENEV[k, c] = 1; NEV[k]++; EV[k, NEV[k]] = c }
# commitct(t): t is "<commit> <committer time>": the commit, its time kept in CT.
function commitct(t,   sp) {
  sp = index(t, " ")
  if (!sp) return t
  CT[substr(t, 1, sp - 1)] = substr(t, sp + 1) + 0
  return substr(t, 1, sp - 1)
}
# scanrun(bound, since, cl, ms): run the scan into cl / ms and read its
# events (files under a consumed contract; Contract-Change lines).
function scanrun(bound, since, cl, ms,   rc, t, c, h, i, n, X, v) {
  rc = system(shq(sh) " " shq(scan) " " shq(base) " " shq(bound) " " shq(dirs) " " shq(cl) " " shq(ms) " " globs " " shq(since) " 2> " shq(scanerr))
  if (rc != 0) { print "scan failed (rc " rc ")" > "/dev/stderr"; exit 2 }
  c = ""
  while ((getline t < cl) > 0) {
    while (substr(t, 1, 1) == "\001") t = substr(t, 2)
    if (substr(t, 1, 1) == "\002") { c = commitct(substr(t, 2)); continue }
    if (t == "" || c == "") continue
    if (!(t in HIT)) {
      gx_match(t); h = ""
      for (i = 1; i <= GX_MN; i++) h = h SUBSEP ID[GX_M[i]]
      HIT[t] = h
    }
    n = split(substr(HIT[t], 2), X, SUBSEP)
    for (i = 1; i <= n; i++) addev(X[i], c)
  }
  close(cl)
  c = ""
  while ((getline t < ms) > 0) {
    if (substr(t, 1, 1) == "\001") { c = commitct(substr(t, 2)); continue }
    tr_match(t)
    for (i = 1; i <= TRM; i++) { v = TRMV[i]; sub(/[ \t].*/, "", v); if (v != "" && c != "") addev(v, c) }
  }
  close(ms)
}
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
  # The hosted items: their landing and touch times (epoch s; "" unknown).
  while ((getline l < hostf) > 0) {
    split(l, a, "\t"); HOST[a[1]] = 1; HL[a[1]] = a[2]; HU[a[1]] = a[3]; HUI[a[1]] = a[4]
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
  kb = -1; nob = 0; cons = 0; hcons = 0; hmin = ""
  for (i = 1; i <= no; i++) {
    # A hosted consumer: the commits since its last update (scanned apart).
    if (OC[i] != "" && (OP[i] in HOST) && HU[OP[i]] != "") {
      if (!hcons || HU[OP[i]] + 0 < hmin + 0) { hmin = HU[OP[i]]; hminI = HUI[OP[i]] }
      hcons = 1
      continue
    }
    if (OC[i] == "" || !(OP[i] in LAST)) continue
    l = LAST[OP[i]]; cons = 1
    if (!(l in ENTER)) { nob = 1; continue }
    if (l in MIDX) k = MIDX[l]
    else { side(l); k = KMIN[l] }
    if (k < 0) nob = 1
    else if (k > kb) kb = k
  }
  if (cons || hcons) {
    globs = 0
    while ((getline l < cg) > 0) {
      t = index(l, "\001"); g++
      if (gx_add(g, substr(l, t + 1))) { ID[g] = substr(l, 1, t - 1); globs = 1 }
    }
    # Contract-Change: <id> … lines (the first word is the id).
    tr_load(trf)
    # The file consumers: B ^M_k. The hosted ones: the base commits since the
    # oldest of their updates. (An event either scan finds is decided per
    # item below: anc() for a file item, the time for a hosted one.)
    if (cons) scanrun((nob || kb < 0) ? "" : MAIN[kb], "", clog, msg)
    if (hcons) scanrun("", hminI, clog ".h", msg ".h")
  }
  while ((getline l < termf) > 0) TERM[l] = 1
  # The commit times a pair with a hosted side needs: the last commit L of
  # a file X (a hosted source), the event commit of a file source (a hosted X).
  nn = 0
  printf "" > needf
  for (i = 1; i <= no; i++) {
    p = OP[i]; hp = (p in HOST)
    if (!hp && !(p in LAST)) continue
    ns = split(OS[i], b, "\003")
    for (j = 1; j <= ns; j++) {
      q = b[j]
      if (!(q in TERM)) continue
      if (q in HOST) { if (!hp && !(LAST[p] in NEEDC)) { NEEDC[LAST[p]] = 1; print LAST[p] > needf; nn++ } }
      else if (hp && (q in LAST) && !(LAST[q] in NEEDC)) { NEEDC[LAST[q]] = 1; print LAST[q] > needf; nn++ }
    }
  }
  close(needf)
  if (nn > 0) {
    rc = system("git log --no-walk=unsorted --stdin " shq("--format=%H %ct") " < " shq(needf) " > " shq(ctf) " 2>> " shq(scanerr))
    if (rc != 0) { print "commit times failed (rc " rc ")" > "/dev/stderr"; exit 2 }
    while ((getline t < ctf) > 0) commitct(t)
  }
  for (i = 1; i <= no; i++) {
    p = OP[i]
    hp = (p in HOST)
    if (hp) { if (HU[p] == "") continue; tu = HU[p] + 0 }
    else { if (!(p in LAST)) continue; l = LAST[p] }
    ns = split(OS[i], b, "\003")
    for (j = 1; j <= ns; j++) {
      q = b[j]
      if (!(q in TERM)) continue
      if (q in HOST) {
        if (HL[q] == "") continue
        tq = HL[q] + 0
        if (hp ? (tq > tu) : ((l in CT) && tq > CT[l])) print ON[i] "\t" SK[q]
      } else if (q in LAST) {
        if (hp ? ((LAST[q] in CT) && CT[LAST[q]] > tu) : !anc(LAST[q], l)) print ON[i] "\t" SK[q]
      }
    }
    nc = split(OC[i], cc, "\003")
    for (j = 1; j <= nc; j++) {
      k = cc[j]
      for (x = 1; x <= NEV[k]; x++) {
        e = EV[k, x]
        if (hp ? ((e in CT) && CT[e] > tu) : !anc(e, l)) { print ON[i] "\t" k; break }
      }
    }
  }
  exit 0
}'

# _lg_ix_recheck <base-commit|""> <tab> <current-ids|""> <out.tsv> <dirs>
# <dated-commit|""> [hosted-times]: the re-check markers (see the header)
# into <out.tsv>,
# one line per marked item: "<n>\t<[entries] as JSON>", n its place among
# the items (index.sh writes them into the item lines). <tab>:
# lg_relations' tab lines (defs.jq). <current-ids>: the working tree's
# "<path>\t<blob id>" (index.sh _lg_ix_effective); "" when the items are
# B's own (--rev). <dirs>: the item globs' directories (the dates walk's).
# <dated-commit>: the commit the dates walk read (HEAD; B's events are
# derived from its map, index.sh _lg_ix_events_base). [hosted-times]:
# index.sh's "<ref>\t<landed>\t<updated>\t<updated ISO>" lines (a hosted
# source is terminal as the index has it, whatever the base holds). No
# base, or no open item to check: empty.
_lg_ix_recheck() {
  local B="$1" tab="$2" cur="$3" out="$4" dirs="$5" H="$6" ht="${7:-}" s
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
  # A hosted source: terminal as the index has it (no blob at the base).
  if [ -n "$ht" ] && [ -s "$ht" ]; then
    LC_ALL=C awk -v ht="$ht" 'BEGIN { FS = "\002"; while ((getline l < ht) > 0) { t = index(l, "\t"); H[substr(l, 1, t - 1)] = 1 } }
      $1 == "S" && $4 == 1 && ($2 in H) { print $2 }' "$tab" >> "$s.term" || _lg_die "cannot list the hosted re-check sources"
  else
    ht=/dev/null
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
      -v hostf="$ht" -v needf="$s.need" -v ctf="$s.ct" \
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

# --- suggest ---------------------------------------------------------------------------

# ledger suggest <ref> (3.4.0; ledger new --suggest-contracts runs the same
# query after its write): contracts an item might declare — never written.
#   changes   each contract whose defined_in matches a file the item lists
#             (paths; the index's path_contracts): "lists <f>, which
#             defines it";
#   consumes  each contract a related item changes or consumes — its
#             confirmed neighbours (upstream, downstream, siblings, any
#             class) and the open candidates related lists (lg_r_candidates,
#             lg_v_active): "<key> changes|consumes it (<kind> via <via>)"
#             ("(<kind>)" when via is the kind), "… (candidate: <reasons>)".
# A contract the item already declares on that side is left out; only index
# contracts (registry or contracts adapter) are offered — what link takes.
# One entry per (field, contract), its reasons and sources sorted by the
# related item's key (or the file); entries changes first, then by the
# number of reasons (most first), then contract id.
# Text: the item's line (as related), "<field>  <contract>  <reasons>" each
# (reasons joined "; ", cut at 200), then "confirm with: ledger link <key
# or path> --changes a,b --consumes c"; "(no contract candidates)" when
# none. JSON: {item, declared: {changes, consumes}, candidates: [{field,
# contract, reasons, sources: [{kind: "file", file} | {kind, key, path,
# side, why}]}]}; unknown: {item: null, ref} (exit 1).

# lg_sg_text($head): the text lines of a suggest object ($head: with the
# item's line first).
# shellcheck disable=SC2016  # jq source
_LG_JQ_SG_TEXT_DEFS='
def lg_sg_text($head):
  . as $O
  | (($O.item.key // $O.item.path) | lg_q_one) as $id
  | (if $head then
       "\($id)  \(($O.item.ledger // "—") | lg_q_one)  \(($O.item.severity // "—") | lg_q_one)  \($O.item.display) — \(($O.item.summary // "(no summary)") | lg_q_one | lg_q_cut(100))"
     else empty end),
    (if $O.candidates == [] then "(no contract candidates)"
     else ($O.candidates[] | "\(.field)  \(.contract | lg_q_one)  \(.reasons | join("; ") | lg_q_one | lg_q_cut(200))"),
       ("confirm with: ledger link \($id)"
        + ([("changes", "consumes") as $f | [$O.candidates[] | select(.field == $f) | .contract] as $cs
            | select($cs != []) | " --\($f) \($cs | join(",") | lg_q_one)"] | join("")))
     end);
'

# shellcheck disable=SC2016  # jq source
_LG_JQ_SUGGEST="$_LG_JQ_REL_HEAD$_LG_JQ_SG_TEXT_DEFS"'
lg_resolve($ref; $c[0]) as $R
| . as $ix
| if $R.r == "ambiguous" then "ambiguous\t\($R.v | join(", "))"
  elif $R.r == "archived" then "archived\t\($R.v)"
  elif $R.r != "item" then "none", (if $mode == "json" then ({item: null, ref: $ref} | tojson) else empty end)
  else
    lg_r_maps($ix) as $M
    | $M.BYP[$R.v] as $I
    | [($ix.contracts // [])[] | .id] as $ids
    | (($I.changes // []) | unique) as $dch
    | (($I.consumes // []) | unique) as $dco
    | ($I.neighbours // {}) as $n
    | ([(($n.upstream // [])[] | . + {kind: "upstream"}), (($n.downstream // [])[] | . + {kind: "downstream"}),
        (($n.siblings // [])[] | . + {kind: "sibling"})]
       | map(($M.K2P[.key] // null) as $p | select($p != null and $p != $I.path) | {kind, p: $p, why: .via})) as $NB
    | ($NB | map(.p)) as $nbp
    | [lg_r_candidates($I; $M)[] | .p as $p | select($nbp | index([$p]) == null) | select($M.BYP[$p] | lg_v_active)
       | {kind: "candidate", p: $p, why: (.reasons | join("; "))}] as $CA
    | [ ((($I.paths // []) | unique)[] as $f | ($M.D[$f] // [])[]
         | {field: "changes", contract: ., r: "lists \($f), which defines it", src: {kind: "file", file: $f}, o: $f}),
        (($NB + $CA)[] as $e | $M.BYP[$e.p] as $Y | ($Y.key // $Y.path) as $yid
         | ((($Y.changes // []) | unique)[] | {side: "changes", c: .}), ((($Y.consumes // []) | unique)[] | {side: "consumes", c: .})
         | {field: "consumes", contract: .c,
            r: "\($yid) \(.side) it (\(if $e.kind == "candidate" then "candidate: \($e.why)" elif $e.why == $e.kind then $e.kind else "\($e.kind) via \($e.why)" end))",
            src: {kind: $e.kind, key: $Y.key, path: $Y.path, side: .side, why: $e.why}, o: $yid}) ]
    | map(select(.contract as $k | ($ids | index([$k])) != null)
          | select(.contract as $k | (if .field == "changes" then $dch else $dco end) | index([$k]) == null))
    | group_by([.field, .contract])
    | map(sort_by([.o, .src.kind]) | reduce .[] as $x ([]; if any(.[]; .r == $x.r) then . else . + [$x] end)
          | {field: .[0].field, contract: .[0].contract, reasons: map(.r), sources: map(.src)})
    | sort_by([(if .field == "changes" then 0 else 1 end), -(.reasons | length), .contract]) as $CS
    | {item: lg_rr_item($I), declared: {changes: $dch, consumes: $dco}, candidates: $CS} as $O
    | "ok", (if $mode == "json" then ($O | tojson) else ($O | lg_sg_text(true)) end)
  end
'

# shellcheck disable=SC2154  # _ARGS is set by _parse_args
cmd_ledger_suggest() {
  local s
  _lg_init suggest
  _lg_r_ref
  _LG_IX_NEED_CONTRACTS=1
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_SUGGEST" "$s.out" --arg ref "$_LG_RREF" --arg mode "$_LG_FORMAT"
  _lg_r_finish suggest "$s.out"
}

# _lg_suggest_into <path> <lines-file> <payload-file> (ledger new
# --suggest-contracts): the item's candidates appended to <lines-file> (no
# item line) and added to the JSON payload as "candidates".
_lg_suggest_into() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  _lg_q_run "$_LG_JQ_SUGGEST" "$s.sg" --arg ref "$1" --arg mode json
  [ "$_LG_QHEAD" = ok ] || _lg_die "internal: ledger new --suggest-contracts: '$1' did not resolve ($_LG_QHEAD)"
  jq -L "$_LG_LIB" -r "$_LG_JQ_INCLUDE$_LG_JQ_SG_TEXT_DEFS"'lg_sg_text(false)' "$s.sg" | tr -d '\000-\010\013-\037' >> "$2" \
    || _lg_die "jq failed (suggestions)"
  if ! jq -c --slurpfile sg "$s.sg" '. + {candidates: $sg[0].candidates}' "$3" > "$3.sg" || ! mv -f -- "$3.sg" "$3"; then
    _lg_die "jq failed (suggestions payload)"
  fi
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

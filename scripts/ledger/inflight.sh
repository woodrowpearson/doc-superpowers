# shellcheck shell=bash
# scripts/ledger/inflight.sh — in-flight awareness (design §H.1, opt-in:
# config inflight.enabled): the branches in flight here, on the remote and
# on other machines; what each claims; `ledger inflight`; the overlay the
# read verbs apply to the index (query.sh, views.sh). Sourced by lib.sh;
# uses lib.sh's _lg_init / _lg_die / _lg_usage / _lg_emit / _lg_cfg /
# _lg_doc_index / _lg_out_file, adapters.sh's _lg_remote_cache, index.sh's
# _lg_index / _lg_ix_shallow / _lg_ix_trace / _lg_ix_pr_note, relations.sh's
# _lg_trailers / _lg_msg_claims / _LG_AWK_TRAILER, glob.sh's _LG_AWK_GLOB,
# parse.sh's _lg_scratch_name / _lg_awkv, query.sh's _lg_pr_data_into and
# doc-tools.sh's _hash_one.
#
# Range semantics (controller ruling R2 — the principle of spec-claims
# 3.2.0's `claims gate`: trunk merged into a branch is never the branch's
# work). A branch's work is the commits of merge-base(<base>, <tip>)..<tip>:
# every commit in that range, so a feature branch merged INTO the branch
# counts as its work, and the trunk merged into it does not (the merge base
# then is the trunk commit merged in). Its trailers and claims come from
# every message line of those commits (_LG_AWK_TRAILER: any line, bullets
# included); its files are the net diff `git diff --name-only <merge-base>
# <tip>`. <base> is config base; its own branch, a ref named HEAD and
# views.branch are never in flight.
#
# Sources (_lg_branches): local branches (refs/heads/), every worktree's
# HEAD (a detached one is "(detached:<first 8 hex of sha256(its path)>)" —
# never the path), keys.remote's branches (refs/remotes/<remote>/) and
# in-flight refs <ref_prefix>/<host>/<branch> — one `git for-each-ref
# --no-merged=<base>` call, so merged branches cost nothing, and a tip older
# than inflight.max_age_days (> 0; 0 or less: no cutoff) is skipped (the
# current branch never is). One line per (host, name): this host's local,
# worktree, remote and own in-flight copies of a branch are one (the newest
# commit wins: committer date, then local, worktree, remote, in-flight);
# other hosts' stay apart. Sorted by name, this host first, then host.
#
# Fetch: `git fetch --prune <keys.remote's url> +<ref_prefix>/*:<ref_prefix>/*`
# (+ +<inflight.pull_refs>:refs/doc-superpowers/pull/* when set — PR heads,
# a fork's too, which index.sh resolves as refs/doc-superpowers/pull/<n>)
# through the remote cache (_lg_remote_cache "inflight"): on --fetch, or
# when the last one is older than cache.remote_ttl_minutes. A failed fetch
# is one stderr note and the refs here serve (--fetch: exit 2);
# DOC_TOOLS_LEDGER_OFFLINE=1 never fetches (--fetch: exit 2, "offline").
# A remote with no URL configured is not fetched from.
#
# The host id (_lg_host_id): inflight.host_id, else git config
# doc-superpowers.ledger.host, else the first 8 hex of sha256(`hostname`,
# else `uname -n`) — the machine's name is never written anywhere.
#
# Caches (under $_LG_CACHE, never the index's own key — a tip that moves
# never rebuilds the item index, ruling R1):
#   branch/mb-<base>[.<shallow>].tsv   "<tip>\t<merge-base>" per tip seen
#       against this base ("M" merged, "U" no common history), and the
#       tip's committer date
#   branch/f-<tip>-<merge-base>-<sig>.tsv   the branch's facts, forever (a fact
#       about the two commits): its net diff, its trailer lines, the key-
#       shaped words of the plans it modifies; <sig> (and line 1) is the
#       signature of what they depend on (the trailer names, the plan
#       directories of the source's doc-index, the parser programs:
#       _lg_ifl_sig), so two plan-directory sets keep their own files
#   inflight/[rev/]overlay-<key>.json  the claims joined with one index
#       (rev/: an index built from a commit — publish — kept apart, so a
#       publish never evicts the working tree's):
#       keyed by the index file (its own key covers code, config, items and
#       PR data), the base, the host id and every scanned branch's host,
#       name, tip, sources and merge base. The read verbs apply it to the
#       index at query time (defs.jq lg_ifl_apply).
# A cold scan reads every new tip in one walk (`git log ^<base> <tips…>`):
# a tip whose own commits reach exactly one base commit has it as its merge
# base, and that walk is its range; a tip reaching several (the trunk merged
# in) asks `git merge-base` and walks its own range. One `git diff-tree
# --stdin` gives every net diff, one `git cat-file --batch` the plans.
#
# Claims (design §H.1), joined with the index: a trailers.claims value
# naming a key or alias (split on commas and blanks, any case); a
# trailers.claims_by_path value naming an item path ("./" dropped); an item
# file in the net diff; a key or alias named (as a word) in a plan the
# branch modifies — a .md file in the directory of a doc-index entry of a
# doc_columns.plan type, or matching doc_columns.plan.globs; a
# trailers.claims_by_ref keyword (#N) maps to an item only through the
# items adapter (not yet configured: counted in the run's one stderr note
# and dropped). Contract changes: a net-diff file a contract's defined_in
# matches ({id, line: null}), or "Contract-Change: <id> <text>" ({id,
# line: <text> without the leading separator}); acks: Ledger-Ack's first
# word. A branch's PR: an open PR (config adapters.pr) whose head is the
# branch's name (this host's branches; never a cross-repository one), else
# whose resolved head commit is the branch's tip; the highest number.

_LG_IFL_SCHEMA="ledger-inflight/1"
_LG_IFL_FACTS="ledger-branch/1"
_LG_IFL_LOADED=""
_LG_IFL_ON=0

# _lg_ifl_seg_ok <value>: a host id / ref segment: [A-Za-z0-9._-], 1–64
# characters, no ".." and not starting with "." or ending with ".lock".
_lg_ifl_seg_ok() {
  case "$1" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*|.*|*..*|*.lock) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# _lg_ifl_ref_ok <ref> [star]: a ref name under refs/ git accepts (no "..",
# "//", "@{", a component starting with "." or ending with ".lock", no
# trailing "/"); [star] 1: exactly one "*" is required.
_lg_ifl_ref_ok() {
  local r="$1" rest
  case "$r" in
    refs/?*) ;;
    *) return 1 ;;
  esac
  case "$r" in
    */|*//*|*..*|*/.*|*.lock/*|*.lock|*@\{*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/*-]*) return 1 ;;
  esac
  rest=${r#*\*}
  if [ "${2:-}" = 1 ]; then
    [ "$rest" != "$r" ] || return 1
    case "$rest" in *'*'*) return 1 ;; esac
  else
    [ "$rest" = "$r" ] || return 1
  fi
  return 0
}

# _lg_ifl_ref_overlap <a> <b>: a and b name the same ref, or one lies
# under the other (whole components: refs/heads overlaps refs/heads/x,
# never refs/headsx).
_lg_ifl_ref_overlap() {
  [ "$1" = "$2" ] && return 0
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

# The refs the in-flight fetch must never write or prune (it runs `git
# fetch --prune +<ref_prefix>/*:<ref_prefix>/*`): git's own namespaces, the
# pull refs' destination, and the ledger's counter ref and private refs
# (keys.sh). A ref_prefix that equals, holds or lies under one is refused —
# except strictly under refs/heads/ with a segment of its own (design §H.1:
# a server that rejects other refs; e.g. refs/heads/ledger-inflight). Then
# the branch scans skip that namespace and its remote-tracking mirror
# (_lg_ifl_scan): in-flight refs are never read as ordinary branches.
_LG_IFL_RESERVED="refs/heads refs/remotes refs/tags refs/notes refs/stash refs/bisect refs/replace refs/worktree refs/rewritten refs/prefetch refs/doc-superpowers/pull refs/doc-superpowers/ledger/counters-remote refs/doc-superpowers/ledger/base-remote"

# _lg_ifl_load: the in-flight settings of the run's config, once. Sets
# _LG_IFL_ON (1 when inflight.enabled is true) and, when on, _LG_IFL_PREFIX,
# _LG_IFL_AGE (days; 0: no cutoff), _LG_IFL_PULL, _LG_IFL_HOSTCFG,
# _LG_IFL_REMOTE, _LG_IFL_VIEWS, _LG_IFL_BASEREF, _LG_IFL_TTL (seconds).
# Disabled costs no process: the merged config is one compact line, and
# without '"enabled":true' in it no jq runs.
_lg_ifl_load() {
  local line="" s ctr="" r
  [ -z "$_LG_IFL_LOADED" ] || return 0
  _LG_IFL_LOADED=1
  _LG_IFL_ON=0
  IFS= read -r line < "$_LG_CFG" || true
  case "$line" in
    *'"enabled":true'*) ;;
    *) return 0 ;;
  esac
  _lg_scratch_name
  s=$_LG_SN
  # shellcheck disable=SC2016  # jq source
  _lg_cfg 'def l: if type == "string" and (test("[\\n\\r]") | not) then . elif . == null then "" else "\u0007" + tojson end;
    (.inflight.enabled == true),
    (.inflight.ref_prefix | l),
    (.inflight.max_age_days | if type == "number" and . > 0 then floor else 0 end),
    (.inflight.pull_refs | l),
    (.inflight.host_id | l),
    (.keys.remote | if type == "string" and . != "" then l else "origin" end),
    (.views.branch | l),
    (.base | l),
    ('"$_LG_RTTL_JQ"'),
    (.keys.counter_ref | if type == "string" and . != "" then l else "refs/doc-superpowers/ledger/counters" end)' > "$s.cfg"
  {
    IFS= read -r line
    IFS= read -r _LG_IFL_PREFIX
    IFS= read -r _LG_IFL_AGE
    IFS= read -r _LG_IFL_PULL
    IFS= read -r _LG_IFL_HOSTCFG
    IFS= read -r _LG_IFL_REMOTE
    IFS= read -r _LG_IFL_VIEWS
    IFS= read -r _LG_IFL_BASEREF
    IFS= read -r _LG_IFL_TTL
    IFS= read -r ctr
  } < "$s.cfg" || _lg_die "cannot read the in-flight config"
  [ "$line" = true ] || return 0
  _lg_ifl_ref_ok "$_LG_IFL_PREFIX" || _lg_die "config inflight.ref_prefix '$_LG_IFL_PREFIX' is not a ref prefix under refs/ (no trailing '/')"
  for r in $_LG_IFL_RESERVED "$ctr"; do
    if [ "$r" = refs/heads ]; then
      case "$_LG_IFL_PREFIX" in refs/heads/?*) continue ;; esac
    fi
    if _lg_ifl_ref_overlap "$_LG_IFL_PREFIX" "$r"; then
      _lg_die "config inflight.ref_prefix '$_LG_IFL_PREFIX' overlaps $r: the in-flight fetch (--prune) would rewrite or delete those refs — choose a prefix of its own (default refs/doc-superpowers/inflight; under refs/heads/, a segment of its own such as refs/heads/ledger-inflight)"
    fi
  done
  if [ -n "$_LG_IFL_PULL" ]; then
    _lg_ifl_ref_ok "$_LG_IFL_PULL" 1 || _lg_die "config inflight.pull_refs '$_LG_IFL_PULL' is not a ref pattern under refs/ with one '*' (e.g. refs/pull/*/head)"
  fi
  case "$_LG_IFL_REMOTE" in
    $'\a'*|-*) _lg_die "config keys.remote is not a remote name" ;;
  esac
  case "$_LG_IFL_TTL" in ''|*[!0123456789]*) _LG_IFL_TTL=600 ;; esac
  _LG_IFL_ON=1
}

# _lg_host_id [<inflight.host_id value>]: print this machine's in-flight
# host id (see the header). Dies (2) when the configured one is no ref
# segment.
_lg_host_id() {
  local v h
  if [ $# -gt 0 ]; then
    v=$1
  else
    v=$(_lg_cfg '.inflight.host_id | if type == "string" then . elif . == null then "" else "\u0007" + tojson end') || exit "$?"
  fi
  if [ -n "$v" ]; then
    _lg_ifl_seg_ok "$v" || _lg_die "config inflight.host_id '$v' is not a ref segment ([A-Za-z0-9._-], at most 64 characters)"
    printf '%s\n' "$v"
    return 0
  fi
  v=$(git config --get doc-superpowers.ledger.host 2>/dev/null) || v=""
  if [ -n "$v" ]; then
    _lg_ifl_seg_ok "$v" || _lg_die "git config doc-superpowers.ledger.host '$v' is not a ref segment ([A-Za-z0-9._-], at most 64 characters)"
    printf '%s\n' "$v"
    return 0
  fi
  # bash's $HOSTNAME (gethostname, no process), else hostname, else uname -n.
  h=${HOSTNAME:-}
  [ -n "$h" ] || h=$(hostname 2>/dev/null) || h=""
  [ -n "$h" ] || h=$(uname -n 2>/dev/null) || h=""
  if command -v sha256sum >/dev/null 2>&1; then
    v=$(printf '%s' "$h" | sha256sum) || _lg_die "sha256sum failed"
  else
    v=$(printf '%s' "$h" | shasum -a 256) || _lg_die "shasum failed"
  fi
  printf '%s\n' "${v:0:8}"
}

# --- Fetch --------------------------------------------------------------------------

# The remote cache's producer: fetch the in-flight (and pull) refs, print
# what is here afterwards (the cached "data": a record, never read back).
_lg_ifl_fetch_produce() {
  set -- "+$_LG_IFL_PREFIX/*:$_LG_IFL_PREFIX/*"
  if [ -n "$_LG_IFL_PULL" ]; then set -- "$@" "+$_LG_IFL_PULL:refs/doc-superpowers/pull/*"; fi
  LC_ALL=C git fetch --quiet --prune --no-tags --no-recurse-submodules "$_LG_IFL_URL" "$@" > /dev/null || return 1
  git for-each-ref --format='%(objectname) %(refname)' "$_LG_IFL_PREFIX/" refs/doc-superpowers/pull/
}

# _lg_ifl_fetch <force 0|1>: fetch through the remote cache (see the
# header). For `ledger inflight`, writes $_SCRATCH/lg-ifl-data.json
# {"state": fresh|stale|offline|none|unconfigured, "as_of", "error"}; a
# failure is a note (_LG_IFL_NOTES), or — forced — exit 2.
_lg_ifl_fetch() {
  local force="$1" rc=0 saved="${_LG_REMOTE_FORCE:-}" t state err
  # Its push URL when set, else its URL (keys.sh _lg_k_url's choice).
  _LG_IFL_URL=$(git remote get-url --push "$_LG_IFL_REMOTE" 2>/dev/null) || _LG_IFL_URL=""
  if [ -z "$_LG_IFL_URL" ]; then
    if [ "$force" = 1 ]; then _lg_die "in-flight refs: remote '$_LG_IFL_REMOTE' (keys.remote) has no URL"; fi
    if [ "$_LG_VERB" = inflight ]; then
      printf '{"state":"unconfigured","as_of":null,"error":null}\n' > "$_SCRATCH/lg-ifl-data.json" || _lg_die "cannot write the in-flight state"
    fi
    return 0
  fi
  _LG_REMOTE_FORCE=""
  if [ "$force" = 1 ]; then _LG_REMOTE_FORCE=1; fi
  _LG_RTTL=$_LG_IFL_TTL
  _lg_remote_cache inflight "$(printf 'inflight\n%s\n%s\n%s' "$_LG_IFL_URL" "$_LG_IFL_PREFIX" "$_LG_IFL_PULL")" _lg_ifl_fetch_produce || rc=$?
  _LG_RTTL=""
  _LG_REMOTE_FORCE=$saved
  state=$_LG_RSTATE
  err=$_LG_RERR
  if [ "$rc" != 0 ] && [ "$force" = 1 ]; then
    _lg_die "in-flight refs: ${err:-the fetch failed}"
  fi
  if [ "$rc" != 0 ] && [ "$state" != offline ]; then
    _lg_ifl_note "in-flight refs not fetched (${err:-the fetch failed}): the refs here serve"
  elif [ "$state" = stale ]; then
    t=$(jq -nr --argjson t "$_LG_RFETCHED" '$t | strftime("%Y-%m-%d %H:%M UTC")') || t="?"
    _lg_ifl_note "in-flight refs as of $t — the fetch failed: ${err:-?}"
  fi
  if [ "$state" = offline ]; then err=""; fi
  # Only `ledger inflight` reports it (inflight_data).
  [ "$_LG_VERB" = inflight ] || return 0
  jq -nc --arg st "$state" --arg t "${_LG_RFETCHED:-}" --arg e "$err" \
    '{state: $st, as_of: (if $t == "" then null else ($t | tonumber) end), error: (if $e == "" then null else $e end)}' \
    > "$_SCRATCH/lg-ifl-data.json" || _lg_die "cannot write the in-flight state"
}

# _lg_ifl_note <text>: add to the run's in-flight note — printed with the
# PR note as the run's one "ledger:" stderr line (index.sh _lg_ix_pr_note).
_LG_IFL_NOTES=""
_lg_ifl_note() {
  _LG_IFL_NOTES="${_LG_IFL_NOTES:+$_LG_IFL_NOTES; }$1"
  printf '%s\n' "$_LG_IFL_NOTES" > "$_SCRATCH/lg-ifl.note" || _lg_die "cannot write the in-flight note"
}

# --- The scan -----------------------------------------------------------------------

# The scan (awk): stdin `for-each-ref` lines "<oid>\t<date>\t<ref>"; -v me,
# rh (refs/remotes/<remote>/), ip (<ref_prefix>/), bb (the base's branch),
# views, cur (the current branch), cutoff, wt (the worktree list, one field
# per line, records split by empty lines), dd (a directory for detached
# worktrees' paths), det (their list). One line per (host, name):
# "<sort>\t<host>\t<name>\t<oid>\t<sources>\t<date>" — the newest commit
# (date, then local < worktree < remote < inflight) and every source, in
# that order; <sort> is name \001 (0 this host, 1 another) \001 host. A
# key whose copies point at different commits is listed in <conf>
# ("<sort>\t<oid>\t<date>\t<source rank>" per commit) for the descendant
# check (_lg_ifl_scan). A detached worktree goes to <det> as "<n>\t<oid>"
# (its path written to <dd>.<n>, \001 back to \n).
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_SCAN='
function wt_end(   p) {
  if (wh != "" && wb != "") { if (substr(wb, 1, 11) == "refs/heads/") W[substr(wb, 12)] = 1 }
  else if (wh != "" && wdet) {
    nd++; p = wp; gsub(/\001/, "\n", p); printf "%s", p > (dd "." nd); close(dd "." nd)
    print nd "\t" wh > det
  }
  wp = ""; wh = ""; wb = ""; wdet = 0
}
function add(host, name, oid, d, src,   k, j) {
  k = host SUBSEP name
  if (!(k in O)) { n++; K[n] = k; H[k] = host; N[k] = name }
  if (!(k in O) || d > D[k] || (d == D[k] && PR[src] < PR[P[k]])) { O[k] = oid; D[k] = d; P[k] = src }
  S[k, src] = 1
  # Every distinct tip of the key (the descendant check runs on these).
  if (!((k, oid) in TJ)) { NO[k]++; TJ[k, oid] = NO[k]; CO[k, NO[k]] = oid; CD[k, NO[k]] = d; CP[k, NO[k]] = PR[src] }
  else { j = TJ[k, oid]; if (PR[src] < CP[k, j]) CP[k, j] = PR[src] }
}
BEGIN {
  FS = "\t"; PR["local"] = 1; PR["worktree"] = 2; PR["remote"] = 3; PR["inflight"] = 4
  printf "" > det
  while ((getline l < wt) > 0) {
    if (l == "") { wt_end(); continue }
    if (substr(l, 1, 9) == "worktree ") wp = substr(l, 10)
    else if (substr(l, 1, 5) == "HEAD ") wh = substr(l, 6)
    else if (substr(l, 1, 7) == "branch ") wb = substr(l, 8)
    else if (l == "detached") wdet = 1
  }
  wt_end()
}
{
  oid = $1; d = $2 + 0; r = $3
  # The in-flight prefix first: under refs/heads/ it is no local branch.
  if (substr(r, 1, length(ip)) == ip) {
    rest = substr(r, length(ip) + 1); t = index(rest, "/")
    if (t < 2) next
    host = substr(rest, 1, t - 1); name = substr(rest, t + 1); src = "inflight"
  }
  else if (substr(r, 1, 11) == "refs/heads/") { host = me; name = substr(r, 12); src = "local" }
  else if (substr(r, 1, length(rh)) == rh) {
    # The remote-tracking mirror of an in-flight prefix under refs/heads/.
    if (rm != "" && substr(r, 1, length(rm)) == rm) next
    host = me; name = substr(r, length(rh) + 1); src = "remote"
  } else next
  if (name == "" || name == "HEAD" || name == bb || name == views) next
  if (cutoff > 0 && d < cutoff && !(host == me && name == cur)) next
  add(host, name, oid, d, src)
}
END {
  split("local worktree remote inflight", X, " ")
  for (i = 1; i <= n; i++) {
    k = K[i]
    if (H[k] == me && (N[k] in W) && ((k, "local") in S)) S[k, "worktree"] = 1
    s = ""
    for (j = 1; j <= 4; j++) if ((k, X[j]) in S) s = s (s == "" ? "" : ",") X[j]
    sk = N[k] "\001" (H[k] == me ? 0 : 1) "\001" H[k]
    print sk "\t" H[k] "\t" N[k] "\t" O[k] "\t" s "\t" D[k]
    if (NO[k] > 1) for (j = 1; j <= NO[k]; j++) print sk "\t" CO[k, j] "\t" CD[k, j] "\t" CP[k, j] > conf
  }
}'

# _lg_ifl_dedup <conf> <out>: per key of <conf> (consecutive lines
# "<sort>\t<oid>\t<date>\t<source rank>"), the winning "<sort>\t<oid>\t
# <date>": a descendant of every other tip wins; between unrelated tips,
# the newer date, then the better-ranked source.
_lg_ifl_dedup() {
  local k o d p pk="" bo="" bd="" bp=""
  : > "$2" || _lg_die "cannot write $2"
  while IFS="$(printf '\t')" read -r k o d p; do
    if [ "$k" != "$pk" ]; then
      if [ -n "$pk" ]; then printf '%s\t%s\t%s\n' "$pk" "$bo" "$bd" >> "$2"; fi
      pk=$k; bo=$o; bd=$d; bp=$p
      continue
    fi
    if git merge-base --is-ancestor "$bo" "$o" 2>/dev/null; then bo=$o; bd=$d; bp=$p
    elif git merge-base --is-ancestor "$o" "$bo" 2>/dev/null; then :
    elif [ "$d" -gt "$bd" ] || { [ "$d" = "$bd" ] && [ "$p" -lt "$bp" ]; }; then bo=$o; bd=$d; bp=$p
    fi
  done < "$1"
  if [ -n "$pk" ]; then printf '%s\t%s\t%s\n' "$pk" "$bo" "$bd" >> "$2"; fi
}

# _lg_ifl_scan <out>: the candidate branches (no merge base yet) as
# "<sort>\t<host>\t<name>\t<oid>\t<sources>\t<date>", sorted (name, this
# host first, host). Needs _lg_ifl_prepare's _LG_IFL_B, _LG_IFL_BB (the
# base's branch), _LG_IFL_CUR (the current branch), _LG_IFL_ME.
_lg_ifl_scan() {
  local out="$1" s cutoff=0 n i now rm=""
  case "$_LG_IFL_PREFIX" in
    refs/heads/?*) rm="refs/remotes/$_LG_IFL_REMOTE/${_LG_IFL_PREFIX#refs/heads/}/" ;;
  esac
  _lg_scratch_name
  s=$_LG_SN
  if [ "$_LG_IFL_AGE" -gt 0 ] 2>/dev/null; then
    now=${_LG_RNOW:-}
    [ -n "$now" ] || now=$(date +%s) || _lg_die "date failed"
    cutoff=$((now - _LG_IFL_AGE * 86400))
  fi
  git for-each-ref --no-merged="$_LG_IFL_B" --format='%(objectname)%09%(committerdate:unix)%09%(refname)' \
    refs/heads/ "refs/remotes/$_LG_IFL_REMOTE/" "$_LG_IFL_PREFIX/" > "$s.refs" 2> "$s.err" \
    || _lg_die "git for-each-ref failed: $(head -n 1 "$s.err")"
  if git worktree list --porcelain -z > "$s.wtz" 2> /dev/null; then
    tr '\n\000' '\001\n' < "$s.wtz" > "$s.wt" || _lg_die "cannot read the worktree list"
  else
    git worktree list --porcelain > "$s.wt" 2> "$s.err" || _lg_die "git worktree list failed: $(head -n 1 "$s.err")"
  fi
  LC_ALL=C awk -v me="$_LG_IFL_ME" -v rh="refs/remotes/$_LG_IFL_REMOTE/" -v ip="$_LG_IFL_PREFIX/" -v bb="$_LG_IFL_BB" \
    -v views="$_LG_IFL_VIEWS" -v cur="$_LG_IFL_CUR" -v cutoff="$cutoff" -v wt="$s.wt" -v dd="$s.dd" -v det="$s.det" \
    -v conf="$s.conf" -v rm="$rm" "$_LG_AWK_IFL_SCAN" "$s.refs" > "$s.cands" || _lg_die "cannot read the branches"
  # Copies of one branch at different commits (only then, a git call per
  # pair): a descendant wins; unrelated tips, the newer committer date,
  # then local < worktree < remote < inflight.
  if [ -s "$s.conf" ]; then
    _lg_ifl_dedup "$s.conf" "$s.win"
    LC_ALL=C awk -F '\t' -v win="$s.win" '
      BEGIN { while ((getline l < win) > 0) { split(l, a, "\t"); WO[a[1]] = a[2]; WD[a[1]] = a[3] } }
      ($1 in WO) { print $1 "\t" $2 "\t" $3 "\t" WO[$1] "\t" $5 "\t" WD[$1]; next } { print }' "$s.cands" > "$s.cands2" \
      || _lg_die "cannot pick the branches' tips"
    mv -f -- "$s.cands2" "$s.cands" || _lg_die "cannot pick the branches' tips"
  fi
  # Detached worktrees: the hash of each path (one sha256 call for all) and
  # the tip's date (one git log); merged ones are dropped by the merge-base
  # pass (_lg_ifl_resolve). Each name is its own: nothing to merge.
  if [ -s "$s.det" ]; then
    n=$(wc -l < "$s.det" | tr -d ' ')
    i=1
    while [ "$i" -le "$n" ]; do printf '%s\n' "${s##*/}.dd.$i"; i=$((i + 1)); done > "$s.dn"
    if command -v sha256sum >/dev/null 2>&1; then
      ( cd "$_SCRATCH" && xargs sha256sum < "$s.dn" ) > "$s.dh" 2> "$s.err" || _lg_die "sha256sum failed"
    else
      ( cd "$_SCRATCH" && xargs shasum -a 256 < "$s.dn" ) > "$s.dh" 2> "$s.err" || _lg_die "shasum failed"
    fi
    LC_ALL=C awk -F '\t' '{ print $2 }' "$s.det" | git log --no-walk=unsorted --stdin --format='%H %ct' > "$s.ddate" 2> "$s.err" \
      || _lg_die "git log failed (detached worktrees): $(head -n 1 "$s.err")"
    LC_ALL=C awk -v me="$_LG_IFL_ME" -v dh="$s.dh" -v dt="$s.ddate" -v cutoff="$cutoff" '
      BEGIN {
        while ((getline l < dh) > 0) { split(l, a, " "); fn = a[2]; sub(/.*\./, "", fn); H[fn] = substr(a[1], 1, 8) }
        while ((getline l < dt) > 0) { split(l, a, " "); T[a[1]] = a[2] }
      }
      { split($0, f, "\t"); if (!(f[2] in T) || (cutoff > 0 && T[f[2]] + 0 < cutoff)) next
        nm = "(detached:" H[f[1]] ")"
        print nm "\0010\001" me "\t" me "\t" nm "\t" f[2] "\tworktree\t" T[f[2]] }' "$s.det" >> "$s.cands" \
      || _lg_die "cannot read the detached worktrees"
  fi
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$s.cands" > "$out" || _lg_die "cannot sort the branches"
}

# --- Merge bases and facts ------------------------------------------------------------

# The cold walk (awk): stdin `git log --format='%x01%H %ct %P%n%B' ^<base>
# <tips…>`; -v tips (one per line), tr (the trailer names). Per tip:
#   "M\t<tip>"                 merged (not in the walk)
#   "B\t<tip>\t<mb>\t<date>"   its commits reach one base commit, <mb>
#   "U\t<tip>\t<date>"         none (no common history)
#   "X\t<tip>\t<date>"         several (its merge base is git's to say)
# and for B and X, the trailer lines of its commits in the walk,
# "T\t<tip>\t<kind>\t<value>" (each once). (For X they are its range's
# when git names one merge base m: every base commit the tip reaches is
# then an ancestor of m, so m..tip is exactly the walk's commits.)
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_WALK='
BEGIN { tr_load(tr) }
substr($0, 1, 1) == "\001" {
  l = substr($0, 2); n = split(l, a, " ")
  c = a[1]; DT[c] = a[2]; IN[c] = 1; p = ""
  for (i = 3; i <= n; i++) p = p (p == "" ? "" : " ") a[i]
  PAR[c] = p
  next
}
{ tr_match($0); for (i = 1; i <= TRM; i++) { NT[c]++; TK[c, NT[c]] = TRMK[i]; TV[c, NT[c]] = TRMV[i] } }
END {
  while ((getline o < tips) > 0) {
    if (!(o in IN)) { print "M\t" o; continue }
    delete SEEN; delete BD; delete OUT; nb = 0; sp = 0; ST[++sp] = o; nt = 0
    while (sp > 0) {
      c = ST[sp--]
      if (c in SEEN) continue
      SEEN[c] = 1
      for (i = 1; i <= NT[c]; i++) { k = TK[c, i] "\t" TV[c, i]; if (!(k in OUT)) { OUT[k] = 1; TL[++nt] = k } }
      m = split(PAR[c], A, " ")
      for (i = 1; i <= m; i++) {
        if (A[i] in IN) { if (!(A[i] in SEEN)) ST[++sp] = A[i] }
        else if (!(A[i] in BD)) { BD[A[i]] = 1; nb++; mb = A[i] }
      }
    }
    if (nb == 0) { print "U\t" o "\t" DT[o]; continue }
    if (nb > 1) print "X\t" o "\t" DT[o]
    else print "B\t" o "\t" mb "\t" DT[o]
    for (i = 1; i <= nt; i++) print "T\t" o "\t" TL[i]
  }
}'

# The plan words (awk): stdin `git cat-file --batch` (NUL → \001) for
# "<tip>:<path>" lines (-v req: the same lines, in order). Prints
# "K\t<tip>\t<word>" per distinct key-shaped word (lowercased) of each
# blob.
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_WORDS='
function words(s,   n, i, w, W, j) {
  s = tolower(s); gsub(/[^a-z0-9-]+/, " ", s)
  n = split(s, W, " ")
  for (i = 1; i <= n; i++) {
    w = W[i]
    if (w !~ /^[a-z0-9-]+-[1-9][0-9]*$/) continue
    j = match(w, /-[1-9][0-9]*$/)
    if (j < 2 || j > 17) continue
    if (!((tip, w) in SEENW)) { SEENW[tip, w] = 1; print "K\t" tip "\t" w }
  }
}
BEGIN { left = -1 }
{
  if (left < 0) {
    if ((getline r < req) <= 0) exit
    t = index(r, ":"); tip = substr(r, 1, t - 1)
    if ($0 ~ / missing$/ || $2 != "blob") { left = -1; next }
    left = $3 + 0
    if (left == 0) left = -2
    next
  }
  if (left == -2) { left = -1; next }
  words($0)
  # The blob ends with this line: exactly (its newline was part of the
  # blob; the separator line follows), or one byte short (the separator
  # ended it).
  left -= length($0) + 1
  if (left == 0) left = -2
  else if (left < 0) left = -1
}'

# _lg_ifl_sig: the facts signature into _LG_IFL_SIG (16 hex, part of every
# facts file's name) and the plan directories / globs into
# $_SCRATCH/lg-ifl-plans (lines "d\t<dir/>", "g\t<glob>"), and the trailer
# names into $_SCRATCH/lg-ifl-tr — once per source (_LG_IFL_SRC: the
# working tree, or the commit an index is built from — publish's base).
# The signature covers what facts depend on beyond the two commits: the
# trailer names, the plan directories (the source's doc-index), and the
# parser programs (_LG_AWK_TRAILER — the closing-keyword rule included —,
# the walk, the plan words).
_LG_IFL_SRC=worktree
_LG_IFL_SIGSRC=""
_lg_ifl_sig() {
  local di s
  [ -z "${_LG_IFL_SIG:-}" ] || [ "$_LG_IFL_SIGSRC" != "$_LG_IFL_SRC" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  _lg_trailers "$_SCRATCH/lg-ifl-tr"
  di=$(_lg_doc_index "$_LG_IFL_SRC") || exit "$?"
  # shellcheck disable=SC2016  # jq source
  jq -r --slurpfile c "$_LG_CFG" '
    ($c[0].doc_columns.plan // null) as $pc
    | ($pc | if type == "array" then . elif type == "object" then (.doc_types // []) else [] end | [.[] | strings]) as $types
    | ([.docs | to_entries[] | select((.value | type) == "object" and ((.value.doc_type // null) as $t | $types | index([$t])))
        | .key | select(test("[\\n\\t]") | not) | (split("/") | .[0:-1] | join("/")) | if . == "" then "" else . + "/" end]
       | unique[] | "d\t\(.)"),
      ($pc | if type == "object" then ((.globs // [])[] | strings | select(test("[\\n\\t]") | not) | "g\t\(.)") else empty end)' \
    "$di" > "$_SCRATCH/lg-ifl-plans" || _lg_die "jq failed (the plan directories)"
  { printf '%s\n' "$_LG_IFL_FACTS"; cat "$_SCRATCH/lg-ifl-tr"; printf 'plans\n'; cat "$_SCRATCH/lg-ifl-plans"
    printf 'parsers\n%s\n%s\n%s\n' "$_LG_AWK_TRAILER" "$_LG_AWK_IFL_WALK" "$_LG_AWK_IFL_WORDS"; } > "$s.sig" \
    || _lg_die "cannot write $s.sig"
  _hash_one "$s.sig"
  _LG_IFL_SIG=${_HASH#sha256:}
  _LG_IFL_SIG=${_LG_IFL_SIG:0:16}
  _LG_IFL_SIGSRC=$_LG_IFL_SRC
}

# _lg_ifl_cold <tips-file> <mbs-out>: compute the facts of the tips (one
# per line) — see the header — writing branch/f-<tip>-<mb>-<sig>.tsv for each
# that has a merge base; "<tip>\t<mb|M|U>\t<date>" per tip into <mbs-out>.
_lg_ifl_cold() {
  local tips="$1" mbs="$2" s dir o mb d n tmpd
  _lg_scratch_name
  s=$_LG_SN
  dir="$_LG_CACHE/branch"
  _lg_ifl_sig
  { printf '^%s\n' "$_LG_IFL_B"; cat "$tips"; } > "$s.revs" || _lg_die "cannot write $s.revs"
  git -c log.showSignature=false log --no-color --stdin --format='%x01%H %ct %P%n%B' < "$s.revs" > "$s.log" 2> "$s.err" \
    || _lg_die "git log failed (the in-flight branches): $(head -n 3 "$s.err")"
  LC_ALL=C awk -v tips="$tips" -v tr="$_SCRATCH/lg-ifl-tr" "$_LG_AWK_TRAILER$_LG_AWK_IFL_WALK" "$s.log" > "$s.walk" \
    || _lg_die "cannot read the in-flight branches' commits"
  # Several base commits reached (the trunk merged in): git's merge base.
  # One (the usual case): the walk's trailers are the range's. Several (a
  # criss-cross): the first, and the trailers of its own range ("R" marks
  # the tip, "Y" its trailer lines).
  LC_ALL=C awk -F '\t' '$1 == "X" { print $2 "\t" $3 }' "$s.walk" > "$s.x"
  : > "$s.xw"
  while IFS="$(printf '\t')" read -r o d; do
    git merge-base --all "$_LG_IFL_B" "$o" > "$s.mball" 2>/dev/null || : > "$s.mball"
    mb=""
    { IFS= read -r mb; } < "$s.mball" || true
    if [ -z "$mb" ]; then printf 'U\t%s\t%s\n' "$o" "$d" >> "$s.xw"; continue; fi
    printf 'B\t%s\t%s\t%s\n' "$o" "$mb" "$d" >> "$s.xw"
    [ "$(wc -l < "$s.mball" | tr -d ' ')" -gt 1 ] || continue
    printf 'R\t%s\n' "$o" >> "$s.xw"
    _lg_msg_claims "$mb..$o" | LC_ALL=C awk -F '\t' -v o="$o" '!((o, $2, $3) in S) { S[o, $2, $3] = 1; print "Y\t" o "\t" $2 "\t" substr($0, length($1) + length($2) + 3) }' \
      >> "$s.xw" || _lg_die "cannot read the trailers of $o"
  done < "$s.x"
  LC_ALL=C awk -F '\t' '$1 == "R" { R[$2] = 1; next } $1 == "Y" { print "T" substr($0, 2); next } $1 == "X" { next }
    $1 == "T" && ($2 in R) { next } { print }' "$s.xw" "$s.walk" > "$s.walk2" || _lg_die "cannot write $s.walk2"
  mv -f -- "$s.walk2" "$s.walk" || _lg_die "cannot write $s.walk"
  # "<tip>\t<mb|M|U>\t<date>\t<issue refs>" (the claims_by_ref values, for
  # the run's note without reading the facts again).
  LC_ALL=C awk -F '\t' '
    $1 == "T" && $3 == "claims_by_ref" { v = substr($0, length($1) + length($2) + length($3) + 4); if (!(($2, v) in S)) { S[$2, v] = 1; R[$2] = R[$2] (R[$2] == "" ? "" : " ") v } next }
    $1 == "M" { n++; O[n] = $2 "\tM\t" } $1 == "U" { n++; O[n] = $2 "\tU\t" $3 } $1 == "B" { n++; O[n] = $2 "\t" $3 "\t" $4; TIP[n] = $2 }
    END { for (i = 1; i <= n; i++) print O[i] "\t" (i in TIP ? R[TIP[i]] : "") }' \
    "$s.walk" > "$mbs" || _lg_die "cannot write $mbs"
  # The tips whose facts are not here yet (a base that moved finds most
  # of them: facts are about the tip and its merge base, not the base).
  LC_ALL=C awk -F '\t' -v dir="$dir" -v sig="# $_LG_IFL_FACTS $_LG_IFL_SIG" -v sx="$_LG_IFL_SIG" '
    $1 == "B" { f = dir "/f-" $2 "-" $3 "-" sx ".tsv"; h = ""; if ((getline h < f) <= 0) h = ""; close(f); if (h != sig) print $2 " " $3 }' \
    "$s.walk" > "$s.pairs" || _lg_die "cannot check the in-flight facts"
  # The net diffs, one diff-tree for every such tip: "<tip> <mb>" per line.
  : > "$s.diff"
  if [ -s "$s.pairs" ]; then
    git diff-tree --stdin -r --name-only -z --no-renames < "$s.pairs" > "$s.dz" 2> "$s.err" \
      || _lg_die "git diff-tree failed (the in-flight branches): $(head -n 3 "$s.err")"
    # One token per line (a newline in a name as \001); a line that is a
    # tip of the batch starts that tip's names.
    tr '\n\000' '\001\n' < "$s.dz" | LC_ALL=C awk -v pairs="$s.pairs" '
      BEGIN { while ((getline l < pairs) > 0) { split(l, a, " "); TIP[a[1]] = 1 } }
      ($0 in TIP) { t = $0; next }
      t != "" && $0 != "" { x = $0; gsub(/\t/, "\002", x); print "F\t" t "\t" x }' > "$s.diff" \
      || _lg_die "cannot read the in-flight diffs"
  fi
  # The plans each modifies (.md files in a plan directory, or matching a
  # plan glob), read in one cat-file batch.
  LC_ALL=C awk -v plans="$_SCRATCH/lg-ifl-plans" "$_LG_AWK_GLOB"'
    BEGIN {
      while ((getline l < plans) > 0) {
        t = index(l, "\t"); k = substr(l, 1, t - 1); v = substr(l, t + 1)
        if (k == "d") PD[v] = 1; else if (k == "g") { g++; gx_add(g, v) }
      }
    }
    {
      split($0, a, "\t"); p = a[3]
      if (p !~ /\.md$/ || index(p, "\001") || index(p, "\002")) next
      d = p; sub(/[^\/]*$/, "", d)
      ok = (d in PD)
      if (!ok && g > 0) { gx_match(p); ok = GX_MN > 0 }
      if (ok) print a[2] ":" p
    }' "$s.diff" > "$s.preq" || _lg_die "cannot list the in-flight plans"
  : > "$s.words"
  if [ -s "$s.preq" ]; then
    git cat-file --batch < "$s.preq" 2> "$s.err" | tr '\000' '\001' \
      | LC_ALL=C awk -v req="$s.preq" "$_LG_AWK_IFL_WORDS" > "$s.words" \
      || _lg_die "cannot read the in-flight plans: $(head -n 1 "$s.err")"
  fi
  # One facts file per tip with a merge base: written in a private
  # directory, then moved into place (each rename atomic).
  mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
  tmpd=$(mktemp -d "$dir/.new.XXXXXX") || _lg_die "cannot create a temp dir in $dir"
  if ! LC_ALL=C awk -F '\t' -v d="$tmpd" -v hdr="# $_LG_IFL_FACTS $_LG_IFL_SIG" -v sx="$_LG_IFL_SIG" -v diff="$s.diff" -v words="$s.words" -v pairs="$s.pairs" '
      BEGIN { while ((getline l < pairs) > 0) { split(l, a, " "); WANT[a[1]] = 1 } }
      $1 == "B" { if ($2 in WANT) { MB[$2] = $3; n++; ORD[n] = $2 } next }
      $1 == "T" { T[$2] = T[$2] "T\t" substr($0, length($1) + length($2) + 3) "\n"; next }
      END {
        while ((getline l < diff) > 0) { split(l, a, "\t"); F[a[2]] = F[a[2]] "F\t" substr(l, length(a[1]) + length(a[2]) + 3) "\n" }
        while ((getline l < words) > 0) { split(l, a, "\t"); K[a[2]] = K[a[2]] "K\t" a[3] "\n" }
        for (i = 1; i <= n; i++) {
          o = ORD[i]; f = d "/f-" o "-" MB[o] "-" sx ".tsv"
          printf "%s\nmb\t%s\n%s%s%s# end\n", hdr, MB[o], F[o], T[o], K[o] > f
          close(f)
        }
      }' "$s.walk"; then
    rm -rf -- "$tmpd"
    _lg_die "cannot write the in-flight facts"
  fi
  n=$(find "$tmpd" -type f -name 'f-*' | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ] && ! mv -f -- "$tmpd"/f-* "$dir"/; then
    rm -rf -- "$tmpd"
    _lg_die "cannot install the in-flight facts"
  fi
  rm -rf -- "$tmpd"
  _lg_ix_trace "inflight-facts $(wc -l < "$s.pairs" | tr -d ' ') cold"
}

# The resolve pass (awk): stdin the candidates ("<sort>\t<host>\t<name>\t
# <oid>\t<sources>\t<date>"); -v mbs (the merge-base cache), dir, sig,
# check, need, key, refs, hdr. Prints "<host>\t<name>\t<oid>\t<sources>\t
# <mb>\t<facts file>\t<issue refs>" per candidate with a merge base; the
# tips to walk (merge base unknown; with check 1, facts missing or of
# another signature) into <need>; the overlay key's material (<hdr>, then
# columns 1–5) into <key>; "<n>\t<the first three refs>" into <refs>.
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_RESOLVE='
BEGIN {
  FS = "\t"; printf "" > need; printf "%s\n", hdr > key
  while ((getline l < mbs) > 0) { split(l, a, "\t"); if (!(a[1] in MB)) { MB[a[1]] = a[2]; RF[a[1]] = a[4] } }
}
{
  o = $4
  if (!(o in MB)) { if (!(o in ASK)) { ASK[o] = 1; print o > need }; next }
  if (MB[o] == "M" || MB[o] == "U") next
  f = dir "/f-" o "-" MB[o] "-" sx ".tsv"
  if (check == 1) {
    h = ""
    if ((getline h < f) <= 0) h = ""
    close(f)
    if (h != sig) { if (!(o in ASK)) { ASK[o] = 1; print o > need }; next }
  }
  print $2 "\t" $3 "\t" o "\t" $5 "\t" MB[o] "\t" f "\t" RF[o]
  print $2 "\t" $3 "\t" o "\t" $5 "\t" MB[o] > key
  if (RF[o] != "") {
    k = split(RF[o], A, " ")
    for (j = 1; j <= k; j++) { nr++; if (!(A[j] in R)) { R[A[j]] = 1; m++; if (m <= 3) rs = rs (rs == "" ? "" : ", ") A[j] } }
  }
}
END { printf "%s\n", (nr ? nr "\t" rs (m > 3 ? ", …" : "") : "") > refs }'

# _lg_ifl_resolve <cands> <out> [check 0|1]: each candidate's merge base
# (the cache branch/mb-<base>.tsv, else the cold walk) and facts file;
# merged and unrelated tips (a detached worktree's, or no common history)
# dropped. <out>: "<host>\t<name>\t<oid>\t<sources>\t<mb>\t<facts file>\t
# <issue refs>"; <out>.key the overlay key's material, <out>.refs the
# issue refs (_LG_AWK_IFL_RESOLVE). A tip of unknown merge base is walked
# (its facts written with it); with <check> 1 (an overlay build, the one
# reader of facts) so is a tip whose facts file is missing or carries
# another signature. The cache is replaced whole (a temp file moved into
# place), so it is read in place.
_lg_ifl_resolve() {
  local cands="$1" out="$2" check="${3:-0}" s dir mbf tmp
  _lg_scratch_name
  s=$_LG_SN
  dir="$_LG_CACHE/branch"
  _lg_ix_shallow
  mbf="$dir/mb-$_LG_IFL_B${_LG_SHALLOW:+.$_LG_SHALLOW}.tsv"
  if [ "$check" = 1 ]; then _lg_ifl_sig; fi
  set -- -v dir="$dir" -v sig="# $_LG_IFL_FACTS ${_LG_IFL_SIG:-}" -v sx="${_LG_IFL_SIG:-}" -v check="$check" -v need="$s.need" \
    -v key="$out.key" -v refs="$out.refs" -v hdr="$_LG_IFL_SCHEMA $_LG_IFL_B $_LG_IFL_ME"
  LC_ALL=C awk -v mbs="$mbf" "$@" "$_LG_AWK_IFL_RESOLVE" "$cands" > "$out" || _lg_die "cannot resolve the merge bases"
  [ -s "$s.need" ] || return 0
  _lg_ifl_cold "$s.need" "$s.new"
  mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
  tmp=$(mktemp "$dir/.mb.XXXXXX") || _lg_die "cannot create a temp file in $dir"
  if [ -f "$mbf" ]; then cat -- "$s.new" "$mbf" > "$s.mb" 2>/dev/null || cp -- "$s.new" "$s.mb"; else cp -- "$s.new" "$s.mb"; fi \
    || _lg_die "cannot write $s.mb"
  if ! LC_ALL=C awk -F '\t' '!($1 in S) { S[$1] = 1; print }' "$s.mb" > "$tmp" || ! mv -f -- "$tmp" "$mbf"; then
    rm -f -- "$tmp"
    _lg_die "cannot write $mbf"
  fi
  # shellcheck disable=SC2012  # cache names are mb-<hex>.tsv
  ls -t "$dir"/mb-*.tsv 2>/dev/null | tail -n +4 | while IFS= read -r tmp; do rm -f "$tmp"; done
  LC_ALL=C awk -v mbs="$s.mb" "$@" "$_LG_AWK_IFL_RESOLVE" "$cands" > "$out" || _lg_die "cannot resolve the merge bases"
}

# _lg_ifl_prepare <fetch 0|1> [source]: the run's in-flight scan, before the index is
# built (its notes join the PR note): load the settings; nothing more when
# disabled. Fetch (forced with 1), resolve the host id and the base, scan,
# resolve the merge bases into $_LG_IFL_SCAN (the candidates in
# $_LG_IFL_CANDS; both "" when there is nothing to scan: disabled, or the
# base does not resolve) and the scan's key into _LG_IFL_SKEY, count the
# issue refs no adapter maps (one note).
_LG_IFL_SCAN=""
_LG_IFL_CANDS=""
_LG_IFL_ME=""
_lg_ifl_prepare() {
  local force="$1" s n refs="" full="" hfull=""
  _LG_IFL_SRC=${2:-worktree}
  _lg_ifl_load
  _LG_IFL_SCAN=""
  _LG_IFL_CANDS=""
  [ "$_LG_IFL_ON" = 1 ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  if [ -z "$_LG_IFL_ME" ]; then _LG_IFL_ME=$(_lg_host_id "$_LG_IFL_HOSTCFG") || exit "$?"; fi
  # The base's commit, the current branch and the base's full name: one
  # call (two when HEAD is unborn or the base does not resolve). The
  # base's name comes last: a base given as a commit id has none (git
  # prints nothing for it), and nothing after it can shift.
  _LG_IFL_B=""
  _LG_IFL_CUR=""
  case "$_LG_IFL_BASEREF" in
    -*|''|$'\a'*) ;;
    *)
      if git rev-parse "$_LG_IFL_BASEREF^{commit}" --symbolic-full-name HEAD "$_LG_IFL_BASEREF" > "$s.rp" 2>/dev/null; then
        { IFS= read -r _LG_IFL_B; IFS= read -r hfull; IFS= read -r full; } < "$s.rp" || true
        _LG_IFL_CUR=$hfull
      else
        _LG_IFL_B=$(git rev-parse -q --verify "$_LG_IFL_BASEREF^{commit}" 2>/dev/null) || _LG_IFL_B=""
        if [ -n "$_LG_IFL_B" ]; then full=$(git rev-parse --symbolic-full-name "$_LG_IFL_BASEREF" 2>/dev/null) || full=""; fi
      fi ;;
  esac
  case "$_LG_IFL_B" in
    *[!0123456789abcdef]*) _LG_IFL_B="" ;;
  esac
  _LG_IFL_BB=""
  case "$full" in
    refs/heads/?*) _LG_IFL_BB=${full#refs/heads/} ;;
    "refs/remotes/$_LG_IFL_REMOTE/"?*) _LG_IFL_BB=${full#refs/remotes/"$_LG_IFL_REMOTE"/} ;;
    refs/remotes/?*/?*) _LG_IFL_BB=${full#refs/remotes/*/} ;;
  esac
  case "$_LG_IFL_CUR" in
    refs/heads/?*) _LG_IFL_CUR=${_LG_IFL_CUR#refs/heads/} ;;
    *) _LG_IFL_CUR="" ;;
  esac
  _lg_ifl_fetch "$force"
  if [ -z "$_LG_IFL_B" ]; then
    _lg_ifl_note "in-flight branches not scanned: the base '$_LG_IFL_BASEREF' does not resolve"
    return 0
  fi
  _lg_ifl_scan "$s.cands"
  _lg_ifl_resolve "$s.cands" "$s.scan"
  _LG_IFL_CANDS="$s.cands"
  _LG_IFL_SCAN="$s.scan"
  _hash_one "$s.scan.key"
  _LG_IFL_SKEY=${_HASH#sha256:}
  # The issue refs (#N) no adapter maps, counted once per (branch, ref)
  # (the merge-base cache carries each tip's).
  { IFS= read -r refs < "$s.scan.refs"; } 2>/dev/null || refs=""
  if [ -n "$refs" ]; then
    n=${refs%%	*}
    if [ "$n" = 1 ]; then
      _lg_ifl_note "1 issue reference not resolved (${refs#*	}): no items adapter maps #N"
    else
      _lg_ifl_note "$n issue references not resolved (${refs#*	}): no items adapter maps #N"
    fi
  fi
}

# _lg_ifl_prepare_bg / _lg_ifl_prepare_wait: _lg_ifl_prepare 0 in the
# background, beside the index build (query.sh _lg_q_run: a warm read verb
# pays for the scan's git calls in parallel, not in sequence). The settings
# are read here first (their errors die in this shell), and the shallow tag
# (one git call either side would make). The child:
#   - prints no verdict: _LG_IFL_CHILD makes its _lg_fail (doc-tools.sh)
#     leave "<rc>\t<message>" in $_SCRATCH/lg-ifl.fail and exit; the wait
#     raises it here, the run's one verdict;
#   - holds none of this run's output: its stdout and fd 9 go to
#     /dev/null, its stderr (trace lines) to $_SCRATCH/lg-ifl.err, which the
#     wait copies to stderr — a `$(…)` reading this run returns when the
#     run ends;
#   - numbers its scratch names apart, resolves the host id (off this
#     shell's path) and leaves its results in $_SCRATCH/lg-ifl.state.
# _on_exit (doc-tools.sh) kills and waits for it when the run ends first.
# While it runs, the index's PR note is held (_LG_NOTE_DEFER: index.sh
# _lg_ix_pr_note), so the run's one note carries both; the wait prints it.
# DOC_TOOLS_LEDGER_SELFTEST=ifl-pidfile (scripts/test-ledger.sh only): the
# child's pid into $DOC_TOOLS_LEDGER_SELFTEST_PIDFILE.
_LG_IFL_PID=""
_LG_IFL_CHILD=""
_lg_ifl_prepare_bg() {
  _LG_IFL_PID=""
  _lg_ifl_load
  [ "$_LG_IFL_ON" = 1 ] || return 0
  _lg_ix_shallow
  rm -f -- "$_SCRATCH/lg-ifl.state" "$_SCRATCH/lg-ifl.fail" "$_SCRATCH/lg-ifl.err"
  (
    _LG_IFL_CHILD=1
    exec > /dev/null 9> /dev/null 2> "$_SCRATCH/lg-ifl.err"
    _LG_PARSE_N=$((_LG_PARSE_N + 100000))
    _lg_ifl_prepare 0
    printf '%s\n' "$_LG_IFL_SCAN" "$_LG_IFL_CANDS" "${_LG_IFL_SKEY:-}" "$_LG_IFL_B" "$_LG_IFL_ME" > "$_SCRATCH/lg-ifl.state.tmp" \
      && mv -f -- "$_SCRATCH/lg-ifl.state.tmp" "$_SCRATCH/lg-ifl.state"
  ) &
  _LG_IFL_PID=$!
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    ifl-pidfile) printf '%s\n' "$_LG_IFL_PID" > "$DOC_TOOLS_LEDGER_SELFTEST_PIDFILE" ;;
  esac
  _LG_NOTE_DEFER=1
}
_lg_ifl_prepare_wait() {
  local rc=0 n="" f=""
  [ -n "$_LG_IFL_PID" ] || return 0
  wait "$_LG_IFL_PID" || rc=$?
  _LG_IFL_PID=""
  _LG_NOTE_DEFER=""
  if [ -s "$_SCRATCH/lg-ifl.err" ]; then cat -- "$_SCRATCH/lg-ifl.err" >&2 || true; fi
  if [ -s "$_SCRATCH/lg-ifl.fail" ]; then
    { IFS= read -r f < "$_SCRATCH/lg-ifl.fail"; } 2>/dev/null || true
    case "${f%%	*}" in
      1|2|3) _lg_fail "${f%%	*}" "${f#*	}" ;;
    esac
    _lg_die "${f#*	}"
  fi
  [ "$rc" = 0 ] || _lg_die "internal: the in-flight scan exited $rc"
  { IFS= read -r _LG_IFL_SCAN; IFS= read -r _LG_IFL_CANDS; IFS= read -r _LG_IFL_SKEY; IFS= read -r _LG_IFL_B; IFS= read -r _LG_IFL_ME; } \
    < "$_SCRATCH/lg-ifl.state" || _lg_die "internal: the in-flight scan left no state"
  { IFS= read -r n < "$_SCRATCH/lg-pr.held"; } 2>/dev/null || n=""
  _lg_ix_pr_note "$n"
}

# --- The join -----------------------------------------------------------------------

# The join (awk): the index's lines (-v ixd: "I\t<path>\t<id>", "K\t<key or
# alias, lowercased>\t<path>", "C\t<contract>\t<glob>", "P\t<n>\t<head>\t
# <url>" per open non-cross PR, "Q\t<n>\t<url>" per open PR), the PR heads
# (-v heads: index.sh's "<n>\t<head>\t<oid>\t<o|m>"), -v me, files (1: list
# each branch's files); stdin the scan with an index "<i>\t<host>\t<name>\t
# <oid>\t<sources>\t<mb>\t<facts>". Prints per branch "B\t<i>\t<host>\t
# <name>\t<oid>\t<sources>\t<mb>\t<pr n>\t<pr url>\t<files n>", then
# "C\t<i>\t<path>\t<id>" (claims), "X\t<i>\t<contract>\t<line>",
# "A\t<i>\t<ack>", "R\t<i>\t<#N>", "F\t<i>\t<file>" (files=1). Names use
# \001 for a newline and \002 for a tab.
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_JOIN='
function claim(i, p) { if (!((i, p) in CL)) { CL[i, p] = 1; print "C\t" i "\t" p "\t" ID[p] } }
function cc(i, k, line) {
  if (!((i, k) in CC)) { CC[i, k] = line; NCC[i]++; CCK[i, NCC[i]] = k }
  else if (CC[i, k] == "" && line != "") CC[i, k] = line
}
BEGIN {
  FS = "\t"
  while ((getline l < ixd) > 0) {
    split(l, a, "\t")
    if (a[1] == "I") ID[a[2]] = a[3]
    else if (a[1] == "K") { if (!(a[2] in KM)) KM[a[2]] = a[3] }
    else if (a[1] == "C") { g++; if (gx_add(g, a[3])) CID[g] = a[2] }
    else if (a[1] == "P") { if (!(a[3] in PRH) || a[2] + 0 > PRH[a[3]] + 0) PRH[a[3]] = a[2]; URL[a[2]] = a[4] }
    else if (a[1] == "Q") URL[a[2]] = a[3]
  }
  while ((getline l < heads) > 0) {
    split(l, a, "\t")
    if (a[4] == "o" && (!(a[3] in PRO) || a[2] + 0 > PRO[a[3]] + 0)) PRO[a[3]] = a[1]
  }
}
{
  i = $1; host = $2; name = $3; oid = $4; f = $7; nf = 0
  while ((getline l < f) > 0) {
    k = substr(l, 1, 2)
    if (k == "F\t") {
      p = substr(l, 3); nf++
      if (files) print "F\t" i "\t" p
      if (p in ID) claim(i, p)
      q = p; gsub(/\001/, "\n", q); gsub(/\002/, "\t", q)
      gx_match(q)
      for (j = 1; j <= GX_MN; j++) cc(i, CID[GX_M[j]], "")
    } else if (k == "T\t") {
      l = substr(l, 3); t = index(l, "\t"); kind = substr(l, 1, t - 1); v = substr(l, t + 1)
      if (kind == "claims") {
        n = split(tolower(v), W, /[, \t]+/)
        for (j = 1; j <= n; j++) if (W[j] != "" && (W[j] in KM)) claim(i, KM[W[j]])
      } else if (kind == "claims_by_path") {
        sub(/^\.\//, "", v); gsub(/\t/, "\002", v)
        if (v in ID) claim(i, v)
      } else if (kind == "claims_by_ref") {
        if (!((i, v) in RF)) { RF[i, v] = 1; print "R\t" i "\t" v }
      } else if (kind == "contract_change") {
        w = v; sub(/[ \t].*/, "", w); line = substr(v, length(w) + 1)
        sub(/^[ \t:]*/, "", line); if (substr(line, 1, 3) == "\342\200\224" || substr(line, 1, 3) == "\342\200\223") line = substr(line, 4)
        sub(/^[ \t:-]*/, "", line)
        if (w != "") cc(i, w, line)
      } else if (kind == "ack") {
        w = v; sub(/[ \t].*/, "", w)
        if (w != "" && !((i, w) in AK)) { AK[i, w] = 1; print "A\t" i "\t" w }
      }
    } else if (k == "K\t") {
      w = substr(l, 3)
      if (w in KM) claim(i, KM[w])
    }
  }
  close(f)
  pr = ""
  if (host == me && (name in PRH)) pr = PRH[name]
  else if (oid in PRO) pr = PRO[oid]
  for (j = 1; j <= NCC[i]; j++) print "X\t" i "\t" CCK[i, j] "\t" CC[i, CCK[i, j]]
  print "B\t" i "\t" host "\t" name "\t" oid "\t" $5 "\t" $6 "\t" pr "\t" (pr == "" ? "" : URL[pr]) "\t" nf
}'

# The join's lines → the branches (jq, -R -n): [{host, own, name, branch,
# oid, sources, merge_base, pr, files_n, claims, claim_paths,
# contract_changes, acks, refs[, files]}] in scan order; $me the host id.
# shellcheck disable=SC2016  # jq source
_LG_JQ_IFL_BRANCHES='
def dec: if test("[\u0001\u0002]") then gsub("\u0001"; "\n") | gsub("\u0002"; "\t") else . end;
[inputs | split("\t")] as $L
| lg_lists($L[] | select(.[0] != "B") | {k: "\(.[0])\(.[1])", v: .[2:]}) as $G
| [ $L[] | select(.[0] == "B")
    | .[1] as $i
    | {host: .[2], own: (.[2] == $me), name: .[3],
       branch: (if .[2] == $me then .[3] else "\(.[3])@\(.[2])" end),
       oid: .[4], sources: (.[5] | split(",")), merge_base: .[6],
       pr: (if .[7] == "" then null else {number: (.[7] | tonumber), url: (if .[8] == "" then null else .[8] end), state: "open"} end),
       files_n: (.[9] | tonumber),
       claims: ([($G["C\($i)"] // [])[] | .[1] | dec] | unique),
       claim_paths: ([($G["C\($i)"] // [])[] | .[0] | dec] | unique),
       contract_changes: ([($G["X\($i)"] // [])[] | {id: .[0], line: (if (.[1] // "") == "" then null else .[1] end)}] | sort_by(.id)),
       acks: ([($G["A\($i)"] // [])[] | .[0]] | unique),
       refs: ([($G["R\($i)"] // [])[] | .[0]] | unique)}
    + (if $files then {files: [($G["F\($i)"] // [])[] | .[0] | dec]} else {} end) ]
'

# _lg_ifl_join <index> <scan> <files 0|1> <out>: the branches (see
# _LG_JQ_IFL_BRANCHES) as one JSON array in <out>.
_lg_ifl_join() {
  local ix="$1" scan="$2" files="$3" out="$4" s prl heads ixd dir k tmp
  _lg_scratch_name
  s=$_LG_SN
  prl="$_SCRATCH/lg-pr.prl"
  heads="$_SCRATCH/lg-pr.heads"
  [ -f "$prl" ] || prl=/dev/null
  [ -f "$heads" ] || heads=/dev/null
  # The index's lines depend on the index alone (its key covers the PR
  # data): kept beside the overlays as ixd-<index key>.tsv, so a moved tip
  # re-reads none of the 3,000 items.
  case "$ix" in
    */rev/index-*) dir="$_LG_CACHE/inflight/rev" ;;
    *) dir="$_LG_CACHE/inflight" ;;
  esac
  k=${ix##*/index-}
  ixd="$dir/ixd-${k%.json}.tsv"
  if [ -s "$ixd" ]; then
    _lg_ifl_join_lines "$ixd" "$scan" "$files" "$out" "$heads"
    return 0
  fi
  mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
  tmp=$(mktemp "$dir/.ixd.XXXXXX") || _lg_die "cannot create a temp file in $dir"
  # shellcheck disable=SC2016  # jq source
  jq -L "$_LG_LIB" -r --slurpfile prs "$prl" "$_LG_JQ_INCLUDE"'
    def e: if test("[\n\t]") then gsub("\n"; "\u0001") | gsub("\t"; "\u0002") else . end;
    (.items[] | (.path | e) as $p | "I\t\($p)\t\((.key // .path) | e)",
       (([.key] + (.aliases // []))[] | strings | select(test("[\\s]") | not) | "K\t\(lg_lower)\t\($p)")),
    (.contracts[]? | .id as $id | (.defined_in // [])[] | strings | select(test("[\n\t]") | not) | "C\t\($id)\t\(.)"),
    ($prs[] | select(.state == "open" and (.number | tostring | test("^[0-9]+$")))
     | "Q\t\(.number)\t\(.url // "" | tostring | e)",
       (select(.cross != true and (.head | type) == "string" and (.head | test("^[^\t\n\r]+$"))) | "P\t\(.number)\t\(.head)\t\(.url // "" | tostring | e)"))' \
    "$ix" > "$tmp" || { rm -f -- "$tmp"; _lg_die "jq failed (the in-flight join's index lines)"; }
  mv -f -- "$tmp" "$ixd" || { rm -f -- "$tmp"; _lg_die "cannot install $ixd"; }
  # shellcheck disable=SC2012  # cache names are ixd-<hex>.tsv
  ls -t "$dir"/ixd-*.tsv 2>/dev/null | tail -n +4 | while IFS= read -r tmp; do rm -f "$tmp"; done
  _lg_ifl_join_lines "$ixd" "$scan" "$files" "$out" "$heads"
}

# _lg_ifl_join_lines <ixd> <scan> <files 0|1> <out> <heads>: the join
# proper (_LG_AWK_IFL_JOIN, _LG_JQ_IFL_BRANCHES).
_lg_ifl_join_lines() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  LC_ALL=C awk -F '\t' '{ print (NR - 1) "\t" $0 }' "$2" \
    | LC_ALL=C awk -v ixd="$1" -v heads="$5" -v me="$_LG_IFL_ME" -v files="$3" "$_LG_AWK_GLOB$_LG_AWK_IFL_JOIN" > "$s.join" \
    || _lg_die "cannot join the in-flight branches with the index"
  jq -L "$_LG_LIB" -R -n -c --arg me "$_LG_IFL_ME" --argjson files "$( [ "$3" = 1 ] && echo true || echo false )" \
    "$_LG_JQ_INCLUDE$_LG_JQ_IFL_BRANCHES" "$s.join" > "$4" || _lg_die "jq failed (the in-flight branches)"
}

# _lg_ifl_overlay <index>: the overlay for <index> (see the header) into
# _LG_IFL_OV — its path, or "" when nothing is in flight here (disabled,
# no base). Needs _lg_ifl_prepare.
_LG_IFL_OV=""
_lg_ifl_overlay() {
  local ix="$1" s dir key f tmp
  _LG_IFL_OV=""
  [ -n "$_LG_IFL_SCAN" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  # An index built from a commit (publish) keeps its overlays apart.
  case "$ix" in
    */rev/index-*) dir="$_LG_CACHE/inflight/rev" ;;
    *) dir="$_LG_CACHE/inflight" ;;
  esac
  # The key: the index's own (its file name) and the scan's (prepare).
  key=${ix##*/index-}
  key="${key%.json}"
  key="${key:0:24}-${_LG_IFL_SKEY:0:24}"
  f="$dir/overlay-$key.json"
  # Written whole (a temp file moved into place): present is valid.
  if [ -s "$f" ]; then
    _lg_ix_trace "inflight-hit overlay-$key.json"
    _LG_IFL_OV=$f
    return 0
  fi
  _lg_ix_trace "inflight-build overlay-$key.json"
  # Facts of another signature (the trailer names or plan directories
  # changed: the index changed too, so this is a build) are computed again.
  _lg_ifl_resolve "$_LG_IFL_CANDS" "$s.scan" 1
  _lg_ifl_join "$ix" "$s.scan" 0 "$s.br"
  mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
  tmp=$(mktemp "$dir/.overlay.XXXXXX") || _lg_die "cannot create a temp file in $dir"
  # shellcheck disable=SC2016  # jq source
  if ! jq -c --arg schema "$_LG_IFL_SCHEMA" --arg base "$_LG_IFL_B" --arg me "$_LG_IFL_ME" '
      . as $B
      | {schema: $schema, base: $base, host: $me,
         claims: ([range(0; $B | length) as $i | $B[$i].claim_paths[] | {k: ., v: $i}]
                  | group_by(.k) | map({(.[0].k): map(.v)}) | add // {}),
         branches: [$B[] | del(.claim_paths)]}' "$s.br" > "$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    _lg_die "cannot write $f"
  fi
  # The newest 3 overlays of this directory kept (by when they were
  # built); facts files and temp dirs nobody used for 30 days removed.
  # shellcheck disable=SC2012  # cache names are overlay-<hex>.json
  ls -t "$dir"/overlay-*.json 2>/dev/null | tail -n +4 | while IFS= read -r tmp; do rm -f "$tmp"; done
  cut -f 6 "$s.scan" | tr '\n' '\000' | xargs -0 touch -c 2>/dev/null || true
  find "$_LG_CACHE/branch" -maxdepth 1 \( -name 'f-*.tsv' -mtime +30 -o -name '.new.*' -mmin +60 -o -name '.mb.*' -mmin +60 \) \
    -exec rm -rf {} + 2>/dev/null || true
  _LG_IFL_OV=$f
}

# _lg_ifl_index_note: print the in-flight note when the index build did
# not (index.sh prints it with the PR note when it builds or checks one).
_lg_ifl_index_note() {
  _lg_ix_pr_note ""
}

# --- _lg_branches, _lg_branch_facts ---------------------------------------------------

# _lg_branches <out>: the branches in flight as "<host>\t<name>\t<oid>\t
# <sources>" (see the header); empty when disabled. Fetches when the TTL
# has expired.
_lg_branches() {
  _lg_ifl_prepare 0
  if [ -n "$_LG_IFL_SCAN" ]; then
    cut -f 1-4 "$_LG_IFL_SCAN" > "$1" || _lg_die "cannot write $1"
  else
    : > "$1" || _lg_die "cannot write $1"
  fi
}

# _lg_branch_facts <oid>: print the facts of the commit as a branch tip,
# {"merge_base", "files", "claims" (keys; a path for an item without one),
# "contract_changes" [{id, line}], "acks", "refs" (issue refs no adapter
# maps)} — joined with the working tree's index. Dies (2) when in-flight
# awareness is off, the base does not resolve, or the commit is merged
# into it.
_lg_branch_facts() {
  local o="$1" s ix
  _lg_ifl_load
  [ "$_LG_IFL_ON" = 1 ] || _lg_die "in-flight awareness is off (config inflight.enabled)"
  _lg_scratch_name
  s=$_LG_SN
  _LG_IFL_ME=$(_lg_host_id "$_LG_IFL_HOSTCFG") || exit "$?"
  _LG_IFL_B=$(git rev-parse -q --verify "$_LG_IFL_BASEREF^{commit}" 2>/dev/null) || _lg_die "the base '$_LG_IFL_BASEREF' does not resolve"
  o=$(git rev-parse -q --verify "$o^{commit}" 2>/dev/null) || _lg_die "unknown commit: '$1'"
  printf -- '-\t%s\t-\t%s\t-\t0\n' "$_LG_IFL_ME" "$o" > "$s.cands"
  _lg_ifl_resolve "$s.cands" "$s.scan" 1
  [ -s "$s.scan" ] || _lg_die "$o is merged into the base, or shares no history with it"
  ix=$(_lg_index) || exit "$?"
  _lg_ifl_join "$ix" "$s.scan" 1 "$s.br"
  jq -c '.[0] | {merge_base, files, claims, contract_changes, acks, refs}' "$s.br" || _lg_die "jq failed (the branch facts)"
}

# --- ledger inflight ------------------------------------------------------------------

# Text: one line per branch, "<name> <sources>[@<host>] <PR #n|no PR>
# claims:<keys> contracts:<ids> files:<n>" ("—" for none).
# shellcheck disable=SC2016  # jq source
_LG_JQ_IFL_TEXT='
.[] | "\(.name | lg_q_one) \(.sources | join(","))\(if .own then "" else "@\(.host)" end) \(if .pr == null then "no PR" else "PR #\(.pr.number)" end) claims:\(if .claims == [] then "—" else (.claims | map(lg_q_one) | join(",")) end) contracts:\(if .contract_changes == [] then "—" else (.contract_changes | map(.id) | join(",")) end) files:\(.files_n)"
'

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_inflight() {
  local s ix rc=0 want
  _lg_init inflight
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  _lg_scratch_name
  s=$_LG_SN
  _lg_ifl_load
  if [ -n "$_OPT_push" ]; then
    if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
      echo "ledger inflight --push: offline (DOC_TOOLS_LEDGER_OFFLINE=1): nothing pushed" >&2
      _lg_emit inflight 0
    fi
    _lg_die "ledger inflight --push: not implemented yet"
  fi
  if [ "$_LG_IFL_ON" != 1 ]; then
    if [ "$_LG_FORMAT" = json ]; then
      printf '{"inflight_enabled":false,"branches":[]}\n' > "$s.json" || _lg_die "cannot write $s.json"
      _lg_emit inflight 0 "$s.json"
    fi
    printf 'in-flight awareness is off (config inflight.enabled)\n' > "$s.out" || _lg_die "cannot write $s.out"
    _lg_out_file "$s.out"
    _lg_emit inflight 0
  fi
  _lg_ifl_prepare "$( [ -n "$_OPT_fetch" ] && echo 1 || echo 0 )"
  ix=$(_lg_index) || exit "$?"
  _lg_ifl_index_note
  if [ -n "$_LG_IFL_SCAN" ]; then
    # The facts files (and their signature) are checked here, as for an
    # overlay build.
    _lg_ifl_resolve "$_LG_IFL_CANDS" "$s.scan" 1
    _lg_ifl_join "$ix" "$s.scan" 1 "$s.br"
  else
    printf '[]\n' > "$s.br" || _lg_die "cannot write $s.br"
  fi
  want=${_OPT_branch:-}
  if [ -n "$want" ]; then
    # shellcheck disable=SC2016  # jq source
    jq -c --arg b "$want" '[.[] | select(.branch == $b or (.own and .name == $b))]' "$s.br" > "$s.sel" \
      || _lg_die "jq failed (--branch)"
    mv -f "$s.sel" "$s.br" || _lg_die "cannot write $s.br"
    if [ "$(jq 'length' "$s.br")" = 0 ]; then rc=1; fi
  fi
  if [ "$_LG_FORMAT" = json ]; then
    # shellcheck disable=SC2016  # jq source
    jq -c --arg me "$_LG_IFL_ME" --slurpfile d "$_SCRATCH/lg-ifl-data.json" \
      '{inflight_enabled: true, host_id: $me, inflight_data: $d[0], branches: [.[] | del(.claim_paths)]}' "$s.br" > "$s.json" \
      || _lg_die "jq failed (the inflight payload)"
    _lg_pr_data_into "$s.json"
    _lg_emit inflight "$rc" "$s.json"
  fi
  if [ "$rc" = 1 ]; then
    printf "no in-flight branch '%s'\n" "$want" | tr -d '\000-\010\013-\037' | head -n 1 > "$s.out"
  else
    jq -L "$_LG_LIB" -r "$_LG_JQ_INCLUDE$_LG_JQ_IFL_TEXT" "$s.br" > "$s.out" || _lg_die "jq failed (the inflight lines)"
  fi
  _lg_out_file "$s.out"
  _lg_emit inflight "$rc"
}

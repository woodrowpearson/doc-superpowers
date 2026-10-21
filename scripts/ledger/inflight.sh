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
# Fetch: `git fetch --prune <keys.remote's url> +<ref_prefix>/*:refs/doc-
# superpowers/inflight-fetch/*` (a private namespace; <ref_prefix>/ is then
# synced from it, touching only its own mirrors: _lg_ifl_mirror_sync)
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
# trailers.claims_by_ref keyword (#N) — with config items.adapter, the one
# hosted item whose ref ends in "#N" (controller ruling R5: mapped at join
# time against the index, the "H" lines of the join; the branch facts keep
# the raw "#N"). A ref no hosted item ends in, or several do, or any ref
# without an items adapter, is counted (once per branch and ref) in the
# run's one stderr note and dropped (_lg_ifl_refs_note once the hosted
# items are known; "no items adapter maps #N" without one). Contract
# changes: a net-diff file a contract's defined_in
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

# The refs the in-flight fetch must never write or prune (it fetches
# `+<ref_prefix>/*` into $_LG_IFL_TMP/ with --prune, then syncs
# <ref_prefix>/ from it): git's own namespaces, the
# pull refs' destination, and the ledger's counter ref and private refs
# (keys.sh). A ref_prefix that equals, holds or lies under one is refused —
# except strictly under refs/heads/ with a segment of its own (design §H.1:
# a server that rejects other refs; e.g. refs/heads/ledger-inflight). Then
# the branch scans skip that namespace and its remote-tracking mirror
# (_lg_ifl_scan): in-flight refs are never read as ordinary branches.
_LG_IFL_TMP=refs/doc-superpowers/inflight-fetch
_LG_IFL_RESERVED="refs/heads refs/remotes refs/tags refs/notes refs/stash refs/bisect refs/replace refs/worktree refs/rewritten refs/prefetch refs/doc-superpowers/pull $_LG_IFL_TMP refs/doc-superpowers/ledger/counters-remote refs/doc-superpowers/ledger/base-remote"

# _lg_ifl_load: the in-flight settings of the run's config, once. Sets
# _LG_IFL_ON (1 when inflight.enabled is true) and, when on, _LG_IFL_PREFIX,
# _LG_IFL_AGE (days; 0: no cutoff), _LG_IFL_PULL, _LG_IFL_HOSTCFG,
# _LG_IFL_REMOTE, _LG_IFL_VIEWS, _LG_IFL_BASEREF, _LG_IFL_TTL (seconds),
# _LG_IFL_ITEMS (1: config items.adapter names an adapter).
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
    (.keys.counter_ref | if type == "string" and . != "" then l else "refs/doc-superpowers/ledger/counters" end),
    (.items | if type == "object" and .adapter != null and .adapter != "" then "1" else "" end)' > "$s.cfg"
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
    IFS= read -r _LG_IFL_ITEMS
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

# _lg_ifl_fetch_run <git fetch args…>: git fetch in the background and
# waited for, so a TERM or INT to this shell (the run's EXIT trap killing
# the scan, or Ctrl-C) takes the fetch with it — the fetch and every
# process under it (_lg_kill_tree: its transport, e.g. the shell an ssh
# command runs in, which a bare `kill <fetch>` would orphan); the run's own
# traps (doc-tools.sh _traps) are put back afterwards.
_lg_ifl_fetch_run() {
  local p rc=0
  LC_ALL=C git fetch --quiet --no-tags --no-recurse-submodules "$@" < /dev/null > /dev/null &
  p=$!
  # shellcheck disable=SC2064  # $p now, on purpose
  trap "_lg_kill_tree $p; exit 143" TERM
  # shellcheck disable=SC2064
  trap "_lg_kill_tree $p; exit 130" INT
  wait "$p" || rc=$?
  trap 'exit 143' TERM
  trap 'exit 130' INT
  return "$rc"
}

# The shape of an in-flight mirror (awk): shaped(<ref>, <prefix>/) is 1
# when <ref> is <prefix>/<host>/<name> with a host segment _lg_ifl_seg_ok
# accepts (and a non-empty name).
_LG_AWK_IFL_SHAPED='
function shaped(r, ip,    rest, t, h) {
  rest = substr(r, length(ip) + 1); t = index(rest, "/"); h = substr(rest, 1, t - 1)
  return !(t < 2 || t == length(rest) || h !~ /^[A-Za-z0-9_][A-Za-z0-9._-]*$/ || h ~ /\.\./ || length(h) > 64)
}'

# _lg_ifl_heads_check: with ref_prefix under refs/heads/, every ref there
# must be an in-flight mirror — <prefix>/<host>/<name> (a host segment
# _lg_ifl_seg_ok accepts), no upstream, not checked out in any worktree —
# before anything is fetched into that namespace. Dies (2) naming the
# first refs that are not.
_lg_ifl_heads_check() {
  local s bad
  case "$_LG_IFL_PREFIX" in refs/heads/?*) ;; *) return 0 ;; esac
  _lg_scratch_name
  s=$_LG_SN
  git for-each-ref --format='%(refname)%09%(upstream)%09%(worktreepath)' "$_LG_IFL_PREFIX/" > "$s.hc" 2> "$s.err" \
    || _lg_die "git for-each-ref failed (checking $_LG_IFL_PREFIX): $(head -n 1 "$s.err")"
  bad=$(LC_ALL=C awk -F '\t' -v ip="$_LG_IFL_PREFIX/" "$_LG_AWK_IFL_SHAPED"'
    {
      why = ""
      if (!shaped($1, ip)) why = "not <host>/<name>"
      else if ($2 != "") why = "tracks " $2
      else if ($3 != "") why = "checked out in a worktree"
      if (why != "") { n++; if (n <= 3) s = s (s == "" ? "" : "; ") substr($1, 12) " (" why ")" }
    }
    END { if (n > 3) s = s "; …"; print s }' "$s.hc") || _lg_die "cannot check $_LG_IFL_PREFIX"
  if [ -n "$bad" ]; then
    _lg_die "config inflight.ref_prefix '$_LG_IFL_PREFIX' holds branches that are not in-flight mirrors: $bad — give the in-flight refs a namespace of their own"
  fi
}

# _lg_ifl_mirror_sync <snapshot>: bring <ref_prefix>/ in line with what
# was just fetched into $_LG_IFL_TMP/ (a private namespace, pruned by the
# fetch). No --prune and no forced fetch reach <ref_prefix>/. A ref here is
# a mirror ("ours") when it holds
#   - the value this sync last recorded (remote/inflight-mirror.<prefix>.tsv,
#     "<ref>\t<oid>": the refs it wrote), or
#   - the value $_LG_IFL_TMP/ held for it before this fetch (<snapshot>,
#     the producer's one for-each-ref "<oid> <ref>" of that namespace) —
#     so a lost or lagging record (a wiped cache, a run killed between the
#     update and the record) neither freezes nor strands a mirror; or,
#   - with neither a record file nor a snapshot (a first fetch, or both
#     lost), when it is shaped <prefix>/<host>/<name> (_LG_AWK_IFL_SHAPED):
#     adopted, and the run's note says so once. Under refs/heads/ (where
#     _lg_ifl_heads_check already refused anything with an upstream or a
#     worktree) adoption is non-destructive: such a ref is updated only
#     when the fetched value fast-forwards it (`git merge-base
#     --is-ancestor`), and never deleted — an unpushed branch there is
#     not a mirror until proven so.
# A ref here is
#   created     when absent;
#   updated     when it is ours (or already holds the fetched value);
#   deleted     when the remote no longer has it and it is ours;
#   left alone  otherwise — a ref no fetch wrote, or one changed since:
#               never overwritten, never deleted; the run's note names it
#               — one the remote has, with its remedy (`git update-ref -d
#               <ref>`: the next fetch recreates it; under refs/heads/,
#               where it may be the user's branch, rename it out of the
#               prefix with `git branch -m`, else delete it); one the
#               remote lacks, so it is never listed silently.
# One `git update-ref --stdin` transaction, each change compare-and-swap.
# DOC_TOOLS_LEDGER_SELFTEST=ifl-kill-after-update-ref (scripts/test-ledger.sh
# only): SIGKILL to this shell right after the transaction, before the
# record is written.
_lg_ifl_mirror_sync() {
  local snap="$1" s rec recf tmp n list adopt=0 heads=0 r l o
  _lg_scratch_name
  s=$_LG_SN
  recf="$_LG_CACHE/remote/inflight-mirror.${_LG_IFL_PREFIX//\//%}.tsv"
  rec=$recf
  if [ ! -f "$rec" ]; then
    rec=/dev/null
    if [ ! -s "$snap" ]; then adopt=1; fi
  fi
  case "$_LG_IFL_PREFIX" in refs/heads/?*) heads=1 ;; esac
  git for-each-ref --format='%(objectname) %(refname)' "$_LG_IFL_TMP/" "$_LG_IFL_PREFIX/" > "$s.cur" 2> "$s.err" \
    || { head -n 1 "$s.err" >&2; return 1; }
  LC_ALL=C awk -v tmp="$_LG_IFL_TMP/" -v ip="$_LG_IFL_PREFIX/" -v rec="$rec" -v snap="$snap" -v adopt="$adopt" \
    -v heads="$heads" -v cmds="$s.cmds" -v newrec="$s.rec" -v skip="$s.skip" -v gone="$s.gone" -v ffq="$s.ff" \
    -v adopted="$s.adopted" "$_LG_AWK_IFL_SHAPED"'
    function owned(r) { return ((r in REC) && L[r] == REC[r]) || ((r in SNAP) && L[r] == SNAP[r]) }
    BEGIN {
      printf "" > cmds; printf "" > newrec; printf "" > skip; printf "" > gone; printf "" > ffq
      while ((getline l < rec) > 0) { t = index(l, "\t"); REC[substr(l, 1, t - 1)] = substr(l, t + 1) }
      while ((getline l < snap) > 0) {
        t = index(l, " "); r = substr(l, t + 1)
        if (substr(r, 1, length(tmp)) == tmp) SNAP[ip substr(r, length(tmp) + 1)] = substr(l, 1, t - 1)
      }
    }
    {
      o = $1; r = substr($0, length(o) + 2)
      if (substr(r, 1, length(tmp)) == tmp) R[ip substr(r, length(tmp) + 1)] = o
      else if (substr(r, 1, length(ip)) == ip) L[r] = o
    }
    END {
      na = 0
      for (r in R) {
        if (!(r in L)) { print "create " r " " R[r] > cmds; print r "\t" R[r] > newrec }
        else if (L[r] == R[r]) print r "\t" R[r] > newrec
        else if (owned(r) || (adopt && !heads && shaped(r, ip) && ++na)) {
          print "update " r " " R[r] " " L[r] > cmds; print r "\t" R[r] > newrec
        }
        else if (adopt && heads && shaped(r, ip)) print r " " L[r] " " R[r] > ffq
        else print r > skip
      }
      for (r in L) if (!(r in R)) {
        if (owned(r) || (adopt && !heads && shaped(r, ip) && ++na)) print "delete " r " " L[r] > cmds
        else print r > gone
      }
      print na > adopted
    }' "$s.cur" || return 1
  n=0
  { IFS= read -r n < "$s.adopted"; } 2>/dev/null || n=0
  case "$n" in ''|*[!0123456789]*) n=0 ;; esac
  # Cold start under refs/heads/: fast-forwards only (an error is "no").
  while read -r r l o; do
    if git merge-base --is-ancestor "$l" "$o" 2>/dev/null; then
      printf 'update %s %s %s\n' "$r" "$o" "$l" >> "$s.cmds"
      printf '%s\t%s\n' "$r" "$o" >> "$s.rec"
      n=$((n + 1))
    else
      printf '%s\n' "$r" >> "$s.skip"
    fi
  done < "$s.ff"
  if [ -s "$s.cmds" ]; then
    git update-ref --stdin < "$s.cmds" 2> "$s.err" || { head -n 1 "$s.err" >&2; return 1; }
    case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
      ifl-kill-after-update-ref) sh -c 'kill -KILL "$PPID"' ;;
    esac
  fi
  mkdir -p -- "$_LG_CACHE/remote" 2>/dev/null || return 1
  tmp="$_LG_CACHE/remote/.inflight-mirror.$$"
  if ! LC_ALL=C sort "$s.rec" > "$tmp" || ! mv -f -- "$tmp" "$recf"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ "$n" -gt 0 ]; then
    if [ "$heads" = 1 ]; then
      _lg_ifl_note "no record of an earlier in-flight fetch: $n branch(es) under $_LG_IFL_PREFIX/ fast-forwarded and adopted as in-flight mirrors"
    else
      _lg_ifl_note "no record of an earlier in-flight fetch: $n ref(s) under $_LG_IFL_PREFIX/ shaped <host>/<name> adopted as in-flight mirrors (updated or pruned)"
    fi
  fi
  if [ -s "$s.skip" ]; then
    n=$(wc -l < "$s.skip" | tr -d ' ')
    list=$(LC_ALL=C sort "$s.skip" | head -n 3 | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
    if [ "$n" -gt 3 ]; then list="$list, …"; fi
    # Under refs/heads/ such a ref may be the user's own branch: never tell
    # them to delete it outright.
    if [ "$heads" = 1 ]; then
      _lg_ifl_note "$n in-flight ref(s) here differ from the remote's and from the last fetch's — not updated: $list (if it is your branch, rename it out of $_LG_IFL_PREFIX/ (\`git branch -m\`); else delete it and the next fetch recreates the mirror)"
    else
      _lg_ifl_note "$n in-flight ref(s) here differ from the remote's and from the last fetch's — not updated: $list (\`git update-ref -d <ref>\` lets the next fetch recreate it)"
    fi
  fi
  if [ -s "$s.gone" ]; then
    n=$(wc -l < "$s.gone" | tr -d ' ')
    list=$(LC_ALL=C sort "$s.gone" | head -n 3 | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
    if [ "$n" -gt 3 ]; then list="$list, …"; fi
    _lg_ifl_note "$n ref(s) under $_LG_IFL_PREFIX/ are not on the remote and no in-flight fetch wrote them — left alone: $list"
  fi
}

# The remote cache's producer: snapshot $_LG_IFL_TMP/ (one for-each-ref:
# the values the last fetch left there, _lg_ifl_mirror_sync's second proof
# of ownership), fetch the in-flight refs into it (and the pull refs into
# refs/doc-superpowers/pull/; both private, so --prune is safe there),
# sync <ref_prefix>/, print what is here afterwards (the cached "data": a
# record, never read back).
_lg_ifl_fetch_produce() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  git for-each-ref --format='%(objectname) %(refname)' "$_LG_IFL_TMP/" > "$s.snap" 2> "$s.err" \
    || { head -n 1 "$s.err" >&2; return 1; }
  set -- "+$_LG_IFL_PREFIX/*:$_LG_IFL_TMP/*"
  if [ -n "$_LG_IFL_PULL" ]; then set -- "$@" "+$_LG_IFL_PULL:refs/doc-superpowers/pull/*"; fi
  _lg_ifl_fetch_run --prune "$_LG_IFL_URL" "$@" || return 1
  _lg_ifl_mirror_sync "$s.snap" || return 1
  git for-each-ref --format='%(objectname) %(refname)' "$_LG_IFL_PREFIX/" refs/doc-superpowers/pull/
}

# _lg_ifl_fetch <force 0|1>: fetch through the remote cache (see the
# header). For `ledger inflight`, writes $_SCRATCH/lg-ifl-data.json
# {"state": fresh|stale|offline|none|unconfigured, "as_of", "error"}; a
# failure is a note (_LG_IFL_NOTES), or — forced — exit 2. A failure that
# was not a deliberate DOC_TOOLS_LEDGER_OFFLINE=1 (the refs here, or a
# stale copy, serve) also sets _LG_IFL_UNVERIFIED to its reason, which
# `notices --gate` refuses to pass on (3.3.1, final review CORE-m1).
_LG_IFL_UNVERIFIED=""
_lg_ifl_fetch() {
  local force="$1" rc=0 saved="${_LG_REMOTE_FORCE:-}" t state err
  _LG_IFL_UNVERIFIED=""
  # Its push URL when set, else its URL (keys.sh _lg_k_url's choice).
  _LG_IFL_URL=$(git remote get-url --push "$_LG_IFL_REMOTE" 2>/dev/null) || _LG_IFL_URL=""
  if [ -z "$_LG_IFL_URL" ]; then
    if [ "$force" = 1 ]; then _lg_die "in-flight refs: remote '$_LG_IFL_REMOTE' (keys.remote) has no URL"; fi
    if [ "$_LG_VERB" = inflight ]; then
      printf '{"state":"unconfigured","as_of":null,"error":null}\n' > "$_SCRATCH/lg-ifl-data.json" || _lg_die "cannot write the in-flight state"
    fi
    return 0
  fi
  # A prefix under refs/heads/ is checked before any fetch can write there
  # (here, not in the producer: its stderr is the remote cache's).
  _lg_ifl_heads_check
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
    _LG_IFL_UNVERIFIED="in-flight refs not fetched (${err:-the fetch failed})"
  elif [ "$state" = stale ]; then
    t=$(jq -nr --argjson t "$_LG_RFETCHED" '$t | strftime("%Y-%m-%d %H:%M UTC")') || t="?"
    _lg_ifl_note "in-flight refs as of $t — the fetch failed: ${err:-?}"
    _LG_IFL_UNVERIFIED="in-flight refs as of $t — the fetch failed: ${err:-?}"
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
function add_tip(host, name, oid, d, src,   k, j) {
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
  add_tip(host, name, oid, d, src)
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

# _lg_ifl_anc <pairs> <out>: for each "<a> <b>" line of <pairs>, "<a> <b>
# 1|0" into <out> (1: a is an ancestor of b). The verdicts are facts about
# two commits: cached in branch/anc.tsv ("<a> <b> 1|0"), so only a pair
# never seen runs git. A pair asked both ways is one process (final review,
# Task 12 m): `git merge-base --all <a> <b>` lists <a> exactly when <a> is
# an ancestor of <b>, and <b> when the reverse; one asked one way is `git
# merge-base --is-ancestor`. Of two distinct commits at most one is an
# ancestor of the other: when the cache holds <b> <a> as 1, <a> <b> is 0
# without asking. Only the answers are cached; an error (128: a missing
# object, a broken repository) counts as "not an ancestor" for this run
# alone and is asked again next time.
_lg_ifl_anc() {
  local s af a b r v tmp mb nl=$'\n'
  _lg_scratch_name
  s=$_LG_SN
  af="$_LG_CACHE/branch/anc.tsv"
  [ -f "$af" ] || af=/dev/null
  : > "$s.new"
  : > "$s.unc"
  # The pairs the cache lacks, each once: "<a> <b> 2" when <b> <a> is asked
  # too (only the first of the two is listed), else "<a> <b> 1"; a pair
  # whose reverse the cache holds as 1 is 0 at once (into <new>).
  LC_ALL=C awk -v af="$af" -v new="$s.new" '
    BEGIN { while ((getline l < af) > 0) { split(l, x, " "); C[x[1] " " x[2]] = x[3] } }
    $0 != "" && !($0 in C) && !($0 in S) { S[$0] = 1; n++; K[n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        k = K[i]
        if (k in D) continue
        split(k, x, " "); r = x[2] " " x[1]
        if (x[1] != x[2] && C[r] == 1) { print k " 0" > new; continue }
        if (x[1] != x[2] && (r in S)) { D[r] = 1; print k " 2" } else print k " 1"
      }
    }' "$1" > "$s.ask" || _lg_die "cannot list the tips to compare"
  while read -r a b r; do
    v=0
    if [ "$r" = 2 ]; then
      mb=$(git merge-base --all "$a" "$b" 2>/dev/null) || v=$?
      case "$v" in
        0|1)
          case "$nl$mb$nl" in
            *"$nl$a$nl"*) printf '%s %s 1\n%s %s 0\n' "$a" "$b" "$b" "$a" >> "$s.new" ;;
            *"$nl$b$nl"*) printf '%s %s 0\n%s %s 1\n' "$a" "$b" "$b" "$a" >> "$s.new" ;;
            *) printf '%s %s 0\n%s %s 0\n' "$a" "$b" "$b" "$a" >> "$s.new" ;;
          esac ;;
        *) printf '%s %s 0\n%s %s 0\n' "$a" "$b" "$b" "$a" >> "$s.unc" ;;
      esac
      continue
    fi
    git merge-base --is-ancestor "$a" "$b" 2>/dev/null || v=$?
    case "$v" in
      0) printf '%s %s 1\n' "$a" "$b" >> "$s.new" ;;
      1) printf '%s %s 0\n' "$a" "$b" >> "$s.new" ;;
      *) printf '%s %s 0\n' "$a" "$b" >> "$s.unc" ;;
    esac
  done < "$s.ask"
  if [ -s "$s.new" ]; then
    mkdir -p -- "$_LG_CACHE/branch" 2>/dev/null || _lg_die "cannot create $_LG_CACHE/branch"
    tmp=$(mktemp "$_LG_CACHE/branch/.anc.XXXXXX") || _lg_die "cannot create a temp file in $_LG_CACHE/branch"
    if ! cat -- "$af" "$s.new" | tail -n 20000 > "$tmp" || ! mv -f -- "$tmp" "$_LG_CACHE/branch/anc.tsv"; then
      rm -f -- "$tmp"
      _lg_die "cannot write the ancestry cache"
    fi
    af="$_LG_CACHE/branch/anc.tsv"
  fi
  LC_ALL=C awk -v af="$af" -v unc="$s.unc" '
    BEGIN {
      while ((getline l < af) > 0) { split(l, x, " "); A[x[1] " " x[2]] = x[3] }
      while ((getline l < unc) > 0) { split(l, x, " "); A[x[1] " " x[2]] = x[3] }
    }
    $0 != "" { print $0 " " (A[$0] == 1 ? 1 : 0) }' "$1" > "$2" || _lg_die "cannot read the ancestry verdicts"
}

# _lg_ifl_dedup <conf> <out>: per key of <conf> (consecutive lines
# "<sort>\t<oid>\t<date>\t<source rank>"), the winning "<sort>\t<oid>\t
# <date>": a descendant of the running best wins; between unrelated tips,
# the newer date, then the better-ranked source. The ancestry verdicts come
# from _lg_ifl_anc (cached in branch/anc.tsv).
_lg_ifl_dedup() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  # Every ordered pair of a key's tips.
  LC_ALL=C awk -F '\t' '
    $1 != k { k = $1; n = 0 }
    { n++; O[n] = $2; for (i = 1; i < n; i++) { p = O[i] " " $2; q = $2 " " O[i]; if (!(p in C)) { C[p] = 1; print p } if (!(q in C)) { C[q] = 1; print q } } }' \
    "$1" > "$s.pairs" || _lg_die "cannot list the tips to compare"
  _lg_ifl_anc "$s.pairs" "$s.verd"
  LC_ALL=C awk -F '\t' -v vd="$s.verd" -v out="$2" '
    function flush() { if (k != "") print k "\t" bo "\t" bd > out }
    BEGIN {
      printf "" > out
      while ((getline l < vd) > 0) { split(l, x, " "); A[x[1] " " x[2]] = x[3] }
    }
    $1 != k { flush(); k = $1; bo = $2; bd = $3 + 0; bp = $4 + 0; next }
    {
      o = $2; d = $3 + 0; p = $4 + 0
      if (A[bo " " o] == 1) { bo = o; bd = d; bp = p }
      else if (A[o " " bo] == 1) { }
      else if (d > bd || (d == bd && p < bp)) { bo = o; bd = d; bp = p }
    }
    END { flush() }' "$1" || _lg_die "cannot pick the branches' tips"
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
BEGIN { tr_load(tr); tr_since(trx) }
substr($0, 1, 1) == "\001" {
  l = substr($0, 2); n = split(l, a, " ")
  c = a[1]; DT[c] = a[2]; IN[c] = 1; p = ""
  for (i = 3; i <= n; i++) p = p (p == "" ? "" : " ") a[i]
  PAR[c] = p
  next
}
{ tr_match($0); tr_cut(c); for (i = 1; i <= TRM; i++) { NT[c]++; TK[c, NT[c]] = TRMK[i]; TV[c, NT[c]] = TRMV[i] } }
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
# blob. Each header takes one request. As frontmatter.awk's batch mode, a
# stream out of step with its requests exits 3 (the caller dies): a header
# past the last request, a line where a header belongs that is none, a
# separator line that is not empty, an object whose lines overrun its
# size, a stream that ends inside an object or before every request has
# its object — never a short read that passes, or that only fails when
# git, past the pipe buffers, dies of SIGPIPE.
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_WORDS='
function desync() { DIE = 1; exit 3 }
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
  # -2: this line is the separator after an object that ended on a
  # newline (or was empty) — tested first, since -2 < 0 would read it as
  # a header and take the next request with it.
  if (left == -2) { if ($0 != "") desync(); left = -1; next }
  if (left < 0) {
    if ((getline r < req) <= 0) desync()
    if ($0 ~ / (missing|ambiguous)$/) next
    if ($0 !~ /^[0123456789abcdef]+ (blob|tree|commit|tag) [0123456789]+$/) desync()
    t = index(r, ":"); tip = substr(r, 1, t - 1)
    blob = ($2 == "blob")
    left = $3 + 0
    if (left == 0) left = -2
    next
  }
  # Another type (a gitlink whose commit is here): its content is skipped.
  if (blob) words($0)
  # The object ends with this line: exactly (its newline was part of the
  # object; the separator line follows), or one byte short (the separator
  # ended it).
  left -= length($0) + 1
  if (left == 0) left = -2
  else if (left < -1) desync()
}
# An `exit` in a rule still runs END: DIE says it was a desync already.
END {
  if (DIE) exit 3
  if (left != -1 || (getline r < req) > 0) exit 3
}'

# _lg_ifl_plans <src> <out>: which files are plans, as lines "d\t<dir/>"
# (the directory of each entry of the doc-index <src> holds — the working
# tree, or a commit — whose doc_type is a doc_columns.plan type) and
# "g\t<glob>" (each doc_columns.plan.globs entry), for _LG_AWK_IFL_PLAN.
# In-flight's plan claims and upkeep's plans (design 2026-10-18 §4 D9)
# find plans this way; each has its own link test.
_lg_ifl_plans() {
  local di
  di=$(_lg_doc_index "$1") || exit "$?"
  # shellcheck disable=SC2016  # jq source
  jq -r --slurpfile c "$_LG_CFG" '
    ($c[0].doc_columns.plan // null) as $pc
    | ($pc | if type == "array" then . elif type == "object" then (.doc_types // []) else [] end | [.[] | strings]) as $types
    | ([.docs | to_entries[] | select((.value | type) == "object" and ((.value.doc_type // null) as $t | $types | index([$t])))
        | .key | select(test("[\\n\\t]") | not) | (split("/") | .[0:-1] | join("/")) | if . == "" then "" else . + "/" end]
       | unique[] | "d\t\(.)"),
      ($pc | if type == "object" then ((.globs // [])[] | strings | select(test("[\\n\\t]") | not) | "g\t\(.)") else empty end)' \
    "$di" > "$2" || _lg_die "jq failed (the plan directories)"
}

# The plan test (awk, after _LG_AWK_GLOB): ifl_plans(file) reads
# _lg_ifl_plans' lines; ifl_plan(p) is 1 when path p (a newline in it as
# \001, a tab as \002: never a plan) is a .md file in one of those
# directories, or matches one of the globs; else 0.
# shellcheck disable=SC2016  # awk source
_LG_AWK_IFL_PLAN='
function ifl_plans(f,   l, t, k, v) {
  while ((getline l < f) > 0) {
    t = index(l, "\t"); k = substr(l, 1, t - 1); v = substr(l, t + 1)
    if (k == "d") IFL_PD[v] = 1; else if (k == "g") { IFL_NG++; gx_add(IFL_NG, v) }
  }
  close(f)
}
function ifl_plan(p,   d) {
  if (p !~ /\.md$/ || index(p, "\001") || index(p, "\002")) return 0
  d = p; sub(/[^\/]*$/, "", d)
  if (d in IFL_PD) return 1
  if (IFL_NG > 0) { gx_match(p); return GX_MN > 0 }
  return 0
}
'

# _lg_ifl_sig: the facts signature into _LG_IFL_SIG (16 hex, part of every
# facts file's name) and the plan directories / globs into
# $_SCRATCH/lg-ifl-plans (lines "d\t<dir/>", "g\t<glob>"), and the trailer
# names into $_SCRATCH/lg-ifl-tr — once per source (_LG_IFL_SRC: the
# working tree, or the commit an index is built from — publish's base).
# The signature covers what facts depend on beyond the two commits: the
# trailer names, the plan directories (the source's doc-index), and the
# parser programs (_LG_AWK_TRAILER — the closing-keyword rule included —,
# the walk, the plan words, the plan test _LG_AWK_IFL_PLAN and the glob
# grammar _LG_AWK_GLOB it matches plan globs with).
_LG_IFL_SRC=worktree
_LG_IFL_SIGSRC=""
_lg_ifl_sig() {
  local s
  [ -z "${_LG_IFL_SIG:-}" ] || [ "$_LG_IFL_SIGSRC" != "$_LG_IFL_SRC" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  _lg_trailers "$_SCRATCH/lg-ifl-tr"
  _lg_tr_since
  _lg_ifl_plans "$_LG_IFL_SRC" "$_SCRATCH/lg-ifl-plans"
  { printf '%s\n' "$_LG_IFL_FACTS"; cat "$_SCRATCH/lg-ifl-tr"; printf 'since %s\nplans\n' "$_LG_TR_SINCE"; cat "$_SCRATCH/lg-ifl-plans"
    printf 'parsers\n%s\n%s\n%s\n%s\n%s\n' "$_LG_AWK_TRAILER" "$_LG_AWK_IFL_WALK" "$_LG_AWK_IFL_WORDS" "$_LG_AWK_IFL_PLAN" "$_LG_AWK_GLOB"; } > "$s.sig" \
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
  _lg_tr_incl "$s.tri" "$s.revs"
  git -c log.showSignature=false log --no-color --stdin --format='%x01%H %ct %P%n%B' < "$s.revs" > "$s.log" 2> "$s.err" \
    || _lg_die "git log failed (the in-flight branches): $(head -n 3 "$s.err")"
  LC_ALL=C awk -v tips="$tips" -v tr="$_SCRATCH/lg-ifl-tr" -v trx="$s.tri" "$_LG_AWK_TRAILER$_LG_AWK_IFL_WALK" "$s.log" > "$s.walk" \
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
  LC_ALL=C awk -v plans="$_SCRATCH/lg-ifl-plans" "$_LG_AWK_GLOB$_LG_AWK_IFL_PLAN"'
    BEGIN { ifl_plans(plans) }
    { split($0, a, "\t"); if (ifl_plan(a[3])) print a[2] ":" a[3] }' "$s.diff" > "$s.preq" \
    || _lg_die "cannot list the in-flight plans"
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
  # (the merge-base cache carries each tip's). With an items adapter, the
  # refs each branch carries, for the note once the hosted items are known
  # (_lg_ifl_refs_note).
  { IFS= read -r refs < "$s.scan.refs"; } 2>/dev/null || refs=""
  rm -f -- "$_SCRATCH/lg-ifl.refs"
  if [ -n "$refs" ] && [ "${_LG_IFL_ITEMS:-}" = 1 ]; then
    cut -f 7 "$s.scan" | grep . > "$_SCRATCH/lg-ifl.refs" || _lg_die "cannot write the in-flight issue refs"
  elif [ -n "$refs" ]; then
    n=${refs%%	*}
    if [ "$n" = 1 ]; then
      _lg_ifl_note "1 issue reference not resolved (${refs#*	}): no items adapter maps #N"
    else
      _lg_ifl_note "$n issue references not resolved (${refs#*	}): no items adapter maps #N"
    fi
  fi
}

# _lg_ifl_refs_note: the note on the issue refs no hosted item maps
# ($_SCRATCH/lg-ifl.refs: one line per branch, its refs; $_SCRATCH/
# lg-items.refs: the "#<n>" exactly one hosted ref ends in — index.sh
# _lg_ix_items_prepare; none when the hosted items are unavailable),
# counted once per (branch, ref): "<n> issue reference(s) not resolved
# (<the first three>[, …]): no single hosted item (items adapter) is #N";
# nothing when every ref maps.
_lg_ifl_refs_note() {
  local map="$_SCRATCH/lg-items.refs"
  [ -f "$map" ] || map=/dev/null
  _lg_awkv "$map"
  LC_ALL=C awk -v map="$_LG_AV" '
    BEGIN { while ((getline l < map) > 0) M[l] = 1 }
    {
      n = split($0, A, " ")
      for (j = 1; j <= n; j++) {
        if (A[j] == "" || (A[j] in M)) continue
        c++
        if (!(A[j] in S)) { S[A[j]] = 1; m++; if (m <= 3) rs = rs (rs == "" ? "" : ", ") A[j] }
      }
    }
    END {
      if (c) printf "%d issue reference%s not resolved (%s%s): no single hosted item (items adapter) is #N", c, (c == 1 ? "" : "s"), rs, (m > 3 ? ", …" : "")
    }' "$_SCRATCH/lg-ifl.refs" || _lg_die "cannot count the in-flight issue refs"
}

# _lg_ifl_prepare_bg / _lg_ifl_prepare_wait: _lg_ifl_prepare 0 in the
# background, beside the index build (query.sh _lg_q_run: a warm read verb
# pays for the scan's git calls in parallel, not in sequence). The settings
# are read here first (their errors die in this shell), and the shallow tag
# (one git call either side would make). The child:
#   - prints no verdict: _LG_FAIL_REC makes its _lg_fail (doc-tools.sh)
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
_lg_ifl_prepare_bg() {
  _LG_IFL_PID=""
  _lg_ifl_load
  [ "$_LG_IFL_ON" = 1 ] || return 0
  _lg_ix_shallow
  rm -f -- "$_SCRATCH/lg-ifl.state" "$_SCRATCH/lg-ifl.fail" "$_SCRATCH/lg-ifl.err"
  (
    _LG_FAIL_REC="$_SCRATCH/lg-ifl.fail"
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
# <url>" per open non-cross PR, "Q\t<n>\t<url>" per open PR, "H\t#<n>\t
# <path>" per "#<n>" a hosted item's ref ends in — <path> empty when
# several do: unmapped, ruling R5), the PR heads
# (-v heads: index.sh's "<n>\t<head>\t<oid>\t<o|m>"), -v me, files (1: list
# each branch's files); stdin the scan with an index "<i>\t<host>\t<name>\t
# <oid>\t<sources>\t<mb>\t<facts>". Prints per branch "B\t<i>\t<host>\t
# <name>\t<oid>\t<sources>\t<mb>\t<pr n>\t<pr url>\t<files n>", then
# "C\t<i>\t<path>\t<id>" (claims), "X\t<i>\t<contract>\t<line>",
# "A\t<i>\t<ack>", "R\t<i>\t<#N>", "F\t<i>\t<file>" (files 1 or 2),
# "Y\t<i>\t<contract>\t<file>" (files 2: each net-diff file a contract's
# defined_in matches — the notices' diffstats). Names use \001 for a
# newline and \002 for a tab.
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
    else if (a[1] == "H") HM[a[2]] = a[3]
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
      for (j = 1; j <= GX_MN; j++) { cc(i, CID[GX_M[j]], ""); if (files == 2) print "Y\t" i "\t" CID[GX_M[j]] "\t" p }
    } else if (k == "T\t") {
      l = substr(l, 3); t = index(l, "\t"); kind = substr(l, 1, t - 1); v = substr(l, t + 1)
      if (kind == "claims") {
        n = split(tolower(v), W, /[, \t]+/)
        for (j = 1; j <= n; j++) if (W[j] != "" && (W[j] in KM)) claim(i, KM[W[j]])
      } else if (kind == "claims_by_path") {
        sub(/^\.\//, "", v); gsub(/\t/, "\002", v)
        if (v in ID) claim(i, v)
      } else if (kind == "claims_by_ref") {
        if ((v in HM) && HM[v] != "" && (HM[v] in ID)) claim(i, HM[v])
        else if (!((i, v) in RF)) { RF[i, v] = 1; print "R\t" i "\t" v }
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
# contract_changes, acks, refs[, files][, contract_files]}] in scan order;
# $me the host id; contract_files ($cf): {<contract>: [files]}.
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
    + (if $files then {files: [($G["F\($i)"] // [])[] | .[0] | dec]} else {} end)
    + (if $cf then {contract_files: (lg_lists(($G["Y\($i)"] // [])[] | {k: .[0], v: (.[1] | dec)}) | map_values(unique))} else {} end) ]
'

# _lg_ifl_join <index> <scan> <files 0|1|2> <out>: the branches (see
# _LG_JQ_IFL_BRANCHES) as one JSON array in <out>; files 1 lists each
# branch's files, 2 also its contract files.
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
    ([.items[] | select((.url | type) == "string") | .path | e | {p: ., n: (capture("(?<n>#[0-9]+)$").n // empty)}]
     | group_by(.n)[] | "H\t\(.[0].n)\t\(if length == 1 then .[0].p else "" end)"),
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

# _lg_ifl_join_lines <ixd> <scan> <files 0|1|2> <out> <heads>: the join
# proper (_LG_AWK_IFL_JOIN, _LG_JQ_IFL_BRANCHES).
_lg_ifl_join_lines() {
  local s
  _lg_scratch_name
  s=$_LG_SN
  LC_ALL=C awk -F '\t' '{ print (NR - 1) "\t" $0 }' "$2" \
    | LC_ALL=C awk -v ixd="$1" -v heads="$5" -v me="$_LG_IFL_ME" -v files="$3" "$_LG_AWK_GLOB$_LG_AWK_IFL_JOIN" > "$s.join" \
    || _lg_die "cannot join the in-flight branches with the index"
  jq -L "$_LG_LIB" -R -n -c --arg me "$_LG_IFL_ME" --argjson files "$( [ "$3" != 0 ] && echo true || echo false )" \
    --argjson cf "$( [ "$3" = 2 ] && echo true || echo false )" \
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
  find "$_LG_CACHE/branch" -maxdepth 1 \( -name 'f-*.tsv' -mtime +30 -o -name 'r-*.tsv' -mtime +30 -o -name '.new.*' -mmin +60 \
    -o -name '.mb.*' -mmin +60 -o -name '.rf.*' -mmin +60 \) \
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

# --- Notices (design §H.2) ------------------------------------------------------------
#
# ledger notices [--branch B] [--gate] [--fetch]: for branch B (default: the
# current branch; a detached worktree is its "(detached:…)" entry), against
# every other branch in flight and the base since B's merge base (ruling
# R1: B's work, and every other branch's, is merge-base(<base>, X)..X; the
# base's is merge-base(<base>, B)..<base> — its contract changes found as a
# branch's are: a defined_in path in its net diff, or a Contract-Change
# line):
#   stop      another branch, or the base, changes a contract B's claimed
#             items consume or B changes itself (overlap: contracts); or it
#             claims an item B claims (overlap: keys — B's own item file,
#             edited on both, is then no heads-up too)
#   heads-up  another branch changes files B changes (overlap: files)
#   info      another branch claims a sibling of an item B claims (defs.jq
#             lg_relations: a contract both change or both consume, or a
#             relates sibling) (overlap: keys)
# One notice per (other branch, urgency, overlap kind). A branch whose tip
# B's history holds (B has that work) raises none; B's own branch on
# another host, ahead of B (its tip descends from B's), raises one info —
# its first overlap, what_changed "<name>@<host> is ahead of this branch"
# — never a stop against itself (ruling I1; a copy that diverged is
# another branch). Notice = {id, urgency, other: {branch, host, pr},
# overlap: {contracts|keys|files: […]}, what_changed, action}; other.branch
# is the branch's name (the base's ref name, host and pr null, for the
# base); id = the first 12 hex of sha256(<other> NUL <kind>:<values joined
# by ","> NUL <head>) — <other> canonical, so every host computes one id
# (ruling m3): "<name>" when any scanned copy of the branch is on
# keys.remote, else "<name>@<host>" (this host's too), or the base's ref
# name; and copies of one branch (one name: the remote's, another host's
# in-flight ref) collapse — a copy whose tip equals an earlier copy's or is
# behind another copy's raises nothing, so the branch is one notice keyed to
# its newer tip on every host (_lg_ifl_rel); <head> the other's tip, or for
# the base the sha256 (64 hex) of its overlap's state, the sorted unique
# lines "F\t<path>\t<post-image blob>" (each overlap contract file; \n and
# \t in a path as \001 and \002) and "C\t<commit>" (each base commit whose
# Contract-Change names an overlap contract), each newline-ended (ruling
# C1) — so a notice fires again only when the other side moves, and the
# base's only when its overlap does. The text and JSON keep the display
# name ("<name>" this host's, "<name>@<host>" another's). B's claimed
# items (their consumes, their siblings) are this working tree's: with
# --branch naming another branch the run's note says they are not read
# from its tip (ruling m4). what_changed: per contract "<id>:
# <Contract-Change line>", else "<id>: <diffstat of its defined_in
# files>"; files: the diffstat of the shared files; keys: the other
# branch's whole diffstat ("<n> file(s), +<added> -<deleted>", "0
# files"). action: stop reconcile-before-next-chunk,
# heads-up rebase-after-merge, info heads-up. A `Ledger-Ack: <id>` trailer
# line (the configured trailers.ack name, case-sensitive; " — <clause>"
# may follow) anywhere in B's range hides that notice; an ack of an id that
# does not fire is silent. Sorted by urgency (stop, heads-up, info), then
# <other>, then id. Text: "<urgency> <id> <other> <PR #n|no PR>
# <kind>:<values> — <what_changed> → <action>" (the first three values,
# then " (+n)"). JSON: {"notices": […], "pr_data"}. Exit 0; with --gate, 1
# when a stop notice is not acked; 2 when it cannot run (a base that does
# not resolve, a --branch naming no branch) or — no stop found — when the
# in-flight fetch failed (_LG_IFL_UNVERIFIED: "could not verify"). DOC_TOOLS_LEDGER_OFFLINE=1:
# the refs and branch facts here, the note says so, nothing fetched
# (--fetch: exit 2). Computed from the cached branch facts (_lg_ifl_resolve
# with check 1, _lg_ifl_join) — never an index rebuild; the base's range
# has its own facts file (_lg_ifl_range_facts).

# _lg_ifl_range_facts <mb> <tip>: the facts of the range <mb>..<tip> — the
# base since a branch's merge base — into $_LG_IFL_RF, a facts file
# (branch/r-<mb>-<tip>-<sig>.tsv, headed "# ledger-range/2 <sig>": its net
# diff's "F\t<path>" lines and its Contract-Change "T" lines, as a branch's
# facts, which the join reads; and, for a base notice's id (the overlap's
# state, _lg_ifl_notices), "b\t<post-image blob>\t<path>" per net-diff file
# and "c\t<commit>\t<contract id>" per Contract-Change line; facts about
# two commits, kept like a branch's).
_LG_IFL_RFACTS="ledger-range/2"
_LG_IFL_RF=""
_lg_ifl_range_facts() {
  local mb="$1" t="$2" s dir f h="" tmp
  _lg_ifl_sig
  dir="$_LG_CACHE/branch"
  f="$dir/r-$mb-$t-$_LG_IFL_SIG.tsv"
  _LG_IFL_RF=$f
  if [ -s "$f" ]; then
    { IFS= read -r h < "$f"; } 2>/dev/null || h=""
    if [ "$h" = "# $_LG_IFL_RFACTS $_LG_IFL_SIG" ]; then
      touch -c "$f" 2>/dev/null || true
      return 0
    fi
  fi
  _lg_scratch_name
  s=$_LG_SN
  # --raw -z: ":<mode> <mode> <blob> <blob> <status>" NUL <path> NUL per
  # file (--no-renames: always one path), the post-image blob in full.
  git diff --raw --no-abbrev -z --no-renames "$mb" "$t" -- > "$s.dz" 2> "$s.err" \
    || _lg_die "git diff failed (the base since $mb): $(head -n 1 "$s.err")"
  _lg_msg_claims "$mb..$t" > "$s.tr"
  mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
  tmp=$(mktemp "$dir/.rf.XXXXXX") || _lg_die "cannot create a temp file in $dir"
  if ! {
      printf '# %s %s\nmb\t%s\n' "$_LG_IFL_RFACTS" "$_LG_IFL_SIG" "$mb"
      # Tokens alternate, a record then its path (a path may start with
      # ":"): the record's fourth field is the post-image blob.
      tr '\n\000' '\001\n' < "$s.dz" | LC_ALL=C awk '
        NR % 2 == 1 { split($0, r, " "); o = r[4]; next }
        $0 != "" { x = $0; gsub(/\t/, "\002", x); print "F\t" x; B[++n] = "b\t" o "\t" x }
        END { for (i = 1; i <= n; i++) print B[i] }'
      LC_ALL=C awk -F '\t' '$2 == "contract_change" {
        v = substr($0, length($1) + length($2) + 3); print "T\tcontract_change\t" v
        w = v; sub(/[ \t].*/, "", w); if (w != "") C[++n] = "c\t" $1 "\t" w }
        END { for (i = 1; i <= n; i++) print C[i] }' "$s.tr"
      printf '# end\n'
    } > "$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    _lg_die "cannot write $f"
  fi
}

# _lg_ifl_rel <scan> <B host> <B name> <B tip> <out>: B's relatives among
# the scanned branches, and copies of one branch, as lines into <out>:
#   "b\t<tip>"           behind B: a tip B's history holds — B already has
#                        that work, so it raises nothing (ruling I1; one
#                        `git rev-list <B> ^<base>`: no tip in flight is on
#                        the base)
#   "a\t<tip>"           ahead of B: a tip of B's own branch on another host
#                        that descends from B's — one info (I1)
#   "d\t<host>\t<name>"  a copy of a branch (one name, another entry) whose
#                        tip equals an earlier copy's (scan order: this
#                        host's first) or is behind another copy's — dropped,
#                        so the branch on keys.remote and in flight from its
#                        host is one notice, keyed to its newer tip (m3)
# The ancestry verdicts come from _lg_ifl_anc (branch/anc.tsv), asked only
# for copies whose tips differ — usually none, and then no second pass.
_lg_ifl_rel() {
  local scan="$1" bh="$2" bn="$3" bo="$4" out="$5" s
  _lg_scratch_name
  s=$_LG_SN
  git rev-list "$bo" "^$_LG_IFL_B" -- > "$s.rl" 2> "$s.err" \
    || _lg_die "git rev-list failed (the branches behind '$bn'): $(head -n 1 "$s.err")"
  # Pass 1 lists the pairs to ask ("<a> <b>": is a an ancestor of b?) into
  # <ask>; pass 2 (only when there are some) reads their verdicts (<vd>).
  # shellcheck disable=SC2016  # awk source
  set -- -v rl="$s.rl" -v bh="$bh" -v bn="$bn" -v bo="$bo" -v ask="$s.ask" '
    function anc(x, y,   k) {
      k = x " " y
      if (k in V) return V[k] == 1
      if (!(k in Q)) { Q[k] = 1; print k > ask }
      return 0
    }
    BEGIN {
      printf "" > ask
      while ((getline l < rl) > 0) R[l] = 1
      while ((getline l < vd) > 0) { split(l, w, " "); V[w[1] " " w[2]] = w[3] }
    }
    $3 == bo { next }
    ($3 in R) { if (!($3 in BS)) { BS[$3] = 1; print "b\t" $3 } next }
    $2 == bn && $1 != bh && anc(bo, $3) && !($3 in AS) { AS[$3] = 1; print "a\t" $3 }
    { n++; H[n] = $1; N[n] = $2; O[n] = $3; G[$2] = G[$2] " " n; GC[$2]++ }
    END {
      for (nm in GC) {
        if (GC[nm] < 2) continue
        m = split(G[nm], I, " ")
        for (i = 1; i <= m; i++) {
          ia = I[i] + 0; drop = 0
          for (j = 1; j <= m; j++) {
            ib = I[j] + 0
            if (ib == ia) continue
            if (O[ib] == O[ia]) { if (ib < ia) drop = 1 }
            else if (anc(O[ia], O[ib])) drop = 1
          }
          if (drop) print "d\t" H[ia] "\t" N[ia]
        }
      }
    }'
  LC_ALL=C awk -F '\t' -v vd=/dev/null "$@" "$scan" > "$out" || _lg_die "cannot write $out"
  [ -s "$s.ask" ] || return 0
  _lg_ifl_anc "$s.ask" "$s.verd"
  LC_ALL=C awk -F '\t' -v vd="$s.verd" "$@" "$scan" > "$out" || _lg_die "cannot write $out"
}

# The notices (jq, the index as input; --slurpfile br: the branches of
# _lg_ifl_join with files 2; --rawfile rel: B's relatives and the dropped
# copies (_lg_ifl_rel); $bh/$bn: B;
# $base: the base's name; $me): raw lines "A\t<ack>" (B's acks), and per
# notice "J\t<json>" ({n, urgency, other, disp, cn, oid, mb, kind, vals,
# stat ("all" | [files] | null), parts (contracts: [{id, line, files}]),
# what (a fixed what_changed), base}), "H\t<n>\t<cn>\t<kind>:<vals>\t<oid
# | ^state>" (the id's input; \n and \t as \001 and \002; ^state: the
# base's overlap state stands in for its tip), "P\t<oid> <mb>" (a diffstat
# to compute), "G\t<n>\t<F|C>\t<path | contract>" (a base notice's overlap:
# its contract files and contracts).
# shellcheck disable=SC2016  # jq source
_LG_JQ_NTC_FIND='
def enc: if test("[\n\t]") then gsub("\n"; "\u0001") | gsub("\t"; "\u0002") else . end;
$br[0] as $BR
| [$rel | split("\n")[] | select(. != "") | split("\t")] as $RL
| lg_obj($RL[] | select(.[0] == "b") | {(.[1]): true}) as $BEHIND
| lg_obj($RL[] | select(.[0] == "a") | {(.[1]): true}) as $AHEAD
| lg_obj($RL[] | select(.[0] == "d") | {("\(.[1])\t\(.[2])"): true}) as $DROP
# The canonical name: <name> when any copy of the branch is on keys.remote.
| lg_obj($BR[] | select(any(.sources[]; . == "remote")) | {(.name): true}) as $RN
| (first($BR[] | select(.host == $bh and .name == $bn)) // null) as $B
| if $B == null then empty else
  lg_obj($B.claim_paths[] | {(.): true}) as $BP
  | [.items[] | select($BP[.path] == true)] as $BI
  | lg_obj((($BI[] | (.consumes // [])[] | strings), ($B.contract_changes[] | .id)) | {(.): true}) as $S
  | lg_obj($B.claims[] | {(.): true}) as $BC
  | lg_obj($BI[] | (.neighbours.siblings // [])[] | .key | strings | select($BC[.] != true) | {(.): true}) as $SIB
  | lg_obj(($B.files // [])[] | {(.): true}) as $BF
  | def parts($X; $cc): [$cc[] | {id, line, files: (($X.contract_files // {})[.id] // [])}];
  ($B.acks[] | "A\t\(.)"),
  ([ ( $BR[] | select((.name == "^base" or .oid == $B.oid or $BEHIND[.oid] == true or $DROP["\(.host)\t\(.name)"] == true) | not) as $X
       | {other: {branch: $X.name, host: $X.host, pr: $X.pr},
          disp: (if $X.host == $me then $X.name else "\($X.name)@\($X.host)" end),
          cn: (if $RN[$X.name] == true then $X.name else "\($X.name)@\($X.host)" end),
          oid: $X.oid, mb: $X.merge_base} as $o
       | [$X.contract_changes[] | select($S[.id] == true)] as $cc
       | ([$X.claims[] | select($BC[.] == true)] | unique) as $dk
       | lg_obj($X.claim_paths[] | select($BP[.] == true) | {(.): true}) as $DP
       | ([($X.files // [])[] | select($BF[.] == true and $DP[.] != true)] | unique) as $df
       | ([$X.claims[] | select($SIB[.] == true)] | unique) as $ik
       | [ (if $cc != [] then $o + {urgency: "stop", kind: "contracts", vals: [$cc[] | .id], stat: null, parts: parts($X; $cc)} else empty end),
           (if $dk != [] then $o + {urgency: "stop", kind: "keys", vals: $dk, stat: "all"} else empty end),
           (if $df != [] then $o + {urgency: "heads-up", kind: "files", vals: $df, stat: $df} else empty end),
           (if $ik != [] then $o + {urgency: "info", kind: "keys", vals: $ik, stat: "all"} else empty end) ] as $ns
       # B itself, ahead on another host: one info (its first overlap).
       | if $X.name == $B.name and $X.host != $B.host and $AHEAD[$X.oid] == true
         then $ns[0:1][] | . + {urgency: "info", stat: null, parts: [], what: "\($o.disp) is ahead of this branch"}
         else $ns[] end ),
     ( $BR[] | select(.name == "^base") as $X
       | [$X.contract_changes[] | select($S[.id] == true)] as $cc
       | if $cc == [] then empty
         else {other: {branch: $base, host: null, pr: null}, disp: $base, cn: $base, base: true, oid: $X.oid, mb: $X.merge_base,
               urgency: "stop", kind: "contracts", vals: [$cc[] | .id], stat: null, parts: parts($X; $cc)} end ) ]
   | to_entries[] | .value + {n: .key}
   | "J\t\(tojson)",
     "H\t\(.n)\t\(.cn | enc)\t\(.kind):\(.vals | join(",") | enc)\t\(if .base == true then "^state" else .oid end)",
     (if .stat != null or any(.parts[]?; .line == null and (.files | length) > 0) then "P\t\(.oid) \(.mb)" else empty end),
     (if .base == true then (.n as $n | (.parts[] | .files[] | "G\t\($n)\tF\t\(enc)"), (.vals[] | "G\t\($n)\tC\t\(.)")) else empty end))
  end
'

# The notices, finished (jq -n -R; inputs: "I\t<n>\t<id>", "A\t<ack>",
# "S\t<oid>\t<added>\t<deleted>\t<path>"; --slurpfile N: the J objects):
# line 1 the unacked stop count, line 2 {"notices": […]}, then one text
# line per notice.
# shellcheck disable=SC2016  # jq source
_LG_JQ_NTC_FINISH='
def dec: if test("[\u0001\u0002]") then gsub("\u0001"; "\n") | gsub("\u0002"; "\t") else . end;
[inputs | split("\t")] as $L
| lg_obj($L[] | select(.[0] == "I") | {(.[1]): .[2]}) as $ID
| lg_obj($L[] | select(.[0] == "A") | {(.[1]): true}) as $ACK
| lg_lists($L[] | select(.[0] == "S") | {k: .[1], v: {p: (.[4] | dec), a: (.[2] | tonumber), d: (.[3] | tonumber)}}) as $ST
| def stat($o; $fs):
    ($ST[$o] // []) as $all
    | (if $fs == "all" then $all else (lg_obj($fs[] | {(.): true}) as $F | [$all[] | select($F[.p] == true)]) end)
    | if length == 0 then "0 files"
      else "\(length) file\(if length == 1 then "" else "s" end), +\(map(.a) | add) -\(map(.d) | add)" end;
  [ $N[] | . + {id: $ID["\(.n)"]} | select($ACK[.id] != true)
    | .oid as $o
    | {rank: {"stop": 0, "heads-up": 1, "info": 2}[.urgency], disp, kind, vals,
       notice: {id, urgency, other, overlap: {(.kind): .vals},
                what_changed: (if .what != null then .what
                               elif .kind == "contracts"
                               then [.parts[] | if .line != null then "\(.id): \(.line)"
                                                elif (.files | length) > 0 then "\(.id): \(stat($o; .files))"
                                                else "\(.id) (Contract-Change)" end] | join("; ")
                               else stat($o; .stat) end),
                action: {"stop": "reconcile-before-next-chunk", "heads-up": "rebase-after-merge", "info": "heads-up"}[.urgency]}} ]
| sort_by(.rank, .disp, .notice.id) as $S
| ([$S[] | select(.notice.urgency == "stop")] | length),
  ({notices: [$S[] | .notice]} | tojson),
  ($S[] | "\(.notice.urgency) \(.notice.id) \(.disp | lg_q_one) \(if .notice.other.pr == null then "no PR" else "PR #\(.notice.other.pr.number)" end) \(.kind):\(.vals[0:3] | map(lg_q_one) | join(","))\(if (.vals | length) > 3 then " (+\((.vals | length) - 3))" else "" end) — \(.notice.what_changed | lg_q_one) → \(.notice.action)")
'

# _lg_ifl_notices <index> <branches> <B host> <B name> <rel> <out>: B's
# notices into <out> — line 1 the unacked stop count, line 2 the JSON
# payload, then the text lines (see the section header). <rel>: B's
# relatives (_lg_ifl_rel); a base notice's overlap state is read from
# $_LG_IFL_RF (_lg_ifl_range_facts).
_lg_ifl_notices() {
  local ix="$1" br="$2" bh="$3" bn="$4" rel="$5" out="$6" s d n o ov oid
  local -a dg
  _lg_scratch_name
  s=$_LG_SN
  # shellcheck disable=SC2016  # jq source
  jq -L "$_LG_LIB" -r --slurpfile br "$br" --rawfile rel "$rel" --arg bh "$bh" --arg bn "$bn" --arg base "$_LG_IFL_BASEREF" \
    --arg me "$_LG_IFL_ME" "$_LG_JQ_INCLUDE$_LG_JQ_NTC_FIND" "$ix" > "$s.find" || _lg_die "jq failed (the notices)"
  LC_ALL=C awk -v j="$s.nj" -v a="$s.sx" -v p="$s.pairs" -v h="$s.pre" -v g="$s.gx" '
    BEGIN { printf "" > j; printf "" > a; printf "" > p; printf "" > h; printf "" > g }
    substr($0, 1, 2) == "J\t" { print substr($0, 3) > j; next }
    substr($0, 1, 2) == "A\t" { print > a; next }
    substr($0, 1, 2) == "P\t" { k = substr($0, 3); if (!(k in S)) { S[k] = 1; print k > p }; next }
    substr($0, 1, 2) == "G\t" { print substr($0, 3) > g; next }
    substr($0, 1, 2) == "H\t" { print substr($0, 3) > h }' "$s.find" || _lg_die "cannot split the notices"
  if [ -s "$s.pairs" ]; then
    # One diff-tree for every diffstat: "<tip> <mb>" pairs — read as a
    # commit and its parent, so git prints the tip as the header and diffs
    # mb → tip.
    git diff-tree --stdin -r --numstat -z --no-renames < "$s.pairs" > "$s.nz" 2> "$s.err" \
      || _lg_die "git diff-tree failed (the notices' diffstats): $(head -n 1 "$s.err")"
    tr '\n\000' '\001\n' < "$s.nz" | LC_ALL=C awk -v pairs="$s.pairs" '
      BEGIN { while ((getline l < pairs) > 0) { split(l, x, " "); TIP[x[1]] = 1 } }
      ($0 in TIP) { t = $0; next }
      t != "" && $0 != "" {
        i = index($0, "\t"); a = substr($0, 1, i - 1); r = substr($0, i + 1)
        i = index(r, "\t"); d = substr(r, 1, i - 1); p = substr(r, i + 1); gsub(/\t/, "\002", p)
        if (a !~ /^[0-9]+$/) a = 0
        if (d !~ /^[0-9]+$/) d = 0
        print "S\t" t "\t" a "\t" d "\t" p
      }' >> "$s.sx" || _lg_die "cannot read the notices' diffstats"
  fi
  if [ -s "$s.gx" ]; then
    # A base notice's head (ruling C1): the digest of its overlap's state,
    # sorted lines "F\t<path>\t<post-image blob>" (each overlap contract
    # file) and "C\t<commit>" (each base commit whose Contract-Change names
    # an overlap contract) — so only the overlap moving fires it again, not
    # the base taking unrelated commits.
    LC_ALL=C awk -F '\t' -v rf="$_LG_IFL_RF" -v d="$s.st" '
      BEGIN {
        while ((getline l < rf) > 0) {
          split(l, x, "\t")
          if (x[1] == "b") BL[x[3]] = x[2]; else if (x[1] == "c") CM[x[3]] = CM[x[3]] " " x[2]
        }
      }
      { f = d "." $1 }
      $2 == "F" { print "F\t" $3 "\t" BL[$3] > f }
      $2 == "C" { k = split(CM[$3], c, " "); for (i = 1; i <= k; i++) print "C\t" c[i] > f }
      END { close(f) }' "$s.gx" || _lg_die "cannot read the base's overlap state"
    cut -f 1 "$s.gx" | LC_ALL=C sort -u > "$s.gn" || _lg_die "cannot list the base notices"
    while IFS= read -r n; do
      LC_ALL=C sort -u "$s.st.$n" > "$s.st.$n.s" || _lg_die "cannot sort the base's overlap state"
      _hash_one "$s.st.$n.s"
      dg[n]=${_HASH#sha256:}
    done < "$s.gn"
  fi
  if [ -s "$s.pre" ]; then
    # The ids: one file per notice holding <other> NUL <overlap> NUL <oid>,
    # one sha256 call for all.
    d="$s.ids"
    mkdir -p -- "$d" || _lg_die "cannot create $d"
    while IFS="$(printf '\t')" read -r n o ov oid; do
      o=${o//$'\001'/$'\n'}
      o=${o//$'\002'/$'\t'}
      ov=${ov//$'\001'/$'\n'}
      ov=${ov//$'\002'/$'\t'}
      if [ "$oid" = "^state" ]; then
        oid=${dg[n]:-}
        [ -n "$oid" ] || _lg_die "internal: no overlap state for base notice $n"
      fi
      printf '%s\0%s\0%s' "$o" "$ov" "$oid" > "$d/$n" || _lg_die "cannot write $d/$n"
    done < "$s.pre"
    # (The files are named 0, 1, …: the glob is safe.)
    if command -v sha256sum >/dev/null 2>&1; then
      ( cd "$d" && sha256sum -- * ) > "$s.sha" 2> "$s.err" || _lg_die "sha256sum failed"
    else
      ( cd "$d" && shasum -a 256 -- * ) > "$s.sha" 2> "$s.err" || _lg_die "shasum failed"
    fi
    LC_ALL=C awk '{ print "I\t" $2 "\t" substr($1, 1, 12) }' "$s.sha" >> "$s.sx" || _lg_die "cannot read the notice ids"
  fi
  jq -L "$_LG_LIB" -n -r -R --slurpfile N "$s.nj" "$_LG_JQ_INCLUDE$_LG_JQ_NTC_FINISH" "$s.sx" > "$out" \
    || _lg_die "jq failed (the notices' payload)"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_notices() {
  local s ix want bh="" bn="" bo="" bmb="" fetch=0 rc=0 nstop=0 head="" payload=""
  _lg_init notices
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  # --hook (Task 16c U4; hooks.sh): the SessionStart hook — the current
  # branch, offline, its own output.
  if [ -n "${_OPT_hook:-}" ]; then
    [ -z "$_OPT_branch" ] && [ -z "$_OPT_gate" ] && [ -z "$_OPT_fetch" ] || _lg_usage "--hook takes no other option"
    _lg_hook_payload
    DOC_TOOLS_LEDGER_OFFLINE=1
    export DOC_TOOLS_LEDGER_OFFLINE
  fi
  if [ -n "$_OPT_fetch" ]; then fetch=1; fi
  want=${_OPT_branch:-}
  _lg_scratch_name
  s=$_LG_SN
  _lg_ifl_load
  if [ "$_LG_IFL_ON" != 1 ]; then
    if [ -n "${_OPT_hook:-}" ]; then _lg_hook_done; fi
    if [ "$_LG_FORMAT" = json ]; then
      printf '{"inflight_enabled":false,"notices":[]}\n' > "$s.json" || _lg_die "cannot write $s.json"
      _lg_emit notices 0 "$s.json"
    fi
    printf 'in-flight awareness is off (config inflight.enabled): no notices\n' > "$s.out" || _lg_die "cannot write $s.out"
    _lg_out_file "$s.out"
    _lg_emit notices 0
  fi
  # From here a hook-mode failure is the "cannot list" line.
  if [ -n "${_OPT_hook:-}" ]; then _LG_HOOK_FAIL=_lg_notices_hook_fail; fi
  _lg_ifl_prepare "$fetch"
  [ -n "$_LG_IFL_B" ] || _lg_die "the base '$_LG_IFL_BASEREF' does not resolve: no notices"
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    _lg_ifl_note "offline (DOC_TOOLS_LEDGER_OFFLINE=1): notices from the in-flight refs and branch facts here, nothing fetched"
  fi
  # B: --branch <name>|<name>@<host>, else the current branch, else (HEAD
  # detached) this worktree's "(detached:…)" entry — the one at HEAD.
  if [ -z "$want" ] && [ -z "$_LG_IFL_CUR" ]; then
    head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  fi
  LC_ALL=C awk -F '\t' -v me="$_LG_IFL_ME" -v want="$want" -v cur="$_LG_IFL_CUR" -v head="$head" '
    want != "" { if (($1 == me && $2 == want) || ($2 "@" $1) == want) { print; exit } next }
    cur != "" { if ($1 == me && $2 == cur) { print; exit } next }
    head != "" && $1 == me && substr($2, 1, 10) == "(detached:" && $3 == head { print; exit }' "$_LG_IFL_SCAN" > "$s.b" \
    || _lg_die "cannot find the branch"
  { IFS="$(printf '\t')" read -r bh bn bo _ bmb _; } < "$s.b" 2>/dev/null || true
  if [ -z "$bn" ] && [ -n "$want" ]; then
    if git show-ref -q --verify "refs/heads/$want" 2>/dev/null || [ "$want" = "$_LG_IFL_BB" ]; then
      _lg_ifl_note "'$want' is not in flight (merged, no commits beyond the base, or older than inflight.max_age_days): no notices"
    else
      _lg_die "no branch '$want' here or in flight"
    fi
  fi
  # B's claimed items are this working tree's (the index): for another
  # branch they are read as they are here, not at its tip (ruling m4 —
  # reading them there is a cold index of that commit, ~3 s at 3,000
  # items, past the notices' 2 s budget). The note says so.
  if [ -n "$want" ] && [ -n "$bn" ] && { [ "$bh" != "$_LG_IFL_ME" ] || [ "$bn" != "$_LG_IFL_CUR" ]; }; then
    _lg_ifl_note "--branch $want: the consumes and siblings of the items it claims are read from this working tree, not from $want's tip"
  fi
  ix=$(_lg_index) || exit "$?"
  _lg_ifl_index_note
  if [ -n "$bn" ]; then
    # Every branch's facts, checked (computed when missing); the base since
    # B's merge base as one more line ("^base": never a branch name).
    _lg_ifl_resolve "$_LG_IFL_CANDS" "$s.scan" 1
    _lg_ifl_rel "$s.scan" "$bh" "$bn" "$bo" "$s.rel"
    _LG_IFL_RF=""
    if [ "$bmb" != "$_LG_IFL_B" ]; then
      _lg_ifl_range_facts "$bmb" "$_LG_IFL_B"
      printf '%s\t^base\t%s\t-\t%s\t%s\t\n' "$_LG_IFL_ME" "$_LG_IFL_B" "$bmb" "$_LG_IFL_RF" >> "$s.scan" || _lg_die "cannot write $s.scan"
    fi
    _lg_ifl_join "$ix" "$s.scan" 2 "$s.br"
    _lg_ifl_notices "$ix" "$s.br" "$bh" "$bn" "$s.rel" "$s.nt"
  else
    printf '0\n{"notices":[]}\n' > "$s.nt" || _lg_die "cannot write $s.nt"
  fi
  { IFS= read -r nstop; IFS= read -r payload; } < "$s.nt" || _lg_die "internal: no notices payload"
  if [ -n "${_OPT_hook:-}" ]; then
    tail -n +3 "$s.nt" > "$s.out" || _lg_die "cannot write $s.out"
    _LG_HOOK_FAIL=""
    _lg_notices_hook_out "$s.out"
    _lg_hook_done
  fi
  if [ -n "$_OPT_gate" ] && [ "$nstop" -gt 0 ] 2>/dev/null; then rc=1; fi
  # A gate never passes on in-flight data it could not verify (CORE-m1): a
  # failed fetch — not a deliberate DOC_TOOLS_LEDGER_OFFLINE=1 — with no
  # stop to block on is "could not verify" (2). A stop found anyway blocks
  # as a stop (1).
  if [ -n "$_OPT_gate" ] && [ "$rc" = 0 ] && [ -n "$_LG_IFL_UNVERIFIED" ]; then
    _lg_die "could not verify: $_LG_IFL_UNVERIFIED — notices --gate does not pass on in-flight data it could not fetch (--fetch retries now; DOC_TOOLS_LEDGER_OFFLINE=1 decides on the refs here)"
  fi
  if [ "$_LG_FORMAT" = json ]; then
    printf '%s\n' "$payload" > "$s.json" || _lg_die "cannot write $s.json"
    _lg_pr_data_into "$s.json"
    _lg_emit notices "$rc" "$s.json"
  fi
  tail -n +3 "$s.nt" > "$s.out" || _lg_die "cannot write $s.out"
  _lg_out_file "$s.out"
  _lg_emit notices "$rc"
}

# --- Push and prune (design §H.1) -----------------------------------------------------

# _lg_ifl_push_run <git push args…>: git push in the background and waited
# for, reaped with every process under it on TERM / INT (_lg_ifl_fetch_run's
# shape); stdout and stderr are the caller's.
_lg_ifl_push_run() {
  local p rc=0
  LC_ALL=C git push "$@" < /dev/null &
  p=$!
  # shellcheck disable=SC2064  # $p now, on purpose
  trap "_lg_kill_tree $p; exit 143" TERM
  # shellcheck disable=SC2064
  trap "_lg_kill_tree $p; exit 130" INT
  wait "$p" || rc=$?
  trap 'exit 143' TERM
  trap 'exit 130' INT
  return "$rc"
}

# _lg_ifl_push_refname <host> <branch>: print the ref `inflight --push`
# writes, <ref_prefix>/<host>/<branch>; dies (2) when `git check-ref-format`
# refuses it.
_lg_ifl_push_refname() {
  local r
  _lg_ifl_load
  r="$_LG_IFL_PREFIX/$1/$2"
  git check-ref-format "$r" 2>/dev/null \
    || _lg_die "'$r' is not a ref name git accepts (git check-ref-format): nothing pushed"
  printf '%s\n' "$r"
}

# _lg_ifl_push_end <s> <rc> <pushed true|false> <stream out|err> <line>
# [<ref> <oid> <base-oid>]: the --push verdict — <line> on the run's output
# (out) or stderr (err, a warning); JSON {pushed, remote, ref, oid,
# base_oid, note} (plus $s.check, when present, as "check").
_lg_ifl_push_end() {
  local s="$1" rc="$2" pushed="$3" stream="$4" line="$5" ref="${6:-}" oid="${7:-}" mb="${8:-}"
  if [ "$stream" = err ]; then printf 'ledger inflight --push: %s\n' "$line" >&2; fi
  if [ "$_LG_FORMAT" = json ]; then
    [ -f "$s.check" ] || printf 'null\n' > "$s.check" || _lg_die "cannot write $s.check"
    # shellcheck disable=SC2016  # jq source
    jq -nc --argjson p "$pushed" --arg r "${_LG_IFL_REMOTE:-}" --arg ref "$ref" --arg o "$oid" --arg mb "$mb" --arg n "$line" \
      --slurpfile c "$s.check" \
      'def nn: if . == "" then null else . end;
       {pushed: $p, remote: ($r | nn), ref: ($ref | nn), oid: ($o | nn), base_oid: ($mb | nn), note: $n}
       + (if $c[0] == null then {} else {check: $c[0]} end)' > "$s.json" || _lg_die "jq failed (the push verdict)"
    _lg_emit inflight "$rc" "$s.json"
  fi
  if [ "$stream" = out ]; then
    printf '%s\n' "$line" > "$s.out" || _lg_die "cannot write $s.out"
    if [ -f "$s.ppc" ]; then cat -- "$s.ppc" >> "$s.out" || _lg_die "cannot write $s.out"; fi
    _lg_out_file "$s.out"
  fi
  _lg_emit inflight "$rc"
}

# _lg_ifl_push <s>: `ledger inflight --push` (ruling R5). This host's
# current branch, when in-flight awareness is on and it has commits not on
# the base: inflight.pre_push_check (when set) runs with `sh -c` in the
# work tree's top level, its stdin exactly one line "<merge-base>..<tip>"
# (the merge base with the base, HEAD's commit) — non-zero: nothing pushed,
# its output shown, exit 1; then `git push --no-verify --force <keys.remote's
# push URL> <tip>:<ref_prefix>/<host>/<branch>` (the name checked with git
# check-ref-format: refused, exit 2). DOC_TOOLS_LEDGER_OFFLINE=1, a remote
# that cannot be reached, or an authentication / permission failure ("Permission
# denied", "Authentication failed", "could not read Username", "returned
# error: 403", "HTTP 403", "Forbidden" — lib.sh _LG_PERM_RE, said as such,
# a rejected ref included): a warning, exit 0; a push the remote refuses
# for any other reason ("rejected"): exit 2. Detached HEAD, no commits beyond the base, the
# base's own branch or views.branch: one line, exit 0.
_lg_ifl_push() {
  local s="$1" full br tip b bfull bb="" mb host ref url ppc rc=0 err
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    _lg_ifl_push_end "$s" 0 false err "offline (DOC_TOOLS_LEDGER_OFFLINE=1): nothing pushed"
  fi
  if [ "$_LG_IFL_ON" != 1 ]; then
    _lg_ifl_push_end "$s" 0 false out "in-flight awareness is off (config inflight.enabled): nothing pushed"
  fi
  full=$(git symbolic-ref -q HEAD 2>/dev/null) || full=""
  case "$full" in
    refs/heads/?*) br=${full#refs/heads/} ;;
    *) _lg_ifl_push_end "$s" 0 false out "detached HEAD: nothing pushed (an in-flight ref names a branch)" ;;
  esac
  tip=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) \
    || _lg_ifl_push_end "$s" 0 false out "'$br' has no commits: nothing pushed"
  case "$_LG_IFL_BASEREF" in
    -*|''|$'\a'*) _lg_die "config base is not a revision: '$_LG_IFL_BASEREF'" ;;
  esac
  b=$(git rev-parse -q --verify "$_LG_IFL_BASEREF^{commit}" 2>/dev/null) \
    || _lg_die "the base '$_LG_IFL_BASEREF' does not resolve: nothing pushed"
  bfull=$(git rev-parse --symbolic-full-name "$_LG_IFL_BASEREF" 2>/dev/null) || bfull=""
  case "$bfull" in
    refs/heads/?*) bb=${bfull#refs/heads/} ;;
    "refs/remotes/$_LG_IFL_REMOTE/"?*) bb=${bfull#refs/remotes/"$_LG_IFL_REMOTE"/} ;;
    refs/remotes/?*/?*) bb=${bfull#refs/remotes/*/} ;;
  esac
  if [ "$br" = "$bb" ] || [ "$br" = "$_LG_IFL_VIEWS" ]; then
    _lg_ifl_push_end "$s" 0 false out "'$br' is the base's branch or views.branch — never in flight: nothing pushed"
  fi
  mb=$(git merge-base "$b" "$tip" 2>/dev/null) || mb=""
  [ -n "$mb" ] || _lg_ifl_push_end "$s" 0 false out "'$br' shares no history with the base: nothing pushed"
  [ "$mb" != "$tip" ] || _lg_ifl_push_end "$s" 0 false out "'$br' has no commits beyond the base: nothing pushed"
  host=$(_lg_host_id "$_LG_IFL_HOSTCFG") || exit "$?"
  ref=$(_lg_ifl_push_refname "$host" "$br") || exit "$?"
  url=$(git remote get-url --push "$_LG_IFL_REMOTE" 2>/dev/null) || url=""
  [ -n "$url" ] || _lg_die "in-flight push: remote '$_LG_IFL_REMOTE' (keys.remote) has no URL"
  # shellcheck disable=SC2016  # jq source
  ppc=$(_lg_cfg '.inflight.pre_push_check | if type == "string" then . elif . == null then "" else "\u0007" end') || exit "$?"
  case "$ppc" in
    $'\a') _lg_die "config inflight.pre_push_check is not a command string" ;;
  esac
  if [ -n "$ppc" ]; then
    printf '%s..%s\n' "$mb" "$tip" > "$s.ppin" || _lg_die "cannot write $s.ppin"
    sh -c "$ppc" < "$s.ppin" > "$s.ppc" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
      jq -Rsc --argjson rc "$rc" '{exit: $rc, output: .}' "$s.ppc" > "$s.check" || _lg_die "jq failed (the check's output)"
      _lg_ifl_push_end "$s" 1 false out "inflight.pre_push_check exited $rc on $mb..$tip: nothing pushed to $ref" "$ref" "$tip" "$mb"
    fi
    rm -f -- "$s.ppc"
  fi
  if ! _lg_ifl_push_run -q --no-verify --force "$url" "$tip:$ref" > "$s.perr" 2>&1; then
    err=$(head -n 3 "$s.perr" | tr '\n' ' ' | sed 's/ *$//')
    # Credentials or rights (ruling m5): said as such, still exit 0 — the
    # post-commit hook never fails a commit — whether git reports it as an
    # HTTP failure or as a rejected ref (lib.sh _LG_PERM_RE, shared with the
    # counter CAS: final review OPS-m9).
    if grep -Eq "$_LG_PERM_RE" "$s.perr"; then
      _lg_ifl_push_end "$s" 0 false err "authentication or permission failure on $_LG_IFL_REMOTE ($err): nothing pushed" "$ref" "$tip" "$mb"
    fi
    if grep -q 'rejected' "$s.perr"; then
      _lg_die "the in-flight push to $_LG_IFL_REMOTE $ref was rejected: $err"
    fi
    _lg_ifl_push_end "$s" 0 false err "$_LG_IFL_REMOTE cannot be reached ($err): nothing pushed" "$ref" "$tip" "$mb"
  fi
  _lg_ifl_push_end "$s" 0 true out "pushed $(git rev-parse --short "$tip") to $_LG_IFL_REMOTE $ref" "$ref" "$tip" "$mb"
}

# _lg_ifl_prune <base> <dry 0|1>: delete the in-flight refs on keys.remote
# whose tips are on <base> (reachable) or older than inflight.max_age_days
# (> 0) — read from the copies the run's forced fetch just wrote to
# $_LG_IFL_TMP/ (_lg_ifl_prepare 1: publish), so nothing is listed again;
# under refs/heads/ only <prefix>/<host>/<name>-shaped refs (the mirror
# shape). One `git push --porcelain --no-verify --force-with-lease=<ref>:<oid>…
# <url> --delete <ref>…` (each lease the fetched value: a ref pushed since is
# kept); never offline, never without a fetched remote. With <dry> 1 nothing
# is pushed. The refs deleted (or, dry, that would be) into
# $_LG_IFL_PRUNED (a file, one per line; "" when none). Publish has pushed
# its views by now: every failure here — git's, a tool's, an internal one
# (ruling m6) — is the run's note ("not pruned"), never the run's failure.
_LG_IFL_PRUNED=""
_lg_ifl_prune() {
  local b="$1" dry="$2" s rc=0 n="" why="" p
  _LG_IFL_PRUNED=""
  [ "$_LG_IFL_ON" = 1 ] || return 0
  [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" != 1 ] || return 0
  [ -n "${_LG_IFL_URL:-}" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  rm -f -- "$s.note" "$s.die" "$s.sent" "$s.pruned"
  # The work in a subshell, errexit live there: whatever stops it — a
  # _lg_die (redefined there to leave its message), a failed command, an
  # unset variable — ends the subshell alone. It runs in the background and
  # is waited for (_lg_ifl_push_run's shape): bash runs a trap only once a
  # foreground child exits, while `wait` returns at once — so a TERM / INT
  # to the run reaps the subshell and every process under it (the push,
  # its transport, the remote's side of a local one) and ends the run now,
  # not when the push is done.
  ( set -e; _lg_ifl_prune_run "$b" "$dry" "$s" ) < /dev/null &
  p=$!
  # shellcheck disable=SC2064  # $p now, on purpose
  trap "_lg_kill_tree $p; exit 143" TERM
  # shellcheck disable=SC2064
  trap "_lg_kill_tree $p; exit 130" INT
  wait "$p" || rc=$?
  trap 'exit 143' TERM
  trap 'exit 130' INT
  if [ -s "$s.note" ]; then
    { IFS= read -r n < "$s.note"; } 2>/dev/null || n=""
    [ -z "$n" ] || _lg_ifl_note "$n"
  fi
  if [ "$rc" != 0 ]; then
    { IFS= read -r why < "$s.die"; } 2>/dev/null || why=""
    [ -n "$why" ] || why="internal: the prune exited $rc"
    if [ -e "$s.sent" ]; then
      _lg_ifl_note "in-flight prune on $_LG_IFL_REMOTE: $why, after its push was sent — which refs were deleted is unknown"
    else
      _lg_ifl_note "in-flight refs not pruned ($why)"
    fi
    return 0
  fi
  if [ -s "$s.pruned" ]; then _LG_IFL_PRUNED="$s.pruned"; fi
}

# _lg_ifl_prune_run <base> <dry> <s>: _lg_ifl_prune's work, in its
# subshell: the refs deleted (or that would be) into <s>.pruned, a note's
# text into <s>.note, <s>.sent once the push has started, a fatal error's
# message into <s>.die.
_lg_ifl_prune_run() {
  local b="$1" dry="$2" s="$3" cutoff=0 now heads=0 n list r o rc=0
  local -a args
  [ "${BASH_SUBSHELL:-0}" -gt 0 ] || _lg_die "internal: _lg_ifl_prune_run outside its subshell"
  # Never the run's verdict from here: the message is left for the caller
  # (this definition lives in the subshell alone; _lg_die and _die call it).
  # shellcheck disable=SC2329  # invoked through _lg_die / _die
  _lg_fail() {
    printf '%s\n' "$2" > "$s.die" 2>/dev/null || true
    exit 2
  }
  case "$_LG_IFL_PREFIX" in refs/heads/?*) heads=1 ;; esac
  if [ "$_LG_IFL_AGE" -gt 0 ] 2>/dev/null; then
    now=${_LG_RNOW:-}
    [ -n "$now" ] || now=$(date +%s) || _lg_die "date failed"
    cutoff=$((now - _LG_IFL_AGE * 86400))
  fi
  if ! git for-each-ref --format='%(objectname)%09%(committerdate:unix)%09%(refname)' "$_LG_IFL_TMP/" > "$s.all" 2> "$s.err" \
      || ! git for-each-ref --merged="$b" --format='%(refname)' "$_LG_IFL_TMP/" > "$s.merged" 2>> "$s.err"; then
    _lg_die "git for-each-ref failed: $(head -n 1 "$s.err")"
  fi
  LC_ALL=C awk -F '\t' -v tmp="$_LG_IFL_TMP/" -v ip="$_LG_IFL_PREFIX/" -v heads="$heads" -v cutoff="$cutoff" -v merged="$s.merged" \
    "$_LG_AWK_IFL_SHAPED"'
    BEGIN { while ((getline l < merged) > 0) M[l] = 1 }
    {
      r = $3; rr = ip substr(r, length(tmp) + 1)
      if (heads && !shaped(rr, ip)) next
      if ((r in M) || (cutoff > 0 && $2 + 0 < cutoff)) print rr "\t" $1
    }' "$s.all" | LC_ALL=C sort > "$s.cand" || _lg_die "cannot list them"
  [ -s "$s.cand" ] || return 0
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    # TEST-ONLY (scripts/test-ledger.sh): an internal failure in the prune.
    ifl-prune-internal) _lg_die "selftest: an internal failure in the prune" ;;
  esac
  if [ "$dry" = 1 ]; then
    cut -f 1 "$s.cand" > "$s.pruned"
    return 0
  fi
  args=()
  while IFS="$(printf '\t')" read -r r o; do args[${#args[@]}]="--force-with-lease=$r:$o"; done < "$s.cand"
  args[${#args[@]}]=$_LG_IFL_URL
  args[${#args[@]}]=--delete
  while IFS="$(printf '\t')" read -r r o; do args[${#args[@]}]=$r; done < "$s.cand"
  : > "$s.sent"
  _lg_ifl_push_run --porcelain --no-verify "${args[@]}" > "$s.out" 2> "$s.err" || rc=$?
  # --porcelain: "-\t:<ref>\t[deleted]" per ref deleted.
  LC_ALL=C awk -F '\t' '$1 == "-" { r = $2; sub(/^:/, "", r); print r }' "$s.out" | LC_ALL=C sort > "$s.pruned"
  if [ "$rc" != 0 ] || [ "$(wc -l < "$s.pruned" | tr -d ' ')" != "$(wc -l < "$s.cand" | tr -d ' ')" ]; then
    cut -f 1 "$s.cand" | LC_ALL=C comm -23 - "$s.pruned" > "$s.left"
    n=$(wc -l < "$s.left" | tr -d ' ')
    list=$(head -n 3 "$s.left" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
    if [ "$n" -gt 3 ]; then list="$list, …"; fi
    # The reason: git's summary of the first refused ref, else its first
    # error line.
    r=$(LC_ALL=C awk -F '\t' '$1 == "!" { print $3; exit }' "$s.out" 2>/dev/null) || r=""
    [ -n "$r" ] || r=$(grep -v '^ *$' "$s.err" 2>/dev/null | head -n 1) || r=""
    printf '%s\n' "$n in-flight ref(s) not pruned on $_LG_IFL_REMOTE (${r:-git push exited $rc}): $list" > "$s.note"
  fi
}

# _lg_ifl_pruned_line <verb>: "<verb> <n> in-flight ref(s) from <remote>:
# <the first three>[, …]" for $_LG_IFL_PRUNED.
_lg_ifl_pruned_line() {
  local n list
  n=$(wc -l < "$_LG_IFL_PRUNED" | tr -d ' ')
  list=$(head -n 3 "$_LG_IFL_PRUNED" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  if [ "$n" -gt 3 ]; then list="$list, …"; fi
  printf '%s %s in-flight ref(s) from %s: %s\n' "$1" "$n" "$_LG_IFL_REMOTE" "$list"
}

# _lg_note_flush: print the run's "ledger:" note held by publish
# (_LG_NOTE_DEFER=publish: its index build held it so the prune's outcome
# joins it). doc-tools.sh _on_exit calls it too, so a run that ends early
# still prints it.
_lg_note_flush() {
  local n=""
  [ "${_LG_NOTE_DEFER:-}" = publish ] || return 0
  _LG_NOTE_DEFER=""
  { IFS= read -r n < "$_SCRATCH/lg-pr.held"; } 2>/dev/null || n=""
  _lg_ix_pr_note "$n"
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
    [ -z "$_OPT_fetch" ] && [ -z "${_OPT_branch:-}" ] || _lg_usage "--push takes no --fetch or --branch"
    _lg_ifl_push "$s"
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

# shellcheck shell=bash
# scripts/ledger/keys.sh — item keys (design §D): resolving a reference to an
# item, the counter ref on the remote and its compare-and-swap, allocation
# (one or a batch), provisional keys, finalize, and the verbs `ledger new`,
# `ledger assign`, `ledger finalize`. Sourced by lib.sh (before query.sh,
# whose `show` program includes _LG_JQ_RESOLVE_DEFS); uses lib.sh's _lg_init,
# _lg_cfg, _lg_die, _lg_usage, _lg_emit, _lg_out_file, _lg_registry,
# index.sh's _lg_index and _LG_JQ_INDEX_DEFS, parse.sh's parsers and
# writers, glob.sh's _lg_paths_filter and doc-tools.sh's _hash_one,
# _tmp_beside and _replace_file.
#
# Resolution (_lg_resolve <ref>): in order, the first that matches —
#   1. a path from the top level ("./" allowed) of an item;
#   2. a key or an alias, case-insensitive: "L-14", or "L 14" / "L #14"
#      (read as "L-14"); a provisional key recorded in
#      docs/ledger/finalized.json reaches the key it became;
#   3. a legacy ref "<old>#<n>", "<old> row <n>", "<old> ledger row <n>",
#      or "<old> #<n>" for a letter-suffixed row only (with digits alone
#      it is a key form, 2) (case-insensitive; <n> digits and an optional
#      letter, "21c": canonical without leading zeros and in lower case,
#      "07B" → "7b" — a map key's row is read the same way), looked up as
#      "<id>#<n>" in the legacy map
#      (config "legacy"), where <id> is tried as <old> itself, its file stem,
#      the id config legacy_ledgers maps to a file with that stem, and the
#      stem without a trailing "-ledger" (Task 15's rule for legacy ids).
#      {"key": K} → K's item (as in 2); {"item": P} → P; {"archived": A} →
#      the anchor A (rc 0, kind "archived");
#   4. a path stem (the file name without ".md"), as `ls` prints an item
#      without a key.
# Several items at one step → ambiguous (rc 3); none → rc 1.
#
# Keys (design §D): "<ledger>-<n>"; a provisional key is
# "<ledger>-~<the first 4 to 8 hex digits of sha256(item path)>": 4,
# lengthened past a key it would repeat (_lg_k_prov_lines).
#
# The counter ref (config keys.counter_ref on keys.remote) is a commit whose
# tree is one blob, counters.json: {ledger: next number}. Allocation fetches
# it (one ref, into refs/doc-superpowers/ledger/counters-remote), writes a
# commit with the new numbers whose parent is the fetched one, and pushes it
# with --force-with-lease=<ref>:<fetched oid> (--no-verify: a pre-push hook
# guards the user's branches, not this ref). The remote's ref update is
# the atomic step: two allocators never get the same numbers. The loser
# retries — at most 8 times, 0.1–0.6 s of random jitter apart, re-reading
# each time — then gives up (rc 2; never a provisional key: the remote was
# reachable). A ledger absent from the counters starts after the highest key
# number (keys and aliases) of the items at config base (fetched first, into
# a private ref, when it is a remote-tracking ref). Every counter commit
# carries a random nonce: two allocators writing the same numbers on the
# same parent in the same second must not produce one commit id — the
# second push would read "up to date" (exit 0) and both would take the keys.
#
# Push outcome (_lg_counter_cas): success ONLY when the push exits 0 and the
# ref's porcelain flag is " " (fast-forward), "*" (created) or "=" (the
# remote already has this very commit: ours, thanks to the nonce) → 0;
# "!" with "stale info", "failed to lock" or "failed to update ref" → 1
# (retry) — and with the reasons git ≥ 2.51's receive-pack gives the same
# lost race when its ref transaction finds the ref moved under it ("reference
# already exists": a concurrent create; "incorrect old value provided" /
# "reference does not exist": a concurrent update; deviation from the plan's
# list, which predates them — observed in the race test on git 2.54); exit
# 128 or no status line for the ref → 4 (transport), as is a refusal in
# the words of a permission failure (lib.sh _LG_PERM_RE: "403 Forbidden",
# "Permission denied", … — a claude.ai/code session's proxy; final review
# OPS-m9), which then gives provisional keys as an unreachable remote does;
# any other outcome (a declining hook, a refused namespace, "+" …) → 2.
# Retrying is always safe:
# only a push that exits 0 with one of the three flags hands out keys.
# Known limit: two processes of ONE repository racing to create the counter
# ref share its local copy (refs/doc-superpowers/ledger/counters-remote); the
# loser can then see an outcome outside the retry set and exit 2 (a
# spurious "could not allocate" — run it again). Never a duplicate key: the
# remote's ref update still decides.
#
# The counter ref is read from the remote's push URL (remote.<name>.pushurl,
# else url): the repository the CAS writes to. Seeding reads the base fetched
# from its remote's url into a private ref (refs/remotes/ are never moved).
#
# keys.mode "merge" (fork-and-PR repositories): allocation never touches the
# network — every key is provisional — and `ledger finalize`, run on the
# base, numbers them after the highest key in the working tree and commits
# the rewrite ("ledger: finalize N keys").

_LG_COUNTERS_REMOTE=refs/doc-superpowers/ledger/counters-remote
_LG_BASE_REMOTE=refs/doc-superpowers/ledger/base-remote
_LG_K_BASE_C=""      # the base commit seeding reads (_lg_k_fetch_base)
_LG_ALLOC_RETRIES=8
_LG_K_MODE=""
_LG_K_REMOTE=""
_LG_K_REF=""
_LG_K_BASE=""
_LG_ALLOC_STRICT=""  # 1: no provisional key — an unreachable remote dies (finalize)

# --- Resolution --------------------------------------------------------------------

# jq: lg_resolve($ref; $cfg), applied to the index object →
# {r: "item", v: path} | {r: "archived", v: anchor} | {r: "ambiguous", v: [paths]} | {r: "none"}.
# shellcheck disable=SC2016  # jq source
_LG_JQ_RESOLVE_DEFS='
def lg_r_stem: split("/") | last | if endswith(".md") then .[0:-3] else . end;
def lg_r_by_key($ix; $k):
  ($k | ascii_downcase) as $l
  | [$ix.items[] | select(((.key // "") | ascii_downcase) == $l or any((.aliases // [])[]; ascii_downcase == $l)) | .path]
  | unique;
def lg_r_keyish($ix; $k):
  lg_r_by_key($ix; $k) as $m
  | if $m != [] then $m
    else (($ix.finalized // {}) | if type == "object" then (.[$k] // .[$k | ascii_downcase] // null) else null end) as $to
      | if ($to | type) == "string" then lg_r_by_key($ix; $to) else [] end
    end;
def lg_r_one($m):
  if ($m | length) == 1 then {r: "item", v: $m[0]} elif ($m | length) > 1 then {r: "ambiguous", v: $m} else {r: "none"} end;
def lg_r_legacy_ids($old; $cfg):
  ($old | lg_r_stem) as $stem
  | reduce ($old, $stem,
            (($cfg.legacy_ledgers // {}) | if type == "object" then to_entries[]
               | select((.value | type) == "string" and (.value | lg_r_stem) == $stem) | .key else empty end),
            ($stem | if endswith("-ledger") then .[0:-7] else . end)) as $id
      ([]; if $id == "" or index([$id]) != null then . else . + [$id] end);
# lg_r_row: a legacy row number as typed → its canonical form: the digits
# without leading zeros, then the optional letter, lower case ("07B" → "7b");
# null when it is not one.
def lg_r_row:
  ascii_downcase | (capture("^0*(?<d>[0-9]+)(?<s>[a-z]?)$") // null) | if . == null then null else .d + .s end;
# lg_r_lkey: a legacy map key "<id>#<row>", lower case, its row canonical.
def lg_r_lkey:
  ascii_downcase | (rindex("#") // null) as $i
  | if $i == null then . else .[0:$i + 1] + (.[$i + 1:] | lg_r_row // .) end;
def lg_r_legacy($ix; $cfg; $old; $n):
  ($ix.legacy // {}) as $L
  | if ($L | type) != "object" then null
    else first(lg_r_legacy_ids($old; $cfg)[] as $id
               | "\($id)#\($n)" as $k
               | ($k | ascii_downcase) as $lk
               | ($L[$k] // first($L | to_entries[] | select(.key | lg_r_lkey == $lk) | .value) // empty)) // null
    end;
def lg_resolve($ref; $cfg):
  . as $ix
  | ($ref | gsub("^\\s+|\\s+$"; "")) as $r
  | ($r | if startswith("./") then sub("^(\\./)+"; "") else . end) as $p
  | if $p != "" and any($ix.items[]; .path == $p) then {r: "item", v: $p}
    else
      (if ($r | test("^\\S+$")) then $r
       else ($r | capture("^(?<l>\\S+)\\s+#?\\s*(?<n>[0-9]+)$") // null | if . == null then null else "\(.l)-\(.n)" end)
       end) as $k
      | (if $k == null then [] else lg_r_keyish($ix; $k) end) as $m
      | if $m != [] then lg_r_one($m)
        else
          # "<old> #<n>" spaced is a key form ("L #14", step 2): as a legacy
          # ref it takes a letter-suffixed row only, so a missing key never
          # falls through to a legacy row of the same number.
          ($r | capture("^(?<o>[^\\s#]+)#(?<n>[0-9]+[A-Za-z]?)$")
                // capture("^(?<o>[^\\s#]+)\\s+#(?<n>[0-9]+[A-Za-z])$")
                // capture("^(?<o>\\S+)\\s+(?:ledger\\s+)?row\\s+#?(?<n>[0-9]+[a-z]?)$"; "i") // null) as $lg
          | (if $lg == null then null else lg_r_legacy($ix; $cfg; $lg.o; ($lg.n | lg_r_row)) end) as $e
          | if $e != null then
              (if ($e | type) != "object" then {r: "none"}
               elif ($e.key | type) == "string" then lg_r_one(lg_r_keyish($ix; $e.key))
               elif ($e.item | type) == "string" then {r: "item", v: $e.item}
               elif ($e.archived | type) == "string" then {r: "archived", v: $e.archived}
               else {r: "none"} end)
            else lg_r_one([$ix.items[] | select(.path | lg_r_stem == $p) | .path])
            end
        end
    end;
'

# _lg_k_multiword <text>: the text is one of the several-word reference forms
# ("L 14", "L #14", "<old> row <n>", "<old> ledger row <n>").
_lg_k_multiword() {
  local l='[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]?'
  local re1='^[^[:space:]]+[[:space:]]+#?[[:space:]]*[0123456789]+'"$l"'$'
  local re2='^[^[:space:]]+[[:space:]]+([Ll][Ee][Dd][Gg][Ee][Rr][[:space:]]+)?[Rr][Oo][Ww][[:space:]]+#?[0123456789]+'"$l"'$'
  [[ $1 =~ $re1 ]] || [[ $1 =~ $re2 ]]
}

# _lg_resolve_into <ref>: resolve into _LG_RES_KIND (item | archived | none
# | ambiguous) and _LG_RES (the path, the anchor, or the paths ", "-joined).
# Call in the main shell. Dies (2) when the index cannot be built.
_lg_resolve_into() {
  local ix out
  ix=$(_lg_index) || exit "$?"
  out=$(jq -r --arg ref "$1" --slurpfile c "$_LG_CFG" "$_LG_JQ_RESOLVE_DEFS"'
    lg_resolve($ref; $c[0])
    | if .r == "ambiguous" then "ambiguous\t" + (.v | join(", "))
      elif .r == "none" then "none\t"
      else "\(.r)\t\(.v)" end' "$ix") || _lg_die "jq failed (resolving '$1')"
  _LG_RES_KIND=${out%%$'\t'*}
  _LG_RES=${out#*$'\t'}
}

# _lg_resolve <ref>: print the item's path (or a legacy row's archived
# anchor); rc 1 when nothing matches, rc 3 when several items do (named on
# stderr).
_lg_resolve() {
  _lg_resolve_into "$1"
  case "$_LG_RES_KIND" in
    item|archived) printf '%s\n' "$_LG_RES" ;;
    none) return 1 ;;
    ambiguous)
      printf "ledger: '%s' matches several items: %s\n" "$1" "$_LG_RES" >&2
      return 3 ;;
    *) _lg_die "internal: resolve kind '$_LG_RES_KIND'" ;;
  esac
}

# --- Configuration and small helpers -----------------------------------------------

# _lg_k_cfg: keys.mode, keys.remote, keys.counter_ref and base into _LG_K_*;
# dies (2) on a value that cannot work.
_lg_k_cfg() {
  local d
  [ -z "$_LG_K_MODE" ] || return 0
  d=$(mktemp "$_SCRATCH/lg-kcfg.XXXXXX") || _lg_die "mktemp failed"
  _lg_cfg '(.keys.mode, .keys.remote, .keys.counter_ref, .base) | if type == "string" then gsub("\n"; " ") else "" end' > "$d"
  { IFS= read -r _LG_K_MODE; IFS= read -r _LG_K_REMOTE; IFS= read -r _LG_K_REF; IFS= read -r _LG_K_BASE; } < "$d" || true
  case "$_LG_K_MODE" in
    cas|merge) ;;
    *) _lg_die "config keys.mode must be \"cas\" or \"merge\" (got '$_LG_K_MODE')" ;;
  esac
  case "$_LG_K_REMOTE" in
    ''|-*) _lg_die "config keys.remote must name a remote (got '$_LG_K_REMOTE')" ;;
  esac
  case "$_LG_K_REF" in
    refs/?*) git check-ref-format "$_LG_K_REF" 2>/dev/null \
      || _lg_die "config keys.counter_ref is not a valid ref name: '$_LG_K_REF'" ;;
    *) _lg_die "config keys.counter_ref must be a ref under refs/ (got '$_LG_K_REF')" ;;
  esac
}

# _lg_k_random: random hex (16 digits from /dev/urandom), with a fresh
# process id — unique among the processes alive now even without urandom
# ($RANDOM and $$ are the same in every subshell of one bash 3.2 process).
_lg_k_random() {
  local r="" p
  r=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || r=""
  p=$(sh -c 'echo $$') || p=0
  printf '%s-%s-%s-%s\n' "${r:-$RANDOM$RANDOM}" "$p" "$(date +%s)" "$$"
}

# _lg_k_jitter: sleep 0.10–0.60 s (from /dev/urandom: subshells share
# $RANDOM's sequence in bash 3.2, and lockstep retries collide again).
_lg_k_jitter() {
  local b
  b=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' \n') || b=""
  case "$b" in ''|*[!0123456789]*) b=$RANDOM ;; esac
  b=$((b % 51 + 10))
  sleep "0.$b"
}

# _lg_k_parse_defs: jq — lg_k_split: a key string → {l, n} (a real key,
# lowercased), else null; lg_k_prov: a provisional key (lowercased) or null.
# shellcheck disable=SC2016  # jq source
_LG_JQ_KEYS_DEFS='
def lg_k_split:
  if type != "string" then null
  else ascii_downcase | if test("^[a-z0-9-]{1,16}-[1-9][0-9]*$") then (capture("^(?<l>.+)-(?<n>[0-9]+)$") | {l, n: (.n | tonumber)}) else null end
  end;
def lg_k_prov:
  if type != "string" then null else ascii_downcase | if test("^[a-z0-9-]{1,16}-~[0-9a-f]{4,8}$") then . else null end end;
'

# _lg_k_maxes <records.jsonl> <out>: {ledger: highest key number} over the
# records' keys and aliases.
_lg_k_maxes() {
  jq -L "$_LG_LIB" -n -c --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS$_LG_JQ_KEYS_DEFS"'
    lg_fields($c[0]) as $F
    | reduce (inputs | (.fm // {}) | ((lg_fv($F; "key") | lg_list[]), (lg_fv($F; "aliases") | lg_list[]))
              | lg_k_split | select(. != null)) as $x
        ({}; .[$x.l] = ([.[$x.l] // 0, $x.n] | max))' "$1" > "$2" \
    || _lg_die "jq failed (the highest keys)"
}

# _lg_k_base_max <out>: _lg_k_maxes over the items at config base.
_lg_k_base_max() {
  local out="$1" d commit=$_LG_K_BASE_C
  case "$_LG_K_BASE" in
    -*|'') _lg_die "cannot seed the key counters: config base is '$_LG_K_BASE'" ;;
  esac
  [ -n "$commit" ] || commit=$(git rev-parse -q --verify "$_LG_K_BASE^{commit}" 2>/dev/null) \
    || _lg_die "cannot seed the key counters: the base '$_LG_K_BASE' (config base) is not a commit here (fetch it first)"
  d=$(mktemp -d "$_SCRATCH/lg-kbase.XXXXXX") || _lg_die "mktemp failed"
  _lg_item_paths "$commit" "$d/paths.z"
  _lg_parse_blobs "$commit" "$d/paths.z" "$d/recs"
  _lg_k_maxes "$d/recs" "$out"
}

# --- The counter ref ------------------------------------------------------------------

# _lg_counter_fetch: fetch the counter ref → _LG_CTR_OID (the commit, "" when
# the remote has no counter ref) and _LG_CTR_FILE (its counters, {} when
# none). rc 0; 1 when the local copy is locked by a concurrent run (retry);
# 4 when the remote cannot be reached (_LG_CTR_ERR says why). Every failure
# is checked explicitly: callers run it on the left of ||.
_lg_counter_fetch() {
  local d err
  d=$(mktemp -d "$_SCRATCH/lg-ctr.XXXXXX") || _lg_die "mktemp failed"
  _LG_CTR_OID=""
  _LG_CTR_FILE="$d/counters.json"
  _LG_CTR_ERR=""
  _lg_k_url "$_LG_K_REMOTE"
  if LC_ALL=C git fetch --quiet --no-tags --no-recurse-submodules "$_LG_KU" \
      "+$_LG_K_REF:$_LG_COUNTERS_REMOTE" < /dev/null > /dev/null 2> "$d/err"; then
    _LG_CTR_OID=$(git rev-parse -q --verify "$_LG_COUNTERS_REMOTE^{commit}" 2>/dev/null) \
      || _lg_die "the counter ref $_LG_K_REF on '$_LG_K_REMOTE' is not a commit"
    git cat-file blob "$_LG_CTR_OID:counters.json" > "$_LG_CTR_FILE" 2>/dev/null \
      || _lg_die "the counter ref $_LG_K_REF ($_LG_CTR_OID) has no counters.json"
    jq -e -s 'length == 1 and (.[0] | type == "object"
        and all(to_entries[]; (.key | test("^[a-z0-9-]{1,16}$")) and (.value | type == "number" and . >= 1 and . == floor)))' \
        "$_LG_CTR_FILE" > /dev/null 2>&1 \
      || _lg_die "the counter ref $_LG_K_REF ($_LG_CTR_OID): counters.json is not {ledger: next number}"
    return 0
  fi
  err=$(cat "$d/err" 2>/dev/null) || err=""
  case "$err" in
    *"couldn't find remote ref"*)
      git update-ref -d "$_LG_COUNTERS_REMOTE" > /dev/null 2>&1 || true
      printf '{}\n' > "$_LG_CTR_FILE" || _lg_die "cannot write $_LG_CTR_FILE"
      return 0 ;;
    *"cannot lock ref"*|*".lock"*) return 1 ;;
  esac
  _LG_CTR_ERR=$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | head -n 2 | tr '\n' ' ')
  return 4
}

# _lg_k_url <remote>: the URL a push to <remote> goes to — its pushurl when
# set, else its url; a name git does not know is taken as a URL — into
# _LG_KU. Only the counter ref's read (_lg_counter_fetch) uses it, so it
# sees the repository the CAS push writes to; the base is fetched from its
# remote's url (_lg_k_fetch_base).
_lg_k_url() {
  _LG_KU=$(git config --get "remote.$1.pushurl" 2>/dev/null) \
    || _LG_KU=$(git config --get "remote.$1.url" 2>/dev/null) || _LG_KU=$1
  [ -n "$_LG_KU" ] || _LG_KU=$1
}

# _lg_k_fetch_base: when config base is a remote-tracking ref
# (refs/remotes/<remote>/<branch> of a configured remote), fetch that branch
# from the remote's url into a private ref ($_LG_BASE_REMOTE — the user's
# refs/remotes/ are never moved) and seed from it, so seeding never reads a
# stale copy; _LG_K_BASE_C is the commit to read ("" = config base as it
# is). rc 0; 1 when the private ref is locked by a concurrent run (retry);
# 4 when the branch cannot be fetched (_LG_CTR_ERR says why).
_lg_k_fetch_base() {
  local full rest rem best="" d url err
  _LG_K_BASE_C=""
  full=$(git rev-parse -q --verify --symbolic-full-name "$_LG_K_BASE" 2>/dev/null) || return 0
  case "$full" in refs/remotes/?*) ;; *) return 0 ;; esac
  rest=${full#refs/remotes/}
  for rem in $(git remote 2>/dev/null); do
    case "$rest" in
      "$rem"/?*) if [ "${#rem}" -gt "${#best}" ]; then best=$rem; fi ;;
    esac
  done
  [ -n "$best" ] || return 0
  url=$(git config --get "remote.$best.url" 2>/dev/null) || url=$best
  d=$(mktemp "$_SCRATCH/lg-kfb.XXXXXX") || _lg_die "mktemp failed"
  if LC_ALL=C git fetch --quiet --no-tags --no-recurse-submodules "$url" \
      "+refs/heads/${rest#"$best"/}:$_LG_BASE_REMOTE" < /dev/null > /dev/null 2> "$d"; then
    _LG_K_BASE_C=$(git rev-parse -q --verify "$_LG_BASE_REMOTE^{commit}" 2>/dev/null) \
      || _lg_die "the fetched base $_LG_BASE_REMOTE is not a commit"
    return 0
  fi
  err=$(cat "$d" 2>/dev/null) || err=""
  case "$err" in
    *"cannot lock ref"*|*".lock"*) return 1 ;;
  esac
  _LG_CTR_ERR="cannot fetch the base $_LG_K_BASE: $(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | head -n 2 | tr '\n' ' ')"
  return 4
}

# _lg_k_read_merged <want-json|""> <out>: the counters (fetched) with seeds
# put in: when a wanted ledger (or, with no want, any) is absent from them,
# every ledger the base has keys for and the counters lack gets its highest
# number + 1 — the highest over the base's keys and aliases and, when the
# caller holds the run's index (_LG_K_IX: init --accept, new), its items'
# too, so a key that sits only in the working tree or on this branch is
# never issued again (final review CORE-I3). rc as _lg_counter_fetch.
_lg_k_read_merged() {
  local want="$1" out="$2" rc=0 need d
  _lg_counter_fetch || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if [ -n "$want" ]; then
    need=$(jq -r --argjson w "$want" '[$w | keys[]] - keys | length' "$_LG_CTR_FILE") \
      || _lg_die "jq failed (counters)"
  else
    need=1
  fi
  if [ "$need" = 0 ]; then
    cp -- "$_LG_CTR_FILE" "$out" || _lg_die "cannot write $out"
    return 0
  fi
  d=$(mktemp "$_SCRATCH/lg-kmax.XXXXXX") || _lg_die "mktemp failed"
  rc=0
  _lg_k_fetch_base || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  _lg_k_base_max "$d"
  : > "$d.noix"
  # shellcheck disable=SC2016  # jq source
  jq -c --slurpfile m "$d" --slurpfile ix "${_LG_K_IX:-$d.noix}" "$_LG_JQ_KEYS_DEFS"'
    . as $c
    | (reduce ((($ix[0] // {}).items // [])[] | (.key, ((.aliases // []) | if type == "array" then .[] else empty end))
               | lg_k_split | select(. != null)) as $x
         ($m[0]; .[$x.l] = ([.[$x.l] // 0, $x.n] | max))) as $M
    | reduce ($M | to_entries[]) as $e ($c; if has($e.key) then . else .[$e.key] = $e.value + 1 end)' \
    "$_LG_CTR_FILE" > "$out" || _lg_die "jq failed (seeding the counters)"
}

# _lg_counter_read: print the counters {ledger: next} — the remote's, with
# every ledger they lack that has keys at the base seeded. Dies (2) when the
# remote cannot be read.
_lg_counter_read() {
  local d rc=0
  _lg_k_cfg
  d=$(mktemp "$_SCRATCH/lg-kread.XXXXXX") || _lg_die "mktemp failed"
  _lg_k_read_merged "" "$d" || rc=$?
  case "$rc" in
    0) cat -- "$d" ;;
    1) _lg_die "cannot update $_LG_COUNTERS_REMOTE: locked by another run" ;;
    *) _lg_die "cannot read the counter ref $_LG_K_REF from '$_LG_K_REMOTE': $_LG_CTR_ERR" ;;
  esac
}

# _lg_k_commit_tree <tree> <parent|""> <message-file>: a commit, with a
# fallback identity when git has none (the counter commits are machinery).
_lg_k_commit_tree() {
  local tree="$1" parent="$2" msg="$3"
  local an="" ae="" cn="" ce=""
  if ! git var GIT_AUTHOR_IDENT > /dev/null 2>&1 || ! git var GIT_COMMITTER_IDENT > /dev/null 2>&1; then
    an="doc-superpowers ledger" ae="ledger@doc-superpowers.invalid"
    cn=$an ce=$ae
  fi
  if [ -n "$parent" ]; then
    GIT_AUTHOR_NAME="${an:-${GIT_AUTHOR_NAME:-}}" GIT_AUTHOR_EMAIL="${ae:-${GIT_AUTHOR_EMAIL:-}}" \
    GIT_COMMITTER_NAME="${cn:-${GIT_COMMITTER_NAME:-}}" GIT_COMMITTER_EMAIL="${ce:-${GIT_COMMITTER_EMAIL:-}}" \
      _lg_k_ct "$tree" -p "$parent" < "$msg"
  else
    GIT_AUTHOR_NAME="${an:-${GIT_AUTHOR_NAME:-}}" GIT_AUTHOR_EMAIL="${ae:-${GIT_AUTHOR_EMAIL:-}}" \
    GIT_COMMITTER_NAME="${cn:-${GIT_COMMITTER_NAME:-}}" GIT_COMMITTER_EMAIL="${ce:-${GIT_COMMITTER_EMAIL:-}}" \
      _lg_k_ct "$tree" < "$msg"
  fi
}

# git commit-tree, with an empty identity variable left unset (an empty
# GIT_AUTHOR_NAME is an error, unset is "use the config").
_lg_k_ct() {
  local v
  for v in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    if [ -z "${!v:-}" ]; then unset "$v"; else export "${v?}"; fi
  done
  git commit-tree "$@"
}

# _lg_counter_cas <expected-oid|""> <new-json> [message]: one commit (tree:
# counters.json = <new-json>; parent: <expected>, none when ""), pushed to
# the counter ref with --force-with-lease=<ref>:<expected>. rc 0 pushed · 1
# lost the race (retry) · 2 refused · 4 transport; _LG_CAS_ERR says why.
# Every failure is checked explicitly (callers run it on the left of ||).
_lg_counter_cas() {
  local expected="$1" json="$2" msg="${3:-ledger: allocate}" d blob tree commit rc=0 line flag summary nonce
  _lg_k_cfg
  _LG_CAS_ERR=""
  d=$(mktemp -d "$_SCRATCH/lg-cas.XXXXXX") || _lg_die "mktemp failed"
  jq -S . <<<"$json" > "$d/counters.json" 2>/dev/null || _lg_die "internal: the new counters are not JSON: $json"
  blob=$(git hash-object -w "$d/counters.json") || _lg_die "git hash-object failed (the counters)"
  tree=$(printf '100644 blob %s\tcounters.json\n' "$blob" | git mktree) || _lg_die "git mktree failed (the counters)"
  nonce=$(_lg_k_random) || exit "$?"
  printf '%s\n\nNonce: %s\n' "$msg" "$nonce" > "$d/msg" || _lg_die "cannot write $d/msg"
  commit=$(_lg_k_commit_tree "$tree" "$expected" "$d/msg") || _lg_die "git commit-tree failed (the counters)"
  LC_ALL=C git push --porcelain --no-verify "--force-with-lease=$_LG_K_REF:$expected" \
    "$_LG_K_REMOTE" "$commit:$_LG_K_REF" < /dev/null > "$d/out" 2> "$d/err" || rc=$?
  # The ref's status line: "<flag>\t<from>:<to>\t<summary>".
  _lg_awkv ":$_LG_K_REF"
  line=$(LC_ALL=C awk -F '\t' -v r="$_LG_AV" '
    NF >= 3 { n = length($2); k = length(r); if (n >= k && substr($2, n - k + 1) == r) { print; exit } }' "$d/out") || line=""
  if [ "$rc" = 128 ] || [ -z "$line" ]; then
    _LG_CAS_ERR="the push to '$_LG_K_REMOTE' failed (exit $rc): $(grep -v '^[[:space:]]*$' "$d/err" 2>/dev/null | head -n 2 | tr '\n' ' ')"
    return 4
  fi
  flag=${line:0:1}
  summary=${line##*$'\t'}
  if [ "$rc" = 0 ]; then
    case "$flag" in
      ' '|'*'|'=')
        git update-ref "$_LG_COUNTERS_REMOTE" "$commit" > /dev/null 2>&1 || true
        _LG_CAS_COMMIT=$commit
        return 0 ;;
    esac
  fi
  if [ "$flag" = '!' ]; then
    case "$summary" in
      *"stale info"*|*"failed to lock"*|*"failed to update ref"*|\
      *"reference already exists"*|*"incorrect old value provided"*|*"reference does not exist"*)
        _LG_CAS_ERR="lost the race for $_LG_K_REF: $summary"
        return 1 ;;
    esac
  fi
  _LG_CAS_ERR="the push of $_LG_K_REF to '$_LG_K_REMOTE' was refused (exit $rc, '$flag' $summary)$(
    grep -v '^[[:space:]]*$' "$d/err" 2>/dev/null | grep -v '^error: failed to push' | head -n 2 | tr '\n' ' ' | sed 's/^/: /')"
  if printf '%s\n' "$summary" | cat - "$d/err" 2>/dev/null | grep -Eq "$_LG_PERM_RE"; then
    _LG_CAS_ERR="permission failure: $_LG_CAS_ERR"
    return 4
  fi
  return 2
}

# --- Allocation ----------------------------------------------------------------------

# _lg_k_prov_lines <paths-file>: "ledger\tprovisional key" per line of
# <paths-file> ("ledger\tpath"), in its order. A provisional key is
# "<ledger>-~<the first 4 hex digits of sha256(path)>", lengthened one
# digit at a time (8 at most) while it is taken — a key or an alias of an
# item in the index (_LG_K_IX when the caller has one, else _lg_index), a
# provisional key docs/ledger/finalized.json records, or a key given
# earlier in this batch, which is numbered in path order (so the keys do not
# depend on the input order). All five lengths taken: dies 2. One hash
# process for the batch (xargs), one jq program.
_LG_K_IX=""
_lg_k_prov_lines() {
  local d ix i=0 l p
  d=$(mktemp -d "$_SCRATCH/lg-kp.XXXXXX") || _lg_die "mktemp failed"
  ix=${_LG_K_IX:-}
  if [ -z "$ix" ]; then ix=$(_lg_index) || exit "$?"; fi
  : > "$d/names"
  while IFS=$'\t' read -r l p; do
    i=$((i + 1))
    printf '%s' "$p" > "$d/$i" || _lg_die "cannot write $d/$i"
    printf '%s\n' "$i" >> "$d/names"
  done < "$1"
  : > "$d/sums"
  if [ "$i" -gt 0 ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      ( cd "$d" && xargs sha256sum < names ) > "$d/sums" || _lg_die "sha256sum failed (provisional keys)"
    else
      ( cd "$d" && xargs shasum -a 256 < names ) > "$d/sums" || _lg_die "shasum failed (provisional keys)"
    fi
  fi
  # shellcheck disable=SC2016  # jq source
  jq -n -r -R --rawfile h "$d/sums" --slurpfile ix "$ix" '
    ($ix[0]) as $X
    | (reduce ([$X.items[] | (.key, (.aliases // [])[])]
               + [($X.finalized // {}) | if type == "object" then keys[] else empty end])[] as $k
         ({}; if ($k | type) == "string" then .[$k | ascii_downcase] = true else . end)) as $T
    | ($h | split("\n") | map(select(. != "") | .[0:64])) as $H
    | [inputs | split("\t") | {l: .[0], p: (.[1:] | join("\t"))}] as $in
    | if ($in | length) != ($H | length) then error("\($H | length) hashes for \($in | length) paths") else . end
    | (reduce ([range(0; $in | length)] | sort_by($in[.].p))[] as $i ({t: $T, k: [], bad: null};
         . as $s | $in[$i] as $x
         | (first(range(4; 9) as $n | "\($x.l)-~\($H[$i][0:$n])" | select($s.t[ascii_downcase] == null)) // null) as $k
         | if $k == null then .bad = (.bad // "\($x.p) (\($x.l)-~\($H[$i][0:4])…\($H[$i][4:8]))")
           else .t[$k | ascii_downcase] = true | .k[$i] = $k end)) as $R
    | if $R.bad != null then "!\t\($R.bad)"
      else range(0; $in | length) | "\($in[.].l)\t\($R.k[.])" end' "$1" > "$d/out" \
    || _lg_die "jq failed (provisional keys)"
  if [ "$(head -c 1 "$d/out")" = "!" ]; then
    _lg_die "cannot give $(head -n 1 "$d/out" | cut -f 2-) a provisional key: every length from 4 to 8 hex digits is taken (by a key, an alias, docs/ledger/finalized.json or this batch)"
  fi
  cat -- "$d/out"
}

# _lg_alloc_batch <json {ledger: count}> [paths-file]: allocate the keys in
# ONE counter commit and print "ledger\tkey" per key — in <paths-file>'s
# order when given ("ledger\tpath" per item, as many per ledger as its
# count: the item each key is for), else by ledger and number. Retries
# (≤ 8, 0.1–0.6 s jitter, re-reading each time) when it loses the race;
# exhausted → dies 2. An unreachable remote → provisional keys (they need
# <paths-file>) with a warning on stderr, rc 0 — unless _LG_ALLOC_STRICT=1
# (dies 2). keys.mode merge → provisional keys, no network.
_lg_alloc_batch() {
  local want="$1" paths="${2:-}" d attempt=0 rc msg json
  _lg_k_cfg
  jq -e 'type == "object" and length > 0
      and all(to_entries[]; (.key | test("^[a-z0-9-]{1,16}$")) and .key != "unassigned"
              and (.value | type == "number" and . >= 1 and . == floor))' <<<"$want" > /dev/null 2>&1 \
    || _lg_die "allocation: expected {ledger: count} (ledger ids ^[a-z0-9-]{1,16}\$, not unassigned; counts ≥ 1), got: $want"
  d=$(mktemp -d "$_SCRATCH/lg-alloc.XXXXXX") || _lg_die "mktemp failed"
  if [ -n "$paths" ]; then
    jq -e -R -n --argjson w "$want" '
      [inputs | split("\t") | .[0]] | group_by(.) | map({key: .[0], value: length}) | from_entries == $w' "$paths" \
      > /dev/null 2>&1 || _lg_die "internal: allocation: the item paths do not match the counts $want"
  fi
  if [ "$_LG_K_MODE" = merge ]; then
    [ -n "$paths" ] || _lg_die "internal: keys.mode merge allocates provisional keys, which need the item paths"
    _lg_k_prov_lines "$paths"
    return 0
  fi
  while :; do
    rc=0
    _lg_k_read_merged "$want" "$d/cur.json" || rc=$?
    if [ "$rc" = 0 ]; then
      jq -n -r --slurpfile cur "$d/cur.json" --argjson want "$want" '
        reduce ($want | to_entries | sort_by(.key))[] as $e ({c: $cur[0], k: [], m: []};
          (.c[$e.key] // 1) as $f
          | .c[$e.key] = $f + $e.value
          | .k += [range($f; $f + $e.value) as $i | "\($e.key)\t\($e.key)-\($i)"]
          | .m += ["\($e.key)-\($f)" + (if $e.value > 1 then "..\($e.key)-\($f + $e.value - 1)" else "" end)])
        | (.c | tojson), ("ledger: allocate " + (.m | join(", "))), .k[]' > "$d/next" \
        || _lg_die "jq failed (the next counters)"
      { IFS= read -r json; IFS= read -r msg; } < "$d/next" || _lg_die "cannot read $d/next"
      tail -n +3 "$d/next" > "$d/keys" || _lg_die "cannot write $d/keys"
      rc=0
      _lg_counter_cas "$_LG_CTR_OID" "$json" "$msg" || rc=$?
      if [ "$rc" = 0 ]; then
        if [ -n "$paths" ]; then
          LC_ALL=C awk -F '\t' -v keys="$d/keys" '
            BEGIN { while ((getline l < keys) > 0) { split(l, f, "\t"); Q[f[1], ++N[f[1]]] = f[2] } }
            { print $1 "\t" Q[$1, ++I[$1]] }' "$paths" || _lg_die "cannot print the keys"
        else
          cat -- "$d/keys"
        fi
        return 0
      fi
      [ "$rc" != 4 ] || _LG_CTR_ERR=$_LG_CAS_ERR
      [ "$rc" = 1 ] || [ "$rc" = 4 ] || _lg_die "could not allocate keys: $_LG_CAS_ERR"
    fi
    if [ "$rc" = 4 ]; then
      if [ "${_LG_ALLOC_STRICT:-}" = 1 ]; then
        _lg_die "cannot reach '$_LG_K_REMOTE' for the counter ref $_LG_K_REF: ${_LG_CTR_ERR:-transport failure}"
      fi
      [ -n "$paths" ] || _lg_die "cannot reach '$_LG_K_REMOTE' for the counter ref (${_LG_CTR_ERR:-transport failure}), and no item paths were given for provisional keys"
      _lg_k_prov_lines "$paths" > "$d/prov" || _lg_die "cannot compute the provisional keys"
      echo "ledger: warning: cannot reach or write to '$_LG_K_REMOTE' (${_LG_CTR_ERR:-transport failure}) — provisional key(s) $(cut -f2 "$d/prov" | tr '\n' ' ')given; run \`doc-tools.sh ledger finalize\` once it is reachable (in keys.mode cas the pre-push hook refuses provisional keys)." >&2
      cat -- "$d/prov"
      return 0
    fi
    attempt=$((attempt + 1))
    _lg_ix_trace "alloc-retry $attempt: ${_LG_CAS_ERR:-the counter ref is locked here}"
    if [ "$attempt" -gt "$_LG_ALLOC_RETRIES" ]; then
      _lg_die "could not allocate keys: the counter ref $_LG_K_REF kept moving — gave up after $_LG_ALLOC_RETRIES retries (no provisional key: the remote is reachable; run it again)"
    fi
    _lg_k_jitter
  done
}

# _lg_alloc <ledger> <count> [path…]: _lg_alloc_batch for one ledger (the
# paths, when given, one per key, are the items the keys are for).
_lg_alloc() {
  local l="$1" n="$2" p f=""
  shift 2
  case "$n" in ''|*[!0123456789]*) _lg_die "internal: _lg_alloc: count '$n'" ;; esac
  if [ $# -gt 0 ]; then
    f=$(mktemp "$_SCRATCH/lg-allocp.XXXXXX") || _lg_die "mktemp failed"
    for p in "$@"; do printf '%s\t%s\n' "$l" "$p"; done > "$f"
  fi
  _lg_alloc_batch "{\"$l\":$n}" "$f"
}

# _lg_k_local_alloc <paths-file> <index>: keys.mode merge's allocation on the
# base: "ledger\tkey" per line of <paths-file>, numbered after the highest
# key (or alias, or finalized key) per ledger in <index>.
_lg_k_local_alloc() {
  jq -n -r -R --slurpfile ix "$2" "$_LG_JQ_KEYS_DEFS"'
    (reduce ($ix[0] | (.items[] | (.key, (.aliases // [])[])), ((.finalized // {}) | if type == "object" then .[] else empty end))
       as $k ({}; ($k | lg_k_split) as $x | if $x == null then . else .[$x.l] = ([.[$x.l] // 0, $x.n] | max) end)) as $M
    | foreach (inputs | split("\t")) as $p ({M: $M};
        .M[$p[0]] = ((.M[$p[0]] // 0) + 1) | .out = "\($p[0])\t\($p[0])-\(.M[$p[0]])"; .out)' "$1" \
    || _lg_die "jq failed (numbering the provisional keys)"
}

# --- Reading and writing an item's key fields ---------------------------------------------

# _lg_k_names <file>: the frontmatter names to write for key, ledger,
# summary and aliases — the first configured candidate the file has, else
# the first candidate — into _LG_KN_KEY, _LG_KN_LEDGER, _LG_KN_SUMMARY,
# _LG_KN_ALIASES.
_lg_k_names() {
  local d
  _lg_parse_prep
  d=$(mktemp "$_SCRATCH/lg-kn.XXXXXX") || _lg_die "mktemp failed"
  LC_ALL=C awk -v path=x "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" < "$1" > "$d.rec" \
    || _lg_die "cannot parse $1"
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS"'
    lg_fields($c[0]) as $F | (.fm // {}) as $fm
    | ("key", "ledger", "summary", "aliases") as $l
    | ($F[$l] // []) as $cs
    | (first($cs[] | select(. as $n | $fm | has($n))) // $cs[0] // $l)' "$d.rec" > "$d" \
    || _lg_die "jq failed (field names of $1)"
  { IFS= read -r _LG_KN_KEY; IFS= read -r _LG_KN_LEDGER; IFS= read -r _LG_KN_SUMMARY; IFS= read -r _LG_KN_ALIASES; } < "$d" \
    || _lg_die "cannot read the field names of $1"
}

# _lg_k_item_info <index> <path>: the item's key and ledger into _LG_KI_KEY,
# _LG_KI_LEDGER ("" when none); _LG_KI_FOUND 1 when <path> is an item.
_lg_k_item_info() {
  local d
  d=$(mktemp "$_SCRATCH/lg-kinfo.XXXXXX") || _lg_die "mktemp failed"
  # Three lines (not one \001-separated line: bash 3.2 mangles \001 in IFS).
  jq -r --arg p "$2" '[.items[] | select(.path == $p)]
      | if length == 0 then "0", "", ""
        else .[0] | "1", (.key // "" | gsub("[\r\n]"; " ")), (.ledger // "" | gsub("[\r\n]"; " ")) end' "$1" > "$d" \
    || _lg_die "jq failed (item $2)"
  { IFS= read -r _LG_KI_FOUND; IFS= read -r _LG_KI_KEY; IFS= read -r _LG_KI_LEDGER; } < "$d" \
    || _lg_die "cannot read the item $2"
}

# _lg_k_check_ledger <id> <allow-unassigned 0|1>: a usage error unless <id>
# is a registered, active ledger (or, allowed, "unassigned").
_lg_k_check_ledger() {
  local id="$1" st reg re
  if [ "$id" = unassigned ]; then
    [ "$2" = 1 ] || _lg_usage "'unassigned' carries no key: give a ledger"
    return 0
  fi
  re='^[abcdefghijklmnopqrstuvwxyz0123456789-]{1,16}$'
  [[ $id =~ $re ]] || _lg_usage "'$id' is not a ledger id (^[a-z0-9-]{1,16}\$)"
  reg=$(_lg_registry) || exit "$?"
  st=$(jq -r --arg id "$id" '[.ledgers[] | select(.id == $id)]
      | if length == 0 then "none" else (.[0].status | if type == "string" then . else "active" end) end' "$reg") \
    || _lg_die "jq failed (registry)"
  case "$st" in
    none) _lg_usage "'$id' is not a ledger (registry: $(jq -r '[.ledgers[] | .id | strings] | join(", ")' "$reg"))" ;;
    retired) _lg_usage "ledger '$id' is retired: it accepts no new items" ;;
  esac
}

# _lg_k_item_path <path>: the path normalized ("./" dropped) into _LG_KP; a
# usage error unless it is an existing file the item globs match.
_lg_k_item_path() {
  local p="$1" d
  while :; do
    case "$p" in ./*) p=${p#./} ;; *) break ;; esac
  done
  [ -f "$p" ] || _lg_usage "no such file: '$1'"
  d=$(mktemp "$_SCRATCH/lg-kip.XXXXXX") || _lg_die "mktemp failed"
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$d.globs"
  printf '%s\0' "$p" > "$d.in"
  _lg_paths_filter "$d.in" "$d.globs" "$d.out"
  [ -s "$d.out" ] || _lg_usage "'$p' is not an item: config items.globs do not match it"
  _LG_KP=$p
}

# _lg_k_new_candidates <index> <with-provisional 0|1> <out>: the staged or
# untracked item files (items.globs) whose key is missing — or, with 1,
# provisional — one per line.
_lg_k_new_candidates() {
  local ix="$1" prov="$2" out="$3" d
  d=$(mktemp -d "$_SCRATCH/lg-kcand.XXXXXX") || _lg_die "mktemp failed"
  git diff --cached --name-only -z --diff-filter=ACMR > "$d/staged.z" 2> "$d/err" \
    || _lg_die "git diff --cached failed: $(head -n 2 "$d/err")"
  git ls-files -o --exclude-standard -z > "$d/untracked.z" 2> "$d/err" \
    || _lg_die "git ls-files -o failed: $(head -n 2 "$d/err")"
  cat "$d/staged.z" "$d/untracked.z" > "$d/all.z" || _lg_die "cannot write $d/all.z"
  _lg_cfg '[(.items.globs // [])[]?] | .[] | strings | select(. != "")' > "$d/globs"
  _lg_paths_filter "$d/all.z" "$d/globs" "$d/items.z"
  tr '\n\000' '\001\n' < "$d/items.z" > "$d/items" || _lg_die "cannot read $d/items.z"
  jq -r -R -n --slurpfile ix "$ix" --arg prov "$prov" "$_LG_JQ_KEYS_DEFS"'
    ([inputs] | unique) as $P
    | $ix[0].items[] | select(.path as $p | $P | index([$p]) != null)
    | select(.key == null or ($prov == "1" and (.key | lg_k_prov) != null)) | .path' "$d/items" > "$out" \
    || _lg_die "jq failed (new item candidates)"
}

# --- Finalize ------------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq source
_LG_JQ_REWRITE='
# The edits that replace the provisional keys of $map[0] ({provisional: key},
# lowercase) in one record, in the logical fields $fields: records
# "set\u0001name\u0001value\u0000" or
# "setlist\u0001name\u0001count\u0001items joined by \u0001\u0000";
# "broken\u0001name\u0000" for a field the parser rejected.
($map[0]) as $M
| def m($v): if ($v | type) == "string" then $M[$v | ascii_downcase] else null end;
  def item:
    if m(.) != null then m(.)
    else (capture("^(?<a>[^:]*:\\s*)(?<b>.*)$") // null) as $x
      | if $x != null and m($x.b) != null then $x.a + m($x.b) else . end
    end;
lg_fields($c[0]) as $F
| (.fm // {}) as $fm | (.fm_errors // []) as $errs
| [ [$fields[] as $l | ($F[$l] // [])[]] | unique[] as $n
| select($fm | has($n))
| $fm[$n] as $v
| if ($v | type) == "string" then
    ($v | item) as $nv
    | if $nv == $v then empty
      elif any($errs[]; startswith($n + ": ")) then "broken\u0001\($n)\u0000"
      else "set\u0001\($n)\u0001\($nv)\u0000" end
  elif ($v | type) == "array" then
    [$v[] | if type == "string" then item else . end] as $nl
    | if $nl == $v then empty
      elif any($errs[]; startswith($n + ": ")) or any($nl[]; type != "string") then "broken\u0001\($n)\u0000"
      else "setlist\u0001\($n)\u0001\($nl | length)\u0001\($nl | join("\u0001"))\u0000" end
  else empty end ]
# A rejected field: only its record (first), so nothing is half-done.
| if any(.[]; startswith("broken\u0001")) then first(.[] | select(startswith("broken\u0001"))) else .[] end
'

_LG_K_FIELDS_ALL='["key","superseded_by","relates","aliases"]'
_LG_K_FIELDS_REFS='["superseded_by","relates","aliases"]'

# _lg_k_rewrite_ops <file> <map-file> <fields-json> <out>: the edits (see
# _LG_JQ_REWRITE) into <out>. A field the parser rejected dies (2) — callers
# run this over every file BEFORE anything is allocated or written.
_lg_k_rewrite_ops() {
  local file="$1" mapf="$2" fields="$3" out="$4"
  _lg_parse_prep
  LC_ALL=C awk -v path=x "${_LG_PARSE_ARGS[@]}" -f "$_LG_LIB/frontmatter.awk" < "$file" > "$out.rec" \
    || _lg_die "cannot parse $file"
  jq -L "$_LG_LIB" -j --slurpfile c "$_LG_CFG" --slurpfile map "$mapf" --argjson fields "$fields" \
    "$_LG_JQ_INDEX_DEFS$_LG_JQ_REWRITE" "$out.rec" > "$out" || _lg_die "jq failed (rewriting $file)"
  if [ "$(head -c 6 "$out")" = broken ]; then
    _lg_die "cannot rewrite $(tr -d '\000' < "$out" | cut -c 8-) in $file: the parser rejects that field (see its frontmatter errors) — nothing was changed"
  fi
}

# _lg_k_rewrite <file> <map-file> <fields-json> [field value]: replace the
# provisional keys of <map-file> in <file>'s <fields> — plus, when given, a
# scalar to set — in ONE fm-write.awk pass.
_lg_k_rewrite() {
  local file="$1" mapf="$2" fields="$3" d rec op rest name count
  d=$(mktemp "$_SCRATCH/lg-krw.XXXXXX") || _lg_die "mktemp failed"
  _lg_k_rewrite_ops "$file" "$mapf" "$fields" "$d"
  _lg_fm_ops_reset
  while IFS= read -r -d '' rec; do
    op=${rec%%$'\001'*}
    rest=${rec#*$'\001'}
    name=${rest%%$'\001'*}
    rest=${rest#*$'\001'}
    case "$op" in
      set) _lg_fm_op set "$name" "$rest" ;;
      setlist)
        count=${rest%%$'\001'*}
        rest=${rest#*$'\001'}
        _lg_fm_op setlist "$name" "" "$rest" "$count" ;;
      *) _lg_die "internal: rewrite op '$op'" ;;
    esac
  done < "$d"
  if [ $# -ge 5 ]; then _lg_fm_op set "$4" "$5"; fi
  [ "$_LG_FMO_N" = 0 ] || _lg_fm_ops_apply "$file"
  _lg_fm_ops_reset
}

# _lg_k_refs_files <index> <map-file> <out>: the item files whose key,
# superseded_by, relates or aliases name a provisional key of <map-file>,
# one per line (a name holding a newline is left out: it cannot be edited).
_lg_k_refs_files() {
  jq -r --slurpfile m "$2" '
    ($m[0]) as $M
    | def hit: type == "string" and ($M[ascii_downcase] != null);
    .items[] | select((.key | hit) or (.superseded_by | hit) or any(.relates[]; .key | hit) or any(.aliases[]; hit))
    | .path | select(test("\n") | not)' "$1" > "$3" || _lg_die "jq failed (references)"
}

# _lg_k_refs_check <files> <keys-file>: every file's edits can be made (no
# rejected field) for the provisional keys listed in <keys-file> (a JSON
# list) — checked before anything is allocated or written.
_lg_k_refs_check() {
  local files="$1" d p
  d=$(mktemp "$_SCRATCH/lg-kchk.XXXXXX") || _lg_die "mktemp failed"
  # A stand-in key for each: any change shows a rejected field.
  jq -c 'map({key: ascii_downcase, value: (. + "-check")}) | from_entries' "$2" > "$d.map" \
    || _lg_die "jq failed (check map)"
  while IFS= read -r p; do
    _lg_k_rewrite_ops "$p" "$d.map" "$_LG_K_FIELDS_ALL" "$d.ops"
  done < "$files"
}

# _lg_k_finalized_add <map-file>: merge {provisional: key} into
# docs/ledger/finalized.json — one entry per line, keys sorted. A provisional
# key already recorded with another key dies (2).
_lg_k_finalized_add() {
  local mapf="$1" f=docs/ledger/finalized.json d
  d=$(mktemp "$_SCRATCH/lg-kfin.XXXXXX") || _lg_die "mktemp failed"
  if [ -f "$f" ]; then
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$f" > /dev/null 2>&1 \
      || _lg_die "$f is not one JSON object"
    cp -- "$f" "$d" || _lg_die "cannot read $f"
  else
    printf '{}\n' > "$d" || _lg_die "cannot write $d"
  fi
  jq -S --slurpfile m "$mapf" '
    . as $o | $m[0] as $n
    | ([$n | to_entries[] | select(($o[.key] // null) != null and $o[.key] != .value) | .key]) as $bad
    | if $bad != [] then error("already finalized differently: \($bad | join(", "))") else . + $n end' "$d" > "$d.new" \
    || _lg_die "cannot record the finalized keys in $f"
  if cmp -s "$d.new" "$f"; then return 0; fi
  _tmp_beside "$f"
  cat -- "$d.new" > "$_TMP" || _lg_die "cannot write $_TMP"
  _replace_file "$_TMP" "$f"
}

# _lg_k_item_carrying <index> <key>: some item's key is <key> (any case).
_lg_k_item_carrying() {
  jq -e --arg k "$2" '($k | ascii_downcase) as $l | any(.items[]; ((.key // "") | ascii_downcase) == $l)' "$1" \
    > /dev/null 2>&1
}

# _lg_k_collisions <index> <finalized-map-file> <out>: one message line per
# item whose key is a provisional key the map records as finalized to a key
# some item carries (see _lg_k_finalize).
_lg_k_collisions() {
  jq -r --slurpfile f0 "$2" "$_LG_JQ_KEYS_DEFS"'
    ($f0[0]) as $F
    | [.items[] | {p: .path, k: ((.key // "") | ascii_downcase)}] as $I
    | $I[] | . as $x | ($x.k | lg_k_prov) as $pk
    | select($pk != null and ($F[$pk] | type) == "string")
    | ($F[$pk] | ascii_downcase) as $real
    | [$I[] | select(.k == $real) | .p] | select(length > 0)
    | "the provisional key \($pk) on \($x.p) was already finalized as \($F[$pk]) (docs/ledger/finalized.json), which \(join(", ")) carries: it now names a different item (a reused path, or two paths whose hex digits collide on two branches) — give \($x.p) a new key with: ledger assign \($x.p) <ledger>"' \
    "$1" > "$3" || _lg_die "jq failed (finalized collisions)"
}

# _lg_k_merge_on_base <rc>: keys.mode merge gives real keys only on the base:
# HEAD must be config base's commit, else exit <rc> (3: the finalize verb's
# usage error; 2: new --finalize could not run).
_lg_k_merge_on_base() {
  local base_c msg
  base_c=$(git rev-parse -q --verify "$_LG_K_BASE^{commit}" 2>/dev/null) \
    || _lg_die "keys.mode merge: the base '$_LG_K_BASE' (config base) is not a commit here"
  [ "$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)" != "$base_c" ] || return 0
  msg="keys.mode merge: real keys are given on the base — check out $_LG_K_BASE and run ledger finalize there (HEAD is not $base_c)"
  if [ "$1" = 3 ]; then _lg_usage "$msg"; fi
  _lg_die "$msg"
}

# _lg_k_merge_remote_check: keys.mode merge numbers keys after the highest
# one in this base, so two maintainers finalizing different copies of the
# base would give one number to two items, in different files git merges
# without a conflict (final review CORE-m2). Before finalize writes, fetch
# the base's branch from its remote — config base's remote and branch for a
# remote-tracking ref, a local branch's upstream (else keys.remote's branch
# of the same name) — into a private ref; HEAD must contain its tip, else
# exit 2 (pull, then run finalize again). The remote has no such branch, or
# config base is a commit or tag: nothing to compare. Unreachable, or
# DOC_TOOLS_LEDGER_OFFLINE=1: a warning, and finalize goes on as before.
_lg_k_merge_remote_check() {
  local full rest rem="" best="" br="" mref url err d tip
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    echo "ledger: warning: offline (DOC_TOOLS_LEDGER_OFFLINE=1): finalize did not check the remote's base for another maintainer's finalize — pull before you push this one" >&2
    return 0
  fi
  full=$(git rev-parse -q --verify --symbolic-full-name "$_LG_K_BASE" 2>/dev/null) || full=""
  case "$full" in
    refs/remotes/?*)
      rest=${full#refs/remotes/}
      for rem in $(git remote 2>/dev/null); do
        case "$rest" in
          "$rem"/?*) if [ "${#rem}" -gt "${#best}" ]; then best=$rem; fi ;;
        esac
      done
      [ -n "$best" ] || return 0
      rem=$best
      br=${rest#"$best"/} ;;
    refs/heads/?*)
      br=${full#refs/heads/}
      rem=$(git config --get "branch.$br.remote" 2>/dev/null) || rem=""
      mref=$(git config --get "branch.$br.merge" 2>/dev/null) || mref=""
      case "$rem:$mref" in
        ?*:refs/heads/?*) br=${mref#refs/heads/} ;;
        *) rem=$_LG_K_REMOTE ;;
      esac
      case "$rem" in .|'') return 0 ;; esac ;;
    *) return 0 ;;
  esac
  url=$(git config --get "remote.$rem.url" 2>/dev/null) || url=$rem
  d=$(mktemp "$_SCRATCH/lg-kmrc.XXXXXX") || _lg_die "mktemp failed"
  if ! LC_ALL=C git fetch --quiet --no-tags --no-recurse-submodules "$url" \
      "+refs/heads/$br:$_LG_BASE_REMOTE" < /dev/null > /dev/null 2> "$d"; then
    err=$(grep -v '^[[:space:]]*$' "$d" 2>/dev/null | head -n 2 | tr '\n' ' ') || err=""
    case "$err" in
      *"couldn't find remote ref"*) return 0 ;;
    esac
    echo "ledger: warning: cannot fetch $br from '$rem' (${err:-the fetch failed}): finalize did not check the remote's base for another maintainer's finalize — pull before you push this one" >&2
    return 0
  fi
  tip=$(git rev-parse -q --verify "$_LG_BASE_REMOTE^{commit}" 2>/dev/null) || _lg_die "the fetched base $_LG_BASE_REMOTE is not a commit"
  git merge-base --is-ancestor "$tip" HEAD 2>/dev/null \
    || _lg_die "keys.mode merge: $br on '$rem' has commits this base lacks (another maintainer's finalize, or merges): pull them, then run finalize again — finalizing two copies of the base would give one number to two items. Nothing was written."
}

# _lg_k_finalize <only-path|""> <all 0|1> <out-lines> <out-json> [off-base-rc]
# [summary-field summary]: replace provisional keys — <only-path>'s; else
# (cas) those this branch added (provisional keys the base's items do not
# carry) or, <all> 1, every one; (merge) every one, committed on the base
# (with <only-path>: no commit). Writes "prov → key  path" lines and the
# JSON payload. Call in the main shell.
#
# Crash-safe and resumable, in this order: every file's edits are checked
# (a rejected field dies before anything is allocated or written); a
# provisional key already in finalized.json keeps that key (an interrupted
# run completes; nothing is allocated twice); the rest are allocated;
# finalized.json is written FIRST, then each item's own key, then the
# references (relates / superseded_by / aliases) — including any left
# behind by an interrupted run for a key finalized.json already records.
# Every intermediate state resolves: an old provisional key reaches its key
# through finalized.json.
_lg_k_finalize() {
  local only="$1" all="$2" outl="$3" outj="$4" offrc="${5:-3}" ix d base_c="" n m p commit=null touched commit_it=0
  local files=()
  _lg_k_cfg
  d=$(mktemp -d "$_SCRATCH/lg-kfz.XXXXXX") || _lg_die "mktemp failed"
  if [ "$_LG_K_MODE" = merge ]; then
    _lg_k_merge_on_base "$offrc"
    all=1
    [ -n "$only" ] || commit_it=1
  fi
  ix=$(_lg_index) || exit "$?"
  # The base's provisional keys (cas, not --all): not this branch's.
  printf '[]\n' > "$d/basep.json"
  if [ -z "$only" ] && [ "$all" != 1 ]; then
    if base_c=$(git rev-parse -q --verify "$_LG_K_BASE^{commit}" 2>/dev/null); then
      _lg_item_paths "$base_c" "$d/bpaths.z"
      _lg_parse_blobs "$base_c" "$d/bpaths.z" "$d/brecs"
      jq -L "$_LG_LIB" -n -c --slurpfile c "$_LG_CFG" "$_LG_JQ_INDEX_DEFS$_LG_JQ_KEYS_DEFS"'
        lg_fields($c[0]) as $F | [inputs | (.fm // {}) | lg_fv($F; "key") | lg_k_prov | select(. != null)] | unique' \
        "$d/brecs" > "$d/basep.json" || _lg_die "jq failed (the base's provisional keys)"
    fi
  fi
  # finalized.json so far (lowercase provisional keys).
  jq -c '(.finalized // {}) | if type == "object" then with_entries(.key |= ascii_downcase) else {} end' "$ix" \
    > "$d/f0.json" || _lg_die "jq failed (finalized map)"
  # "prov\tledger\tpath\t<key from finalized.json or "">" for each item to
  # finalize; a provisional key on several items cannot be finalized (which
  # one would keep it?).
  jq -r --slurpfile bp "$d/basep.json" --slurpfile f0 "$d/f0.json" --arg only "$only" "$_LG_JQ_KEYS_DEFS"'
    [.items[] | {p: .path, k: (.key | lg_k_prov)} | select(.k != null)
     | select(if $only != "" then .p == $only else (.k as $k | $bp[0] | index([$k]) == null) end)] as $S
    | ($S | group_by(.k) | map(select(length > 1))) as $dup
    | if $dup != [] then "dup\t\($dup[0][0].k)\t\($dup[0] | map(.p) | join(", "))"
      else $S | sort_by(.p)[] | "\(.k)\t\(.k | split("-~")[0])\t\(.p)\t\($f0[0][.k] // "")" end' "$ix" > "$d/todo" \
    || _lg_die "jq failed (provisional keys)"
  if [ -n "$only" ]; then
    # Every item holding <only>'s key — a duplicate elsewhere too.
    jq -r --arg only "$only" "$_LG_JQ_KEYS_DEFS"'
      (first(.items[] | select(.path == $only) | .key | lg_k_prov) // null) as $k
      | if $k == null then empty else [.items[] | select((.key | lg_k_prov) == $k) | .path] | select(length > 1)
        | "dup\t\($k)\t\(join(", "))" end' "$ix" >> "$d/todo" || _lg_die "jq failed (provisional keys)"
  fi
  if grep -q '^dup	' "$d/todo"; then
    _lg_die "provisional key $(grep '^dup	' "$d/todo" | head -n 1 | cut -f2) is on several items ($(grep '^dup	' "$d/todo" | head -n 1 | cut -f3)): give each its own key first (ledger assign)"
  fi
  # A provisional key finalized.json records whose key another item carries:
  # the provisional key now names a different item (its path was reused, or
  # two paths' hex digits collide on two branches). Reusing the record would
  # give a second item that key, and redirecting references would point them
  # at the old item: refuse, before anything is allocated or written. (A
  # genuine resume — a run cut short after recording — leaves no item with
  # the key.)
  _lg_k_collisions "$ix" "$d/f0.json" "$d/coll"
  if [ -s "$d/coll" ]; then
    _lg_die "$(head -n 1 "$d/coll")"
  fi
  n=$(grep -c . "$d/todo" || true)
  # The provisional keys whose references go: this run's and every one
  # finalized.json records. Check every file they touch before anything else.
  jq -R -n -c --slurpfile f0 "$d/f0.json" '([inputs | split("\t") | .[0]] + ($f0[0] | keys)) | unique' "$d/todo" \
    > "$d/planned.json" || _lg_die "jq failed (planned keys)"
  jq -c 'map({key: ., value: .}) | from_entries' "$d/planned.json" > "$d/plan.map" || _lg_die "jq failed (plan)"
  _lg_k_refs_files "$ix" "$d/plan.map" "$d/touch"
  if [ "$n" = 0 ] && [ ! -s "$d/touch" ]; then
    : > "$outl"
    printf '{"finalized":[],"commit":null}\n' > "$outj"
    return 0
  fi
  _lg_k_refs_check "$d/touch" "$d/planned.json"
  while IFS= read -r p; do files+=("$p"); done < "$d/touch"
  files+=(docs/ledger/finalized.json)
  if [ "$commit_it" = 1 ]; then
    touched=$(GIT_LITERAL_PATHSPECS=1 git status --porcelain -- "${files[@]}" 2>&1) || touched="(git status failed) $touched"
    [ -z "$touched" ] || _lg_die "keys.mode merge: commit or stash the changes to the files finalize rewrites first: $(printf '%s' "$touched" | tr '\n' ' ')"
  fi
  if [ "$_LG_K_MODE" = merge ]; then _lg_k_merge_remote_check; fi
  # The keys: finalized.json's, else allocated (in "ledger\tpath" order).
  LC_ALL=C awk -F '\t' '$4 == "" { print $2 "\t" $3 }' "$d/todo" > "$d/paths" || _lg_die "cannot write $d/paths"
  : > "$d/keys"
  if [ -s "$d/paths" ]; then
    if [ "$_LG_K_MODE" = merge ]; then
      _lg_k_local_alloc "$d/paths" "$ix" > "$d/keys"
    else
      jq -R -n -c '[inputs | split("\t") | .[0]] | group_by(.) | map({key: .[0], value: length}) | from_entries' \
        "$d/paths" > "$d/want" || _lg_die "jq failed (counts)"
      _LG_ALLOC_STRICT=1 _lg_alloc_batch "$(cat "$d/want")" "$d/paths" > "$d/keys" || exit "$?"
    fi
  fi
  # pairs: prov, ledger, path, key.
  LC_ALL=C awk -F '\t' -v keys="$d/keys" '
    { if ($4 == "") { if ((getline k < keys) <= 0) exit 3; split(k, f, "\t"); $4 = f[2] }
      print $1 "\t" $2 "\t" $3 "\t" $4 }' OFS='\t' "$d/todo" > "$d/pairs" || _lg_die "cannot pair the keys"
  jq -R -n -c '[inputs | split("\t") | {key: .[0], value: .[3]}] | from_entries' "$d/pairs" > "$d/map.json" \
    || _lg_die "jq failed (the key map)"
  # 1. finalized.json.
  m=$(jq -r 'length' "$d/map.json") || _lg_die "jq failed (map)"
  if [ "$m" != 0 ]; then _lg_k_finalized_add "$d/map.json"; fi
  # 2. each item's own key (with <only>'s summary, when given, in the same pass).
  while IFS=$'\t' read -r _ _ p _; do
    if [ "$p" = "$only" ] && [ $# -ge 7 ]; then
      _lg_k_rewrite "$p" "$d/map.json" '["key"]' "$6" "$7"
    else
      _lg_k_rewrite "$p" "$d/map.json" '["key"]'
    fi
  done < "$d/pairs"
  # 3. the references, to this run's keys and to every key finalized.json records.
  jq -c -s '.[0] + .[1]' "$d/f0.json" "$d/map.json" > "$d/all.map" || _lg_die "jq failed (map)"
  while IFS= read -r p; do
    _lg_k_rewrite "$p" "$d/all.map" "$_LG_K_FIELDS_REFS"
  done < "$d/touch"
  if [ "$commit_it" = 1 ]; then
    GIT_LITERAL_PATHSPECS=1 git add -- "${files[@]}" > "$d/commit.out" 2>&1 \
      || _lg_die "git add failed: $(head -n 3 "$d/commit.out")"
    if [ "$n" = 0 ]; then m="ledger: rewrite references to finalized keys"; else m="ledger: finalize $n keys"; fi
    GIT_LITERAL_PATHSPECS=1 git commit -q -m "$m" -- "${files[@]}" > "$d/commit.out" 2>&1 \
      || _lg_die "git commit failed: $(head -n 3 "$d/commit.out")"
    commit="\"$(git rev-parse HEAD)\""
  fi
  LC_ALL=C awk -F '\t' '{ print $1 " → " $4 "  " $3 }' "$d/pairs" > "$outl" || _lg_die "cannot write $outl"
  if [ "$n" = 0 ]; then
    printf 'references to finalized keys rewritten in %s file(s)\n' "$(grep -c . "$d/touch")" >> "$outl"
  fi
  jq -R -n -c --argjson commit "$commit" \
    '{finalized: [inputs | split("\t") | {provisional: .[0], key: .[3], path: .[2]}], commit: $commit}' \
    "$d/pairs" > "$outj" || _lg_die "jq failed (finalize payload)"
}

# --- Verbs -----------------------------------------------------------------------------------

# _lg_k_summary_check <summary>: one line, 1–140 characters, else usage.
_lg_k_summary_check() {
  local n
  case "$1" in
    *[![:space:]]*) ;;
    *) _lg_usage "--summary is empty" ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) _lg_usage "--summary must be one line" ;;
  esac
  n=$(jq -nr --arg s "$1" '$s | length') || _lg_die "jq failed (summary)"
  [ "$n" -le 140 ] || _lg_usage "--summary is $n characters: at most 140"
}

# _lg_k_emit_lines <lines-file> <payload-json-file>: the run's output.
_lg_k_emit_lines() {
  if [ "$_LG_FORMAT" = json ]; then _lg_emit "$_LG_VERB" 0 "$2"; fi
  _lg_out_file "$1"
  _lg_emit "$_LG_VERB" 0
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_new() {
  local L S F fin ix s cands n out key prov=false
  _lg_init new
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}' (the item is --file <path>)"
  L=$_OPT_ledger
  S=$_OPT_summary
  F=$_OPT_file
  fin=$_OPT_finalize
  _lg_k_cfg
  if _opt_seen summary; then _lg_k_summary_check "$S"; fi
  if [ -n "$L" ]; then _lg_k_check_ledger "$L" 1; fi
  s=$(mktemp -d "$_SCRATCH/lg-new.XXXXXX") || _lg_die "mktemp failed"
  ix=$(_lg_index) || exit "$?"
  _LG_K_IX=$ix
  if [ -n "$F" ]; then
    _lg_k_item_path "$F"
    F=$_LG_KP
  else
    _lg_k_new_candidates "$ix" "$([ -n "$fin" ] && echo 1 || echo 0)" "$s/cands"
    n=$(grep -c . "$s/cands" || true)
    cands=$(tr '\n' ' ' < "$s/cands")
    case "$n" in
      0) _lg_usage "no staged or untracked item file without a key: give --file <path>" ;;
      1) IFS= read -r F < "$s/cands" ;;
      *) _lg_usage "$n staged or untracked item files have no key ($cands): give --file <path>" ;;
    esac
  fi
  _lg_k_item_info "$ix" "$F"
  _lg_k_names "$F"
  if [ -n "$_LG_KI_KEY" ]; then
    case "$_LG_KI_KEY" in
      *-~*)
        [ -n "$fin" ] || _lg_usage "$F already has the provisional key $_LG_KI_KEY: --finalize replaces it"
        if [ -n "$L" ] && [ "$L" != "${_LG_KI_KEY%%-~*}" ]; then
          _lg_usage "$F's provisional key $_LG_KI_KEY is in ledger '${_LG_KI_KEY%%-~*}', not '$L' (ledger assign moves it)"
        fi
        # The summary, when given, goes into the same pass as the key.
        if [ -n "$S" ]; then
          _lg_k_finalize "$F" 0 "$s/lines" "$s/fin.json" 2 "$_LG_KN_SUMMARY" "$S"
        else
          _lg_k_finalize "$F" 0 "$s/lines" "$s/fin.json" 2
        fi
        jq -c --arg p "$F" '{path: $p, key: (.finalized[0].key // null), provisional: false, finalized: .finalized}' \
          "$s/fin.json" > "$s/payload" || _lg_die "jq failed (payload)"
        _lg_k_emit_lines "$s/lines" "$s/payload" ;;
      *) _lg_usage "$F already has the key $_LG_KI_KEY (ledger assign moves an item to another ledger)" ;;
    esac
  fi
  [ -n "$L" ] || _lg_usage "give --ledger <id> (or unassigned)"
  _opt_seen summary || _lg_usage "give --summary \"<why it matters, ≤ 140 characters>\""
  if [ "$L" = unassigned ]; then
    _lg_fm_ops_reset
    _lg_fm_op set "$_LG_KN_LEDGER" "$L"
    _lg_fm_op set "$_LG_KN_SUMMARY" "$S"
    _lg_fm_ops_apply "$F"
    printf 'unassigned  %s\n' "$F" > "$s/lines"
    jq -nc --arg p "$F" '{path: $p, ledger: "unassigned", key: null, provisional: false}' > "$s/payload" \
      || _lg_die "jq failed (payload)"
    _lg_k_emit_lines "$s/lines" "$s/payload"
  fi
  if [ -n "$fin" ] && [ "$_LG_K_MODE" = merge ]; then
    # keys.mode merge: a real key only on the base, numbered there.
    _lg_k_merge_on_base 2
    printf '%s\t%s\n' "$L" "$F" > "$s/paths"
    out=$(_lg_k_local_alloc "$s/paths" "$ix") || exit "$?"
  elif [ -n "$fin" ]; then
    out=$(_LG_ALLOC_STRICT=1 _lg_alloc "$L" 1 "$F") || exit "$?"
  else
    out=$(_lg_alloc "$L" 1 "$F") || exit "$?"
  fi
  key=${out#*$'\t'}
  case "$key" in *-~*) prov=true ;; esac
  # One pass: key, ledger and summary land together.
  _lg_fm_ops_reset
  _lg_fm_op set "$_LG_KN_KEY" "$key"
  _lg_fm_op set "$_LG_KN_LEDGER" "$L"
  _lg_fm_op set "$_LG_KN_SUMMARY" "$S"
  _lg_fm_ops_apply "$F"
  printf '%s  %s\n' "$key" "$F" > "$s/lines"
  jq -nc --arg p "$F" --arg l "$L" --arg k "$key" --argjson prov "$prov" \
    '{path: $p, ledger: $l, key: $k, provisional: $prov}' > "$s/payload" || _lg_die "jq failed (payload)"
  _lg_k_emit_lines "$s/lines" "$s/payload"
}

# shellcheck disable=SC2154  # _ARGS is set by _parse_args
cmd_ledger_assign() {
  local ref L ix s out key old oldl p rec_key coll prov=false
  _lg_init assign
  [ "${#_ARGS[@]}" = 2 ] || _lg_usage "give an item and a ledger: ledger assign <item> <ledger>"
  ref=${_ARGS[0]}
  L=${_ARGS[1]}
  [ -n "$ref" ] || _lg_usage "the item is empty"
  _lg_k_cfg
  _lg_k_check_ledger "$L" 0
  s=$(mktemp -d "$_SCRATCH/lg-assign.XXXXXX") || _lg_die "mktemp failed"
  _lg_resolve_into "$ref"
  case "$_LG_RES_KIND" in
    item) ;;
    none)
      if [ "$_LG_FORMAT" = json ]; then
        jq -nc --arg r "$ref" '{item: null, ref: $r}' > "$s/payload" || _lg_die "jq failed (payload)"
        _lg_emit assign 1 "$s/payload"
      fi
      printf "no item matches '%s'\n" "$ref" | tr -d '\000-\010\013-\037' | head -n 1 > "$s/msg"
      _lg_out_file "$s/msg"
      _lg_emit assign 1 ;;
    ambiguous) _lg_usage "'$ref' matches several items: $_LG_RES" ;;
    archived) _lg_usage "'$ref' is an archived legacy row ($_LG_RES): there is no item to assign" ;;
    *) _lg_die "internal: resolve kind '$_LG_RES_KIND'" ;;
  esac
  [ -f "$_LG_RES" ] || _lg_not_file_die "$_LG_RES" assign
  ix=$(_lg_index) || exit "$?"
  _lg_k_item_info "$ix" "$_LG_RES"
  [ "$_LG_KI_FOUND" = 1 ] || _lg_usage "'$ref' leads to $_LG_RES, which is not an item (config items.globs)"
  old=$_LG_KI_KEY
  case "$old" in
    *-~*) oldl=${old%-~*} ;;
    *) oldl=${old%-*} ;;
  esac
  # finalized.json already recording a provisional old key — checked before
  # a number is allocated. Its key carried by another item: the provisional
  # key names a different item now (a reused path or a 4-hex collision), so
  # the item gets a new key and nothing else changes (the record and the
  # references stay with the old item). Its key carried by no item: a
  # finalize was cut short — finalize completes it (same ledger), else
  # refuse.
  rec_key=""
  coll=0
  case "$old" in
    *-~*)
      rec_key=$(jq -r --arg o "$old" '(.finalized // {}) | if type == "object" then (.[$o | ascii_downcase] // "") else "" end
          | if type == "string" then . else "" end' "$ix") || _lg_die "jq failed (finalized)"
      if [ -n "$rec_key" ] && _lg_k_item_carrying "$ix" "$rec_key"; then coll=1; fi
      ;;
  esac
  if [ -n "$old" ] && [ "$oldl" = "$L" ] && [ "$coll" = 0 ]; then
    case "$old" in
      *-~*)
        # Already in the ledger with a provisional key: finalize it.
        _lg_k_finalize "$_LG_RES" 0 "$s/lines" "$s/fin.json" 2
        jq -c --arg p "$_LG_RES" --arg l "$L" --arg o "$old" \
          '{path: $p, ledger: $l, key: (.finalized[0].key // null), previous: $o, provisional: false}' \
          "$s/fin.json" > "$s/payload" || _lg_die "jq failed (payload)"
        ;;
      *)
        printf '%s  %s  (already in %s)\n' "$old" "$_LG_RES" "$L" > "$s/lines"
        jq -nc --arg p "$_LG_RES" --arg l "$L" --arg k "$old" \
          '{path: $p, ledger: $l, key: $k, previous: null, provisional: false}' > "$s/payload" \
          || _lg_die "jq failed (payload)"
        ;;
    esac
    _lg_k_emit_lines "$s/lines" "$s/payload"
  fi
  if [ -n "$rec_key" ] && [ "$coll" = 0 ]; then
    _lg_die "$old was already finalized as $rec_key (docs/ledger/finalized.json) but no item carries $rec_key: a finalize was cut short — run ledger finalize first, then assign"
  fi
  [ "$coll" = 1 ] || rec_key=""
  _lg_k_names "$_LG_RES"
  case "$old:$rec_key" in
    *-~*:)
      # A provisional key is never kept as an alias: its references are
      # rewritten to the new key (checked first: a rejected field dies
      # before anything is allocated).
      jq -nc --arg o "$old" '{($o | ascii_downcase): ($o | ascii_downcase)}' > "$s/plan.map" \
        || _lg_die "jq failed (plan)"
      _lg_k_refs_files "$ix" "$s/plan.map" "$s/touch"
      jq -nc --arg o "$old" '[$o | ascii_downcase]' > "$s/planned.json" || _lg_die "jq failed (plan)"
      _lg_k_refs_check "$s/touch" "$s/planned.json"
      ;;
  esac
  out=$(_lg_alloc "$L" 1 "$_LG_RES") || exit "$?"
  key=${out#*$'\t'}
  case "$key" in *-~*) prov=true ;; esac
  case "$old:$rec_key" in
    *-~*:?*)
      echo "ledger: warning: $old was already finalized as $rec_key for another item — $_LG_RES gets $key; references to $old stay with $rec_key" >&2
      _lg_fm_ops_reset
      _lg_fm_op set "$_LG_KN_KEY" "$key"
      _lg_fm_op set "$_LG_KN_LEDGER" "$L"
      _lg_fm_ops_apply "$_LG_RES"
      ;;
    *-~*:)
      jq -nc --arg o "$old" --arg k "$key" '{($o | ascii_downcase): $k}' > "$s/map.json" || _lg_die "jq failed (map)"
      # finalized.json first (only a real key finalizes), then the item, then
      # the references.
      if [ "$prov" = false ]; then _lg_k_finalized_add "$s/map.json"; fi
      _lg_fm_ops_reset
      _lg_fm_op set "$_LG_KN_KEY" "$key"
      _lg_fm_op set "$_LG_KN_LEDGER" "$L"
      _lg_fm_ops_apply "$_LG_RES"
      while IFS= read -r p; do
        _lg_k_rewrite "$p" "$s/map.json" "$_LG_K_FIELDS_REFS"
      done < "$s/touch"
      ;;
    *)
      # One pass: key, ledger and the old key appended to aliases.
      _lg_fm_ops_reset
      _lg_fm_op set "$_LG_KN_KEY" "$key"
      _lg_fm_op set "$_LG_KN_LEDGER" "$L"
      if [ -n "$old" ]; then _lg_fm_op_list_add "$_LG_RES" "$_LG_KN_ALIASES" "$old"; fi
      _lg_fm_ops_apply "$_LG_RES"
      ;;
  esac
  if [ -n "$old" ]; then
    printf '%s  %s  (was %s)\n' "$key" "$_LG_RES" "$old" > "$s/lines"
  else
    printf '%s  %s\n' "$key" "$_LG_RES" > "$s/lines"
  fi
  jq -nc --arg p "$_LG_RES" --arg l "$L" --arg k "$key" --arg o "$old" --argjson prov "$prov" \
    '{path: $p, ledger: $l, key: $k, previous: (if $o == "" then null else $o end), provisional: $prov}' \
    > "$s/payload" || _lg_die "jq failed (payload)"
  _lg_k_emit_lines "$s/lines" "$s/payload"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_finalize() {
  local s all=0
  _lg_init finalize
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  if [ -n "$_OPT_all" ]; then all=1; fi
  s=$(mktemp -d "$_SCRATCH/lg-fin.XXXXXX") || _lg_die "mktemp failed"
  _lg_k_finalize "" "$all" "$s/lines" "$s/payload"
  if [ ! -s "$s/lines" ]; then printf 'no provisional keys to finalize\n' > "$s/lines"; fi
  if jq -e '.commit != null' "$s/payload" > /dev/null 2>&1; then
    jq -r '"committed \(.commit[0:12]): ledger: finalize \(.finalized | length) keys"' "$s/payload" >> "$s/lines" \
      || _lg_die "jq failed (payload)"
  fi
  _lg_k_emit_lines "$s/lines" "$s/payload"
}

# --- Push range -------------------------------------------------------------------------------

# _lg_provisional_in_range <a>..<b>: "key\twhere\tpath" for each provisional
# key the range adds — the item keys at <b> (of the item files the range
# changes) that no changed item had at <a>, nor at git merge-base <b>
# <base> (an existing branch that merged the base after a provisional key
# landed there is not refused for it: 3.3.1). <a> empty or all zeros (a new
# branch): the keys <b> adds since config base (from git merge-base <b>
# <base>, so a provisional key already on the base never blocks a new
# branch: final review CORE-I4); with no base here (it does not resolve, or
# shares no history with <b>), every provisional key at <b> (a new branch)
# or that the range adds (an existing one). <where>:
# "base" for a key the base's copy of that file also carries, "nobase" for
# every key when config base does not resolve here, else "" (a base that
# resolves but shares no history with <b> is still compared file by file,
# so its keys are "base") — `ledger finalize` replaces only the keys the
# base lacks; `--all` the others too.
_lg_provisional_in_range() {
  local range="$1" a b ac="" bc d basec="" where="" k w p mb
  case "$range" in
    *..*) a=${range%%..*}; b=${range#*..} ;;
    *) _lg_die "internal: _lg_provisional_in_range takes <a>..<b> (got '$range')" ;;
  esac
  [ -n "$b" ] || b=HEAD
  case "$b" in -*) _lg_die "not a revision: '$b'" ;; esac
  bc=$(git rev-parse -q --verify "$b^{commit}" 2>/dev/null) || _lg_die "unknown revision: '$b'"
  case "$a" in
    ''|*[!0]*) ;;
    *) a="" ;;
  esac
  _lg_k_cfg
  case "$_LG_K_BASE" in
    ''|-*) ;;
    *) basec=$(git rev-parse -q --verify "$_LG_K_BASE^{commit}" 2>/dev/null) || basec="" ;;
  esac
  if [ -n "$a" ]; then
    case "$a" in -*) _lg_die "not a revision: '$a'" ;; esac
    ac=$(git rev-parse -q --verify "$a^{commit}" 2>/dev/null) || _lg_die "unknown revision: '$a'"
  elif [ -n "$basec" ]; then
    ac=$(git merge-base "$bc" "$basec" 2>/dev/null) || ac=""
  fi
  [ -n "$ac" ] || [ -n "$basec" ] || where=nobase
  d=$(mktemp -d "$_SCRATCH/lg-kpr.XXXXXX") || _lg_die "mktemp failed"
  if [ -n "$ac" ]; then
    git diff --name-only -z --no-renames "$ac" "$bc" -- > "$d/changed.z" 2> "$d/err" \
      || _lg_die "git diff failed: $(head -n 2 "$d/err")"
    _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$d/globs"
    _lg_paths_filter "$d/changed.z" "$d/globs" "$d/paths.z"
  else
    _lg_item_paths "$bc" "$d/paths.z"
  fi
  [ -s "$d/paths.z" ] || return 0
  _lg_parse_blobs "$bc" "$d/paths.z" "$d/b.recs"
  : > "$d/a.recs"
  if [ -n "$ac" ]; then _lg_parse_blobs "$ac" "$d/paths.z" "$d/a.recs"; fi
  # An existing branch (<a> given): a key the branch got from the base —
  # one its merge-base with config base already carries — is not this
  # push's either (3.3.1: a branch that merges the base after a provisional
  # key lands there; CORE-I4 covered new branches). Only the keys the branch
  # adds since that merge-base are checked.
  if [ -n "$a" ] && [ -n "$basec" ]; then
    mb=$(git merge-base "$bc" "$basec" 2>/dev/null) || mb=""
    if [ -n "$mb" ] && [ "$mb" != "$ac" ]; then
      _lg_parse_blobs "$mb" "$d/paths.z" "$d/m.recs"
      cat "$d/m.recs" >> "$d/a.recs" || _lg_die "cannot write $d/a.recs"
    fi
  fi
  jq -L "$_LG_LIB" -n -r --slurpfile c "$_LG_CFG" --slurpfile a "$d/a.recs" "$_LG_JQ_INDEX_DEFS$_LG_JQ_KEYS_DEFS"'
    lg_fields($c[0]) as $F
    | [$a[] | (.fm // {}) | lg_fv($F; "key") | lg_k_prov | select(. != null)] as $old
    | inputs | . as $r | ((.fm // {}) | lg_fv($F; "key") | lg_k_prov) as $k
    | select($k != null and ($old | index([$k]) == null))
    | "\($k)\t\($r.path)"' "$d/b.recs" > "$d/found" || _lg_die "jq failed (provisional keys in $range)"
  # Which of them the base carries too: one blob read per refused key (a
  # refused push is rare; an accepted one reads none).
  while IFS=$'\t' read -r k p; do
    w=$where
    if [ -z "$w" ] && [ -n "$basec" ] \
        && git cat-file -p "$basec:$p" 2>/dev/null | LC_ALL=C grep -qiF -- "$k"; then
      w=base
    fi
    printf '%s\t%s\t%s\n' "$k" "$w" "$p"
  done < "$d/found"
}

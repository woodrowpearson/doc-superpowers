# shellcheck shell=bash
# scripts/ledger/adapters.sh — the ledger's adapters (design §G): executables
# named in config "adapters" that read a host's systems for the ledger, and
# the remote cache (_lg_remote_cache, below) that keeps what they read from
# the network for cache.remote_ttl_minutes.
# Sourced by lib.sh; uses lib.sh's _lg_cfg, _LG_ROOT and parse.sh's
# _lg_scratch_name; doc-tools.sh's SCRIPT_DIR (the scripts/ directory of the
# running copy — the plugin's, or a vendored copy's).
#
# _lg_adapter <name> <args…>: run adapters.<name> with <args>, from the top
# level, stdin closed. The value is
#   - an absolute path,
#   - a path relative to the top level of the work tree, or
#   - "doc-superpowers:<adapter>" → $SCRIPT_DIR/adapters/<adapter>.sh, the
#     adapter shipped beside this copy of doc-tools.sh (<adapter>:
#     [a-z0-9_-]+, nothing that leaves the directory).
# Absent (null, "" or no such key) → rc 0, no output. A value that is not a
# string, a file that is missing or not executable, a non-zero exit, or
# output that breaks the adapter's contract → rc 2, with one message on
# stderr that carries the adapter's own stderr (its first lines). Otherwise
# the output, one JSON object per line, compact, on stdout (rc 0).
#
# The contract a list output is checked against (_LG_ADAPTER_REQ: every line
# one JSON object holding these fields):
#   contracts list   "id" a contract id (<kind>:<name>), "ledger" a string
#                    or null, "defined_in" a list of strings; "title", when
#                    present, a string or null
#   pr list          "number", "head", "state", "url"; optional "cross"
#                    (true: the head is a fork's branch — never resolved
#                    through a same-named branch of keys.remote; absent:
#                    false) and "head_oid" (the head's commit: a merged PR
#                    is walked from it when this clone has it, never from
#                    its branch; absent: a merged PR adds nothing beyond
#                    the base's own claims). The reference adapter,
#                    scripts/adapters/ledger-pr-gh.sh, adds "merge_commit";
#                    state open | merged | closed
# Other subcommands (contracts resolve <id>: exit 0/1) are not checked: the
# caller reads the exit status (_lg_adapter_rc).

# _lg_adapter_path <name>: the executable adapters.<name> names into
# _LG_ADP ("" when the config names none); rc 2 with a message in
# _LG_ADP_ERR when the value cannot be one.
_lg_adapter_path() {
  local name="$1" v
  _LG_ADP=""
  _LG_ADP_ERR=""
  v=$(_lg_cfg ".adapters[\"$name\"] // null | if . == null then \"\" elif type == \"string\" then \"s\" + . else \"!\" + tojson end")
  case "$v" in
    '') return 0 ;;
    s) return 0 ;;
    '!'*) _LG_ADP_ERR="config adapters.$name is not a path: ${v#!}"; return 2 ;;
  esac
  v=${v#s}
  case "$v" in
    doc-superpowers:*)
      local a=${v#doc-superpowers:}
      case "$a" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
          _LG_ADP_ERR="config adapters.$name: '$v' does not name a doc-superpowers adapter ([a-z0-9_-]+)"
          return 2 ;;
      esac
      _LG_ADP="$SCRIPT_DIR/adapters/$a.sh" ;;
    /*) _LG_ADP=$v ;;
    *) _LG_ADP="$_LG_ROOT/$v" ;;
  esac
  if [ ! -f "$_LG_ADP" ]; then
    _LG_ADP_ERR="adapter $name: no such file: $_LG_ADP (config adapters.$name '$v')"
    return 2
  fi
  if [ ! -x "$_LG_ADP" ]; then
    _LG_ADP_ERR="adapter $name: not executable: $_LG_ADP"
    return 2
  fi
  return 0
}

# The required fields of a list output, per adapter (jq: true when the line
# — an object — keeps the contract).
# shellcheck disable=SC2016  # jq source
_LG_ADAPTER_REQ_contracts='(.id | type == "string" and test("\\A[a-z][a-z0-9_-]*:[^[:space:]]+\\z"))
  and has("ledger") and (.ledger == null or (.ledger | type) == "string")
  and (.defined_in | type == "array" and all(.[]; type == "string"))
  and ((has("title") | not) or .title == null or (.title | type) == "string")'
# shellcheck disable=SC2016  # jq source
_LG_ADAPTER_REQ_pr='has("number") and has("head") and has("state") and has("url")'

_lg_adapter() {
  local name="$1" s rc=0 req=""
  shift
  _lg_adapter_path "$name" || { printf '%s\n' "$_LG_ADP_ERR" >&2; return 2; }
  [ -n "$_LG_ADP" ] || return 0
  _lg_scratch_name
  s=$_LG_SN
  ( cd "$_LG_ROOT" && "$_LG_ADP" "$@" ) < /dev/null > "$s.aout" 2> "$s.aerr" || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'adapter %s (%s %s) exited %s: %s\n' "$name" "$_LG_ADP" "$*" "$rc" \
      "$(head -n 5 "$s.aerr" | tr '\n' ' ' | tr -d '\000-\010\013-\037')" >&2
    return 2
  fi
  if [ "${1:-}" = list ]; then
    case "$name" in
      contracts) req=$_LG_ADAPTER_REQ_contracts ;;
      pr) req=$_LG_ADAPTER_REQ_pr ;;
    esac
  fi
  [ -n "$req" ] || { cat -- "$s.aout"; return 0; }
  # Each line on its own (fromjson per raw line), so the message names the
  # first line that breaks the contract; empty lines are skipped.
  if ! jq -R -r "
      (input_line_number) as \$n
      | if test(\"^\\\\s*\$\") then empty
        else (try fromjson catch null) as \$o
          | if (\$o | type) == \"object\" and (\$o | $req) then \$o | tojson
            else error(\"line \\(\$n): \\(.[0:200])\") end
        end" "$s.aout" > "$s.aok" 2> "$s.ajq"; then
    printf 'adapter %s (%s %s): output breaks the %s contract — %s%s\n' "$name" "$_LG_ADP" "$*" "$name" \
      "$(sed -n 's/^jq: error ([^)]*): //p; s/^jq: error: //p' "$s.ajq" | head -n 1 | tr -d '\000-\010\013-\037')" \
      "$(if [ -s "$s.aerr" ]; then printf ' (stderr: %s)' "$(head -n 3 "$s.aerr" | tr '\n' ' ' | tr -d '\000-\010\013-\037')"; fi)" >&2
    return 2
  fi
  cat -- "$s.aok"
}

# _lg_adapter_rc <name> <args…>: run the adapter for its exit status (0/1
# answers, e.g. contracts resolve <id>); absent → 1; any other status, or an
# adapter that cannot run → 2 with the message on stderr.
_lg_adapter_rc() {
  local name="$1" rc=0
  shift
  _lg_adapter_path "$name" || { printf '%s\n' "$_LG_ADP_ERR" >&2; return 2; }
  [ -n "$_LG_ADP" ] || return 1
  ( cd "$_LG_ROOT" && "$_LG_ADP" "$@" ) < /dev/null > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
  esac
  printf 'adapter %s (%s %s) exited %s\n' "$name" "$_LG_ADP" "$*" "$rc" >&2
  return 2
}

# --- The remote cache --------------------------------------------------------------
#
# _lg_remote_cache <name> <key-material> <producer…>: data read from a
# remote system (the PR adapter's list), cached for cache.remote_ttl_minutes
# (default 10; 0: never served from the cache; capped at 1,000,000) so that
# no verb reaches the network more than once per TTL. Results in globals
# (callers run it in the shell that reads them):
#   _LG_RCACHE  the cache file ("" when there is none to read)
#   _LG_RSNAP   a private snapshot of it, taken once: line 1 the header,
#               then the data — callers read the data, the fetch time and
#               the data hash from this one copy, never from the live file
#               (a concurrent refresh may replace it meanwhile)
#   _LG_RDSHA   the snapshot's data hash (the header's data_sha256)
#   _LG_RSTATE  fresh — read within the TTL, or just written;
#               stale — the producer failed (now, or within the last TTL:
#                 a failure is not retried before the TTL is out — no
#                 retry storm against a remote that is down) and the last
#                 good copy is served;
#               offline — DOC_TOOLS_LEDGER_OFFLINE=1 kept the producer
#                 from running: the copy past its TTL is served (rc 0), or
#                 there is none (rc 2);
#               none — it failed and there is no copy (rc 2)
#   _LG_RAGE    seconds since the copy was fetched ("" with none)
#   _LG_RFETCHED its fetch time (epoch seconds; "" with none)
#   _LG_RERR    the failure's first stderr line, or "offline:
#               DOC_TOOLS_LEDGER_OFFLINE=1" when forced offline ("" else)
# The file is $_LG_CACHE/remote/<name>-<the first 16 hex of the sha256 of
# <key-material>>.json: line 1 {"schema":"ledger-remote/1","fetched_at":
# <epoch s>,"data_sha256":"<hex>","name":"<name>"}, then the producer's
# stdout as it printed it. A fetch time in the future (clock skew) counts
# as expired. It is written to a temp file in the same directory and moved
# into place, so a reader sees a whole file and of two concurrent refreshes
# the last to finish wins; a write sweeps temp files older than 10 minutes
# (a writer that died). A failure is remembered in <file>.fail
# ({"failed_at", "error"}; removed by the next success).
# _LG_REMOTE_FORCE=1 (--refresh, publish): the producer runs whatever the
# age, and its failure — or DOC_TOOLS_LEDGER_OFFLINE=1 — is rc 2 even when
# a copy exists. DOC_TOOLS_LEDGER_OFFLINE=1: the producer never runs and no
# failure is recorded (hooks that must not reach the network). The
# producer runs with stdin closed; non-zero is a failure (its output is
# discarded). DOC_TOOLS_LEDGER_SELFTEST=remote-swap (scripts/test-ledger.sh
# only): right after the snapshot, the live file is replaced by
# $DOC_TOOLS_LEDGER_SELFTEST_SWAP — a concurrent writer.
_LG_REMOTE_FORCE=""
_LG_RTTL=""
_LG_RTTL_JQ='.cache.remote_ttl_minutes | if type == "number" and . >= 0 then ([., 1000000] | min) * 60 | floor else 600 end'
_lg_remote_cache() {
  local name="$1" km="$2" s dir f tmp ttl now h t d rc=0 failed_at="" ferr="" fl
  shift 2
  _LG_RCACHE=""
  _LG_RSNAP=""
  _LG_RDSHA=""
  _LG_RSTATE=none
  _LG_RAGE=""
  _LG_RFETCHED=""
  _LG_RERR=""
  _lg_scratch_name
  s=$_LG_SN
  printf '%s' "$km" > "$s.km" || _lg_die "cannot write $s.km"
  _hash_one "$s.km"
  # shellcheck disable=SC2153  # _LG_CACHE: lib.sh's _lg_init
  dir="$_LG_CACHE/remote"
  d=${_HASH#sha256:}
  f="$dir/$name-${d:0:16}.json"
  # The TTL in seconds: _LG_RTTL when the caller read it already (one jq
  # less on every warm run), else from the config.
  ttl=${_LG_RTTL:-}
  [ -n "$ttl" ] || ttl=$(_lg_cfg "$_LG_RTTL_JQ")
  case "$ttl" in ''|*[!0123456789]*) ttl=600 ;; esac
  now=$(date +%s) || _lg_die "date failed"
  # The copy, snapshotted once: its header's fetch time and data hash (a
  # file that does not start with the header, or that vanished, is no copy).
  t=""
  if [ -f "$f" ] && cp -- "$f" "$s.snap" 2>/dev/null; then
    case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
      remote-swap) cp -- "$DOC_TOOLS_LEDGER_SELFTEST_SWAP" "$f" ;;
    esac
    h=""
    IFS= read -r h < "$s.snap" || true
    case "$h" in
      '{"schema":"ledger-remote/1","fetched_at":'*'"data_sha256":"'*)
        t=${h#*\"fetched_at\":}
        t=${t%%,*}
        case "$t" in ''|*[!0123456789]*) t="" ;; esac
        d=${h#*\"data_sha256\":\"}
        d=${d%%\"*} ;;
    esac
  fi
  if [ -n "$t" ] && [ "${_LG_REMOTE_FORCE:-}" != 1 ] && [ "$t" -le "$now" ] && [ $((now - t)) -lt "$ttl" ]; then
    _LG_RCACHE=$f
    _LG_RSNAP="$s.snap"
    _LG_RDSHA=$d
    _LG_RSTATE=fresh
    _LG_RFETCHED=$t
    _LG_RAGE=$((now - t))
    return 0
  fi
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    _LG_RSTATE=offline
    _LG_RERR="offline: DOC_TOOLS_LEDGER_OFFLINE=1"
    if [ "${_LG_REMOTE_FORCE:-}" = 1 ] || [ -z "$t" ]; then return 2; fi
    _LG_RCACHE=$f
    _LG_RSNAP="$s.snap"
    _LG_RDSHA=$d
    _LG_RFETCHED=$t
    _LG_RAGE=$((now - t))
    if [ "$_LG_RAGE" -lt 0 ]; then _LG_RAGE=0; fi
    return 0
  fi
  # A failure younger than the TTL is not retried (unless forced).
  if [ "${_LG_REMOTE_FORCE:-}" != 1 ] && [ -f "$f.fail" ]; then
    fl=""
    IFS= read -r fl < "$f.fail" || true
    failed_at=$(printf '%s' "$fl" | jq -r '.failed_at | if type == "number" then floor else "" end' 2>/dev/null) || failed_at=""
    case "$failed_at" in ''|*[!0123456789]*) failed_at="" ;; esac
    if [ -n "$failed_at" ] && [ "$failed_at" -le "$now" ] && [ $((now - failed_at)) -lt "$ttl" ]; then
      ferr=$(printf '%s' "$fl" | jq -r '.error // "" | tostring' 2>/dev/null) || ferr=""
      rc=1
    fi
  fi
  if [ "$rc" = 0 ]; then
    "$@" < /dev/null > "$s.rout" 2> "$s.rerr" || rc=$?
    if [ "$rc" = 0 ]; then
      mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
      find "$dir" -maxdepth 1 -type f -name '.*' -mmin +10 -exec rm -f {} + 2>/dev/null || true
      _hash_one "$s.rout"
      d=${_HASH#sha256:}
      { printf '{"schema":"ledger-remote/1","fetched_at":%s,"data_sha256":"%s","name":"%s"}\n' "$now" "$d" "$name" \
          && cat -- "$s.rout"; } > "$s.snap" || _lg_die "cannot write $s.snap"
      tmp=$(mktemp "$dir/.$name.XXXXXX") || _lg_die "cannot create a temp file in $dir"
      if ! cp -- "$s.snap" "$tmp" || ! mv -f -- "$tmp" "$f"; then
        rm -f -- "$tmp"
        _lg_die "cannot write $f"
      fi
      rm -f -- "$f.fail"
      _LG_RCACHE=$f
      _LG_RSNAP="$s.snap"
      _LG_RDSHA=$d
      _LG_RSTATE=fresh
      _LG_RFETCHED=$now
      _LG_RAGE=0
      return 0
    fi
    ferr=$(head -n 1 "$s.rerr" | tr -d '\000-\010\013-\037')
    [ -n "$ferr" ] || ferr="exited $rc"
    mkdir -p -- "$dir" 2>/dev/null || _lg_die "cannot create $dir"
    tmp=$(mktemp "$dir/.$name.XXXXXX") || _lg_die "cannot create a temp file in $dir"
    if jq -nc --argjson t "$now" --arg e "$ferr" '{failed_at: $t, error: $e}' > "$tmp" 2>/dev/null; then
      mv -f -- "$tmp" "$f.fail" || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  fi
  _LG_RERR=$ferr
  if [ "${_LG_REMOTE_FORCE:-}" = 1 ] || [ -z "$t" ]; then
    return 2
  fi
  _LG_RCACHE=$f
  _LG_RSNAP="$s.snap"
  _LG_RDSHA=$d
  _LG_RSTATE=stale
  _LG_RFETCHED=$t
  _LG_RAGE=$((now - t))
  if [ "$_LG_RAGE" -lt 0 ]; then _LG_RAGE=0; fi
  return 0
}

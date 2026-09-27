#!/usr/bin/env bash
set -euo pipefail

# doc-tools.sh — bundled doc freshness tracking for doc-superpowers
# Usage: doc-tools.sh <subcommand> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Dependency checks ---

# jq >= 1.6: the index writers pass keys with `--args` / `$ARGS.positional`,
# which jq 1.5 does not have (it would fail deep inside a writer with a jq usage
# error). Accepts the version strings jq has printed: "jq-1.6", "jq-1.7.1",
# "jq-1.7.1-apple", "jq-1.5-1-a5b5cbe" (Debian), "jq version 1.3". A string
# with no parsable version (a dev build such as "jq-master-…") is not blocked.
_jq_version_ok() {
  local v="$1" major minor
  v="${v#jq-}"
  v="${v#jq version }"
  case "$v" in
    [0-9]*.[0-9]*) ;;
    *) return 0 ;;
  esac
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%[!0-9]*}"
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "${minor:-0}" -ge 6 ]; }
}

check_deps() {
  local missing=0
  for cmd in git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $cmd" >&2
      missing=1
    fi
  done
  if command -v jq >/dev/null 2>&1; then
    local jq_version
    jq_version=$(jq --version 2>/dev/null || true)
    if ! _jq_version_ok "$jq_version"; then
      echo "ERROR: jq >= 1.6 required (found: ${jq_version:-unknown}). Upgrade jq: brew upgrade jq / apt install jq." >&2
      missing=1
    fi
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "ERROR: required command not found: sha256sum or shasum" >&2
    missing=1
  fi
  [ "$missing" -eq 0 ]
}

# --- Utility functions ---

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Resolve a GNU-compatible sed binary.
# macOS Homebrew ships GNU sed as `gsed`; on Linux/CI it's just `sed`.
# BSD sed (macOS default `sed`) differs on `-i` syntax + extended regex flags,
# so we require GNU sed. Exits with a clear error if neither is available.
gnu_sed() {
  if command -v gsed >/dev/null 2>&1; then
    printf '%s' gsed
  elif sed --version 2>/dev/null | grep -q 'GNU sed'; then
    printf '%s' sed
  else
    echo "ERROR: GNU sed required (install via 'brew install gnu-sed' on macOS, or use the system sed on Linux)" >&2
    exit 2
  fi
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

repo_head() {
  git rev-parse HEAD 2>/dev/null || echo "unknown"
}

# --- Doc-path normalization ---
#
# Every path this tool touches is interpreted relative to the working directory:
# the index itself is read from the relative `docs/.doc-index.json`, `-f` tests
# and git pathspecs resolve against $PWD, and the installed hooks all `cd` to the
# git root before invoking us. The doc-index is therefore keyed by working-tree-
# relative paths, and every lookup (`update-index`, `check-freshness`, the
# coverage gate, the merge driver) assumes that form.
#
# An absolute key is consequently invisible to every other subcommand — it can be
# written, but never found. These helpers reject or rewrite such a path at the
# boundary instead of letting it reach the index.

# True if the path contains a `.` or `..` *segment* (not merely a dot in a
# filename — `docs/v1.2/x.md` has none). Sentinel slashes make leading/trailing
# segments match the same pattern as interior ones.
_has_dot_segment() {
  case "/$1/" in
    */./*|*/../*) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve a path to its physical (symlink-free) absolute form WITHOUT requiring
# the leaf to exist — `add-entry` deliberately supports docs that are not yet on
# disk (it stores a null content_hash for them). Walks up to the longest existing
# ancestor directory, resolves that with `cd`+`pwd -P`, then re-appends the
# remaining components. `cd` also collapses any `.`/`..` segments for us.
#
# Physical resolution is required, not cosmetic: on macOS `mktemp -d` hands back
# /var/... which is a symlink to /private/var/..., so a purely lexical prefix
# comparison against $PWD would wrongly report an in-tree path as outside.
_physical_path() {
  local p="$1" suffix="" parent
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  while [ ! -d "$p" ]; do
    parent=$(dirname "$p")
    # Guard against a non-terminating walk if dirname ever stops shrinking.
    [ "$parent" = "$p" ] && return 1
    suffix="/$(basename "$p")$suffix"
    p="$parent"
  done
  p=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  printf '%s%s' "$p" "$suffix"
}

# Normalize a doc path to the working-tree-relative form used as the index key.
# Prints the normalized path on stdout; on failure prints an error to stderr and
# returns 1 so callers can refuse to write.
#
# An ordinary relative path — the documented input, and the form that already
# works — is passed through byte-identically and never touches the filesystem.
normalize_doc_path() {
  local raw="$1"
  local ctx="${2:-doc path}"

  if [ -z "$raw" ]; then
    echo "ERROR: empty $ctx." >&2
    return 1
  fi

  case "$raw" in
    /*) ;;
    *)
      # Fast path: already in key form.
      _has_dot_segment "$raw" || { printf '%s' "$raw"; return 0; }
      ;;
  esac

  local base abs rel
  base=$(pwd -P)

  if ! abs=$(_physical_path "$raw"); then
    echo "ERROR: cannot resolve $ctx '$raw'." >&2
    return 1
  fi

  if [ "$abs" = "$base" ]; then
    echo "ERROR: $ctx '$raw' resolves to the working directory itself, not a document." >&2
    return 1
  fi

  case "$abs" in
    "$base"/*)
      rel="${abs#"$base"/}"
      ;;
    *)
      echo "ERROR: $ctx '$raw' is outside the working directory ($base)." >&2
      echo "       doc-index keys must be relative to the repo root; run doc-tools.sh from the repo root." >&2
      return 1
      ;;
  esac

  printf '%s' "$rel"
}

# Computes freshness for a single doc entry.
# Args: doc_path entry_json
# Outputs JSON with: status, doc_modified, commits_behind, and if stale: reason, code_refs_changed
compute_freshness() {
  local doc_path="$1"
  local entry="$2"

  local current_hash stored_hash doc_modified
  current_hash="sha256:$(hash_file "$doc_path")"
  stored_hash=$(echo "$entry" | jq -r '.content_hash')
  [ "$current_hash" != "$stored_hash" ] && doc_modified=true || doc_modified=false

  local code_refs_arr=()
  while IFS= read -r _ref; do
    [[ -n "$_ref" ]] && code_refs_arr+=("$_ref")
  done < <(echo "$entry" | jq -r '.code_refs[]' 2>/dev/null || true)

  local current_code_commit=""
  if [ ${#code_refs_arr[@]} -gt 0 ]; then
    current_code_commit=$(git log -1 --format=%H -- "${code_refs_arr[@]}" 2>/dev/null || true)
  fi

  local stored_code_commit
  stored_code_commit=$(echo "$entry" | jq -r '.code_commit // empty')

  local status reason
  if [ -n "$current_code_commit" ] && [ "$current_code_commit" != "$stored_code_commit" ]; then
    status="stale"
    reason="code_changed"
  else
    status="current"
    reason=""
  fi

  local commits_behind=0
  if [ -n "$stored_code_commit" ] && [ ${#code_refs_arr[@]} -gt 0 ]; then
    commits_behind=$(git rev-list --count "${stored_code_commit}..HEAD" -- "${code_refs_arr[@]}" 2>/dev/null || echo 0)
  fi

  local code_refs_changed_json="[]"
  if [ "$status" = "stale" ] && [ -n "$stored_code_commit" ]; then
    local changed_refs=()
    for ref in "${code_refs_arr[@]}"; do
      local ref_commit
      ref_commit=$(git log -1 --format=%H -- "$ref" 2>/dev/null || true)
      if [ -n "$ref_commit" ] && [ "$ref_commit" != "$stored_code_commit" ]; then
        changed_refs+=("$ref")
      fi
    done
    code_refs_changed_json=$(printf '%s\n' "${changed_refs[@]+"${changed_refs[@]}"}" | jq -R . | jq -s .)
  fi

  if [ -n "$reason" ]; then
    jq -n \
      --arg status "$status" \
      --arg reason "$reason" \
      --argjson doc_modified "$doc_modified" \
      --argjson commits_behind "$commits_behind" \
      --argjson code_refs_changed "$code_refs_changed_json" \
      '{status: $status, reason: $reason, doc_modified: $doc_modified, commits_behind: $commits_behind, code_refs_changed: $code_refs_changed}'
  else
    jq -n \
      --arg status "$status" \
      --argjson doc_modified "$doc_modified" \
      --argjson commits_behind "$commits_behind" \
      '{status: $status, doc_modified: $doc_modified, commits_behind: $commits_behind}'
  fi
}

# Hash many files in ONE process — hash_file per doc was a fork+exec (two, with
# the awk) per file. Prints "sha256:<hex>" per file, in argument order. If the
# batch output does not line up one-to-one (an unreadable file drops its line),
# falls back to hash_file per file so a hash can never land on the wrong doc.
_hash_files() {
  [ $# -gt 0 ] || return 0
  local out="" line hashes=() h
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum -- "$@" 2>/dev/null) || out=""
  else
    out=$(shasum -a 256 -- "$@" 2>/dev/null) || out=""
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    h="${line%% *}"
    # GNU/shasum prefix the line with "\" when the filename needed escaping.
    hashes+=("${h#\\}")
  done <<< "$out"
  if [ "${#hashes[@]}" -eq $# ]; then
    for h in "${hashes[@]}"; do
      printf 'sha256:%s\n' "$h"
    done
  else
    local f
    for f in "$@"; do
      printf 'sha256:%s\n' "$(hash_file "$f")"
    done
  fi
}

# --- Index persistence ---------------------------------------------------------
#
# docs/.doc-index.json is shared, long-lived state. The skill's `update` action
# dispatches one agent per stale doc and each calls update-index, so writers
# run CONCURRENTLY, and any of them can be interrupted (Ctrl-C, a CI job
# cancel, an agent's Bash timeout). Every write therefore goes through one path:
#
#   _index_apply <jq-program> [jq args…]
#     _index_lock     mkdir spin-lock docs/.doc-index.json.lock (flock(1) is not
#                     on macOS); the owner pid is recorded, a dead owner's lock
#                     is broken, a live one is waited on then reported
#     _index_load     a private snapshot, shape-validated: exactly one JSON
#                     object whose .docs is an object (a 0-byte file is NOT an
#                     empty index)
#     one jq pass     <program> maps the old index to the new one
#     _index_install  tmp file BESIDE the target (same filesystem, so mv is an
#                     atomic rename — a tmp in $TMPDIR would make mv degrade to
#                     copy-then-unlink) → chmod to the prior mode (644 when
#                     new) → mv. The only place the index file is replaced.
#
# A run that changes nothing writes nothing (no generated_at bump), and
# _INDEX_CHANGED lists the docs keys whose entries actually changed, so writers
# report what they did rather than what they were asked. Writers build a
# per-key patch list (JSONL) first and apply it in that one pass: O(N + k), not
# a whole-index re-parse per path. Signals terminate (_traps): an interrupted
# writer leaves the previous index byte-identical, never a partial one.

INDEX_FILE="docs/.doc-index.json"
INDEX_LOCK="$INDEX_FILE.lock"
_SCRATCH=""          # private scratch dir (snapshots, patches); removed on exit
_INDEX_TMP=""        # in-flight tmp beside the index; removed on exit
_INDEX_LOCK_HELD=0
_INDEX_BREAKING=0
_INDEX_NOW=""        # one timestamp per run: last_verified and generated_at agree
_INDEX_CHANGED=()
_INDEX_CHANGED_SET=$'\n'   # the same keys, newline-framed, for O(1)-call lookups
_INDEX_WROTE=0

# Shared patch interpreter for _index_apply. Each $patch row is one of
#   {"key": k, "add":   {...}}   insert the entry unless k is already indexed
#   {"key": k, "merge": {...}}   merge fields into an existing entry (else skip)
#   {"key": k, "del":   true}    delete the entry (absent: no-op)
# `+=` keeps existing field positions and appends new fields, so a merge
# serializes exactly as the old field-by-field assignments did.
# shellcheck disable=SC2016  # jq program, not shell expansion
_INDEX_PATCH='reduce $patch[] as $x (.;
  if ($x | has("del")) then del(.docs[$x.key])
  elif ($x | has("add")) then (if (.docs | has($x.key)) then . else .docs[$x.key] = $x.add end)
  elif ($x | has("merge")) then (if (.docs | has($x.key)) then .docs[$x.key] += $x.merge else . end)
  else error("doc-tools: unknown index patch row: \($x | tojson)") end)'

_die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Record streams from bash to jq. Each field is written as "<n>\n" followed by
# the value's n lines (n = its newline count + 1, so "" is one empty line), and
# read back by the jq def rec_fields. Line-framed on purpose: up to jq 1.6 raw
# input (-R) is read with fgets/strlen, so a NUL-delimited stream could be
# truncated there, while newline-terminated lines are safe on every supported
# jq. Any bash string round-trips (bash strings cannot hold NUL).
_rec_put() {
  local v nl
  for v in "$@"; do
    nl="${v//[!$'\n']/}"
    printf '%s\n%s\n' "$(( ${#nl} + 1 ))" "$v"
  done
}
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_REC_FIELDS='def rec_fields:
  reduce inputs as $line ({out: [], want: null, buf: []};
    if .want == null then .want = ($line | tonumber) | .buf = []
    else .buf += [$line]
      | if (.buf | length) == .want
        then .out += [.buf | join("\n")] | .want = null
        else . end
    end)
  | .out;'


# EXIT handler: remove whatever this run left in flight. Never calls exit, so
# the status of the `exit` that got us here (130/143 from a signal) stands.
cleanup() {
  if [ -n "$_INDEX_TMP" ]; then rm -f "$_INDEX_TMP"; fi
  _index_unlock
  if [ "$_INDEX_BREAKING" = 1 ]; then rmdir "$INDEX_LOCK.break" 2>/dev/null || true; fi
  # A lock renamed aside for deletion (see _index_unlock / _index_break_stale)
  # whose rm was cut short. Named by our pid, so it is ours to remove.
  if [ -e "$INDEX_LOCK.gone.$$" ]; then rm -rf "$INDEX_LOCK.gone.$$"; fi
  if [ -n "$_SCRATCH" ]; then rm -rf "$_SCRATCH"; fi
  return 0
}

# INT/TERM END the run; EXIT cleans up. The previous traps cleaned up and then
# RESUMED: a TERM'd build-index ran on and installed a truncated index with
# rc 0, and one blocked on stdin treated the interrupted read as EOF and
# installed an EMPTY one. Never RETURN: it fires on every function return.
_traps() {
  trap 'cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Critical sections that must not be split between an external command
# succeeding and the shell recording that it did. bash runs a trap only once
# the foreground child exits, so a TERM during a successful `mkdir` of the lock
# would otherwise exit before _INDEX_LOCK_HELD=1 — and cleanup, seeing the lock
# as not ours, would leave it behind with no owner pid, wedging every later
# writer. Inside a deferred section a signal is only recorded; _signals_restore
# puts the terminating traps back and THEN exits with the recorded status.
_INDEX_SIG=""
_signals_defer() {
  _INDEX_SIG=""
  trap '_INDEX_SIG=130' INT
  trap '_INDEX_SIG=143' TERM
}
_signals_restore() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "$_INDEX_SIG" ]; then exit "$_INDEX_SIG"; fi
}

# Create this run's scratch dir. Call in the main shell (never inside $(…)):
# the path must outlive the call so cleanup can remove it.
_scratch_init() {
  [ -z "$_SCRATCH" ] || return 0
  _SCRATCH=$(mktemp -d -t doc-tools.XXXXXX) || _die "mktemp -d failed"
}

_index_now() {
  [ -n "$_INDEX_NOW" ] || _INDEX_NOW=$(iso_now)
}

# Octal permission bits of $1 (e.g. 644). GNU stat spells it -c %a, BSD stat
# -f %Lp; each rejects the other's flag, so try both and validate the result.
_file_mode() {
  local m=""
  m=$(stat -c '%a' "$1" 2>/dev/null) || m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=""
  case "$m" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s' "$m" ;;
    *) return 1 ;;
  esac
}

_index_invalid() {
  if [ ! -s "$1" ]; then
    echo "ERROR: $INDEX_FILE is empty (0 bytes) — not a valid doc-index." >&2
  else
    echo "ERROR: $INDEX_FILE is not a valid doc-index (expected one JSON object with a \"docs\" object)." >&2
  fi
  echo "       Restore it (git checkout -- $INDEX_FILE) or rebuild it with build-index." >&2
}

# Print the path of a private, shape-validated copy of the index. Readers work
# on the copy, so one run sees one version even while a writer replaces the
# file (mv swaps the directory entry; cp read a single inode). Dies unless the
# file holds exactly one JSON object whose .docs is an object. Needs
# _scratch_init first; call as: snap=$(_index_load) || exit 1
_index_load() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi
  local snap
  snap=$(mktemp "$_SCRATCH/index.XXXXXX") || _die "mktemp failed"
  cp "$INDEX_FILE" "$snap" || _die "cannot read $INDEX_FILE"
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"' \
      "$snap" >/dev/null 2>&1; then
    _index_invalid "$snap"
    exit 1
  fi
  printf '%s\n' "$snap"
}

# Break a lock whose recorded owner ($1) is no longer running. Serialized by a
# second mkdir mutex, and the owner is re-read under it: without both, two
# waiters that saw the same dead pid could each remove the lock — the second
# removing the one the first had just taken. The whole section runs with
# signals deferred (see _signals_defer), so the mutex can never be orphaned by
# a TERM landing during its mkdir. The dead lock is renamed aside before it is
# deleted: one rename(2), so no signal can leave a half-removed, pid-less lock.
# Returns 0 if it broke the lock.
_index_break_stale() {
  local dead="$1" now_owner broke=1
  _signals_defer
  if mkdir "$INDEX_LOCK.break" 2>/dev/null; then
    _INDEX_BREAKING=1
    now_owner=$(cat "$INDEX_LOCK/pid" 2>/dev/null || true)
    if [ "$now_owner" = "$dead" ] && mv "$INDEX_LOCK" "$INDEX_LOCK.gone.$$" 2>/dev/null; then
      rm -rf "$INDEX_LOCK.gone.$$"
      echo "WARNING: removed stale lock $INDEX_LOCK (owner pid $dead is no longer running)." >&2
      broke=0
    fi
    rmdir "$INDEX_LOCK.break" 2>/dev/null || true
    _INDEX_BREAKING=0
  fi
  _signals_restore
  return "$broke"
}

# Take the writer lock (re-entrant within a run). mkdir is atomic everywhere
# and needs nothing beyond POSIX. Waits up to DOC_TOOLS_LOCK_TIMEOUT seconds
# (default 30), then fails naming the owner. Main shell only: it records $$
# and sets the held flag the EXIT trap releases.
_index_lock() {
  [ "$_INDEX_LOCK_HELD" = 0 ] || return 0
  local timeout="${DOC_TOOLS_LOCK_TIMEOUT:-30}"
  case "$timeout" in
    ''|*[!0-9]*) _die "DOC_TOOLS_LOCK_TIMEOUT must be a whole number of seconds (got '$timeout')." ;;
  esac
  local polls=0 max=$((timeout * 10)) owner err acquired
  while :; do
    # mkdir + held flag + owner pid form one signal-deferred section (see
    # _signals_defer): a signal landing in it is acted on only once the lock
    # is recorded as ours, so cleanup releases it instead of orphaning it.
    acquired=0
    _signals_defer
    if mkdir "$INDEX_LOCK" 2>/dev/null; then
      _INDEX_LOCK_HELD=1
      if printf '%s\n' "$$" > "$INDEX_LOCK/pid"; then
        acquired=1
      else
        rm -rf "$INDEX_LOCK"
        _INDEX_LOCK_HELD=0
        _signals_restore
        _die "cannot record the owner of lock $INDEX_LOCK"
      fi
    fi
    _signals_restore
    [ "$acquired" = 0 ] || return 0
    if [ ! -d "$INDEX_LOCK" ]; then
      # No lock in place: either its holder released it between our mkdir and
      # this check (retry at once), or mkdir cannot work here at all — missing
      # or read-only docs/ — where waiting would only end in a misleading
      # timeout.
      local parent
      parent=$(dirname "$INDEX_LOCK")
      polls=$((polls + 1))
      if [ -d "$parent" ] && [ -w "$parent" ] && [ "$polls" -lt "$max" ]; then
        continue
      fi
      err=$(mkdir "$INDEX_LOCK" 2>&1 && rmdir "$INDEX_LOCK") || true
      _die "cannot create lock $INDEX_LOCK${err:+: $err}"
    fi
    owner=$(cat "$INDEX_LOCK/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      _index_break_stale "$owner" && continue
    fi
    if [ "$polls" -ge "$max" ]; then
      echo "ERROR: timed out after ${timeout}s waiting for the doc-index lock $INDEX_LOCK" >&2
      if [ -n "$owner" ]; then
        echo "       (held by running pid $owner). Retry when it finishes, or raise DOC_TOOLS_LOCK_TIMEOUT." >&2
      else
        echo "       (no owner pid recorded). If no doc-tools.sh is running, remove it: rm -rf '$INDEX_LOCK'" >&2
      fi
      exit 1
    fi
    polls=$((polls + 1))
    sleep 0.1
  done
}

# Release the lock — only if it is still ours. A TERM landing during the rm
# below runs cleanup, which calls this again with the flag still set; by then
# another writer may already hold a fresh lock, so the owner pid is checked
# rather than trusting the flag. The lock is renamed aside first (one atomic
# rename), so a signal can never leave a half-removed, pid-less lock in place.
_index_unlock() {
  if [ "$_INDEX_LOCK_HELD" = 1 ]; then
    local owner
    owner=$(cat "$INDEX_LOCK/pid" 2>/dev/null || true)
    if [ "$owner" = "$$" ] && mv "$INDEX_LOCK" "$INDEX_LOCK.gone.$$" 2>/dev/null; then
      rm -rf "$INDEX_LOCK.gone.$$"
    fi
    _INDEX_LOCK_HELD=0
  fi
  return 0
}

# The ONE place the index file is replaced. $1 must be a tmp beside the index
# (_index_apply creates it) and the caller must hold the lock. The mode is the
# prior file's (so a deliberate 0664 survives), or 0644 for a new index —
# never mktemp's 0600, which git does not even carry.
_index_install() {
  local tmp="$1" mode
  mode=$(_file_mode "$INDEX_FILE") || mode=644
  chmod "$mode" "$tmp" || _die "cannot chmod $mode $tmp"
  mv -f "$tmp" "$INDEX_FILE" || _die "cannot install $INDEX_FILE"
  _INDEX_TMP=""
}

# _index_apply [--replace] <jq-program> [jq args…]
#
# Lock → snapshot → ONE jq pass → tmp beside the target → chmod → mv. The
# program gets the current index as `.` and must yield exactly one whole new
# index. `$now` (this run's timestamp) is bound for it — do not pass --arg now.
# It must not stamp generated_at: that is set here, and only if something
# changed. --replace (build-index only) tolerates a missing or invalid prior
# index — `.` is then null — because rebuilding is how one recovers from it.
#
# Sets _INDEX_WROTE (0/1) and _INDEX_CHANGED (sorted docs keys whose entry was
# added, removed or modified). Releases the lock before returning.
_index_apply() {
  local replace=0
  if [ "${1:-}" = "--replace" ]; then
    replace=1
    shift
  fi
  local program="$1"
  shift
  _scratch_init
  _index_now
  _index_lock

  local snap
  if [ "$replace" = 1 ] && [ ! -f "$INDEX_FILE" ]; then
    snap="$_SCRATCH/null.json"
    printf 'null\n' > "$snap"
  elif [ "$replace" = 1 ]; then
    if ! snap=$(_index_load 2>/dev/null); then
      echo "WARNING: replacing invalid $INDEX_FILE." >&2
      snap="$_SCRATCH/null.json"
      printf 'null\n' > "$snap"
    fi
  else
    snap=$(_index_load) || exit 1
  fi

  # Output protocol (NUL-delimited, so any key round-trips). NUL is safe in
  # jq's OUTPUT on every supported version (raw strings are written with
  # fwrite and their byte length since 1.6); it is jq's raw INPUT that is not
  # NUL-safe there — see _rec_put.
  #   same\0                                  nothing changed — write nothing
  #   write\0<n>\0<key>\0…(n keys)<index>\n  the changed keys, then the index
  # The index is emitted pretty-printed, byte-for-byte what `jq .` writes.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  local wrapped='. as $__old
    | [ '"$program"' ] as $__out
    | if ($__out | length) != 1
      then error("doc-tools: index program yielded \($__out | length) results, expected 1")
      else $__out[0] end
    | . as $__new
    | if (type != "object") or ((.docs | type) != "object")
      then error("doc-tools: index program yielded an invalid index") else . end
    | (if ($__old | type) == "object" then $__old.docs else {} end) as $__od
    | if (if ($__old | type) == "object" then ($__old | del(.generated_at)) else null end)
         == del(.generated_at)
      then "same\u0000"
      else
        [ (($__od | keys) + ($__new.docs | keys) | unique)[] as $k
          | select($__od[$k] != $__new.docs[$k]) | $k ] as $__ch
        | "write\u0000", "\($__ch | length)\u0000", ($__ch[] | . + "\u0000"),
          (.generated_at = $now), "\n"
      end'

  local out
  out=$(mktemp "$_SCRATCH/apply.XXXXXX") || _die "mktemp failed"
  # Caller options go BEFORE the program: the documented `jq [options] filter`
  # order (jq 1.6 is the floor — see check_deps).
  if ! jq -j --arg now "$_INDEX_NOW" "$@" "$wrapped" < "$snap" > "$out"; then
    _die "failed to apply the index update; $INDEX_FILE is unchanged."
  fi

  _INDEX_CHANGED=()
  _INDEX_CHANGED_SET=$'\n'
  _INDEX_WROTE=0
  local verdict="" n=0 i=0 key
  _INDEX_TMP=$(mktemp "$INDEX_FILE.tmp.XXXXXX") || _die "cannot create a temp file beside $INDEX_FILE"
  {
    IFS= read -r -d '' verdict || true
    if [ "$verdict" = write ]; then
      IFS= read -r -d '' n
      while [ "$i" -lt "$n" ]; do
        IFS= read -r -d '' key
        _INDEX_CHANGED+=("$key")
        _INDEX_CHANGED_SET="$_INDEX_CHANGED_SET$key"$'\n'
        i=$((i + 1))
      done
      cat > "$_INDEX_TMP" || _die "cannot write $_INDEX_TMP"
    fi
  } < "$out"

  case "$verdict" in
    write)
      [ -s "$_INDEX_TMP" ] || _die "rendered index is empty; $INDEX_FILE is unchanged."
      _index_install "$_INDEX_TMP"
      _INDEX_WROTE=1
      ;;
    same)
      rm -f "$_INDEX_TMP"
      _INDEX_TMP=""
      ;;
    *) _die "unexpected index-apply output; $INDEX_FILE is unchanged." ;;
  esac
  _index_unlock
}

# True if $1 is among the keys the last _index_apply changed. One glob match
# on a newline-framed string, not a scan per call: reports call this per key.
# "$1" is quoted in the pattern, so glob characters in a path match literally.
_index_changed_has() {
  case "$_INDEX_CHANGED_SET" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# One pass over snapshot $1: print 1 or 0 per remaining argument, one per line,
# for whether that key is indexed.
_index_present() {
  local snap="$1"
  shift
  jq -r '.docs as $d | $ARGS.positional[] as $p | if ($d | has($p)) then 1 else 0 end' \
    --args "$@" < "$snap"
}

# Print a report section to stderr — "<verb> N entry|entries[ <note>]" and the
# listed keys, the colon only when a list follows:
#   _report_keys <verb> <note-or-""> [key…]
_report_keys() {
  local verb="$1" note="$2"
  shift 2
  local count=$#
  echo "$verb $count $([ "$count" -eq 1 ] && echo entry || echo entries)${note:+ $note}$([ "$count" -gt 0 ] && echo ':')" >&2
  local p
  for p in "$@"; do
    echo "  $p" >&2
  done
}

# --- Usage ---

usage() {
  cat >&2 <<'EOF'
Usage: doc-tools.sh <subcommand> [options]

Subcommands:
  build-index       Build docs/.doc-index.json from stdin mapping
                    Stdin format: one line per doc — doc_path:code_refs_csv:doc_type
                    Example: docs/architecture.md:SKILL.md,scripts/:architecture
  check-freshness   Check if docs are stale relative to code changes
  update-index      Update specific entries in docs/.doc-index.json
  add-entry         Add new entries to existing docs/.doc-index.json
                    Stdin format: same as build-index — doc_path:code_refs_csv:doc_type
  remove-entry      Remove entries from docs/.doc-index.json by path
  move-entry        Re-key an entry after a doc moves, preserving its metadata
                    Usage: move-entry <old_doc_path> <new_doc_path>
                    Preserves code_refs, code_commit, last_verified, doc_type,
                    status and every other field; only content_hash is
                    recomputed. Use this — not remove-entry + add-entry — for a
                    rename, which would drop the freshness metadata.
  deprecate-entry   Mark entries as deprecated in docs/.doc-index.json
                    Usage: deprecate-entry [--superseded-by <path>] <doc_path> ...
  status <path>     Query freshness of a single doc (read-only)
  bump-version VER  Update version string in all manifest files
                    Files: RELEASE-NOTES.md, package.json, claude-code.json,
                    .claude-plugin/plugin.json, .claude-plugin/marketplace.json,
                    .cursor-plugin/plugin.json, gemini-extension.json
  check-version     Verify all manifest files have the same version
  fragments list                       List per-PR release-notes fragments + hash status
  fragments validate <path>            Exit 0 if fragment hash matches, 1 if drifted
  fragments merge <start> <end> [--paths-out=<file>]
                                       Print merged sections from fragments in commit range
                                       (--paths-out writes consumed fragment paths, one per line)
  tools install [--dest <path>] [--with-helpers]
                                       Vendor doc-tools.sh (and optionally doc-pr-release
                                       helpers + RELEASE-NOTES.next/README.md) into <path>.
                                       Default --dest is .github/scripts.
  tools uninstall [--dest <path>]      Remove vendored doc-tools.sh (and matching helpers)
                                       from <path>. Default --dest is .github/scripts.
  tools status [--dest <path>]         Report whether doc-tools.sh is vendored, version,
                                       drift state, helper presence.

Doc paths:
  The doc-index is keyed by paths relative to the repo root, and every
  subcommand resolves paths against the current working directory — so run
  doc-tools.sh from the repo root. An absolute path inside the working tree is
  rewritten to its relative form; a path outside it is rejected (non-zero exit)
  rather than written as an unfindable key.

Index writes:
  build-index, update-index, add-entry, remove-entry, move-entry and
  deprecate-entry take the lock docs/.doc-index.json.lock and replace the
  index atomically, so they are safe to run concurrently and an interrupted
  run leaves the previous index intact. A run that changes nothing writes
  nothing (generated_at is not bumped). The incremental writers report only
  the entries they actually changed. Every verb that reads the index refuses
  one that is empty or malformed; build-index rebuilds over it.

Environment:
  DOC_TOOLS_LOCK_TIMEOUT  Seconds a writer waits for the index lock before
                          failing (default 30). A lock whose recorded owner
                          is no longer running is removed automatically.

Options:
  --help            Show this help message

EOF
  exit 1
}

# --- Subcommand stubs ---

cmd_build_index() {
  # Read stdin: one line per doc in format doc_path:comma_code_refs:doc_type
  # Write docs/.doc-index.json (via _index_apply --replace — see "Index persistence")
  local docs_dir="docs"
  _scratch_init
  _index_now
  local now="$_INDEX_NOW"
  local build_commit
  build_commit=$(repo_head)

  # Per-entry accumulator: one single-key JSON object per line, merged once at
  # the end. Replaces the previous `docs_json=$(echo "$docs_json" | jq '. + …')`
  # rebuild, which was both O(N^2) in bytes re-serialized and — because the
  # merged object was ultimately handed to `jq -n --argjson docs "$docs_json"` —
  # a hard ceiling on index size: Linux caps a SINGLE argv string at
  # MAX_ARG_STRLEN (32 pages = 131072 bytes) no matter how large ARG_MAX is, so
  # build-index died with "jq: Argument list too long" at ~420 entries. macOS
  # has no per-argument cap (only the ~1 MB total ARG_MAX), which is why this
  # only ever reproduced on Linux. Mirrors the accumulator cmd_check_freshness
  # already uses. Both live in this run's scratch dir, removed by the EXIT trap.
  local entries_tmp="$_SCRATCH/entries.jsonl"
  local docs_tmp="$_SCRATCH/docs.json"
  : > "$entries_tmp"

  local invalid=0

  # Save stdin to fd 3, then redirect fd 0 to /dev/null so subprocesses
  # (e.g. git) don't consume lines from the input pipe
  exec 3<&0 0</dev/null

  while IFS= read -r line <&3 || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    # Parse fields
    local doc_path raw_doc_path code_refs_raw doc_type
    raw_doc_path=$(echo "$line" | cut -d: -f1)
    code_refs_raw=$(echo "$line" | cut -d: -f2)
    doc_type=$(echo "$line" | cut -d: -f3)

    # A key that isn't working-tree-relative is unfindable by every other
    # subcommand. Unlike add-entry (which is incremental and can keep the good
    # lines), build-index REPLACES the whole index — writing a partial one would
    # silently drop docs — so a single bad line aborts before any write.
    if ! doc_path=$(normalize_doc_path "$raw_doc_path"); then
      invalid=$((invalid + 1))
      continue
    fi

    # Compute content hash
    local content_hash_val
    if [ -f "$doc_path" ]; then
      content_hash_val="\"sha256:$(hash_file "$doc_path")\""
    else
      content_hash_val="null"
    fi

    # Build code_refs JSON array from comma-separated list.
    #
    # Empty strings are dropped so an omitted refs field yields [], not [""].
    # A `""` ref is a phantom that is not a path: behaviourally it matches []
    # (compute_freshness filters empty strings out of code_refs_arr), but it is
    # a state no caller intended, and a consuming project had to normalize 1691
    # such entries away. Only affects newly-written entries — existing [""]
    # entries already behave as [], so no migration is needed.
    local code_refs_json
    code_refs_json=$(echo "$code_refs_raw" | tr ',' '\n' | jq -R . | jq -s 'map(select(. != ""))')

    # Compute latest commit across all code refs (single git log call per spec)
    #
    # The count guard is load-bearing on bash 3.2: an entry with no code_refs
    # (`docs/x.md::spec`) leaves `refs` empty, and bash 3.2 treats an unguarded
    # "${refs[@]}" on an empty array as an unbound variable under `set -u`,
    # aborting build-index outright. Same guard the sibling call sites use.
    local code_commit=""
    IFS=',' read -ra refs <<< "$code_refs_raw"
    if [ ${#refs[@]} -gt 0 ]; then
      code_commit=$(git log -1 --format=%H -- "${refs[@]}" 2>/dev/null || true)
    fi

    # Append the entry as a single-key object keyed by doc path. Emitting the
    # key here (rather than merging into a growing object) is what keeps the
    # accumulator flat.
    if [ -n "$code_commit" ]; then
      jq -nc \
        --arg key "$doc_path" \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg code_commit "$code_commit" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{($key): {
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: $code_commit,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }}' >> "$entries_tmp"
    else
      jq -nc \
        --arg key "$doc_path" \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{($key): {
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: null,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }}' >> "$entries_tmp"
    fi
  done

  exec 3<&-

  if [ "$invalid" -gt 0 ]; then
    echo "ERROR: $invalid invalid $([ "$invalid" -eq 1 ] && echo path || echo paths) in build-index input; index NOT written." >&2
    exit 1
  fi

  # Collapse the per-entry accumulator into one object in a single jq call.
  # Each row is a single-key object, so `. + $row` on disjoint keys is plain
  # object merge — and a repeated key keeps the LAST occurrence, matching the
  # previous `. + {($key): $val}` accumulation semantics.
  if [ -s "$entries_tmp" ]; then
    jq -cs 'reduce .[] as $row ({}; . + $row)' "$entries_tmp" > "$docs_tmp"
  else
    printf '{}\n' > "$docs_tmp"
  fi

  # Build the final index
  # schema_version bumped 1 → 2 in Task 3.4 of
  # docs/plans/2026-05-16-adr-implementation-field-rollout.md to capture the
  # new per-entry `implementation` array. Renamed from `version` (only test
  # helpers read the field; live doc-index migrated in the same commit).
  #
  # `docs` arrives via --slurpfile, NOT --argjson: it is the one unbounded
  # value here, and passing it through argv is what capped the index at ~420
  # entries on Linux (see the accumulator comment above).
  #
  # --replace: build-index is the recovery path, so a missing or invalid prior
  # index is replaced rather than refused. generated_at is stamped by
  # _index_apply ($now), and nothing is written if the result is identical.
  mkdir -p "$docs_dir"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  _index_apply --replace '{
      schema_version: 2,
      generated_by: "doc-superpowers",
      generated_at: $now,
      build_commit: $build_commit,
      docs: $docs[0]
    }' \
    --arg build_commit "$build_commit" \
    --slurpfile docs "$docs_tmp"
  # Silent on success, as before: it replaces the whole index, so a per-key
  # report would only restate its input.
}

cmd_check_freshness() {
  local filter_refs=()

  # Parse optional --code-refs arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code-refs)
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do
          filter_refs+=("$1")
          shift
        done
        ;;
      *) shift ;;
    esac
  done

  # ONE validated snapshot serves both passes below (entry walk + untracked
  # key set). Reading the live file twice let a concurrent writer land between
  # them, so the summary and .docs could describe two different indexes.
  _scratch_init
  local snap
  snap=$(_index_load) || exit 1

  local checked_at repo_head_val
  checked_at=$(iso_now)
  repo_head_val=$(repo_head)

  local count_current=0
  local count_stale=0
  local count_missing=0
  local count_deprecated=0

  # Per-doc result accumulator: one JSON object per line (path -> result),
  # merged once at the end with `jq -s` instead of rebuilding via
  # `jq '. + {(p): v}'` per iteration. Eliminates O(N) jq spawns for
  # accumulator updates — the dominant cost on large indexes.
  # All in this run's scratch dir (removed by the EXIT trap).
  local jsonl_tmp="$_SCRATCH/fresh.jsonl" idx_paths_tmp="$_SCRATCH/idx-paths"
  local fs_paths_tmp="$_SCRATCH/fs-paths"
  # Both of these hold values that scale with the corpus, so they are handed to
  # the final `jq -n` via --slurpfile rather than --argjson: Linux caps a single
  # argv string at MAX_ARG_STRLEN (131072 bytes) regardless of ARG_MAX, and the
  # merged docs object passes that at a few hundred entries.
  local docs_out_tmp="$_SCRATCH/docs-out.json" untracked_tmp="$_SCRATCH/untracked.json"
  : > "$jsonl_tmp"

  # Single-pass field extraction: one `jq` call emits every entry's fields
  # in NUL-delimited records (tab-separated within each record). The body
  # of the loop never re-invokes `jq` to read a field — replaces ~5 jq
  # spawns per entry. Records are NUL-delimited to tolerate paths/values
  # containing newlines; tabs in paths would corrupt parsing but are
  # vanishingly rare in `docs/` (and `add-entry` already rejects colons).
  while IFS=$'\t' read -r -d '' doc_path stored_status doc_type last_verified content_hash code_commit code_refs_csv; do
    # Reconstruct code_refs array from CSV. Refs may contain spaces but
    # not commas (commas are the build-index/add-entry CSV separator).
    local code_refs_arr=()
    if [[ -n "$code_refs_csv" ]]; then
      local _IFS_SAVE="$IFS"
      IFS=','
      # shellcheck disable=SC2206
      code_refs_arr=( $code_refs_csv )
      IFS="$_IFS_SAVE"
    fi

    # Apply --code-refs filter if provided (bidirectional prefix match) —
    # unchanged semantics from the per-jq-call path; just operates on the
    # pre-extracted array.
    if [ ${#filter_refs[@]} -gt 0 ]; then
      local matched=0
      for filter_ref in "${filter_refs[@]}"; do
        for doc_ref in "${code_refs_arr[@]+"${code_refs_arr[@]}"}"; do
          if [[ "$doc_ref" == "$filter_ref"* || "$filter_ref" == "$doc_ref"* ]]; then
            matched=1
            break 2
          fi
        done
      done
      [ "$matched" -eq 0 ] && continue
    fi

    # Deprecated: preserve status, no freshness fields.
    if [ "$stored_status" = "deprecated" ]; then
      count_deprecated=$((count_deprecated + 1))
      jq -nc \
        --arg p "$doc_path" \
        --arg doc_type "$doc_type" \
        '{($p): {status: "deprecated", doc_type: $doc_type}}' >> "$jsonl_tmp"
      continue
    fi

    # Missing: doc file no longer exists.
    if [ ! -f "$doc_path" ]; then
      count_missing=$((count_missing + 1))
      jq -nc \
        --arg p "$doc_path" \
        --arg doc_type "$doc_type" \
        '{($p): {status: "missing", doc_type: $doc_type}}' >> "$jsonl_tmp"
      continue
    fi

    # Compute freshness inline — same logic as `compute_freshness` but
    # works on pre-extracted fields, avoiding 4 internal jq spawns
    # (status/code_refs/hash/code_commit reads). `compute_freshness`
    # itself stays unchanged for the `cmd_status` single-doc caller.
    local current_hash doc_modified
    current_hash="sha256:$(hash_file "$doc_path")"
    [ "$current_hash" != "$content_hash" ] && doc_modified=true || doc_modified=false

    local current_code_commit=""
    if [ ${#code_refs_arr[@]} -gt 0 ]; then
      current_code_commit=$(git log -1 --format=%H -- "${code_refs_arr[@]}" 2>/dev/null || true)
    fi

    local status reason
    if [ -n "$current_code_commit" ] && [ "$current_code_commit" != "$code_commit" ]; then
      status="stale"; reason="code_changed"
    else
      status="current"; reason=""
    fi

    local commits_behind=0
    if [ -n "$code_commit" ] && [ ${#code_refs_arr[@]} -gt 0 ]; then
      commits_behind=$(git rev-list --count "${code_commit}..HEAD" -- "${code_refs_arr[@]}" 2>/dev/null || echo 0)
    fi

    local code_refs_changed_json="[]"
    if [ "$status" = "stale" ] && [ -n "$code_commit" ]; then
      local changed_refs=()
      for ref in "${code_refs_arr[@]+"${code_refs_arr[@]}"}"; do
        local ref_commit
        ref_commit=$(git log -1 --format=%H -- "$ref" 2>/dev/null || true)
        if [ -n "$ref_commit" ] && [ "$ref_commit" != "$code_commit" ]; then
          changed_refs+=("$ref")
        fi
      done
      if [ ${#changed_refs[@]} -gt 0 ]; then
        code_refs_changed_json=$(printf '%s\n' "${changed_refs[@]}" | jq -R . | jq -cs .)
      fi
    fi

    if [ "$status" = "current" ]; then
      count_current=$((count_current + 1))
    else
      count_stale=$((count_stale + 1))
    fi

    if [ -n "$reason" ]; then
      jq -nc \
        --arg p "$doc_path" \
        --arg status "$status" \
        --arg reason "$reason" \
        --argjson doc_modified "$doc_modified" \
        --argjson commits_behind "$commits_behind" \
        --argjson code_refs_changed "$code_refs_changed_json" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$last_verified" \
        '{($p): {status: $status, reason: $reason, doc_modified: $doc_modified, commits_behind: $commits_behind, code_refs_changed: $code_refs_changed, doc_type: $doc_type, last_verified: $last_verified}}' \
        >> "$jsonl_tmp"
    else
      jq -nc \
        --arg p "$doc_path" \
        --arg status "$status" \
        --argjson doc_modified "$doc_modified" \
        --argjson commits_behind "$commits_behind" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$last_verified" \
        '{($p): {status: $status, doc_modified: $doc_modified, commits_behind: $commits_behind, doc_type: $doc_type, last_verified: $last_verified}}' \
        >> "$jsonl_tmp"
    fi

  done < <(jq -j '
    .docs | to_entries[] | (
      [
        .key,
        (.value.status // ""),
        (.value.doc_type // ""),
        (.value.last_verified // ""),
        (.value.content_hash // ""),
        (.value.code_commit // ""),
        ((.value.code_refs // []) | join(","))
      ] | @tsv
    ) + "\u0000"
  ' "$snap")

  # Merge JSON-lines accumulator into a single object in ONE jq invocation
  # instead of N. `reduce .[] as $row (...; . + $row)` works because each
  # row is a single-key object and the union operator on disjoint keys is
  # just object merge.
  if [ -s "$jsonl_tmp" ]; then
    jq -cs 'reduce .[] as $row ({}; . + $row)' "$jsonl_tmp" > "$docs_out_tmp"
  else
    printf '{}\n' > "$docs_out_tmp"
  fi

  # Untracked detection — set-difference between filesystem and index keys.
  # Replaces N per-file `jq '.docs | has($p)'` queries with a single
  # `jq keys` + `find` + `comm`. Raw keys, not the @tsv-escaped ones above.
  jq -r '.docs | keys[]' "$snap" | sort > "$idx_paths_tmp"
  find docs -name '*.md' -not -path 'docs/archive/*' 2>/dev/null | sort > "$fs_paths_tmp"
  if [ -s "$fs_paths_tmp" ]; then
    comm -23 "$fs_paths_tmp" "$idx_paths_tmp" | jq -R . | jq -cs . > "$untracked_tmp"
  else
    printf '[]\n' > "$untracked_tmp"
  fi
  local untracked_count
  untracked_count=$(jq 'length' "$untracked_tmp")

  # Build final output. `docs` and `untracked_docs` come in via --slurpfile
  # (see the tempfile declarations above); only the bounded scalars use argv.
  jq -n \
    --arg checked_at "$checked_at" \
    --arg repo_head "$repo_head_val" \
    --argjson current "$count_current" \
    --argjson stale "$count_stale" \
    --argjson missing "$count_missing" \
    --argjson deprecated "$count_deprecated" \
    --argjson untracked "$untracked_count" \
    --slurpfile untracked_docs "$untracked_tmp" \
    --slurpfile docs "$docs_out_tmp" \
    '{
      checked_at: $checked_at,
      repo_head: $repo_head,
      summary: {current: $current, stale: $stale, missing: $missing, deprecated: $deprecated, untracked: $untracked},
      untracked_docs: $untracked_docs[0],
      docs: $docs[0]
    }'
}

cmd_update_index() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: update-index requires at least one doc path argument." >&2
    exit 1
  fi

  local targets=() raw_doc_path doc_path
  for raw_doc_path in "$@"; do
    doc_path=$(normalize_doc_path "$raw_doc_path") || exit 1
    targets+=("$doc_path")
  done

  _scratch_init
  _index_now
  # The patch is derived from each entry's code_refs, so they are read under
  # the lock: no concurrent writer can change an entry between this read and
  # the write below.
  _index_lock
  local snap
  snap=$(_index_load) || exit 1

  # ONE pass over the index for every target (the previous per-path loop
  # re-parsed the whole index three times per doc: O(k·N)). NUL-delimited
  # records, one per target in argument order: <has 0|1> <n> <ref>… — the refs
  # as `.code_refs[]` yielded them, minus empty strings.
  local info="$_SCRATCH/update-info"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -j '.docs as $d | $ARGS.positional[] as $p
    | if ($d | has($p)) then
        (($d[$p].code_refs | if type == "array" then . else [] end)
          | map(tostring | select(. != ""))) as $r
        | "1\u0000\($r | length)\u0000" + ([$r[] | . + "\u0000"] | add // "")
      else "0\u00000\u0000" end' --args "${targets[@]}" < "$snap" > "$info"

  # Unknown key → abort the whole batch before anything is computed or written
  # (unchanged contract). Refs are kept in one flat array with per-target
  # offsets (bash 3.2 has no arrays of arrays).
  local has n j ref idx=0
  local ref_all=() ref_start=() ref_count=()
  exec 3< "$info"
  while [ "$idx" -lt "${#targets[@]}" ]; do
    IFS= read -r -d '' has <&3
    IFS= read -r -d '' n <&3
    ref_start+=("${#ref_all[@]}")
    ref_count+=("$n")
    j=0
    while [ "$j" -lt "$n" ]; do
      IFS= read -r -d '' ref <&3
      ref_all+=("$ref")
      j=$((j + 1))
    done
    if [ "$has" != "1" ]; then
      exec 3<&-
      echo "ERROR: '${targets[$idx]}' not found in index. Use add-entry to add new docs." >&2
      exit 1
    fi
    idx=$((idx + 1))
  done
  exec 3<&-

  # Targets whose file is gone are skipped (with rename advice); the rest are
  # hashed in one batch.
  local live=() live_idx=()
  idx=0
  while [ "$idx" -lt "${#targets[@]}" ]; do
    doc_path="${targets[$idx]}"
    if [ ! -f "$doc_path" ]; then
      echo "WARNING: '$doc_path' no longer exists on disk. Skipping." >&2
      # The path is quoted INSIDE the advice string: a doc path containing a
      # space would otherwise paste as three arguments and trip move-entry's
      # arity guard — misleading exactly the operator who follows the advice.
      echo "         If it was RENAMED, use: move-entry \"$doc_path\" <new-path>" >&2
      echo "         (remove-entry + add-entry would drop its code_refs, leaving an entry that can never go stale.)" >&2
      echo "         If it was deleted, use remove-entry or deprecate-entry to clean up." >&2
    else
      live+=("$doc_path")
      live_idx+=("$idx")
    fi
    idx=$((idx + 1))
  done

  local hashes=() h
  while IFS= read -r h; do
    hashes+=("$h")
  done < <(_hash_files "${live[@]+"${live[@]}"}")

  # Implementation: (ADRs) / Realized-by: (SPECs) bullets, for every live doc
  # in ONE awk pass (a fork+exec per doc dominated the batch). Per file this is
  # exactly the old single-file program — the `exit` that ended it at the
  # first blank or unindented line is now a per-file `done` — and each
  # captured line is tagged with its ARGV index. Empty files never reach
  # FNR == 1, so argi catches up by name. Both fields are stored under the
  # single JSON key "implementation" to keep downstream consumers simple
  # (validate_docs.py, doc-audit routine) — see Task 3.4 of
  # docs/plans/2026-05-16-adr-implementation-field-rollout.md.
  local impl=() tagged ai line
  if [ ${#live[@]} -gt 0 ]; then
    tagged=$(awk '
        FNR == 1 {
          argi++
          while (argi < ARGC && ARGV[argi] != FILENAME) argi++
          capture = 0; done = 0
        }
        done { next }
        /^Implementation:[[:space:]]*$|^Realized-by:[[:space:]]*$/ { capture = 1; next }
        capture && /^[[:space:]]+-/ { print argi "\t" $0; next }
        capture && /^[[:space:]]*$|^[^[:space:]]/ { done = 1 }
    ' "${live[@]}")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Split by hand: `IFS=$'\t' read` would also trim a tab-indented bullet.
      ai="${line%%$'\t'*}"
      line="${line#*$'\t'}"
      ai=$((ai - 1))
      impl[$ai]="${impl[$ai]:+${impl[$ai]}$'\n'}$line"
    done <<< "$tagged"
  fi

  # code_commit: one git log per DISTINCT code_refs set — docs that share refs
  # (common: several docs covering src/) share the answer. Linear cache, no
  # associative arrays (bash 3.2). Written as a _rec_put record stream, turned
  # into the JSONL patch by ONE jq below.
  local raw="$_SCRATCH/update-raw" patch="$_SCRATCH/update-patch.jsonl"
  : > "$raw"
  local k=0 c code_commit start count code_refs_arr ckey
  local cache_keys=() cache_vals=()
  while [ "$k" -lt "${#live[@]}" ]; do
    doc_path="${live[$k]}"
    idx="${live_idx[$k]}"
    start="${ref_start[$idx]}"
    count="${ref_count[$idx]}"
    code_refs_arr=()
    ckey=""
    j=0
    while [ "$j" -lt "$count" ]; do
      ref="${ref_all[$((start + j))]}"
      code_refs_arr+=("$ref")
      ckey="$ckey$ref"$'\037'
      j=$((j + 1))
    done
    code_commit=""
    if [ ${#code_refs_arr[@]} -gt 0 ]; then
      c=0
      while [ "$c" -lt "${#cache_keys[@]}" ] && [ "${cache_keys[$c]}" != "$ckey" ]; do
        c=$((c + 1))
      done
      if [ "$c" -lt "${#cache_keys[@]}" ]; then
        code_commit="${cache_vals[$c]}"
      else
        code_commit=$(git log -1 --format=%H -- "${code_refs_arr[@]}" 2>/dev/null || true)
        cache_keys+=("$ckey")
        cache_vals+=("$code_commit")
      fi
    fi
    _rec_put "$doc_path" "${hashes[$k]}" "$code_commit" "${impl[$k]:-}" >> "$raw"
    k=$((k + 1))
  done

  # Refresh: re-hash, re-query code_commit, set status=current, stamp
  # last_verified, capture implementation (bullets with a leading "  - "
  # stripped). Preserved: replaces, superseded_by, doc_type, code_refs, and the
  # top-level build_commit.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -c -n -R --arg now "$_INDEX_NOW" "$_JQ_REC_FIELDS"'
    rec_fields as $f
    | range(0; $f | length; 4) as $i
    | {key: $f[$i], merge: {
        content_hash: $f[$i + 1],
        code_commit: (if $f[$i + 2] == "" then null else $f[$i + 2] end),
        status: "current",
        last_verified: $now,
        implementation: (if $f[$i + 3] == "" then []
                         else ($f[$i + 3] | split("\n") | map(ltrimstr("  - "))) end)}}
  ' < "$raw" > "$patch"

  _index_apply "$_INDEX_PATCH" --slurpfile patch "$patch"

  # Report what actually changed. A doc re-verified within the same second
  # with nothing to update changes nothing, and is listed as unchanged.
  local refreshed=() unchanged=()
  for doc_path in "${live[@]+"${live[@]}"}"; do
    if _index_changed_has "$doc_path"; then
      refreshed+=("$doc_path")
    else
      unchanged+=("$doc_path")
    fi
  done
  _report_keys "Refreshed" "" "${refreshed[@]+"${refreshed[@]}"}"
  if [ ${#unchanged[@]} -gt 0 ]; then
    _report_keys "Unchanged" "(already up to date)" "${unchanged[@]}"
  fi
}

cmd_add_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  _scratch_init
  _index_now

  local invalid=0
  local requested=()
  # Facts about each doc (hash, code_commit) do not depend on the index, so
  # they are gathered WITHOUT the lock — stdin may be slow — as a _rec_put
  # record stream. The "add" patch rows only insert keys that are still absent
  # when applied under the lock, so a concurrent writer cannot be clobbered.
  local raw="$_SCRATCH/add-raw" patch="$_SCRATCH/add-patch.jsonl"
  : > "$raw"

  # Save stdin to fd 3, redirect fd 0 so subprocesses don't consume input
  exec 3<&0 0</dev/null

  local line
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    local doc_path raw_doc_path code_refs_raw doc_type
    raw_doc_path=$(echo "$line" | cut -d: -f1)
    code_refs_raw=$(echo "$line" | cut -d: -f2)
    doc_type=$(echo "$line" | cut -d: -f3)

    # Reject anything that can't be expressed as a working-tree-relative key.
    # add-entry is incremental, so the valid lines are still applied — but the
    # command exits non-zero so a bad path can never pass silently.
    if ! doc_path=$(normalize_doc_path "$raw_doc_path"); then
      invalid=$((invalid + 1))
      continue
    fi

    # Compute content hash ("" → null: a not-yet-written doc is allowed)
    local content_hash_val=""
    if [ -f "$doc_path" ]; then
      content_hash_val="sha256:$(hash_file "$doc_path")"
    fi

    # Compute latest commit across code refs (count guard: see cmd_build_index —
    # an empty code_refs list is unbound under bash 3.2 + `set -u`)
    local code_commit=""
    local refs=()
    IFS=',' read -ra refs <<< "$code_refs_raw"
    if [ ${#refs[@]} -gt 0 ]; then
      code_commit=$(git log -1 --format=%H -- "${refs[@]}" 2>/dev/null || true)
    fi

    _rec_put "$doc_path" "$content_hash_val" "$code_refs_raw" "$code_commit" "$doc_type" >> "$raw"
    requested+=("$doc_path")
  done

  exec 3<&-

  # code_refs: comma-split with empty strings dropped — see cmd_build_index for
  # why [""] must never be written.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -c -n -R --arg now "$_INDEX_NOW" "$_JQ_REC_FIELDS"'
    rec_fields as $f
    | range(0; $f | length; 5) as $i
    | {key: $f[$i], add: {
        content_hash: (if $f[$i + 1] == "" then null else $f[$i + 1] end),
        code_refs: ($f[$i + 2] | split(",") | map(select(. != ""))),
        code_commit: (if $f[$i + 3] == "" then null else $f[$i + 3] end),
        doc_type: $f[$i + 4],
        status: "current",
        replaces: null,
        superseded_by: null,
        last_verified: $now}}
  ' < "$raw" > "$patch"

  _index_apply "$_INDEX_PATCH" --slurpfile patch "$patch"

  # Report what actually happened, in input order. A key that was already
  # indexed (or repeated within this batch) was not added.
  local added=() seen=$'\n' p
  for p in "${requested[@]+"${requested[@]}"}"; do
    case "$seen" in
      *$'\n'"$p"$'\n'*) ;;
      *)
        if _index_changed_has "$p"; then
          added+=("$p")
          seen="$seen$p"$'\n'
          continue
        fi
        ;;
    esac
    echo "SKIP: '$p' already in index. Use update-index to refresh." >&2
  done
  _report_keys "Added" "" "${added[@]+"${added[@]}"}"

  if [ "$invalid" -gt 0 ]; then
    echo "Rejected $invalid invalid $([ "$invalid" -eq 1 ] && echo path || echo paths)." >&2
    exit 1
  fi
}

cmd_remove_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: remove-entry requires at least one doc path argument." >&2
    exit 1
  fi

  # Normalize every path up front so an unusable one aborts before we mutate the
  # index. Without this an absolute path merely reported "not found in index" and
  # exited 0 — a silent no-op for a caller who asked to remove a real entry.
  local targets=() raw_doc_path doc_path
  for raw_doc_path in "$@"; do
    doc_path=$(normalize_doc_path "$raw_doc_path") || exit 1
    targets+=("$doc_path")
  done

  _scratch_init
  local patch="$_SCRATCH/remove-patch.jsonl"
  jq -nc '$ARGS.positional[] | {key: ., del: true}' --args "${targets[@]}" > "$patch"
  _index_apply "$_INDEX_PATCH" --slurpfile patch "$patch"

  # A present key is always removed, so "not changed" means "not indexed".
  local removed=()
  for doc_path in "${targets[@]}"; do
    if _index_changed_has "$doc_path"; then
      removed+=("$doc_path")
    else
      echo "SKIP: '$doc_path' not found in index." >&2
    fi
  done
  _report_keys "Removed" "" "${removed[@]+"${removed[@]}"}"
}

cmd_move_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  # A move is inherently PAIRED, so this takes exactly one pair. A varargs
  # `move-entry old1 new1 old2 new2` form would silently mis-pair on an odd
  # argument count, and the failure mode is an index full of wrong keys.
  if [ $# -ne 2 ]; then
    echo "ERROR: move-entry requires exactly two arguments." >&2
    echo "Usage: move-entry <old_doc_path> <new_doc_path>" >&2
    exit 1
  fi

  local old_path new_path
  old_path=$(normalize_doc_path "$1" "old doc path") || exit 1
  new_path=$(normalize_doc_path "$2" "new doc path") || exit 1

  # Same-path is a no-op that writes NOTHING — not even a generated_at bump. A
  # re-run of an operator script must not fail, and must not manufacture a
  # doc-index diff (see docs/issues/2026-05-04-doc-index-metadata-rewrite-on-every-commit.md).
  if [ "$old_path" = "$new_path" ]; then
    echo "SKIP: '$old_path' — old and new path are the same; nothing to move." >&2
    return 0
  fi

  _scratch_init
  # The existence checks below and the write must see the same index, so both
  # happen under the lock.
  _index_lock
  local snap has_old has_new
  snap=$(_index_load) || exit 1
  { read -r has_old; read -r has_new; } < <(_index_present "$snap" "$old_path" "$new_path")

  if [ "$has_old" != "1" ]; then
    echo "ERROR: '$old_path' not found in index. Nothing to move." >&2
    exit 1
  fi

  # Refuse to clobber: overwriting the destination would discard ITS metadata,
  # which is the precise loss move-entry exists to prevent.
  if [ "$has_new" = "1" ]; then
    echo "ERROR: '$new_path' is already in the index. Refusing to overwrite it." >&2
    echo "       Remove it first (remove-entry) if it is genuinely obsolete." >&2
    exit 1
  fi

  # Unlike add-entry — which tolerates a not-yet-written doc because it supports
  # authoring — re-keying onto a path with no file on it is a typo, and it would
  # mint an entry with a null hash: unfindable, and permanently "current"
  # because there is nothing to hash-compare. Refuse.
  if [ ! -f "$new_path" ]; then
    echo "ERROR: '$new_path' does not exist on disk. Move the file first, then re-key." >&2
    exit 1
  fi

  # The old file still being present is legitimate — a partially-staged `git mv`,
  # or a deliberate copy-then-reindex — so warn rather than refuse. But do not
  # stay silent: a copy-instead-of-move typo leaves an orphaned unindexed doc on
  # disk that resurfaces later as an untracked file.
  if [ -f "$old_path" ]; then
    echo "WARNING: '$old_path' still exists on disk; it will be left unindexed." >&2
  fi

  local content_hash
  content_hash="sha256:$(hash_file "$new_path")"

  # The entry object is carried over WHOLESALE (`.value + {content_hash: …}`)
  # rather than field-by-field, so a field this code has never heard of still
  # survives a move. Only content_hash is adjusted: code_commit and
  # last_verified are deliberately PRESERVED, because a move is not a
  # verification — re-deriving either would make the entry assert a freshness
  # nobody confirmed. Run update-index afterwards for a genuine re-verify.
  #
  # to_entries|map|from_entries re-keys IN POSITION, so the commit-time diff is a
  # one-line key rename rather than the delete-plus-append that
  # `.docs[$new] = .docs[$old] | del(.docs[$old])` would produce. (Only until the
  # next merge: merge-doc-index.sh sorts .docs alphabetically.) from_entries
  # cannot collide here — the duplicate-key case is refused above.
  #
  # The second stage repoints other entries' path-valued fields, which
  # references/doc-spec.md holds to the same key contract as the keys themselves
  # — without it a rename leaves a dangling superseded_by/replaces.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  _index_apply '.docs |= (to_entries
               | map(if .key == $old
                     then {key: $new, value: (.value + {content_hash: $content_hash})}
                     else . end)
               | from_entries)
    | .docs |= map_values(
        (if .replaces == $old then .replaces = $new else . end)
        | (if .superseded_by == $old then .superseded_by = $new else . end))' \
    --arg old "$old_path" \
    --arg new "$new_path" \
    --arg content_hash "$content_hash"

  echo "Moved 1 entry:" >&2
  echo "  $old_path -> $new_path" >&2
  local repointed=() k
  for k in "${_INDEX_CHANGED[@]+"${_INDEX_CHANGED[@]}"}"; do
    [ "$k" = "$old_path" ] || [ "$k" = "$new_path" ] || repointed+=("$k")
  done
  if [ ${#repointed[@]} -gt 0 ]; then
    _report_keys "Repointed" "(replaces/superseded_by now name the new path)" "${repointed[@]}"
  fi
}

cmd_deprecate_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: deprecate-entry requires at least one doc path argument." >&2
    echo "Usage: deprecate-entry [--superseded-by <path>] <doc_path> [doc_path ...]" >&2
    exit 1
  fi

  # Parse optional --superseded-by flag
  local superseded_by="null"
  if [ "${1:-}" = "--superseded-by" ]; then
    shift
    if [ $# -eq 0 ]; then
      echo "ERROR: --superseded-by requires a path argument." >&2
      exit 1
    fi
    # This is stored in the index as a doc reference, so it is subject to the
    # same key contract as the entries themselves.
    local superseded_by_path
    superseded_by_path=$(normalize_doc_path "$1" "--superseded-by path") || exit 1
    superseded_by=$(printf '%s' "$superseded_by_path" | jq -R .)
    shift
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: no doc paths provided after flags." >&2
    exit 1
  fi

  # Normalize up front — same rationale as remove-entry: an absolute path used to
  # report "not found" and exit 0, silently failing to deprecate a real entry.
  local targets=() raw_doc_path doc_path
  for raw_doc_path in "$@"; do
    doc_path=$(normalize_doc_path "$raw_doc_path") || exit 1
    targets+=("$doc_path")
  done

  _scratch_init
  _index_now
  # Presence is read under the lock so "not found" and "already deprecated"
  # (a no-op) can be told apart in the report.
  _index_lock
  local snap
  snap=$(_index_load) || exit 1
  local absent=() present_flag i=0
  while IFS= read -r present_flag; do
    [ "$present_flag" = "1" ] || absent+=("${targets[$i]}")
    i=$((i + 1))
  done < <(_index_present "$snap" "${targets[@]}")

  local patch="$_SCRATCH/deprecate-patch.jsonl"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -nc --argjson superseded_by "$superseded_by" --arg now "$_INDEX_NOW" \
    '$ARGS.positional[] | {key: ., merge: {status: "deprecated", superseded_by: $superseded_by, last_verified: $now}}' \
    --args "${targets[@]}" > "$patch"
  _index_apply "$_INDEX_PATCH" --slurpfile patch "$patch"

  local deprecated=() unchanged=() p
  for doc_path in "${targets[@]}"; do
    if _index_changed_has "$doc_path"; then
      deprecated+=("$doc_path")
      continue
    fi
    local is_absent=0
    for p in "${absent[@]+"${absent[@]}"}"; do
      [ "$p" = "$doc_path" ] && is_absent=1
    done
    if [ "$is_absent" = 1 ]; then
      echo "SKIP: '$doc_path' not found in index." >&2
    else
      unchanged+=("$doc_path")
    fi
  done
  _report_keys "Deprecated" "" "${deprecated[@]+"${deprecated[@]}"}"
  if [ ${#unchanged[@]} -gt 0 ]; then
    _report_keys "Unchanged" "(already deprecated)" "${unchanged[@]}"
  fi
}

cmd_status() {
  if [ $# -eq 0 ]; then
    echo "ERROR: status requires a doc path argument." >&2
    exit 1
  fi

  local doc_path
  doc_path=$(normalize_doc_path "$1") || exit 1

  _scratch_init
  local snap index
  snap=$(_index_load) || exit 1
  index=$(cat "$snap")

  # Verify path exists in index
  local exists
  exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
  if [ "$exists" != "true" ]; then
    echo "ERROR: '$doc_path' not found in index." >&2
    exit 1
  fi

  local entry
  entry=$(echo "$index" | jq --arg p "$doc_path" '.docs[$p]')

  local stored_status
  stored_status=$(echo "$entry" | jq -r '.status')
  local doc_type
  doc_type=$(echo "$entry" | jq -r '.doc_type')
  local last_verified
  last_verified=$(echo "$entry" | jq -r '.last_verified // empty')

  # Deprecated: short-circuit
  if [ "$stored_status" = "deprecated" ]; then
    jq -n \
      --arg path "$doc_path" \
      --arg doc_type "$doc_type" \
      --arg status "deprecated" \
      --arg last_verified "$last_verified" \
      '{path: $path, doc_type: $doc_type, status: $status, last_verified: $last_verified}'
    return 0
  fi

  # Missing
  if [ ! -f "$doc_path" ]; then
    jq -n \
      --arg path "$doc_path" \
      --arg doc_type "$doc_type" \
      --arg status "missing" \
      '{path: $path, doc_type: $doc_type, status: $status}'
    return 0
  fi

  # Compute freshness via shared helper, add path/doc_type/last_verified
  local freshness
  freshness=$(compute_freshness "$doc_path" "$entry")

  echo "$freshness" | jq \
    --arg path "$doc_path" \
    --arg doc_type "$doc_type" \
    --arg last_verified "$last_verified" \
    '{path: $path} + . + {doc_type: $doc_type, last_verified: $last_verified}'
}

# --- Version management ---

# All files that carry a version string, with their jq path
VERSION_FILES=(
  "package.json:.version"
  "claude-code.json:.version"
  ".claude-plugin/plugin.json:.version"
  ".claude-plugin/marketplace.json:.metadata.version"
  ".cursor-plugin/plugin.json:.version"
  "gemini-extension.json:.version"
)

cmd_bump_version() {
  local new_version="${1:-}"
  if [[ -z "$new_version" ]]; then
    echo "ERROR: bump-version requires a version argument (e.g., 2.5.0)" >&2
    exit 1
  fi

  # Validate semver format
  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: invalid version format '$new_version' — expected MAJOR.MINOR.PATCH" >&2
    exit 1
  fi

  local updated=0

  for entry in "${VERSION_FILES[@]}"; do
    local file="${entry%%:*}"
    local jq_path="${entry#*:}"

    if [[ ! -f "$file" ]]; then
      echo "  skip: $file (not found)"
      continue
    fi

    local current
    current=$(jq -r "$jq_path // empty" "$file" 2>/dev/null)
    if [[ "$current" == "$new_version" ]]; then
      echo "  ok:   $file (already $new_version)"
      continue
    fi

    local tmp
    tmp=$(mktemp)
    jq "$jq_path = \"$new_version\"" "$file" > "$tmp" && mv "$tmp" "$file"
    echo "  bump: $file ($current → $new_version)"
    updated=$((updated + 1))
  done

  echo "Updated $updated file(s) to v$new_version"
}

cmd_check_version() {
  # Extract canonical version from RELEASE-NOTES.md
  local canonical
  canonical=$(grep -m 1 -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' RELEASE-NOTES.md 2>/dev/null | sed 's/## v//')
  if [[ -z "$canonical" ]]; then
    echo "ERROR: could not extract version from RELEASE-NOTES.md" >&2
    exit 1
  fi

  local mismatched=0
  local checked=0

  echo "Canonical version (RELEASE-NOTES.md): v$canonical"

  for entry in "${VERSION_FILES[@]}"; do
    local file="${entry%%:*}"
    local jq_path="${entry#*:}"

    if [[ ! -f "$file" ]]; then
      continue
    fi

    local actual
    actual=$(jq -r "$jq_path // empty" "$file" 2>/dev/null)
    checked=$((checked + 1))

    if [[ "$actual" != "$canonical" ]]; then
      echo "  MISMATCH: $file has $actual (expected $canonical)"
      mismatched=$((mismatched + 1))
    else
      echo "  ok:       $file"
    fi
  done

  if [[ "$mismatched" -gt 0 ]]; then
    echo "FAIL: $mismatched/$checked file(s) have mismatched versions"
    echo "  Run: doc-tools.sh bump-version $canonical"
    exit 1
  fi

  echo "PASS: all $checked file(s) match v$canonical"
}

# --- Fragments subcommand ---

# Compute SHA-256 of bytes from line 3 onwards of a fragment file.
_fragment_payload_sha256() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    tail -n +3 "$path" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    tail -n +3 "$path" | shasum -a 256 | awk '{print $1}'
  else
    echo "no sha256 tool available" >&2
    return 1
  fi
}

# Extract the line-2 hash from a fragment file (returns empty if missing).
_fragment_stored_hash() {
  local path="$1"
  sed -n '2p' "$path" \
    | grep -oE '^<!-- doc-superpowers:hash [a-f0-9]+ -->$' \
    | awk '{print $3}'
}

# Extract the integer N from a fragment filename "PR-<N>.md".
# Returns empty string if filename is not "PR-<digits>.md".
_fragment_pr_number() {
  local path="$1"
  local base
  base=$(basename "$path" .md)
  if [[ "$base" =~ ^PR-([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Parse section headings from a fragment body (line 3 onwards).
# Emits one heading per line, with the leading "### " stripped (full heading text).
# Accepts any heading text (single or multi-word).
_fragment_section_headings() {
  local path="$1"
  tail -n +3 "$path" | grep -E '^###[[:space:]]+.+' | sed -E 's/^###[[:space:]]+//'
}

# Backward-compat shim used by cmd_fragments_list — emits unique section headings.
_fragment_section_names() {
  _fragment_section_headings "$1" | sort -u
}

cmd_fragments_list() {
  local dir="RELEASE-NOTES.next"
  if [[ ! -d "$dir" ]]; then
    echo "[]"
    return 0
  fi
  local out="[]"
  local found=0
  for path in "$dir"/PR-*.md; do
    [[ -f "$path" ]] || continue
    local n hash_stored hash_actual hash_valid sections_json
    n=$(_fragment_pr_number "$path")
    if [[ -z "$n" ]]; then
      echo "WARN: skipping non-numeric fragment filename: $path" >&2
      continue
    fi
    found=1
    hash_stored=$(_fragment_stored_hash "$path")
    hash_actual=$(_fragment_payload_sha256 "$path")
    if [[ "$hash_stored" = "$hash_actual" ]] && [[ -n "$hash_stored" ]]; then
      hash_valid="true"
    else
      hash_valid="false"
    fi
    sections_json=$(_fragment_section_names "$path" \
      | jq -R -s 'split("\n") | map(select(length > 0))')
    out=$(printf '%s' "$out" | jq \
      --argjson n "$n" \
      --arg path "$path" \
      --arg hash_stored "$hash_stored" \
      --arg hash_actual "$hash_actual" \
      --arg hash_valid "$hash_valid" \
      --argjson sections "$sections_json" \
      '. += [{pr_number: $n, path: $path, hash_stored: $hash_stored, hash_actual: $hash_actual, hash_valid: ($hash_valid == "true"), sections: $sections}]'
    )
  done
  if [[ "$found" -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$out" | jq 'sort_by(.pr_number)'
}

cmd_fragments_validate() {
  local path="$1"
  if [[ -z "$path" ]]; then
    echo "Usage: $0 fragments validate <path>" >&2
    return 2
  fi
  if [[ ! -f "$path" ]]; then
    echo "ERROR: fragment not found: $path" >&2
    return 2
  fi
  local stored actual
  stored=$(_fragment_stored_hash "$path")
  actual=$(_fragment_payload_sha256 "$path")
  if [[ -z "$stored" ]]; then
    echo "ERROR: no hash marker on line 2 of $path" >&2
    return 1
  fi
  if [[ "$stored" = "$actual" ]]; then
    echo "valid: $path"
    return 0
  fi
  echo "drifted: $path (stored=$stored, actual=$actual)" >&2
  return 1
}

cmd_fragments_merge() {
  local range_start="$1" range_end="$2"
  local paths_out_file=""
  # Optional --paths-out=<file>: write one consumed-fragment path per line.
  # Lets callers (e.g., SKILL.md step 9) `git rm` only the fragments that were
  # actually merged, instead of globbing PR-*.md unconditionally.
  if [[ "${3:-}" == --paths-out=* ]]; then
    paths_out_file="${3#--paths-out=}"
    : > "$paths_out_file"
  fi
  if [[ -z "$range_start" ]] || [[ -z "$range_end" ]]; then
    echo "Usage: $0 fragments merge <range-start> <range-end> [--paths-out=<file>]" >&2
    return 2
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: fragments merge must be run inside a git repo" >&2
    return 2
  fi
  local dir="RELEASE-NOTES.next"
  if [[ ! -d "$dir" ]]; then
    return 0  # Empty output is valid (no fragments)
  fi

  # Collect fragments whose introducing commit is in the range.
  local -a included_paths=()
  for path in "$dir"/PR-*.md; do
    [[ -f "$path" ]] || continue
    # Skip non-numeric PR filenames (defensive — see cmd_fragments_list).
    local n
    n=$(_fragment_pr_number "$path")
    if [[ -z "$n" ]]; then
      echo "WARN: skipping non-numeric fragment filename: $path" >&2
      continue
    fi
    # Find the commit that introduced this fragment (oldest commit touching it).
    local introduced
    introduced=$(git log --format="%H" --reverse -- "$path" 2>/dev/null | head -n 1)
    if [[ -z "$introduced" ]]; then
      # Untracked; skip with a warning.
      echo "WARN: $path is not tracked; skipping" >&2
      continue
    fi
    # Check if `introduced` is in `range_start..range_end` (exclusive of range_start).
    if git merge-base --is-ancestor "$introduced" "$range_end" 2>/dev/null \
       && ! git merge-base --is-ancestor "$introduced" "$range_start" 2>/dev/null; then
      included_paths+=("$path")
    fi
  done

  if [[ "${#included_paths[@]}" -eq 0 ]]; then
    return 0
  fi

  # Sort by integer PR number.
  local -a sorted
  # shellcheck disable=SC2207
  sorted=($(for p in "${included_paths[@]}"; do
    printf "%s\t%s\n" "$(_fragment_pr_number "$p")" "$p"
  done | sort -n -k1,1 | awk -F'\t' '{print $2}'))

  # Section storage: any heading is accepted. Canonical Keep-a-Changelog
  # sections emit in a fixed order; non-canonical sections emit after, in
  # first-seen order.
  #
  # bash 3.2 — macOS's /bin/bash, frozen at the last GPLv2 release and the
  # interpreter this repo supports — has no associative arrays at all, so
  # `local -A` aborts the script outright ("local: -A: invalid option"). The
  # section map is therefore two parallel indexed arrays with a linear lookup.
  # Section counts are single-digit in practice (7 canonical plus the rare
  # custom heading), so the O(n) scan is noise next to the per-fragment git
  # calls above.
  local -a canonical_order=(Added Changed Deprecated Removed Fixed Security Dependencies)
  local -a section_names=()
  local -a section_bodies=()
  local -a non_canonical_seen=()
  local s

  # True when $1 is one of the canonical Keep-a-Changelog headings.
  _is_canonical_section() {
    local want="$1" c
    for c in "${canonical_order[@]}"; do
      [ "$c" = "$want" ] && return 0
    done
    return 1
  }

  # Locate $1 in section_names, setting _section_idx to its index (or -1).
  # Sets a variable instead of echoing so the per-line body loop below stays
  # fork-free.
  _section_find() {
    local want="$1"
    _section_idx=0
    while [ "$_section_idx" -lt "${#section_names[@]}" ]; do
      [ "${section_names[$_section_idx]}" = "$want" ] && return 0
      _section_idx=$((_section_idx + 1))
    done
    _section_idx=-1
    return 1
  }
  local _section_idx=-1

  for path in "${sorted[@]}"; do
    # Validate hash; include drifted fragments anyway (human edits authoritative)
    # but warn on stderr.
    if ! cmd_fragments_validate "$path" >/dev/null 2>&1; then
      echo "WARN: including drifted fragment $path (human edits are authoritative)" >&2
    fi
    # Parse sections out of the fragment body (line 3 onwards). Accept any
    # heading text after "### " (single or multi-word).
    local current_section=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        # Track non-canonical headings in first-seen order. The array is empty
        # on the first such heading, and bash 3.2 treats an unguarded
        # "${arr[@]}" on an empty array as an unbound variable under `set -u`
        # — hence the "${arr[@]+…}" guard (same idiom as cmd_check_freshness).
        if ! _is_canonical_section "$current_section"; then
          local already_seen=0
          local seen
          for seen in "${non_canonical_seen[@]+"${non_canonical_seen[@]}"}"; do
            if [[ "$seen" = "$current_section" ]]; then
              already_seen=1
              break
            fi
          done
          if [[ "$already_seen" -eq 0 ]]; then
            non_canonical_seen+=("$current_section")
          fi
        fi
        continue
      fi
      if [[ -n "$current_section" ]] && [[ -n "$line" ]]; then
        if ! _section_find "$current_section"; then
          section_names+=("$current_section")
          section_bodies+=("")
          _section_idx=$(( ${#section_names[@]} - 1 ))
        fi
        section_bodies[$_section_idx]+="${line}"$'\n'
      fi
    done < <(tail -n +3 "$path")

    if [[ -n "$paths_out_file" ]]; then
      printf '%s\n' "$path" >> "$paths_out_file"
    fi
  done

  # Emit canonical sections first (fixed order), then non-canonical (first-seen).
  # Dedupe bullets within each section, preserving first-occurrence order.
  _emit_section() {
    local section="$1"
    if ! _section_find "$section"; then
      return 0
    fi
    local body="${section_bodies[$_section_idx]}"
    if [[ -z "$body" ]]; then
      return 0
    fi
    local deduped
    deduped=$(printf '%s' "$body" | awk '!seen[$0]++')
    printf '### %s\n%s\n' "$section" "$deduped"
  }

  for s in "${canonical_order[@]}"; do
    _emit_section "$s"
  done
  # Guarded: this array is empty whenever every heading was canonical, which is
  # the common case — unguarded it aborts under bash 3.2 + `set -u`.
  for s in "${non_canonical_seen[@]+"${non_canonical_seen[@]}"}"; do
    _emit_section "$s"
  done
}

cmd_set_implementation() {
    # Append/update a single Implementation: ref in a doc.
    # Usage: doc-tools.sh set-implementation <path> --ref <kind: ref> --status <status> [--note <note>]
    local FILE="" REF="" STATUS="" NOTE=""
    local VALID_STATUSES="complete partial in-progress not-started reverted superseded blocked"

    if [[ $# -eq 0 ]]; then
        echo "Usage: set-implementation <path> --ref <kind: ref> --status <status> [--note <note>]" >&2
        exit 2
    fi

    # Positional: path
    FILE="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref) REF="$2"; shift 2 ;;
            --status) STATUS="$2"; shift 2 ;;
            --note) NOTE="$2"; shift 2 ;;
            *) echo "Unknown arg: $1" >&2; exit 2 ;;
        esac
    done

    if [[ -z "$FILE" || -z "$REF" || -z "$STATUS" ]]; then
        echo "Usage: set-implementation <path> --ref <kind: ref> --status <status> [--note <note>]" >&2
        exit 2
    fi
    if [[ ! -f "$FILE" ]]; then
        echo "ERROR: file not found: $FILE" >&2
        exit 2
    fi
    # Validate status enum
    if ! echo " $VALID_STATUSES " | grep -q " $STATUS "; then
        echo "invalid status: $STATUS (allowed: $VALID_STATUSES)" >&2
        exit 2
    fi

    # Build the new line
    local new_line
    if [[ -n "$NOTE" ]]; then
        new_line="  - ${REF} — ${STATUS} — ${NOTE}"
    else
        new_line="  - ${REF} — ${STATUS}"
    fi

    # Resolve a GNU-compatible sed (macOS: gsed; Linux: sed).
    local SED
    SED=$(gnu_sed)

    # If the ref already exists in the file's Implementation block, replace its line.
    # Escape regex metachars in REF for grep/sed safety.
    local ref_escaped
    ref_escaped=$(printf '%s' "$REF" | sed 's/[][\/.^$*]/\\&/g')
    if grep -qE "^  - ${ref_escaped} —" "$FILE"; then
        "$SED" -i "s|^  - ${ref_escaped} —.*$|${new_line}|" "$FILE"
    else
        # Append after last existing Implementation block line, OR
        # create new Implementation: block if absent.
        if grep -q "^Implementation:" "$FILE"; then
            local last_bullet
            last_bullet=$(awk '
                /^Implementation:/ { in_block=1; last_line=NR; next }
                in_block && /^  -/ { last_line=NR; next }
                in_block && /^[^[:space:]]|^$/ { in_block=0 }
                END { print last_line }
            ' "$FILE")
            "$SED" -i "${last_bullet}a\\
${new_line}" "$FILE"
        else
            # Append a new Implementation: block after the Date: line
            "$SED" -i "/^\*\*Date:\*\*/a\\
\\
Implementation:\\
${new_line}" "$FILE"
        fi
    fi
}

cmd_implementation_status() {
    # Parse Implementation: YAML field from one or more docs.
    # Usage: doc-tools.sh implementation-status [--filter <status>[,<status>...]] <path> [<path>...]
    local FILTER=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter) FILTER="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    local path block filter_re
    for path in "$@"; do
        if [[ ! -f "$path" ]]; then
            echo "$path: not found" >&2
            continue
        fi
        # Find the Implementation: block — from the line matching '^Implementation:' to the next blank line or non-indented line
        block=$(awk '
            /^Implementation:[[:space:]]*\[\][[:space:]]*$/ { print "(empty)"; exit 0 }
            /^Implementation:[[:space:]]*$/ { capture=1; next }
            capture && /^[[:space:]]+-/ { print; next }
            capture && /^[[:space:]]*$/ { exit 0 }
            capture && /^[^[:space:]]/ { exit 0 }
        ' "$path")

        if [[ -z "$block" ]]; then
            echo "$path: no Implementation field"
            continue
        fi
        if [[ "$block" == "(empty)" ]]; then
            echo "$path: Implementation: [] (intentionally empty)"
            continue
        fi

        echo "$path:"
        if [[ -n "$FILTER" ]]; then
            # Filter to refs whose status matches one of FILTER's comma-separated values
            filter_re=$(echo "$FILTER" | sed 's/,/|/g')
            echo "$block" | rg -- " (${filter_re}) " | sed 's/^/  /'
        else
            echo "$block" | sed 's/^/  /'
        fi
    done
}

# --- `tools` subcommand: vendor/uninstall/status doc-tools.sh itself ---

# Source of truth: SCRIPT_DIR points at the directory containing the running
# script. Use that as the "plugin copy" — when this script lives in a plugin
# cache, the plugin copy is the one being executed; when it lives in
# .github/scripts/ (already-vendored), `tools install` becomes a no-op
# self-copy which is still valid.
_tools_plugin_source() {
  echo "$SCRIPT_DIR/doc-tools.sh"
}

_tools_plugin_helpers_dir() {
  # Helpers live under scripts/hooks/ci/doc-pr-release/ in the plugin source
  # tree. When the script has been vendored to .github/scripts/, there are no
  # helpers next to it — return empty so callers can skip gracefully.
  local candidate="$SCRIPT_DIR/hooks/ci/doc-pr-release"
  [[ -d "$candidate" ]] && echo "$candidate" || echo ""
}

cmd_tools() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    install)   _tools_install "$@" ;;
    uninstall) _tools_uninstall "$@" ;;
    status)    _tools_status "$@" ;;
    ""|--help) cat >&2 <<'EOF'
Usage:
  doc-tools.sh tools install   [--dest <path>] [--with-helpers]
  doc-tools.sh tools uninstall [--dest <path>]
  doc-tools.sh tools status    [--dest <path>]

--dest defaults to .github/scripts (project-relative).
--with-helpers also installs doc-pr-release/*.sh + RELEASE-NOTES.next/README.md
EOF
      exit 1 ;;
    *) echo "Unknown tools sub-command: $sub" >&2; exit 2 ;;
  esac
}

_tools_install() {
  local dest=".github/scripts"
  local with_helpers=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      --with-helpers) with_helpers=true; shift ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local src
  src="$(_tools_plugin_source)"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: source doc-tools.sh not found at $src" >&2
    exit 1
  fi

  mkdir -p "$dest"
  cp "$src" "$dest/doc-tools.sh"
  chmod +x "$dest/doc-tools.sh"
  echo "Installed doc-tools.sh → $dest/doc-tools.sh"

  if [[ "$with_helpers" == "true" ]]; then
    local helpers_src
    helpers_src="$(_tools_plugin_helpers_dir)"
    if [[ -z "$helpers_src" ]]; then
      echo "WARN: --with-helpers requested but plugin helpers dir not found." >&2
      echo "      (Are you running from a vendored copy? Re-run from plugin source.)" >&2
    else
      mkdir -p "$dest/doc-pr-release"
      local helpers_installed=0
      for helper in "$helpers_src"/*.sh; do
        [[ -f "$helper" ]] || continue
        cp "$helper" "$dest/doc-pr-release/$(basename "$helper")"
        chmod +x "$dest/doc-pr-release/$(basename "$helper")"
        helpers_installed=$((helpers_installed + 1))
      done
      echo "Installed $helpers_installed doc-pr-release helpers → $dest/doc-pr-release/"

      # RELEASE-NOTES.next/README.md — never overwrite (user may have edits).
      if [[ -f "$helpers_src/RELEASE-NOTES.next.README.md" ]] \
         && [[ ! -f "RELEASE-NOTES.next/README.md" ]]; then
        mkdir -p RELEASE-NOTES.next
        cp "$helpers_src/RELEASE-NOTES.next.README.md" \
           "RELEASE-NOTES.next/README.md"
        echo "Created RELEASE-NOTES.next/README.md (fragment format spec)"
      fi
    fi
  fi
}

_tools_uninstall() {
  local dest=".github/scripts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local removed=0
  if [[ -f "$dest/doc-tools.sh" ]]; then
    rm "$dest/doc-tools.sh"
    echo "Removed $dest/doc-tools.sh"
    removed=$((removed + 1))
  fi

  # Best-effort helper cleanup: only remove if files match the plugin copy
  # byte-for-byte (no local edits). The `RELEASE-NOTES.next/README.md` is
  # intentionally NOT removed — it may have user-authored fragment edits.
  local helpers_src
  helpers_src="$(_tools_plugin_helpers_dir)"
  if [[ -d "$dest/doc-pr-release" ]] && [[ -n "$helpers_src" ]]; then
    local has_local_edits=false
    for installed in "$dest/doc-pr-release"/*.sh; do
      [[ -f "$installed" ]] || continue
      local plugin_copy="$helpers_src/$(basename "$installed")"
      if [[ ! -f "$plugin_copy" ]] \
         || ! cmp -s "$plugin_copy" "$installed"; then
        has_local_edits=true
        break
      fi
    done
    if [[ "$has_local_edits" == "true" ]]; then
      echo "Kept $dest/doc-pr-release/ (contains local edits or unknown files)"
    else
      rm -rf "$dest/doc-pr-release"
      echo "Removed $dest/doc-pr-release/"
      removed=$((removed + 1))
    fi
  fi

  # Clean up empty parent dir.
  rmdir "$dest" 2>/dev/null || true

  if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to uninstall at $dest"
  fi
  return 0
}

_tools_status() {
  local dest=".github/scripts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local installed="$dest/doc-tools.sh"
  local plugin
  plugin="$(_tools_plugin_source)"

  if [[ ! -f "$installed" ]]; then
    echo "doc-tools.sh: not installed at $dest"
    return 0
  fi

  if cmp -s "$plugin" "$installed"; then
    echo "doc-tools.sh: installed at $dest (matches plugin v$( _tools_extract_version ))"
  else
    echo "doc-tools.sh: installed at $dest (DRIFTED from plugin source)"
  fi

  # Helper-presence summary.
  if [[ -d "$dest/doc-pr-release" ]]; then
    local helper_count
    helper_count=$(find "$dest/doc-pr-release" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
    echo "doc-pr-release helpers: $helper_count installed at $dest/doc-pr-release/"
  else
    echo "doc-pr-release helpers: not installed at $dest"
  fi
  if [[ -f "RELEASE-NOTES.next/README.md" ]]; then
    echo "RELEASE-NOTES.next/README.md: present"
  else
    echo "RELEASE-NOTES.next/README.md: not present"
  fi
}

# Best-effort: parse version from RELEASE-NOTES.md.
# Looks in two places, in order:
#   1. $SCRIPT_DIR/../RELEASE-NOTES.md (canonical plugin layout: scripts/doc-tools.sh
#      + RELEASE-NOTES.md at repo root).
#   2. <git-toplevel>/RELEASE-NOTES.md (vendored case: .github/scripts/doc-tools.sh
#      within a consuming repo — only useful if that repo also versions its docs
#      with the same convention; otherwise falls through to "unknown").
# Prints "unknown" if neither resolves.
_tools_extract_version() {
  local candidate version
  for candidate in \
    "$(dirname "$SCRIPT_DIR")/RELEASE-NOTES.md" \
    "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)/RELEASE-NOTES.md"; do
    [[ -f "$candidate" ]] || continue
    version=$(grep -m 1 -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' "$candidate" \
              | sed 's/## v//')
    if [[ -n "$version" ]]; then
      echo "$version"
      return
    fi
  done
  echo "unknown"
}

# --- Main ---

check_deps
_traps

case "${1:-}" in
  build-index)      shift; cmd_build_index "$@" ;;
  check-freshness)  shift; cmd_check_freshness "$@" ;;
  update-index)     shift; cmd_update_index "$@" ;;
  add-entry)        shift; cmd_add_entry "$@" ;;
  remove-entry)     shift; cmd_remove_entry "$@" ;;
  move-entry)       shift; cmd_move_entry "$@" ;;
  deprecate-entry)  shift; cmd_deprecate_entry "$@" ;;
  status)           shift; cmd_status "$@" ;;
  bump-version)     shift; cmd_bump_version "$@" ;;
  check-version)    shift; cmd_check_version "$@" ;;
  implementation-status) shift; cmd_implementation_status "$@" ;;
  set-implementation) shift; cmd_set_implementation "$@" ;;
  fragments)
    shift
    case "${1:-}" in
      list)
        cmd_fragments_list
        ;;
      validate)
        cmd_fragments_validate "${2:-}"
        ;;
      merge)
        cmd_fragments_merge "${2:-}" "${3:-}" "${4:-}"
        ;;
      *)
        echo "Usage: $0 fragments {list|validate <path>|merge <range-start> <range-end> [--paths-out=<file>]}" >&2
        exit 2
        ;;
    esac
    ;;
  tools)            shift; cmd_tools "$@" ;;
  --help|"")        usage ;;
  *)                usage ;;
esac

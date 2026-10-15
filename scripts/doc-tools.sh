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
    [0123456789]*.[0123456789]*) ;;
    *) return 0 ;;
  esac
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%[!0123456789]*}"
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

# SHA-256 of a file's bytes into _HASH as "sha256:<hex>" — one process, no
# subshell. The file is read on stdin, never named on the command line: as an
# argument, a name containing "\" made GNU sha256sum / shasum prefix the digest
# with "\" (invalid index JSON), and a doc named "-" hashed stdin itself — in
# check-freshness that drained the record stream the loop was reading.
_hash_one() {
  if command -v sha256sum >/dev/null 2>&1; then
    _HASH=$(sha256sum < "$1") || _die "cannot hash $1"
  else
    _HASH=$(shasum -a 256 < "$1") || _die "cannot hash $1"
  fi
  _HASH="sha256:${_HASH%% *}"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Remove leading/trailing whitespace from $1 into _TRIMMED (no subshell).
_trim() {
  _TRIMMED="${1#"${1%%[![:space:]]*}"}"
  _TRIMMED="${_TRIMMED%"${_TRIMMED##*[![:space:]]}"}"
}

# --- git ------------------------------------------------------------------------
#
# Every git call's exit status is checked: a failed call is an error, never "no
# history". (Outside a repository, check-freshness used to report every doc
# current with rc 0, because each `git log … || true` read as "never changed".)
# The dispatcher refuses a repository verb outside a work tree up front, so the
# one legitimate "no history" left is an unborn HEAD. Plumbing (rev-list,
# rev-parse), never porcelain `git log`: porcelain honours user config such as
# log.showSignature, which prefixed code_commit with "No signature\n".

_HEAD=""        # this run's HEAD commit; "" on an unborn branch
_HEAD_DONE=0

# Resolve HEAD once per run, so every lookup in the run sees the same commit.
_head_init() {
  [ "$_HEAD_DONE" = 0 ] || return 0
  local rc=0
  _HEAD=$(git rev-parse --verify -q 'HEAD^{commit}') || rc=$?
  case "$rc" in
    0) ;;
    1) _HEAD="" ;;   # unborn HEAD: no commits yet
    *) _die "git rev-parse HEAD failed (rc=$rc)" ;;
  esac
  _HEAD_DONE=1
}

# True if $1 is a full hex object id (SHA-1 or SHA-256). A stored code_commit
# is only ever handed to git after this check: an index value such as
# "--output=x" otherwise reached `git rev-list` as an option and wrote a file.
_is_oid() {
  # An explicit list, not [0-9a-f]: bash 3.2 matches a bracket RANGE by the
  # locale's collation order, so a-f could admit other letters.
  case "$1" in
    ''|*[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

# The newest commit reachable from HEAD that touches any of the given
# pathspecs, into _LAST ("" when none has, or HEAD is unborn). The refs follow
# `--`, so none can be read as an option. Dies if git fails. Pre-v3 (legacy)
# entries only: their refs are git pathspecs, glob characters included.
_git_last_commit() {
  _LAST=""
  [ $# -gt 0 ] || return 0
  _head_init
  [ -n "$_HEAD" ] || return 0
  _LAST=$(git rev-list -1 "$_HEAD" -- "$@") || _die "git rev-list failed for code refs: $*"
}

# Commits in <base>..HEAD touching the refs, into _BEHIND; "" (reported as
# null) when <base> is not reachable from HEAD: the repository does not have
# it (a squash-merged branch deleted, a shallow clone), or it is not an
# ancestor of HEAD (only the re-baseline commit was cherry-picked, a branch that
# never merged). `rev-list --count <base>..HEAD` answers 0 or a count of
# unrelated commits there — a masked 0, the same as "not behind". Any other
# git failure dies. <base> must pass _is_oid. With --literal first, the refs
# are literal paths (schema v3 entries); otherwise pathspecs. The ancestry
# answer is kept per commit (_ANCESTORS / _NOT_ANCESTORS), so docs sharing a
# baseline cost one merge-base between them.
_ANCESTORS=" "
_NOT_ANCESTORS=" "
_git_commits_behind() {
  local literal=() rc=0
  if [ "$1" = --literal ]; then
    literal=(--literal-pathspecs)
    shift
  fi
  local base="$1"
  shift
  _BEHIND=0
  [ $# -gt 0 ] || return 0
  _head_init
  [ -n "$_HEAD" ] || return 0
  case "$_NOT_ANCESTORS" in
    *" $base "*) _BEHIND=""; return 0 ;;
  esac
  case "$_ANCESTORS" in
    *" $base "*) ;;
    *)
      git merge-base --is-ancestor "$base" "$_HEAD" 2>/dev/null || rc=$?
      case "$rc" in
        0) _ANCESTORS="$_ANCESTORS$base " ;;
        1) _NOT_ANCESTORS="$_NOT_ANCESTORS$base "; _BEHIND=""; return 0 ;;
        *)
          if git cat-file -e "$base^{commit}" 2>/dev/null; then
            _die "git merge-base --is-ancestor $base HEAD failed"
          fi
          _NOT_ANCESTORS="$_NOT_ANCESTORS$base "
          _BEHIND=""
          return 0
          ;;
      esac
      ;;
  esac
  _BEHIND=$(git ${literal[@]+"${literal[@]}"} rev-list --count "$base..$_HEAD" -- "$@") \
    || _die "git rev-list --count $base..HEAD failed for code refs: $*"
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

# Normalize a doc path to the working-tree-relative form used as the index key,
# into _NORM (no subshell). On failure prints an error to stderr and returns 1
# so callers can refuse to write.
#
# A path may not start with "-" (it would read as an option to a later tool),
# and "//" collapses to "/" (`docs//a.md` was stored as a second key for the
# same file). Otherwise an ordinary relative path — the documented input — is
# passed through byte-identically and never touches the filesystem.
_norm_path() {
  local raw="$1"
  local ctx="${2:-doc path}"
  _NORM=""

  if [ -z "$raw" ]; then
    echo "ERROR: empty $ctx." >&2
    return 1
  fi
  case "$raw" in
    -*)
      echo "ERROR: $ctx '$raw' starts with '-'; index paths may not (it would read as an option)." >&2
      return 1
      ;;
  esac
  local dd='//' s='/'
  while :; do
    case "$raw" in
      *//*) raw="${raw//$dd/$s}" ;;
      *) break ;;
    esac
  done

  case "$raw" in
    /*) ;;
    *)
      # Fast path: already in key form.
      _has_dot_segment "$raw" || { _NORM="$raw"; return 0; }
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

  _NORM="$rel"
}

# Printing form of _norm_path: $(normalize_doc_path <path> [context]).
normalize_doc_path() {
  _norm_path "$@" || return 1
  printf '%s' "$_NORM"
}

# Print the entries of the argument list that occur more than once (byte
# comparison), one per line; nothing when there are none. One sort, so a
# repeat check stays O(n log n) — a newline-framed `case` membership test per
# item is quadratic (4,000 keys: 34 s on bash 5, 109 s on bash 3.2).
_repeated() {
  [ $# -gt 1 ] || return 0
  printf '%s\n' "$@" | LC_ALL=C sort | LC_ALL=C uniq -d
}

# _first_occurrences <repeated-set> <item>… — the items minus every repeat of
# an item listed in <repeated-set> (the output of _repeated), into _FIRST.
_first_occurrences() {
  local dups=$'\n'"$1"$'\n' seen=$'\n' item
  shift
  _FIRST=()
  for item in "$@"; do
    case "$dups" in
      *$'\n'"$item"$'\n'*)
        case "$seen" in
          *$'\n'"$item"$'\n'*) continue ;;
        esac
        seen="$seen$item"$'\n'
        ;;
    esac
    _FIRST+=("$item")
  done
}

# Normalize every path argument into _TARGETS, dying on the first bad one, and
# drop repeats: `remove-entry a.md a.md` (or docs/a.md plus docs//a.md) names
# ONE entry, and must be reported once.
#
# bash 3.2 copies the CALLER's positional parameters on every function call,
# so a loop that calls a function while "$@" holds k paths is O(k²): 4,000
# paths took 2.4 s here, against 0.05 s once "$@" is moved into an array and
# cleared. Verbs taking many paths do the same (set -- once _TARGETS is set).
_targets_from_args() {
  local raw norm=() args=("$@")
  set --
  _TARGETS=()
  for raw in ${args[@]+"${args[@]}"}; do
    _norm_path "$raw" || exit 1
    norm+=("$_NORM")
  done
  [ ${#norm[@]} -gt 0 ] || return 0
  _first_occurrences "$(_repeated "${norm[@]}")" "${norm[@]}"
  _TARGETS=("${_FIRST[@]}")
}

# --- Content identity (index schema v3) ----------------------------------------
#
# A doc is stale when the CONTENT of one of its code refs differs from what was
# recorded at its baseline. Before schema v3 it was stale when the newest
# commit touching the refs had a different id from the stored code_commit —
# and a commit id is a poor proxy for content: squash merges, rebase-merges,
# cherry-picks and reverts mint new ids for identical bytes; a shallow clone's
# graft poses as the last commit; a commit cannot contain its own id, so
# re-baselining a doc in the same commit as the code never matched; and every
# doc paid its own history walks (O(N·H): 117 s at N=4,000 docs, H=3,000
# commits).
#
# Writers (build-index, add-entry, update-index) store per ref the git object
# id of its content — a blob for a file, a tree for a directory, the commit
# for a submodule, "missing" when there is none — in code_oids, captured from the WORKING TREE, which is
# what the doc was read against, staged or not (through a private index: git's own is
# never touched). Readers (check-freshness, status) look every ref up in HEAD,
# or in the tree given with --tree (pre-commit passes the staged tree, `git
# write-tree`), with ONE `git cat-file --batch-check` for the whole index:
# stale ⇔ some ref's object id differs. With --tree the index and the docs are
# read from that tree too (_reader_snapshot): one snapshot, never the working
# copy's index against the staged refs.
#
#   - Refs are literal paths: a file, a directory, or "." (the repository
#     root). Git sees them with --literal-pathspecs; a ref containing * ? or [
#     is warned about when written, and names only a path of exactly that name.
#   - The doc-index itself (docs/.doc-index.json, its lock and tmp files) is
#     not part of any ref's content: a ref covering docs/ or "." would
#     otherwise change with every index write, and could never read current.
#   - code_commit (the newest commit touching the refs) is still written, for
#     display, for commits_behind and for older readers — but not in a shallow
#     clone, whose truncated history names the graft (null + a warning; the
#     object ids are exact there).
#   - commits_behind and code_refs_changed are computed for stale docs only.
#     code_refs_changed is exactly the refs whose object id differs;
#     commits_behind is `git rev-list --count <code_commit>..HEAD -- <refs>`,
#     one per distinct stale (code_commit, refs) pair, and null when that
#     commit is not an ancestor of HEAD here (absent, or on another line of
#     history) — never a masked 0.
#   - An entry without code_oids (written before v3) is judged by the old
#     commit logic — its refs as git pathspecs, globs included — until a
#     writer records its code_oids. The first write bumps schema_version to 3.

_SCHEMA_VERSION=3

# awk functions shared by every step that turns a stored ref into a path git
# sees, so writers and readers cannot disagree on one:
#   refpath(r)  "" and "." segments dropped (so "//", "./" and a trailing "/"
#               fold away), "." for the root, and "" for a ref with a ".."
#               segment, which must reach no lookup (git cat-file
#               --batch-check dies on a path outside the repository)
#   covers(p)   whether path p contains the doc-index (-v ix=): the root or a
#               directory above it
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_REFPATH='
  function refpath(r,   n, i, s, out) {
    n = split(r, s, "/")
    out = ""
    for (i = 1; i <= n; i++) {
      if (s[i] == "" || s[i] == ".") continue
      if (s[i] == "..") return ""
      out = (out == "" ? s[i] : out "/" s[i])
    }
    return out == "" ? "." : out
  }
  function covers(p) { return p == "." || index(ix "/", p "/") == 1 }
'

# Whether this is a shallow clone, into _SHALLOW (true|false); once per run.
_SHALLOW=""
_shallow_init() {
  [ -z "$_SHALLOW" ] || return 0
  _SHALLOW=$(git rev-parse --is-shallow-repository) || _die "git rev-parse --is-shallow-repository failed"
}

# Drop docs/.doc-index.json, its lock directory and its tmp files from the
# private index $1. Glob pathspecs, on purpose: the tmp names are random.
_drop_index_family() {
  GIT_INDEX_FILE="$1" git rm -r -f -q --cached --ignore-unmatch -- \
    ":(glob)$INDEX_FILE*" ":(glob)$INDEX_FILE*/**" >/dev/null \
    || _die "cannot drop $INDEX_FILE from a private index"
}

# Tree $1 without the doc-index family, into _SAN_TREE (a private index).
_sanitized_tree() {
  local idx="$_SCRATCH/sanitize.index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree "$1" || _die "git read-tree $1 failed"
  _drop_index_family "$idx"
  _SAN_TREE=$(GIT_INDEX_FILE="$idx" git write-tree) || _die "git write-tree failed"
}

# _oid_lookup <tree> <refs-file> <out-file> <sanitize 0|1> [<trees-file>]
# The object id of each ref (one per line of <refs-file>, as stored) in
# <tree> — or, given <trees-file>, in that line's own tree-ish (one per line,
# aligned with <refs-file>; <tree> is then ignored) — one line each in
# <out-file>: "missing" where the tree has no such path. ONE git cat-file
# --batch-check for all of them. With <sanitize> 1, a ref covering the
# doc-index is looked up in its tree minus the index family (a working-tree
# capture lacks it already). The normalized paths are left line-aligned in
# <out-file>.paths.
_oid_lookup() {
  local tree="$1" in="$2" out="$3" sanitize="$4" trees="${5:-}" rc=0 t
  : > "$out"
  : > "$out.paths"
  [ -s "$in" ] || return 0
  if [ -z "$trees" ]; then
    trees="$out.trees"
    awk -v t="$tree" '{ print t }' "$in" > "$trees" || _die "cannot read the code refs"
  fi
  awk -v ix="$INDEX_FILE" "$_AWK_REFPATH"'
    { p = refpath($0); print p; if (covers(p)) c = 1 }
    END { exit c ? 3 : 0 }' "$in" > "$out.paths" || rc=$?
  case "$rc" in
    0) ;;
    3)
      if [ "$sanitize" = 1 ]; then
        # Each distinct tree holding a covering ref is sanitized once; the
        # covering lines then read that copy.
        awk -v ix="$INDEX_FILE" "$_AWK_REFPATH"'
          FILENAME == ARGV[1] { t[FNR] = $0; next }
          covers($0) && !(t[FNR] in s) { s[t[FNR]] = 1; print t[FNR] }' "$trees" "$out.paths" > "$out.cov" \
          || _die "cannot read the code refs"
        while IFS= read -r t; do
          _sanitized_tree "$t"
          printf '%s\t%s\n' "$t" "$_SAN_TREE"
        done < "$out.cov" > "$out.san"
        awk -v ix="$INDEX_FILE" "$_AWK_REFPATH"'
          FILENAME == ARGV[1] { i = index($0, "\t"); m[substr($0, 1, i - 1)] = substr($0, i + 1); next }
          FILENAME == ARGV[2] { t[FNR] = $0; next }
          { print (covers($0) && (t[FNR] in m)) ? m[t[FNR]] : t[FNR] }' \
          "$out.san" "$trees" "$out.paths" > "$out.strees" || _die "cannot read the code refs"
        trees="$out.strees"
      fi
      ;;
    *) _die "cannot read the code refs" ;;
  esac
  # batch-check answers "<id>" for a found object and "<name> missing" (or
  # "ambiguous") otherwise; anything but a bare object id reads as missing
  # here, and is re-resolved below. An empty line (a ".." ref) is answered
  # " missing".
  awk 'FILENAME == ARGV[1] { t[FNR] = $0; next }
       { if ($0 == "") print ""; else if ($0 == ".") print t[FNR] ":"; else print t[FNR] ":" $0 }' \
      "$trees" "$out.paths" \
    | git cat-file --batch-check='%(objectname)' \
    | awk '{ if ((length($0) == 40 || length($0) == 64) && $0 !~ /[^0123456789abcdef]/) print; else print "missing" }' \
      > "$out" || _die "git cat-file --batch-check failed"

  # A path batch-check could not resolve can still be an entry of its tree
  # whose object this repository does not hold: a submodule (gitlink) — its
  # commit lives in the submodule's store, and git answers "missing" (newer
  # git: "<id> submodule") — or an object a partial clone has not fetched. The
  # entry's own id is its identity, so ONE `git ls-tree` per distinct tree
  # (one in all but the writers' per-doc baselines) over every such path
  # resolves them (a submodule bump then reads stale, as it did before v3).
  local miss="$out.miss" ls="$out.ls"
  awk 'FILENAME == ARGV[1] { p[FNR] = $0; next }
       FILENAME == ARGV[2] { t[FNR] = $0; next }
       $0 == "missing" && p[FNR] != "" && p[FNR] != "." { print t[FNR] "\t" p[FNR] }' \
    "$out.paths" "$trees" "$out" > "$miss" || _die "cannot list the unresolved code refs"
  [ -s "$miss" ] || return 0
  : > "$ls"
  awk '{ t = substr($0, 1, index($0, "\t") - 1); if (!(t in s)) { s[t] = 1; print t } }' "$miss" > "$miss.trees" \
    || _die "cannot list the unresolved code refs"
  while IFS= read -r t; do
    awk -v t="$t" 'substr($0, 1, length(t) + 1) == t "\t" { print substr($0, length(t) + 2) }' "$miss" \
      | tr '\n' '\000' \
      | xargs -0 git --literal-pathspecs ls-tree -z "$t" -- \
      | tr '\000' '\n' \
      | awk -v t="$t" '{ print t "\t" $0 }' >> "$ls" || _die "git ls-tree failed"
  done < "$miss.trees"
  [ -s "$ls" ] || return 0
  # $ls lines: "<tree>\t<mode> <type> <id>\t<path>" (a path may hold a tab).
  awk 'FILENAME == ARGV[1] {
         i = index($0, "\t"); tr = substr($0, 1, i - 1); rest = substr($0, i + 1)
         j = index(rest, "\t")
         if (j) { split(substr(rest, 1, j - 1), m, " ")
                  if ((length(m[3]) == 40 || length(m[3]) == 64) && m[3] !~ /[^0123456789abcdef]/)
                    id[tr "\t" substr(rest, j + 1)] = m[3] }
         next }
       FILENAME == ARGV[2] { p[FNR] = $0; next }
       FILENAME == ARGV[3] { t[FNR] = $0; next }
       { k = t[FNR] "\t" p[FNR]; if ($0 == "missing" && (k in id)) print id[k]; else print }' \
    "$ls" "$out.paths" "$trees" "$out" > "$out.tmp" && mv -f "$out.tmp" "$out" \
    || _die "cannot resolve the code refs' tree entries"
}

# Re-stage the refs of _worktree_tree from the working tree into the private
# index $1: add the paths that exist (one batch; if git refuses one — ignored,
# unreadable — each is added alone and a refused one is dropped and warned
# about), drop the ones that do not, and drop the doc-index family when a ref
# covers it. xargs keeps any number of refs under the argv limit.
_wt_stage() {
  local idx="$1" p out
  if [ ${#_WT_PRESENT[@]} -gt 0 ] && ! printf '%s\0' "${_WT_PRESENT[@]}" \
      | GIT_INDEX_FILE="$idx" xargs -0 git --literal-pathspecs add -A -- >/dev/null 2>&1; then
    for p in "${_WT_PRESENT[@]}"; do
      if ! out=$(GIT_INDEX_FILE="$idx" git --literal-pathspecs add -A -- "$p" 2>&1); then
        echo "WARNING: git cannot stage code ref '$p' (${out%%$'\n'*}); its content is recorded as missing." >&2
        GIT_INDEX_FILE="$idx" git --literal-pathspecs rm -r -f -q --cached --ignore-unmatch -- "$p" >/dev/null \
          || _die "cannot drop '$p' from a private index"
      fi
    done
  fi
  if [ ${#_WT_ABSENT[@]} -gt 0 ]; then
    printf '%s\0' "${_WT_ABSENT[@]}" \
      | GIT_INDEX_FILE="$idx" xargs -0 git --literal-pathspecs rm -r -f -q --cached --ignore-unmatch -- >/dev/null \
      || _die "cannot drop the absent code refs from a private index"
  fi
  [ "$_WT_COVERS" = 0 ] || _drop_index_family "$idx"
}

# The tree of what the working tree holds at the given refs (one per line of
# $1, as stored), into _WT_TREE: git's index is copied to a private one, every
# ref is re-staged from the working tree (_wt_stage), and the result written
# as a tree. Paths outside the refs keep their index state; only the refs are
# ever looked up in it.
#
# `add -A` stages untracked files too — new files under a ref are code the doc
# was read against — so an untracked file (not ignored) under a ref is part of
# the recorded content, and HEAD lacks it: the doc reads stale until it is
# committed or ignored. One `git ls-files -o` over the refs names every such
# path in a warning (the doc-index's own files aside). --no-empty-directory:
# without it an empty directory, or one holding only ignored files, is listed
# as dir/ too, although git stages nothing from it (it is recorded missing).
_WT_PRESENT=()
_WT_ABSENT=()
_WT_COVERS=0
_worktree_tree() {
  local in="$1" paths="$_SCRATCH/worktree.paths" idx="$_SCRATCH/worktree.index" real p rc=0
  _WT_PRESENT=() _WT_ABSENT=() _WT_COVERS=0 _WT_TREE=""
  awk -v ix="$INDEX_FILE" "$_AWK_REFPATH"'
    { p = refpath($0); if (p != "" && !(p in seen)) { seen[p] = 1; print p; if (covers(p)) c = 1 } }
    END { exit c ? 3 : 0 }' "$in" > "$paths" || rc=$?
  case "$rc" in
    0) ;;
    3) _WT_COVERS=1 ;;
    *) _die "cannot read the code refs" ;;
  esac
  while IFS= read -r p; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      _WT_PRESENT+=("$p")
    else
      _WT_ABSENT+=("$p")
    fi
  done < "$paths"
  if [ ${#_WT_PRESENT[@]} -gt 0 ]; then
    local untracked="$_SCRATCH/worktree.untracked" names="" count=0
    printf '%s\0' "${_WT_PRESENT[@]}" \
      | xargs -0 git --literal-pathspecs ls-files -z -o --exclude-standard --directory --no-empty-directory -- \
      | tr '\000' '\n' > "$untracked" || _die "git ls-files failed"
    while IFS= read -r p; do
      case "$p" in
        ''|"$INDEX_FILE"*) continue ;;
      esac
      count=$((count + 1))
      [ "$count" -gt 10 ] || names="${names:+$names, }$p"
    done < "$untracked"
    if [ "$count" -gt 0 ]; then
      [ "$count" -le 10 ] || names="$names, … ($((count - 10)) more)"
      echo "WARNING: code refs cover $count $([ "$count" -eq 1 ] && echo path || echo paths) git does not track: $names. Their content is recorded as verified and HEAD lacks it, so the doc reads stale until they are committed or ignored." >&2
    fi
  fi
  real=$(git rev-parse --git-path index) || _die "git rev-parse --git-path index failed"
  rm -f "$idx"
  if [ -f "$real" ]; then
    cp "$real" "$idx" || _die "cannot copy $real"
  fi
  _wt_stage "$idx"
  if ! _WT_TREE=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null); then
    # git's index holds unmerged entries (a merge in progress): start from
    # HEAD's tree instead — the refs are re-staged from the working tree anyway.
    rm -f "$idx"
    _head_init
    if [ -n "$_HEAD" ]; then
      GIT_INDEX_FILE="$idx" git read-tree "$_HEAD" || _die "git read-tree HEAD failed"
    fi
    _wt_stage "$idx"
    _WT_TREE=$(GIT_INDEX_FILE="$idx" git write-tree) \
      || _die "cannot capture the code refs from the working tree (git write-tree failed)"
  fi
}

# _last_commits <refsets-file> <out-file> [<starts-file>]
# code_commit for each line of <refsets-file> (one entry's refs, \x1f-joined):
# the newest commit touching any of them reachable from the line's start —
# its line of <starts-file>, a commit id; HEAD when that is empty or there is
# no <starts-file> — or "": no refs, no such commit, an unborn HEAD, or a
# shallow clone (warned once). One `git rev-list -1` per DISTINCT (start,
# refs): docs that share both share the walk, and matching them up is two awk
# passes, not a lookup per doc.
_last_commits() {
  local in="$1" out="$2" starts="${3:-}" ids="$_SCRATCH/lc.ids" sets="$_SCRATCH/lc.sets" res="$_SCRATCH/lc.res"
  local set c start refs=()
  : > "$out"
  [ -s "$in" ] || return 0
  : > "$sets"
  # A set is "<start>\035<refs>"; the start (hex or "") never holds \035.
  awk -F $'\x1f' -v ix="$INDEX_FILE" -v sets="$sets" -v sf="$starts" "$_AWK_REFPATH"'
    { st = ""
      if (sf != "" && (getline st < sf) <= 0) st = ""
      k = ""
      for (i = 1; i <= NF; i++) { p = refpath($i); if (p != "") k = (k == "" ? p : k FS p) }
      k = st "\035" k
      if (!(k in id)) { id[k] = ++n; print k > sets }
      print id[k] }' "$in" > "$ids" || _die "cannot read the code refs"
  _head_init
  _shallow_init
  if [ "$_SHALLOW" = true ]; then
    echo "WARNING: shallow clone: code_commit is not recorded (the truncated history cannot name the last commit touching the refs); code_oids are." >&2
  fi
  while IFS= read -r set; do
    c=""
    start="${set%%$'\035'*}"
    set="${set#*$'\035'}"
    [ -n "$start" ] || start="$_HEAD"
    if [ -n "$set" ] && [ -n "$start" ] && [ "$_SHALLOW" != true ]; then
      IFS=$'\x1f' read -r -a refs <<<"$set"
      c=$(git --literal-pathspecs rev-list -1 "$start" -- "${refs[@]}") \
        || _die "git rev-list failed for code refs: ${refs[*]}"
    fi
    printf '%s\n' "$c"
  done < "$sets" > "$res"
  awk 'NR == FNR { c[FNR] = $0; next } { print c[$0] }' "$res" "$ids" > "$out" \
    || _die "cannot match code_commit to the entries"
}

# _doc_commits <out-file>
# For each doc of _FACT_KEYS, the newest commit reachable from HEAD that
# touched it — what `git rev-list -1 HEAD -- <doc>` names — one line each in
# order: "" for a doc git has never committed (and on an unborn HEAD). A path
# holding a newline is not looked up ("").
#
# ONE `git log` walk for them all (the paths on its stdin: no argv limit),
# each doc taking the first (newest) commit that lists it, read by an awk that
# stops the walk once every doc is found. The walk's history simplification
# is over ALL the paths, so a merge that kept one parent's version of a doc
# but another's of some other doc is TREESAME to neither parent, and both
# sides are walked: a side-branch commit to the doc that the merge discarded
# is newer than the one it kept, and was taken as the doc's last commit (a
# baseline newer than the doc's content, which can hide staleness). So each
# hit is checked: the doc's blob at the hit must be HEAD's (one batch-check
# for all of them); a doc that fails it gets its own `rev-list -1`.
_doc_commits() {
  local out="$1" list="$_SCRATCH/dc.list" names="$_SCRATCH/dc.names" hits="$_SCRATCH/dc.hits" p
  : > "$out"
  [ ${#_FACT_KEYS[@]} -gt 0 ] || return 0
  _head_init
  for p in "${_FACT_KEYS[@]}"; do
    case "$p" in
      *$'\n'*) p="" ;;
    esac
    printf '%s\n' "$p"
  done > "$names"
  awk 'NF' "$names" > "$list.paths" || _die "cannot list the docs"
  # No path at all would make git log list every file of every commit.
  if [ -z "$_HEAD" ] || [ ! -s "$list.paths" ]; then
    awk '{ print "" }' "$names" > "$out" || _die "cannot list the docs"
    return 0
  fi
  { printf '%s\n--\n' "$_HEAD"; cat "$list.paths"; } > "$list" || _die "cannot list the docs"
  # -z output: "\001<commit>\0", then "\n<path>\0" for its first path and
  # "<path>\0" for the rest. Commit lines start with \001; paths are the
  # other non-empty lines. The awk exits once every doc has its commit, so
  # git (and tr) may end on SIGPIPE: their statuses are checked apart, in a
  # subshell without pipefail — an early stop is fine, a failed walk is not.
  # With SIGPIPE inherited as ignored, tr gets EPIPE instead and exits 1 (GNU
  # tr at once, and git then ends 141; BSD tr after reading all of git's
  # output, and git ends 0), saying so on stderr. tr only writes to a pipe,
  # so a reader that stopped is its one way to fail: with awk at 0 and git
  # at 0 or 141, tr's status is not checked, and its stderr is discarded.
  local rcs
  rcs=$(
    set +e +o pipefail
    git --literal-pathspecs -c core.quotePath=false -c log.showSignature=false \
        log --no-renames --format='%x01%H' --name-only -z --stdin < "$list" \
      | tr '\000' '\n' 2>/dev/null \
      | awk -v want="$list.paths" '
          BEGIN { while ((getline p < want) > 0) if (!(p in w)) { w[p] = 1; left++ } }
          substr($0, 1, 1) == "\001" { c = substr($0, 2); next }
          $0 != "" && ($0 in w) && !($0 in at) { at[$0] = c; print $0 "\t" c; if (--left == 0) exit }' \
        > "$hits"
    echo "${PIPESTATUS[*]}"
  )
  local grc trc arc
  read -r grc trc arc <<<"$rcs"
  case "$arc:$grc:$trc" in
    0:0:*|0:141:*) ;;
    *) _die "git log failed while finding the docs' last commits" ;;
  esac
  # Each hit's blob of the doc against HEAD's (one batch-check): the same
  # blob — or both absent, a doc deleted at its hit — keeps the hit.
  local verdict="$_SCRATCH/dc.verdict" fixed="$_SCRATCH/dc.fixed" d c
  awk -F '\t' -v head="$_HEAD" '{ c = $NF; d = substr($0, 1, length($0) - length(c) - 1)
                                   print c ":" d; print head ":" d }' "$hits" \
    | git cat-file --batch-check='%(objectname)' \
    | awk '{ id = ((length($0) == 40 || length($0) == 64) && $0 !~ /[^0123456789abcdef]/) ? $0 : "missing"
             if (NR % 2) a = id; else print (a == id ? "ok" : "check") }' > "$verdict" \
    || _die "git cat-file --batch-check failed while checking the docs' last commits"
  : > "$fixed"
  while IFS= read -r p <&3 && IFS= read -r c <&4; do
    [ "$c" = check ] || continue
    d="${p%$'\t'*}"
    c=$(git --literal-pathspecs rev-list -1 "$_HEAD" -- "$d") \
      || _die "git rev-list failed for '$d'"
    printf '%s\t%s\n' "$d" "$c" >> "$fixed"
  done 3< "$hits" 4< "$verdict"
  awk -v hits="$hits" -v fixed="$fixed" '
    function load(f,   l, i) { while ((getline l < f) > 0) { i = length(l); while (i > 0 && substr(l, i, 1) != "\t") i--
                                                             at[substr(l, 1, i - 1)] = substr(l, i + 1) } }
    BEGIN { load(hits); load(fixed) }
    { print ($0 != "" && ($0 in at)) ? at[$0] : "" }' "$names" > "$out" \
    || _die "cannot match the docs to their last commits"
}

# _hash_list <names-file> <out-file>
# "sha256:<hex>" for each NUL-terminated file name in <names-file>, one line
# each, in order — in as few processes as argv allows (xargs); a hash per doc
# was a fork+exec per file. Names reach the hasher as ./<name>, so a doc named
# "-" is never read as stdin. If the batch does not line up one to one (an
# unreadable file drops its line), each file is hashed on its own, so a hash
# can never land on the wrong doc — and an unreadable one dies.
_hash_list() {
  local in="$1" out="$2" list="$_SCRATCH/hash.names" raw="$_SCRATCH/hash.raw"
  local f n=0 m=0 line h
  : > "$out"
  [ -s "$in" ] || return 0
  while IFS= read -r -d '' f; do
    case "$f" in
      /*) ;;
      *) f="./$f" ;;
    esac
    printf '%s\0' "$f"
    n=$((n + 1))
  done < "$in" > "$list"
  if command -v sha256sum >/dev/null 2>&1; then
    xargs -0 sha256sum -- < "$list" > "$raw" 2>/dev/null || true
  else
    xargs -0 shasum -a 256 -- < "$list" > "$raw" 2>/dev/null || true
  fi
  while IFS= read -r line; do
    h="${line%% *}"
    # GNU sha256sum and shasum prefix the line with "\" when the name needed
    # escaping.
    h="${h#\\}"
    case "$h" in
      *[!0123456789abcdef]*) m=-1; break ;;
    esac
    [ "${#h}" -eq 64 ] || { m=-1; break; }
    printf 'sha256:%s\n' "$h"
    m=$((m + 1))
  done < "$raw" > "$out"
  [ "$m" -ne "$n" ] || return 0
  while IFS= read -r -d '' f; do
    _hash_one "$f"
    printf '%s\n' "$_HASH"
  done < "$in" > "$out"
}

# _tree_presence <names-file> <out-file>
# For each NUL-terminated doc path in <names-file>, one line in <out-file>:
# the blob id _DOCS_TREE holds at that path, or "missing" (no file there).
# ONE git cat-file --batch-check. A path holding a newline cannot be one line
# of the query; it reads as missing (as a ref with one does).
_tree_presence() {
  local in="$1" out="$2" q="$_SCRATCH/tdocs.query" f
  : > "$out"
  while IFS= read -r -d '' f; do
    case "$f" in
      *$'\n'*) printf '\n' ;;
      *) printf '%s:%s\n' "$_DOCS_TREE" "$f" ;;
    esac
  done < "$in" > "$q"
  [ -s "$q" ] || return 0
  git cat-file --batch-check='%(objecttype) %(objectname)' < "$q" \
    | awk '{ if ($1 == "blob" && (length($2) == 40 || length($2) == 64) && $2 !~ /[^0123456789abcdef]/) print $2
             else print "missing" }' > "$out" \
    || _die "git cat-file --batch-check failed"
}

# _tree_hash_list <names-file> <blob-ids-file> <out-file>
# _hash_list for docs as _DOCS_TREE holds them (<blob-ids-file>: each doc's
# blob there, one per line, aligned with the NUL-terminated names). A doc
# whose working copy git would store as that very blob (one `git hash-object
# --stdin-paths` for all of them) has the working copy's bytes, hashed in one
# _hash_list batch. Any other doc (edited, deleted or never written in the
# working copy) is read from its blob, with the filters a checkout applies,
# and hashed alone. That is rare, and never one process per unchanged doc.
_tree_hash_list() {
  local in="$1" ids="$2" out="$3"
  local flags="$_SCRATCH/th.flags" ondisk="$_SCRATCH/th.ondisk" wt="$_SCRATCH/th.wt"
  local plan="$_SCRATCH/th.plan" same="$_SCRATCH/th.same" samehash="$_SCRATCH/th.samehash"
  local blob="$_SCRATCH/th.blob" f o w p h
  : > "$out"
  [ -s "$in" ] || return 0
  # Each doc once: is it a file in the working copy (1) or not (0)?
  while IFS= read -r -d '' f; do
    case "$f" in
      *$'\n'*) echo 0; continue ;;
    esac
    if [ -f "$f" ]; then
      printf '%s\n' "$f" >&3
      echo 1
    else
      echo 0
    fi
  done < "$in" > "$flags" 3> "$ondisk"
  : > "$wt"
  if [ -s "$ondisk" ]; then
    git hash-object --stdin-paths < "$ondisk" > "$wt" || _die "git hash-object failed"
  fi
  : > "$same"
  while IFS= read -r -d '' f <&3; do
    IFS= read -r o <&4 || _die "cannot read the docs' blob ids"
    IFS= read -r p <&5 || _die "cannot read the doc list"
    w=""
    if [ "$p" = 1 ]; then
      IFS= read -r w <&6 || _die "cannot read the working copy's blob ids"
    fi
    if [ -n "$w" ] && [ "$w" = "$o" ]; then
      printf '%s\0' "$f" >&7
      echo s
    else
      echo t
    fi
  done 3< "$in" 4< "$ids" 5< "$flags" 6< "$wt" 7> "$same" > "$plan"
  _hash_list "$same" "$samehash"
  while IFS= read -r -d '' f <&3; do
    IFS= read -r o <&4 || _die "cannot read the docs' blob ids"
    IFS= read -r p <&5 || _die "cannot read the hash plan"
    if [ "$p" = s ]; then
      IFS= read -r h <&6 || _die "cannot read the doc hashes"
      printf '%s\n' "$h"
    else
      git cat-file --filters --path="$f" "$o" > "$blob" 2>/dev/null \
        || git cat-file blob "$o" > "$blob" \
        || _die "cannot read '$f' from the tree"
      _hash_one "$blob"
      printf '%s\n' "$_HASH"
    fi
  done 3< "$in" 4< "$ids" 5< "$plan" 6< "$samehash" > "$out"
}

# _warn_refs <refs-file> <unmatched 0|1>
# Warn once per distinct ref (one per line of <refs-file>) that holds a glob
# character — refs are literal paths, so it names only a path of exactly that
# name. With <unmatched> 1, also list in $_SCRATCH/unmatched each other ref
# that matches no file git tracks; _entry_facts warns about the ones then
# recorded "missing" (a typo, an empty or all-ignored directory: HEAD agrees
# until that path is committed, so the doc cannot go stale). One that holds
# untracked content is recorded instead, and named by _worktree_tree. One
# `git ls-files`, one awk. The list is read NUL-separated: git quotes a name
# holding `"`, a backslash or a tab even with core.quotePath=false, and a
# quoted name would match no ref.
_warn_refs() {
  local list="$1" unmatched="$2" tracked="$_SCRATCH/tracked" out r kind
  : > "$_SCRATCH/unmatched"
  [ -s "$list" ] || return 0
  : > "$tracked"
  if [ "$unmatched" = 1 ]; then
    git ls-files -z | tr '\000' '\n' > "$tracked" || _die "git ls-files failed"
  fi
  out=$(awk -v reffile="$list" -v unmatched="$unmatched" '
    function norm(r,   n, i, parts, out) {
      n = split(r, parts, "/")
      out = ""
      for (i = 1; i <= n; i++)
        if (parts[i] != "" && parts[i] != ".") out = (out == "" ? parts[i] : out "/" parts[i])
      return out == "" ? "." : out
    }
    BEGIN {
      while ((getline r < reffile) > 0) {
        if (r in glob) continue
        # index(), not /[*?[]/: a literal "[" inside a bracket expression
        # is read differently by mawk (see the awk portability note below).
        if (index(r, "*") || index(r, "?") || index(r, "[")) { glob[r] = 1; print "G\t" r; continue }
        k = norm(r)
        if (!(k in want)) { want[k] = 1; orig[k] = r; order[++total] = k }
      }
    }
    {
      if ("." in want) found["."] = 1
      p = $0
      while (1) {
        if (p in want) found[p] = 1
        if (!match(p, /\/[^\/]*$/)) break
        p = substr(p, 1, RSTART - 1)
      }
    }
    END { if (unmatched) for (i = 1; i <= total; i++) if (!(order[i] in found)) print "U\t" orig[order[i]] }
  ' "$tracked") || _die "cannot check the code refs"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    kind="${r%%$'\t'*}"
    r="${r#*$'\t'}"
    case "$kind" in
      G) echo "WARNING: code ref '$r' contains a glob character (* ? [): code refs are literal paths, so it names only a path of exactly that name." >&2 ;;
      U) printf '%s\n' "$r" >> "$_SCRATCH/unmatched" ;;
    esac
  done <<<"$out"
}

# _entry_facts <unmatched 0|1> [<baseline worktree|doc>]
# What a writer records for each entry of _FACT_KEYS / _FACT_REFSETS (its
# refs, \x1f-joined), each fact gathered in ONE batch for the whole run:
#   _FACT_HASH[i]    "sha256:<hex>" of the doc, "" when it is not a file
#   _FACT_COMMIT[i]  code_commit (_last_commits), "" when none
#   _FACT_OIDS[i]    the refs' object ids in the entry's baseline,
#                    \x1f-joined in ref order
# The baseline is the code an entry is recorded against:
#   worktree  (update-index, the one baseline reset) the working tree the
#             reviewer read (_worktree_tree); code_commit from HEAD
#   doc       (build-index, add-entry, set-code-refs: none is a reset) the
#             code as of the DOC'S OWN LAST COMMIT (_doc_commits), so a doc
#             written against older code reads stale; code_commit from that
#             commit. A doc git has never committed is being written now: its
#             baseline is the working tree it is written in.
# Warns about glob-looking refs, and with <unmatched> 1 about untracked ones.
_entry_facts() {
  local unmatched="$1" baseline="${2:-worktree}" n=${#_FACT_KEYS[@]} i=0 x isfile=()
  local docs="$_SCRATCH/facts.docs" hashes="$_SCRATCH/facts.hashes" sets="$_SCRATCH/facts.sets"
  local refs="$_SCRATCH/facts.refs" commits="$_SCRATCH/facts.commits" oids="$_SCRATCH/facts.oids"
  local oidsets="$_SCRATCH/facts.oidsets" bases="$_SCRATCH/facts.bases" trees="$_SCRATCH/facts.trees"
  local wrefs="$_SCRATCH/facts.wrefs"
  _FACT_HASH=() _FACT_COMMIT=() _FACT_OIDS=()
  [ "$n" -gt 0 ] || return 0
  while [ "$i" -lt "$n" ]; do
    if [ -f "${_FACT_KEYS[$i]}" ]; then
      isfile+=(1)
      printf '%s\0' "${_FACT_KEYS[$i]}" >&3
    else
      isfile+=(0)
    fi
    printf '%s\n' "${_FACT_REFSETS[$i]}" >&4
    i=$((i + 1))
  done 3> "$docs" 4> "$sets"
  # One baseline commit per entry ("" = the working tree), and one tree-ish
  # per ref line: its entry's commit, or W for the working tree.
  if [ "$baseline" = doc ]; then
    _doc_commits "$bases"
  else
    awk '{ print "" }' "$sets" > "$bases" || _die "cannot read the code refs"
  fi
  : > "$refs"
  : > "$trees"
  awk -F $'\x1f' -v bf="$bases" -v r="$refs" -v t="$trees" '
    { if ((getline b < bf) <= 0) exit 1
      for (i = 1; i <= NF; i++) { print $i > r; print (b == "" ? "W" : b) > t } }' "$sets" \
    || _die "cannot read the code refs"
  _warn_refs "$refs" "$unmatched"
  _hash_list "$docs" "$hashes"
  _last_commits "$sets" "$commits" "$bases"
  : > "$oids"
  if [ -s "$refs" ]; then
    # The working tree is captured (one private-index tree) only for the
    # refs whose baseline it is.
    awk 'FILENAME == ARGV[1] { t[FNR] = $0; next } t[FNR] == "W"' "$trees" "$refs" > "$wrefs" \
      || _die "cannot read the code refs"
    if [ -s "$wrefs" ]; then
      _worktree_tree "$wrefs"
      awk -v w="$_WT_TREE" '{ print ($0 == "W" ? w : $0) }' "$trees" > "$trees.w" \
        && mv -f "$trees.w" "$trees" || _die "cannot read the code refs"
    fi
    # A commit's tree holds the doc-index itself: sanitize (a working-tree
    # capture lacks it already, so update-index needs no second pass).
    if [ "$baseline" = doc ]; then
      _oid_lookup - "$refs" "$oids" 1 "$trees"
    else
      _oid_lookup - "$refs" "$oids" 0 "$trees"
    fi
  fi
  # A ref git tracks nothing under is warned about only if it was recorded
  # missing: whether it exists does not decide it (an empty or all-ignored
  # directory exists, yet git stages nothing from it), and one holding
  # untracked content was recorded and named by _worktree_tree.
  if [ -s "$_SCRATCH/unmatched" ]; then
    local r
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      echo "WARNING: code ref '$r' matches no file tracked by git, and git would stage nothing from it (typo? empty or all ignored?); it is recorded as missing, so the doc cannot go stale until that path is committed." >&2
    done < <(awk 'FNR == 1 { f++ }
               f == 1 { u[$0] = 1; next }
               f == 2 { o[FNR] = $0; next }
               ($0 in u) && o[FNR] == "missing" && !($0 in done) { done[$0] = 1; print }' \
               "$_SCRATCH/unmatched" "$oids" "$refs")
  fi
  awk -F $'\x1f' -v o="$oids" '
    { s = ""
      for (i = 1; i <= NF; i++) { if ((getline x < o) <= 0) exit 1; s = (i == 1 ? x : s FS x) }
      print s }' "$sets" > "$oidsets" || _die "cannot match code_oids to the entries"
  i=0
  while [ "$i" -lt "$n" ]; do
    x=""
    if [ "${isfile[$i]}" = 1 ]; then
      IFS= read -r x <&5 || _die "cannot read the doc hashes"
    fi
    _FACT_HASH+=("$x")
    IFS= read -r x <&6 || _die "cannot read code_commit"
    _FACT_COMMIT+=("$x")
    IFS= read -r x <&7 || _die "cannot read code_oids"
    _FACT_OIDS+=("$x")
    i=$((i + 1))
  done 5< "$hashes" 6< "$commits" 7< "$oidsets"
}

# The tree readers compare against, into _TREE: --tree <tree-ish> when given
# (checked by the verb: it cannot start with "-"), else HEAD's — or the empty
# tree on an unborn HEAD.
_TREE=""
_tree_init() {
  [ -z "$_TREE" ] || return 0
  if _opt_seen tree; then
    if ! _TREE=$(git rev-parse --verify -q "$_OPT_tree^{tree}"); then
      echo "ERROR: --tree '$_OPT_tree' does not name a tree (give a commit, a tree or a tag, e.g. HEAD or the output of git write-tree)." >&2
      exit 1
    fi
    return 0
  fi
  _head_init
  if [ -n "$_HEAD" ]; then
    _TREE=$(git rev-parse --verify -q "$_HEAD^{tree}") || _die "cannot read HEAD's tree"
  else
    _TREE=$(git hash-object -t tree /dev/null) || _die "cannot name the empty tree"
  fi
}

# A --tree value is a revision; one starting with "-" would read as an option.
_check_tree_opt() {
  if _opt_seen tree; then
    case "$_OPT_tree" in
      ''|-*) _usage_error "$1" "--tree needs a tree-ish, such as HEAD or \$(git write-tree) (got '$_OPT_tree')" ;;
    esac
  fi
}

# --- Freshness: ONE implementation, shared by check-freshness and status ------
#
# check-freshness used to carry its own inline copy of the per-doc logic, and
# the copy drifted: it split jq's @tsv records on tab, which bash treats as IFS
# WHITESPACE, so an empty middle field (a null code_commit or content_hash, an
# empty doc_type) collapsed and shifted every later column — stale docs read
# as current; refs were re-split on "," and glob-expanded by the shell; a key
# containing a tab was @tsv-escaped into a path that never existed. Both verbs
# now run _freshness_scan, and the fields travel \x1f-separated (not
# whitespace, so an empty field stays a field) in NUL-terminated records.

# jq: every entry (or only $only) that passes the --code-refs filter, as
#   key \x1f status \x1f doc_type \x1f last_verified \x1f content_hash
#     \x1f code_commit \x1f mode \x1f <n refs> [\x1f ref]… [\x1f oid]… \0
# mode is "record" for a record doc (no refs follow: it is never compared),
# "oids" when the entry has code_oids (then the stored object id of each ref
# follows the refs, "" for a ref code_oids lacks), else "legacy". Refs are
# the stored strings minus empties (a legacy "" is not a path).
#
# A record doc describes a point in time — a plan, an issue, an audit, a
# design spec, or anything archived — so the code moving on does not make it
# wrong: doc_type plan / issue / audit / design-spec, or a key under
# docs/archive/. It is never reported stale.
#
# Filter ($flt: the raw --code-refs list, one path per line, or null): an
# entry is kept when a ref shares a path SEGMENT with a listed path: equal,
# the ref a directory above the path, or the path a directory above the ref.
# `src/m1` matches refs src/m1, src/m1/a.js and src/ — never src/m10 (the old
# raw string prefix matched 260 of 400 docs where 40 were right). "." is the
# repository root; an empty list keeps nothing. Sets, not a scan per pair.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_FRESH_EXTRACT='
  def segs: split("/") | map(select(. != "" and . != "."));
  def normref: segs | if length == 0 then "." else join("/") end;
  def dirs: segs | . as $p | [range(1; ($p | length) + 1) as $i | $p[0:$i] | join("/")];
  (if $flt == null then null
   else ($flt | split("\n")
         | map(if endswith("\r") then .[:-1] else . end | select(. != "") | normref)) as $F
     | { empty: ($F | length == 0),
         root: any($F[]; . == "."),
         exact: (reduce $F[] as $f ({}; .[$f] = true)),
         under: (reduce ($F[] | select(. != ".") | dirs[]) as $d ({}; .[$d] = true)) }
   end) as $M
  | def hit: normref as $n
      | $M.root or $n == "." or ($M.under[$n] // false)
        or any(($n | dirs[]); $M.exact[.] // false);
  .docs
  | (if $only == "" then to_entries[] else ({key: $only, value: .[$only]} | select(.value != null)) end)
  | .key as $k
  | .value as $v
  | [($v.code_refs // []) | if type == "array" then .[] else empty end
     | select(type == "string" and . != "")] as $refs
  | select($M == null or (($M.empty | not) and any($refs[]; hit)))
  | ((($v.doc_type // "") as $t | $t == "plan" or $t == "issue" or $t == "audit" or $t == "design-spec")
     or ($k | startswith("docs/archive/"))) as $record
  | (if $record then [] else $refs end) as $refs
  | (if $record then "record" elif ($v.code_oids | type) == "object" then "oids" else "legacy" end) as $mode
  | ([$k, ($v.status // "" | tostring), ($v.doc_type // "" | tostring),
      ($v.last_verified // "" | tostring), ($v.content_hash // "" | tostring),
      ($v.code_commit // "" | tostring), $mode, ($refs | length | tostring)] + $refs
     + (if $mode == "oids"
        then [$refs[] as $r | $v.code_oids[$r] | if type == "string" then . else "" end]
        else [] end))
  | join("\u001f") + "\u0000"'

# jq (after $_JQ_REC_FIELDS): the _freshness_scan stream as def results:
# {key: result}. The stream opens with the commits_behind of each distinct
# stale (code_commit, refs) group — <G>, then G pairs <group> <count or "">
# — and then holds 8 fields per doc: key status doc_type last_verified reason
# doc_modified commits_behind changed-refs (\x1f-joined). commits_behind is a
# count, "" (null) or "?<group>". Field order is the report's. A record doc
# (status "record" in the stream) is reported current, with "record": true
# and commits_behind null (not evaluated) — no new status value, so every
# consumer that counts stale or current reads it as before. last_verified
# is null when the entry has none (never re-baselined).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_FRESH_RESULTS='
  def results:
    rec_fields as $f
    | ($f[0] | tonumber) as $g
    | (reduce range(0; $g) as $j ({}; .[$f[1 + 2 * $j]] = $f[2 + 2 * $j])) as $B
    | def behind:
        if . == "" then null
        elif startswith("?") then ($B[.[1:]] // "" | if . == "" then null else tonumber end)
        else tonumber end;
      def lv: if . == "" then null else . end;
    [range(1 + 2 * $g; $f | length; 8) as $i
       | {key: $f[$i], value: (
           if $f[$i + 1] == "deprecated" then
             {status: "deprecated", doc_type: $f[$i + 2], last_verified: ($f[$i + 3] | lv)}
           elif $f[$i + 1] == "missing" then
             {status: "missing", doc_type: $f[$i + 2]}
           elif $f[$i + 1] == "record" then
             {status: "current", record: true, doc_modified: ($f[$i + 5] == "true"), commits_behind: null,
              doc_type: $f[$i + 2], last_verified: ($f[$i + 3] | lv)}
           else
             {status: $f[$i + 1]}
             + (if $f[$i + 1] == "stale" then {reason: $f[$i + 4]} else {} end)
             + {doc_modified: ($f[$i + 5] == "true"), commits_behind: ($f[$i + 6] | behind)}
             + (if $f[$i + 1] == "stale"
                then {code_refs_changed: ($f[$i + 7] | if . == "" then [] else split("\u001f") end)}
                else {} end)
             + {doc_type: $f[$i + 2], last_verified: ($f[$i + 3] | lv)}
           end)}]
    | from_entries;'

# The pre-v3 verdict of an entry without code_oids: stale when the newest
# commit touching the refs (git pathspecs, as before v3) is not the stored
# code_commit. Into _F_STATUS, _F_REASON, _F_BEHIND ("" = null) and
# _F_CHANGED (\x1f-joined refs). A stored code_commit that is not an object id
# counts as no baseline, and is never handed to git (see _is_oid).
#   _freshness_legacy <code_commit> [ref…]
_freshness_legacy() {
  local code_commit="$1" ref
  shift
  _F_STATUS=current _F_REASON="" _F_BEHIND=0 _F_CHANGED=""
  _is_oid "$code_commit" || code_commit=""
  _git_last_commit "$@"
  [ -n "$_LAST" ] && [ "$_LAST" != "$code_commit" ] || return 0
  _F_STATUS=stale
  _F_REASON=code_changed
  _F_BEHIND=""
  if [ -n "$code_commit" ]; then
    _git_commits_behind "$code_commit" "$@"
    _F_BEHIND="$_BEHIND"
  fi
  # With no baseline, every ref with any history counts as changed.
  for ref in "$@"; do
    _git_last_commit "$ref"
    if [ -n "$_LAST" ] && [ "$_LAST" != "$code_commit" ]; then
      _F_CHANGED="${_F_CHANGED:+$_F_CHANGED$'\x1f'}$ref"
    fi
  done
}

# _freshness_scan <snapshot> <only-key or ""> <filter-file or ""> <out-file>
# The one freshness walk. ONE jq pass extracts the entries. Pass 1 sorts them
# (deprecated / missing / record / live) and lists what to look up; then every
# live and record doc is hashed in one batch (a record's refs are never looked
# up: it is never stale), and every ref of every live v3 entry is looked up
# in the compared tree (_TREE) in one batch-check. Pass 2 compares; a legacy
# entry takes the pre-v3 commit logic. Then one `git rev-list --count` per
# distinct stale (code_commit, refs) group. The verdicts go to <out-file> as a
# _rec_put stream for $_JQ_FRESH_RESULTS. No jq or git runs per current doc.
_freshness_scan() {
  local snap="$1" only="$2" filter="$3" out="$4"
  local fields="$_SCRATCH/fresh.fields" docs="$_SCRATCH/fresh.docs" hashes="$_SCRATCH/fresh.hashes"
  local refs="$_SCRATCH/fresh.refs" cur="$_SCRATCH/fresh.cur" groups="$_SCRATCH/fresh.groups"
  local pairs="$_SCRATCH/fresh.pairs" recs="$_SCRATCH/fresh.recs"
  local flt=(--argjson flt null)
  [ -z "$filter" ] || flt=(--rawfile flt "$filter")
  jq -j --arg only "$only" "${flt[@]}" "$_JQ_FRESH_EXTRACT" < "$snap" > "$fields" \
    || _die "cannot read the entries of $INDEX_FILE"
  _head_init

  # A doc's presence and bytes: in the working copy, or (--tree with an
  # index) as _DOCS_TREE holds them — one batch-check over every key, in
  # record order, read alongside the records in pass 1.
  local keys="$_SCRATCH/fresh.keys" present="$_SCRATCH/fresh.present" ids="$_SCRATCH/fresh.ids" f
  : > "$present"
  if [ -n "$_DOCS_TREE" ]; then
    while IFS=$'\x1f' read -r -d '' -a f; do
      printf '%s\0' "${f[0]}"
    done < "$fields" > "$keys"
    _tree_presence "$keys" "$present"
  fi

  # Pass 1. fd 3 carries the records, so nothing in the loop can read them as
  # its stdin. A ref holding a newline (only a hand-edited index has one)
  # cannot be one line of the lookup: ".." makes it unaddressable ("missing").
  # fd 6: the doc's blob in _DOCS_TREE (tree mode), fd 7: those of the docs
  # listed on fd 4, for their hashes.
  local f cls=() n j r id=""
  while IFS=$'\x1f' read -r -d '' -a f <&3; do
    if [ -n "$_DOCS_TREE" ]; then
      IFS= read -r id <&6 || _die "cannot read the docs' presence in the tree"
    fi
    if [ "${f[1]}" = deprecated ]; then
      cls+=(d)
    elif { [ -n "$_DOCS_TREE" ] && [ "$id" = missing ]; } || { [ -z "$_DOCS_TREE" ] && [ ! -f "${f[0]}" ]; }; then
      cls+=(m)
    elif [ "${f[6]}" = record ]; then
      cls+=(r)
      printf '%s\0' "${f[0]}" >&4
      [ -z "$_DOCS_TREE" ] || printf '%s\n' "$id" >&7
    else
      cls+=(l)
      printf '%s\0' "${f[0]}" >&4
      [ -z "$_DOCS_TREE" ] || printf '%s\n' "$id" >&7
      if [ "${f[6]}" = oids ]; then
        n="${f[7]}"
        j=0
        while [ "$j" -lt "$n" ]; do
          r="${f[$((8 + j))]}"
          case "$r" in
            *$'\n'*) r=.. ;;
          esac
          printf '%s\n' "$r" >&5
          j=$((j + 1))
        done
      fi
    fi
  done 3< "$fields" 4> "$docs" 5> "$refs" 6< "$present" 7> "$ids"

  if [ -n "$_DOCS_TREE" ]; then
    _tree_hash_list "$docs" "$ids" "$hashes"
  else
    _hash_list "$docs" "$hashes"
  fi
  _tree_init
  _oid_lookup "$_TREE" "$refs" "$cur" 1

  # Pass 2: fd 4 the hashes (one per live doc), fd 5 the looked-up object ids
  # and fd 6 their normalized paths (one per ref of a live v3 entry), fd 7 the
  # stale groups needing commits_behind.
  local k=0 hash mod st reason behind changed stored now path gpaths
  {
    while IFS=$'\x1f' read -r -d '' -a f <&3; do
      case "${cls[$k]}" in
        d) _rec_put "${f[0]}" deprecated "${f[2]}" "${f[3]}" "" "" "" "" ;;
        m) _rec_put "${f[0]}" missing "${f[2]}" "${f[3]}" "" "" "" "" ;;
        r)
          IFS= read -r hash <&4 || _die "cannot read the doc hashes"
          if [ "$hash" = "${f[4]}" ]; then mod=false; else mod=true; fi
          _rec_put "${f[0]}" record "${f[2]}" "${f[3]}" "" "$mod" "" ""
          ;;
        *)
          IFS= read -r hash <&4 || _die "cannot read the doc hashes"
          if [ "$hash" = "${f[4]}" ]; then mod=false; else mod=true; fi
          n="${f[7]}"
          if [ "${f[6]}" = oids ]; then
            changed="" gpaths=""
            j=0
            while [ "$j" -lt "$n" ]; do
              IFS= read -r now <&5 || _die "cannot read the looked-up object ids"
              IFS= read -r path <&6 || _die "cannot read the looked-up paths"
              # :- because read -a drops a trailing empty field (the last
              # ref's stored id is "" when code_oids lacks it).
              stored="${f[$((8 + n + j))]:-}"
              if [ "$stored" != "$now" ]; then
                changed="${changed:+$changed$'\x1f'}${f[$((8 + j))]}"
              fi
              [ -z "$path" ] || gpaths="$gpaths"$'\x1f'"$path"
              j=$((j + 1))
            done
            if [ -z "$changed" ]; then
              st=current reason="" behind=0
            else
              st=stale reason=code_changed behind=""
              if _is_oid "${f[5]}" && [ -n "$_HEAD" ] && [ -n "$gpaths" ]; then
                behind="?${f[5]}$gpaths"
                printf '%s\n' "${f[5]}$gpaths" >&7
              fi
            fi
          else
            _freshness_legacy "${f[5]}" ${f[8]+"${f[@]:8:$n}"}
            st="$_F_STATUS" reason="$_F_REASON" behind="$_F_BEHIND" changed="$_F_CHANGED"
          fi
          _rec_put "${f[0]}" "$st" "${f[2]}" "${f[3]}" "$reason" "$mod" "$behind" "$changed"
          ;;
      esac
      k=$((k + 1))
    done 3< "$fields" 4< "$hashes" 5< "$cur" 6< "$cur.paths" 7> "$groups"
  } > "$recs"

  # commits_behind once per distinct stale (code_commit, refs) group: every
  # doc sharing refs and a baseline shares the answer.
  local g=0 gkey base grefs=()
  awk '!seen[$0]++' "$groups" > "$groups.u" || _die "cannot group the stale docs"
  while IFS= read -r gkey; do
    base="${gkey%%$'\x1f'*}"
    IFS=$'\x1f' read -r -a grefs <<<"${gkey#*$'\x1f'}"
    _git_commits_behind --literal "$base" "${grefs[@]}"
    _rec_put "$gkey" "$_BEHIND"
    g=$((g + 1))
  done < "$groups.u" > "$pairs"
  {
    _rec_put "$g"
    cat "$pairs" "$recs" || _die "cannot assemble the freshness report"
  } > "$out"
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
# A run that changes nothing writes nothing (no generated_at bump). Writers
# report what they did rather than what they were asked: they build a
# per-key patch list (JSONL) first and apply it in that one pass: O(N + k), not
# a whole-index re-parse per path; with --report the same pass classifies each
# patch row, so a writer's report is one walk over its rows (a newline-framed
# `case` lookup per key made the reports quadratic: 4,000 keys took 34 s on
# bash 5, 109 s on bash 3.2). Any write stamps schema_version 3 (and drops the
# pre-v2 "version" key). Signals terminate (_traps): an interrupted writer
# leaves the previous index byte-identical, never a partial one.

INDEX_FILE="docs/.doc-index.json"
INDEX_LOCK="$INDEX_FILE.lock"
_SCRATCH=""          # private scratch dir (snapshots, patches); removed on exit
_INDEX_TMP=""        # in-flight tmp beside the index; removed on exit
_TMP_PATHS=()        # in-flight tmps beside other files (_tmp_beside); removed on exit
_CL_WTS=()           # throwaway worktrees (_claims_worktree_add); removed on exit
_INDEX_LOCK_HELD=0
_INDEX_BREAKING=0
_INDEX_NOW=""        # one timestamp per run: last_verified and generated_at agree
_INDEX_CLASSES=""    # with --report: one class per patch row (see _index_apply)
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
  # A claims verb's failure is "could not run": exit 2, with its verdict.
  if [ "$_CL_ACTIVE" = 1 ]; then _claims_die "$*"; fi
  echo "ERROR: $*" >&2
  exit 1
}

# Record streams from bash to jq. Each field is written as "<n>\n" followed by
# the value's n lines (n = its newline count + 1, so "" is one empty line), and
# read back by the jq def rec_fields. Line-framed on purpose: up to jq 1.6 raw
# input (-R) is read with fgets/strlen, so a NUL-delimited stream could be
# truncated there, while newline-terminated lines are safe on every supported
# jq. Any bash string round-trips (bash strings cannot hold NUL).
#
# The newline count walks the value once per newline. It used to be
# ${v//[!$'\n']/}, which bash 3.2 evaluates in time quadratic in the value's
# length: about 8 s for one 5,000-character doc_type.
_rec_put() {
  local v n rest
  for v in "$@"; do
    n=1
    case "$v" in
      *$'\n'*)
        rest="$v"
        while :; do
          case "$rest" in
            *$'\n'*) rest="${rest#*$'\n'}"; n=$((n + 1)) ;;
            *) break ;;
          esac
        done
        ;;
    esac
    printf '%s\n%s\n' "$n" "$v"
  done
}
# Linear in the stream: one small state per line (appending to a growing
# array in a reduce, as this once did, is quadratic in jq — 40k fields took
# 4 s — and check-freshness now sends every entry's verdict through here).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_REC_FIELDS='def rec_fields:
  [foreach inputs as $line ({want: 0, buf: [], out: null};
     if .want == 0 then {want: ($line | tonumber), buf: [], out: null}
     else .buf += [$line] | .want -= 1
       | if .want == 0 then .out = (.buf | join("\n")) else .out = null end
     end;
     if .want == 0 and .out != null then .out else empty end)];'


# _claims_worktrees_remove: a claims run's throwaway worktrees (_CL_WTS, in
# the scratch dir), each removed with its registration; _CL_WTS emptied.
# When a remove fails, the directory is deleted and the remove retried (git
# removes the registration of a worktree whose directory is gone). Never a
# repository-wide `git worktree prune`: it would also drop the registration
# of every other worktree that only looks gone (one on an unmounted volume).
# cleanup runs it on every exit path; --reverify after each claim.
_claims_worktrees_remove() {
  local p
  for p in ${_CL_WTS[@]+"${_CL_WTS[@]}"}; do
    if ! git worktree remove --force "$p" >/dev/null 2>&1; then
      rm -rf "$p"
      git worktree remove --force "$p" >/dev/null 2>&1 || true
    fi
  done
  _CL_WTS=()
}

# Remove whatever this run left in flight (the EXIT handler, _on_exit, runs
# it). Never calls exit, so the status of the `exit` that got us here
# (130/143 from a signal) stands.
cleanup() {
  if [ -n "$_INDEX_TMP" ]; then rm -f "$_INDEX_TMP"; fi
  local p
  for p in ${_TMP_PATHS[@]+"${_TMP_PATHS[@]}"}; do rm -f "$p"; done
  _index_unlock
  if [ "$_INDEX_BREAKING" = 1 ]; then rmdir "$INDEX_LOCK.break" 2>/dev/null || true; fi
  # A lock renamed aside for deletion (see _index_unlock / _index_break_stale)
  # whose rm was cut short. Named by our pid, so it is ours to remove.
  if [ -e "$INDEX_LOCK.gone.$$" ]; then rm -rf "$INDEX_LOCK.gone.$$"; fi
  _claims_worktrees_remove
  if [ -n "$_SCRATCH" ]; then rm -rf "$_SCRATCH"; fi
  return 0
}

# EXIT: clean up, then end with the status that ended the run — except that
# a run which claims 0 without having finished is a crash, and exits 1. bash
# 3.2 (macOS's /bin/bash) runs the EXIT trap of a fatal shell error, such as a
# `set -u` unbound variable, with $? = 0, so such a crash used to exit 0: a
# silent success. A run finishes by returning from _main, or by _exit_ok
# (an intended exit 0, such as --help); both set _EXIT_OK first.
#
# A claims verb (_CL_ACTIVE=1) has its own exit family (see "Spec claims"):
# the run ends with the exit code its verdict printed — recorded by
# _claims_mark_emitted in this shell (_CL_EMITTED_RC) or, for a verdict a
# $(…) printed, in the marker file — whatever status reached the trap (a
# parent's `|| exit 1` after a subshell's _claims_die, or bash 3.2's crash
# status 0 → 1 above). A run that emitted no verdict — a set -u crash, a
# stray exit 1, a failed command — gets one fallback verdict object and
# exits 2, never 1. 130/143 (a signal) stand either way. The marker is read
# BEFORE cleanup, which removes the scratch dir holding it.
_EXIT_OK=0
_USAGE_RC=2          # claims verbs: 3 (set in _main)
_CL_ACTIVE=0         # 1: this run is a claims verb
_CL_EMITTED=0        # 1: this shell printed the run's verdict
_CL_EMITTED_RC=""    # …and the exit code that verdict carries
_CL_VERB=""          # the claims verb ("validate", …), for verdict objects
_on_exit() {
  local rc=$? emitted=0 erc=""
  if [ "$_CL_ACTIVE" = 1 ]; then
    if [ "$_CL_EMITTED" = 1 ]; then
      emitted=1
      erc="$_CL_EMITTED_RC"
    elif [ -n "$_SCRATCH" ] && [ -e "$_SCRATCH/cl-emitted" ]; then
      emitted=1
      # No trailing newline: read assigns, then returns 1.
      IFS= read -r erc < "$_SCRATCH/cl-emitted" || true
    fi
    # A marker whose code is unreadable still means a verdict was printed.
    case "$erc" in
      0|1|2|3) ;;
      *) erc=2 ;;
    esac
  fi
  cleanup
  if [ "$rc" -eq 0 ] && [ "$_EXIT_OK" != 1 ]; then
    rc=1
  fi
  if [ "$_CL_ACTIVE" = 1 ]; then
    case "$rc" in
      130|143) ;;
      *)
        if [ "$emitted" = 0 ]; then
          _claims_fallback "$rc"
          rc=2
        else
          rc=$erc
        fi
        ;;
    esac
  fi
  exit "$rc"
}

# An intended successful exit from anywhere in the run.
_exit_ok() {
  _EXIT_OK=1
  exit 0
}

# INT/TERM END the run; EXIT cleans up. The previous traps cleaned up and then
# RESUMED: a TERM'd build-index ran on and installed a truncated index with
# rc 0, and one blocked on stdin treated the interrupted read as EOF and
# installed an EMPTY one. Never RETURN: it fires on every function return.
_traps() {
  trap '_on_exit' EXIT
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
# the path must outlive the call so cleanup can remove it. Assigned through a
# temporary, so a failed mktemp leaves _SCRATCH empty when _die runs: a claims
# verb's _claims_die must not write its marker to "/cl-emitted".
_scratch_init() {
  [ -z "$_SCRATCH" ] || return 0
  local d
  d=$(mktemp -d -t doc-tools.XXXXXX) || { _SCRATCH=""; _die "mktemp -d failed"; }
  _SCRATCH=$d
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
    [01234567][01234567][01234567]|[01234567][01234567][01234567][01234567]) printf '%s' "$m" ;;
    *) return 1 ;;
  esac
}

# The index's write discipline (a tmp beside the target, then mv, so a reader
# or an interrupted run never sees a partial file) for any other file this
# tool rewrites: a doc (set-implementation), the manifests (bump-version), a
# vendored copy (tools install).
#
# _tmp_beside <target>: create an empty temp file in <target>'s directory into
# _TMP, registered for removal on exit. Call it in the main shell, never inside
# $(…), or the registration is lost. A hidden name, so a watcher or a glob in
# that directory does not pick it up as a doc. A <target> that is a symbolic
# link is refused (before anything is written): the mv would replace the link
# with a regular file, and its mode would be the link's own.
_tmp_beside() {
  local dir base
  [ ! -L "$1" ] || _die "$1 is a symbolic link: not replacing it (edit the file it points to). Nothing was written."
  dir=$(dirname "$1")
  base=$(basename "$1")
  _TMP=$(mktemp "$dir/.$base.XXXXXX") || _die "cannot create a temp file beside $1"
  _TMP_PATHS+=("$_TMP")
}

# _replace_file <tmp> <target> [mode] [exec]: install <tmp> as <target>,
# keeping <target>'s permission bits (mktemp creates 0600) — or [mode]
# (default 644) when <target> does not exist yet. [exec] = 1 also sets the
# execute bits (a+x, i.e. OR 0111) on whichever mode that is: a script a CI
# job runs directly must stay executable, whatever mode the old copy had.
_replace_file() {
  local tmp="$1" target="$2" mode
  mode=$(_file_mode "$target" 2>/dev/null) || mode="${3:-644}"
  chmod "$mode" "$tmp" || _die "cannot chmod $mode $tmp"
  if [ "${4:-0}" = 1 ]; then
    chmod a+x "$tmp" || _die "cannot chmod a+x $tmp"
  fi
  mv -f "$tmp" "$target" || _die "cannot replace $target"
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

# The snapshot a reader (check-freshness, status) judges: the index, into
# _SNAP, and the tree its docs are read from, into _DOCS_TREE. With --tree T,
# the index and the docs come from T, like the code refs, so the verdict is
# one consistent snapshot. A pre-commit check then judges the commit being
# made even when the working copy's index or a doc differs from what is
# staged. Otherwise _DOCS_TREE is "" and the working copy's index and docs are
# read, as before, against HEAD's refs. A T that holds no index (it was never
# committed or staged) falls back to the working copy's index and docs, with
# one note on stderr. An invalid index in T is an error. Call in the main
# shell, never in $( ): it sets globals.
_SNAP=""
_DOCS_TREE=""
_reader_snapshot() {
  _SNAP="" _DOCS_TREE=""
  if _opt_seen tree; then
    _tree_init
    if [ "$(git cat-file -t "$_TREE:$INDEX_FILE" 2>/dev/null)" = blob ]; then
      _SNAP=$(mktemp "$_SCRATCH/index.XXXXXX") || _die "mktemp failed"
      git cat-file blob "$_TREE:$INDEX_FILE" > "$_SNAP" \
        || _die "cannot read $INDEX_FILE from --tree $_OPT_tree"
      if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"' \
          "$_SNAP" >/dev/null 2>&1; then
        echo "ERROR: $INDEX_FILE in --tree $_OPT_tree is not a valid doc-index (expected one JSON object with a \"docs\" object)." >&2
        exit 1
      fi
      _DOCS_TREE="$_TREE"
      return 0
    fi
    echo "NOTE: --tree $_OPT_tree holds no $INDEX_FILE; the working copy's index and docs are judged (code refs are still read from the tree)." >&2
  fi
  _SNAP=$(_index_load) || exit 1
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

# Whether process $1 is running. kill -0 fails with EPERM for a live process
# of another user (a shared checkout, a CI runner's other account) — which
# read as dead and got its lock broken — so a failed kill -0 is confirmed
# with ps -p (POSIX). Where ps cannot tell, the process counts as gone, as
# before.
_pid_alive() {
  case "$1" in
    ''|*[!0123456789]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# Take the writer lock (re-entrant within a run). mkdir is atomic everywhere
# and needs nothing beyond POSIX. Waits up to DOC_TOOLS_LOCK_TIMEOUT seconds
# (default 30), then fails naming the owner. Main shell only: it records $$
# and sets the held flag the EXIT trap releases.
_index_lock() {
  [ "$_INDEX_LOCK_HELD" = 0 ] || return 0
  local timeout="${DOC_TOOLS_LOCK_TIMEOUT:-30}"
  case "$timeout" in
    ''|*[!0123456789]*) _die "DOC_TOOLS_LOCK_TIMEOUT must be a whole number of seconds (got '$timeout')." ;;
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
    if [ -n "$owner" ] && ! _pid_alive "$owner"; then
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

# _index_apply [--replace | --report] <jq-program> [jq args…]
#
# Lock → snapshot → ONE jq pass → tmp beside the target → chmod → mv. The
# program gets the current index as `.` and must yield exactly one whole new
# index. `$now` (this run's timestamp) is bound for it — do not pass --arg now.
# It must not stamp generated_at: that is set here, and only if something
# changed — as is schema_version (3; a pre-v2 "version" key is dropped), so a
# v2 index is read as it is and upgraded by its first real write. --replace
# (build-index only) tolerates a missing or invalid prior index — `.` is then
# null — because rebuilding is how one recovers from it. --report (the patch
# writers, which pass --slurpfile patch) also classifies every $patch row, in
# row order, into _INDEX_CLASSES — one character each:
#   c  the row's key changed          u  unchanged, and it was indexed before
#   v  changed, but in last_verified alone (update-index re-baselining a doc
#      whose recorded content is as it was: a real write, reported as such)
#   a  unchanged, and it was not indexed before
# A real write also drops a stored status of "current" or "stale" from every
# entry: status is stored only as "deprecated" (current / stale are computed
# by check-freshness), and a legacy value is read as absent until then. A run
# that changes nothing leaves such values, like everything else, untouched.
#
# Sets _INDEX_WROTE (0/1). Releases the lock before returning. An index that
# is a symbolic link is refused before anything is read or written (as
# _tmp_beside refuses one for every other file): the mv would replace the
# link with a regular file.
_index_apply() {
  local replace=0 report=0
  case "${1:-}" in
    --replace) replace=1; shift ;;
    --report) report=1; shift ;;
  esac
  local program="$1"
  shift
  [ ! -L "$INDEX_FILE" ] || _die "$INDEX_FILE is a symbolic link: not replacing it (the write would turn it into a regular file; point the tools at the file itself). Nothing was written."
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
  #   same\0 | write\0                     whether anything changed
  #   <classes>\0                          (--report) one class per $patch row
  #   <index>\n                            (write) the new index
  # The index is emitted pretty-printed, byte-for-byte what `jq .` writes.
  local classes='empty'
  # shellcheck disable=SC2016  # jq program, not shell expansion
  [ "$report" = 0 ] || classes='(reduce $__ch[] as $k ({}; .[$k] = true)) as $__cs
      | def __lv: if type == "object" then del(.last_verified) else . end;
      ([$patch[] | .key as $k
          | if $__cs[$k] then (if ($__od[$k] | __lv) == ($__new.docs[$k] | __lv) then "v" else "c" end)
            elif ($__od | has($k)) then "u" else "a" end] | join("")) + "\u0000"'
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
    | ((if ($__old | type) == "object" then ($__old | del(.generated_at)) else null end)
       == ($__new | del(.generated_at))) as $__same
    | (if $__same then []
       else [ (($__od | keys) + ($__new.docs | keys) | unique)[] as $k
              | select($__od[$k] != $__new.docs[$k]) | $k ] end) as $__ch
    | (if $__same then "same\u0000" else "write\u0000" end),
      ('"$classes"'),
      (if $__same then empty
       else ($__new
             | .generated_at = $now
             | .docs |= map_values(if type == "object" and (.status == "current" or .status == "stale")
                                   then del(.status) else . end)
             | if has("schema_version") then .schema_version = '"$_SCHEMA_VERSION"' | del(.version)
               else {schema_version: '"$_SCHEMA_VERSION"'} + del(.version) end),
            "\n" end)'

  local out
  out=$(mktemp "$_SCRATCH/apply.XXXXXX") || _die "mktemp failed"
  # Caller options go BEFORE the program: the documented `jq [options] filter`
  # order (jq 1.6 is the floor — see check_deps).
  if ! jq -j --arg now "$_INDEX_NOW" "$@" "$wrapped" < "$snap" > "$out"; then
    _die "failed to apply the index update; $INDEX_FILE is unchanged."
  fi

  _INDEX_CLASSES=""
  _INDEX_WROTE=0
  local verdict=""
  _INDEX_TMP=$(mktemp "$INDEX_FILE.tmp.XXXXXX") || _die "cannot create a temp file beside $INDEX_FILE"
  {
    IFS= read -r -d '' verdict || true
    if [ "$report" = 1 ]; then
      IFS= read -r -d '' _INDEX_CLASSES || _die "unexpected index-apply output; $INDEX_FILE is unchanged."
    fi
    if [ "$verdict" = write ]; then
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

# --- Command line ------------------------------------------------------------
#
# ONE verb table drives both the dispatcher and the usage text: a subcommand
# exists only if it has a row here, so --help cannot drift from what actually
# dispatches (it once omitted implementation-status and set-implementation).
# A row is a header line followed by indented help lines:
#
#   <verb>|<handler>|<needs>|<options>   (a verb may be two words: "tools install")
#     <synopsis: the arguments after the verb, or "-" for none>
#     <description…>
#
# needs    repo  reads/writes the index or queries git: runs only inside a git
#                work tree (checked once, before the handler)
#          deps  needs jq (check_deps) but no repository
#          none  pure bash (help)
# options  the long options the verb takes, space-separated (see _parse_args):
#          name    a flag                            → _OPT_name=1
#          name=   one value                         → _OPT_name=<value>
#          name=*  one value, repeatable             → _OPTV_name+=(<value>)
#          name+   one or more values, up to the next --option → _OPTV_name+=(…)
#          ("-" in a name becomes "_" in the variable.)
_VERBS=""
IFS= read -r -d '' _VERBS <<'VERBS' || true
build-index|cmd_build_index|repo|force
  [--force] < mapping-lines
  Build docs/.doc-index.json from mapping lines on stdin (see "Mapping
  lines"). Each entry is recorded as add-entry records one, with no
  baseline reset (last_verified null).
  Writes nothing and exits non-zero when stdin holds no mapping line or
  any line is invalid. Refuses to replace an index that already has
  entries unless --force is given; --force keeps each re-indexed key's
  deprecation (status, superseded_by, replaces) and re-records the rest.
  For incremental changes use add-entry, update-index or remove-entry. A
  missing or malformed index is rebuilt without --force: this is the
  recovery path.
check-freshness|cmd_check_freshness|repo|code-refs+ code-refs-from=* tree=
  [--tree <tree-ish>] [--code-refs <path>...] [--code-refs-from <file|->]
  Report which indexed docs are stale relative to their code (read-only,
  JSON). A doc is stale when the content of one of its code_refs differs
  from what was recorded (code_oids). Without --tree, the working copy's
  index and docs are judged against the refs in HEAD. --tree <tree-ish>
  judges one snapshot: the index, the docs (present or missing, and
  doc_modified) and the refs all as that tree holds them. A pre-commit check
  wants the staged tree, --tree "$(git write-tree)", so an update-index
  whose index is not staged does not count. A tree without the index falls
  back to the working copy's index and docs, with a note on stderr. An
  entry without code_oids (pre-v3) keeps the old commit comparison, at
  HEAD, until update-index re-baselines it.
  --code-refs limits the report to docs whose code_refs share a path
  segment with a listed path: src/m1 matches refs src/m1, src/m1/a.js and
  src/, never src/m10. It takes every following argument up to the next
  --option. --code-refs-from reads the same list from a file, or from
  stdin with "-" (no argv limit; use it from hooks and CI): one path per
  line, or NUL-separated. Produce it NUL-separated, so git quotes no name
  (it quotes one holding '"', a backslash or a tab even with
  core.quotePath=false):
    git diff -z --name-only --no-renames <range>
update-index|cmd_update_index|repo|
  <doc_path>...
  Re-baseline indexed docs (a baseline reset, never a verification —
  claims carry verification): re-hash, record code_oids (each code ref's
  content in the working tree) and code_commit, stamp last_verified. Run it
  only for a doc you read against its code. A deprecated entry stays
  deprecated. Reports Refreshed (something recorded changed), Re-verified
  (only last_verified did) or Unchanged (re-baselined this second already). A
  doc whose file is gone is skipped with advice. A path that is not
  indexed is reported and skipped; the others are still applied, and the
  run exits 1.
add-entry|cmd_add_entry|repo|
  < mapping-lines
  Add new entries from mapping lines on stdin (same format as
  build-index). Indexing is not a baseline reset: last_verified is null, and
  each ref's content is recorded as of the doc's own last commit (the
  working tree for a doc git has never committed), so code that changed
  since the doc was written reads stale until update-index re-baselines it.
  A key already indexed is skipped (update-index re-baselines it,
  set-code-refs changes its refs). An invalid line is rejected; the valid
  lines are still applied, and the run exits 1.
remove-entry|cmd_remove_entry|repo|
  <doc_path>...
  Remove entries from the index. A path that is not indexed is reported
  (SKIP) and the run still exits 0: the entry being absent is the end
  state asked for, so removing twice is safe.
move-entry|cmd_move_entry|repo|stdin
  <old_doc_path> <new_doc_path> | --stdin < <old><TAB><new> lines
  Re-key an entry after a doc moves, preserving its metadata: code_refs,
  code_oids, code_commit, last_verified, doc_type, status and every other
  field; only content_hash is recomputed. Every entry that names the old
  path is repointed: its replaces / superseded_by, and its code_refs (in
  place; a moved ref is dropped when the list already holds its new path
  or has just gained it, so [old, old] becomes [new]; a duplicate of a ref
  the move did not touch stays) with the matching code_oids key, whose
  recorded object id is kept: a rename keeps the content, so once the
  tree judged holds the rename (after the commit) a doc citing the moved
  one reads as it did; an entry without code_oids, written before schema
  3, reads stale from that commit until update-index re-baselines it. Use this, not
  remove-entry + add-entry, for a rename, which would drop the freshness
  metadata. --stdin moves a batch in one index write: one "<old><TAB><new>"
  pair per line (blank lines skipped, a trailing CR removed), taken as one
  simultaneous rename, so a path one pair vacates may be another's target.
  Every pair is checked first; one bad pair writes nothing (exit 1).
set-code-refs|cmd_set_code_refs|repo|refs=
  <doc_path> --refs <ref>[,<ref>...]
  Replace an indexed doc's code_refs in place (--refs '' leaves none); the
  same refs (compared as paths) write nothing. Not a baseline reset: the
  entry keeps its position and every other field (last_verified,
  content_hash, status, …). code_oids is re-derived: a ref the entry
  already had keeps its recorded content (for a pre-v3 entry, the content
  in its code_commit); a new one is recorded as add-entry records it (as
  of the doc's last commit), so the doc reads stale if that code changed
  since, until update-index re-baselines it. code_commit (the commits_behind
  baseline) stays when every ref is kept; is derived as add-entry derives
  it when every ref's content comes from the doc's last commit; and with
  both is the older baseline — git merge-base of the stored and derived
  commits, or null when there is no derived one or the stored one is
  absent, not an object id, not a commit of this repository, or not an
  ancestor of HEAD — so commits_behind may over-count but is never a
  masked 0.
  Refs are parsed like a mapping line's; their order is kept.
set-doc-type|cmd_set_doc_type|repo|
  <doc_path> <doc_type>
  Change an indexed doc's doc_type in place: the entry keeps its key
  position and every other field (last_verified, code_oids, status, …);
  the same type writes nothing. Not a baseline reset. doc_type decides
  whether a doc is a record (plan, issue, audit, design-spec: never
  reported stale) or a living doc compared with its code, so <doc_type>
  must be a known type — architecture, api-contracts, data-layer, infra,
  ci-cd, workflows, agentic, guide, codebase-guide, conventions, spec,
  adr, plan, issue, audit or design-spec — or one this index already
  uses (a project's own vocabulary); anything else (a typo) exits 1,
  writing nothing. Use it, not remove-entry + add-entry, which would drop
  the entry's baseline, deprecation and links.
deprecate-entry|cmd_deprecate_entry|repo|superseded-by=
  [--superseded-by <doc_path>] <doc_path>...
  Mark entries deprecated, optionally naming the doc that supersedes them;
  that successor's replaces is set to the (first) deprecated doc unless it
  already names one. --superseded-by replaces an entry's superseded_by;
  without it, an existing superseded_by is kept (so archiving a superseded
  doc keeps its link). last_verified is not touched: deprecating is not a
  baseline reset. A path that is not indexed is reported and skipped; the
  others are still applied, and the run exits 1 (so an archive step that
  names the old path after move-entry, deprecating nothing, fails).
status|cmd_status|repo|tree=
  [--tree <tree-ish>] <doc_path>
  Freshness of one doc (read-only, JSON): the same verdict check-freshness
  reports for it (with the same --tree, read from that one snapshot), plus
  its path.
audit-merges|cmd_audit_merges|repo|
  <since> [<until>]
  Find merges that silently lost an index change (read-only, JSON on
  stdout once the audit completes). For every two-parent merge commit in
  <since>..<until> (until: HEAD) whose parents' indexes differ, it works
  out what the merge should have recorded — the changed side's index when
  only one side changed it (git runs no driver then), else this plugin's
  merge driver run as an oracle on the merge base and both parents — and
  compares that with the recorded index, entry by entry. A finding is an
  entry whose recorded value differs: "kept": "parent 1" or "parent 2"
  means the merge kept that parent's entry where the other parent's change
  should have survived (a silent revert, e.g. by a driver that is not
  base-aware, on a last_verified tie); "neither" means the merge commit
  itself rewrote it (a hand resolution or a re-baseline: review it).
  "refused": the merge needed a resolution the driver would not make (it
  stays reported after a correct hand resolution, and its other entries
  are not compared); "unreadable": "recorded" when the merge's own index
  is not exactly one index object, "parent 1" / "parent 2" when the one
  side that changed the index, whose index the merge was to take, is not.
  "merges_checked" counts the merges whose parents' indexes differ,
  "merges_replayed" those that needed the driver. A stored status "current"/"stale" is not compared
  (freshness is derived), nor are top-level fields. An octopus merge is
  listed under "skipped", not replayed. The replay uses one merge base, so
  a criss-cross merge is approximated; in a squash-merge repository only
  merges made on the audited line are seen. Runs from the plugin's
  scripts/ (it needs merge-doc-index.sh beside it: a vendored doc-tools.sh
  alone exits 1). Exits 1 on any finding. Repair a lost change with the
  verb that made it.
bump-version|cmd_bump_version|deps|
  <MAJOR.MINOR.PATCH>
  Write the version into the 5 manifest files: package.json,
  .claude-plugin/plugin.json, .claude-plugin/marketplace.json,
  .cursor-plugin/plugin.json, gemini-extension.json. RELEASE-NOTES.md is
  the canonical version: check-version reads it, and it is never written.
  All or nothing: every manifest found is read first, and one that is not
  valid JSON writes nothing (exit 1); so does finding none (run it from the
  repo root). Each file keeps its mode.
check-version|cmd_check_version|deps|
  -
  Verify that every manifest carries RELEASE-NOTES.md's version: its first
  release heading, a line "## vMAJOR.MINOR.PATCH …" outside code fences (a
  pre-release suffix is refused, not skipped). Exits 1 on a mismatch, a
  manifest that is not valid JSON, or no manifest found.
implementation-status|cmd_implementation_status|deps|
  <path>...
  Report ADR/SPEC realization state (read-only): each doc's
  Implementation: (ADR) or Realized-by: (SPEC) entries, or that it has
  none, or that it is explicitly empty ("Implementation: []"). The block
  grammar is the one set-implementation writes and update-index records;
  see "Realization blocks".
set-implementation|cmd_set_implementation|deps|ref= status= note=
  <path> --ref <kind: ref> --status <status> [--note <note>]
  Set one realization entry, "<ref> — <status>[ — <note>]", in a doc's
  Implementation: / Realized-by: block: the first entry whose text is
  "<ref>" or starts with "<ref> —" is replaced in place (with its wrapped
  lines), and a later duplicate of it is dropped; otherwise one is
  appended at the block's indent ("<key>: []" becomes a list). A doc
  with no block gets one after the paragraph holding its first
  **Date**: / **Date:** (Implementation:) or **Created**: / **Created:**
  (Realized-by:) line; with neither it exits 1 and writes nothing. Values
  are written literally; --ref and --note must each be one line. Status:
  complete, partial, in-progress, not-started, reverted, superseded or
  blocked. The doc is replaced atomically, keeping its mode. Exits 2 (not
  1) for an invalid --status, a missing <path> or a multi-line --ref /
  --note: they are checked with the command line, before anything is read.
claims validate|cmd_claims_validate|repo|staged all config=* base=
  (--staged | --all) [--config <KEY=VALUE>...] [--base <ref>]
  Check the spec claims in docs/spec-claims/ without running a test:
  --staged the claims the staged change touches, in the staged tree;
  --all every claim, in the working tree. A finding blocks (exit 1) when
  its check is in the config's "blocking" list, and is reported as an
  advisory otherwise. The plans (config "plans") staged, or present under
  --all, are checked for their claims gates and **Claims:** lines (V12).
  --config KEY=VALUE (repeatable) checks a configuration change made
  outside git (V10, the configuration extension only: a usage error
  without it). See "Spec claims".
claims run|cmd_claims_run|repo|claims+ planes-of= all scheduled judge-sample= base=
  (--claims <id>... | --planes-of <range> | --all) [--scheduled] [--judge-sample <n>] [--base <ref>]
  Execute claims: test claims through their runner adapters (config
  "runners": one run call per runner), log claims (with --scheduled only)
  through the log adapter, and lint claims by their pattern (grep -E) over
  the working tree's lint.paths files (pass, or assert-fail). --claims
  takes ids (commas split them too). --planes-of <a>..<b> (or <a>...<b>:
  from their merge-base) runs the test claims of every runner that has a
  "paths" entry (a prefix or a glob) matching a file the range changes:
  its first-parent commits' files and its merges' conflict resolutions,
  never trunk merged in. --judge-sample
  <n> also names n judge claims to review, rotated weekly. Retired, frozen
  and judge claims are reported skipped. Each outcome is judged by the
  claim's status: built must pass, diverged fail by an assertion, unbuilt
  not pass. Every finding blocks (an unsafe lint path, an invalid pattern,
  or an absent lint path on a claim that is not unbuilt, is one: an unbuilt
  claim's absent lint path is its allowed assert-fail); an indeterminate
  outcome, or a missing or failing adapter, exits 2.
claims promote|cmd_claims_promote|repo|reverify all base=
  <id> | --reverify (<id>... | --all) [--base <ref>]
  Promote a test claim to built (to gated, with the configuration extension
  on, when the recorded configuration at HEAD does not satisfy its "when"):
  run its bound test green at HEAD, verify its
  non-vacuity proofs, each in a throwaway worktree where the test first
  passes unmodified (under nonvacuity.mutant, an exactly-once literal
  find/replace, and under nonvacuity.observed_red <sha>, a full commit id,
  the subject files as at that commit, the test must fail by an
  assertion), store the verdict, record the promotion in the sidecar
  ({at, verdict_sha256, proved}: proved digests the fields it proved) and
  render the doc's status block (results: {claim, status_from, status_to,
  green, red, verdict_sha256}). A built claim whose verdict matches it,
  every field as proved records it, is refused (already promoted), unless
  the configuration extension is on and the recorded configuration at HEAD
  no longer satisfies its "when": it is
  then re-proved and written gated. --reverify re-runs those proofs at HEAD
  for each <id>, or with --all for each built or gated claim with a
  promotion (a frozen one is reported skipped), and stores each fresh
  verdict, writing neither sidecar nor doc (results: {claim, verdict}:
  ok, finding, indeterminate or skipped); a named claim that is not
  promoted is a finding. Refuses a dirty tree (exit 2, dirty-tree).
  Every finding blocks.
claims render|cmd_claims_render|repo|check base=
  [--check] [--base <ref>]
  Write the generated "## Claim status" block of each doc that has a
  sidecar (results: {doc, changed}); --check writes nothing and reports
  each block that differs as a V11 finding. A sidecar whose doc is
  missing or not governing is skipped (results: {doc, skipped}): its doc
  is never written, nor created.
claims gate|cmd_claims_gate|repo|plan= chunk= from= holds=* by= base=
  --plan <plan> --chunk <n> [--from <rev>] [--holds <id>]... [--by <principal>] [--base <ref>]
  Run a plan chunk's claims gate at HEAD and record it in
  docs/spec-claims/gates/<plan-stem>/chunk-<n>.json (written even when
  red): the claims the chunk's **Claims:** lines name plus --planes-of
  <from>..HEAD and each lint, log or judge claim the range moved into
  built or gated, re-promotions owed, V8, V8n and V9 over <from>..HEAD,
  every named id no claim has and every named claim still unbuilt that no
  included DOC-STALE ruling covers, and the reconciliations since <from> (a
  ruling counts only when its record is this chunk's record; anything else
  is a silent reconciliation). <from> is --from, else chunk <n-1>'s head,
  else the merge-base; a range reads the branch's own commits (first
  parent), never trunk merged in.
  --holds <id> (repeatable, one id each) records that a claim-bound test
  edit leaves the claim's states true, adjudicated by --by (required with
  --holds: without it, exit 3). Refuses a dirty tree. Every finding
  blocks.
claims attest|cmd_claims_attest|repo|plan= final deep base=
  --plan <plan> [--final] [--deep] [--base <ref>]
  Check a plan's gate records against the branch at HEAD: every chunk
  with a gate task recorded, its commits matched to merge-base..HEAD by
  patch id (an unmatched one marks the record rebased: re-verified);
  every claim the plan names, and each lint, log or judge claim the branch
  moved into built or gated, run at HEAD (built must pass, diverged fail
  with its ruling and tracker; unbuilt, or a re-promotion owed, is a
  finding); every ruling, promotion and status change since the
  merge-base on the plan's claims and its specs' claims recorded in a
  chunk record or in final.json, whose reconciliations are rebuilt from
  the last chunk record's head (a ruling counts there only when it names
  final.json as its record), and every recorded ruling still at HEAD; the
  amendment batch (claims rulings); render --check. --final is the final
  gate: refuses a dirty tree, and writes
  docs/spec-claims/gates/<plan-stem>/final.json even when it does not
  pass. --deep re-runs each record's test claims in a throwaway worktree
  at its head (a head not here is indeterminate). Every finding blocks.
claims rulings|cmd_claims_rulings|repo|range= format= base=
  --range <a>..<b> [--format json|markdown] [--base <ref>]
  List the DOC-STALE and RETIRE rulings present at <b> and absent at <a>
  (or <a>...<b>: from their merge-base; <a> must be an ancestor of <b>):
  the spec amendments a reviewer approves, one row each {claim, doc,
  direction, by, date, reason, approved {quote, states} at <a> (null for a
  new claim), new {quote, states} at <b>}. --format markdown prints them
  as Markdown for a PR description, under "## Spec amendments (N)",
  instead of the verdict object.
fragments list|cmd_fragments_list|deps|
  -
  List the per-PR release-notes fragments (RELEASE-NOTES.next/PR-<N>.md in
  the working tree) as JSON: hash status, sections, the no-notes state,
  and the problem that keeps `fragments merge` from consuming one (null
  when there is none). Symbolic links and non-numeric names are skipped
  with a warning.
fragments validate|cmd_fragments_validate|deps|
  <path>
  Exit 0 if the fragment's hash matches its body, 1 if it drifted (or has
  no hash marker), 2 if <path> is not a regular file.
fragments merge|cmd_fragments_merge|repo|paths-out= remove
  <range-start> <range-end> [--paths-out <file>] [--remove]
  Print the merged sections of every fragment present at <range-end>: a
  fragment is unreleased until a release deletes it. <range-start> is the
  latest release: its version's tag, else the commit that added its
  RELEASE-NOTES.md heading (an untagged release); ROOT for the first one.
  Each fragment is merged losslessly or skipped with a warning (it stays
  for the next release). --paths-out writes the consumed paths, one per
  line; --remove (<range-end> must be HEAD) git-rm's exactly those. Exits
  3, naming them, when a fragment here was already consumed by
  <range-start>, or by a v* release tag cut from this history after it,
  whose release commit has not reached <range-end> (merge or cherry-pick
  it first); 1 on any other failure.
tools install|cmd_tools_install|deps|dest= with-helpers helper=*
  [--dest <path>] [--with-helpers | --helper <dir>...]
  Vendor doc-tools.sh into <path> (default .github/scripts); with
  --with-helpers also every helper the CI templates run
  (<path>/doc-pr-release/ and <path>/doc-superpowers-steps/), with
  --helper <dir> (repeatable) only those helper directories; shipping
  doc-pr-release also creates RELEASE-NOTES.next/README.md (only if
  absent). Files are replaced atomically; an existing file keeps its mode,
  and every script ends up executable (the templates run them directly).
  A symbolic link at a destination or at a directory on its way is refused
  before anything is written. Run from a vendored copy it can only copy
  itself (onto itself it only makes sure the copy is executable); a helper
  request then exits 1, writing nothing.
tools uninstall|cmd_tools_uninstall|deps|dest= helper=*
  [--dest <path>] [--helper <dir>...]
  Remove from <path> each vendored file that is byte-identical to the
  plugin's copy; a file with local edits (or from another plugin
  version) and a file you added are kept and reported, and so is a helper
  directory that still holds them. With --helper <dir> (repeatable), only
  those helper directories (doc-tools.sh stays). A symbolic link on the
  way is refused. With the doc-pr-release helpers it also removes
  RELEASE-NOTES.next/README.md when it is byte-identical to the plugin's
  fragment-format spec and the only file there (an edited one, or one
  beside fragments, is kept). Must run from the plugin's doc-tools.sh
  (exit 1 from a vendored copy, which has nothing to compare against).
tools status|cmd_tools_status|deps|dest=
  [--dest <path>]
  Report whether doc-tools.sh is vendored at <path>, whether it matches the
  plugin's copy (and the plugin's version), and the helpers present: how
  many differ from the plugin's copies, and how many the plugin does not
  ship (added locally) — and whether RELEASE-NOTES.next/README.md matches
  the plugin's fragment-format spec (an older copy gives outdated advice:
  replace it with the plugin's). Run from a vendored copy it reports
  presence only: no plugin to compare with.
tools version|cmd_tools_version|none|
  -
  Print the doc-superpowers version this doc-tools.sh belongs to: the
  first release heading of the plugin's RELEASE-NOTES.md (as check-version
  reads it). Exits 1 from a vendored copy, whose version is unknown.
help|cmd_help|none|
  [<subcommand>]
  Print this usage, or one subcommand's.
VERBS

# The sections of the full usage that follow the subcommand list.
_USAGE_NOTES=""
IFS= read -r -d '' _USAGE_NOTES <<'NOTES' || true
Options:
  --opt VALUE and --opt=VALUE are the same, and options may appear anywhere
  on the line; "--" ends them. --help (-h) prints a subcommand's usage and
  exits 0. An option a subcommand does not take is an error (exit 2; 3 for
  a claims subcommand), never silently ignored.

Mapping lines (stdin of build-index and add-entry, one doc per line):
  doc_path:code_refs_csv:doc_type
  e.g. docs/architecture.md:SKILL.md,scripts/:architecture
  ':' separates the fields, so a doc path or ref may not contain one. A
  line is rejected when it is a bare path (no ':'), when it has more than
  three fields, or when its first field is not a file but its first two or
  three fields joined by ':' name one: an existing ':' file would otherwise
  be indexed under the wrong key. (A ':' path whose file does not exist yet
  cannot be detected.) doc_type may be empty or omitted. Refs are
  comma-separated; each is trimmed, and empty ones are dropped. A trailing
  CR (a CRLF file) is removed. A ref is a literal path — a file, a
  directory, or "." for the whole repository — never a glob: one containing
  * ? or [ is warned about. A ref that matches no file tracked by git and
  from which git would stage nothing (a typo, an empty or all-ignored
  directory) is warned about too: it is recorded as missing, which HEAD
  agrees with, so the doc cannot go stale. Untracked (not
  ignored) files under a ref are part of what is recorded: writers name
  them, and the doc reads stale until they are committed or ignored.

Realization blocks (set-implementation, implementation-status, update-index):
  A line "Implementation:" (ADRs) or "Realized-by:" (SPECs) at the start of
  a line, outside code fences, followed by "- <text>" entries at any
  indent, column 0 included; an indented line after an entry wraps it
  (joined with a space). Any other line ends the block: a blank line, a
  fence line, or an unindented line that is not a "- " entry. The first
  such block is the doc's; "Implementation: []" (or "[ ]") is explicitly
  empty.
  update-index records the entries' text as the entry's implementation.

Doc paths:
  The doc-index is keyed by paths relative to the repo root, and every
  subcommand resolves paths against the current working directory, so run
  doc-tools.sh from the repo root: a repository subcommand run from a
  subdirectory exits 2, writing nothing. An absolute path inside the working tree
  is rewritten to its relative form, "//" collapses to "/", and a path
  outside the tree, or one starting with "-", is rejected (non-zero exit)
  rather than written as an unfindable key. A path named twice counts once.

Index writes:
  build-index, update-index, add-entry, remove-entry, move-entry,
  set-code-refs, set-doc-type and deprecate-entry take the lock
  docs/.doc-index.json.lock and replace the index atomically, so they are
  safe to run concurrently and an interrupted run leaves the previous index
  intact. An index that is a symbolic link is refused, writing nothing: the
  replacement would turn the link into a regular file. A run that changes nothing writes
  nothing (generated_at is not bumped). The incremental writers report only
  the entries they actually changed. Every verb that reads the index refuses
  one that is empty or malformed; build-index rebuilds over it. Writes stamp
  schema_version 3; a v2 index is read as it is.

Freshness (index schema v3):
  An entry records, per code ref, the git object id of its content
  (code_oids: a blob, a tree, a submodule's commit, or "missing"):
  update-index as the working tree holds it (what the doc was read against);
  build-index, add-entry and set-code-refs as of the doc's own last commit
  (the code it was written against; the working tree for a doc git has
  never committed). A doc is stale when one differs in the compared tree
  (HEAD, or --tree, which also supplies the index and the docs). So squash
  merges, rebase-merges, cherry-picks and reverts to
  the recorded bytes stay current, as does a doc re-baselined in the same
  commit as its code; a submodule bump reads stale. code_refs_changed lists
  exactly the refs that differ. commits_behind counts the commits touching
  the refs since code_commit, and is null when that commit is not an
  ancestor of HEAD here (a deleted squash-merged branch, a shallow clone, a
  cherry-picked re-baseline). In a shallow clone writers record no
  code_commit (null, with a warning). The doc-index itself is never part of
  a ref's content.

Stored state (who may re-baseline):
  Only update-index writes last_verified: it records a baseline reset, run
  only for a doc read against its code (no hook runs it). The other writers
  leave it as it is, and a new entry has null. status is stored only as
  "deprecated"; current and stale are always computed (a stored "current"
  or "stale" from an older index reads as absent, and the next write drops
  it). A record doc — doc_type plan, issue, audit or design-spec, or any
  path under docs/archive/ — describes a point in time, so it is never
  reported stale: check-freshness reports it current with "record": true
  (and commits_behind null: not evaluated). set-doc-type retypes an entry
  in place (an index written before v3 typed design specs "spec": retype
  them design-spec). Archiving a doc is git mv into docs/archive/<type>/,
  then move-entry, then deprecate-entry on the new path (which keeps the
  doc's superseded_by).

Spec claims (claims validate, run, promote, render, gate, attest, rulings):
  Claims live in docs/spec-claims/: one <DOC-ID>.json sidecar per governing
  doc, and an optional config.json (a key it omits takes its default; an
  unknown key is a V1 finding). A project without docs/spec-claims/ sees no
  change: every claims subcommand prints {"verb":…,"enabled":false,"exit":0}
  and exits 0. That check runs after the options are parsed (an unknown
  option still exits 3) and before the required arguments are checked.
  Every ratchet compares with git merge-base HEAD <base>, never the base's
  tip: <base> is --base, else the config's "base", else origin/main.
  The output is exactly one verdict JSON object on stdout — verb, enabled,
  exit, base, findings, advisories, indeterminate, results — except for
  rulings --format markdown. The exit codes are their own (see "Exit
  status"): 0 as expected, 1 findings, 2 could not run, 3 usage, with
  precedence 1 > 2 > 0. In a claims glob (config "governing", "plans", …),
  * also matches "/".
  Only a new DOC-STALE or RETIRE ruling licenses a changed states, a lowered
  enforced_by or a re-anchor that changes a token (validate, V6). The
  direction policy (config "policy") judges each new DOC-STALE or RETIRE
  ruling (V6). A ruling whose record is a gate record
  (docs/spec-claims/gates/<stem>/chunk-<n>.json or final.json) is made inside
  a plan: with in_plan_ruling_requires_gate_record true (the default) it is
  valid only when a plan matching "plans" has that stem and lists the claim's
  doc as target, infer or amends. Any other record is outside a plan: when
  doc_stale_outside_plan_requires is a string, the ruling's "by" must equal
  it. outside_plan_presumption (CODE-DIVERGES) states the default direction
  for a deviation found outside a plan and has no mechanical effect.
  The configuration extension is off unless config "config_adapter" names
  an adapter (surfaces; recorded [--rev <rev> | --staged] [--override
  KEY=VALUE]… → {key: {recorded, default}}; readers <path>…). Off, a claim's
  "when" or status gated is a V1 finding. On, each "when" key must be a
  recorded key (V1), a bound test must establish the claim's "when" (V3), a
  key its subject reads whose recorded value is not its default must be
  pinned in "when" unless "config_independent" says why not (V3), a built
  claim's "when" must hold under the recorded configuration (V3), gated
  needs an open tracker (V5), and run expects a gated claim to pass. V10
  re-classifies the gated, built and diverged claims whose "when" keys or
  subject's readers keys a configuration change touches — a staged surface
  (validate --staged), or validate --config KEY=VALUE — comparing recorded
  --rev <merge-base> with the proposed configuration: a gated claim now
  satisfied is an advisory (promote-owed: promote it to built once the
  change is committed); a built one no longer satisfied owes a new ruling,
  committed before the change (then promote re-gates it); a diverged one
  whose "when" the change switches on is a finding, whatever its rulings
  (fix the code and promote it, or retire it, first).

Exit status:
  0  success
  1  the operation failed or was refused (an invalid mapping line, a path
     outside the repo, a key not in the index, an unknown doc_type,
     build-index over a non-empty index without --force, …).
     update-index and deprecate-entry report and skip a path not in the
     index, apply the rest, then exit 1. audit-merges exits 1 on any
     finding (its JSON is on stdout) and on any failure (no JSON: a
     non-commit argument, the merge driver not beside doc-tools.sh, a jq
     failure). The one exception: remove-entry
     exits 0 for a key not in the index (SKIP), since the absent entry is
     the end state asked for.
  2  usage error: an unknown subcommand or option, an option without its
     value, the wrong number of arguments (including one given to a
     subcommand that takes none), or a repository subcommand run outside a
     git work tree or below its top level. A malformed argument value
     (bump-version abc) is 1 — except that set-implementation exits 2 for
     an invalid --status, a missing <path> or a multi-line --ref / --note,
     and fragments validate exits 2 for a <path> that is not a regular file.
  3  fragments merge refused: a release consumed fragments that are still
     present, because its release commit has not reached <range-end>

  The claims subcommands have their own codes instead:
  0  everything as expected
  1  findings (a blocking check failed)
  2  could not run: an adapter reported indeterminate or exited non-zero,
     the base did not resolve, the config is not one JSON object, a dirty
     tree where one is refused (gate, promote, attest --final), a missing
     dependency, a run outside a git work tree or below its top level, or
     an internal failure (never 1)
  3  usage error
  When several apply, the precedence is 1 > 2 > 0.

Environment:
  DOC_TOOLS_LOCK_TIMEOUT  Seconds a writer waits for the index lock before
                          failing (default 30). A lock whose recorded owner
                          is no longer running is removed automatically.
NOTES

# Look up a verb row: sets _VERB_HANDLER, _VERB_NEEDS and _VERB_OPTS.
_verb_lookup() {
  local want="$1" line rest
  while IFS= read -r line; do
    case "$line" in
      ''|' '*) continue ;;
    esac
    [ "${line%%|*}" = "$want" ] || continue
    rest="${line#*|}"
    _VERB_HANDLER="${rest%%|*}"
    rest="${rest#*|}"
    _VERB_NEEDS="${rest%%|*}"
    _VERB_OPTS="${rest#*|}"
    return 0
  done <<<"$_VERBS"
  return 1
}

# True if $1 names a group of two-word verbs ("tools", "fragments").
_verb_is_group() {
  local line
  case "$1" in
    ''|*[!abcdefghijklmnopqrstuvwxyz-]*) return 1 ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "$1 "*'|'*) return 0 ;;
    esac
  done <<<"$_VERBS"
  return 1
}

# Print the rows whose verb is $1 — or, with $1 = "*", every row; with a
# one-word group such as "tools", every "tools …" row. <indent> is the
# description's extra indent.
_verb_print() {
  local want="$1" prefix="$2" indent="$3" line verb="" show=0 first=0
  while IFS= read -r line; do
    case "$line" in
      '') continue ;;
      ' '*)
        [ "$show" = 1 ] || continue
        line="${line#  }"
        if [ "$first" = 1 ]; then
          first=0
          if [ "$line" = "-" ]; then
            printf '%s%s\n' "$prefix" "$verb"
          else
            printf '%s%s %s\n' "$prefix" "$verb" "$line"
          fi
        else
          printf '%s%s\n' "$indent" "$line"
        fi
        ;;
      *)
        verb="${line%%|*}"
        show=0
        case "$want" in
          '*') show=1 ;;
          "$verb") show=1 ;;
          *) case "$verb" in "$want "*) show=1 ;; esac ;;
        esac
        first="$show"
        ;;
    esac
  done <<<"$_VERBS"
}

# Full usage. Builtins only: --help must work without jq, and without git.
usage() {
  printf '%s\n' \
    "Usage: doc-tools.sh <subcommand> [options] [args]" \
    "       doc-tools.sh <subcommand> --help" \
    "" \
    "Subcommands:"
  _verb_print '*' '  ' '      '
  printf '\n%s' "$_USAGE_NOTES"
}

# One subcommand's (or one group's) usage.
_verb_usage() {
  _verb_print "$1" 'Usage: doc-tools.sh ' '  '
  printf '%s\n' "" "Options may appear anywhere; --opt VALUE and --opt=VALUE are the same." \
    "See doc-tools.sh --help for mapping lines, doc paths and exit status."
}

cmd_help() {
  if [ $# -eq 0 ]; then
    usage
    return 0
  fi
  if ! _verb_lookup "$*" && ! _verb_is_group "$*"; then
    _usage_error help "unknown subcommand '$*'"
  fi
  _verb_usage "$*"
}

# A command-line error: say what is wrong and where the usage is; exit 2
# (a claims verb: _claims_usage_error, exit 3 with its verdict object).
_usage_error() {
  if [ "$_CL_ACTIVE" = 1 ]; then _claims_usage_error "$1" "$2"; fi
  echo "ERROR: $1: $2" >&2
  echo "       See: doc-tools.sh $1 --help" >&2
  exit "$_USAGE_RC"
}

_is_long_opt() {
  case "$1" in
    --?*) return 0 ;;
  esac
  return 1
}

# True if option $1 was given on this command line.
_opt_seen() {
  local v="_OPTSEEN_${1//-/_}"
  [ -n "${!v:-}" ]
}

# _parse_args <verb> <options> [args…]
#
# The one argument loop every subcommand goes through (the verb table holds
# each verb's <options>). --opt VALUE and --opt=VALUE are the same and may
# appear anywhere; "--" ends the options; --help / -h prints the verb's usage
# and exits 0; anything else starting with "-" that the verb does not take is
# a usage error (exit 2) — it is never taken for a path, and never ignored.
# Positional arguments land in _ARGS.
_parse_args() {
  local verb="$1" spec="$2"
  shift 2
  _ARGS=()
  # Split the spec with read, never by an unquoted expansion: "name=*" would
  # undergo pathname expansion (a file "code-refs-from=zz" in the working
  # directory made --code-refs-from an unknown option).
  local specs=() s n
  read -r -a specs <<<"$spec"
  for s in ${specs[@]+"${specs[@]}"}; do
    n="${s%[=+]*}"
    n="${n//-/_}"
    printf -v "_OPT_$n" '%s' ""
    printf -v "_OPTSEEN_$n" '%s' ""
    eval "_OPTV_$n=()"
  done

  local a name val has_val kind endopts=0
  while [ $# -gt 0 ]; do
    a="$1"
    shift
    if [ "$endopts" = 1 ]; then
      _ARGS+=("$a")
      continue
    fi
    case "$a" in
      --) endopts=1; continue ;;
      -h|--help) _verb_usage "$verb"; _exit_ok ;;
      --?*=*) name="${a%%=*}"; name="${name#--}"; val="${a#*=}"; has_val=1 ;;
      --?*) name="${a#--}"; val=""; has_val=0 ;;
      -?*) _usage_error "$verb" "Unknown option '$a'" ;;
      *) _ARGS+=("$a"); continue ;;
    esac
    kind=""
    for s in ${specs[@]+"${specs[@]}"}; do
      case "$s" in
        "$name") kind=flag ;;
        "$name=") kind=one ;;
        "$name=*") kind=many ;;
        "$name+") kind=list ;;
      esac
    done
    n="${name//-/_}"
    case "$kind" in
      flag)
        [ "$has_val" = 0 ] || _usage_error "$verb" "option --$name takes no value"
        printf -v "_OPT_$n" '%s' 1
        ;;
      one|many)
        if [ "$has_val" = 0 ]; then
          if [ $# -eq 0 ] || _is_long_opt "$1"; then
            _usage_error "$verb" "option --$name requires a value"
          fi
          val="$1"
          shift
        fi
        if [ "$kind" = one ]; then
          ! _opt_seen "$name" || _usage_error "$verb" "option --$name given more than once"
          printf -v "_OPT_$n" '%s' "$val"
        else
          eval "_OPTV_$n+=(\"\$val\")"
        fi
        ;;
      list)
        if [ "$has_val" = 1 ]; then
          eval "_OPTV_$n+=(\"\$val\")"
        else
          if [ $# -eq 0 ] || _is_long_opt "$1"; then
            _usage_error "$verb" "option --$name requires at least one value"
          fi
          # Inline, not _is_long_opt per value: bash 3.2 copies "$@" on every
          # function call (see _targets_from_args), so a long list was O(k²).
          while [ $# -gt 0 ]; do
            case "$1" in
              --?*) break ;;
            esac
            eval "_OPTV_$n+=(\"\$1\")"
            shift
          done
        fi
        ;;
      *) _usage_error "$verb" "Unknown option '--$name'" ;;
    esac
    printf -v "_OPTSEEN_$n" '%s' 1
  done
}

# Repository verbs run only inside a git work tree, at its top level. Checked
# ONCE, up front: per-call `2>/dev/null || true` used to turn "not a
# repository" into "no history", and check-freshness reported every doc
# current, rc 0. Paths are keyed relative to the top level and resolved
# against the cwd, so from a subdirectory build-index wrote a stray
# sub/docs/.doc-index.json with keys of mixed bases.
_require_repo() {
  local prefix
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    _require_repo_fail "$1 must run inside a git repository (run doc-tools.sh from the repo root)."
  fi
  prefix=$(git rev-parse --show-prefix 2>/dev/null) || prefix=""
  if [ -n "$prefix" ]; then
    _require_repo_fail "$1 must run from the repository's top level, not from ${prefix%/}/ (doc paths are keyed from the root). Run: cd \"\$(git rev-parse --show-toplevel)\""
  fi
}
# Exit 2 — for a claims verb with its verdict object (could not run).
_require_repo_fail() {
  if [ "$_CL_ACTIVE" = 1 ]; then _claims_die "$1"; fi
  echo "ERROR: $1" >&2
  exit 2
}

# check_deps failed (it named what is missing): exit 1 — 2, with its verdict
# object, for a claims verb (could not run).
_deps_fail() {
  if [ "$_CL_ACTIVE" = 1 ]; then _claims_die "a required command is missing or too old (see the errors above)"; fi
  exit 1
}

# Dispatch. --help / help needs nothing: it runs before check_deps.
_main() {
  case "${1:-}" in
    '')
      usage >&2
      exit 2
      ;;
    -h|--help)
      usage
      _exit_ok
      ;;
  esac

  # A claims verb: its own exit family (usage = 3) and fd 9, the run's real
  # stdout, for its verdict — set before the lookup, so an unknown claims
  # subcommand is a claims usage error too (see "Spec claims").
  # _CL_VERB names the sub-verb in a usage error's object: the word after
  # "claims" until the lookup confirms it, "claims" when there is none.
  if [ "$1" = claims ]; then
    _USAGE_RC=3
    _CL_ACTIVE=1
    _CL_VERB="${2:-claims}"
    exec 9>&1
  fi

  local verb
  if [ $# -ge 2 ] && _verb_lookup "$1 $2"; then
    verb="$1 $2"
    shift 2
  elif _verb_lookup "$1"; then
    verb="$1"
    shift
  elif _verb_is_group "$1"; then
    # A group ("tools", "fragments") without a valid subcommand.
    case "${2:-}" in
      -h|--help) _verb_usage "$1"; _exit_ok ;;
      '') _usage_error "$1" "needs a subcommand" ;;
      *) _usage_error "$1" "unknown subcommand '$1 $2'" ;;
    esac
  else
    echo "ERROR: unknown subcommand '$1'." >&2
    echo "" >&2
    usage >&2
    exit 2
  fi
  if [ "$_CL_ACTIVE" = 1 ]; then _CL_VERB="${verb#claims }"; fi

  # --help anywhere before "--" wins, before any dependency is needed.
  local a
  for a in "$@"; do
    case "$a" in
      --) break ;;
      -h|--help) _verb_usage "$verb"; _exit_ok ;;
    esac
  done

  # Terminating traps before anything that can block (the repository check
  # runs git), so a signal at any point from here ends the run through cleanup.
  _traps
  _parse_args "$verb" "$_VERB_OPTS" "$@"
  case "$_VERB_NEEDS" in
    repo) check_deps || _deps_fail; _require_repo "$verb" ;;
    deps) check_deps || _deps_fail ;;
  esac
  "$_VERB_HANDLER" ${_ARGS[@]+"${_ARGS[@]}"}
}

# --- Mapping lines (stdin of build-index and add-entry) ------------------------
#
# ONE parser for `doc_path:code_refs_csv:doc_type` lines. The old one cut each
# field with `cut -d:` and trusted the result: a bare path (no ':') came back
# as the path, the refs AND the doc_type; "a, b" stored " b", a ref nothing
# ever matches; a CRLF file kept "\r" in doc_type; a ':' inside a path
# re-keyed the entry; and the refs handed to git were split separately from
# the refs that were stored.

_line_error() {
  echo "ERROR: line $1: $3: '$2'" >&2
}

# _entry_from_line <line-no> <line>
# Parse one mapping line into _E_PATH (the normalized key), _E_TYPE and
# _E_REFS: trimmed, empty ones dropped, key-form normalized ("." is the repo
# root). That ONE array is both stored as code_refs and handed to git. Returns
# 1, having said why on stderr, for a line that breaks the format.
_entry_from_line() {
  local lineno="$1" line="${2%$'\r'}"
  local path refs type extra
  _E_PATH="" _E_TYPE="" _E_REFS=()
  case "$line" in
    *:*:*:*)
      _line_error "$lineno" "$line" "more than three ':'-separated fields (a doc path or ref may not contain ':')"
      return 1
      ;;
    *:*) ;;
    *)
      _line_error "$lineno" "$line" "a bare path; expected doc_path:code_refs_csv:doc_type"
      return 1
      ;;
  esac
  case "$line" in
    *$'\x1f'*)
      _line_error "$lineno" "$line" "contains a 0x1f control character"
      return 1
      ;;
  esac
  IFS=: read -r path refs type extra <<<"$line"
  if [ -n "$extra" ]; then
    _line_error "$lineno" "$line" "more than three ':'-separated fields"
    return 1
  fi
  # A ':' inside a doc path cannot be told from the field separator:
  # `docs/a:b.md` reads as path docs/a with ref b.md (and with doc_type
  # omitted, which is allowed, a three-field line parses cleanly too). When the
  # first field names no file but the first two or three fields joined by ':'
  # do, the line is ambiguous: refuse it rather than index the wrong key. (A
  # ':'-path whose file does not exist yet cannot be detected.)
  if [ ! -f "$path" ]; then
    if [ -e "$path:$refs" ] || { case "$line" in *:*:*) [ -e "$path:$refs:$type" ] ;; *) false ;; esac; }; then
      _line_error "$lineno" "$line" "ambiguous: a file named with ':' exists, but ':' separates the fields (a doc path may not contain ':')"
      return 1
    fi
  fi
  _trim "$path"
  if ! _norm_path "$_TRIMMED"; then
    echo "       (line $lineno)" >&2
    return 1
  fi
  _E_PATH="$_NORM"
  _trim "$type"
  _E_TYPE="$_TRIMMED"
  _refs_from_csv "$refs" "line $lineno"
}

# _refs_from_csv <code_refs_csv> [<where>]
# Split a comma-separated ref list into _E_REFS: each ref trimmed, empty ones
# dropped, key-form normalized ("." or "./" is the repository root). The one
# ref parser, for mapping lines and set-code-refs alike, and that ONE array is
# both stored as code_refs and handed to git. Returns 1, having said why (and
# <where>, e.g. "line 3") on stderr, for a ref that cannot be a key.
_refs_from_csv() {
  local csv="$1" where="${2:-}" r raw=()
  _E_REFS=()
  IFS=, read -r -a raw <<<"$csv"
  for r in ${raw[@]+"${raw[@]}"}; do
    _trim "$r"
    r="$_TRIMMED"
    case "$r" in
      '') continue ;;
      .|./) r=. ;;
      *)
        if ! _norm_path "$r" "code ref"; then
          [ -z "$where" ] || echo "       ($where)" >&2
          return 1
        fi
        r="$_NORM"
        ;;
    esac
    _E_REFS+=("$r")
  done
}

# _read_mapping <verb> <out-file>
# Read mapping lines from stdin with _entry_from_line. A key listed twice
# keeps its FIRST line (the rest are warned about), in both build-index and
# add-entry. Sets _M_KEYS (the kept keys, in input order) and _M_INVALID, and
# writes one _rec_put record per kept entry to <out-file> (_entry_facts
# gathers the facts, each in one batch):
#   key  content_hash ("" if not on disk)  code_commit ("" if none)
#   doc_type  refs (\x1f-joined)  code_oids (\x1f-joined, in ref order)
_read_mapping() {
  local verb="$1" out="$2"
  local lineno=0 line keys=() types=() refsets=() joined r
  _M_KEYS=() _M_INVALID=0
  : > "$out"
  if [ -t 0 ]; then
    echo "$verb: reading mapping lines from stdin (doc_path:code_refs_csv:doc_type); end with Ctrl-D." >&2
  fi
  # stdin → fd 3, fd 0 → /dev/null: no child process can eat mapping lines.
  exec 3<&0 0</dev/null
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    _trim "${line%$'\r'}"
    [ -n "$_TRIMMED" ] || continue
    if ! _entry_from_line "$lineno" "$line"; then
      _M_INVALID=$((_M_INVALID + 1))
      continue
    fi
    joined=""
    for r in ${_E_REFS[@]+"${_E_REFS[@]}"}; do
      joined="${joined:+$joined$'\x1f'}$r"
    done
    keys+=("$_E_PATH")
    types+=("$_E_TYPE")
    refsets+=("$joined")
  done
  exec 3<&-
  [ ${#keys[@]} -gt 0 ] || return 0

  local dups
  dups=$(_repeated "${keys[@]}")
  if [ -n "$dups" ]; then
    while IFS= read -r r; do
      echo "WARNING: '$r' is listed more than once; keeping its first line." >&2
    done <<<"$dups"
  fi

  local i=0 seen=$'\n' kept_types=()
  _FACT_KEYS=() _FACT_REFSETS=()
  while [ "$i" -lt "${#keys[@]}" ]; do
    if [ -n "$dups" ]; then
      case $'\n'"$dups"$'\n' in
        *$'\n'"${keys[$i]}"$'\n'*)
          case "$seen" in
            *$'\n'"${keys[$i]}"$'\n'*) i=$((i + 1)); continue ;;
          esac
          seen="$seen${keys[$i]}"$'\n'
          ;;
      esac
    fi
    _FACT_KEYS+=("${keys[$i]}")
    _FACT_REFSETS+=("${refsets[$i]}")
    kept_types+=("${types[$i]}")
    i=$((i + 1))
  done
  _M_KEYS=("${_FACT_KEYS[@]}")
  _entry_facts 1 doc
  i=0
  while [ "$i" -lt "${#_M_KEYS[@]}" ]; do
    _rec_put "${_M_KEYS[$i]}" "${_FACT_HASH[$i]}" "${_FACT_COMMIT[$i]}" "${kept_types[$i]}" \
      "${_FACT_REFSETS[$i]}" "${_FACT_OIDS[$i]}"
    i=$((i + 1))
  done > "$out"
}

# jq: code_oids from a record's \x1f-joined refs and object ids (same order).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CODE_OIDS='
  def code_oids($refs; $oids):
    [range(0; $refs | length) as $j | {key: $refs[$j], value: $oids[$j]}] | from_entries;
  def fields_list: if . == "" then [] else split("\u001f") end;'

# jq (after $_JQ_REC_FIELDS and $_JQ_CODE_OIDS): the _read_mapping records as
# a {key: entry} object of fresh entries (field order is the index's). No
# status (it is stored only as "deprecated"), and last_verified is null:
# writing an entry is not re-baselining its doc — only update-index does.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_MAPPING_ENTRIES='
  def mapping_entries:
    rec_fields as $f
    | [range(0; $f | length; 6) as $i
       | ($f[$i + 4] | fields_list) as $refs
       | {key: $f[$i], value: {
           content_hash: (if $f[$i + 1] == "" then null else $f[$i + 1] end),
           code_refs: $refs,
           code_oids: code_oids($refs; $f[$i + 5] | fields_list),
           code_commit: (if $f[$i + 2] == "" then null else $f[$i + 2] end),
           doc_type: $f[$i + 3],
           replaces: null,
           superseded_by: null,
           last_verified: null}}]
    | from_entries;'

# --- Subcommands -----------------------------------------------------------------

cmd_build_index() {
  if [ $# -gt 0 ]; then
    _usage_error build-index "takes no arguments; it reads mapping lines from stdin (got '$1')"
  fi
  _scratch_init
  _index_now
  local force="${_OPT_force:-}"

  # build-index REPLACES the index: refuse up front, before stdin is read,
  # when there is one with entries and --force was not given. (An agent's
  # non-TTY shell hands it an empty stdin, and a one-line pipe used to leave
  # a one-key index; either way every deprecation was reset.) A missing or
  # invalid index is still rebuilt: that is how one recovers from it. The
  # same check runs again under the lock (below), against the index actually
  # being replaced.
  if [ -z "$force" ] && [ -f "$INDEX_FILE" ]; then
    local have
    have=$(jq -s 'if length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"
                  then .[0].docs | length else 0 end' "$INDEX_FILE" 2>/dev/null) || have=0
    if [ "${have:-0}" -gt 0 ]; then
      echo "ERROR: $INDEX_FILE already has $have $([ "$have" -eq 1 ] && echo entry || echo entries); build-index would replace them all." >&2
      echo "       Use add-entry, update-index or remove-entry for incremental changes, or" >&2
      echo "       build-index --force to rebuild from scratch (every entry is re-recorded unverified; only each re-indexed key's deprecation is kept)." >&2
      exit 1
    fi
  fi

  local rec="$_SCRATCH/map.rec" docs_tmp="$_SCRATCH/docs.json"
  _read_mapping build-index "$rec"

  # One bad line aborts the whole build: it replaces the index, so writing
  # the good lines alone would silently drop docs.
  if [ "$_M_INVALID" -gt 0 ]; then
    echo "ERROR: $_M_INVALID invalid mapping $([ "$_M_INVALID" -eq 1 ] && echo line || echo lines) in build-index input; index NOT written." >&2
    exit 1
  fi
  if [ ${#_M_KEYS[@]} -eq 0 ]; then
    echo "ERROR: build-index: no mapping lines on stdin (doc_path:code_refs_csv:doc_type); index NOT written." >&2
    exit 1
  fi

  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -c -n -R --arg now "$_INDEX_NOW" "$_JQ_REC_FIELDS$_JQ_CODE_OIDS$_JQ_MAPPING_ENTRIES"'mapping_entries' \
    < "$rec" > "$docs_tmp" || _die "cannot assemble the index entries; $INDEX_FILE is unchanged."

  # schema_version: 2 added the per-entry `implementation` array and renamed
  # `version` (v2.11.0); 3 added code_oids (sweep 05ea982 I-1 — see "Content
  # identity").
  #
  # `docs` arrives via --slurpfile, NOT --argjson: it is the one unbounded
  # value here, and Linux caps a single argv string at MAX_ARG_STRLEN (131072
  # bytes), which once capped the index at ~420 entries.
  #
  # --replace: a missing or invalid prior index is replaced rather than
  # refused. generated_at is stamped by _index_apply ($now), and nothing is
  # written if the result is identical. build_commit is null on an unborn
  # HEAD (it used to be "HEAD\nunknown").
  #
  # A deprecation is a human decision no mapping line can express, so a
  # rebuild (--force) keeps it for every key it re-indexes: status
  # "deprecated", superseded_by and replaces are carried over from the index
  # being replaced. Everything else is re-recorded.
  _head_init
  mkdir -p "$(dirname "$INDEX_FILE")"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  _index_apply --replace '
    if ($force | not) and type == "object" and ((.docs // {}) | length) > 0
    then error("doc-tools: refusing to replace a non-empty index without --force (it gained entries while build-index ran)")
    else . end
    | (if type == "object" and (.docs | type) == "object" then .docs else {} end) as $prev
    | {
      schema_version: '"$_SCHEMA_VERSION"',
      generated_by: "doc-superpowers",
      generated_at: $now,
      build_commit: (if $build_commit == "" then null else $build_commit end),
      docs: ($docs[0] | with_entries(
        ($prev[.key] // null) as $o
        | if ($o | type) != "object" then .
          else .value += ({}
            + (if ($o.superseded_by // null) != null then {superseded_by: $o.superseded_by} else {} end)
            + (if ($o.replaces // null) != null then {replaces: $o.replaces} else {} end)
            + (if $o.status == "deprecated" then {status: "deprecated"} else {} end))
          end))
    }' \
    --argjson force "$([ -n "$force" ] && echo true || echo false)" \
    --arg build_commit "$_HEAD" \
    --slurpfile docs "$docs_tmp"
  # Silent on success, as before: it replaces the whole index, so a per-key
  # report would only restate its input.
}

# Paths for --code-refs / --code-refs-from, one per line, into <file>. The
# list is normalized in jq (_JQ_FRESH_EXTRACT): CR stripped, blank lines
# dropped, "." and "//" segments folded. "-" reads stdin.
_code_refs_list() {
  local out="$1" p src
  : > "$out"
  for p in ${_OPTV_code_refs[@]+"${_OPTV_code_refs[@]}"}; do
    printf '%s\n' "$p" >> "$out"
  done
  # One path per line, or NUL-separated (git diff -z: no name is quoted); a
  # path holds no NUL, so NUL is only ever a separator.
  for src in ${_OPTV_code_refs_from[@]+"${_OPTV_code_refs_from[@]}"}; do
    if [ "$src" = "-" ]; then
      tr '\000' '\n' >> "$out" || _die "cannot read the --code-refs-from list from stdin"
    else
      [ -f "$src" ] || _die "--code-refs-from: no such file '$src'"
      tr '\000' '\n' < "$src" >> "$out" || _die "cannot read --code-refs-from '$src'"
    fi
    printf '\n' >> "$out"
  done
}

cmd_check_freshness() {
  if [ $# -gt 0 ]; then
    _usage_error check-freshness "takes no arguments (got '$1'); scope it with --code-refs <path>... or --code-refs-from <file|->"
  fi
  _check_tree_opt check-freshness
  # ONE validated snapshot serves the entry walk and the untracked-key set:
  # reading the live file twice let a concurrent writer land in between. With
  # --tree it is the tree's index (see _reader_snapshot).
  _scratch_init
  local snap
  _reader_snapshot
  snap="$_SNAP"

  local filter=""
  if _opt_seen code-refs || _opt_seen code-refs-from; then
    filter="$_SCRATCH/code-refs"
    _code_refs_list "$filter"
  fi

  local checked_at results="$_SCRATCH/fresh.rec" fs_paths="$_SCRATCH/fs-paths"
  checked_at=$(iso_now)
  _freshness_scan "$snap" "" "$filter" "$results"

  # Untracked: docs with no index key, on disk or (tree mode) in the tree.
  # The key set comes from the same snapshot, read by the final jq.
  if [ -n "$_DOCS_TREE" ]; then
    git ls-tree -r -z --name-only "$_DOCS_TREE" -- docs 2>/dev/null | tr '\000' '\n' \
      | awk '/\.md$/ && !/^docs\/archive\//' | LC_ALL=C sort > "$fs_paths"
  else
    find docs -name '*.md' -not -path 'docs/archive/*' 2>/dev/null | LC_ALL=C sort > "$fs_paths"
  fi

  # The report in ONE jq: per-doc results (a --slurpfile/--rawfile/stdin
  # value each, never argv — Linux caps one argv string at 131072 bytes), the
  # summary counted from them, so the two cannot disagree.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -n -R --arg checked_at "$checked_at" --arg repo_head "$_HEAD" \
    --rawfile fs "$fs_paths" --slurpfile idx "$snap" \
    "$_JQ_REC_FIELDS$_JQ_FRESH_RESULTS"'
    results as $docs
    | $idx[0].docs as $all
    | [$fs | split("\n")[] | select(. != "") | . as $p | select($all | has($p) | not)] as $untracked
    | def count($s): [$docs[] | select(.status == $s)] | length;
    {
      checked_at: $checked_at,
      repo_head: (if $repo_head == "" then null else $repo_head end),
      summary: {current: count("current"), stale: count("stale"), missing: count("missing"),
                deprecated: count("deprecated"), untracked: ($untracked | length)},
      untracked_docs: $untracked,
      docs: $docs
    }' < "$results"
}

cmd_update_index() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  [ $# -gt 0 ] || _usage_error update-index "requires at least one doc path argument"

  local targets=() doc_path
  _targets_from_args "$@"
  targets=("${_TARGETS[@]}")
  set --   # see _targets_from_args: keep function calls O(1) under bash 3.2

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

  # An unknown key is reported and skipped; the rest of the batch is still
  # applied, and the run exits 1 at the end. (It used to abort the whole
  # batch, so one typo in a list of 20 re-baselined nothing.) Refs are kept in
  # one flat array with per-target offsets (bash 3.2 has no arrays of arrays).
  local has n j ref idx=0 unknown=0
  local ref_all=() ref_start=() ref_count=() indexed=()
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
    indexed+=("$has")
    if [ "$has" != "1" ]; then
      echo "ERROR: '${targets[$idx]}' not found in index; skipped. Use add-entry to add new docs." >&2
      unknown=$((unknown + 1))
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
    if [ "${indexed[$idx]}" != "1" ]; then
      :
    elif [ ! -f "$doc_path" ]; then
      echo "WARNING: '$doc_path' no longer exists on disk. Skipping." >&2
      # The path is quoted INSIDE the advice string: a doc path containing a
      # space would otherwise paste as three arguments and trip move-entry's
      # arity guard — misleading exactly the operator who follows the advice.
      echo "         If it was RENAMED, use: move-entry \"$doc_path\" <new-path>" >&2
      echo "         To change which code it covers, use: set-code-refs \"$doc_path\" --refs <ref>[,<ref>...]" >&2
      echo "         (remove-entry + add-entry would drop its deprecation, replaces, implementation and last_verified.)" >&2
      echo "         If it was deleted, use remove-entry or deprecate-entry to clean up." >&2
    else
      live+=("$doc_path")
      live_idx+=("$idx")
    fi
    idx=$((idx + 1))
  done

  # Implementation: (ADRs) / Realized-by: (SPECs) entries, for every live doc
  # in ONE awk pass (a fork+exec per doc dominated the batch), read with the
  # one block grammar (_AWK_IMPL_BLOCK) that implementation-status and
  # set-implementation use, and the entry accumulator (blk_collect) that
  # implementation-status uses; each entry is tagged with its ARGV index. Empty
  # files never reach FNR == 1, so argi catches up by name. Both fields are
  # stored under the single JSON key "implementation" (v2.11.0), so a consumer
  # reads realization state from one key whatever the doc type.
  local impl=() tagged ai line p awk_files=()
  if [ ${#live[@]} -gt 0 ]; then
    # "./" keeps a doc named like "x=1.md" from being an awk assignment.
    for p in "${live[@]}"; do
      case "$p" in
        /*) awk_files+=("$p") ;;
        *) awk_files+=("./$p") ;;
      esac
    done
    # shellcheck disable=SC2016  # awk program, not shell expansion
    tagged=$(awk "$_AWK_IMPL_BLOCK"'
        FNR == 1 {
          blk_flush(argi)
          argi++
          while (argi < ARGC && ARGV[argi] != FILENAME) argi++
          blk_reset()
        }
        blk == 2 { next }
        { blk_collect(blk_line($0), argi) }
        END { blk_flush(argi) }
    ' "${awk_files[@]}") || _die "cannot read the Implementation: / Realized-by: blocks"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Split by hand: `IFS=$'\t' read` would also trim a tab-indented bullet.
      ai="${line%%$'\t'*}"
      line="${line#*$'\t'}"
      ai=$((ai - 1))
      impl[$ai]="${impl[$ai]:+${impl[$ai]}$'\n'}$line"
    done <<< "$tagged"
  fi

  # What is recorded for each live doc — its hash, code_commit and code_oids
  # (the refs as the working tree holds them) — each gathered in ONE batch
  # (_entry_facts). The refs stay as stored for the code_oids keys; a ref
  # holding a newline (only a hand-edited index has one) cannot be one line
  # of a lookup, and is given to git as ".." (unaddressable: "missing").
  local raw="$_SCRATCH/update-raw" patch="$_SCRATCH/update-patch.jsonl"
  local k=0 start count set fset stored_sets=()
  _FACT_KEYS=() _FACT_REFSETS=()
  while [ "$k" -lt "${#live[@]}" ]; do
    idx="${live_idx[$k]}"
    start="${ref_start[$idx]}"
    count="${ref_count[$idx]}"
    set="" fset=""
    j=0
    while [ "$j" -lt "$count" ]; do
      ref="${ref_all[$((start + j))]}"
      set="${set:+$set$'\x1f'}$ref"
      case "$ref" in
        *$'\n'*) ref=.. ;;
      esac
      fset="${fset:+$fset$'\x1f'}$ref"
      j=$((j + 1))
    done
    _FACT_KEYS+=("${live[$k]}")
    _FACT_REFSETS+=("$fset")
    stored_sets+=("$set")
    k=$((k + 1))
  done
  _entry_facts 0
  k=0
  while [ "$k" -lt "${#live[@]}" ]; do
    _rec_put "${live[$k]}" "${_FACT_HASH[$k]}" "${_FACT_COMMIT[$k]}" "${impl[$k]:-}" \
      "${stored_sets[$k]}" "${_FACT_OIDS[$k]}"
    k=$((k + 1))
  done > "$raw"

  # Re-baseline: re-hash, re-read code_commit and code_oids, stamp
  # last_verified (update-index is the ONE baseline reset), capture
  # implementation (each entry's text: no indent, no "- ", wrapped lines
  # joined).
  # Preserved: status (a deprecated entry stays deprecated; no other status
  # is stored), replaces, superseded_by, doc_type, code_refs, and the
  # top-level build_commit.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -c -n -R --arg now "$_INDEX_NOW" "$_JQ_REC_FIELDS$_JQ_CODE_OIDS"'
    rec_fields as $f
    | range(0; $f | length; 6) as $i
    | {key: $f[$i], merge: {
        content_hash: $f[$i + 1],
        code_commit: (if $f[$i + 2] == "" then null else $f[$i + 2] end),
        code_oids: code_oids($f[$i + 4] | fields_list; $f[$i + 5] | fields_list),
        last_verified: $now,
        implementation: (if $f[$i + 3] == "" then [] else ($f[$i + 3] | split("\n")) end)}}
  ' < "$raw" > "$patch" || _die "cannot assemble the update; $INDEX_FILE is unchanged."

  _index_apply --report "$_INDEX_PATCH" --slurpfile patch "$patch"

  # Report what was written (the patch rows are the live docs, in order).
  # Every one is a baseline reset, and stamps last_verified:
  #   Refreshed    something it records changed too — the doc's hash, its
  #                code's content (code_oids, code_commit) or its
  #                Implementation: bullets
  #   Re-verified  nothing but last_verified changed: a real write, so never
  #                reported as unchanged
  #   Unchanged    re-baselined in this same second already: nothing was written
  local refreshed=() reverified=() unchanged=()
  k=0
  while [ "$k" -lt "${#live[@]}" ]; do
    case "${_INDEX_CLASSES:$k:1}" in
      c) refreshed+=("${live[$k]}") ;;
      v) reverified+=("${live[$k]}") ;;
      *) unchanged+=("${live[$k]}") ;;
    esac
    k=$((k + 1))
  done
  _report_keys "Refreshed" "" "${refreshed[@]+"${refreshed[@]}"}"
  if [ ${#reverified[@]} -gt 0 ]; then
    _report_keys "Re-verified" "(no change since the last verification; last_verified stamped)" "${reverified[@]}"
  fi
  if [ ${#unchanged[@]} -gt 0 ]; then
    _report_keys "Unchanged" "(already verified at $_INDEX_NOW; nothing written)" "${unchanged[@]}"
  fi
  if [ "$unknown" -gt 0 ]; then
    echo "$unknown $([ "$unknown" -eq 1 ] && echo path was || echo paths were) not in the index (see above)." >&2
    exit 1
  fi
}

cmd_add_entry() {
  if [ $# -gt 0 ]; then
    _usage_error add-entry "takes no arguments; it reads mapping lines from stdin (got '$1')"
  fi
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  _scratch_init
  _index_now

  # Facts about each doc (hash, code_commit) do not depend on the index, so
  # they are gathered WITHOUT the lock — stdin may be slow. The "add" patch
  # rows only insert keys that are still absent when applied under the lock,
  # so a concurrent writer cannot be clobbered.
  local rec="$_SCRATCH/add.rec" patch="$_SCRATCH/add-patch.jsonl"
  _read_mapping add-entry "$rec"

  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -c -n -R --arg now "$_INDEX_NOW" "$_JQ_REC_FIELDS$_JQ_CODE_OIDS$_JQ_MAPPING_ENTRIES"'
    mapping_entries | to_entries[] | {key: .key, add: .value}' < "$rec" > "$patch" \
    || _die "cannot assemble the new entries; $INDEX_FILE is unchanged."

  _index_apply --report "$_INDEX_PATCH" --slurpfile patch "$patch"

  # Report what actually happened, in input order (the patch rows are
  # _M_KEYS, in order): a key that was already indexed was not added.
  local added=() i=0
  while [ "$i" -lt "${#_M_KEYS[@]}" ]; do
    if [ "${_INDEX_CLASSES:$i:1}" = c ]; then
      added+=("${_M_KEYS[$i]}")
    else
      echo "SKIP: '${_M_KEYS[$i]}' already in index. Use update-index to re-verify it, or set-code-refs to change its code_refs." >&2
    fi
    i=$((i + 1))
  done
  _report_keys "Added" "" "${added[@]+"${added[@]}"}"

  if [ "$_M_INVALID" -gt 0 ]; then
    echo "Rejected $_M_INVALID invalid mapping $([ "$_M_INVALID" -eq 1 ] && echo line || echo lines)." >&2
    exit 1
  fi
}

cmd_remove_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  [ $# -gt 0 ] || _usage_error remove-entry "requires at least one doc path argument"

  # Normalize every path up front so an unusable one aborts before we mutate the
  # index. Without this an absolute path merely reported "not found in index" and
  # exited 0 — a silent no-op for a caller who asked to remove a real entry.
  # Repeats (docs/a.md docs//a.md) are one target.
  local targets=() doc_path
  _targets_from_args "$@"
  targets=("${_TARGETS[@]}")
  set --   # see _targets_from_args: keep function calls O(1) under bash 3.2

  _scratch_init
  local patch="$_SCRATCH/remove-patch.jsonl"
  jq -nc '$ARGS.positional[] | {key: ., del: true}' --args "${targets[@]}" > "$patch"
  _index_apply --report "$_INDEX_PATCH" --slurpfile patch "$patch"

  # A present key is always removed, so "not changed" means "not indexed".
  # That is a SKIP, not a failure (exit 0): the entry being absent is the end
  # state asked for — the one documented exception to "a key not in the
  # index exits 1".
  local removed=() i=0
  while [ "$i" -lt "${#targets[@]}" ]; do
    if [ "${_INDEX_CLASSES:$i:1}" = c ]; then
      removed+=("${targets[$i]}")
    else
      echo "SKIP: '${targets[$i]}' not found in index." >&2
    fi
    i=$((i + 1))
  done
  _report_keys "Removed" "" "${removed[@]+"${removed[@]}"}"
}

# move-entry --stdin: read "<old>\t<new>" lines from stdin into _MV_OLD /
# _MV_NEW (normalized; a same-path pair is skipped, a pair listed twice counts
# once). Every line is checked; each bad one is reported (by line number) and
# counted in _MV_BAD. A path that is the source, or the target, of two
# different pairs is bad too: a batch is one simultaneous rename.
_read_move_pairs() {
  local lineno=0 line old new pairs=() dups r
  _MV_OLD=() _MV_NEW=() _MV_BAD=0
  if [ -t 0 ]; then
    echo "move-entry: reading <old><TAB><new> lines from stdin; end with Ctrl-D." >&2
  fi
  # stdin → fd 3, fd 0 → /dev/null: no child process can eat the pairs.
  exec 3<&0 0</dev/null
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    _trim "$line"
    [ -n "$_TRIMMED" ] || continue
    case "$line" in
      *$'\t'*$'\t'*)
        _line_error "$lineno" "$line" "more than one TAB; expected <old><TAB><new>"
        _MV_BAD=$((_MV_BAD + 1)); continue ;;
      *$'\t'*) ;;
      *)
        _line_error "$lineno" "$line" "no TAB; expected <old><TAB><new>"
        _MV_BAD=$((_MV_BAD + 1)); continue ;;
    esac
    _trim "${line%%$'\t'*}"
    if ! _norm_path "$_TRIMMED" "old doc path"; then
      echo "       (line $lineno)" >&2
      _MV_BAD=$((_MV_BAD + 1)); continue
    fi
    old="$_NORM"
    _trim "${line#*$'\t'}"
    if ! _norm_path "$_TRIMMED" "new doc path"; then
      echo "       (line $lineno)" >&2
      _MV_BAD=$((_MV_BAD + 1)); continue
    fi
    new="$_NORM"
    if [ "$old" = "$new" ]; then
      echo "SKIP: '$old' — old and new path are the same; nothing to move (line $lineno)." >&2
      continue
    fi
    pairs+=("$old"$'\t'"$new")
  done
  exec 3<&-
  [ ${#pairs[@]} -gt 0 ] || return 0
  dups=$(_repeated "${pairs[@]}")
  if [ -n "$dups" ]; then
    while IFS= read -r r; do
      echo "WARNING: the pair '${r%%$'\t'*}' -> '${r#*$'\t'}' is listed more than once; moving it once." >&2
    done <<<"$dups"
  fi
  _first_occurrences "$dups" "${pairs[@]}"
  for r in "${_FIRST[@]}"; do
    _MV_OLD+=("${r%%$'\t'*}")
    _MV_NEW+=("${r#*$'\t'}")
  done
  dups=$(_repeated "${_MV_OLD[@]}")
  if [ -n "$dups" ]; then
    while IFS= read -r r; do
      echo "ERROR: '$r' is the old path of more than one pair." >&2
      _MV_BAD=$((_MV_BAD + 1))
    done <<<"$dups"
  fi
  dups=$(_repeated "${_MV_NEW[@]}")
  if [ -n "$dups" ]; then
    while IFS= read -r r; do
      echo "ERROR: '$r' is the new path of more than one pair." >&2
      _MV_BAD=$((_MV_BAD + 1))
    done <<<"$dups"
  fi
}

cmd_move_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  # A move is inherently PAIRED, so the argument form takes exactly one pair.
  # A varargs `move-entry old1 new1 old2 new2` form would silently mis-pair on
  # an odd argument count, and the failure mode is an index full of wrong
  # keys. A batch comes on stdin instead (--stdin), one self-delimiting
  # "<old>\t<new>" line per pair (PR #16, Option A).
  local olds=() news=() bad=0
  if _opt_seen stdin; then
    [ $# -eq 0 ] || _usage_error move-entry "--stdin reads <old><TAB><new> lines from stdin and takes no path arguments (got '$1')"
    _read_move_pairs
    bad="$_MV_BAD"
    olds=(${_MV_OLD[@]+"${_MV_OLD[@]}"})
    news=(${_MV_NEW[@]+"${_MV_NEW[@]}"})
  else
    [ $# -eq 2 ] || _usage_error move-entry "requires exactly two arguments: <old_doc_path> <new_doc_path> (got $#), or --stdin with <old><TAB><new> lines"
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
    olds=("$old_path")
    news=("$new_path")
  fi
  set --

  if [ ${#olds[@]} -eq 0 ]; then
    if [ "$bad" -gt 0 ]; then
      echo "ERROR: $bad invalid $([ "$bad" -eq 1 ] && echo pair || echo pairs); nothing moved, $INDEX_FILE is unchanged." >&2
      exit 1
    fi
    _report_keys "Moved" ""
    return 0
  fi

  _scratch_init
  # Every check below and the write see the same index, so all of it happens
  # under the lock.
  _index_lock
  local snap flags="$_SCRATCH/move-flags"
  snap=$(_index_load) || exit 1
  # Per pair, in one pass: is <old> indexed; is <new> indexed and NOT vacated
  # by another pair of the batch (the pairs are one simultaneous rename, so a
  # chain a→b, b→c needs no ordering); is <old> refilled by another pair.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -r --argjson n "${#olds[@]}" '.docs as $d | $ARGS.positional as $a
    | ([$a[0:$n][] | {key: ., value: true}] | from_entries) as $src
    | ([$a[$n:][] | {key: ., value: true}] | from_entries) as $dst
    | range(0; $n) as $i
    | (if ($d | has($a[$i])) then "1" else "0" end)
      + (if ($d | has($a[$n + $i])) and ($src[$a[$n + $i]] | not) then "1" else "0" end)
      + (if $dst[$a[$i]] then "1" else "0" end)' \
    --args "${olds[@]}" "${news[@]}" < "$snap" > "$flags" || _die "cannot read $INDEX_FILE"

  # Every pair is checked, and every problem reported, before anything is
  # written: one bad pair writes nothing.
  local i=0 fl warn=()
  while IFS= read -r fl; do
    if [ "${fl:0:1}" != 1 ]; then
      echo "ERROR: '${olds[$i]}' not found in index. Nothing to move." >&2
      bad=$((bad + 1))
    fi
    # Refuse to clobber: overwriting the destination would discard ITS
    # metadata, which is the precise loss move-entry exists to prevent.
    if [ "${fl:1:1}" = 1 ]; then
      echo "ERROR: '${news[$i]}' is already in the index. Refusing to overwrite it." >&2
      echo "       Remove it first (remove-entry) if it is genuinely obsolete." >&2
      bad=$((bad + 1))
    fi
    # Unlike add-entry — which tolerates a not-yet-written doc because it
    # supports authoring — re-keying onto a path with no file on it is a typo,
    # and it would mint an entry with a null hash: unfindable, and permanently
    # "current" because there is nothing to hash-compare. Refuse.
    if [ ! -f "${news[$i]}" ]; then
      echo "ERROR: '${news[$i]}' does not exist on disk. Move the file first, then re-key." >&2
      bad=$((bad + 1))
    fi
    # The old file still being present is legitimate — a partially-staged
    # `git mv`, or a deliberate copy-then-reindex — so warn rather than
    # refuse. But do not stay silent: a copy-instead-of-move typo leaves an
    # orphaned unindexed doc on disk that resurfaces later as an untracked
    # file. (A path the batch vacates and refills is no orphan.)
    if [ -f "${olds[$i]}" ] && [ "${fl:2:1}" != 1 ]; then
      warn+=("${olds[$i]}")
    fi
    i=$((i + 1))
  done < "$flags"
  if [ "$bad" -gt 0 ]; then
    if _opt_seen stdin; then
      echo "ERROR: $bad $([ "$bad" -eq 1 ] && echo problem || echo problems) in the batch; nothing moved, $INDEX_FILE is unchanged." >&2
    fi
    exit 1
  fi
  for fl in ${warn[@]+"${warn[@]}"}; do
    echo "WARNING: '$fl' still exists on disk; it will be left unindexed." >&2
  done

  # The new paths hashed in one batch; each pair travels as a _rec_put record.
  local names="$_SCRATCH/move-names" hashes="$_SCRATCH/move-hashes" recs="$_SCRATCH/move-recs"
  local map="$_SCRATCH/move-map.json" h
  printf '%s\0' "${news[@]}" > "$names"
  _hash_list "$names" "$hashes"
  i=0
  while IFS= read -r h; do
    _rec_put "${olds[$i]}" "${news[$i]}" "$h"
    i=$((i + 1))
  done < "$hashes" > "$recs"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -n -R "$_JQ_REC_FIELDS"'rec_fields as $f
    | [range(0; $f | length; 3) as $i | {key: $f[$i], value: {new: $f[$i + 1], hash: $f[$i + 2]}}]
    | from_entries' < "$recs" > "$map" || _die "cannot assemble the moves; $INDEX_FILE is unchanged."

  # The entries other than the moved ones whose replaces / superseded_by name
  # a moved path, and the entries (moved ones included, under their new key)
  # whose code_refs name one, for the report (the same snapshot the write sees).
  local repointed=() refs_repointed=() k
  # shellcheck disable=SC2016  # jq program, not shell expansion
  while IFS= read -r -d '' k; do
    repointed+=("$k")
  done < <(jq -j --slurpfile mv "$map" '$mv[0] as $m | .docs | to_entries[]
      | select($m[.key] == null and (.value | type) == "object")
      | select(((.value.replaces | type) == "string" and $m[.value.replaces] != null)
               or ((.value.superseded_by | type) == "string" and $m[.value.superseded_by] != null))
      | .key + "\u0000"' < "$snap")
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -j --slurpfile mv "$map" '$mv[0] as $m | .docs | to_entries[]
      | select((.value | type) == "object")
      | select(((.value.code_refs | type) == "array"
                and any(.value.code_refs[]; type == "string" and $m[.] != null))
               or ((.value.code_oids | type) == "object"
                   and any(.value.code_oids | keys[]; $m[.] != null)))
      | (if $m[.key] != null then $m[.key].new else .key end) + "\u0000"' \
    < "$snap" > "$_SCRATCH/move-refs-repointed" || _die "cannot read $INDEX_FILE"
  while IFS= read -r -d '' k; do
    refs_repointed+=("$k")
  done < "$_SCRATCH/move-refs-repointed"

  # Each entry object is carried over WHOLESALE (`.value + {content_hash: …}`)
  # rather than field-by-field, so a field this code has never heard of still
  # survives a move. Only content_hash is adjusted: code_commit, code_oids and
  # last_verified are deliberately PRESERVED, because a move is not a
  # baseline reset — re-deriving either would make the entry assert a freshness
  # nobody confirmed. Run update-index afterwards for a genuine re-baseline.
  #
  # to_entries|map|from_entries re-keys IN POSITION, so the commit-time diff is a
  # one-line key rename rather than the delete-plus-append that
  # `.docs[$new] = .docs[$old] | del(.docs[$old])` would produce. (The merge
  # driver keeps OURS' key order: a move on the checked-out side keeps its
  # position through a merge, but a move merged in from the other side arrives
  # as a new key and is appended at the end.) from_entries
  # cannot collide here — every target is unindexed or vacated (checked above).
  #
  # The second stage repoints other entries' path-valued fields, which
  # references/doc-spec.md holds to the same key contract as the keys themselves
  # — without it a rename leaves a dangling superseded_by/replaces, and every
  # doc citing the moved one in code_refs points at a path that is gone
  # (GH #22). A code_refs list is rewritten in place; a moved ref whose new
  # path the list already names (unmoved) or has just gained is dropped, so
  # [old, old] becomes [new], and a duplicate of a ref the move did not touch
  # stays. Its code_oids
  # key moves with it and keeps its recorded id: a rename keeps the blob, so the
  # citing doc's verdict is unchanged, and a rename-plus-edit reads stale, as it
  # should. When an entry also records the new path as a ref of its own, that
  # ref's id wins over the moved one's. The batch is one simultaneous rename, so
  # a chain a→b, b→c maps every old path through $m once, never twice.
  # shellcheck disable=SC2016  # jq program, not shell expansion
  _index_apply '$mv[0] as $m
    | .docs |= (to_entries
               | map(if $m[.key] != null
                     then {key: $m[.key].new, value: (.value + {content_hash: $m[.key].hash})}
                     else . end)
               | from_entries)
    | .docs |= map_values(if type != "object" then .
        else (if (.replaces | type) == "string" and $m[.replaces] != null
              then .replaces = $m[.replaces].new else . end)
          | (if (.superseded_by | type) == "string" and $m[.superseded_by] != null
             then .superseded_by = $m[.superseded_by].new else . end)
          | (if (.code_refs | type) == "array"
                and any(.code_refs[]; type == "string" and $m[.] != null)
             then .code_refs |= (. as $orig | reduce $orig[] as $r ([];
                    if ($r | type) == "string" and $m[$r] != null
                    then $m[$r].new as $n
                      # a moved ref collapses only into a copy of its new path
                      # the list already holds (unmoved) or just gained; a
                      # duplicate of a ref the move did not touch stays
                      | if any($orig[]; . == $n and ((type != "string") or $m[.] == null))
                           or any(.[]; . == $n)
                        then . else . + [$n] end
                    else . + [$r] end))
             else . end)
          | (if (.code_oids | type) == "object"
                and any(.code_oids | keys[]; $m[.] != null)
             then .code_oids |= ([to_entries[]
                    | {k: (if $m[.key] != null then $m[.key].new else .key end),
                       v: .value, moved: ($m[.key] != null)}] as $p
                  | reduce $p[] as $e ({};
                      if has($e.k) and $e.moved then . else .[$e.k] = $e.v end))
             else . end)
        end)' \
    --slurpfile mv "$map"

  echo "Moved ${#olds[@]} $([ ${#olds[@]} -eq 1 ] && echo entry || echo entries):" >&2
  i=0
  while [ "$i" -lt "${#olds[@]}" ]; do
    echo "  ${olds[$i]} -> ${news[$i]}" >&2
    i=$((i + 1))
  done
  if [ ${#repointed[@]} -gt 0 ]; then
    _report_keys "Repointed" "(replaces/superseded_by now name the new path)" "${repointed[@]}"
  fi
  if [ ${#refs_repointed[@]} -gt 0 ]; then
    _report_keys "Repointed" "(code_refs/code_oids now name the new path)" "${refs_repointed[@]}"
  fi
}

# set-code-refs (GH #18): the one supported way to change which code an
# indexed doc covers. remove-entry + add-entry dropped the entry's metadata
# and moved it to the end of .docs; update-index keeps code_refs as stored.
cmd_set_code_refs() {
  [ $# -gt 0 ] || _usage_error set-code-refs "requires a doc path argument"
  [ $# -eq 1 ] || _usage_error set-code-refs "takes exactly one doc path (got $#)"
  _opt_seen refs || _usage_error set-code-refs "requires --refs <ref>[,<ref>...] (--refs '' for none)"
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi
  local doc_path joined="" r
  doc_path=$(normalize_doc_path "$1") || exit 1
  case "$_OPT_refs" in
    *$'\n'*|*$'\x1f'*)
      echo "ERROR: --refs holds a newline or a 0x1f control character; a ref cannot." >&2
      exit 1
      ;;
  esac
  _refs_from_csv "$_OPT_refs" "--refs" || exit 1
  for r in ${_E_REFS[@]+"${_E_REFS[@]}"}; do
    joined="${joined:+$joined$'\x1f'}$r"
  done

  _scratch_init
  _index_now
  # The entry's current code_oids decide what is kept, so they are read under
  # the lock the write then takes (re-entrant): nothing can change in between.
  _index_lock
  local snap
  snap=$(_index_load) || exit 1
  if ! jq -e --arg k "$doc_path" '.docs | has($k)' < "$snap" >/dev/null; then
    echo "ERROR: '$doc_path' not found in index. Use add-entry to index it." >&2
    exit 1
  fi

  # What the entry has: its refs compared as paths ("src" is a stored
  # "src/"; a legacy "" is no ref), whether it records code_oids (else it is
  # a pre-v3 entry), and its code_commit — then one flag per new ref: 1 if
  # the entry already had it. The same list is a no-op: nothing is written.
  local plan="$_SCRATCH/set-code-refs.plan" verdict mode cc flag kept=() i=0
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -r --arg k "$doc_path" --arg refs "$joined" "$_JQ_CODE_OIDS"'
    def segs: split("/") | map(select(. != "" and . != "."));
    def normref: segs | if length == 0 then "." else join("/") end;
    .docs[$k] as $e
    | ($refs | fields_list) as $R
    | [($e.code_refs // []) | if type == "array" then .[] else empty end
       | select(type == "string" and . != "") | normref] as $S
    | (reduce $S[] as $s ({}; .[$s] = true)) as $has
    | (if ($R | map(normref)) == $S then "noop" else "write" end),
      (if ($e.code_oids | type) == "object" then "oids" else "legacy" end),
      ($e.code_commit // "" | tostring | split("\n") | join(" ")),
      ($R[] | if $has[normref] then "1" else "0" end)' < "$snap" > "$plan" \
    || _die "cannot read '$doc_path' from $INDEX_FILE"
  {
    IFS= read -r verdict
    IFS= read -r mode
    IFS= read -r cc
    while IFS= read -r flag; do
      [ "$flag" != 1 ] || kept+=("${_E_REFS[$i]}")
      i=$((i + 1))
    done
  } < "$plan"
  if [ "$verdict" = noop ]; then
    _report_keys "Unchanged" "(code_refs already as given; nothing written)" "$doc_path"
    return 0
  fi

  # A new ref is recorded as add-entry records one: as of the doc's own last
  # commit (the working tree for a doc git has never committed). The entry is
  # not re-baselined, so nothing else about it changes.
  _FACT_KEYS=("$doc_path")
  _FACT_REFSETS=("$joined")
  _entry_facts 1 doc

  # A ref the entry already had keeps its recorded content (it may have been
  # re-baselined): its code_oids id, or — for a pre-v3 entry, which records
  # content only as code_commit (the newest commit touching the refs when it
  # was re-baselined) — its object id in that commit's tree, looked up the way
  # every ref is (_oid_lookup). Without a usable code_commit (absent, not an
  # object id, not in this repository) it is recorded like a new ref.
  local lrefs="" loids="" lfile="$_SCRATCH/set-code-refs.kept" lout="$_SCRATCH/set-code-refs.kept.oids" x
  if [ "$mode" = legacy ] && [ ${#kept[@]} -gt 0 ] && _is_oid "$cc" \
      && git cat-file -e "$cc^{commit}" 2>/dev/null; then
    printf '%s\n' "${kept[@]}" > "$lfile"
    _oid_lookup "$cc" "$lfile" "$lout" 1
    for x in "${kept[@]}"; do
      lrefs="${lrefs:+$lrefs$'\x1f'}$x"
    done
    while IFS= read -r x; do
      loids="${loids:+$loids$'\x1f'}$x"
    done < "$lout"
  fi

  # code_refs replaced in place (a `+=` merge keeps every field's position);
  # code_oids re-derived: a kept ref keeps its recorded content, and a new
  # one takes the object id just derived from the doc's last commit. The jq
  # pass prints where the refs' contents now come from — keep (all recorded:
  # refs only removed, re-spelled or reordered), fresh (all from the doc's
  # last commit) or mixed — then the patch row.
  local plan2="$_SCRATCH/set-code-refs.rows" patch="$_SCRATCH/set-code-refs.jsonl" ccmode row newcc=""
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -r -n --arg k "$doc_path" --arg refs "$joined" --arg oids "${_FACT_OIDS[0]}" \
    --arg lrefs "$lrefs" --arg loids "$loids" --slurpfile idx "$snap" \
    "$_JQ_CODE_OIDS"'
    def segs: split("/") | map(select(. != "" and . != "."));
    def normref: segs | if length == 0 then "." else join("/") end;
    ($refs | fields_list) as $R
    | ($oids | fields_list) as $O
    | ($lrefs | fields_list) as $LR
    | ($loids | fields_list) as $LO
    | ($idx[0].docs[$k]) as $e
    | (if ($e.code_oids | type) == "object"
       then reduce ($e.code_oids | to_entries[] | select((.value | type) == "string")) as $x
              ({}; if has($x.key | normref) then . else .[$x.key | normref] = $x.value end)
       else reduce range(0; $LR | length) as $j ({}; .[$LR[$j] | normref] = $LO[$j]) end) as $kept
    | [range(0; $R | length) as $j
       | {key: $R[$j], kept: ($kept[$R[$j] | normref] // null), fresh: $O[$j]}] as $rows
    | (if all($rows[]; .kept != null) then "keep"
       elif all($rows[]; .kept == null) then "fresh" else "mixed" end),
      ({key: $k, merge: {code_refs: $R,
          code_oids: ([$rows[] | {key: .key, value: (.kept // .fresh)}] | from_entries)}} | tojson)' \
    > "$plan2" || _die "cannot assemble the update; $INDEX_FILE is unchanged."
  { IFS= read -r ccmode; IFS= read -r row; } < "$plan2"

  # code_commit is the commits_behind baseline, so it must be no newer than
  # the content of ANY ref, or a change in between goes uncounted: a masked
  # 0. With refs on two baselines — kept ones recorded as of the stored
  # code_commit, new ones as of the doc's last commit (whose code_commit
  # _entry_facts derived, _FACT_COMMIT) — the OLDER baseline is recorded:
  #   keep   every ref kept: the stored code_commit stands
  #   fresh  every ref's content from the doc's last commit: the derived
  #          one, as add-entry records it
  #   mixed  git merge-base <stored> <derived> (the newest commit no newer
  #          than either; it may over-count, never under-count), or null —
  #          so that commits_behind reads null, never a guess — when the
  #          stored one is not usable, there is no derived one, or they
  #          share no ancestor. Usable: an object id naming a commit of
  #          this repository that is an ancestor of HEAD. One off HEAD's
  #          line (only the re-baseline commit was cherry-picked) already reads
  #          null; its merge-base with the derived one would count from a
  #          commit before changes it never saw — a masked 0.
  _head_init
  case "$ccmode" in
    keep) printf '%s\n' "$row" > "$patch" ;;
    fresh|mixed)
      if [ "$ccmode" = fresh ]; then
        newcc="${_FACT_COMMIT[0]}"
      elif [ -n "${_FACT_COMMIT[0]}" ] && [ -n "$_HEAD" ] && _is_oid "$cc" \
          && git cat-file -e "$cc^{commit}" 2>/dev/null \
          && git merge-base --is-ancestor "$cc" "$_HEAD" 2>/dev/null; then
        newcc=$(git merge-base "$cc" "${_FACT_COMMIT[0]}" 2>/dev/null) || newcc=""
        _is_oid "$newcc" || newcc=""
      fi
      # shellcheck disable=SC2016  # jq program, not shell expansion
      jq -c --arg cc "$newcc" '.merge += {code_commit: (if $cc == "" then null else $cc end)}' \
        <<<"$row" > "$patch" || _die "cannot assemble the update; $INDEX_FILE is unchanged."
      ;;
    *) _die "cannot assemble the update; $INDEX_FILE is unchanged." ;;
  esac
  _index_apply --report "$_INDEX_PATCH" --slurpfile patch "$patch"
  case "${_INDEX_CLASSES:0:1}" in
    c) _report_keys "Set code_refs of" "" "$doc_path" ;;
    *) _report_keys "Unchanged" "(code_refs already as given)" "$doc_path" ;;
  esac
}

# The documented doc_type vocabulary: one living type per doc-spec.md
# template, and the record types (never reported stale — the same four
# _JQ_FRESH_EXTRACT tests). set-doc-type also accepts a type the index
# already uses: a project may keep its own vocabulary.
_DOC_TYPES_LIVING="architecture api-contracts data-layer infra ci-cd workflows agentic guide codebase-guide conventions spec adr"
_DOC_TYPES_RECORD="plan issue audit design-spec"

# set-doc-type <doc> <type>: one "merge" patch row, {doc_type: <type>}, so the
# entry keeps its key position and every other field. doc_type decides
# whether a doc is a record (see _JQ_FRESH_EXTRACT): the only other way to
# change it was remove-entry + add-entry, which drops the entry's
# baseline, deprecation and links.
cmd_set_doc_type() {
  [ $# -eq 2 ] || _usage_error set-doc-type "takes exactly <doc_path> <doc_type> (got $# arguments)"
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi
  local doc_path type="$2"
  doc_path=$(normalize_doc_path "$1") || exit 1

  _scratch_init
  _index_now
  # What the entry holds and which types this index uses are read under the
  # lock the write then takes (re-entrant): nothing changes in between.
  _index_lock
  local snap facts="$_SCRATCH/set-doc-type" has old known
  snap=$(_index_load) || exit 1
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -j --arg k "$doc_path" --arg t "$type" --arg vocab "$_DOC_TYPES_LIVING $_DOC_TYPES_RECORD" '
    .docs as $d
    | (if ($d | has($k)) then "1" else "0" end) + "\u0000"
      + (if ($d | has($k)) and ($d[$k] | type) == "object" then ($d[$k].doc_type // "" | tostring) else "" end) + "\u0000"
      + (if $t != "" and (($vocab | split(" ") | any(.[]; . == $t))
                          or any($d[]; type == "object" and .doc_type == $t))
         then "1" else "0" end) + "\u0000"' < "$snap" > "$facts" || _die "cannot read $INDEX_FILE"
  { IFS= read -r -d '' has; IFS= read -r -d '' old; IFS= read -r -d '' known; } < "$facts"
  if [ "$has" != 1 ]; then
    echo "ERROR: '$doc_path' not found in index. Use add-entry to index it." >&2
    exit 1
  fi
  if [ "$known" != 1 ]; then
    echo "ERROR: unknown doc_type '$type' for '$doc_path'. Known: $_DOC_TYPES_LIVING (living docs), $_DOC_TYPES_RECORD (record docs, never reported stale) — or a type this index already uses. Nothing was written." >&2
    exit 1
  fi
  if [ "$old" = "$type" ]; then
    _report_keys "Unchanged" "(doc_type already '$type'; nothing written)" "$doc_path"
    return 0
  fi

  local patch="$_SCRATCH/set-doc-type.jsonl"
  jq -nc --arg k "$doc_path" --arg t "$type" '{key: $k, merge: {doc_type: $t}}' > "$patch" \
    || _die "cannot assemble the update; $INDEX_FILE is unchanged."
  _index_apply --report "$_INDEX_PATCH" --slurpfile patch "$patch"
  case "${_INDEX_CLASSES:0:1}" in
    c) _report_keys "Set doc_type of" "(${old:-none} → $type)" "$doc_path" ;;
    *) _report_keys "Unchanged" "(doc_type already '$type'; nothing written)" "$doc_path"; return 0 ;;
  esac
  # Whether it is a record changes what check-freshness says about it.
  case "$doc_path" in
    docs/archive/*) return 0 ;;
  esac
  local was=0 now=0
  case " $_DOC_TYPES_RECORD " in *" $old "*) was=1 ;; esac
  case " $_DOC_TYPES_RECORD " in *" $type "*) now=1 ;; esac
  if [ "$was" = 0 ] && [ "$now" = 1 ]; then
    echo "NOTE: '$doc_path' is now a record doc: check-freshness reports it current and never compares it with its code." >&2
  elif [ "$was" = 1 ] && [ "$now" = 0 ]; then
    echo "NOTE: '$doc_path' is now a living doc: check-freshness compares it with its code again (update-index it once you have read it against that code)." >&2
  fi
}

cmd_deprecate_entry() {
  if [ ! -f "$INDEX_FILE" ]; then
    echo "ERROR: doc-index.json not found at $INDEX_FILE. Run build-index first." >&2
    exit 1
  fi

  [ $# -gt 0 ] || _usage_error deprecate-entry "requires at least one doc path argument"

  # --superseded-by may come anywhere on the line (_parse_args): given after
  # the path it used to be taken for a second target, deprecating the
  # successor. The value is stored as a doc reference, so it is held to the
  # same key contract as the entries themselves. Without it, an entry's
  # superseded_by is left as it is: the archive recipe (move-entry, then
  # deprecate-entry <new>) used to reset a superseded doc's link to null,
  # while its successor's replaces still named it.
  local superseded_by="null" succ=""
  if _opt_seen superseded-by; then
    _norm_path "$_OPT_superseded_by" "--superseded-by path" || exit 1
    succ="$_NORM"
    superseded_by=$(printf '%s' "$_NORM" | jq -R .)
  fi

  # Normalize up front — same rationale as remove-entry: an absolute path used to
  # report "not found" and exit 0, silently failing to deprecate a real entry.
  local targets=() doc_path
  _targets_from_args "$@"
  targets=("${_TARGETS[@]}")
  set --   # see _targets_from_args: keep function calls O(1) under bash 3.2

  if [ -n "$succ" ]; then
    for doc_path in "${targets[@]}"; do
      if [ "$doc_path" = "$succ" ]; then
        echo "ERROR: '$succ' cannot supersede itself; nothing deprecated." >&2
        exit 1
      fi
    done
  fi

  # Deprecating is not a baseline reset: last_verified is left as it is.
  _scratch_init
  local patch="$_SCRATCH/deprecate-patch.jsonl"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -nc --argjson superseded_by "$superseded_by" --arg given "$succ" \
    '$ARGS.positional[] | {key: ., merge: ({status: "deprecated"}
       + (if $given != "" then {superseded_by: $superseded_by} else {} end))}' \
    --args "${targets[@]}" > "$patch"

  # The successor's replaces names the doc it supersedes: the first target
  # that is indexed. It holds one path, so it is set only when empty — a
  # successor that already replaces another doc keeps it, and that is said.
  # What the successor holds is read under the lock the write then takes
  # (re-entrant), so the report describes the write.
  local pred="" succ_has=0 succ_replaces=""
  if [ -n "$succ" ]; then
    _index_lock
    local snap facts="$_SCRATCH/deprecate-successor"
    snap=$(_index_load) || exit 1
    # shellcheck disable=SC2016  # jq program, not shell expansion
    jq -j --arg s "$succ" '.docs as $d
      | (($d[$s] // null) | type) as $t
      | (if $t == "object" then "1" else "0" end) + "\u0000"
        + (if $t == "object" then ($d[$s].replaces // "" | tostring) else "" end) + "\u0000"
        + ([$ARGS.positional[] | . as $p | select($d | has($p))] | first // "") + "\u0000"' \
      --args "${targets[@]}" < "$snap" > "$facts" || _die "cannot read $INDEX_FILE"
    { IFS= read -r -d '' succ_has; IFS= read -r -d '' succ_replaces; IFS= read -r -d '' pred; } < "$facts"
  fi
  # shellcheck disable=SC2016  # jq program, not shell expansion
  _index_apply --report "$_INDEX_PATCH"' | if $pred != "" and (.docs[$succ] | type) == "object"
        and ((.docs[$succ].replaces // null) == null)
      then .docs[$succ].replaces = $pred else . end' \
    --slurpfile patch "$patch" --arg succ "$succ" --arg pred "$pred"

  # The classes come from the same locked pass as the write, so "not found"
  # and "already deprecated" (a no-op) are told apart against the index that
  # was actually updated. An unknown key is reported and the rest applied;
  # the run exits 1 at the end (like update-index): an archive step that
  # named the old path after move-entry used to deprecate nothing, exit 0.
  local deprecated=() unchanged=() i=0 unknown=0
  while [ "$i" -lt "${#targets[@]}" ]; do
    case "${_INDEX_CLASSES:$i:1}" in
      c) deprecated+=("${targets[$i]}") ;;
      u) unchanged+=("${targets[$i]}") ;;
      *)
        echo "ERROR: '${targets[$i]}' not found in index; skipped (after a move-entry, name the new path)." >&2
        unknown=$((unknown + 1))
        ;;
    esac
    i=$((i + 1))
  done
  _report_keys "Deprecated" "" "${deprecated[@]+"${deprecated[@]}"}"
  if [ ${#unchanged[@]} -gt 0 ]; then
    _report_keys "Unchanged" "(already deprecated)" "${unchanged[@]}"
  fi
  if [ -n "$succ" ]; then
    if [ "$succ_has" != 1 ]; then
      echo "WARNING: successor '$succ' is not in the index, so its replaces is not set (index it with add-entry, then re-run deprecate-entry)." >&2
    elif [ -n "$pred" ] && [ -z "$succ_replaces" ]; then
      echo "Linked: '$succ' now replaces '$pred'." >&2
    elif [ -n "$pred" ] && [ "$succ_replaces" != "$pred" ]; then
      echo "WARNING: '$succ' already replaces '$succ_replaces'; replaces holds one path, so it is left as it is." >&2
    fi
  fi
  if [ "$unknown" -gt 0 ]; then
    echo "$unknown $([ "$unknown" -eq 1 ] && echo path was || echo paths were) not in the index (see above)." >&2
    exit 1
  fi
}

cmd_status() {
  [ $# -gt 0 ] || _usage_error status "requires a doc path argument"
  [ $# -eq 1 ] || _usage_error status "takes exactly one doc path (got $#); check-freshness reports every doc"
  _check_tree_opt status

  local doc_path
  doc_path=$(normalize_doc_path "$1") || exit 1

  _scratch_init
  local snap results="$_SCRATCH/status.rec" out
  _reader_snapshot
  snap="$_SNAP"

  # The same walk check-freshness runs, restricted to this one key, so the
  # two can never disagree about a doc (the old inline copy did).
  _freshness_scan "$snap" "$doc_path" "" "$results"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  out=$(jq -n -R --arg p "$doc_path" "$_JQ_REC_FIELDS$_JQ_FRESH_RESULTS"'
    results | if has($p) then {path: $p} + .[$p] else empty end' < "$results") \
    || _die "cannot render the status of '$doc_path'"
  if [ -z "$out" ]; then
    echo "ERROR: '$doc_path' not found in index." >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

# audit-merges: replay index merges through the driver as an oracle. Read-only:
# every file it writes, the driver's own temporaries included, is under $_SCRATCH.
_am_index_at() { git show "$1:$INDEX_FILE" > "$2" 2>/dev/null || : > "$2"; }
# The index's blob id at <commit>, or "" when that commit has none. Blob ids,
# not `git diff`: a textconv on the index path can make two blobs compare equal.
_am_blob() { git rev-parse -q --verify "$1:$INDEX_FILE" 2>/dev/null || true; }
# Whether <file> holds exactly one index object (an empty file does not).
_am_ok() { jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].docs | type) == "object"' "$1" >/dev/null 2>&1; }

cmd_audit_merges() {
  [ $# -ge 1 ] && [ $# -le 2 ] || _usage_error audit-merges "requires <since> [<until>] (got $# arguments)"
  local since="$1" until="${2:-HEAD}" r
  for r in "$since" "$until"; do
    git rev-parse --verify --quiet "$r^{commit}" >/dev/null \
      || { echo "ERROR: '$r' is not a commit." >&2; exit 1; }
  done
  local driver="$SCRIPT_DIR/merge-doc-index.sh"
  [ -f "$driver" ] || _die "audit-merges needs the merge driver beside doc-tools.sh ($driver): run the plugin's copy, not a vendored one"

  _scratch_init
  local dir="$_SCRATCH/audit-merges" found="$_SCRATCH/audit-merges.jsonl"
  local skipped="$_SCRATCH/audit-merges-skipped.jsonl" list="$_SCRATCH/audit-merges.list"
  mkdir -p "$dir" || _die "cannot create a scratch directory"
  : > "$found"; : > "$skipped"
  # Pinned: a user's log.showSignature=true would print gpg lines among the ids.
  git -c log.showSignature=false log --merges --format='%H %P' "$since..$until" > "$list" \
    || _die "cannot list the merges in $since..$until"
  local total m p1 p2 extra base b1 b2 bb side checked=0 replayed=0 seen=0
  total=$(grep -c . "$list" || true)
  while read -r m p1 p2 extra; do
    [ -n "$m" ] || continue
    seen=$((seen + 1))
    [ $((seen % 25)) -eq 0 ] && echo "audit-merges: $seen/$total merges read, $checked checked" >&2
    if [ -n "${extra:-}" ]; then
      jq -cn --arg m "$m" '{merge: $m, octopus: true}' >> "$skipped"
      continue
    fi
    b1=$(_am_blob "$p1"); b2=$(_am_blob "$p2")
    [ "$b1" = "$b2" ] && continue           # the parents agree: nothing to merge
    checked=$((checked + 1))
    base=$(git merge-base "$p1" "$p2" 2>/dev/null) || base=""
    bb=""; [ -n "$base" ] && bb=$(_am_blob "$base")
    _am_index_at "$m" "$dir/rec"
    # What the merge should have recorded. git's file-level rule first: when
    # only one side changed the index, that side's version is the result and
    # no driver runs (a branch cut before the index existed, a one-sided
    # deletion). Otherwise the driver decides.
    side=""
    if [ "$b1" = "$bb" ]; then
      side="parent 2"; _am_index_at "$p2" "$dir/out"
    elif [ "$b2" = "$bb" ]; then
      side="parent 1"; _am_index_at "$p1" "$dir/out"
    else
      replayed=$((replayed + 1))
      if [ -n "$base" ]; then _am_index_at "$base" "$dir/base"; else : > "$dir/base"; fi
      _am_index_at "$p1" "$dir/out"
      _am_index_at "$p2" "$dir/p2"
      if ! TMPDIR="$dir" "$BASH" "$driver" "$dir/base" "$dir/out" "$dir/p2" >/dev/null 2>&1; then
        jq -cn --arg m "$m" '{merge: $m, refused: true}' >> "$found"
        continue
      fi
    fi
    # An absent index where one is expected, or two documents, is unreadable;
    # absent where absent is expected agrees. So is a changed side's index the
    # merge was to take: nothing can be compared with it.
    if [ ! -s "$dir/rec" ] && [ ! -s "$dir/out" ]; then continue; fi
    if ! _am_ok "$dir/rec"; then
      jq -cn --arg m "$m" '{merge: $m, unreadable: "recorded"}' >> "$found"
      continue
    fi
    if [ -n "$side" ] && [ -s "$dir/out" ] && ! _am_ok "$dir/out"; then
      jq -cn --arg m "$m" --arg s "$side" '{merge: $m, unreadable: $s}' >> "$found"
      continue
    fi
    # The parents only name which one a recorded entry matches; an unreadable
    # one (conflict markers the other side repaired) names none — not even
    # for an entry the merge dropped, which an empty index would match.
    local ux=false uy=false
    _am_index_at "$p1" "$dir/p1"; _am_ok "$dir/p1" || { : > "$dir/p1"; ux=true; }
    _am_index_at "$p2" "$dir/p2"; _am_ok "$dir/p2" || { : > "$dir/p2"; uy=true; }
    # shellcheck disable=SC2016  # jq program, not shell expansion
    jq -cn --arg m "$m" --slurpfile a "$dir/out" --slurpfile b "$dir/rec" \
        --slurpfile x "$dir/p1" --slurpfile y "$dir/p2" --argjson ux "$ux" --argjson uy "$uy" '
      def norm: if type == "object" and (.status == "current" or .status == "stale")
                 then del(.status) else . end;
      def docs($f): if ($f | length) > 0 and ($f[0] | type) == "object" then ($f[0].docs // {}) else {} end;
      docs($a) as $A | docs($b) as $B | docs($x) as $X | docs($y) as $Y
      | ([$A, $B] | map(keys) | add | unique)[] as $k
      | ($A[$k] | norm) as $va | ($B[$k] | norm) as $vb
      | select($va != $vb)
      | {merge: $m, key: $k,
         kept: (if ($ux | not) and $vb == ($X[$k] | norm) then "parent 1"
                elif ($uy | not) and $vb == ($Y[$k] | norm) then "parent 2" else "neither" end)}' \
      >> "$found" || _die "cannot compare merge $m with its expected index"
  done < "$list"

  local count
  count=$(grep -c . "$found" || true)
  jq -n --arg r "$since..$until" --argjson n "$checked" --argjson d "$replayed" \
      --slurpfile f "$found" --slurpfile s "$skipped" \
    '{range: $r, merges_checked: $n, merges_replayed: $d, findings: $f, skipped: $s}' || _die "cannot render the findings"
  echo "audit-merges: $checked merge(s) checked ($replayed through the driver), $count finding(s)$([ -s "$skipped" ] && echo ", $(grep -c . "$skipped") skipped (octopus)")" >&2
  [ "$count" -eq 0 ] || exit 1
}

# --- Version management ---

# The version of a RELEASE-NOTES.md: its first release heading — the first
# line, outside code fences, that starts "## v" and a digit. That heading must
# be exactly "## vMAJOR.MINOR.PATCH", then the end of the line or a space
# ("## v2.15.0 (2026-09-01)"): a pre-release ("## v3.0.0-rc.1") or any other
# suffix is refused, never skipped — skipping would silently compare against
# an older release. (It used to be the first "## vX.Y.Z" SUBSTRING anywhere,
# prose and code blocks included, with its suffix cut off.) The one parser for
# check-version, tools version / tools status, and the installer (through
# tools version). Prints the version without the "v"; on failure prints the
# reason on stderr and returns 1.
_release_notes_version() {
  local file="$1" heading ver
  if [ ! -f "$file" ]; then
    echo "ERROR: $file not found: it holds the canonical version." >&2
    return 1
  fi
  # shellcheck disable=SC2016  # awk program, not shell expansion
  heading=$(awk "$_AWK_FENCE"'
    blk_fence($0) || fence_c != "" { next }
    /^## v[0-9]/ { print; exit }' < "$file") || {
    echo "ERROR: cannot read $file" >&2
    return 1
  }
  if [ -z "$heading" ]; then
    echo "ERROR: $file has no release heading (a line \"## vMAJOR.MINOR.PATCH …\" outside code fences)." >&2
    return 1
  fi
  ver="${heading#'## v'}"
  ver="${ver%%[[:space:]]*}"
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: $file: the first release heading is not a MAJOR.MINOR.PATCH release: '$heading'" >&2
    echo "       (a pre-release or suffixed version is not a release; the manifests carry MAJOR.MINOR.PATCH)" >&2
    return 1
  fi
  printf '%s\n' "$ver"
}

# All files that carry a version string, with their jq path
VERSION_FILES=(
  "package.json:.version"
  ".claude-plugin/plugin.json:.version"
  ".claude-plugin/marketplace.json:.metadata.version"
  ".cursor-plugin/plugin.json:.version"
  "gemini-extension.json:.version"
)

_no_manifest_error() {
  echo "ERROR: no manifest found (none of: ${VERSION_FILES[*]%%:*}) — run $1 from the repository root." >&2
  exit 1
}

cmd_bump_version() {
  if [ $# -gt 1 ]; then
    _usage_error bump-version "takes one version (got $#: $*)"
  fi
  local new_version="${1:-}"
  # A malformed version (below) is a bad value, exit 1; a missing one is a
  # usage error.
  [ -n "$new_version" ] || _usage_error bump-version "requires a version argument (e.g., 2.5.0)"

  # Validate semver format
  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: invalid version format '$new_version' — expected MAJOR.MINOR.PATCH" >&2
    exit 1
  fi

  # All or nothing: every manifest is read and its new content rendered into a
  # tmp beside it BEFORE any is replaced, so a malformed one (it used to abort
  # the run midway, rc 5, half the files bumped) writes nothing at all. The
  # replacements keep each file's mode (a bare mktemp + mv made them 0600).
  local entry file jq_path current found=0 bad="" i=0
  local what=() tmps=() currents=()
  for entry in "${VERSION_FILES[@]}"; do
    file="${entry%%:*}"
    jq_path="${entry#*:}"
    what[$i]=skip tmps[$i]="" currents[$i]=""
    if [ -f "$file" ]; then
      found=$((found + 1))
      if ! current=$(jq -r "$jq_path // empty" "$file" 2>/dev/null); then
        what[$i]=bad
        bad="$bad $file"
      elif [ "$current" = "$new_version" ]; then
        what[$i]=ok
      else
        _tmp_beside "$file"
        if jq --arg v "$new_version" "$jq_path = \$v" "$file" > "$_TMP" 2>/dev/null; then
          what[$i]=bump tmps[$i]="$_TMP" currents[$i]="$current"
        else
          what[$i]=bad
          bad="$bad $file"
        fi
      fi
    fi
    i=$((i + 1))
  done
  [ "$found" -gt 0 ] || _no_manifest_error bump-version
  if [ -n "$bad" ]; then
    echo "ERROR: cannot read the version of:$bad (not valid JSON); nothing was written." >&2
    exit 1
  fi

  local updated=0
  i=0
  for entry in "${VERSION_FILES[@]}"; do
    file="${entry%%:*}"
    case "${what[$i]}" in
      skip) echo "  skip: $file (not found)" ;;
      ok) echo "  ok:   $file (already $new_version)" ;;
      bump)
        _replace_file "${tmps[$i]}" "$file"
        echo "  bump: $file (${currents[$i]} → $new_version)"
        updated=$((updated + 1))
        ;;
    esac
    i=$((i + 1))
  done

  echo "Updated $updated file(s) to v$new_version"
}

cmd_check_version() {
  if [ $# -gt 0 ]; then
    _usage_error check-version "takes no arguments (got '$1')"
  fi
  local canonical
  canonical=$(_release_notes_version RELEASE-NOTES.md) || exit 1

  local entry file jq_path actual mismatched=0 checked=0

  echo "Canonical version (RELEASE-NOTES.md): v$canonical"

  for entry in "${VERSION_FILES[@]}"; do
    file="${entry%%:*}"
    jq_path="${entry#*:}"

    if [[ ! -f "$file" ]]; then
      continue
    fi
    checked=$((checked + 1))

    if ! actual=$(jq -r "$jq_path // empty" "$file" 2>/dev/null); then
      echo "  INVALID:  $file is not valid JSON"
      mismatched=$((mismatched + 1))
    elif [[ "$actual" != "$canonical" ]]; then
      echo "  MISMATCH: $file has ${actual:-no version} (expected $canonical)"
      mismatched=$((mismatched + 1))
    else
      echo "  ok:       $file"
    fi
  done

  [ "$checked" -gt 0 ] || _no_manifest_error check-version

  if [[ "$mismatched" -gt 0 ]]; then
    echo "FAIL: $mismatched/$checked file(s) have mismatched versions"
    echo "  Run: doc-tools.sh bump-version $canonical"
    exit 1
  fi

  echo "PASS: all $checked file(s) match v$canonical"
}

# --- Fragments: RELEASE-NOTES.next/PR-<N>.md ----------------------------------
#
# ONE grammar for the per-PR release-notes fragments, shared by `fragments
# list` and `fragments merge` (_FRAG_AWK). The format and its rules are the
# spec the installer ships as RELEASE-NOTES.next/README.md
# (scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md):
#
#   line 1  <!-- doc-superpowers:fragment PR-<N> -->   N = the file's number
#   line 2  <!-- doc-superpowers:hash <sha256> -->      of the bytes from line 3
#   line 3+ ### <Section> headings, each holding its notes
#
# A fragment is merged losslessly or not at all: one the consumer cannot
# place (a wrong line 1, text before the first ### heading, a # / ##
# heading, an unclosed code fence, no notes) is skipped with a warning and
# left for the next release — never consumed. A missing or drifted hash is
# a hand edit: merged as written, with a warning. Trailing CR and blanks are
# dropped. Notes are units: a unit starts at a list item (-, *, + or 1. at
# column 0) or at a column-0 line after a blank line (a paragraph), and takes
# every following line up to the next such start — indented lines, lazy
# continuation lines, blank lines followed by indented text, whole code
# fences. So a sub-bullet or a sentence two notes share is never cut from
# the second, identical units in one section are merged once, and a
# paragraph unit is printed with a blank line on each side (list items stay
# a tight list). Sections fold onto one vocabulary
# (case-insensitive; Features → Added, Changes → Changed, Fixes / Bug Fixes
# → Fixed) and print in its order; other headings follow as written, in
# first-seen order. A body that is only <!-- doc-superpowers:no-notes -->
# is the explicit "no release notes" state: consumed, nothing printed.
#
# Operands: n=<N> p=<path> <file>, per fragment, in PR order.
# -v mode=merge: the merged sections on stdout; per fragment one status line
#   ok|nonotes|skip \037 <path> [\037 <reason>]
# -v mode=list: per fragment one line
#   F \037 <path> \037 <problem or ""> \037 <1 if no-notes> \037 <sections \036-joined>
# shellcheck disable=SC2016  # awk program, not shell expansion
_FRAG_AWK='
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function fail(r) { if (bad == "") bad = r }
function fold(s,   l) {
  l = tolower(s)
  if (l == "added" || l == "features") return "Added"
  if (l == "changed" || l == "changes") return "Changed"
  if (l == "deprecated") return "Deprecated"
  if (l == "removed") return "Removed"
  if (l == "fixed" || l == "fixes" || l == "bug fixes") return "Fixed"
  if (l == "security") return "Security"
  if (l == "dependencies") return "Dependencies"
  return s
}
# --- fence parser (the same text in scripts/doc-tools.sh _FRAG_AWK and
# --- scripts/hooks/ci/doc-pr-release/update-pr-body.sh FENCED_AWK; keep them
# --- identical: scripts/test-doc-pr-release.sh diffs them and feeds both the
# --- same fence fixtures)
# A code fence opens with 3+ backticks or tildes (any indent) and closes with
# at least as many of the same character and nothing else.
function fence_open(l,   t, c, k) {
  t = l; sub(/^[ \t]+/, "", t)
  c = substr(t, 1, 1)
  if (c != "`" && c != "~") return 0
  k = 0; while (substr(t, k + 1, 1) == c) k++
  if (k < 3) return 0
  if (c == "`" && index(substr(t, k + 1), "`") > 0) return 0
  fc = c; fl = k
  return 1
}
function fence_close(l,   t, k) {
  t = l; sub(/^[ \t]+/, "", t)
  k = 0; while (substr(t, k + 1, 1) == fc) k++
  if (k < fl) return 0
  return (substr(t, k + 1) ~ /^[ \t]*$/)
}
# --- end fence parser
# A list item at column 0: -, * or +, or 1. / 1), then a blank or the end.
function is_item(l) {
  return (l ~ /^[-*+][ \t]/ || l ~ /^[-*+]$/ || l ~ /^[0-9]+[.)][ \t]/ || l ~ /^[0-9]+[.)]$/)
}
# The p= / n= operands of the NEXT file are already applied when end_file()
# runs for this one, so the path is kept here.
function begin_file() {
  fp = p; bad = ""; nonotes = 0; section = ""; nu = 0; cur = 0; pb = 0; infence = 0
  nsf = 0; split("", fseen)
}
function unit_new(l) { nu++; usec[nu] = section; utext[nu] = l; ulist[nu] = is_item(l); cur = nu; pb = 0 }
function unit_add(l,   k) {
  for (k = 0; k < pb; k++) utext[cur] = utext[cur] "\n"
  utext[cur] = utext[cur] "\n" l; pb = 0
}
function end_file(   i, s, key, secs) {
  if (infence) fail("an unclosed code fence")
  if (nonotes && nu > 0) fail("the no-notes marker together with notes")
  if (!nonotes && nu == 0) fail("no notes (write them, or the no-notes marker)")
  if (mode == "list") {
    secs = ""
    for (i = 1; i <= nsf; i++) secs = secs (i > 1 ? "\036" : "") fsec[i]
    printf "F\037%s\037%s\037%d\037%s\n", fp, bad, (nonotes && nu == 0), secs > status
    return
  }
  if (bad != "") { printf "skip\037%s\037%s\n", fp, bad > status; return }
  if (nonotes) { printf "nonotes\037%s\n", fp > status; return }
  printf "ok\037%s\n", fp > status
  for (i = 1; i <= nu; i++) {
    s = usec[i]
    if (!(s in secn)) { nsec++; secname[nsec] = s; secn[s] = 0 }
    key = s SUBSEP utext[i]
    if (key in seen) continue
    seen[key] = 1
    secn[s]++
    sect[s, secn[s]] = utext[i]
    sectl[s, secn[s]] = ulist[i]
  }
}
function emit(s,   j) {
  if (!(s in secn) || secn[s] == 0) return
  if (!first) printf "\n"
  first = 0
  printf "### %s\n", s
  for (j = 1; j <= secn[s]; j++) {
    # A paragraph needs a blank line on each side (else it runs into its
    # neighbour, or into the list item above as a lazy continuation).
    if (j > 1 && !(sectl[s, j] && sectl[s, j - 1])) printf "\n"
    printf "%s\n", sect[s, j]
  }
}
FNR == 1 {
  if (NR > 1) end_file()
  begin_file()
  l = $0; sub(/\r$/, "", l)
  if (rtrim(l) != "<!-- doc-superpowers:fragment PR-" n " -->")
    fail("line 1 is not <!-- doc-superpowers:fragment PR-" n " -->")
  next
}
{
  l = $0; sub(/\r$/, "", l)
  if (FNR == 2 && rtrim(l) ~ hashline) next
  if (infence) {
    if (cur) unit_add(l)
    if (fence_close(l)) infence = 0
    next
  }
  if (l ~ /^[ \t]*$/) { if (cur) pb++; next }
  if (rtrim(l) == "<!-- doc-superpowers:no-notes -->") { nonotes = 1; next }
  if (l ~ /^###[ \t]*$/) { fail("an empty ### heading"); next }
  if (l ~ /^###[ \t]/) {
    name = l; sub(/^###[ \t]+/, "", name)
    section = fold(rtrim(name)); cur = 0; pb = 0
    if (!(section in fseen)) { fseen[section] = 1; nsf++; fsec[nsf] = section }
    next
  }
  if (l ~ /^##?[ \t]/ || l ~ /^##?$/) { fail("a # or ## heading (the release adds the version heading)"); next }
  if (section == "") { fail("text before the first ### heading"); next }
  # A new unit only at a list item or after a blank line; anything else
  # (indented, or a lazy continuation line) belongs to the current one.
  if (cur && (l ~ /^[ \t]/ || (pb == 0 && !is_item(l)))) unit_add(l)
  else unit_new(l)
  if (fence_open(l)) infence = 1
}
END {
  if (NR > 0) end_file()
  if (mode != "merge") exit
  ncan = split("Added Changed Deprecated Removed Fixed Security Dependencies", canon, " ")
  for (i = 1; i <= ncan; i++) iscanon[canon[i]] = 1
  first = 1
  for (i = 1; i <= ncan; i++) emit(canon[i])
  for (i = 1; i <= nsec; i++) if (!(secname[i] in iscanon)) emit(secname[i])
}'

_FRAG_DIR="RELEASE-NOTES.next"

# Line 2 of a fragment: a hash line (the notes start on line 3; else on line
# 2), and a sealed one's captured hash. Byte-identical to FRAG_HASH_LINE_RE /
# FRAG_HASH_RE in scripts/hooks/ci/doc-pr-release/fragment-lib.sh, the
# producer helpers' copy (scripts/test-doc-pr-release.sh pins the two).
_FRAG_HASH_LINE_RE='^<!-- doc-superpowers:hash( [^ ]*)? -->$'
_FRAG_HASH_RE='^<!-- doc-superpowers:hash ([0-9a-f]+) -->$'

# _frag_n <path>: set _FRAG_N to the <N> of ".../PR-<N>.md"; return 1 when the
# name is not PR-<digits>.md.
_frag_n() {
  local base="${1##*/}"
  _FRAG_N=""
  case "$base" in
    PR-*.md) base="${base#PR-}"; base="${base%.md}" ;;
    *) return 1 ;;
  esac
  case "$base" in
    '' | *[!0123456789]*) return 1 ;;
  esac
  _FRAG_N="$base"
}

# _frag_stored_hash <file>: set _FRAG_STORED to the hash on line 2 ("" when
# line 2 is not a hash marker). A trailing CR and blanks are ignored.
_frag_stored_hash() {
  local l1="" l2="" re="$_FRAG_HASH_RE"
  _FRAG_STORED=""
  { IFS= read -r l1 || true; IFS= read -r l2 || true; } < "$1"
  l2="${l2%$'\r'}"
  while :; do
    case "$l2" in
      *[' '$'\t']) l2="${l2%?}" ;;
      *) break ;;
    esac
  done
  if [[ $l2 =~ $re ]]; then
    _FRAG_STORED="${BASH_REMATCH[1]}"
  fi
}

# _frag_hashes <file>...: set _FRAG_HASH[i] to the sha256 of file i's bytes
# from line 3 on — what its line 2 should record — with one hashing process
# for all of them. Needs _scratch_init.
_frag_hashes() {
  _FRAG_HASH=()
  [ $# -gt 0 ] || return 0
  local tool=() f i=0 payloads=() line
  if command -v sha256sum >/dev/null 2>&1; then
    tool=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    tool=(shasum -a 256)
  else
    _die "fragments: neither sha256sum nor shasum is installed"
  fi
  for f in "$@"; do
    tail -n +3 "$f" > "$_SCRATCH/payload.$i" || _die "fragments: cannot read $f"
    payloads+=("$_SCRATCH/payload.$i")
    i=$((i + 1))
  done
  i=0
  while IFS= read -r line; do
    _FRAG_HASH[$i]="${line%% *}"
    i=$((i + 1))
  done < <("${tool[@]}" "${payloads[@]}")
  [ "$i" -eq $# ] || _die "fragments: ${tool[*]} hashed $i of $# fragments"
}

# A fragment left for the next release, and why.
_frag_skip() {
  echo "WARN: $1: not merged and not consumed: $2. It stays for the next release; fix it (and commit) to include it." >&2
}

cmd_fragments_list() {
  if [ $# -gt 0 ]; then
    _usage_error "fragments list" "takes no arguments (got '$1')"
  fi
  if [ ! -d "$_FRAG_DIR" ]; then
    echo "[]"
    return 0
  fi
  local path files=() ns=() awkargs=() i
  for path in "$_FRAG_DIR"/PR-*.md; do
    if [ -L "$path" ]; then
      echo "WARN: skipping $path: a symbolic link (never read)" >&2
      continue
    fi
    [ -f "$path" ] || continue
    if ! _frag_n "$path"; then
      echo "WARN: skipping non-numeric fragment filename: $path" >&2
      continue
    fi
    files+=("$path")
    ns+=("$_FRAG_N")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo "[]"
    return 0
  fi
  _scratch_init
  _frag_hashes "${files[@]}"
  local status="$_SCRATCH/list.status"
  : > "$status"
  for i in "${!files[@]}"; do
    if [ -s "${files[$i]}" ]; then
      awkargs+=("n=${ns[$i]}" "p=${files[$i]}" "${files[$i]}")
    fi
  done
  if [ "${#awkargs[@]}" -gt 0 ]; then
    LC_ALL=C awk -v mode=list -v status="$status" -v hashline="$_FRAG_HASH_LINE_RE" "$_FRAG_AWK" "${awkargs[@]}" \
      || _die "fragments list: parsing the fragments failed"
  fi
  # The status lines come in the order of the non-empty files.
  local problems=() nonotes=() secs=() tag p pr nn ss j=0
  while IFS=$'\037' read -r tag p pr nn ss; do
    problems+=("$pr")
    nonotes+=("$nn")
    secs+=("$ss")
  done < "$status"
  local out
  out=$(
    for i in "${!files[@]}"; do
      if [ -s "${files[$i]}" ]; then
        pr="${problems[$j]}" nn="${nonotes[$j]}" ss="${secs[$j]}"
        j=$((j + 1))
      else
        pr="an empty file" nn=0 ss=""
      fi
      _frag_stored_hash "${files[$i]}"
      _rec_put "${ns[$i]}" "${files[$i]}" "$_FRAG_STORED" "${_FRAG_HASH[$i]}" "$pr" "$nn" "$ss"
    done | jq -n -R "$_JQ_REC_FIELDS"'rec_fields as $f
      | [range(0; $f | length; 7) as $i
         | {pr_number: ($f[$i] | tonumber), path: $f[$i + 1],
            hash_stored: $f[$i + 2], hash_actual: $f[$i + 3],
            hash_valid: ($f[$i + 2] != "" and $f[$i + 2] == $f[$i + 3]),
            sections: ($f[$i + 6] | if . == "" then [] else split("\u001e") | unique end),
            no_notes: ($f[$i + 5] == "1"),
            problem: (if $f[$i + 4] == "" then null else $f[$i + 4] end)}]
      | sort_by(.pr_number)'
  ) || _die "fragments list: building the JSON failed"
  printf '%s\n' "$out"
}

cmd_fragments_validate() {
  local path="${1:-}"
  if [ $# -gt 1 ]; then
    _usage_error "fragments validate" "takes one fragment path (got $#)"
  fi
  [ -n "$path" ] || _usage_error "fragments validate" "requires a fragment path"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    echo "ERROR: fragment not found (or not a regular file): $path" >&2
    return 2
  fi
  _scratch_init
  _frag_stored_hash "$path"
  _frag_hashes "$path"
  if [ -z "$_FRAG_STORED" ]; then
    echo "ERROR: no hash marker on line 2 of $path" >&2
    return 1
  fi
  if [ "$_FRAG_STORED" = "${_FRAG_HASH[0]}" ]; then
    echo "valid: $path"
    return 0
  fi
  echo "drifted: $path (stored=$_FRAG_STORED, actual=${_FRAG_HASH[0]})" >&2
  return 1
}

# _frag_commit <ref>: the commit <ref> names (never an option).
_frag_commit() {
  case "$1" in
    -*) return 1 ;;
  esac
  git rev-parse --verify --quiet "$1^{commit}"
}

# The fragment paths <to>'s history gained after <from>: one pass. --no-renames,
# so a fragment renamed in the range counts as added (rename detection shows
# it as R); a merge commit's diff is taken against its first parent (-m
# --first-parent, and log.diffMerges pinned for git >= 2.31), so a fragment
# a merge brings in — or adds itself — counts as added by that merge.
# log.showSignature is pinned off: a user's `true` would put gpg's verdict
# lines into the path list.
_frag_added() {
  git -c log.diffMerges=first-parent -c log.showSignature=false log -m --first-parent --no-renames --diff-filter=A \
    --format= --name-only "$1..$2" -- ":(top)$_FRAG_DIR/"
}

cmd_fragments_merge() {
  local range_start="${1:-}" range_end="${2:-}"
  local paths_out="${_OPT_paths_out:-}" remove="${_OPT_remove:-}"
  if [ $# -ne 2 ] || [ -z "$range_start" ] || [ -z "$range_end" ]; then
    _usage_error "fragments merge" "requires exactly <range-start> <range-end> (got $# arguments)"
  fi
  # Emptied first: a run that fails or refuses never leaves a list to delete.
  if [ -n "$paths_out" ]; then
    : > "$paths_out" || _die "fragments merge: cannot write --paths-out $paths_out"
  fi
  local start_sha="" end_sha head_sha
  if [ "$range_start" != ROOT ]; then
    start_sha=$(_frag_commit "$range_start") \
      || _usage_error "fragments merge" "<range-start> '$range_start' does not name a commit (a first release, with no earlier release, starts at ROOT)"
  fi
  [ "$range_end" != ROOT ] || _usage_error "fragments merge" "ROOT is only a <range-start> (the first release)"
  end_sha=$(_frag_commit "$range_end") \
    || _usage_error "fragments merge" "<range-end> '$range_end' does not name a commit"
  if [ -n "$remove" ]; then
    head_sha=$(_frag_commit HEAD) || head_sha=""
    [ "$end_sha" = "$head_sha" ] \
      || _usage_error "fragments merge" "--remove edits the checkout, so <range-end> must be HEAD (got '$range_end')"
  fi
  _scratch_init

  # Unreleased = present at <range-end>: a release consumes a fragment by
  # deleting it in its release commit, which the release's tag carries.
  local entry meta path mode type oid NL=$'\n'
  local cand_n=() cand_p=() cand_o=() order=() i
  git ls-tree --full-tree -z "$end_sha" -- "$_FRAG_DIR/" > "$_SCRATCH/end.tree" \
    || _die "fragments merge: cannot list $_FRAG_DIR/ at $range_end"
  while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    case "${path##*/}" in
      PR-*.md) ;;
      *) continue ;;
    esac
    mode="${meta%% *}"
    oid="${meta##* }"
    type="${meta#* }"
    type="${type%% *}"
    if ! _frag_n "$path"; then
      _frag_skip "$path" "not a PR-<number>.md name"
    elif [ "$mode" = 120000 ]; then
      _frag_skip "$path" "a symbolic link (never read)"
    elif [ "$type" != blob ]; then
      _frag_skip "$path" "not a file"
    else
      cand_n+=("$_FRAG_N")
      cand_p+=("$path")
      cand_o+=("$oid")
    fi
  done < "$_SCRATCH/end.tree"
  if [ "${#cand_p[@]}" -eq 0 ]; then
    return 0
  fi
  while IFS= read -r i; do
    order+=("${i#*$'\t'}")
  done < <(for i in "${!cand_n[@]}"; do printf '%s\t%s\n' "${cand_n[$i]}" "$i"; done | sort -n -k1,1)

  # A release consumed a fragment that is still here when its release point
  # S no longer has it and nothing in S..<range-end> added it back: S's
  # release commit has not reached <range-end>, and merging would release it
  # twice. S is <range-start>, and every v* release tag <range-end> does not
  # contain that was cut from its history after <range-start> — the release
  # an earlier <range-start> choice would miss when its commit never came back.
  local s_name=() s_sha=() ref tsha mb
  if [ -n "$start_sha" ]; then
    s_name+=("$range_start")
    s_sha+=("$start_sha")
  fi
  while IFS= read -r ref; do
    tsha=$(git rev-parse --verify --quiet "$ref^{commit}") || continue
    [ "$tsha" != "$start_sha" ] || continue
    mb=$(git merge-base "$tsha" "$end_sha") || continue
    if [ -n "$start_sha" ] && git merge-base --is-ancestor "$mb" "$start_sha"; then
      continue
    fi
    s_name+=("${ref#refs/tags/}")
    s_sha+=("$tsha")
  done < <(git for-each-ref --format='%(refname)' --no-merged="$end_sha" 'refs/tags/v[0-9]*')
  local k present added refused="" c
  for k in "${!s_sha[@]}"; do
    present=$(git ls-tree --full-tree --name-only "${s_sha[$k]}" -- "$_FRAG_DIR/") \
      || _die "fragments merge: cannot list $_FRAG_DIR/ at ${s_name[$k]}"
    added=$(_frag_added "${s_sha[$k]}" "$end_sha") \
      || _die "fragments merge: git log ${s_name[$k]}..$range_end failed"
    for i in "${order[@]}"; do
      c="${cand_p[$i]}"
      case "$NL$present$NL$added$NL" in
        *"$NL$c$NL"*) continue ;;
      esac
      case "$refused" in
        *"  $c "*) ;;
        *) refused="$refused  $c (deleted by ${s_name[$k]}, ${s_sha[$k]:0:12})$NL" ;;
      esac
    done
  done
  if [ -n "$refused" ]; then
    {
      echo "ERROR: fragments merge: refused. A release already consumed (deleted) these fragments, but its release commit has not reached $range_end, so they are still here:"
      printf '%s' "$refused"
      echo "Merge that release's branch into this one (or cherry-pick its release commit), then run again: merging now would release them twice."
    } >&2
    # Its own exit status: 1 is any other failure (_die), 2 a usage error.
    exit 3
  fi

  local files=() fpaths=() f
  for i in "${order[@]}"; do
    f="$_SCRATCH/fragment.$i"
    git cat-file blob "${cand_o[$i]}" > "$f" || _die "fragments merge: cannot read ${cand_p[$i]} at $range_end"
    if [ ! -s "$f" ]; then
      _frag_skip "${cand_p[$i]}" "an empty file"
      continue
    fi
    files+=("$f")
    fpaths+=("${cand_p[$i]}")
  done
  local consumed=() status="$_SCRATCH/merge.status" awkargs=() j tag p reason
  : > "$status"
  : > "$_SCRATCH/merged"
  if [ "${#files[@]}" -gt 0 ]; then
    _frag_hashes "${files[@]}"
    for j in "${!files[@]}"; do
      _frag_n "${fpaths[$j]}"
      awkargs+=("n=$_FRAG_N" "p=${fpaths[$j]}" "${files[$j]}")
    done
    LC_ALL=C awk -v mode=merge -v status="$status" -v hashline="$_FRAG_HASH_LINE_RE" "$_FRAG_AWK" "${awkargs[@]}" > "$_SCRATCH/merged" \
      || _die "fragments merge: parsing the fragments failed"
  fi
  j=0
  while IFS=$'\037' read -r tag p reason; do
    case "$tag" in
      ok)
        _frag_stored_hash "${files[$j]}"
        if [ -z "$_FRAG_STORED" ]; then
          echo "WARN: $p: hand-edited (line 2 is not a valid hash marker); merged as written" >&2
        elif [ "$_FRAG_STORED" != "${_FRAG_HASH[$j]}" ]; then
          echo "WARN: $p: hand-edited (drifted: its hash does not match its text); merged as written" >&2
        fi
        consumed+=("$p")
        ;;
      nonotes)
        echo "NOTE: $p: no release notes (the no-notes marker); consumed" >&2
        consumed+=("$p")
        ;;
      *) _frag_skip "$p" "$reason" ;;
    esac
    j=$((j + 1))
  done < "$status"

  if [ -n "$remove" ] && [ "${#consumed[@]}" -gt 0 ]; then
    local rm_args=()
    for c in "${consumed[@]}"; do
      rm_args+=(":(top,literal)$c")
    done
    if ! git rm -q -- "${rm_args[@]}"; then
      echo "ERROR: fragments merge --remove: git rm failed (above), so nothing was removed. A fragment with uncommitted edits is not what was merged: commit or discard the edits, then run again." >&2
      exit 1
    fi
  fi
  cat "$_SCRATCH/merged"
  if [ -n "$paths_out" ] && [ "${#consumed[@]}" -gt 0 ]; then
    printf '%s\n' "${consumed[@]}" > "$paths_out" || _die "fragments merge: cannot write --paths-out $paths_out"
  fi
}

# --- Implementation: / Realized-by: blocks ------------------------------------
#
# ONE grammar for a doc's realization block, shared by the verb that writes it
# (set-implementation) and the two that read it (implementation-status, and
# update-index, which records it as the entry's `implementation`). Three
# hand-written parsers used to disagree: the writer anchored on one header
# style, appended inside later code fences and replaced matching lines
# anywhere in the file; the readers dropped wrapped lines differently.
#
#   header   "Implementation:" (ADRs) or "Realized-by:" (SPECs), at the start
#            of a line, outside code fences; the FIRST one is the block (a
#            later one is prose). "Implementation: []" is an explicitly empty
#            block (blanks inside the brackets allowed: "[ ]").
#   item     "- <text>" at any indent (none, 2-space, 4-space): one entry.
#   wrap     an indented, non-blank line after an item continues it; readers
#            join the pieces with one space, and the writer replaces the item
#            with all of its lines.
#   end      any other line ends the block: a blank line, a fence line, or
#            an unindented line that is not a "- " item (a column-0 "- "
#            bullet is an item, not the end).
#   fences   ``` / ~~~ (up to 3 spaces of indent; closed by the same character,
#            at least as long): nothing inside one is a header or an anchor.
#
# An entry's text is "<ref> — <status>[ — <note>]". The awk text below is only
# function definitions; each verb appends its own rules. Values reach awk
# through ENVIRON, never -v (which expands backslash escapes) and never program
# text, and are compared with index(), never as a regex.
#
# Portability (POSIX awk, BWK awk, gawk, mawk): no regex interval ({m,n}:
# older BWK awk and mawk builds lack it; the fence indent is a 3-step loop), no
# literal "[" or "]" in a bracket expression (the escaping rules differ; "[]"
# is matched as text; POSIX classes such as [:space:] are fine in every awk
# but mawk before 1.3.4, which lacks them: mawk >= 1.3.4 is required — what
# Debian and Ubuntu ship today), no "?" chain
# and no anchor inside a group ("^#+([[:space:]]|$)" is two regexes); literal
# text is compared with index() / == or substr(). Every exit status a caller
# checks comes from an explicit "exit N" or from awk failing: set-implementation
# exits 3 from END (no block and no anchor) and 0 otherwise; the readers exit 0.

# blk_fence(s): is s a fence line? Opens or closes the fence (fence_c/fence_n)
# as a side effect. Shared by _release_notes_version.
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_FENCE='
function blk_dedent3(s,    k) {
  for (k = 0; k < 3 && substr(s, 1, 1) == " "; k++) s = substr(s, 2)
  return s
}
function blk_fence(s,    t, c, n) {
  t = blk_dedent3(s)
  c = substr(t, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0
  while (substr(t, n + 1, 1) == c) n++
  if (n < 3) return 0
  if (fence_c == "") {
    if (c == "`" && index(substr(t, n + 1), "`")) return 0
    fence_c = c; fence_n = n
    return 1
  }
  if (c == fence_c && n >= fence_n && substr(t, n + 1) ~ /^[[:space:]]*$/) {
    fence_c = ""; fence_n = 0
    return 1
  }
  return 0
}
function blk_fence_like(s,    t) {
  t = blk_dedent3(s)
  return (substr(t, 1, 3) == "```" || substr(t, 1, 3) == "~~~")
}
'
# blk_line(s) classifies the next line of a file (call blk_reset() first) and
# returns one of
#   head   the block header          BKEY = Implementation | Realized-by
#   empty  the header "<key>: []"    BKEY
#   item   an entry of the block     BTEXT = its text, BIND = its indent
#   wrap   a continuation line       BTEXT = the line, trimmed
#   inner  an indented line in the block before its first item
#   fence  a fence line   code  a line inside a fence   text  anything else
# BLK_END is 1 when the block ended just BEFORE this line (the line itself is
# then classified as fence / code / text). blk is 0 before the header, 1
# inside the block, 2 after it.
#
# blk_collect(c, tag) is the one entry accumulator of the readers: fed every
# line's class, it prints each complete entry as "<tag>\t<text>" (an item's
# text, its wrapped lines joined with one space; an entry left empty is
# dropped). blk_flush(tag) prints the pending one: call it at the end of a
# file, before the next blk_reset().
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_IMPL_BLOCK="$_AWK_FENCE"'
function blk_reset() {
  fence_c = ""; fence_n = 0; blk = 0; blk_items = 0; BLK_END = 0
  blk_pend = 0; blk_cur = ""
}
function blk_line(s,    t, k) {
  BLK_END = 0
  if (blk == 1) {
    if (s ~ /^[[:space:]]*-$/ || s ~ /^[[:space:]]*-[[:space:]]/) {
      BIND = s; sub(/-.*$/, "", BIND)
      t = s; sub(/^[[:space:]]*-[[:space:]]*/, "", t); sub(/[[:space:]]+$/, "", t)
      BTEXT = t; blk_items++
      return "item"
    }
    if (s ~ /^[[:space:]]+[^[:space:]]/ && !blk_fence_like(s)) {
      t = s; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      BTEXT = t
      return (blk_items ? "wrap" : "inner")
    }
    blk = 2; BLK_END = 1
  }
  if (blk_fence(s)) return "fence"
  if (fence_c != "") return "code"
  if (blk == 0 && s ~ /^(Implementation|Realized-by):/) {
    k = index(s, ":")
    t = substr(s, k + 1); gsub(/[[:space:]]/, "", t)
    if (t == "") {
      BKEY = substr(s, 1, k - 1); blk = 1; blk_items = 0
      return "head"
    }
    if (t == "[]") {
      BKEY = substr(s, 1, k - 1); blk = 2
      return "empty"
    }
  }
  return "text"
}
function blk_flush(tag) {
  if (blk_pend && blk_cur != "") print tag "\t" blk_cur
  blk_pend = 0; blk_cur = ""
}
function blk_collect(c, tag) {
  if (BLK_END) blk_flush(tag)
  else if (c == "item") { blk_flush(tag); blk_pend = 1; blk_cur = BTEXT }
  else if (c == "wrap") blk_cur = (blk_cur == "" ? BTEXT : blk_cur " " BTEXT)
}
'

# The entries of the block, one "<tag>\t…" line each, for a reader:
#   H\t<key>   the header           E\t<key>   an explicitly empty block
#   I\t<text>  an entry (blk_collect)
# Nothing at all: the doc has no block. Reads the doc on stdin.
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_IMPL_READ="$_AWK_IMPL_BLOCK"'
BEGIN { blk_reset() }
{
  c = blk_line($0)
  blk_collect(c, "I")
  if (BLK_END) exit
  if (c == "head") print "H\t" BKEY
  else if (c == "empty") { print "E\t" BKEY; exit }
}
END { blk_flush("I") }
'

cmd_set_implementation() {
  # Options (--ref/--status/--note, anywhere) come from _parse_args.
  local file="${1:-}" ref="${_OPT_ref:-}" status="${_OPT_status:-}" note="${_OPT_note:-}"

  [ $# -le 1 ] || _usage_error set-implementation "takes one doc path (got $#)"
  # An entry is one bullet line: a line break in a value would end the block
  # (and once injected sed commands). Refused, never folded or trimmed away.
  case "$ref$note" in
    *$'\n'*|*$'\r'*)
      echo "ERROR: set-implementation: --ref and --note must each be one line (an entry is one bullet line)." >&2
      exit 2
      ;;
  esac
  _trim "$ref"; ref="$_TRIMMED"
  _trim "$note"; note="$_TRIMMED"
  if [ -z "$file" ] || [ -z "$ref" ] || [ -z "$status" ]; then
    _usage_error set-implementation "requires <path> --ref <kind: ref> --status <status>"
  fi
  if [ ! -f "$file" ]; then
    echo "ERROR: file not found: $file" >&2
    exit 2
  fi
  case "$status" in
    complete|partial|in-progress|not-started|reverted|superseded|blocked) ;;
    *)
      echo "ERROR: invalid status: $status (allowed: complete partial in-progress not-started reverted superseded blocked)" >&2
      exit 2
      ;;
  esac

  local entry="$ref — $status"
  [ -z "$note" ] || entry="$entry — $note"

  # ONE awk pass writes the whole new doc to a tmp beside it:
  #   - the ref has an entry in the block: its first entry (all of its lines)
  #     is replaced, in place, at its own indent, and any later entry of the
  #     same ref is dropped (one entry per ref); nothing outside the block is
  #     touched;
  #   - otherwise the entry is appended to the block, at its last item's
  #     indent (2 spaces for an empty block); "<key>: []" becomes "<key>:";
  #   - no block: one is created after the paragraph holding the first
  #     **Date**: / **Date:** / **Created**: / **Created:** line —
  #     Implementation: after a date (ADR), Realized-by: after Created (SPEC);
  #   - neither: exit 3, nothing written.
  # The doc is read on stdin: an operand such as "x=1.md" would be an awk
  # variable assignment.
  local rc=0
  _tmp_beside "$file"
  # shellcheck disable=SC2016  # awk program, not shell expansion
  DT_REF="$ref" DT_ENTRY="$entry" awk "$_AWK_IMPL_BLOCK"'
    function is_mine(t) { return t == ref || index(t, ref " —") == 1 }
    { L[++n] = $0 }
    END {
      ref = ENVIRON["DT_REF"]; entry = ENVIRON["DT_ENTRY"]
      blk_reset(); has = 0; anchor = 0
      for (i = 1; i <= n; i++) {
        c = blk_line(L[i])
        if (c == "head" || c == "empty") { has = 1; break }
        if (!anchor && c == "text" && L[i] ~ /^[*][*](Date[*][*]:|Date:[*][*]|Created[*][*]:|Created:[*][*])/) {
          anchor = i
          key = (L[i] ~ /^[*][*]Created/) ? "Realized-by" : "Implementation"
        }
      }
      if (!has && !anchor) exit 3
      if (!has) {
        for (j = anchor + 1; j <= n; j++)
          if (L[j] ~ /^[[:space:]]*$/ || L[j] ~ /^#+$/ || L[j] ~ /^#+[[:space:]]/ || blk_fence_like(L[j])) break
        for (i = 1; i < j; i++) print L[i]
        print ""; print key ":"; print "  - " entry
        if (j <= n && L[j] !~ /^[[:space:]]*$/) print ""
        for (i = j; i <= n; i++) print L[i]
        exit 0
      }
      blk_reset(); done = 0; ind = "  "; drop = 0
      for (i = 1; i <= n; i++) {
        c = blk_line(L[i])
        if (BLK_END && !done) { print ind "- " entry; done = 1 }
        if (c == "empty") { print BKEY ":"; print "  - " entry; done = 1; continue }
        if (c == "item") {
          ind = BIND; drop = 0
          if (is_mine(BTEXT)) {
            # The first entry of the ref is replaced in place; a later one
            # (a duplicate) is dropped, wrapped lines and all.
            if (!done) print BIND "- " entry
            done = 1; drop = 1; continue
          }
        }
        if (c == "wrap" && drop) continue
        print L[i]
      }
      if (!done) print ind "- " entry
    }' < "$file" > "$_TMP" || rc=$?
  case "$rc" in
    0) ;;
    3)
      echo "ERROR: $file has no Implementation: / Realized-by: block, and no **Date**:, **Date:**, **Created**: or **Created:** line (outside code fences) to add one after. Add the block by hand; nothing was written." >&2
      exit 1
      ;;
    *) _die "cannot rewrite $file; it is unchanged." ;;
  esac
  if cmp -s "$_TMP" "$file"; then
    rm -f "$_TMP"
  else
    _replace_file "$_TMP" "$file"
  fi
}

cmd_implementation_status() {
  [ $# -gt 0 ] || _usage_error implementation-status "requires at least one doc path"

  local path out line key items
  for path in "$@"; do
    if [[ ! -f "$path" ]]; then
      echo "$path: not found" >&2
      continue
    fi
    out=$(awk "$_AWK_IMPL_READ" < "$path") || _die "cannot read $path"
    key="" items=""
    while IFS= read -r line; do
      case "$line" in
        H$'\t'*) key="${line#??}" ;;
        E$'\t'*) key="${line#??}"; items="[]" ;;
        I$'\t'*) items="${items:+$items$'\n'}    - ${line#??}" ;;
      esac
    done <<< "$out"
    if [ -z "$key" ]; then
      echo "$path: no Implementation field"
    elif [ "$items" = "[]" ]; then
      echo "$path: $key: [] (intentionally empty)"
    elif [ -z "$items" ]; then
      echo "$path: $key: (no entries)"
    else
      echo "$path:"
      printf '%s\n' "$items"
    fi
  done
}

# --- `tools` subcommand: vendor/uninstall/status doc-tools.sh itself ---
#
# The copy being run is either the PLUGIN's (scripts/doc-tools.sh in the
# doc-superpowers plugin: a skills/doc-superpowers/SKILL.md above it, the CI
# helpers under scripts/hooks/ci/) or a VENDORED one (.github/scripts/ in a
# consuming repo, put there by tools install or install --ci). Only the plugin
# has helpers to ship, a version (its RELEASE-NOTES.md) and copies to compare
# a vendored file against, so:
#   install    from a vendored copy: itself only (onto itself: only +x);
#              --with-helpers is refused, writing nothing
#   uninstall  deletes only files byte-identical to the plugin's copies — a
#              vendored copy has nothing to compare against, so it is refused
#   status     from a vendored copy: presence only, no drift, no version
# (The version used to be looked up at the git toplevel too, which reported
# the CONSUMING repo's RELEASE-NOTES.md as the plugin's.)
# (A parameter expansion, not $(dirname …): this runs at load, on every call
# of every verb, hooks included. SCRIPT_DIR is absolute with no trailing
# slash, so this is its parent — "" for a script in "/<dir>", which still
# yields "/…" paths below.)
_TOOLS_ROOT="${SCRIPT_DIR%/*}"

_tools_is_plugin() {
  [ -f "$_TOOLS_ROOT/skills/doc-superpowers/SKILL.md" ] && [ -d "$SCRIPT_DIR/hooks/ci" ]
}

# The helper directories the CI templates run as .github/scripts/<dir>/*.sh,
# laid out in the plugin as scripts/hooks/ci/<dir>/. doc-superpowers-steps
# holds the step scripts every template runs; doc-pr-release the producer
# helpers of doc-pr-release.yml.
_TOOLS_HELPER_DIRS="doc-pr-release doc-superpowers-steps"

# _tools_copy <src> <dest> <mode for a new dest> [exec]: copy through a tmp
# beside <dest> (never cp over a file a running CI job may be reading). An
# existing <dest> keeps its mode; [exec] = 1 (a script the CI templates run
# directly) makes the result executable whatever that mode was. Sets
# _TOOLS_SAME=1 and copies nothing when both name the same file (which is
# still made executable under [exec]).
_tools_copy() {
  _tools_no_link "$2"
  _TOOLS_SAME=0
  if [ -e "$2" ] && [ "$1" -ef "$2" ]; then
    _TOOLS_SAME=1
    if [ "${4:-0}" = 1 ]; then
      chmod a+x "$2" || _die "cannot chmod a+x $2"
    fi
    return 0
  fi
  _tmp_beside "$2"
  cp "$1" "$_TMP" || _die "cannot copy $1 to $2"
  _replace_file "$_TMP" "$2" "$3" "${4:-0}"
}

# The helper directories a tools install/uninstall acts on: every one for
# --with-helpers, the --helper ones (validated) otherwise; "" for none.
_tools_helper_selection() {
  local d sel=""
  if [ -n "${_OPT_with_helpers:-}" ]; then
    [ "${#_OPTV_helper[@]}" -eq 0 ] || _usage_error "$1" "--with-helpers and --helper are exclusive"
    printf '%s' "$_TOOLS_HELPER_DIRS"
    return 0
  fi
  for d in ${_OPTV_helper[@]+"${_OPTV_helper[@]}"}; do
    case " $_TOOLS_HELPER_DIRS " in
      *" $d "*) ;;
      *) _usage_error "$1" "unknown helper directory '$d' (one of: $_TOOLS_HELPER_DIRS)" ;;
    esac
    case " $sel " in
      *" $d "*) ;;
      *) sel="${sel:+$sel }$d" ;;
    esac
  done
  printf '%s' "$sel"
}

# _tools_no_link <path>: refuse (before anything is written) when <path> or a
# directory on its way is a symbolic link — a committed .github/scripts link
# would send the copy (or the removal) anywhere. A relative path is checked
# component by component; an absolute one with its own directory.
_tools_no_link() {
  local p="$1" stop=""
  case "$p" in
    /*) stop="${p%/*}"; stop="${stop%/*}" ;;
  esac
  while [ -n "$p" ] && [ "$p" != "$stop" ] && [ "$p" != "." ] && [ "$p" != "/" ]; do
    [ ! -L "$p" ] || _die "$p is a symbolic link (on the way to $1): not writing or removing through it. Nothing was changed."
    case "$p" in
      */*) p="${p%/*}" ;;
      *) p="" ;;
    esac
  done
}

cmd_tools_install() {
  [ $# -eq 0 ] || _usage_error "tools install" "takes no arguments (got '$1')"
  local dest="${_OPT_dest:-.github/scripts}" helpers d f n
  helpers=$(_tools_helper_selection "tools install")
  local src="$SCRIPT_DIR/doc-tools.sh"

  # Everything a helper install needs is checked before anything is written.
  if [ -n "$helpers" ]; then
    if ! _tools_is_plugin; then
      echo "ERROR: --with-helpers / --helper ship the plugin's CI helpers, and $src is a vendored copy, which has none. Run the plugin's doc-tools.sh. Nothing was installed." >&2
      exit 1
    fi
    for d in $helpers; do
      [ -d "$SCRIPT_DIR/hooks/ci/$d" ] || _die "the plugin's helper directory $SCRIPT_DIR/hooks/ci/$d is missing. Nothing was installed."
      for f in "$SCRIPT_DIR/hooks/ci/$d"/*.sh; do
        _tools_no_link "$dest/$d/${f##*/}"
      done
    done
    case " $helpers " in
      *" doc-pr-release "*) _tools_no_link "RELEASE-NOTES.next/README.md" ;;
    esac
  fi
  _tools_no_link "$dest/doc-tools.sh"

  mkdir -p "$dest" || _die "cannot create $dest"
  _tools_copy "$src" "$dest/doc-tools.sh" 755 1
  if [ "$_TOOLS_SAME" = 1 ]; then
    echo "doc-tools.sh is already at $dest/doc-tools.sh (it is the copy being run)"
  else
    echo "Installed doc-tools.sh → $dest/doc-tools.sh"
  fi
  [ -n "$helpers" ] || return 0

  for d in $helpers; do
    mkdir -p "$dest/$d" || _die "cannot create $dest/$d"
    n=0
    for f in "$SCRIPT_DIR/hooks/ci/$d"/*.sh; do
      [ -f "$f" ] || continue
      _tools_copy "$f" "$dest/$d/$(basename "$f")" 755 1
      n=$((n + 1))
    done
    echo "Installed $n $d helpers → $dest/$d/"
  done

  # RELEASE-NOTES.next/README.md (with the doc-pr-release helpers: the
  # fragment format they write) — never overwrite (user may have edits).
  case " $helpers " in
    *" doc-pr-release "*) ;;
    *) return 0 ;;
  esac
  f="$SCRIPT_DIR/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md"
  if [ -f "$f" ] && [ ! -e "RELEASE-NOTES.next/README.md" ]; then
    mkdir -p RELEASE-NOTES.next || _die "cannot create RELEASE-NOTES.next"
    _tools_copy "$f" "RELEASE-NOTES.next/README.md" 644
    echo "Created RELEASE-NOTES.next/README.md (fragment format spec)"
  fi
}

cmd_tools_uninstall() {
  [ $# -eq 0 ] || _usage_error "tools uninstall" "takes no arguments (got '$1')"
  local dest="${_OPT_dest:-.github/scripts}" only
  only=$(_tools_helper_selection "tools uninstall")
  local src="$SCRIPT_DIR/doc-tools.sh"
  if ! _tools_is_plugin; then
    echo "ERROR: tools uninstall deletes only files identical to the plugin's copies, and $src is a vendored copy with nothing to compare them with. Run the plugin's doc-tools.sh. Nothing was removed." >&2
    exit 1
  fi

  # A file is removed only when it is byte-identical to the plugin's copy of
  # it (and is not that copy). Anything else — a locally edited or drifted
  # file, one from another plugin version, a file the user added — is kept
  # and reported. RELEASE-NOTES.next/README.md goes with the doc-pr-release
  # helpers only when it is the plugin's own spec and alone there: an edited
  # one, or one beside fragments, is kept.
  local removed=0 kept=0 d f p n
  _tools_no_link "$dest/doc-tools.sh"
  for d in $_TOOLS_HELPER_DIRS; do
    _tools_no_link "$dest/$d/x"
  done
  f="$dest/doc-tools.sh"
  if [ -z "$only" ] && [ -f "$f" ]; then
    if [ "$src" -ef "$f" ]; then
      echo "Kept $f (it is the plugin's own copy)"
      kept=$((kept + 1))
    elif cmp -s "$src" "$f"; then
      rm -f "$f" || _die "cannot remove $f"
      echo "Removed $f"
      removed=$((removed + 1))
    else
      echo "Kept $f (it differs from the plugin's copy: local edits or another version; delete it by hand if it is not needed)"
      kept=$((kept + 1))
    fi
  fi

  for d in ${only:-$_TOOLS_HELPER_DIRS}; do
    [ -d "$dest/$d" ] || continue
    n=0
    for p in "$SCRIPT_DIR/hooks/ci/$d"/*.sh; do
      [ -f "$p" ] || continue
      f="$dest/$d/$(basename "$p")"
      if [ -f "$f" ] && ! [ "$p" -ef "$f" ] && cmp -s "$p" "$f"; then
        rm -f "$f" || _die "cannot remove $f"
        n=$((n + 1))
      fi
    done
    [ "$n" -eq 0 ] || echo "Removed $n $d helpers from $dest/$d/"
    removed=$((removed + n))
    if rmdir "$dest/$d" 2>/dev/null; then
      :
    else
      echo "Kept $dest/$d/ (it holds files that are not unmodified plugin helpers: local edits or your own)"
      kept=$((kept + 1))
    fi
  done

  # Clean up an empty destination directory.
  rmdir "$dest" 2>/dev/null || true

  case " ${only:-$_TOOLS_HELPER_DIRS} " in
    *" doc-pr-release "*)
      f="RELEASE-NOTES.next/README.md"
      p="$SCRIPT_DIR/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md"
      if [ -f "$f" ] && [ ! -L "$f" ] && [ -f "$p" ] && cmp -s "$p" "$f"; then
        _tools_no_link "$f"
        local others
        others=$(cd RELEASE-NOTES.next && ls -A | grep -vxF README.md) || others=""
        if [ -z "$others" ]; then
          rm -f "$f" || _die "cannot remove $f"
          rmdir RELEASE-NOTES.next 2>/dev/null || true
          echo "Removed $f (the plugin's fragment-format spec; nothing else was there)"
          removed=$((removed + 1))
        fi
      fi
      ;;
  esac

  if [ "$removed" -eq 0 ] && [ "$kept" -eq 0 ]; then
    echo "Nothing to uninstall at $dest"
  fi
  return 0
}

cmd_tools_status() {
  [ $# -eq 0 ] || _usage_error "tools status" "takes no arguments (got '$1')"
  local dest="${_OPT_dest:-.github/scripts}"
  local installed="$dest/doc-tools.sh" src="$SCRIPT_DIR/doc-tools.sh"
  local plugin=0 ver="unknown"
  if _tools_is_plugin; then
    plugin=1
    ver=$(_release_notes_version "$_TOOLS_ROOT/RELEASE-NOTES.md" 2>/dev/null) || ver="unknown"
  fi

  if [[ ! -f "$installed" ]]; then
    echo "doc-tools.sh: not installed at $dest"
    return 0
  fi

  if [ "$src" -ef "$installed" ]; then
    if [ "$plugin" = 1 ]; then
      echo "doc-tools.sh: $installed is the plugin's own copy (v$ver), not a vendored one"
    else
      echo "doc-tools.sh: installed at $dest (this is the copy being run: run tools status from the plugin's doc-tools.sh to check it for drift)"
    fi
  elif [ "$plugin" = 0 ]; then
    echo "doc-tools.sh: installed at $dest (not compared: $src is a vendored copy, not the plugin's)"
  elif cmp -s "$src" "$installed"; then
    echo "doc-tools.sh: installed at $dest (matches plugin v$ver)"
  else
    echo "doc-tools.sh: installed at $dest (DRIFTED from plugin v$ver)"
  fi

  # Helper-presence summary (and, when there is a plugin to compare, how many
  # differ from the plugin's copy and how many the plugin does not ship at
  # all — a file the user added is not drift).
  local d f p n drift added note
  for d in $_TOOLS_HELPER_DIRS; do
    if [ -d "$dest/$d" ]; then
      n=0 drift=0 added=0
      for f in "$dest/$d"/*.sh; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        [ "$plugin" = 1 ] || continue
        p="$SCRIPT_DIR/hooks/ci/$d/${f##*/}"
        if [ ! -f "$p" ]; then
          added=$((added + 1))
        elif ! cmp -s "$p" "$f"; then
          drift=$((drift + 1))
        fi
      done
      note=""
      [ "$drift" -eq 0 ] || note="$drift differ from the plugin's"
      [ "$added" -eq 0 ] || note="${note:+$note, }$added not shipped by the plugin"
      echo "$d helpers: $n installed at $dest/$d/${note:+ ($note)}"
    else
      echo "$d helpers: not installed at $dest"
    fi
  done
  # An upgrade keeps an existing README (tools install never overwrites it),
  # so an older copy keeps giving the advice of its version: say so.
  if [[ -f "RELEASE-NOTES.next/README.md" ]]; then
    p="$SCRIPT_DIR/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md"
    if [ "$plugin" = 0 ] || [ ! -f "$p" ]; then
      echo "RELEASE-NOTES.next/README.md: present"
    elif cmp -s "$p" "RELEASE-NOTES.next/README.md"; then
      echo "RELEASE-NOTES.next/README.md: present (matches the plugin's fragment-format spec)"
    else
      echo "RELEASE-NOTES.next/README.md: present (differs from the plugin's fragment-format spec: an older copy, or local edits — compare it with $p, and replace an older copy with it)"
    fi
  else
    echo "RELEASE-NOTES.next/README.md: not present"
  fi
}

cmd_tools_version() {
  [ $# -eq 0 ] || _usage_error "tools version" "takes no arguments (got '$1')"
  if ! _tools_is_plugin; then
    echo "ERROR: $SCRIPT_DIR/doc-tools.sh is a vendored copy: its version is unknown (tools version reads the plugin's RELEASE-NOTES.md)." >&2
    exit 1
  fi
  _release_notes_version "$_TOOLS_ROOT/RELEASE-NOTES.md" || exit 1
}

# --- Spec claims -----------------------------------------------------------------
#
# `claims <verb>`: executable spec claims. Each governing doc's claims live in
# a sidecar, docs/spec-claims/<DOC-ID>.json; docs/spec-claims/config.json
# (optional) holds the host's settings over _JQ_CLAIMS_DEFAULTS. A project
# without docs/spec-claims/ sees nothing new: every verb prints
# {"verb":…,"enabled":false,"exit":0} and exits 0 (_claims_init).
#
# Exit family, claims verbs only: 0 as expected · 1 findings · 2 could not
# run · 3 usage; precedence 1 > 2 > 0; an internal failure is 2, never 1. The
# run prints exactly one verdict object on stdout — a usage error too
# (_claims_usage_error); rulings --format markdown prints Markdown instead.
# What keeps both true whatever fails:
#   - fd 9 is the run's real stdout (_main: exec 9>&1; bash 3.2 has no
#     {fd}). Every verdict is written >&9, so one printed inside $(…) reaches
#     the caller instead of the captured value.
#   - _claims_mark_emitted <rc> records "printed, exit <rc>" twice:
#     _CL_EMITTED=1 / _CL_EMITTED_RC in this shell, and $_SCRATCH/cl-emitted
#     (holding <rc>) for the parent of a $(…) (a subshell's variables never
#     reach it). The file only once scratch exists — never "/cl-emitted" —
#     since no claims code runs in a $(…) before that. Every emitter marks
#     before it prints, and prints its verdict before any stderr line (whose
#     failure, with stderr closed, is ignored).
#   - _on_exit: a run that printed a verdict exits with that verdict's code
#     (whatever status reached the trap); one that printed nothing gets one
#     fallback object, exit 2.
#   - _die delegates to _claims_die (exit 2). A $(…) of claims code that can
#     die is written  v=$(…) || _claims_propagate $?  — the subshell already
#     printed the one verdict; the parent only ends with its status.
#   - every jq call goes through _claims_jq, which dies on a jq failure (a
#     `jq -e` predicate, whose status is an answer, calls jq inside an if).
#
# Scratch files (in $_SCRATCH): cl-config.json (the merged config),
# cl-config-unknown.json (the host keys the defaults do not know), and the
# JSONL accumulators cl-findings.jsonl, cl-advisories.jsonl, cl-indet.jsonl
# and cl-results.jsonl that _claims_emit folds into the verdict. The claim
# lists and the --staged scope (cl-claims.json, cl-touched.json, …) are
# described with their loader, under "DOC-IDs, the claim loader" below.

_CL_ENABLED=0        # 1: docs/spec-claims/ exists
_CL_MODE=""          # staged | all | head: which tree _claims_read reads
_CL_ROOT=""          # the work tree's top level, absolute
_CL_ROOT_PHYS=""     # its physical path (pwd -P), once _claims_contained_path needs it
_CL_BASE_REF=""      # --base, else config "base", else origin/main
_CL_MB=""            # git merge-base HEAD <base>; empty when unresolvable
_CL_ALL_BLOCKING=0   # 1: every finding blocks (run, promote, gate, attest)
_CL_BASE_UNUSED=0    # 1: the verb never reads the base (render): no base-unresolvable
_CL_JS=""            # _claims_json_str's result

# The config defaults, deep-merged (jq *) under the host's config.json:
# objects merge, arrays and scalars are replaced — except governing_extra,
# which is appended to governing. Output: two compact lines, the merged
# config, then the host's top-level keys the defaults do not have (each a V1
# finding). $host is the host file slurped ([] when there is none).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_DEFAULTS='{"schema":1,"base":"origin/main","governing":["docs/adr/*.md","docs/specs/*.md"],"governing_extra":[],
 "normative_headings":[],"descriptive_headings":[],"kinds":[],"code_roots":[],
 "plans":["docs/superpowers/plans/*.md","docs/plans/*.md"],"tracker_patterns":[],
 "source_doc_patterns":["docs/issues/","docs/superpowers/specs/"],
 "runners":{},"log_adapter":null,"config_adapter":null,
 "policy":{"in_plan_ruling_requires_gate_record":true,"outside_plan_presumption":"CODE-DIVERGES","doc_stale_outside_plan_requires":null},
 "blocking":["V1","V2","V3","V4","V5","V6","V10","V11","V12"]} as $d
 | ($host[0] // {}) as $h
 | (($d * $h) | .governing += .governing_extra),
   [$h | keys_unsorted[] | . as $k | select($d | has($k) | not)]'

# The verdict object. A finding blocks — stays in findings, and makes the
# exit 1 — when $all is 1 or its check is in the config's blocking list;
# otherwise it is reported as an advisory (code "non-blocking"). Output: the
# exit code, then the object (one line).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_EMIT='def blocks($blk): $all == 1 or (.check as $c | $blk | any(.[]; . == $c));
 ($cfg[0].blocking // []) as $blk
 | [$f[] | select(blocks($blk))] as $findings
 | ([$f[] | select(blocks($blk) | not) | {check, claim, code: "non-blocking", message}] + $a) as $advisories
 | (if ($findings | length) > 0 then 1 elif ($i | length) > 0 then 2 else 0 end) as $exit
 | ({verb: $verb, enabled: true, exit: $exit,
     base: {ref: $ref, merge_base: (if $mb == "" then null else $mb end)},
     findings: $findings, advisories: $advisories, indeterminate: $i, results: $r}
    + ($extra | del(.verb, .enabled, .exit)))
 | (.exit | tostring), tojson'

# A JSON string literal for $1 into _CL_JS, in bash alone: _claims_die and
# the EXIT trap's fallback must print when jq is what failed (or is missing).
_claims_json_str() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//[[:cntrl:]]/}
  _CL_JS="\"$s\""
}

# Print one line of the run's output to fd 9 (stdout when fd 9 is not open:
# a failure before _main's exec 9>&1). A write that fails (a closed pipe)
# must not turn the exit status into 1.
_claims_out() {
  if { : >&9; } 2>/dev/null; then
    printf '%s\n' "$1" >&9 || true
  else
    printf '%s\n' "$1" || true
  fi
}

# _claims_mark_emitted <rc>: record that this run's verdict, carrying exit
# code <rc>, is being printed; _on_exit then ends the run with <rc>. The
# variables first, before any I/O; the marker file (holding <rc>) only once
# the scratch dir exists.
_claims_mark_emitted() {
  _CL_EMITTED=1
  _CL_EMITTED_RC="$1"
  if [ -n "$_SCRATCH" ]; then
    printf '%s' "$1" > "$_SCRATCH/cl-emitted" || true
  fi
}

# _claims_die <message>: the run could not run. Prints the error verdict to
# fd 9 and exits 2 — inside $(…) too (the parent then _claims_propagate's).
# The verdict before the stderr line, and a failed stderr write (stderr
# closed) ignored: the run must still end with its verdict and 2.
_claims_die() {
  local verb
  _claims_mark_emitted 2
  _claims_json_str "$_CL_VERB"
  verb=$_CL_JS
  _claims_json_str "$*"
  _claims_out "{\"verb\":$verb,\"enabled\":true,\"exit\":2,\"error\":$_CL_JS}"
  echo "ERROR: $*" >&2 || true
  exit 2
}

# _claims_usage_error <verb> <message>: a claims command-line error. One
# verdict object (exit 3; enabled when docs/spec-claims/ exists here, as the
# inert check reads it), then _usage_error's two stderr lines; exit 3.
_claims_usage_error() {
  local verb enabled=false
  _claims_mark_emitted 3
  if [ -d docs/spec-claims ]; then enabled=true; fi
  _claims_json_str "$_CL_VERB"
  verb=$_CL_JS
  _claims_json_str "$1: $2"
  _claims_out "{\"verb\":$verb,\"enabled\":$enabled,\"exit\":3,\"error\":$_CL_JS}"
  echo "ERROR: $1: $2" >&2 || true
  echo "       See: doc-tools.sh $1 --help" >&2 || true
  exit "$_USAGE_RC"
}

# _claims_propagate <rc>: end the run with a failed $(…)'s status. The
# subshell already printed the verdict (_claims_die), so nothing is printed;
# when it printed none, _on_exit adds the fallback.
_claims_propagate() {
  exit "${1:-2}"
}

# The EXIT trap's object for a claims run that printed no verdict.
_claims_fallback() {
  local verb
  _claims_json_str "$_CL_VERB"
  verb=$_CL_JS
  _claims_out "{\"verb\":$verb,\"enabled\":true,\"exit\":2,\"error\":\"internal failure (rc $1)\"}"
}

# _claims_jq <label> <jq args…>: jq, dying with "jq failed (<label>, rc <n>)"
# when it fails.
_claims_jq() {
  local label="$1" rc=0
  shift
  jq "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then _claims_die "jq failed ($label, rc $rc)"; fi
}

# JSONL rows the verdict is built from; "-" is null.
_claims_finding() {
  _claims_jq finding -nc --arg check "$1" --arg claim "$2" --arg doc "$3" --arg message "$4" \
    '{check: $check, claim: (if $claim == "-" then null else $claim end),
      doc: (if $doc == "-" then null else $doc end), message: $message}' \
    >> "$_SCRATCH/cl-findings.jsonl"
}
_claims_advisory() {
  _claims_jq advisory -nc --arg check "$1" --arg claim "$2" --arg code "$3" --arg message "$4" \
    '{check: $check, claim: (if $claim == "-" then null else $claim end), code: $code, message: $message}' \
    >> "$_SCRATCH/cl-advisories.jsonl"
}
_claims_indeterminate() {
  _claims_jq indeterminate -nc --arg check "$1" --arg claim "$2" --arg reason "$3" \
    '{check: $check, claim: (if $claim == "-" then null else $claim end), reason: $reason}' \
    >> "$_SCRATCH/cl-indet.jsonl"
}
_claims_result() {
  _claims_jq result -nc --argjson r "$1" '$r' >> "$_SCRATCH/cl-results.jsonl"
}

# _claims_read <path>: the proposed content of a repo path — the index's in
# mode staged, the working tree's in mode all, HEAD's in mode head. Returns 1
# (printing nothing) when the path is absent there. cat-file, not show: a
# directory is absent too (show would list a tree), and no textconv applies.
_claims_read() {
  case "$_CL_MODE" in
    staged) git cat-file blob ":$1" 2>/dev/null || return 1 ;;
    head) git cat-file blob "HEAD:$1" 2>/dev/null || return 1 ;;
    *)
      [ -f "$1" ] || return 1
      cat -- "$1" || return 1
      ;;
  esac
}
# _claims_read_at <rev> <path>: the content of <path> at <rev>; 1 when absent.
_claims_read_at() {
  git cat-file blob "$1:$2" 2>/dev/null || return 1
}

# _claims_safe_relpath <path>: 0 when <path> is a repo path a claims run may
# read or write: relative, with no empty, "." or ".." segment (the index
# could never hold one, so --staged and --all agree, and nothing outside the
# work tree is reached). Sidecar docs (the loader), trackers (V5), ruling
# records (V6), test files and mutant files (V3) all go through it.
_claims_safe_relpath() {
  case "/$1/" in
    */../*|*/./*|*//*) return 1 ;;
  esac
  return 0
}

# _claims_contained_path <path>: for a work-tree read (mode all) of a safe
# repo path, 0 when reading or writing <path> stays inside the work tree: no
# existing component of it (each directory prefix, and the file itself) is a
# symbolic link, and its parent directory, when it exists, is physically
# under the work tree's top level. A path through a link is never followed:
# _claims_read's [ -f ] would read through it and render would write through
# it (_tmp_beside refuses only a linked file, not a linked directory on the
# way). The index and HEAD need no such check: git stores a link as a blob,
# so a path through one is simply absent there.
_claims_contained_path() {
  local rest="$1" pre="" seg dir phys
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    pre=${pre:+$pre/}$seg
    [ ! -L "$pre" ] || return 1
  done
  case "$1" in
    */*) dir=${1%/*} ;;
    *) dir=. ;;
  esac
  [ -d "$dir" ] || return 0
  if [ -z "$_CL_ROOT_PHYS" ]; then
    _CL_ROOT_PHYS=$(CDPATH='' cd -P -- "$_CL_ROOT" 2>/dev/null && pwd -P) \
      || _claims_die "cannot resolve the work tree's physical path ($_CL_ROOT)"
  fi
  phys=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
  case "$phys/" in
    "$_CL_ROOT_PHYS"/*) return 0 ;;
  esac
  return 1
}

# _claims_glob_match <path> <glob>: a case pattern, so * also matches "/"
# ("docs/specs/*.md" matches docs/specs/sub/x.md).
_claims_glob_match() {
  # shellcheck disable=SC2254  # the glob is the pattern
  case "$1" in
    $2) return 0 ;;
  esac
  return 1
}

# _claims_init <staged|all|head>: inert check, scratch, config, base.
# Without docs/spec-claims/ (in the working tree) it prints the inert object
# and exits 0, before any config is read. Call it in the main shell, after
# _parse_args and before the verb checks its required arguments.
_claims_init() {
  _CL_MODE="$1"
  if [ ! -d docs/spec-claims ]; then
    _CL_ENABLED=0
    _claims_mark_emitted 0
    _claims_json_str "$_CL_VERB"
    _claims_out "{\"verb\":$_CL_JS,\"enabled\":false,\"exit\":0}"
    _exit_ok
  fi
  _CL_ENABLED=1
  _scratch_init
  _CL_ROOT=$(git rev-parse --show-toplevel) || _claims_die "cannot resolve the work tree's top level"
  : > "$_SCRATCH/cl-findings.jsonl"
  : > "$_SCRATCH/cl-advisories.jsonl"
  : > "$_SCRATCH/cl-indet.jsonl"
  : > "$_SCRATCH/cl-results.jsonl"

  local host="$_SCRATCH/cl-config-host.json" cfg
  if _claims_read docs/spec-claims/config.json > "$host"; then
    if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$host" >/dev/null 2>&1; then
      _claims_die "docs/spec-claims/config.json is not one JSON object"
    fi
    set -- --slurpfile host "$host"
  else
    set -- --argjson host '[]'
  fi
  cfg=$(_claims_jq config-merge -nc "$@" "$_JQ_CLAIMS_DEFAULTS") || _claims_propagate $?
  printf '%s\n' "${cfg%%$'\n'*}" > "$_SCRATCH/cl-config.json"
  printf '%s\n' "${cfg#*$'\n'}" > "$_SCRATCH/cl-config-unknown.json"

  _CL_BASE_REF="${_OPT_base:-}"
  if [ -z "$_CL_BASE_REF" ]; then
    _CL_BASE_REF=$(_claims_jq config-base -r 'if (.base | type) == "string" then .base else "" end' \
      "$_SCRATCH/cl-config.json") || _claims_propagate $?
    [ -n "$_CL_BASE_REF" ] || _CL_BASE_REF="origin/main"
  fi
  _CL_MB=""
  if git rev-parse -q --verify "$_CL_BASE_REF^{commit}" >/dev/null 2>&1; then
    _CL_MB=$(git merge-base HEAD "$_CL_BASE_REF" 2>/dev/null) || _CL_MB=""
  fi
  if [ -z "$_CL_MB" ] && [ "$_CL_BASE_UNUSED" = 0 ]; then _claims_indeterminate V6 - base-unresolvable; fi
}

# _claims_emit <verb> [<extra-json>]: print the verdict object (merged with
# <extra-json>; its verb, enabled and exit are never overridden) and exit
# with the precedence code.
_claims_emit() {
  local extra="${2:-}" out rc
  [ -n "$extra" ] || extra='{}'
  out=$(_claims_jq emit -rn --arg verb "$1" --argjson extra "$extra" \
    --arg ref "$_CL_BASE_REF" --arg mb "$_CL_MB" --argjson all "$_CL_ALL_BLOCKING" \
    --slurpfile cfg "$_SCRATCH/cl-config.json" \
    --slurpfile f "$_SCRATCH/cl-findings.jsonl" \
    --slurpfile a "$_SCRATCH/cl-advisories.jsonl" \
    --slurpfile i "$_SCRATCH/cl-indet.jsonl" \
    --slurpfile r "$_SCRATCH/cl-results.jsonl" \
    "$_JQ_CLAIMS_EMIT") || _claims_propagate $?
  rc=${out%%$'\n'*}
  _claims_mark_emitted "$rc"
  _claims_out "${out#*$'\n'}"
  if [ "$rc" = 0 ]; then _exit_ok; fi
  exit "$rc"
}

# A verb that takes no positional argument.
_claims_no_args() {
  local verb="$1"
  shift
  [ $# -eq 0 ] || _usage_error "$verb" "takes no arguments (got '$1')"
}

# V1 (config): each top-level config key the defaults do not know.
_claims_v1_config() {
  _claims_jq v1-config -c '.[] | {check: "V1", claim: null, doc: "docs/spec-claims/config.json",
      message: "config: unknown key \(.)"}' "$_SCRATCH/cl-config-unknown.json" \
    >> "$_SCRATCH/cl-findings.jsonl"
}

# --- Spec claims: DOC-IDs, the claim loader, --staged scope, V1 ---------------
#
# Sidecars are docs/spec-claims/*.json minus config.json (never gates/), each
# {"schema": 1, "doc": "<repo path>", "claims": [<claim record>…]}. The
# loader writes, in $_SCRATCH:
#   cl-sidecars.jsonl / cl-sidecars-base.jsonl — one line per sidecar in the
#     proposed tree / at _CL_MB: {sidecar, data (null when the file is not one
#     JSON object), doc, doc_id, present, governing, unsafe}, present and
#     governing describing doc in that same tree; unsafe: doc is not a safe
#     repo path (_claims_safe_relpath: absolute, or an empty, "." or ".."
#     segment) or, read from the work tree, is reached through a symbolic
#     link (_claims_contained_path), and is then never read (present and
#     governing false); through a link in the index or HEAD it is absent;
#   cl-claims.json / cl-claims-base.json — [{sidecar, doc, doc_id, eligible,
#     claim}], one per object in a well-formed claims array ([] at base when
#     _CL_MB is empty);
#   cl-sidecars.json — [{sidecar, doc, doc_id, eligible, all_retired, skip}]
#     for the proposed tree; skip is null, "malformed sidecar", "unsafe path",
#     "doc missing" or "not governing" (the first that applies).
# eligible: the doc is a safe repo path, present in the tree read and
# governing. V2–V5, render and V11 skip a claim that is not eligible (one V1
# finding already names the doc unless every claim is retired, a legal end
# state — never for an unsafe path, always a finding); V1 and V6 run on all.
# doc_id: the doc's DOC-ID (_claims_doc_id) — for a fully retired sidecar
# whose doc has none (a host-glob doc moved out of its glob), the doc's file
# stem; else null.
# _claims_touched then writes cl-staged.json (the staged paths; [] unless
# --staged) and cl-touched.json (the claim ids V1–V6 check).

_CL_GOV_READY=0   # 1: _CL_GOV_GLOBS / _CL_GOV_EXTRA hold the config's globs
_CL_GOV_GLOBS=""  # config governing (governing_extra included), one per line
_CL_GOV_EXTRA=""  # config governing_extra, one per line
_CL_DOCID=""      # _claims_doc_id_set's result
_CL_SCOPE_ALL=1   # 0: the --staged scope applies (set by _claims_touched)

# Read the governing globs once, in the main shell (so the $(…) of a later
# _claims_doc_id finds them set).
_claims_gov_init() {
  [ "$_CL_GOV_READY" = 0 ] || return 0
  _CL_GOV_GLOBS=$(_claims_jq governing -r '.governing[] | strings' "$_SCRATCH/cl-config.json") \
    || _claims_propagate $?
  _CL_GOV_EXTRA=$(_claims_jq governing-extra -r '(.governing_extra // [])[] | strings' "$_SCRATCH/cl-config.json") \
    || _claims_propagate $?
  _CL_GOV_READY=1
}

# _claims_glob_any <path> <globs, one per line>: 0 when one matches.
_claims_glob_any() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if _claims_glob_match "$1" "$g"; then return 0; fi
  done <<EOF
$2
EOF
  return 1
}

# _claims_doc_id_set <path>: _CL_DOCID = the path's DOC-ID, or "". The
# basename's ADR-NNN or SPEC-CAT-NNN prefix wherever the file lives (an
# archived spec keeps its id); else, under a governing_extra glob, the file
# stem; else none (template.md under docs/specs/ has no DOC-ID).
_claims_doc_id_set() {
  local base="${1##*/}" re_adr='^(ADR-[0-9]+)' re_spec='^(SPEC-[ABCDEFGHIJKLMNOPQRSTUVWXYZ]+-[0-9]+)'
  _CL_DOCID=""
  if [[ $base =~ $re_adr ]] || [[ $base =~ $re_spec ]]; then
    _CL_DOCID="${BASH_REMATCH[1]}"
    return 0
  fi
  _claims_gov_init
  if [ -n "$base" ] && _claims_glob_any "$1" "$_CL_GOV_EXTRA"; then
    _CL_DOCID="${base%.*}"
  fi
}

# _claims_doc_id <path>: print the path's DOC-ID, or nothing.
_claims_doc_id() {
  _claims_doc_id_set "$1"
  if [ -n "$_CL_DOCID" ]; then printf '%s\n' "$_CL_DOCID"; fi
}

# _claims_is_governing <path>: 0 when the path matches a governing glob
# (governing_extra included) and has a DOC-ID.
_claims_is_governing() {
  _claims_gov_init
  _claims_doc_id_set "$1"
  [ -n "$_CL_DOCID" ] || return 1
  _claims_glob_any "$1" "$_CL_GOV_GLOBS"
}

# _claims_load_tree <rev|-> <out.jsonl>: one cl-sidecars line per sidecar of
# the mode's proposed tree (-) or of commit <rev>. A sidecar that is not one
# JSON object is a line with data null (V1 reports it), never a failure.
_claims_load_tree() {
  local rev="$1" out="$2" listing="$_SCRATCH/cl-list" blob="$_SCRATCH/cl-sidecar.raw"
  local p prev="" line doc present governing unsafe
  case "$rev" in
    -)
      case "$_CL_MODE" in
        staged) git ls-files -z --cached -- 'docs/spec-claims/*.json' > "$listing" \
                  || _claims_die "git ls-files failed listing the staged sidecars" ;;
        head) git ls-tree -r -z --name-only HEAD -- docs/spec-claims/ > "$listing" \
                || _claims_die "git ls-tree failed listing HEAD's sidecars" ;;
        *)
          : > "$listing"
          for p in docs/spec-claims/*.json; do
            if [ -f "$p" ]; then printf '%s\0' "$p" >> "$listing"; fi
          done
          ;;
      esac
      ;;
    *) git ls-tree -r -z --name-only "$rev" -- docs/spec-claims/ > "$listing" \
         || _claims_die "git ls-tree failed listing the sidecars at $rev" ;;
  esac
  : > "$out"
  while IFS= read -r -d '' p <&3; do
    case "$p" in
      docs/spec-claims/config.json|docs/spec-claims/*/*) continue ;;
      docs/spec-claims/*.json) ;;
      *) continue ;;
    esac
    # ls-files lists an unmerged path once per stage.
    [ "$p" != "$prev" ] || continue
    prev=$p
    if [ "$rev" = - ]; then
      _claims_read "$p" > "$blob" || continue
    else
      _claims_read_at "$rev" "$p" > "$blob" || continue
    fi
    # Its status is the answer (not one JSON object), so not _claims_jq; and
    # so is empty output: jq 1.6 -s prints nothing and exits 0 on input it
    # cannot parse.
    if ! line=$(jq -c -s --arg p "$p" \
        'if length == 1 and (.[0] | type) == "object" then {sidecar: $p, data: .[0]} else error("malformed") end' \
        "$blob" 2>/dev/null) || [ -z "$line" ]; then
      line=$(_claims_jq sidecar-malformed -nc --arg p "$p" '{sidecar: $p, data: null}') || _claims_propagate $?
    fi
    doc=$(_claims_jq sidecar-doc -r '.data.doc? | if type == "string" then . else "" end' <<<"$line") \
      || _claims_propagate $?
    present=false
    governing=false
    unsafe=false
    _CL_DOCID=""
    if [ -n "$doc" ] && ! _claims_safe_relpath "$doc"; then
      # Never read, never governing: _claims_read in mode all would follow
      # it out of the work tree, and a glob's * matches "/" and "..".
      unsafe=true
    elif [ -n "$doc" ] && [ "$rev" = - ] && [ "$_CL_MODE" = all ] && ! _claims_contained_path "$doc"; then
      # A work-tree path through a symbolic link: the same.
      unsafe=true
    elif [ -n "$doc" ]; then
      if [ "$rev" = - ]; then
        if _claims_read "$doc" >/dev/null; then present=true; fi
      elif _claims_read_at "$rev" "$doc" >/dev/null; then
        present=true
      fi
      if _claims_is_governing "$doc"; then governing=true; fi
      _claims_doc_id_set "$doc"
    fi
    _claims_jq sidecar-line -c --arg doc "$doc" --arg docid "$_CL_DOCID" \
      --argjson present "$present" --argjson governing "$governing" --argjson unsafe "$unsafe" \
      '. + {doc: (if $doc == "" then null else $doc end), doc_id: (if $docid == "" then null else $docid end),
            present: $present, governing: $governing, unsafe: $unsafe}' <<<"$line" >> "$out"
  done 3< "$listing"
}

# The one definition of a sidecar's facts, on a cl-sidecars line: the
# prelude of both _JQ_CLAIMS_LOAD and _JQ_CLAIMS_V1, so the loader (whose
# eligible V2–V5 read) and V1 can never disagree about a sidecar.
#   cl_well_formed  data is an object whose claims is an array
#   cl_all_retired  well formed, at least one claim, every claim retired
#   cl_eligible     the doc is a safe repo path (_claims_safe_relpath),
#                   present and governing in the tree read
#   cl_doc_id       the doc's DOC-ID; for a fully retired sidecar whose doc
#                   has none, the doc's file stem; else (an unsafe path
#                   included) null
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_SIDECAR='def cl_stem: split("/") | last | sub("\\.[^.]*$"; "");
 def cl_well_formed: (.data | type) == "object" and (.data.claims | type) == "array";
 def cl_all_retired: cl_well_formed and (.data.claims | length) > 0
   and all(.data.claims[]; type == "object" and .status == "retired");
 def cl_eligible: (.unsafe | not) and .present and .governing;
 def cl_doc_id: if .unsafe then null elif .doc_id != null then .doc_id
   elif cl_all_retired and .doc != null then .doc | cl_stem
   else null end;'

# cl-sidecars lines (slurped) → the cl-claims entries ($what == "claims") or
# the cl-sidecars.json summary ($what == "sidecars"). Run after
# _JQ_CLAIMS_SIDECAR.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_LOAD='if $what == "claims" then
   [.[] | select(cl_well_formed) | . as $s
    | .data.claims[] | select(type == "object")
    | {sidecar: $s.sidecar, doc: $s.doc, doc_id: ($s | cl_doc_id), eligible: ($s | cl_eligible), claim: .}]
 else
   [.[] | {sidecar, doc, doc_id: cl_doc_id, eligible: cl_eligible, all_retired: cl_all_retired,
           skip: (if (cl_well_formed | not) then "malformed sidecar" elif .unsafe then "unsafe path"
                  elif cl_eligible then null
                  elif .present | not then "doc missing" else "not governing" end)}]
 end'

# _claims_load: the proposed and base claim lists (see the section comment).
_claims_load() {
  _claims_gov_init
  _claims_load_tree - "$_SCRATCH/cl-sidecars.jsonl"
  _claims_jq load-claims -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$_SCRATCH/cl-sidecars.jsonl" \
    > "$_SCRATCH/cl-claims.json"
  _claims_jq load-sidecars -s --arg what sidecars "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$_SCRATCH/cl-sidecars.jsonl" \
    > "$_SCRATCH/cl-sidecars.json"
  if [ -n "$_CL_MB" ]; then
    _claims_load_tree "$_CL_MB" "$_SCRATCH/cl-sidecars-base.jsonl"
  else
    : > "$_SCRATCH/cl-sidecars-base.jsonl"
  fi
  _claims_jq load-claims-base -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$_SCRATCH/cl-sidecars-base.jsonl" \
    > "$_SCRATCH/cl-claims-base.json"
}

# A claim (proposed or base) is touched when a staged path is its sidecar,
# its doc, or is covered by a subject, its test file (test.file, else the
# node's path before "::"), its nonvacuity.mutant.file or a lint path
# ("covered": equal, or under it as a directory). Output: the sorted, unique
# ids.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_TOUCHED='def strs: if type == "array" then .[] | strings else empty end;
 def covered_by($st): . as $p | ($p | rtrimstr("/")) as $d
   | any($st[]; . == $p or startswith($d + "/"));
 ($st[0]) as $st
 | [($p[0] + $b[0])[]
    | select((.claim.id | type) == "string")
    | select($all == 1
        or (.sidecar | covered_by($st))
        or (.doc != null and (.doc | covered_by($st)))
        or any((.claim.subject | strs),
               (.claim.test | if type == "object" then
                  (if (.file | type) == "string" then .file
                   elif (.node | type) == "string" then .node | split("::")[0] else empty end)
                else empty end),
               (.claim.nonvacuity | if type == "object" then .mutant | objects | .file | strings else empty end),
               (.claim.lint | if type == "object" then .paths | strs else empty end);
             covered_by($st)))
    | .claim.id]
 | unique'

# _claims_empty_tree: the empty tree's id in this repository's object
# format (what --staged diffs the index against before the first commit): a
# SHA-256 repository has no 4b825dc… object.
_claims_empty_tree() {
  git hash-object -t tree /dev/null 2>/dev/null || _claims_die "git hash-object failed (the empty tree)"
}

# _claims_touched: cl-staged.json and cl-touched.json (see the section
# comment), and _CL_SCOPE_ALL. Under --staged the staged paths are the
# index's changes against HEAD (both sides of a rename). Every claim is
# touched (_CL_SCOPE_ALL=1) outside --staged, and under --staged when
# docs/spec-claims/config.json is staged: the config (kinds, globs, policy)
# can invalidate any claim without touching its own paths.
_claims_touched() {
  local base
  _CL_SCOPE_ALL=1
  if [ "$_CL_MODE" = staged ]; then
    _CL_SCOPE_ALL=0
    base=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || base=$(_claims_empty_tree) \
      || _claims_propagate $?
    git diff --cached --name-only --no-renames -z "$base" -- > "$_SCRATCH/cl-staged.z" \
      || _claims_die "git diff --cached failed listing the staged paths"
    _claims_jq staged-paths -Rs 'split("\u0000") | map(select(. != ""))' "$_SCRATCH/cl-staged.z" \
      > "$_SCRATCH/cl-staged.json"
    # Its status is the answer, so jq inside an if (not _claims_jq).
    if jq -e 'any(.[]; . == "docs/spec-claims/config.json")' "$_SCRATCH/cl-staged.json" >/dev/null 2>&1; then
      _CL_SCOPE_ALL=1
    fi
  else
    printf '[]\n' > "$_SCRATCH/cl-staged.json"
  fi
  _claims_jq touched -n --argjson all "$_CL_SCOPE_ALL" --slurpfile st "$_SCRATCH/cl-staged.json" \
    --slurpfile p "$_SCRATCH/cl-claims.json" --slurpfile b "$_SCRATCH/cl-claims-base.json" \
    "$_JQ_CLAIMS_TOUCHED" > "$_SCRATCH/cl-touched.json"
}

# claims_v1($docid; $kinds; $known; $b1; $rec): on one claim record, a
# message per V1 violation. $docid null skips the id-prefix check (the doc is
# the problem, and one sidecar finding already says so). $known: the ids of
# every claim in the proposed sidecars, which restates may name (V7's sweep
# reads them); null when a sidecar is malformed, which skips the unknown-id
# check (the id may be in that sidecar, and its own finding already blocks).
# $b1: the configuration extension is on (§B.1). Off, a when (not null) or
# status gated is a finding ("configuration extension is off"); on, gated is
# a status (and runs, as built does), when must be an object whose every key
# is a key of $rec (the recorded configuration, cl-recorded.json; null when
# the adapter failed, which skips that check: the run is indeterminate), a
# gated claim needs a non-empty when, and config_independent is a non-empty
# string or null. Every number inside an object when, as tojson prints it,
# is canonical (cl_canonical_num: an integer, or a decimal with no trailing
# zero, no exponent, at most 15 significant digits): jq 1.7+ keeps a
# number's literal (1.0, 1E+3) and upstream jq 1.6 does not, so only a
# canonical number gives promotion.proved.when one digest on both. A built
# or gated claim's promotion (an object) carries proved, exactly the six
# keys of cl_proved_keys (_JQ_CLAIMS_PROVED: run before it), each a 64-hex
# sha256 but enforced_by (a value): promote writes it, and V6, gate and
# attest compare with it. Fields outside §B's record are not checked.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_SCHEMA='def claims_v1($docid; $kinds; $known; $b1; $rec):
  def nes: type == "string" and length > 0;
  def cl_canonical_num: test("^-?(0|[1-9][0-9]*)(\\.[0-9]*[1-9])?$")
    and (ltrimstr("-") | split(".") | join("") | sub("^0+"; "") | length) <= 15;
  def paths_ok: type == "array" and all(.[]; nes);
  def among($xs): . as $v | any($xs[]; . == $v);
  def req($k; ok; $what):
    if has($k) | not then "missing required field \($k)"
    elif .[$k] | ok then empty
    else "\($k) \(.[$k] | tojson) \($what)" end;
  def opt($k; ok; $what):
    if .[$k] == null then empty
    elif .[$k] | ok then empty
    else "\($k) \(.[$k] | tojson) \($what)" end;
  "configuration extension is off (config config_adapter is null; §B.1)" as $b1_off
  | (["behaviour", "interface", "config"] + $kinds) as $kind_enum
  | (["built", "diverged", "unbuilt", "retired"] + (if $b1 then ["gated"] else [] end)) as $status_enum
  | ["test", "lint", "log", "judge"] as $tier_enum
  | ["CODE-DIVERGES", "DOC-STALE", "RETIRE"] as $dir_enum
  | if type != "object" then "the claim record is not a JSON object"
    else
      (.status == "built" or .status == "diverged" or ($b1 and .status == "gated")) as $runs
      | req("id"; nes; "must be a non-empty string"),
      (if $docid != null and (.id | nes)
          and ((.id | startswith($docid + "#") | not)
               or (.id | ltrimstr($docid + "#") | test("^[a-z0-9][a-z0-9-]*$") | not))
       then "id \(.id) is not \($docid)#<slug> (slug: [a-z0-9][a-z0-9-]*)" else empty end),
      req("quote"; nes; "must be a non-empty string"),
      req("states"; nes; "must be a non-empty string"),
      req("kind"; among($kind_enum); "is not one of \($kind_enum | join(", "))"),
      req("subject"; paths_ok; "must be an array of repo paths"),
      (if .status == "gated" and ($b1 | not)
       then "status gated: \($b1_off): a gated claim is conditioned on recorded configuration"
       else req("status"; among($status_enum); "is not one of \($status_enum | join(", "))") end),
      req("enforced_by"; among($tier_enum); "is not one of \($tier_enum | join(", "))"),
      (if .when == null then empty
       elif $b1 | not then "when \(.when | tojson): \($b1_off)"
       elif (.when | type) != "object" then "when \(.when | tojson) must be an object {KEY: VALUE} or null"
       elif $rec == null then empty
       else .when | keys_unsorted[] | select(. as $k | $rec | has($k) | not)
         | "when key \(.) is not a key of the recorded configuration (the config adapter'"'"'s recorded does not report it)"
       end),
      (if (.when | type) == "object" then
         [.when | .. | numbers | tojson | select(cl_canonical_num | not)]
         | if length == 0 then empty
           else "when holds \(join(", ")): write the number canonically (e.g. 1.5, not 1.50 / 1.0 / 1e3), at most 15 significant digits (promotion.proved digests when'"'"'s jq -cS bytes, which jq 1.6 and jq 1.7+ print alike only for a canonical number)" end
       else empty end),
      (if $b1 and .status == "gated" and ((.when | type) != "object" or (.when | length) == 0)
       then "status gated needs when: the condition, not yet set by the recorded configuration, under which the claim holds"
       else empty end),
      (if $b1 then opt("config_independent"; nes; "must be a non-empty string (why the claim holds whatever the configuration) or null")
       else empty end),
      (if .test == null then
         (if .enforced_by == "test" and $runs
          then "test is null: a \(.status) claim enforced by test needs test {runner, node[, file]} (null only while unbuilt)"
          else empty end)
       elif (.test | type) != "object" then "test \(.test | tojson) must be {runner, node[, file]} or null"
       else .test
         | (if .runner | nes then empty else "test.runner must be a non-empty string" end),
           (if .node | nes then empty else "test.node must be a non-empty string" end),
           (if has("file") and (.file | nes | not) then "test.file must be a non-empty string" else empty end)
       end),
      (if .lint == null then
         (if .enforced_by == "lint" and $runs
          then "lint is null: a \(.status) claim enforced by lint needs lint {pattern, paths, expect, selftest}"
          else empty end)
       elif (.lint | type) != "object" then "lint \(.lint | tojson) must be {pattern, paths, expect, selftest} or null"
       else .lint
         | (if .pattern | nes then empty else "lint.pattern must be a non-empty string" end),
           (if (.paths | paths_ok) and (.paths | length) > 0 then empty
            else "lint.paths must be a non-empty array of repo paths" end),
           (if .expect == "present" or .expect == "absent" then empty
            else "lint.expect must be present or absent" end),
           (if (.selftest | type) == "object" and (.selftest.violates | type) == "string"
               and (.selftest.clean | type) == "string" then empty
            else "lint.selftest must be {violates, clean}, two strings" end)
       end),
      (if .rulings == null then empty
       elif (.rulings | type) != "array" then "rulings \(.rulings | tojson) must be an array"
       else .rulings | range(length) as $i | .[$i]
         | if type != "object" then "rulings[\($i)] is not a JSON object"
           else
             (if (.date | type) == "string" and (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then empty
              else "rulings[\($i)]: date \(.date | tojson) must be YYYY-MM-DD" end),
             (if .direction | among($dir_enum) then empty
              else "rulings[\($i)]: direction \(.direction | tojson) is not one of \($dir_enum | join(", "))" end),
             (if .by | nes then empty else "rulings[\($i)]: by must name who ruled" end),
             (if .record | nes then empty else "rulings[\($i)]: record must name the record of the ruling (a repo path)" end),
             (if (.direction == "DOC-STALE" or .direction == "RETIRE") and (.reason | nes | not)
              then "rulings[\($i)] (\(.direction)): reason is required (the ruling records why)"
              elif .reason != null and (.reason | type) != "string" then "rulings[\($i)]: reason must be a string"
              else empty end)
           end
       end),
      opt("tracker"; nes; "must be a non-empty string or null"),
      opt("frozen_at"; nes; "must be a commit or null"),
      opt("restates"; paths_ok; "must be an array of claim ids"),
      (if (.restates | type) == "array" then
         (. as $c | [.restates[] | select(type == "string" and length > 0)] | unique | .[]
          | . as $r
          | if $r == $c.id then "restates \($r), the claim itself: a claim cannot restate itself"
            elif $known == null or any($known[]; . == $r) then empty
            else "restates \($r): no claim has that id (restates names the claims this one restates)" end)
       else empty end),
      opt("quote_occurrence"; type == "number" and . >= 1 and . == floor; "must be an integer >= 1"),
      opt("nonvacuity"; type == "object"; "must be an object or null"),
      opt("promotion"; type == "object"; "must be an object or null"),
      (if (.status == "built" or .status == "gated") and (.promotion | type) == "object" then
         .promotion.proved as $pv
         | if ($pv | type) == "object" and ($pv | keys) == (cl_proved_keys | sort)
              and all($pv | .states, .test, .subject, .nonvacuity, .when; type == "string" and test("^[0-9a-f]{64}$"))
           then empty
           else "promotion.proved \($pv | tojson) must be {states, test, subject, enforced_by, nonvacuity, when}: each the 64-hex sha256 of that field, enforced_by its value (claims promote writes it: run claims promote)" end
       else empty end),
      opt("why_not_mechanical"; nes; "must be a non-empty string")
    end;'

# V1 over the proposed sidecars (cl-sidecars.jsonl, slurped as $s; run after
# _JQ_CLAIMS_SIDECAR and _JQ_CLAIMS_SCHEMA): the envelope, the doc (present
# and governing, unless every claim is retired), the stem, each record
# (claims_v1) and id uniqueness. With $all 0 (_CL_SCOPE_ALL: --staged, and
# config.json not staged) a claim is in scope when touched or its sidecar or
# doc is staged, and for its restates messages alone when a claim it restates
# is touched (deleting that claim's sidecar leaves the id dangling); a sidecar when it or its doc is staged or it holds a touched
# claim. One finding row per line.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V1='def in_list($l): . as $x | any($l[]; . == $x);
 def v1($claim; $doc; $msg): {check: "V1", claim: $claim, doc: $doc, message: $msg};
 (if ($cfg[0].kinds | type) == "array" then [$cfg[0].kinds[] | strings] else [] end) as $kinds
 | $t[0] as $touched | $st[0] as $staged
 | ($s | map(select(cl_well_formed))) as $wf
 | (if ($wf | length) == ($s | length) then [$wf[] | .data.claims[] | select(type == "object") | .id | strings]
    else null end) as $known
 | (
   ($s[]
    | .sidecar as $p | .data as $d | (.doc // $p) as $fdoc
    | cl_well_formed as $well | cl_all_retired as $retired | cl_eligible as $eligible | cl_doc_id as $docid
    | ($all == 1 or ($p | in_list($staged)) or (.doc != null and (.doc | in_list($staged)))) as $direct
    | ($direct or ($well and any($d.claims[]; type == "object" and (.id | type) == "string"
                                              and (.id | in_list($touched))))) as $in_scope
    | "\($p): doc \(.doc)" as $at
    | ("if the doc was archived or moved, retire each live claim (status retired with a RETIRE ruling)"
       + " and re-key its index entry (doc-tools.sh move-entry <old> <new>), or point doc at its"
       + " governing path; a sidecar whose claims are all retired may name an archived, moved or deleted doc") as $advice
    | (select($in_scope)
       | if ($d | type) != "object" then v1(null; $p; "\($p): not one JSON object (want {\"schema\": 1, \"doc\", \"claims\"})")
         else
           (if $d.schema != 1 then v1(null; $fdoc; "\($p): schema \($d.schema | tojson) must be 1") else empty end),
           (if ($d.claims | type) != "array" then v1(null; $fdoc; "\($p): claims must be an array") else empty end),
           (if .doc == null then v1(null; $p; "\($p): doc must be the repo path of the governing doc")
            elif .unsafe then v1(null; $p; "\($p): doc \(.doc) is not a safe repo path (absolute, an empty, . or .. segment, or reached through a symbolic link): name the doc by its real path from the repo root, as git ls-files prints it")
            elif $retired or $eligible then
              (if ($p | cl_stem) != $docid
               then v1(null; .doc; "\($p): sidecar stem \($p | cl_stem) is not \($docid), the DOC-ID of \(.doc): rename it docs/spec-claims/\($docid).json")
               else empty end)
            elif .present | not then v1(null; .doc; "\($at) is missing: \($advice)")
            else v1(null; .doc; "\($at) is not governing (no governing glob matches it, or it has no DOC-ID): \($advice)")
            end)
         end),
      (select($well)
       | (if $retired or $eligible then $docid else null end) as $idbase
       | $d.claims | range(length) as $i | .[$i]
       | ($direct or (type == "object" and (.id | type) == "string" and (.id | in_list($touched)))) as $full
       | select($full or (type == "object" and (.restates | type) == "array"
                          and any(.restates[]; type == "string" and in_list($touched))))
       | (if type == "object" and (.id | type) == "string" then .id else null end) as $cid
       | claims_v1($idbase; $kinds; $known; $b1; $rec[0])
       | select($full or startswith("restates "))
       | v1($cid; $fdoc; "\($p): \($cid // "claims[\($i)]"): \(.)"))),
   ([$wf[] | .sidecar as $p | (.doc // $p) as $doc
     | .data.claims[] | select(type == "object" and (.id | type) == "string") | {id, sidecar: $p, doc: $doc}]
    | group_by(.id)[] | select(length > 1)
    | select($all == 1 or (.[0].id | in_list($touched)))
    | v1(.[0].id; .[0].doc;
         "duplicate id \(.[0].id): \(length) records (in \(map(.sidecar) | unique | join(", "))); ids are unique across all sidecars"))
 ) | tojson'

# V1 on the claims: one finding row per violation (_JQ_CLAIMS_V1). With the
# configuration extension on, the when keys are checked against
# cl-recorded.json (validate's one recorded call).
_claims_v1() {
  local b1=false
  if _claims_b1_on; then b1=true; fi
  _claims_jq v1 -nr --argjson all "$_CL_SCOPE_ALL" --argjson b1 "$b1" \
    --slurpfile rec "$_SCRATCH/cl-recorded.json" \
    --slurpfile s "$_SCRATCH/cl-sidecars.jsonl" --slurpfile t "$_SCRATCH/cl-touched.json" \
    --slurpfile st "$_SCRATCH/cl-staged.json" --slurpfile cfg "$_SCRATCH/cl-config.json" \
    "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_PROVED $_JQ_CLAIMS_SCHEMA $_JQ_CLAIMS_V1" >> "$_SCRATCH/cl-findings.jsonl"
}

# --- Spec claims: quote normalisation, V2 --------------------------------------
#
# A quote anchors in the doc's live text, normalised (§B): line wraps and
# whitespace collapsed, *, _ and ` emphasis and leading blockquote markers
# stripped. Struck text (~~…~~) and the generated status block are not live;
# a dated AMENDED block is. Everything runs in one jq -Rs call per doc (no
# shell loop over lines), and every offset is a codepoint offset: strings
# are located with split($q) and length, never index/indices (jq 1.6 returns
# byte offsets there), and no gsub pattern can match the empty string (jq
# 1.6 loops on one).

# The shared jq defs (render, V2, V8 and V8n run after them):
#   claims_fence_kinds  LF text → one {t, k} per line, k "out", "delim" (a
#                     fence's opening or closing line) or "in" (inside a
#                     fence). CommonMark fence pairing: an opener is
#                     ^[ \t]* then a run of 3 or more of one character, ` or
#                     ~ (a ` run's info string may not hold a `); the run's
#                     character and length are kept. Only a line whose run
#                     is the same character, at least as long, followed by
#                     nothing but [ \t], closes it; every other line until
#                     then — an inner fence with a shorter or other run
#                     included — is "in". An unclosed fence runs to the end.
#                     V8's section classes (_claims_sections) read it too,
#                     in a jq pass before their awk one.
#   claims_is_marker($m)  the line is the marker $m alone: up to 3 leading
#                     spaces (CommonMark HTML-block indentation) and trailing
#                     spaces, tabs or \r allowed, nothing else; a marker
#                     quoted in prose or backticks is text.
#   claims_status_ranges  LF text → the status blocks, each [first, last]
#                     (0-based line indices): a begin-marker line through the
#                     first end-marker line after it, by claims_is_marker.
#   claims_status_blank  LF text → the same lines, each status block's lines
#                     (claims_status_ranges) blanked to "". render
#                     (_JQ_CLAIMS_RENDER) locates the block by the same rule,
#                     and V8's section classes (_claims_sections) skip it.
#   claims_live       raw doc → the same number of lines, CRLF read as LF and
#                     each dead span (status block, ~~strike~~) blanked to its
#                     newlines. Code fences are masked first, so a fence is
#                     never read as a strike: a delimiter line becomes "", and
#                     each "~" of an "in" line the sentinel U+FFFF — written
#                     here only as the jq escape \uffff, never as raw bytes —
#                     restored once strikes are gone.
#   claims_norm       string → its normalised form (a doc or a quote).
#   claims_doc        raw doc → {text: <normalised>, lines: [{n, start, end,
#                     amended}]}: n the 1-based line, [start, end) its
#                     codepoint span in text, for each line whose normalised
#                     form is non-empty (lines join with one space). amended:
#                     the line is in a blockquote (an "out" line matching
#                     ^[ \t]*>; a blank line ends one) whose first line
#                     matches ^[ \t]*>.*\*\*AMENDED YYYY-MM-DD. Membership and
#                     the header are read from the CRLF-folded source lines
#                     (fence-aware, before strikes are blanked), so a strike
#                     across a line break cannot end the block; the spans
#                     come from the claims_live lines (same indices).
#   claims_occ($q)    on claims_doc: the non-overlapping start offsets of $q
#                     (a normalised quote) in .text.
#   claims_lines_hit($q; $k)  on claims_doc: the n of each line the $k-th
#                     occurrence (1-based, as quote_occurrence) intersects;
#                     [] when there is none.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_NORM='def claims_blank: gsub("[^\n]"; "");
 def claims_fence_kinds:
   reduce split("\n")[] as $l ({c: null, n: 0, out: []};
     (($l | capture("^[ \t]*(?<r>`{3,}|~{3,})(?<rest>.*)$")) // null) as $f
     | if .c == null then
         if $f != null and ($f.r[0:1] == "~" or ($f.rest | test("`") | not))
         then .c = $f.r[0:1] | .n = ($f.r | length) | .out += [{t: $l, k: "delim"}]
         else .out += [{t: $l, k: "out"}] end
       elif $f != null and $f.r[0:1] == .c and ($f.r | length) >= .n and ($f.rest | test("^[ \t]*$"))
       then .c = null | .n = 0 | .out += [{t: $l, k: "delim"}]
       else .out += [{t: $l, k: "in"}] end)
   | .out;
 def claims_mask_fences:
   claims_fence_kinds
   | map(if .k == "delim" then "" elif .k == "in" then .t | gsub("~"; "\uffff") else .t end)
   | join("\n");
 def claims_is_marker($m): test("^ {0,3}" + $m + "[ \t\r]*$");
 def claims_status_ranges:
   split("\n") as $ls
   | reduce range(0; $ls | length) as $i ({p: null, r: []};
       $ls[$i] as $t
       | if .p == null then (if $t | claims_is_marker("<!-- spec-claims:status:begin -->") then .p = $i else . end)
         elif $t | claims_is_marker("<!-- spec-claims:status:end -->") then .r += [[.p, $i]] | .p = null
         else . end)
   | .r;
 def claims_status_blank:
   split("\n") as $ls
   | claims_status_ranges as $r
   | [range(0; $ls | length) as $i | if any($r[]; .[0] <= $i and $i <= .[1]) then "" else $ls[$i] end]
   | join("\n");
 def claims_live: gsub("\r\n"; "\n") | claims_mask_fences
   | claims_status_blank
   | gsub("(?<s>~~[\\s\\S]*?~~)"; .s | claims_blank)
   | gsub("\uffff"; "~");
 def claims_norm_line: sub("^[ \t]*(>[ \t]?)+"; "") | gsub("[*_`]"; "") | gsub("[ \t]+"; " ")
   | sub("^ "; "") | sub(" $"; "");
 def claims_norm: claims_live | split("\n") | map(claims_norm_line) | map(select(. != "")) | join(" ");
 def claims_doc:
   (claims_live | split("\n")) as $ls
   | (gsub("\r\n"; "\n") | claims_fence_kinds) as $src
   | reduce range(0; $ls | length) as $i ({parts: [], lines: [], off: 0, bq: false, amd: false};
       ($ls[$i] | claims_norm_line) as $nl
       | $src[$i] as $s
       | ($s.k == "out" and ($s.t | test("^[ \t]*>"))) as $bq
       | (if $bq and (.bq | not)
          then .amd = ($s.t | test("^[ \t]*>.*\\*\\*AMENDED [0-9]{4}-[0-9]{2}-[0-9]{2}")) else . end)
       | .bq = $bq
       | if $nl == "" then .
         else .parts += [$nl]
           | .lines += [{n: ($i + 1), start: .off, end: (.off + ($nl | length)), amended: ($bq and .amd)}]
           | .off += ($nl | length) + 1
         end)
   | {text: (.parts | join(" ")), lines};
 def claims_occ($q):
   if $q == "" then []
   else (.text | split($q)) as $p | ($q | length) as $ql
     | reduce range(1; $p | length) as $k ([];
         . + [(if $k == 1 then 0 else .[-1] + $ql end) + ($p[$k - 1] | length)])
   end;
 def claims_lines_hit($q; $k):
   (if $k >= 1 then claims_occ($q)[$k - 1] else null end) as $p
   | if $p == null then []
     else ($p + ($q | length)) as $e | [.lines[] | select(.start < $e and .end > $p) | .n] end;'

# V2 over one doc (raw on stdin, path $doc; run after _JQ_CLAIMS_NORM): each
# eligible, touched claim of the doc ($c: cl-claims.json, $t:
# cl-touched.json) whose quote is not anchored. With n live occurrences of
# the normalised quote: retired needs n == 0; quote_occurrence k needs
# n >= k; otherwise n == 1. When n > 1 without quote_occurrence and an
# occurrence lies in an AMENDED block, the message says so: a DOC-STALE
# ruling that re-quotes the sentence must set quote_occurrence too. One
# finding row per line.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V2='def v2($claim; $msg): {check: "V2", claim: $claim, doc: $doc, message: $msg};
 claims_doc as $d
 | [$d.lines[] | select(.amended) | .n] as $amended
 | $t[0] as $touched
 | $c[0][]
 | select(.eligible and .doc == $doc) | .claim
 | select((.id | type) == "string" and (.quote | type) == "string")
 | select(.id as $i | any($touched[]; . == $i))
 | .id as $id | .quote_occurrence as $k
 | (.quote | claims_norm) as $q
 | ($d | claims_occ($q) | length) as $n
 | "quote not found in the live text of \($doc) (struck text and the status block are not live)" as $missing
 | (if $q == "" then "quote is empty once normalised (whitespace and *, _, ` emphasis removed)"
    elif .status == "retired" then
      (if $n == 0 then empty
       else "retired claim: its quote is still live (\($n) live occurrence(s) in \($doc)): strike the sentence (~~text~~) or remove it" end)
    elif ($k | type) == "number" then
      (if $n >= $k then empty
       elif $n == 0 then $missing
       else "quote_occurrence \($k), but the quote has \($n) live occurrence(s) in \($doc)" end)
    elif $k != null then empty
    elif $n == 1 then empty
    elif $n == 0 then $missing
    elif any(range(1; $n + 1); . as $j | $d | claims_lines_hit($q; $j) | any(.[]; . as $x | any($amended[]; . == $x)))
    then "AMENDED block re-quotes a claimed sentence: set quote_occurrence to the live occurrence (a ruling alone does not anchor it)"
    else "quote has \($n) live occurrences in \($doc): make it unique, or set quote_occurrence to the one it anchors"
    end)
 | v2($id; .) | tojson'

# V2: one jq -Rs per doc that has an eligible, touched claim, the doc read
# through _claims_read (the index under --staged). A quote_occurrence that is
# not an integer >= 1 is V1's finding, not V2's.
_claims_v2() {
  local doc_list="$_SCRATCH/cl-v2-docs" doc_raw="$_SCRATCH/cl-v2-doc.raw" doc
  _claims_jq v2-docs -r --slurpfile t "$_SCRATCH/cl-touched.json" \
    '[.[] | select(.eligible and (.doc | type) == "string" and (.claim.id | type) == "string")
      | select(.claim.id as $i | any($t[0][]; . == $i)) | .doc] | unique | .[]' \
    "$_SCRATCH/cl-claims.json" > "$doc_list"
  while IFS= read -r doc <&3; do
    [ -n "$doc" ] || continue
    _claims_read "$doc" > "$doc_raw" || _claims_die "cannot read $doc (V2)"
    _claims_jq v2 -Rsr --arg doc "$doc" --slurpfile c "$_SCRATCH/cl-claims.json" \
      --slurpfile t "$_SCRATCH/cl-touched.json" "$_JQ_CLAIMS_NORM $_JQ_CLAIMS_V2" "$doc_raw" \
      >> "$_SCRATCH/cl-findings.jsonl"
  done 3< "$doc_list"
}

# --- Spec claims: trackers, V5 ---------------------------------------------------
#
# A tracker is open (Design deviations) when it matches one of config
# tracker_patterns — an ERE, tested with jq test(): an issue number or a URL,
# whose state lives in a service a hook cannot read offline, so it is assumed
# open — or when it is a repo path present in the proposed tree (read through
# _claims_read: the index under --staged) whose status value is not closed.
# The status value is the first status line's: front matter `status:` (in a
# leading ---…--- block), or a `**Status**:` / `**Status:**` line outside code
# fences; CRLF reads as LF, and a doc with no status line is open. Leading
# whitespace, *, ` and _ are stripped, and only the value's leading word (the
# first run of [A-Za-z]+) counts, matched whole and case-insensitively against
# the closed words: "Approved — not done" is open, "`Done` (2026-10-01)" closed.

_CL_TRACKER_STATE=""  # _claims_tracker_open's answer: pattern | open | closed | missing
_CL_TRACKER_VALUE=""  # the tracker doc's status value ("" without a status line)

# 0 when $t matches one of config tracker_patterns (on cl-config.json). A
# pattern jq cannot compile matches nothing.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_TRACKER_PATTERN='(if (.tracker_patterns | type) == "array" then [.tracker_patterns[] | strings] else [] end) as $ps
 | any($ps[]; . as $p | $t | try test($p) catch false)'

# A tracker doc (raw on stdin; run after _JQ_CLAIMS_NORM, for
# claims_fence_kinds) → "<open|closed><TAB><status value>".
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_TRACKER='gsub("\r\n"; "\n") as $raw
 | ($raw | split("\n")) as $ls
 | (if ($ls[0] // "") | test("^---[ \t]*$")
    then ([range(1; $ls | length) | select($ls[.] | test("^(---|\\.\\.\\.)[ \t]*$"))][0] // 0)
    else 0 end) as $fm
 | ($raw | claims_fence_kinds) as $k
 | ([range(0; $ls | length) as $i
     | if $i < $fm then
         select($i > 0) | $ls[$i] | capture("^status[ \t]*:(?<v>.*)$") | .v
       elif $i > $fm or $fm == 0 then
         select($k[$i].k == "out") | $ls[$i]
         | capture("^[ \t]*([-+*][ \t]+)?\\*\\*Status(\\*\\*:|:\\*\\*)(?<v>.*)$") | .v
       else empty end][0]) as $v
 | if $v == null then "open\t"
   else ($v | sub("^[ \t*`_]+"; "") | sub("[ \t]+$"; "")) as $val
     | ([$val | match("[A-Za-z]+")][0].string // "") as $word
     | (if $word | test("^(closed|resolved|done|fixed|completed|wontfix)$"; "i") then "closed" else "open" end)
       + "\t" + $val
   end'

# _claims_tracker_open <tracker>: 0 when the tracker is open (see the section
# comment). Sets _CL_TRACKER_STATE and _CL_TRACKER_VALUE, so call it in the
# main shell. A path is a repo path only when relative, with no ".", ".." or
# empty segment (the index could never hold one, and --all must agree).
_claims_tracker_open() {
  local t="$1" raw="$_SCRATCH/cl-tracker.raw" out
  _CL_TRACKER_STATE=missing
  _CL_TRACKER_VALUE=""
  [ -n "$t" ] || return 1
  out=$(_claims_jq tracker-patterns -r --arg t "$t" "$_JQ_CLAIMS_TRACKER_PATTERN" "$_SCRATCH/cl-config.json") \
    || _claims_propagate $?
  if [ "$out" = true ]; then
    _CL_TRACKER_STATE=pattern
    return 0
  fi
  _claims_safe_relpath "$t" || return 1
  _claims_read "$t" > "$raw" || return 1
  out=$(_claims_jq tracker-status -Rsr "$_JQ_CLAIMS_NORM $_JQ_CLAIMS_TRACKER" "$raw") || _claims_propagate $?
  _CL_TRACKER_STATE=${out%%$'\t'*}
  _CL_TRACKER_VALUE=${out#*$'\t'}
  [ "$_CL_TRACKER_STATE" = open ]
}

# V5 over the eligible, touched claims ($c: cl-claims.json, $t:
# cl-touched.json; $tr: one {tracker, state, value} row per tracker
# _claims_v5 resolved — a tracker without a row is missing): diverged,
# unbuilt and gated (§B.1: the configuration change it waits for) need an
# open tracker; diverged needs a CODE-DIVERGES ruling;
# retired a RETIRE or DOC-STALE ruling; enforced_by judge a
# why_not_mechanical. A field of the wrong type counts as absent here (V1
# names the type). One finding row per line.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V5='def v5($claim; $doc; $msg): {check: "V5", claim: $claim, doc: $doc, message: $msg};
 def nes: type == "string" and length > 0;
 def ruled($dirs): [.rulings | if type == "array" then .[] | objects | .direction else empty end] as $have
   | any($dirs[]; . as $d | any($have[]; . == $d));
 (reduce $tr[] as $r ({}; .[$r.tracker] = $r)) as $trackers
 | $t[0] as $touched
 | $c[0][]
 | select(.eligible) | .doc as $doc | .claim
 | select((.id | type) == "string")
 | select(.id as $i | any($touched[]; . == $i))
 | .id as $id
 | (if .status == "diverged" or .status == "unbuilt" or .status == "gated" then
      (if .tracker | nes | not
       then "\(.status) claim has no tracker: it needs an open one (a repo path, or a string matching config tracker_patterns)"
       else ($trackers[.tracker] // {state: "missing"}) as $s
         | if $s.state == "closed"
           then "tracker is closed: \(.tracker) has status: \($s.value); status \(.status) needs an open tracker"
           elif $s.state == "missing"
           then "tracker \(.tracker) is not a path in the proposed tree and matches no config tracker_patterns: status \(.status) needs an open tracker"
           else empty end
       end)
    else empty end),
   (if .status == "diverged" and (ruled(["CODE-DIVERGES"]) | not)
    then "diverged claim has no CODE-DIVERGES ruling" else empty end),
   (if .status == "retired" and (ruled(["RETIRE", "DOC-STALE"]) | not)
    then "retired claim has no RETIRE or DOC-STALE ruling (the ruling records why)" else empty end),
   (if .enforced_by == "judge" and (.why_not_mechanical | nes | not)
    then "enforced_by judge needs why_not_mechanical: why no test, lint or log check is feasible" else empty end)
 | v5($id; $doc; .) | tojson'

# V5: each distinct tracker of an eligible, touched diverged, unbuilt or gated claim
# resolved once (_claims_tracker_open), then one jq over the claims. A
# tracker holding a newline cannot be a repo path, and is left missing.
_claims_v5() {
  local list="$_SCRATCH/cl-v5-trackers" rows="$_SCRATCH/cl-v5-trackers.jsonl" t
  : > "$rows"
  _claims_jq v5-trackers -r --slurpfile t "$_SCRATCH/cl-touched.json" \
    '[.[] | select(.eligible and (.claim.id | type) == "string")
      | select(.claim.id as $i | any($t[0][]; . == $i)) | .claim
      | select(.status == "diverged" or .status == "unbuilt" or .status == "gated")
      | .tracker | strings | select(. != "" and (test("\n") | not))] | unique | .[]' \
    "$_SCRATCH/cl-claims.json" > "$list"
  while IFS= read -r t <&3; do
    _claims_tracker_open "$t" || true
    _claims_jq v5-tracker-row -nc --arg t "$t" --arg s "$_CL_TRACKER_STATE" --arg v "$_CL_TRACKER_VALUE" \
      '{tracker: $t, state: $s, value: $v}' >> "$rows"
  done 3< "$list"
  _claims_jq v5 -nr --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile t "$_SCRATCH/cl-touched.json" \
    --slurpfile tr "$rows" "$_JQ_CLAIMS_V5" >> "$_SCRATCH/cl-findings.jsonl"
}

# --- Spec claims: the verdict store, V6 ---------------------------------------
#
# promote (Task 11; --reverify too) stores each verdict, outside the tree, at
# <store>/<digest>.json: the jq -cS bytes of {claim, states_sha256, test,
# nonvacuity, proved, head, subject_oids, green, red, status_to}, <digest>
# their sha256, also written as the claim's promotion.verdict_sha256. Every
# digest, verdict file name and states_sha256 is a bare 64-hex sha256
# (_claims_sha256); states_sha256 hashes the states string's UTF-8 bytes with
# no trailing newline (jq -j .states). promote also writes the fingerprint of
# the record it proved, promotion.proved (_claims_proved), into the sidecar
# and into the verdict. A verdict is local: a fresh clone or a CI runner has
# none. So what a promotion proved is read from promotion.proved, never from
# the store and never from history (promotion.at is unreachable on trunk
# after a squash or rebase merge): the claim is compared with it field by
# field (_claims_proved_delta), with the verdict or without it. A missing
# verdict is the advisory unverifiable-here only when every field is as
# proved (the scheduled run re-verifies).
#
# V6 compares each claim with its record at _CL_MB (cl-claims-base.json),
# joined by id, on every claim — eligible or not — that is touched. A new
# ruling is a ruling object of the proposed record JSON-equal to none of its
# _CL_MB record's. Without a new DOC-STALE or RETIRE ruling (§F: only those
# change what the doc approved, and only those does the direction policy
# judge, so the latitude cannot be had by labelling a change CODE-DIVERGES):
# states changed, enforced_by lowered (test 4 > lint 3 > log 2 > judge 1),
# or a re-anchor that changed a token (old and new quote differ once
# normalised; a reflow or move does not) is a finding, naming the direction
# it was given. Without a new ruling of any direction, status moved off
# built is one (built → diverged under CODE-DIVERGES is the ordinary case).
# Whatever the rulings: a claim deleted is a finding ("retire it instead";
# the one legal deletion is a whole sidecar whose claims were all retired at
# _CL_MB; a claim whose sidecar is still there but no longer well formed is
# V1's finding, not a deletion), and moving a test claim into built/gated
# without a promotion is one (a promotion and nonvacuity are a test claim's,
# §B: a lint, log or judge claim enters built by a reviewed status edit, and
# run and gate run its check). Each built/gated claim that is new or differs
# from its _CL_MB record — a test claim, or any claim that carries a
# promotion — is compared with its promotion.proved
# (_claims_proved_delta: the fields that differ), and its verdict, when the
# store holds it, is checked to bind the claim (_claims_verdict_bound):
#   - the verdict there but not binding the claim (its file edited, or
#     another claim, status, proved, or — for a field still as proved —
#     another states, test, nonvacuity or subject) → a finding;
#   - no proved (V1's finding too) → a finding;
#   - a field that differs and is not licensed → a finding naming the
#     fields ("run claims promote <id>"; for a lint, log or judge claim, which
#     promote refuses, "remove its promotion"). A new DOC-STALE/RETIRE ruling on
#     the claim licenses a states difference and, with it, a nonvacuity or
#     when difference (an amended threshold needs a new mutant); nothing
#     licenses a test, subject or enforced_by difference (a swapped test
#     or subject proves nothing about the claim);
#   - only licensed differences → the advisory "re-promote owed" (promote
#     re-proves it);
#   - no difference → nothing with the verdict, the advisory
#     unverifiable-here without it (promoted in another clone).
# Each new ruling's record must exist in the proposed tree and be neither
# the claim's doc nor its sidecar. _CL_MB empty: V6 is skipped (_claims_init already
# reported base-unresolvable).
#
# The direction policy (config policy, §F) judges each new DOC-STALE or
# RETIRE ruling whose record exists. A gate record is matched structurally:
# docs/spec-claims/gates/<stem>/chunk-<n>.json (<n> a positive integer,
# written without a leading zero) or docs/spec-claims/gates/<stem>/final.json,
# <stem> one path segment (not "." or ".."); no other path is one, whatever
# it contains. A ruling on a gate record is in a plan: with
# in_plan_ruling_requires_gate_record not false (the default true), it is
# valid only when a plan _claims_plan_paths lists (config plans) has that
# stem and lists the claim's doc as target, infer (as V12's decomposition
# check counts it) or amends (_claims_plan_parse); else the finding "gate
# record of a plan that does not govern <doc>". The gate record is not read:
# its existence is the one check above. Any other record is outside a plan:
# when doc_stale_outside_plan_requires is a non-empty string, the ruling's
# by must equal it, else "outside a plan, <direction> needs <principal>".
# outside_plan_presumption has no mechanical effect (help and
# references/spec-claims.md only).

# The absolute verdict store (it may not exist yet).
_claims_store_dir() {
  local d
  d=$(git rev-parse --git-common-dir) || _claims_die "cannot resolve the git common dir"
  d=$(cd "$d" && pwd -P) || _claims_die "cannot resolve the git common dir ($d)"
  printf '%s\n' "$d/spec-claims/promotions"
}

# _claims_sha256 <file>: the file's bare sha256 (64 hex).
_claims_sha256() {
  _hash_one "$1"
  printf '%s\n' "${_HASH#sha256:}"
}

# _claims_states_sha256 <claim-json>: the claim's states_sha256 — the sha256
# of its states string's bytes with no trailing newline (jq -j; a states
# that is not a string hashes its JSON). The one definition promote writes
# and _claims_verdict_bound compares.
_claims_states_sha256() {
  local st="$_SCRATCH/cl-states"
  _claims_jq states -j '.states | if type == "string" then . else tojson end' <<<"$1" > "$st"
  _claims_sha256 "$st"
}

# The fields a promotion proves (promotion.proved), in the order
# _claims_proved digests them. cl_proved_digested, on a claim: its states,
# test, subject, nonvacuity and when, one value each (null when absent);
# cl_proved_keys: the six keys of proved, enforced_by kept as its value.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PROVED='def cl_proved_digested: .states, .test, .subject, .nonvacuity, .when;
 def cl_proved_keys: ["states", "test", "subject", "enforced_by", "nonvacuity", "when"];'

# _claims_proved <claim-json>: the claim's fingerprint, compact JSON {states,
# test, subject, enforced_by, nonvacuity, when}. Each field but enforced_by
# is the sha256 (_claims_sha256) of its canonical JSON: the jq -cS bytes of
# its value (null when the field is absent, so the sha256 of the four bytes
# "null"), with no trailing newline; enforced_by is its value. The one
# definition promote writes and V6, gate and attest compare with.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_proved() {
  local lines="$_SCRATCH/cl-proved-fields" f="$_SCRATCH/cl-proved-field" line d ds=""
  _claims_jq proved-fields -cS "$_JQ_CLAIMS_PROVED cl_proved_digested" <<<"$1" > "$lines"
  # One compact line per field: no raw newline survives jq -c.
  while IFS= read -r line <&3; do
    printf '%s' "$line" > "$f"
    d=$(_claims_sha256 "$f") || _claims_propagate $?
    ds="$ds $d"
  done 3< "$lines"
  # shellcheck disable=SC2086  # the digests are hex words
  set -- "$1" $ds
  [ $# -eq 6 ] || _claims_die "cannot digest the proved fields of a claim"
  _claims_jq proved -nc --argjson c "$1" --arg s "$2" --arg t "$3" --arg u "$4" --arg n "$5" --arg w "$6" \
    '{states: $s, test: $t, subject: $u, enforced_by: $c.enforced_by, nonvacuity: $n, when: $w}'
}

# _claims_proved_delta <claim-json>: the keys of the claim's promotion.proved
# whose value differs from the claim's own (_claims_proved), as a JSON array
# in cl_proved_keys order ([]: every field as proved); null when the claim
# has no promotion.proved object with exactly the six keys (V1's finding).
# No history is read.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_proved_delta() {
  local now
  now=$(_claims_proved "$1") || _claims_propagate $?
  _claims_jq proved-delta -nc --argjson c "$1" --argjson now "$now" "$_JQ_CLAIMS_PROVED"'
    ($c.promotion | if type == "object" then .proved else null end) as $p
    | if ($p | type) == "object" and ($p | keys) == (cl_proved_keys | sort)
      then [cl_proved_keys[] | select($p[.] != $now[.])]
      else null end'
}

# _claims_verdict_bound <claim-json> <delta-json>: bound, missing or unbound —
# whether the verdict file <store>/<promotion.verdict_sha256>.json binds the
# claim. <delta-json> is _claims_proved_delta's answer for it. bound: the
# file exists, its sha256 is that digest, it is one object, and its claim,
# status_to and proved are the claim's id, status and promotion.proved; and
# for each field still as proved (not in <delta-json>), its states_sha256
# (_claims_states_sha256), test, nonvacuity and subject_oids paths (as a set)
# are the claim's — so neither a forged proved nor an edited verdict hides a
# mismatch. missing: no such file. unbound: anything else, a promotion with
# no 64-hex verdict_sha256 included.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_verdict_bound() {
  local claim="$1" delta="$2" digest store file ss out
  digest=$(_claims_jq verdict-digest -r '.promotion | if type == "object" and (.verdict_sha256 | type) == "string"
      and (.verdict_sha256 | test("^[0-9a-f]{64}$")) then .verdict_sha256 else "" end' <<<"$claim") \
    || _claims_propagate $?
  if [ -z "$digest" ]; then
    echo unbound
    return 0
  fi
  store=$(_claims_store_dir) || _claims_propagate $?
  file="$store/$digest.json"
  if [ ! -f "$file" ]; then
    echo missing
    return 0
  fi
  ss=$(_claims_sha256 "$file") || _claims_propagate $?
  if [ "$ss" != "$digest" ]; then
    echo unbound
    return 0
  fi
  ss=$(_claims_states_sha256 "$claim") || _claims_propagate $?
  # Its output is the answer (a verdict file that is not JSON: unbound), so
  # not _claims_jq; empty output (jq 1.6 on an unparseable file) is unbound
  # too.
  out=$(jq -r -n --slurpfile v "$file" --argjson c "$claim" --arg ss "$ss" --argjson d "$delta" '
      def moved($k): $d != null and any($d[]; . == $k);
      def cl_subj: if type == "array" then unique else . end;
      if ($v | length) == 1 and ($v[0] | type) == "object" and $v[0].claim == $c.id
         and $v[0].status_to == $c.status and $v[0].proved == ($c.promotion | objects | .proved)
         and (moved("states") or $v[0].states_sha256 == $ss)
         and (moved("test") or $v[0].test == $c.test)
         and (moved("nonvacuity") or $v[0].nonvacuity == $c.nonvacuity)
         and (moved("subject") or (($v[0].subject_oids | type) == "object"
                                   and ($v[0].subject_oids | keys) == ($c.subject | cl_subj)))
      then "bound" else "unbound" end' 2>/dev/null) || out=unbound
  [ "$out" = bound ] || out=unbound
  echo "$out"
}

# _claims_verdict_check <claim-json>: ok, missing or mismatch. ok: the
# verdict binds the claim (_claims_verdict_bound) and every field is as
# promotion.proved says it was proved (_claims_proved_delta: []). missing:
# the verdict is not in the local store. mismatch: anything else.
_claims_verdict_check() {
  local claim="$1" delta b
  delta=$(_claims_proved_delta "$claim") || _claims_propagate $?
  b=$(_claims_verdict_bound "$claim" "$delta") || _claims_propagate $?
  case "$b" in
    missing) echo missing ;;
    bound)
      if [ "$delta" = "[]" ]; then echo ok; else echo mismatch; fi
      ;;
    *) echo mismatch ;;
  esac
}

# _claims_repromote_owed <claim-id> <since-rev>: owed or clear for a
# built/gated claim of cl-claims.json (clear for any other status, for a
# lint, log or judge claim without a promotion — it is not promoted: run and
# gate run its check — or no such claim), decided by promotion.proved, never
# by history or by the store: owed when the claim's states, test or
# nonvacuity differs from proved (_claims_proved_delta: an amendment, or a
# later edit under the same ruling, after the proof), or it has no proved;
# and, when the store holds its verdict, when that verdict does not bind it
# (_claims_verdict_bound). Else clear — a subject, enforced_by or when
# difference is V6's finding, not a re-promotion. So a fresh clone, CI, or
# a trunk the promotion's branch was squashed onto gives the same answer.
# <since-rev> (the gate's from / _CL_MB) is accepted for the callers'
# interface and not read: the proved record, not when a ruling arrived,
# decides.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_repromote_owed() {
  local id="$1" entry claim delta b
  entry=$(_claims_jq owed-claim -c --arg id "$id" \
    'first(.[] | select(.claim.id == $id and (.claim.status == "built" or .claim.status == "gated")
                       and (.claim.enforced_by == "test" or (.claim.promotion | type) == "object"))) // empty' \
    "$_SCRATCH/cl-claims.json") || _claims_propagate $?
  if [ -z "$entry" ]; then
    echo clear
    return 0
  fi
  claim=$(_claims_jq owed-record -c '.claim' <<<"$entry") || _claims_propagate $?
  delta=$(_claims_proved_delta "$claim") || _claims_propagate $?
  b=$(_claims_verdict_bound "$claim" "$delta") || _claims_propagate $?
  if [ "$b" = unbound ]; then
    echo owed
    return 0
  fi
  _claims_jq owed-delta -nr --argjson d "$delta" \
    'if $d == null or any($d[]; . == "states" or . == "test" or . == "nonvacuity") then "owed" else "clear" end'
}

# A plan's Specs role that counts as a target (V12's decomposition check, the
# direction policy): target, or infer.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_ROLES='def cl_targets: .role == "target" or .role == "infer";'

# The gate-record shape, one definition for V6's policy matcher, gate's
# chunk-<n>.json and attest's final.json: cl_gate_stem, on a path, is <stem>
# when the path is docs/spec-claims/gates/<stem>/chunk-<n>.json (<n> a
# positive integer, no leading zero) or docs/spec-claims/gates/<stem>/final.json,
# <stem> one path segment other than "." and ".."; else null.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_GATE_PATH='def cl_gate_stem: if type == "string" then
     first(capture("^docs/spec-claims/gates/(?<s>[^/]+)/(chunk-[123456789][0123456789]*|final)\\.json$")
           | .s | select(. != "." and . != "..")) // null
   else null end;'

# The base-versus-proposed defs V6 and V7 share, so "a new ruling" and the
# base claim of an id are one definition. cl_base_by_id($b): the cl-claims-base
# entries keyed by claim id, the first of a duplicated id kept. cl_rulings: a
# claim's rulings array ([] when absent or not an array). On a claim,
# cl_new_rulings($o): its rulings that the base claim $o (null: none) does not
# have, by whole-object equality. (cl_base_by_id also indexes the proposed
# claims: V7's $now.)
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_DELTA='def in_list($l): . as $x | any($l[]; . == $x);
 def cl_rulings: if type == "object" and (.rulings | type) == "array" then .rulings else [] end;
 def cl_base_by_id($b): reduce ($b[] | select((.claim.id | type) == "string")) as $e ({};
   if has($e.claim.id) then . else .[$e.claim.id] = $e end);
 def cl_new_rulings($o): ($o | cl_rulings) as $was
   | [cl_rulings | .[] | . as $r | select(any($was[]; . == $r) | not)];'

# V6 (see the section comment), one program in three phases ($phase), run
# after _JQ_CLAIMS_SIDECAR (cl_well_formed, cl_all_retired) and
# _JQ_CLAIMS_NORM (claims_norm), _JQ_CLAIMS_ROLES (cl_targets),
# _JQ_CLAIMS_GATE_PATH (cl_gate_stem) and _JQ_CLAIMS_DELTA. $p, $b:
# cl-claims.json and cl-claims-base.json; $t: cl-touched.json; $sp, $sb: the
# cl-sidecars lines of the proposed tree and of _CL_MB. Phase verify prints
# the touched built/gated claims whose verdict is to be checked (one JSON
# line each); phase records, the distinct records the new rulings name;
# phase check, the finding rows and advisory rows (the advisories carry a
# code), given $v ({claim, verdict, delta} per checked claim) and $rec ({record,
# exists} per record).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RATCHET='def v6($claim; $doc; $msg): {check: "V6", claim: $claim, doc: $doc, message: $msg};
 def v6a($claim; $code; $msg): {check: "V6", claim: $claim, code: $code, message: $msg};
 def cl_rank: if type == "string" then ({"test": 4, "lint": 3, "log": 2, "judge": 1}[.] // 0) else 0 end;
 def cl_promoted: . == "built" or . == "gated";
 def cl_policy: (.policy | if type == "object" then . else {} end);
 def cl_ruled: type == "object" and (.direction == "DOC-STALE" or .direction == "RETIRE");
 $t[0] as $touched
 | cl_base_by_id($b[0]) as $base
 | [$p[0][] | select((.claim.id | type) == "string") | select(.claim.id | in_list($touched))
    | . as $e | $base[$e.claim.id].claim as $o
    | $e + {old: $o,
            new: ($e.claim | cl_new_rulings($o)),
            moved_in: (($e.claim.status | cl_promoted) and ($o == null or ($o.status | cl_promoted | not)))}
    | .bare = (.moved_in and .claim.enforced_by == "test" and (.claim.promotion | type) != "object")
    | .verify = ((.claim.status | cl_promoted) and (.claim.enforced_by == "test" or (.claim.promotion | type) == "object")
                 and (.old == null or .old != .claim) and (.bare | not))] as $rows
 | if $phase == "verify" then $rows[] | select(.verify) | {claim, sidecar} | tojson
   elif $phase == "records" then
     [$rows[] | .new[] | objects | .record | strings | select(. != "" and (test("\n") | not))] | unique | .[]
   elif $phase == "stems" then
     if ($cfg[0] | cl_policy | .in_plan_ruling_requires_gate_record) == false then empty
     else [$rows[] | .new[] | select(cl_ruled) | .record | cl_gate_stem | strings] | unique | .[] end
   else
     ($cfg[0] | cl_policy) as $pol
     | ($pol.in_plan_ruling_requires_gate_record != false) as $gate_req
     | ($pol.doc_stale_outside_plan_requires | if type == "string" and . != "" then . else null end) as $outside_by
     | (reduce $rec[] as $r ({}; .[$r.record] = $r.exists)) as $exists
     | [$p[0][] | .claim.id | strings] as $ids
     | (reduce $sp[] as $s ({}; .[$s.sidecar] = ($s | cl_well_formed))) as $now
     | (reduce $sb[] as $s ({}; .[$s.sidecar] = ($s | cl_all_retired))) as $retired
     | ($rows[] | . as $e | .claim as $c | .old as $o | .claim.id as $id | .doc as $doc
        | any($e.new[]; cl_ruled) as $amended
        | (($e.new | length) > 0) as $ruled
        | ([$e.new[] | objects | .direction | strings] | unique | join(", ")) as $dirs
        | (if $ruled | not then "without a new ruling" elif $dirs == "" then "under a new ruling with no direction"
           else "under a \($dirs) ruling" end) as $how
        | (if $c.enforced_by == "test" then "run claims promote \($id)"
           else "a \($c.enforced_by | tostring) claim is not promoted (claims promote proves test claims only): remove its promotion" end) as $fix
        | (if $o != null then
             (if $c.states != $o.states and ($amended | not)
              then (if $ruled | not
                    then v6($id; $doc; "states changed since the merge-base without a new ruling (a DOC-STALE amendment records its ruling: direction, by, record, reason)")
                    else v6($id; $doc; "states changed since the merge-base \($how): only a new DOC-STALE (or RETIRE) ruling changes states (CODE-DIVERGES keeps the doc as the intent: fix the code, or move the claim to diverged with a tracker)") end)
              else empty end),
             (if $o.status == "built" and $c.status != "built" and ($ruled | not)
              then v6($id; $doc; "status moved off built (built → \($c.status | tostring)) without a new ruling")
              else empty end),
             (($o.enforced_by | cl_rank) as $was | ($c.enforced_by | cl_rank) as $is
              | if $is > 0 and $was > $is and ($amended | not)
                then v6($id; $doc; "enforced_by lowered (\($o.enforced_by) → \($c.enforced_by); test > lint > log > judge) \($how)\(if $ruled then ": lowering a claim'"'"'s enforcement needs a new DOC-STALE (or RETIRE) ruling" else "" end)")
                else empty end),
             (if ($o.quote | type) == "string" and ($c.quote | type) == "string" and $o.quote != $c.quote
                 and ($o.quote | claims_norm) != ($c.quote | claims_norm) and ($amended | not)
              then v6($id; $doc; "re-anchor changed a token of the quote \($how)\(if $ruled then ": a changed claimed text needs a new DOC-STALE (or RETIRE) ruling" else " (a reflow or a move, equal once normalised, needs none)" end)")
              else empty end)
           else empty end),
          (if $e.bare
           then v6($id; $doc; "status \($c.status) without a promotion: claims promote is a test claim'"'"'s only path into \($c.status)")
           else empty end),
          (if $e.verify then
             (first($v[] | select(.claim == $c)) // {verdict: "missing", delta: null}) as $r
             | $r.delta as $d
             | (if $d != null and $amended and any($d[]; . == "states")
                then ["states", "nonvacuity", "when"] else [] end) as $lic
             | (if $d == null then [] else [$d[] | select(in_list($lic) | not)] end) as $bad
             | if $d == null
               then v6($id; $doc; "promotion has no proved record (promotion.proved: the fields promote proved, digested), so what changed since the proof cannot be told: \($fix)")
               elif $r.verdict == "unbound"
               then v6($id; $doc; "promotion verdict does not match the claim (the verdict file was edited, or it was stored for another claim, status, proved record, states, test, mutant or subject): \($fix)")
               elif ($bad | length) > 0
               then v6($id; $doc; "\($bad | join(", ")) changed since promote proved the claim (promotion.proved)\(if $amended then "; a DOC-STALE or RETIRE ruling covers only a states change (with the nonvacuity or when that moves with it)" elif any($bad[]; . == "states") then " without a new DOC-STALE (or RETIRE) ruling" else "" end): \($fix)")
               elif ($d | length) > 0
               then v6a($id; "re-promote owed"; "states changed under a ruling: \($fix)")
               elif $r.verdict == "missing"
               then v6a($id; "unverifiable-here"; "promotion verdict \($c.promotion.verdict_sha256) is not in the local verdict store (promoted in another clone?), and the claim is as promote proved it (promotion.proved): the scheduled run re-verifies it")
               else empty end
           else empty end),
          ($e.new[] | objects | . as $ru | ($ru.record | strings | select(. != "")) as $r | ($r | cl_gate_stem) as $stem
           | if $r == $doc or $r == $e.sidecar
             then v6($id; $doc; "ruling record \($r) is the doc or the sidecar of the claim it rules on (self-referential record): name where the decision is recorded (an issue, an ADR, a gate record)")
             elif $exists[$r] != true
             then v6($id; $doc; "ruling record \($r) does not exist in the proposed tree")
             elif ($ru | cl_ruled | not) then empty
             elif $stem != null then
               (if $gate_req and (any($gov[]; .stem == $stem
                                      and any(.specs[]; .path == $doc
                                              and (cl_targets or .role == "amends"))) | not)
                then v6($id; $doc; "ruling record \($r) is a gate record of a plan that does not govern \($doc) (no plan matching config plans with stem \($stem) lists it as target, infer or amends): rule at the gate of a plan that builds or amends it, or record the ruling elsewhere")
                else empty end)
             elif $outside_by != null and $ru.by != $outside_by
             then v6($id; $doc; "ruling record \($r) is not a gate record, so the ruling is outside a plan: outside a plan, \($ru.direction) needs \($outside_by) (this ruling is by \($ru.by | tojson))")
             else empty end)),
       ($base[] | select(.claim.id | in_list($touched)) | select(.claim.id | in_list($ids) | not)
        | .sidecar as $sc
        | if $now | has($sc) then
            (if $now[$sc]
             then v6(.claim.id; .doc; "deleted: retire it instead (status retired, a RETIRE ruling, the sentence struck); only a whole sidecar whose claims were all retired at the merge-base may be deleted")
             else empty end)
          elif $retired[$sc] == true then empty
          else v6(.claim.id; .doc; "deleted with its sidecar \($sc): retire it instead (status retired, a RETIRE ruling, the sentence struck); only a whole sidecar whose claims were all retired at the merge-base may be deleted")
          end)
   end'

# V6: the proved delta and the verdict binding of each claim phase verify
# names (_claims_proved_delta, _claims_verdict_bound) and the existence of
# each record phase records names (_claims_read: the
# index under --staged; a path with an empty, "." or ".." segment is never a
# repo path), then phase check. The shell loops run over those short lists,
# never over every claim.
_claims_v6() {
  local prog="$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_NORM $_JQ_CLAIMS_ROLES $_JQ_CLAIMS_GATE_PATH $_JQ_CLAIMS_DELTA $_JQ_CLAIMS_RATCHET"
  local line c x v r exists plan src stem stems
  local verify="$_SCRATCH/cl-v6-verify" vrows="$_SCRATCH/cl-v6-verdicts.jsonl"
  local records="$_SCRATCH/cl-v6-records" rrows="$_SCRATCH/cl-v6-records.jsonl" out="$_SCRATCH/cl-v6.jsonl"
  local gov="$_SCRATCH/cl-v6-gov.jsonl" pj="$_SCRATCH/cl-v6-plan.json"
  [ -n "$_CL_MB" ] || return 0
  : > "$vrows"
  : > "$rrows"
  : > "$gov"
  set -- --slurpfile p "$_SCRATCH/cl-claims.json" --slurpfile b "$_SCRATCH/cl-claims-base.json" \
    --slurpfile t "$_SCRATCH/cl-touched.json" --slurpfile sp "$_SCRATCH/cl-sidecars.jsonl" \
    --slurpfile sb "$_SCRATCH/cl-sidecars-base.jsonl" --slurpfile v "$vrows" --slurpfile rec "$rrows" \
    --slurpfile cfg "$_SCRATCH/cl-config.json" --slurpfile gov "$gov"
  _claims_jq v6-verify -nrc --arg phase verify "$@" "$prog" > "$verify"
  _claims_jq v6-records -nrc --arg phase records "$@" "$prog" > "$records"
  # The direction policy's plans: each plan whose stem a new DOC-STALE/RETIRE
  # ruling's gate record names, as {stem, path, specs}.
  stems=$(_claims_jq v6-stems -nr --arg phase stems "$@" "$prog") || _claims_propagate $?
  if [ -n "$stems" ]; then
    src=all
    [ "$_CL_MODE" != staged ] || src=staged
    _claims_plan_paths indexed
    while IFS= read -r -d '' plan <&3; do
      stem=${plan##*/}
      stem=${stem%.*}
      case "
$stems
" in
        *"
$stem
"*)
          _claims_plan_parse "$plan" "$src" > "$pj"
          _claims_jq v6-plan-row -c '{stem, path, specs}' "$pj" >> "$gov"
          ;;
      esac
    done 3< "$_SCRATCH/cl-plans.z"
  fi
  # Each claim's row: the fields that differ from its promotion.proved
  # (_claims_proved_delta: delta, null without proved) and whether the
  # store's verdict binds it (_claims_verdict_bound: bound, missing or
  # unbound). Phase check decides from the two, as gate and attest do.
  while IFS= read -r line <&3; do
    c=$(_claims_jq v6-verify-claim -c '.claim' <<<"$line") || _claims_propagate $?
    x=$(_claims_proved_delta "$c") || _claims_propagate $?
    v=$(_claims_verdict_bound "$c" "$x") || _claims_propagate $?
    _claims_jq v6-verdict-row -nc --argjson c "$c" --arg v "$v" --argjson d "$x" \
      '{claim: $c, verdict: $v, delta: $d}' >> "$vrows"
  done 3< "$verify"
  while IFS= read -r r <&3; do
    exists=false
    if _claims_safe_relpath "$r" && { [ "$_CL_MODE" != all ] || _claims_contained_path "$r"; } \
        && _claims_read "$r" >/dev/null; then exists=true; fi
    _claims_jq v6-record-row -nc --arg r "$r" --argjson e "$exists" '{record: $r, exists: $e}' >> "$rrows"
  done 3< "$records"
  # jq reads $v and $rec at each call: here, with the rows written.
  _claims_jq v6 -nc --arg phase check "$@" "$prog" > "$out"
  _claims_jq v6-findings -c 'select(has("code") | not)' "$out" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq v6-advisories -c 'select(has("code"))' "$out" >> "$_SCRATCH/cl-advisories.jsonl"
}

# --- Spec claims: the restates sweep, V7 ---------------------------------------
#
# A claim A with restates [B...] says again what claim B says (an ADR's
# sentence and the spec's). When B's states differs between the merge-base
# and the proposed tree and A has no new ruling (the V6 ratchet's own
# definitions: cl_new_rulings, and a changed states), A is stale until it is
# swept: V7 "restates <B>, whose states changed". Not in the default blocking
# list, so validate reports it as an advisory (central, in _JQ_CLAIMS_EMIT).
# Scope: A is judged when A or B is touched (_claims_touched), so under
# --staged a change to B's sidecar finds an A in a sidecar that is not staged
# with it; a staged config.json touches every claim, and --all judges every
# claim. A retired A is not judged (its sentence is struck), nor is an A new
# in this change (it was written against B as B now reads); an id that names
# no claim is V1's, and so is one that names A itself. B must be in both
# trees to have changed.

# cl-claims.json ($p), cl-claims-base.json ($b), cl-touched.json ($t) → the
# V7 finding rows. Run after _JQ_CLAIMS_DELTA.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V7='$t[0] as $touched
 | cl_base_by_id($b[0]) as $base
 | cl_base_by_id($p[0]) as $now
 | $p[0][] | select((.claim.id | type) == "string" and .claim.status != "retired" and (.claim.restates | type) == "array")
 | . as $e | $e.claim as $c
 | select($base[$c.id] != null and ($c | cl_new_rulings($base[$c.id].claim) | length) == 0)
 | ([$c.restates[] | strings | select(. != $c.id)] | unique[]) as $r
 | select(($c.id | in_list($touched)) or ($r | in_list($touched)))
 | select($base[$r] != null and $now[$r] != null and $base[$r].claim.states != $now[$r].claim.states)
 | {check: "V7", claim: $c.id, doc: $e.doc, message: "restates \($r), whose states changed"}'

# _claims_v7: V7 (see the section comment), its rows added to the verdict's
# findings.
_claims_v7() {
  [ -n "$_CL_MB" ] || return 0
  _claims_jq v7 -nc --slurpfile p "$_SCRATCH/cl-claims.json" --slurpfile b "$_SCRATCH/cl-claims-base.json" \
    --slurpfile t "$_SCRATCH/cl-touched.json" "$_JQ_CLAIMS_DELTA $_JQ_CLAIMS_V7" >> "$_SCRATCH/cl-findings.jsonl"
}

# --- Spec claims: the status block, render, V11 --------------------------------
#
# A doc with an eligible sidecar carries a generated block (§B), between the
# markers <!-- spec-claims:status:begin --> and <!-- spec-claims:status:end -->:
# a "## Claim status" heading, then a table of the claims that are neither
# built nor retired (sorted by id), or the single line "Claims: N built" when
# every non-retired claim is built. No dates, SHAs or live values, so it
# changes only when a status (or a tracker) does. The first render puts it
# immediately before the doc's second ## heading line outside a code fence
# (claims_fence_kinds: the one fence rule V2 masks by), or, with none, at the
# end of the file after one blank line; thereafter it replaces the marker
# lines and every line between them — the lines V2's claims_status_blank
# blanks, located by the same rule (claims_is_marker: a marker alone on its
# line, up to 3 spaces of indentation and trailing blanks or \r allowed;
# fences are not consulted), so the block is never live text, and a marker
# quoted in prose is text. Marker lines that are not exactly
# one begin and, after it, one end are a V11 finding; that doc is never
# written. A CRLF doc gets a CRLF block.
# A sidecar that is not eligible (its doc missing or not governing in the
# tree read: the V2 skip) or is malformed is skipped, so nothing is ever
# written into an archived record and a missing doc is never created.

# The rendered doc (raw on stdin; $s: the sidecar object, slurped; run after
# _JQ_CLAIMS_NORM): a tag line — I (the block inserted), R (replaced) or E
# (the markers are unusable) — then the new content, byte for byte (E: the
# reason). A gated row names its condition, when's keys sorted:
# "gated (when: KEY=VALUE, …)". Cells are one line, with "|" escaped.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RENDER='def cl_str: if type == "string" then . else tojson end;
 def cl_cell: cl_str | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
 def cl_status_cell:
   if .status == "gated" and (.when | type) == "object" and (.when | length) > 0
   then "gated (when: \([.when | to_entries | sort_by(.key)[] | "\(.key)=\(.value | cl_str)"] | join(", ")))" | cl_cell
   else .status | cl_cell end;
 def cl_row: "| `\(.id | cl_cell)` | \(cl_status_cell) | \(if (.tracker | type) == "string" and .tracker != "" then .tracker | cl_cell else "—" end) |";
 def claims_block($sc; $eol):
   [$sc.claims[] | select(type == "object") | select(.status != "retired")] as $live
   | (if all($live[]; .status == "built") then ["Claims: \($live | length) built"]
      else ["| Claim | Status | Tracker |", "|---|---|---|"]
        + ([$live[] | select(.status != "built")] | sort_by(.id | cl_str) | map(cl_row))
      end) as $body
   | ["<!-- spec-claims:status:begin -->", "## Claim status", ""] + $body + ["", "<!-- spec-claims:status:end -->"]
   | join($eol);
 "<!-- spec-claims:status:begin -->" as $b | "<!-- spec-claims:status:end -->" as $e
 | (if test("\r\n") then "\r\n" else "\n" end) as $eol
 | claims_block($s[0]; $eol) as $blk
 | split("\n") as $ls
 | [range(0; $ls | length) | select($ls[.] | claims_is_marker($b))] as $bi
 | [range(0; $ls | length) | select($ls[.] | claims_is_marker($e))] as $ei
 | if ($bi | length) == 0 and ($ei | length) == 0 then
     (gsub("\r\n"; "\n") | claims_fence_kinds) as $k
     | ([range(0; $k | length) | select($k[.].k == "out" and ($k[.].t | test("^ {0,3}##([ \t]|$)")))][1]) as $i
     | if $i != null then
         "I\n" + ($ls[0:$i] + [$blk + (if $eol == "\r\n" then "\r" else "" end)] + $ls[$i:] | join("\n"))
       elif . == "" then "I\n" + $blk + $eol
       elif endswith("\n") then "I\n" + . + $eol + $blk + $eol
       else "I\n" + . + $eol + $eol + $blk + $eol end
   elif ($bi | length) == 1 and ($ei | length) == 1 and $bi[0] < $ei[0] then
     "R\n" + ($ls[0:$bi[0]] + [$blk + (if $ls[$ei[0]] | endswith("\r") then "\r" else "" end)] + $ls[$ei[0] + 1:]
               | join("\n"))
   else "E\nthe status block markers are not one begin/end pair, begin first (found \($bi | length) begin and \($ei | length) end marker line(s)): fix them by hand, then run doc-tools.sh claims render"
   end'

_CL_RENDER_KIND=""  # _claims_render_doc's outcome: inserted | replaced | error
_CL_RENDER_ERR=""   # why, when error

# _claims_render_doc <doc> <sidecar-json-file>: print <doc>'s new content —
# the doc read through _claims_read (the index under --staged), its status
# block rendered from the sidecar object in <sidecar-json-file>. The doc as
# read stays in $_SCRATCH/cl-render.raw for the caller's comparison. Returns
# 1, printing nothing, when the markers are unusable (_CL_RENDER_ERR says
# why). Sets _CL_RENDER_KIND, so call it in the main shell, its output
# redirected to a file: $(…) would drop the content's trailing newlines.
_claims_render_doc() {
  local doc="$1" cur="$_SCRATCH/cl-render.raw" out="$_SCRATCH/cl-render.out" tag=""
  _CL_RENDER_KIND=error
  _CL_RENDER_ERR=""
  _claims_read "$doc" > "$cur" || _claims_die "cannot read $doc (render)"
  _claims_jq render -Rsj --slurpfile s "$2" "$_JQ_CLAIMS_NORM $_JQ_CLAIMS_RENDER" "$cur" > "$out"
  IFS= read -r tag < "$out" || true
  case "$tag" in
    I) _CL_RENDER_KIND=inserted ;;
    R) _CL_RENDER_KIND=replaced ;;
    *)
      _CL_RENDER_ERR=$(tail -n +2 "$out")
      return 1
      ;;
  esac
  tail -n +2 "$out"
}

# The sidecars whose blocks a run covers (on the cl-sidecars lines, $sum:
# cl-sidecars.json for each one's skip): every sidecar, or under --staged
# ($staged 1) only those the index changes. One line each: {sidecar, doc,
# skip, data}.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_BLOCKS='$sum[0] as $sum | $st[0] as $st
 | .[] | . as $l
 | select($staged == 0 or any($st[]; . == $l.sidecar))
 | {sidecar, doc, skip: ([$sum[] | select(.sidecar == $l.sidecar) | .skip][0]), data}'

# _claims_blocks <write|check|validate>: each covered sidecar's doc rendered
# (see the section comment). write replaces each doc whose render differs
# (atomic); check and validate write nothing and report a V11 finding per
# doc that differs. write and check add a result per sidecar — {doc,
# changed} (check: whether render would change it; null when the markers
# are unusable) or {doc, skipped};
# validate (V11) adds none, and covers only the staged sidecars under
# --staged, comparing the staged doc with a render of the staged sidecar.
_claims_blocks() {
  local action="$1" staged=0 list="$_SCRATCH/cl-blocks" sc="$_SCRATCH/cl-block-sidecar.json"
  local new="$_SCRATCH/cl-block.new" line doc skip changed row
  if [ "$_CL_MODE" = staged ]; then staged=1; fi
  _claims_jq blocks -sc --argjson staged "$staged" --slurpfile st "$_SCRATCH/cl-staged.json" \
    --slurpfile sum "$_SCRATCH/cl-sidecars.json" "$_JQ_CLAIMS_BLOCKS" "$_SCRATCH/cl-sidecars.jsonl" > "$list"
  while IFS= read -r line <&3; do
    doc=$(_claims_jq block-doc -r '.doc // ""' <<<"$line") || _claims_propagate $?
    skip=$(_claims_jq block-skip -r '.skip // ""' <<<"$line") || _claims_propagate $?
    if [ -n "$skip" ]; then
      if [ "$action" != validate ]; then
        row=$(_claims_jq block-skipped -nc --arg doc "$doc" --arg skip "$skip" \
          '{doc: (if $doc == "" then null else $doc end), skipped: $skip}') || _claims_propagate $?
        _claims_result "$row"
      fi
      continue
    fi
    # The loader already skips an unsafe doc ("unsafe path"); never read or
    # write one even so.
    if ! _claims_safe_relpath "$doc" || ! _claims_contained_path "$doc"; then
      _claims_die "refusing to render $doc: not a safe repo path"
    fi
    _claims_jq block-data -c '.data' <<<"$line" > "$sc"
    changed=false
    if ! _claims_render_doc "$doc" "$sc" > "$new"; then
      changed=null
      _claims_finding V11 - "$doc" "$_CL_RENDER_ERR"
    elif ! cmp -s "$new" "$_SCRATCH/cl-render.raw"; then
      changed=true
      case "$action" in
        write)
          _tmp_beside "$doc"
          cat "$new" > "$_TMP" || _claims_die "cannot write the render of $doc"
          _replace_file "$_TMP" "$doc"
          ;;
        *)
          if [ "$_CL_RENDER_KIND" = inserted ]; then
            _claims_finding V11 - "$doc" "no status block: run doc-tools.sh claims render"
          else
            _claims_finding V11 - "$doc" "the status block differs from its render (a status changed, or the block was edited by hand): run doc-tools.sh claims render"
          fi
          ;;
      esac
    fi
    if [ "$action" != validate ]; then
      row=$(_claims_jq block-result -nc --arg doc "$doc" --argjson c "$changed" \
        '{doc: $doc, changed: $c}') || _claims_propagate $?
      _claims_result "$row"
    fi
  done 3< "$list"
}

# --- Spec claims: runner adapters, claims run --------------------------------
#
# A host plugs its test frameworks in through adapter executables named in
# the config (§D; the JSON shapes are the contract, never extended):
#   runners.<name> = {"adapter": "<repo path>", "paths": ["<prefix-or-glob>"…]}
#     <adapter> list [<file>…]  → JSON lines {"id", "node", "file", "in_gate":
#       bool, "subject_imports_ok": bool, "when": {…}|null}  (V3, validate)
#     <adapter> run --root <dir> <node>…  → JSON lines {"node", "outcome":
#       "pass"|"assert-fail"|"error"|"not-found"|"indeterminate", "reason"}
#     <adapter> edited-bound-tests --staged | <range>  → claim ids
#   log_adapter = "<repo path>"|null
#     <adapter> run <claim-id>  → {"outcome": "pass"|"fail"|"indeterminate",
#       "evidence"}
# Every adapter call goes through _claims_adapter_call: from the repo root,
# stdin /dev/null (an adapter never eats a hook's ref lines) and fd 9, the
# verdict fd, closed (an adapter, or a child it leaves running, never holds
# the caller's captured stdout open). A test.runner the config does not name,
# or an adapter path that is not a safe, contained repo path, is a missing
# adapter: rc 126, indeterminate.
#
# claims run selects claims (--claims, --planes-of, --all), skips the
# retired, frozen and judge ones (and log ones without --scheduled), makes
# one run call per runner and one log-adapter call per log claim, evaluates
# each lint claim's pattern over the working tree (_claims_lint_tree and
# _claims_lint_eval: see "lint, V4"), and judges each outcome by the claim's
# status (claims_expect). Every finding blocks.
# Scratch: cl-run-plan.json (one entry per selected claim), cl-run-rows.jsonl
# (the parsed adapter rows and the lint rows) and cl-run-results.json.

# _claims_adapter_call <out-file> <adapter-path> <args…>: run
# "$_CL_ROOT/<adapter-path>" <args…> from the repo root, its stdout into
# <out-file>, with </dev/null 9>&- 3<&- (fd 3: the callers' open scratch
# list); return its rc. An empty, unsafe
# (_claims_safe_relpath), uncontained (_claims_contained_path), missing or
# non-executable adapter returns 126 without running anything.
_claims_adapter_call() {
  local out="$1" adapter="$2" rc=0
  shift 2
  : > "$out" || _claims_die "cannot write $out"
  if [ -z "$adapter" ] || ! _claims_safe_relpath "$adapter" || ! _claims_contained_path "$adapter" \
      || [ ! -f "$_CL_ROOT/$adapter" ] || [ ! -x "$_CL_ROOT/$adapter" ]; then
    return 126
  fi
  (cd "$_CL_ROOT" && exec "$_CL_ROOT/$adapter" "$@") </dev/null 9>&- 3<&- > "$out" || rc=$?
  return "$rc"
}

# _claims_runner_adapter <runner>: print config runners.<runner>.adapter —
# nothing when the config names no such runner, or gives it no adapter
# string: a missing adapter, which _claims_adapter_call returns 126 for (R6).
# The one lookup run and V3 share.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_runner_adapter() {
  _claims_jq runner-adapter -r --arg r "$1" \
    '.runners | if type == "object" then .[$r] | objects | .adapter | strings else empty end' \
    "$_SCRATCH/cl-config.json"
}

# A run call's stdout ($out: its lines, -R) → one {node, outcome, reason} row
# per requested node ($req[0], a JSON array of nodes). A non-zero adapter rc
# makes every node indeterminate (adapter-exit-<rc>); so does any non-blank
# line that is not a JSON object with a string node and a known outcome
# (malformed-adapter-output: noise is never a pass). A node the output does
# not report, or reports with two different outcomes, is indeterminate
# (malformed-adapter-output). A reason that is not a string is null.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PARSE_RUN='def known: . as $o | any("pass", "assert-fail", "error", "not-found", "indeterminate"; . == $o);
 def indet($n; $r): {node: $n, outcome: "indeterminate", reason: $r};
 $req[0] as $req
 | [inputs | rtrimstr("\r") | select(test("[^ \t]")) | (try {v: fromjson} catch {bad: true})] as $lines
 | (all($lines[]; has("v") and (.v | type) == "object" and (.v.node | type) == "string"
                  and (.v.outcome | type) == "string" and (.v.outcome | known))) as $wf
 | if $rc != 0 then $req[] | indet(.; "adapter-exit-\($rc)")
   elif ($wf | not) then $req[] | indet(.; "malformed-adapter-output")
   else [$lines[].v] as $rows
     | $req[] | . as $n
     | [$rows[] | select(.node == $n)] as $m
     | if ($m | length) == 0 or ([$m[].outcome] | unique | length) > 1 then indet($n; "malformed-adapter-output")
       else {node: $n, outcome: $m[0].outcome, reason: ($m[0].reason | if type == "string" then . else null end)}
       end
   end'

# _claims_rc_arg <helper> <value>: die unless <value> is an exit code (a
# non-empty run of digits). The parse helpers never default one: a missing
# rc would read a crashed adapter's rows as valid.
_claims_rc_arg() {
  case "$2" in
    ''|*[!0123456789]*) _claims_die "$1: <rc> must be the adapter's exit code (got '$2')" ;;
  esac
}

# _claims_parse_run <out-file> <requested-nodes-file> <rc>: print one JSONL
# row {node, outcome, reason} per node of <requested-nodes-file> (a JSON
# array), from a run call's <out-file> and its exit status <rc>
# (_JQ_CLAIMS_PARSE_RUN). All three are required: a missing or non-integer
# <rc> dies (exit 2).
_claims_parse_run() {
  _claims_rc_arg _claims_parse_run "${3-}"
  _claims_jq parse-run -ncR --slurpfile req "$2" --argjson rc "$3" "$_JQ_CLAIMS_PARSE_RUN" < "$1"
}

# A log-adapter call's stdout → one {claim, outcome, reason, evidence} row
# ($claim: the claim id it was called with): exactly
# one non-blank line, a JSON object whose outcome is pass, fail or
# indeterminate; anything else malformed-adapter-output, a non-zero rc
# adapter-exit-<rc> (both indeterminate). An indeterminate's reason is its
# evidence when that is a string.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PARSE_LOG='def indet($r): {claim: $claim, outcome: "indeterminate", reason: $r, evidence: null};
 [inputs | rtrimstr("\r") | select(test("[^ \t]")) | (try {v: fromjson} catch {bad: true})] as $lines
 | if $rc != 0 then indet("adapter-exit-\($rc)")
   elif ($lines | length) != 1 or ($lines[0] | has("v") | not) or ($lines[0].v | type) != "object"
        or (($lines[0].v.outcome as $o | any("pass", "fail", "indeterminate"; . == $o)) | not)
   then indet("malformed-adapter-output")
   else $lines[0].v | (.evidence | if type == "string" then . else null end) as $e
     | {claim: $claim, outcome, reason: (if .outcome == "indeterminate" then ($e // "indeterminate") else null end),
        evidence: $e}
   end'

# _claims_parse_log <out-file> <claim-id> <rc>: print the row
# (_JQ_CLAIMS_PARSE_LOG) of a log-adapter call for <claim-id> that exited <rc>.
# All three are required: a missing or non-integer <rc> dies (exit 2).
_claims_parse_log() {
  _claims_rc_arg _claims_parse_log "${3-}"
  _claims_jq parse-log -ncR --arg claim "$2" --argjson rc "$3" "$_JQ_CLAIMS_PARSE_LOG" < "$1"
}

# claims_expect($status; $outcome; $tier): an outcome judged by the claim's
# status (§D: an unbuilt claim may fail any way; a diverged one only by an
# assertion; a built or gated one must pass) → {verdict: ok | finding |
# indeterminate, message}. A status outside the table is a finding (V1
# names it): nothing can be expected of it. $tier (enforced_by) only words
# the "passes" finding: a test claim is promoted, a lint or log claim moved
# into built by a reviewed status edit (promote refuses it).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_EXPECT='def claims_expect($status; $outcome; $tier):
  def r($v; $m): {verdict: $v, message: $m};
  (if $tier == "test" or ($tier | type) != "string"
   then "passes: promote (the check is green, so the code now does what states says: claims promote <id>)"
   else "passes: move it to built (the check is green, so the code now does what states says: a \($tier) claim enters built by a reviewed status edit; claims promote proves test claims only)"
   end) as $promote
  | if $outcome == "indeterminate" then r("indeterminate"; "indeterminate")
    elif $status == "built" or $status == "gated" then
      (if $outcome == "pass" then r("ok"; "pass")
       else r("finding"; "\($outcome): a \($status) claim must pass its check") end)
    elif $status == "diverged" then
      (if $outcome == "pass" then r("finding"; $promote)
       elif $outcome == "assert-fail" then r("ok"; "assert-fail: the expected red of a diverged claim")
       elif $outcome == "error" then r("finding"; "error is not an expected red (only an assertion failure is): fix the error")
       else r("finding"; "\($outcome): the bound node is not there to fail") end)
    elif $status == "unbuilt" then
      (if $outcome == "pass" then r("finding"; $promote)
       else r("ok"; "\($outcome): an unbuilt claim may fail any way") end)
    else r("finding"; "status \($status | tojson) has no expected outcome")
    end;'

# The run plan: one entry per selected claim of cl-claims.json ($sel: the
# selected ids, null for all), in sidecar order, with what run does with it:
# skip (retired, frozen, judge; log without --scheduled), test (runner,
# node), log, lint (its lint carried), or a verdict decided without running
# (an unbuilt test or lint claim with no check: ok, no check yet; a claim
# that cannot run, or a lint pattern holding a NUL byte: a finding). Run
# after _JQ_CLAIMS_LINT_DEFS.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RUN_PLAN='def nes: type == "string" and length > 0;
 [.[] | select((.claim.id | type) == "string")
  | select($sel == null or (.claim.id as $i | any($sel[]; . == $i)))
  | .claim as $c
  | {claim: $c.id, status: $c.status, tier: $c.enforced_by, doc, node: null}
    + (if $c.status == "retired" then {action: "skip", message: "retired"}
       elif $c.frozen_at | nes then {action: "skip", message: "frozen"}
       elif $c.enforced_by == "judge" then {action: "skip", message: "judge"}
       elif $c.enforced_by == "log" then
         (if $scheduled == 1 then {action: "log"} else {action: "skip", message: "scheduled-only"} end)
       elif $c.enforced_by == "lint" then
         (if $c.lint == null and $c.status == "unbuilt" then {action: "ok", message: "no check yet"}
          elif $c.lint | cl_lint_ok | not then
            {action: "finding", message: "lint \($c.lint | tojson) is not {pattern, paths, expect, selftest}: nothing to run"}
          elif $c.lint.pattern | cl_nonul | not then
            {action: "finding", message: ($c.lint | cl_nul_pattern)}
          else {action: "lint", lint: $c.lint} end)
       elif $c.enforced_by != "test" then {action: "finding", message: "enforced_by \($c.enforced_by | tojson) is not a check run can execute"}
       elif $c.test == null and $c.status == "unbuilt" then {action: "ok", message: "no check yet"}
       elif ($c.test | type) == "object" and ($c.test.runner | nes) and ($c.test.node | nes) then
         {action: "test", runner: $c.test.runner, node: $c.test.node}
       else {action: "finding", message: "test \($c.test | tojson) is not {runner, node}: nothing to run"}
       end)]'

# The plan joined with the adapter rows ($rows: {runner, node, outcome,
# reason} per test node; {claim, outcome, reason, evidence} per log or
# lint claim; {claim, finding} per lint claim that could not be evaluated)
# → the result entries: the row {claim, status, node, outcome, verdict,
# message}, plus doc and reason (for the finding and indeterminate rows).
# A log outcome fail is judged as assert-fail; the row keeps the adapter's
# own word.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RUN_RESULTS='$plan[0] as $plan
 | [$plan[]
    | . as $e
    | if .action == "skip" then {verdict: "skipped", outcome: null, message}
      elif .action == "ok" then {verdict: "ok", outcome: null, message}
      elif .action == "finding" then {verdict: "finding", outcome: null, message}
      else
        ((if .action == "test" then first($rows[] | select(.runner == $e.runner and .node == $e.node))
          else first($rows[] | select(.claim == $e.claim)) end)
         // {outcome: "indeterminate", reason: "not-run"}) as $row
        | if $row.finding != null then {verdict: "finding", outcome: null, message: $row.finding}
          else
            ($row.outcome | if . == "fail" then "assert-fail" else . end) as $o
            | claims_expect($e.status; $o; $e.tier) as $x
            | {outcome: $row.outcome, verdict: $x.verdict, reason: $row.reason,
               message: (if $x.verdict == "indeterminate" then ($row.reason // "indeterminate")
                         elif ($row.evidence | type) == "string" then "\($x.message) (evidence: \($row.evidence))"
                         else $x.message end)}
          end
      end
    | {claim: $e.claim, status: $e.status, node: $e.node, outcome, verdict, message, doc: $e.doc, reason}]'

# --- The range rule: what <a>..<b> means to a claims consumer ---
#
# Every range consumer — run --planes-of's path set, V9 and V8 over the
# gate's <from>..HEAD (V8's added lines: blame, with the merges' hand
# resolutions, _claims_added_lines), the gate record's patch ids (attest
# matches them against <merge-base>..HEAD) — reads the branch's own work,
# never trunk that a merge of the base into the branch brought in:
#   - its commits are `git rev-list --first-parent --no-merges <a>..<b>`;
#     the path set, the patch text and the patch ids come from them alone;
#   - each first-parent merge M of the range (`git rev-list --first-parent
#     --merges`) must have exactly two parents (an octopus merge: dies, exit
#     2) and adds its hand resolutions: the files named by BOTH `git show
#     --cc --name-only M` (differing from every parent) and `git show
#     --remerge-diff --name-only M` (differing from git's own automatic
#     re-merge) — conflict resolutions and evil-merge edits, never a file
#     git merged cleanly nor one resolved by taking a side. Those files go to
#     the path set, and their hunks, `git show --remerge-diff M -- <those
#     files>` (plain unified format: a hunk parser reads them as any other's;
#     a kept conflict marker is a `-` line), to the patch text. Trunk's own
#     lines never come along. A git without --remerge-diff (2.36) and a merge
#     in the range: dies, with no fallback. Patch ids stay non-merge only.
# A three-dot <a>...<b> means <merge-base a b>..<b> (_claims_range_parse). <a>
# must be an ancestor of <b> (a range that is not one branch's work dies,
# exit 2: never an empty set). These helpers are the rule's one
# implementation; no consumer derives a range on its own. Pathspecs are
# literal (git --literal-pathspecs), and the patch text is read with
# _CL_DIFF_OPTS, and a merge re-merged with _CL_REMERGE_CFG, so every clone
# reads the same text and the same merge set. Scratch: cl-range-* .

_CL_RANGE_A=""  # _claims_range_parse's <a>, a full commit id
_CL_RANGE_B=""  # its <b>

# The diff options every patch text of the range rule is read with (with
# core.quotePath on, and no signature shown): pinned, so no clone's git
# config — diff.noprefix, diff.mnemonicPrefix, diff.algorithm, diff.context,
# diff.interHunkContext, diff.indentHeuristic, diff.renames, color, an
# external diff or a textconv driver — changes the text, nor the patch ids
# attest matches across clones and rebases. A caller's own options (V8's
# -U0) come after them, and win.
_CL_DIFF_OPTS=(--no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ --no-color --no-ext-diff
  --no-textconv --unified=3 --inter-hunk-context=0 --indent-heuristic)

# The config git's own re-merge (`show --remerge-diff`) reads, pinned for the
# same reason as _CL_DIFF_OPTS: the diff options shape only the output, not
# which files the re-merge calls clean (merge.renames, which defaults to
# diff.renames, decides whether trunk's edit follows a rename) nor how a
# conflict reads (merge.conflictStyle adds base sections).
_CL_REMERGE_CFG=(-c merge.renames=true -c merge.directoryRenames=conflict -c merge.conflictStyle=merge
  -c merge.renormalize=false -c merge.renameLimit=7000 -c rerere.enabled=false)

# _claims_range_parse <range>: _CL_RANGE_A and _CL_RANGE_B from "<a>..<b>"
# (both given), or from "<a>...<b>", resolved here and only here to
# "$(git merge-base <a> <b>)..<b>" (no merge base: dies). Dies when <range>
# has another shape, when either end is not a commit, or when <a> is not an
# ancestor of <b>.
_claims_range_parse() {
  local a b sep=..
  case "$1" in
    -*|..*|*..) _claims_die "'$1' is not a revision range <a>..<b> or <a>...<b>" ;;
    *...*) sep=... ;;
    *..*) ;;
    *) _claims_die "'$1' is not a revision range <a>..<b> or <a>...<b>" ;;
  esac
  a=${1%%"$sep"*}
  b=${1#*"$sep"}
  _CL_RANGE_A=$(git rev-parse -q --verify "$a^{commit}" 2>/dev/null) || _claims_die "'$a' (in $1) is not a commit"
  _CL_RANGE_B=$(git rev-parse -q --verify "$b^{commit}" 2>/dev/null) || _claims_die "'$b' (in $1) is not a commit"
  if [ "$sep" = ... ]; then
    _CL_RANGE_A=$(git merge-base "$_CL_RANGE_A" "$_CL_RANGE_B" 2>/dev/null) \
      || _claims_die "'$a' and '$b' have no merge base (in $1): the range is not one branch's work"
  fi
  git merge-base --is-ancestor "$_CL_RANGE_A" "$_CL_RANGE_B" 2>/dev/null \
    || _claims_die "'$a' is not an ancestor of '$b' (in $1): the range is not one branch's work"
}

# _claims_range_merges <range> <out-file>: the range's first-parent merges,
# one commit id per line (none: an empty file). Sets _CL_RANGE_A/_B. Dies
# on a merge with other than two parents: --remerge-diff skips an octopus
# merge in silence, so its resolutions would read as none.
_claims_range_merges() {
  local range="$1" out="$2" raw="$_SCRATCH/cl-range-mraw" line m
  _claims_range_parse "$range"
  git rev-list --first-parent --merges --parents "$_CL_RANGE_A..$_CL_RANGE_B" -- > "$raw" 2>/dev/null \
    || _claims_die "git rev-list failed listing the merges of $range"
  : > "$out" || _claims_die "cannot write $out"
  while IFS= read -r line; do
    # shellcheck disable=SC2086  # the line is hex ids: split on spaces
    set -- $line
    m=$1
    [ $# -eq 3 ] || _claims_die "merge $m (in $range) has $(($# - 1)) parents: an octopus merge's resolutions cannot be read (--remerge-diff skips it), so the range is indeterminate"
    printf '%s\n' "$m" >> "$out"
  done < "$raw"
}

# _claims_merge_files <merge> <out-file>: the hand resolutions of the
# two-parent merge <merge>, NUL separated: the files named by both `git show
# --cc --name-only` (changed against every parent) and `git show
# --remerge-diff --name-only` (changed against git's own re-merge). Dies when
# this git rejects --remerge-diff (tried, not guessed from the version).
_claims_merge_files() {
  local cc="$_SCRATCH/cl-merge-cc" rmz="$_SCRATCH/cl-merge-remerge" p q
  local ccf=() rmf=()
  git show -z --no-renames --cc --name-only --format= "$1" -- > "$cc" 2>/dev/null \
    || _claims_die "git show --cc failed on merge $1"
  git "${_CL_REMERGE_CFG[@]}" show -z --no-renames --remerge-diff --name-only --format= "$1" -- > "$rmz" 2>/dev/null \
    || _claims_die "git $(git --version 2>/dev/null | awk '{print $3}') cannot read merge $1 with --remerge-diff (git 2.36 or newer is needed): its hand resolutions are indeterminate"
  while IFS= read -r -d '' p; do
    if [ -n "$p" ]; then ccf+=("$p"); fi
  done < "$cc"
  while IFS= read -r -d '' p; do
    if [ -n "$p" ]; then rmf+=("$p"); fi
  done < "$rmz"
  : > "$2" || _claims_die "cannot write $2"
  for p in ${ccf[@]+"${ccf[@]}"}; do
    for q in ${rmf[@]+"${rmf[@]}"}; do
      if [ "$p" = "$q" ]; then
        printf '%s\0' "$p" >> "$2"
        break
      fi
    done
  done
}

# _claims_range_paths <range> <out-file>: the range's path set (see the
# range rule), NUL separated, no empty entry (a path may repeat): the files
# of its first-parent non-merge commits (both sides of a rename), then each
# first-parent merge's hand resolutions (_claims_merge_files).
_claims_range_paths() {
  local zout="$2" zraw="$_SCRATCH/cl-range-paths.raw" ms="$_SCRATCH/cl-range-merges" mf="$_SCRATCH/cl-range-mfiles" m p
  _claims_range_merges "$1" "$ms"
  git log -z --first-parent --no-merges --no-renames --format= --name-only \
    "$_CL_RANGE_A..$_CL_RANGE_B" -- > "$zraw" 2>/dev/null || _claims_die "git log failed listing the paths of $1"
  while IFS= read -r m <&3; do
    _claims_merge_files "$m" "$mf"
    cat "$mf" >> "$zraw" || _claims_die "cannot write $zraw"
  done 3< "$ms"
  : > "$zout" || _claims_die "cannot write $zout"
  while IFS= read -r -d '' p; do
    if [ -n "$p" ]; then printf '%s\0' "$p" >> "$zout"; fi
  done < "$zraw"
}

# _claims_range_log <out-file> [<diff-option>…]: the patch text of the
# first-parent non-merge commits of _CL_RANGE_A.._CL_RANGE_B (set by
# _claims_range_parse), each after a "commit <sha>" line: `git log -p
# --first-parent --no-merges --format='commit %H'` with _CL_DIFF_OPTS, then
# <diff-option>…. The one invocation _claims_range_patch and
# _claims_patch_ids share.
_claims_range_log() {
  local out="$1"
  shift
  git -c core.quotePath=true log -p --no-show-signature --first-parent --no-merges --format='commit %H' \
    "${_CL_DIFF_OPTS[@]}" "$@" "$_CL_RANGE_A..$_CL_RANGE_B" -- > "$out" 2>/dev/null \
    || _claims_die "git log -p failed on $_CL_RANGE_A..$_CL_RANGE_B"
}

# _claims_range_patch <range> <out-file> [<diff-option>…]: the range's patch
# text (see the range rule): _claims_range_log, then, per first-parent merge
# with hand-resolved files, a "commit <M>" line and `git show --remerge-diff`
# (_CL_DIFF_OPTS, then <diff-option>…) M -- <those files>. A hunk parser
# passes its options. (V8 does not read it: one commit's hunk numbers are
# its own post-image's, not the range end's; see _claims_added_lines.)
_claims_range_patch() {
  local range="$1" out="$2" ms="$_SCRATCH/cl-range-merges" mf="$_SCRATCH/cl-range-mfiles" m p
  local files=()
  shift 2
  _claims_range_merges "$range" "$ms"
  _claims_range_log "$out" "$@"
  while IFS= read -r m <&3; do
    _claims_merge_files "$m" "$mf"
    files=()
    while IFS= read -r -d '' p; do
      if [ -n "$p" ]; then files+=("$p"); fi
    done < "$mf"
    [ ${#files[@]} -gt 0 ] || continue
    printf 'commit %s\n' "$m" >> "$out" || _claims_die "cannot write $out"
    git "${_CL_REMERGE_CFG[@]}" -c core.quotePath=true --literal-pathspecs show --no-show-signature --remerge-diff --format= \
      "${_CL_DIFF_OPTS[@]}" "$@" "$m" -- "${files[@]}" >> "$out" 2>/dev/null \
      || _claims_die "git show --remerge-diff failed on merge $m"
  done 3< "$ms"
}

# _claims_patch_ids <range>: the JSON array [{sha, patch_id}] of the range's
# first-parent non-merge commits, newest first: their patch text
# (_claims_range_log, the text _claims_range_patch reads) through `git
# patch-id --stable` (a commit with an empty patch has none, and is not
# listed). The gate record's commits; attest matches them against
# <merge-base>..HEAD's.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_patch_ids() {
  local log="$_SCRATCH/cl-range-log" ids="$_SCRATCH/cl-range-ids"
  _claims_range_parse "$1"
  _claims_range_log "$log"
  git patch-id --stable < "$log" > "$ids" 2>/dev/null || _claims_die "git patch-id failed on $1"
  _claims_jq patch-ids -Rsc 'split("\n") | map(select(. != "") | split(" ") | {sha: .[1], patch_id: .[0]})' "$ids"
}

# _claims_planes_of <range>: the JSON array of runner names one of whose
# paths entries matches a path <range> changes. An entry holding a glob
# character (* ? [) is a glob (_claims_glob_match: * also matches "/");
# any other entry is a prefix ("src/" matches src/auth/token.py).
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_planes_of() {
  local zs="$_SCRATCH/cl-range.z" entries="$_SCRATCH/cl-run-entries" hit="$_SCRATCH/cl-run-hit"
  local name entry p last=""
  _claims_range_paths "$1" "$zs"
  _claims_jq runner-paths -r '.runners | if type == "object" then to_entries[] else empty end
      | .key as $n | .value | objects | (.paths | if type == "array" then .[] | strings else empty end)
      | select(. != "" and (($n + .) | test("[\t\n]") | not)) | "\($n)\t\(.)"' \
    "$_SCRATCH/cl-config.json" > "$entries"
  : > "$hit"
  while IFS=$'\t' read -r name entry <&3; do
    [ "$name" != "$last" ] || continue
    while IFS= read -r -d '' p <&4; do
      case "$entry" in
        *[*?[]*) _claims_glob_match "$p" "$entry" || continue ;;
        *) case "$p" in "$entry"*) ;; *) continue ;; esac ;;
      esac
      printf '%s\n' "$name" >> "$hit"
      last=$name
      break
    done 4< "$zs"
  done 3< "$entries"
  _claims_jq runners-hit -Rsc 'split("\n") | map(select(. != "")) | unique' "$hit"
}

# _claims_judge_sample <n>: print the JSON array of <n> judge claim ids
# (neither retired nor frozen), sorted by id, starting at index (ISO week,
# date +%V) mod their count and wrapping; every one when <n> exceeds it.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_judge_sample() {
  local week
  week=$(date +%V) || _claims_die "date +%V failed"
  week=$((10#$week))
  _claims_jq judge-sample -c --arg n "$1" --argjson w "$week" \
    '[.[] | .claim | select(type == "object" and .enforced_by == "judge" and .status != "retired"
        and ((.frozen_at | type) != "string" or .frozen_at == "") and (.id | type) == "string") | .id]
     | unique as $ids | ($ids | length) as $k
     | if $k == 0 then [] else ($w % $k) as $s | [range(0; [($n | tonumber), $k] | min) | $ids[($s + .) % $k]] end' \
    "$_SCRATCH/cl-claims.json"
}

# _claims_planes_sel <range> <out-file>: the --planes-of selection — the
# JSON array of the ids of every test claim (cl-claims.json) whose runner
# _claims_planes_of names for <range> — into <out-file>. run and gate share it.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_planes_sel() {
  local runner
  runner=$(_claims_planes_of "$1") || _claims_propagate $?
  _claims_jq run-planes -c --argjson r "$runner" \
    '[.[] | select(.claim.test | type == "object" and (.runner as $n | any($r[]; . == $n))) | .claim.id | strings]' \
    "$_SCRATCH/cl-claims.json" > "$2"
}

# _claims_run_selected <sel-file> <scheduled>: the run core (see the section
# comment), shared by run and gate: the claims <sel-file> selects (a JSON
# array of ids, or null for all) planned (cl-run-plan.json), executed and
# judged (cl-run-results.json); their result rows, findings (check "run")
# and indeterminate rows added to the verdict. <scheduled> 1 runs the log
# claims.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_run_selected() {
  local sel="$1" scheduled="$2" runner adapter rc id node i pattern expect t
  local plan="$_SCRATCH/cl-run-plan.json" rows="$_SCRATCH/cl-run-rows.jsonl"
  local req="$_SCRATCH/cl-run-req.json" nodesz="$_SCRATCH/cl-run-nodes" out="$_SCRATCH/cl-run-out"
  local one="$_SCRATCH/cl-run-one.jsonl" list="$_SCRATCH/cl-run-list" res="$_SCRATCH/cl-run-results.json"
  local nodes=()
  _claims_jq run-plan -c --slurpfile sel "$sel" --argjson scheduled "$scheduled" \
    "$_JQ_CLAIMS_LINT_DEFS"' $sel[0] as $sel | '"$_JQ_CLAIMS_RUN_PLAN" "$_SCRATCH/cl-claims.json" > "$plan"

  # One run call per runner, its nodes as separate arguments.
  : > "$rows"
  _claims_jq run-runners -r '[.[] | select(.action == "test") | .runner] | unique | .[] | select(test("\n") | not)' \
    "$plan" > "$list"
  while IFS= read -r runner <&3; do
    _claims_jq run-nodes -c --arg r "$runner" '[.[] | select(.action == "test" and .runner == $r) | .node] | unique' \
      "$plan" > "$req"
    _claims_jq run-nodes-z -j '.[] | . + "\u0000"' "$req" > "$nodesz"
    nodes=()
    while IFS= read -r -d '' node; do nodes+=("$node"); done < "$nodesz"
    adapter=$(_claims_runner_adapter "$runner") || _claims_propagate $?
    rc=0
    _claims_adapter_call "$out" "$adapter" run --root "$_CL_ROOT" ${nodes[@]+"${nodes[@]}"} || rc=$?
    _claims_parse_run "$out" "$req" "$rc" > "$one"
    _claims_jq run-rows -c --arg r "$runner" '. + {runner: $r}' "$one" >> "$rows"
  done 3< "$list"

  # One log-adapter call per log claim (--scheduled only: the plan has none
  # without it).
  _claims_jq run-logs -r '.[] | select(.action == "log") | .claim | select(test("\n") | not)' "$plan" > "$list"
  if [ -s "$list" ]; then
    adapter=$(_claims_jq log-adapter -r '.log_adapter | strings' "$_SCRATCH/cl-config.json") || _claims_propagate $?
    while IFS= read -r id <&3; do
      rc=0
      _claims_adapter_call "$out" "$adapter" run "$id" || rc=$?
      _claims_parse_log "$out" "$id" "$rc" >> "$rows"
    done 3< "$list"
  fi

  # Each lint claim evaluated over the working tree: pass, assert-fail
  # (an unbuilt claim's absent lint path among them), or (an unusable path,
  # an invalid pattern) a finding.
  _claims_jq run-lints -j 'range(length) as $i | .[$i] | select(.action == "lint")
      | "\($i)\u0000\(.lint.pattern)\u0000\(.lint.expect)\u0000"' "$plan" > "$list"
  while IFS= read -r -d '' i <&3 && IFS= read -r -d '' pattern <&3 && IFS= read -r -d '' expect <&3; do
    rc=0
    _claims_lint_tree "$plan" "$i" || rc=$?
    if [ "$rc" = 1 ]; then
      _claims_jq run-lint-bad -nc --slurpfile plan "$plan" --argjson i "$i" --slurpfile bad "$_SCRATCH/cl-lint-bad.jsonl" \
        '{claim: $plan[0][$i].claim, finding: ([$bad[].message] | join("; "))}' >> "$rows"
      continue
    elif [ "$rc" = 2 ]; then
      t=absent
    else
      t=$(_claims_lint_eval "$pattern" "$expect" "$_SCRATCH/cl-lint-tree") || t=error
    fi
    _claims_jq run-lint-row -nc --slurpfile plan "$plan" --argjson i "$i" --arg t "$t" \
      "$_JQ_CLAIMS_LINT_DEFS"' $plan[0][$i] | if $t == "error" then {claim, finding: (.lint | cl_invalid_pattern)}
       else {claim, outcome: (if $t == "pass" then "pass" else "assert-fail" end), reason: null,
             evidence: ("grep -E \(.lint.pattern | tojson), expect \(.lint.expect), over \(.lint.paths | join(", "))"
                        + (if $t == "absent" then "; a lint path is absent: an unbuilt claim'"'"'s allowed failure" else "" end))}
       end' >> "$rows"
  done 3< "$list"

  _claims_jq run-results -nc --slurpfile plan "$plan" --slurpfile rows "$rows" \
    "$_JQ_CLAIMS_EXPECT $_JQ_CLAIMS_RUN_RESULTS" > "$res"
  _claims_jq run-result-rows -c '.[] | {claim, status, node, outcome, verdict, message}' "$res" \
    >> "$_SCRATCH/cl-results.jsonl"
  _claims_jq run-findings -c '.[] | select(.verdict == "finding") | {check: "run", claim, doc, message}' "$res" \
    >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq run-indeterminate -c \
    '.[] | select(.verdict == "indeterminate") | {check: "run", claim, reason: (.reason // "indeterminate")}' "$res" \
    >> "$_SCRATCH/cl-indet.jsonl"
}

# run: see the section comment. --claims takes ids (commas split them too);
# an id no claim has is a usage error. The base is never read.
# shellcheck disable=SC2016  # jq programs, not shell expansion
cmd_claims_run() {
  _CL_ALL_BLOCKING=1
  _CL_BASE_UNUSED=1
  _claims_init all
  local n=0 scheduled=0 unknown extra='{}'
  local sel="$_SCRATCH/cl-run-sel.json" list="$_SCRATCH/cl-run-list"
  if [ ${#_OPTV_claims[@]} -gt 0 ]; then n=$((n + 1)); fi
  if [ -n "$_OPT_planes_of" ]; then n=$((n + 1)); fi
  if [ "$_OPT_all" = 1 ]; then n=$((n + 1)); fi
  [ "$n" -eq 1 ] || _usage_error "claims run" "give exactly one of --claims <id>..., --planes-of <range> and --all"
  case "$_OPT_judge_sample" in
    *[!0123456789]*) _usage_error "claims run" "--judge-sample must be a whole number (got '$_OPT_judge_sample')" ;;
  esac
  _claims_no_args "claims run" "$@"
  if [ "$_OPT_scheduled" = 1 ]; then scheduled=1; fi
  _claims_load

  if [ ${#_OPTV_claims[@]} -gt 0 ]; then
    printf '%s\n' "${_OPTV_claims[@]}" > "$list"
    _claims_jq run-ids -Rsc 'split("\n") | map(split(",")[] | select(. != ""))' "$list" > "$sel"
    unknown=$(_claims_jq run-unknown -r --slurpfile c "$_SCRATCH/cl-claims.json" \
      'if length == 0 then "-" else [.[] | select(. as $i | any($c[0][]; .claim.id == $i) | not)] | unique | join(", ") end' \
      "$sel") || _claims_propagate $?
    [ "$unknown" != - ] || _usage_error "claims run" "--claims names no claim id"
    [ -z "$unknown" ] || _usage_error "claims run" "--claims: no claim has the id $unknown"
  elif [ -n "$_OPT_planes_of" ]; then
    _claims_planes_sel "$_OPT_planes_of" "$sel"
  else
    printf 'null\n' > "$sel"
  fi
  _claims_run_selected "$sel" "$scheduled"
  if [ -n "$_OPT_judge_sample" ]; then
    extra=$(_claims_judge_sample "$_OPT_judge_sample") || _claims_propagate $?
    extra="{\"judge_sample\":$extra}"
  fi
  _claims_emit run "$extra"
}

# --- Spec claims: the configuration extension (§B.1) ---------------------------
#
# Off unless config config_adapter is not null (_claims_b1_on). Off, nothing
# here runs and no config-adapter call is made: a claim's when (not null), or
# status gated, is a V1 finding ("configuration extension is off"), and a
# runner list row's when is ignored. On, the config adapter (§D, the
# contract; never extended):
#   <adapter> surfaces  → the files that carry production configuration
#   <adapter> recorded [--rev <rev> | --staged] [--override KEY=VALUE]…
#     → JSON {key: {"recorded": …, "default": …}}
#   <adapter> readers <path>…  → the keys read by code in those paths, one
#     per line
# each called, as every adapter is, through _claims_adapter_call (from the
# repo root, </dev/null 9>&-). validate calls recorded once (--staged under
# --staged; no flag, the work tree, under --all) into cl-recorded.json, which
# V1 (each when key a recorded key) and V3 share (V10 makes its own calls,
# and restores it: see "V10"); promote calls recorded --rev HEAD and writes
# gated, not built, when claims_when_ok fails there — for a built claim
# whose verdict matches, that re-gates it instead of refusing it. A
# failing call (an rc ≠ 0, 126 for a missing adapter; output that is not one
# JSON object whose every value is {recorded, default}) is indeterminate
# (check config): cl-recorded.json then holds null, and what needs it is
# skipped.
#
# V3 with the extension on: _JQ_CLAIMS_V3 checks each bound list row's when
# against the claim's; _claims_v3_config covers every eligible, touched claim
# that is neither retired nor frozen:
#   - configuration-faithful: each key that readers <subject…> reports and
#     whose recorded value differs from its default must be a key of the
#     claim's when, unless config_independent is a non-empty string. The
#     value pinned is judged by status: a built claim's must be the recorded
#     one (next rule); a gated claim's is, by definition, not;
#   - a built claim whose when the recorded configuration does not satisfy
#     is gated, not built.
# readers is called once per distinct subject list. A subject path that is
# not a safe repo path, is reached through a symbolic link or starts with
# "-" never reaches the adapter (a finding); a failing readers call makes the
# claims of that list indeterminate.
# Scratch: cl-recorded.json, cl-v3c-plan.json, cl-v3c-subjects.jsonl
# (each distinct subject list), cl-v3c-readers.jsonl ({subject, ok, keys |
# reason | unsafe} per list: _claims_readers_rows).

_CL_B1=""  # _claims_b1_on's answer, once read: 0 on, 1 off

# _claims_b1_on: 0 when the configuration extension is on (config
# config_adapter is not null). Call it in an if (it returns 1 when off), and
# first in the main shell, so a later $(…) finds the answer cached.
_claims_b1_on() {
  local x
  if [ -z "$_CL_B1" ]; then
    x=$(_claims_jq b1 -r '.config_adapter == null' "$_SCRATCH/cl-config.json") || _claims_propagate $?
    if [ "$x" = true ]; then _CL_B1=1; else _CL_B1=0; fi
  fi
  return "$_CL_B1"
}

# _claims_config_adapter: print config config_adapter (nothing when it is not
# a string: a missing adapter, which _claims_adapter_call returns 126 for).
_claims_config_adapter() {
  _claims_jq config-adapter -r '.config_adapter | strings' "$_SCRATCH/cl-config.json"
}

# _claims_recorded [--rev <rev> | --staged] [--override KEY=VALUE]…: the
# config adapter's recorded call, its object written to
# $_SCRATCH/cl-recorded.json. Returns 1, the file holding null, after an
# indeterminate row (check config): adapter-exit-<rc>, or
# malformed-adapter-output when the output is not one JSON object whose every
# value is an object with recorded and default.
_claims_recorded() {
  local rec="$_SCRATCH/cl-recorded.json" out="$_SCRATCH/cl-recorded.out" adapter rc=0
  printf 'null\n' > "$rec" || _claims_die "cannot write $rec"
  adapter=$(_claims_config_adapter) || _claims_propagate $?
  _claims_adapter_call "$out" "$adapter" recorded "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _claims_indeterminate config - "adapter-exit-$rc"
    return 1
  fi
  # Its status is the answer (malformed output), so not _claims_jq; and so
  # is empty output: jq 1.6 -s prints nothing and exits 0 on input it cannot
  # parse (a log line on stdout).
  if ! jq -c -s 'if length == 1 and (.[0] | type) == "object"
        and all(.[0][]; type == "object" and has("recorded") and has("default"))
      then .[0] else error("malformed") end' "$out" > "$rec.new" 2>/dev/null || [ ! -s "$rec.new" ]; then
    _claims_indeterminate config - malformed-adapter-output
    return 1
  fi
  cat "$rec.new" > "$rec" || _claims_die "cannot write $rec"
}

# _claims_recorded_ok: 0 when cl-recorded.json holds the recorded
# configuration (its last _claims_recorded call succeeded).
_claims_recorded_ok() {
  local x=null
  IFS= read -r x < "$_SCRATCH/cl-recorded.json" 2>/dev/null || true
  [ -n "$x" ] && [ "$x" != null ]
}

# claims_when_ok($rec), on a claim: every key of its when (none when when is
# not an object) is recorded in $rec (the recorded object) with exactly that
# value (JSON-equal). V3 and promote share it.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_WHEN='def claims_when_ok($rec):
  (.when | if type == "object" then . else {} end) as $w
  | all($w | keys_unsorted[]; . as $k | ($rec | type) == "object" and ($rec[$k] | type) == "object"
                                       and $rec[$k].recorded == $w[$k]);'

# cl-claims.json → the claims _claims_v3_config checks ($t: cl-touched.json):
# eligible, touched, neither retired nor frozen. subject is the list readers
# is called with, or null (not a non-empty list of non-empty strings: V1's
# finding, or nothing read).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3C_PLAN='def nes: type == "string" and length > 0;
 $t[0] as $touched
 | [.[] | select(.eligible and (.claim.id | type) == "string")
    | select(.claim.id as $i | any($touched[]; . == $i))
    | .doc as $doc | .claim
    | select(.status != "retired" and (.frozen_at | nes | not))
    | {claim: .id, doc: $doc, status, when, config_independent,
       subject: (if (.subject | type) == "array" and (.subject | length) > 0 and all(.subject[]; nes)
                 then .subject else null end)}]'

# The configuration-faithful checks over the plan ($plan), given $rows (the
# readers rows) and $rec (the recorded object): finding rows and
# indeterminate rows, as _JQ_CLAIMS_V3's. Run after _JQ_CLAIMS_WHEN.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3C='def v3($e; $msg): {check: "V3", claim: $e.claim, doc: $e.doc, message: $msg};
 def nes: type == "string" and length > 0;
 def cl_str: if type == "string" then . else tojson end;
 $rec[0] as $rec
 | $plan[0][] as $e
 | ($e.when | if type == "object" then . else {} end) as $w
 | (if $e.subject == null then empty
    else ([$rows[] | select(.subject == $e.subject)][0] // error("V3: no readers row for \($e.claim)")) as $r
      | if $r.unsafe != null then
          v3($e; "subject \($r.unsafe | tojson) is not a safe repo path (absolute, an empty, . or .. segment, reached through a symbolic link, or starting with \"-\"): it never reaches the config adapter (readers), so the keys it reads are unknown")
        elif ($r.ok | not) then {check: "V3", claim: $e.claim, reason: $r.reason}
        elif $e.config_independent | nes then empty
        else $r.keys[] | . as $k
          | select(($rec | has($k)) and $rec[$k].recorded != $rec[$k].default and ($w | has($k) | not))
          | v3($e; "configuration-faithful: pin \($k)=\($rec[$k].recorded | cl_str) in when or declare config_independent (the subject reads \($k), recorded as \($rec[$k].recorded | tojson) where its code default is \($rec[$k].default | tojson))")
        end
    end),
   (if $e.status == "built" and ($w | length) > 0 and ($e | claims_when_ok($rec) | not) then
      v3($e; "built but recorded configuration does not satisfy when: gated (\([$w | to_entries[]
        | select(($rec[.key] | type) != "object" or $rec[.key].recorded != .value)
        | if ($rec[.key] | type) == "object" then "\(.key) is recorded as \($rec[.key].recorded | tojson), when sets \(.value | tojson)"
          else "\(.key) is not recorded, when sets \(.value | tojson)" end]
        | join("; ")))")
    else empty end)'

# _claims_v3_config: the configuration-faithful V3 checks (see the section
# comment), after validate's recorded call succeeded.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v3_config() {
  local plan="$_SCRATCH/cl-v3c-plan.json" subj="$_SCRATCH/cl-v3c-subjects.jsonl"
  local rows="$_SCRATCH/cl-v3c-readers.jsonl" res="$_SCRATCH/cl-v3c.jsonl"
  _claims_jq v3c-plan -c --slurpfile t "$_SCRATCH/cl-touched.json" "$_JQ_CLAIMS_V3C_PLAN" \
    "$_SCRATCH/cl-claims.json" > "$plan"
  _claims_jq v3c-subjects -c '[.[] | .subject | arrays] | unique | .[]' "$plan" > "$subj"
  _claims_readers_rows "$subj" "$rows"
  _claims_jq v3c -nc --slurpfile plan "$plan" --slurpfile rows "$rows" --slurpfile rec "$_SCRATCH/cl-recorded.json" \
    "$_JQ_CLAIMS_WHEN $_JQ_CLAIMS_V3C" > "$res"
  _claims_jq v3c-findings -c 'select(has("reason") | not)' "$res" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq v3c-indeterminate -c 'select(has("reason"))' "$res" >> "$_SCRATCH/cl-indet.jsonl"
}

# _claims_readers_rows <subjects> <rows>: one config-adapter readers call per
# line of <subjects> (a JSON list of subject paths), its row written to
# <rows> (truncated first): {subject, ok: true, keys} (the lines it printed,
# trimmed, blank ones dropped, unique), {subject, ok: false, reason:
# adapter-exit-<rc>}, or {subject, ok: false, unsafe: <path>} for a path
# that is not a safe repo path, is reached through a symbolic link or starts
# with "-": it never reaches the adapter. V3 and V10 share it.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_readers_rows() {
  local subj="$1" rows="$2" out="$_SCRATCH/cl-readers-out" z="$_SCRATCH/cl-readers.z"
  local adapter line p bad rc
  local rpaths=()
  : > "$rows" || _claims_die "cannot write $rows"
  adapter=$(_claims_config_adapter) || _claims_propagate $?
  while IFS= read -r line <&3; do
    _claims_jq readers-paths -j '.[] | . + "\u0000"' <<<"$line" > "$z"
    rpaths=()
    bad=""
    while IFS= read -r -d '' p; do
      case "$p" in
        -*) bad=$p ;;
        *) if ! _claims_safe_relpath "$p" || ! _claims_contained_path "$p"; then bad=$p; fi ;;
      esac
      [ -z "$bad" ] || break
      rpaths+=("$p")
    done < "$z"
    if [ -n "$bad" ]; then
      _claims_jq readers-unsafe -nc --argjson s "$line" --arg p "$bad" '{subject: $s, ok: false, unsafe: $p}' >> "$rows"
      continue
    fi
    rc=0
    _claims_adapter_call "$out" "$adapter" readers ${rpaths[@]+"${rpaths[@]}"} || rc=$?
    _claims_jq readers-row -nRc --argjson s "$line" --argjson rc "$rc" \
      '[inputs | rtrimstr("\r") | sub("^[ \t]+"; "") | sub("[ \t]+$"; "") | select(. != "")] as $k
       | if $rc != 0 then {subject: $s, ok: false, reason: "adapter-exit-\($rc)"}
         else {subject: $s, ok: true, keys: ($k | unique)} end' < "$out" >> "$rows"
  done 3< "$subj"
}

# --- Spec claims: configuration re-classification, V10 (§B.1) -----------------
#
# With the extension on, V10 runs in validate when a staged path (--staged)
# is one of the config adapter's surfaces — equal to a line surfaces prints,
# or under it as a directory — or when --config KEY=VALUE (repeatable) is
# given; never otherwise (--all without --config: no surfaces call, no V10),
# nor without a merge-base. It compares the recorded configuration at _CL_MB
# (recorded --rev <merge-base>) with the proposed one: the staged one
# (validate's own recorded --staged call) or, under --config, recorded with
# an --override per --config, in the mode's tree (--staged under --staged,
# the work tree under --all). A changed key is one whose recorded value
# differs between the two (a key only one side records included). V10 then
# judges every eligible claim that is gated, built or diverged and not
# frozen, and whose when keys or whose subject's readers keys (one readers
# call per distinct subject list, asked only for a claim its when does not
# already select) include a changed key, against the proposed configuration
# (claims_when_ok):
#   - gated, its when now satisfied → "now satisfied: promote to built", an
#     advisory (code promote-owed, as V6's re-promote owed): never blocking,
#     for its remedy, claims promote, needs the change committed (a clean
#     tree, and HEAD's recorded configuration satisfying when);
#   - built, its when not satisfied, and no new ruling (cl_new_rulings
#     against its claim at _CL_MB, the V6/V7 definition) → "ruling owed":
#     the direction is ruled (§F) in a commit before the change (staged
#     with it, V3's "…: gated" blocks), then claims promote re-gates it;
#   - diverged, its non-empty when satisfied by the proposed configuration
#     and not by the merge-base's → "switches on a diverged claim", whatever
#     its rulings (a diverged claim carries one: honouring it would make
#     the check vacuous): the code is fixed and the claim promoted, or the
#     claim retired, before the configuration switches it on.
# A failing surfaces or recorded call is indeterminate (check config), and a
# failing readers call makes the claims it was asked for indeterminate
# (check V10); a subject path readers is never asked about (unsafe: V3's
# finding) selects nothing. validate's own recorded call having failed,
# V10 makes no call. V10 is in the default blocking list.
# Scratch: cl-v10-old.json and cl-v10-new.json (the two recorded objects;
# cl-recorded.json is restored to validate's own), cl-v10-changed.json,
# cl-v10-plan.json, cl-v10-subjects.jsonl, cl-v10-readers.jsonl.

# The changed keys ($old, $new: the two recorded objects, slurped), sorted.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V10_CHANGED='$old[0] as $o | $new[0] as $n
 | [($o | keys[]), ($n | keys[])] | unique
 | map(. as $k | select(($o | has($k)) != ($n | has($k)) or $o[$k].recorded != $n[$k].recorded))'

# cl-claims.json → the claims V10 may judge ($ch: the changed keys, $b:
# cl-claims-base.json; run after _JQ_CLAIMS_DELTA): {claim, doc, status,
# when (an object; {} when not one), ruled (a new ruling), by_when (a when
# key changed), subject (null when not a non-empty list of non-empty
# strings)}.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V10_PLAN='def nes: type == "string" and length > 0;
 $ch[0] as $ch
 | cl_base_by_id($b[0]) as $base
 | [.[] | select(.eligible and (.claim.id | type) == "string")
    | .doc as $doc | .claim
    | select(.status as $s | any("gated", "built", "diverged"; . == $s))
    | select(.frozen_at | nes | not)
    | (.when | if type == "object" then . else {} end) as $w
    | {claim: .id, doc: $doc, status, when: $w,
       ruled: ((cl_new_rulings($base[.id].claim) | length) > 0),
       by_when: any($w | keys_unsorted[]; in_list($ch)),
       subject: (if (.subject | type) == "array" and (.subject | length) > 0 and all(.subject[]; nes)
                 then .subject else null end)}]'

# V10 over the plan ($plan), given the readers rows ($rows), the two
# recorded objects ($old, $new) and the changed keys ($ch): finding rows,
# advisory rows (with a code) and indeterminate rows (with a reason). Run after _JQ_CLAIMS_DELTA and _JQ_CLAIMS_WHEN.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V10='def v10($e; $msg): {check: "V10", claim: $e.claim, doc: $e.doc, message: $msg};
 def v10a($e; $code; $msg): {check: "V10", claim: $e.claim, code: $code, message: $msg};
 def cl_str: if type == "string" then . else tojson end;
 def cl_cond: [to_entries | sort_by(.key)[] | "\(.key)=\(.value | cl_str)"] | join(", ");
 def cl_unmet($rec): [to_entries | sort_by(.key)[] | select(($rec[.key] | type) != "object" or $rec[.key].recorded != .value)
   | if ($rec[.key] | type) == "object" then "\(.key) is recorded as \($rec[.key].recorded | tojson), when sets \(.value | tojson)"
     else "\(.key) is not recorded, when sets \(.value | tojson)" end] | join("; ");
 $old[0] as $old | $new[0] as $new | $ch[0] as $ch
 | $plan[0][] as $e
 | (if $e.by_when or $e.subject == null then null
    else [$rows[] | select(.subject == $e.subject)][0] end) as $r
 | if $r != null and ($r.ok | not) and $r.unsafe == null then {check: "V10", claim: $e.claim, reason: $r.reason}
   elif $e.by_when or ($r != null and $r.ok and any($r.keys[]; in_list($ch))) then
     ({when: $e.when} | claims_when_ok($new)) as $now
     | ($e.when | length > 0) as $cond
     | if $e.status == "gated" and $cond and $now then
         v10a($e; "promote-owed"; "now satisfied: promote to built (the configuration this change records satisfies when \($e.when | cl_cond): once it is committed, run claims promote \($e.claim))")
       elif $e.status == "built" and ($now | not) and ($e.ruled | not) then
         v10($e; "ruling owed: built, but the configuration this change records no longer satisfies its when (\($e.when | cl_unmet($new))): commit a new ruling on the claim first (the direction: CODE-DIVERGES, DOC-STALE or RETIRE), then make the configuration change, then run claims promote \($e.claim), which re-gates it")
       elif $e.status == "diverged" and $cond and $now and ({when: $e.when} | claims_when_ok($old) | not) then
         v10($e; "switches on a diverged claim: the configuration this change records satisfies when \($e.when | cl_cond), which the merge-base'"'"'s did not, so production would run what the claim records as diverged: fix the code and promote the claim, or retire it, before switching the configuration on (a ruling does not answer this)")
       else empty end
   else empty end'

# _claims_v10: V10 (see the section comment), in validate after V9.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v10() {
  local rec="$_SCRATCH/cl-recorded.json" saved="$_SCRATCH/cl-v10-saved.json"
  local old="$_SCRATCH/cl-v10-old.json" new="$_SCRATCH/cl-v10-new.json" ch="$_SCRATCH/cl-v10-changed.json"
  local plan="$_SCRATCH/cl-v10-plan.json" subj="$_SCRATCH/cl-v10-subjects.jsonl"
  local rows="$_SCRATCH/cl-v10-readers.jsonl" out="$_SCRATCH/cl-v10-surfaces" res="$_SCRATCH/cl-v10.jsonl"
  local adapter x kv rc=0
  local ov=() rflag=()
  if ! _claims_b1_on || [ -z "$_CL_MB" ] || ! _claims_recorded_ok; then return 0; fi
  for kv in ${_OPTV_config[@]+"${_OPTV_config[@]}"}; do ov+=(--override "$kv"); done
  cat "$rec" > "$saved" || _claims_die "cannot write $saved"
  if [ ${#ov[@]} -eq 0 ]; then
    [ "$_CL_MODE" = staged ] || return 0
    adapter=$(_claims_config_adapter) || _claims_propagate $?
    _claims_adapter_call "$out" "$adapter" surfaces || rc=$?
    if [ "$rc" -ne 0 ]; then
      _claims_indeterminate config - "adapter-exit-$rc"
      return 0
    fi
    x=$(_claims_jq v10-surfaces -nR --slurpfile st "$_SCRATCH/cl-staged.json" \
      '[inputs | rtrimstr("\r") | sub("^[ \t]+"; "") | sub("[ \t]+$"; "") | select(. != "")] as $sf
       | any($st[0][]; . as $p | any($sf[]; . as $s | ($s | rtrimstr("/")) as $d
                                       | $p == $s or ($d != "" and ($p | startswith($d + "/")))))' < "$out") \
      || _claims_propagate $?
    [ "$x" = true ] || return 0
    cat "$saved" > "$new" || _claims_die "cannot write $new"
  else
    [ "$_CL_MODE" != staged ] || rflag=(--staged)
    if ! _claims_recorded ${rflag[@]+"${rflag[@]}"} "${ov[@]}"; then
      cat "$saved" > "$rec" || _claims_die "cannot write $rec"
      return 0
    fi
    cat "$rec" > "$new" || _claims_die "cannot write $new"
  fi
  if ! _claims_recorded --rev "$_CL_MB"; then
    cat "$saved" > "$rec" || _claims_die "cannot write $rec"
    return 0
  fi
  cat "$rec" > "$old" || _claims_die "cannot write $old"
  cat "$saved" > "$rec" || _claims_die "cannot write $rec"
  _claims_jq v10-changed -nc --slurpfile old "$old" --slurpfile new "$new" "$_JQ_CLAIMS_V10_CHANGED" > "$ch"
  x=$(_claims_jq v10-any -r 'length > 0' "$ch") || _claims_propagate $?
  [ "$x" = true ] || return 0
  _claims_jq v10-plan -c --slurpfile ch "$ch" --slurpfile b "$_SCRATCH/cl-claims-base.json" \
    "$_JQ_CLAIMS_DELTA $_JQ_CLAIMS_V10_PLAN" "$_SCRATCH/cl-claims.json" > "$plan"
  _claims_jq v10-subjects -c '[.[] | select(.by_when | not) | .subject | arrays] | unique | .[]' "$plan" > "$subj"
  _claims_readers_rows "$subj" "$rows"
  _claims_jq v10 -nc --slurpfile plan "$plan" --slurpfile rows "$rows" --slurpfile old "$old" \
    --slurpfile new "$new" --slurpfile ch "$ch" "$_JQ_CLAIMS_DELTA $_JQ_CLAIMS_WHEN $_JQ_CLAIMS_V10" > "$res"
  _claims_jq v10-findings -c 'select(has("reason") or has("code") | not)' "$res" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq v10-advisories -c 'select(has("code"))' "$res" >> "$_SCRATCH/cl-advisories.jsonl"
  _claims_jq v10-indeterminate -c 'select(has("reason"))' "$res" >> "$_SCRATCH/cl-indet.jsonl"
}

# --- Spec claims: test binding, V3 ---------------------------------------------
#
# V3 checks each eligible, touched test claim (enforced_by test, test
# {runner, node[, file]}) that is not retired. Binding (skipped for a frozen
# claim: it is validated structurally only, and run skips it): one
# `<adapter> list [<file>…]` call per runner (§D: a static scan, so
# pre-commit can afford it), naming every file of its claims — test.file when
# set, else the node's path before "::" when that is a file of the proposed
# tree (_claims_read: the index under --staged), else none, and then the
# call names no file (all files). The adapter reads the work tree whatever
# the mode, so each such file must be a safe repo path, contained
# (_claims_contained_path) in every mode, and must not start with "-" (an
# adapter would take it for an option): else a finding, and the file never
# reaches the adapter. A claim is bound when a list row has its id and its
# node; a bound row must be in_gate and subject_imports_ok (a finding
# whatever the status: Design clarifications). An adapter rc ≠ 0 (126: an
# unknown runner or a missing adapter, R6; a runner name holding a newline
# or NUL is one, as in run), or any non-blank line that is not one §D row,
# makes every claim of that call indeterminate: never a pass, never "not
# bound". Whatever the adapter says, a built or gated claim (frozen too)
# needs nonvacuity (observed_red or mutant) and a promotion. The mutant of a
# built or gated claim that is not frozen needs {file, find, replace}, its
# file a safe repo path (_claims_safe_relpath; in the work tree
# _claims_contained_path too) present in the proposed tree — an unsafe one
# is never read — and find occurring there exactly once, counted literally
# (jq split, codepoints). Neither proof of such a claim may move its bound
# test off HEAD: a mutant.file that is the test's own file, or (with an
# observed_red) a subject that is or holds it, is a finding. A diverged or
# unbuilt claim's mutant is not checked (a diverged claim's mutant no
# longer matches, by construction; promote re-verifies a mutant before a
# claim becomes built). The adapter's stderr passes through (its
# diagnostics). With the configuration extension on (§B.1), every bound row's
# when must hold each when pair of the claim (the test establishes the
# condition the claim declares), and _claims_v3_config adds the
# configuration-faithful checks; off, a row's when is ignored.
#
# Scratch: cl-v3-plan.json (one entry per checked claim), cl-v3-paths.jsonl
# ({path, safe, exists} per candidate file), cl-v3-calls.jsonl ({runner,
# files} per list call), cl-v3-lists.jsonl ({runner, ok, reason, rows} per
# call) and cl-v3-mutants.jsonl ({i, state, n} per checked mutant).

# Shared by V3 and promote: the bound test's own files (cl_test_files:
# test.file, and the node's path before "::"), which a nonvacuity proof must
# leave at HEAD. cl_mutant_is_test($tf; $node), on a mutant.file — it is one of them:
# a mutant of the test's expectation proves nothing. cl_subject_holds_test,
# on a subject path — it is one of them or a directory holding one: an
# observed_red proof checks each subject out as at its commit, and would
# take the test back with it. Each with its finding's message.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_MUTANT_DEFS='def cl_test_files($tf; $node): [($tf | strings), ($node | strings | split("::")[0])];
 def cl_mutant_is_test($tf; $node): . as $f | any(cl_test_files($tf; $node)[]; . == $f);
 def cl_mutant_test_msg: "nonvacuity.mutant.file \(.) is the bound test'"'"'s own file: a mutant of the test'"'"'s expectation proves nothing; mutate the subject";
 def cl_subject_holds_test($tf; $node): . as $p | any(cl_test_files($tf; $node)[]; . == $p or startswith($p + "/"));
 def cl_subject_test_msg: "subject \(.) is, or holds, the bound test'"'"'s own file: observed_red checks each subject out as at its commit, and the test must stay at HEAD; name only the code under test";'

# Shared by the V3 programs. cl_plain: no newline or NUL (the shell reads
# names and paths NUL- or newline-separated). cl_v3_bind($pp), on a plan
# entry given the cl-v3-paths rows by path: what binding does with it —
# {skip} (frozen), {indet: <reason>}, {finding: <message>} or {arg: <file or
# null>} (in its runner's list call) — the one decision the call builder and
# the checks share. cl_v3_mutant_checked: the entry's mutant is checked.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3_DEFS=$_JQ_CLAIMS_MUTANT_DEFS'
 def nes: type == "string" and length > 0;
 def cl_plain: (split("\n") | length) <= 1 and (split("\u0000") | length) <= 1;
 def cl_unsafe: "(absolute, an empty, . or .. segment, or reached through a symbolic link)";
 def cl_mutant_ok: type == "object" and (.file | nes) and (.find | nes) and (.replace | type) == "string";
 def cl_mutant: .nonvacuity | if type == "object" then .mutant else null end;
 def cl_v3_mutant_checked: (.status == "built" or .status == "gated") and (.frozen | not);
 def cl_v3_bind($pp):
   if .frozen then {skip: true}
   elif .runner | cl_plain | not then {indet: "adapter-exit-126"}
   elif .file != null then
     (if $pp[.file].safe != true
      then {finding: "test.file \(.file) is not a safe repo path \(cl_unsafe): name the test file by its path from the repo root"}
      elif .file | startswith("-")
      then {finding: "test.file \(.file) starts with \"-\": an adapter would read it as an option; rename the test file"}
      else {arg: .file} end)
   elif $pp[.prefix].exists == true then
     (if .prefix | startswith("-")
      then {finding: "test file \(.prefix) (the node path before ::) starts with \"-\": an adapter would read it as an option; rename the test file"}
      else {arg: .prefix} end)
   else {arg: null} end;'

# cl-claims.json → the plan: the claims V3 checks ($t: cl-touched.json), in
# sidecar order.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3_PLAN='$t[0] as $touched
 | [.[] | select(.eligible and (.claim.id | type) == "string")
    | select(.claim.id as $i | any($touched[]; . == $i))
    | .doc as $doc | .claim
    | select(.enforced_by == "test" and .status != "retired")
    | select((.test | type) == "object" and (.test.runner | nes) and (.test.node | nes))
    | {claim: .id, doc: $doc, status, frozen: (.frozen_at | nes), runner: .test.runner, node: .test.node,
       file: (if .test.file | nes then .test.file else null end),
       prefix: (.test.node | split("::")[0]), subject, nonvacuity, promotion, when}]'

# The plan, with $paths (the cl-v3-paths rows) → one {runner, files} line
# per list call (cl_v3_bind's {arg} entries): files [] (all files) when a
# claim of the runner has none.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3_CALLS='(reduce $paths[] as $p ({}; .[$p.path] = $p)) as $pp
 | [.[] | . + cl_v3_bind($pp) | select(has("arg"))]
 | group_by(.runner)[]
 | {runner: .[0].runner, files: (if any(.[]; .arg == null) then [] else [.[].arg] | unique end)}'

# The plan → "<i>\0<mutant.file>\0" per checked entry whose mutant is well
# shaped and whose file is plain: the mutants the shell reads.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3_MUTANTS='range(length) as $i | .[$i] | select(cl_v3_mutant_checked) | cl_mutant
 | select(cl_mutant_ok and (.file | cl_plain)) | "\($i)\u0000\(.file)\u0000"'

# A list call's stdout ($out: its lines, -R) and rc → {ok, reason, rows}.
# ok only when the rc is 0 and every non-blank line is one §D row: a JSON
# object with string id and node, boolean in_gate and subject_imports_ok, a
# string file when present, and when an object or null.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PARSE_LIST='def row: type == "object" and (.id | type) == "string" and (.node | type) == "string"
   and (.in_gate | type) == "boolean" and (.subject_imports_ok | type) == "boolean"
   and ((has("file") | not) or (.file | type) == "string")
   and ((.when | type) == "object" or .when == null);
 [inputs | rtrimstr("\r") | select(test("[^ \t]")) | (try {v: fromjson} catch {bad: true})] as $lines
 | if $rc != 0 then {ok: false, reason: "adapter-exit-\($rc)", rows: []}
   elif all($lines[]; has("v") and (.v | row)) then {ok: true, reason: null, rows: [$lines[].v]}
   else {ok: false, reason: "malformed-adapter-output", rows: []} end'

# _claims_parse_list <out-file> <rc>: print the {ok, reason, rows} object of
# a list call (_JQ_CLAIMS_PARSE_LIST). Both are required: a missing or
# non-integer <rc> dies (exit 2), as for _claims_parse_run.
_claims_parse_list() {
  _claims_rc_arg _claims_parse_list "${2-}"
  _claims_jq parse-list -ncR --argjson rc "$2" "$_JQ_CLAIMS_PARSE_LIST" < "$1"
}

# V3 over the plan ($plan), given $paths, $lists ({runner, ok, reason, rows}
# per call), $mut ({i, state: unsafe | absent | count, n}) and $b1 (the
# configuration extension is on): finding rows {check, claim, doc, message}
# and indeterminate rows {check, claim, reason}.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V3='def v3($e; $msg): {check: "V3", claim: $e.claim, doc: $e.doc, message: $msg};
 $plan[0] as $plan
 | (reduce $paths[] as $p ({}; .[$p.path] = $p)) as $pp
 | (reduce $lists[] as $l ({}; .[$l.runner] = $l)) as $calls
 | (reduce $mut[] as $m ({}; .[$m.i | tostring] = $m)) as $muts
 | range($plan | length) as $i | $plan[$i] as $e
 | ($e | cl_v3_bind($pp)) as $bind
 | (if $bind.skip then empty
    elif $bind.indet != null then {check: "V3", claim: $e.claim, reason: $bind.indet}
    elif $bind.finding != null then v3($e; $bind.finding)
    else
      ($calls[$e.runner] // error("V3: no list call for runner \($e.runner)")) as $c
      | if $c.ok | not then {check: "V3", claim: $e.claim, reason: $c.reason}
        else [$c.rows[] | select(.id == $e.claim and .node == $e.node)] as $b
          | if ($b | length) == 0 then
              v3($e; "test not bound: the list of runner \($e.runner) reports no test at \($e.node) binding itself to \($e.claim) (the test declares its claim id: a pytest marker, a jest helper, …)")
            else
              (if any($b[]; .in_gate == false)
               then v3($e; "bound test \($e.node) is outside the test gate (in_gate: false): the host test run never runs it")
               else empty end),
              (if any($b[]; .subject_imports_ok == false)
               then v3($e; "bound test \($e.node) imports its subject at module level (subject_imports_ok: false): an unbuilt subject would be a collection error no expected failure can absorb; import it inside the test")
               else empty end),
              (if $b1 and ($e.when | type) == "object" then
                 $e.when | to_entries[] | . as $w
                 | select(all($b[]; (.when | type) == "object" and (.when | has($w.key)) and .when[$w.key] == $w.value) | not)
                 | v3($e; "test does not establish when \($w.key): the list of runner \($e.runner) reports \($e.node) setting it to \([$b[].when | if type == "object" and has($w.key) then .[$w.key] | tojson else "nothing" end] | unique | join(" or ")), the claim declares \($w.value | tojson) (the bound test sets the condition itself)")
               else empty end)
            end
        end
    end),
   (if $e.status == "built" or $e.status == "gated" then
      ($e.nonvacuity | if type == "object" then . else {} end) as $nv
      | (if ($nv.observed_red | nes) or ($nv.mutant | type) == "object" then empty
         else v3($e; "\($e.status) without nonvacuity: a \($e.status) test claim proves its test can fail (observed_red <sha>, or mutant {file, find, replace}); claims promote records it") end),
        (if ($e.promotion | type) == "object" then empty
         else v3($e; "\($e.status) without promotion: claims promote is the only path into \($e.status)") end)
    else empty end),
   ($e | select(cl_v3_mutant_checked) | cl_mutant | select(type == "object") | . as $m
    | if cl_mutant_ok | not then
        v3($e; "nonvacuity.mutant must be {file, find, replace}: three strings, file and find non-empty")
      elif $m.file | cl_mutant_is_test($e.file; $e.node) then
        v3($e; $m.file | cl_mutant_test_msg)
      elif $m.file | cl_plain | not then
        v3($e; "nonvacuity.mutant.file \($m.file | tojson) is not a safe repo path \(cl_unsafe): it is never read")
      else ($muts[$i | tostring] // error("V3: no mutant row for plan entry \($i)")) as $r
        | if $r.state == "unsafe" then
            v3($e; "nonvacuity.mutant.file \($m.file) is not a safe repo path \(cl_unsafe): it is never read")
          elif $r.state == "absent" then
            v3($e; "nonvacuity.mutant.file \($m.file) is not in the proposed tree")
          elif $r.n != 1 then
            v3($e; "nonvacuity.mutant.find occurs \($r.n) times in \($m.file) (counted literally): it must match exactly once")
          else empty end
      end),
   ($e | select(cl_v3_mutant_checked)
    | select(.nonvacuity | type == "object" and (.observed_red | nes))
    | .subject | arrays | .[] | strings | select(cl_subject_holds_test($e.file; $e.node))
    | v3($e; cl_subject_test_msg))'

# V3 (see the section comment): the plan; each candidate file's safety and
# presence; one list call per runner; each mutant file read and counted;
# then one jq for the rows. The shell loops run over those short lists.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v3() {
  local plan="$_SCRATCH/cl-v3-plan.json" paths="$_SCRATCH/cl-v3-paths.jsonl" calls="$_SCRATCH/cl-v3-calls.jsonl"
  local lists="$_SCRATCH/cl-v3-lists.jsonl" muts="$_SCRATCH/cl-v3-mutants.jsonl" z="$_SCRATCH/cl-v3.z"
  local filesz="$_SCRATCH/cl-v3-files.z" out="$_SCRATCH/cl-v3-out" one="$_SCRATCH/cl-v3-one.json"
  local mraw="$_SCRATCH/cl-v3-mutant.raw" res="$_SCRATCH/cl-v3.jsonl"
  local p safe exists call runner adapter rc i f state n b1
  local files=()
  : > "$paths"
  : > "$lists"
  : > "$muts"
  _claims_jq v3-plan -c --slurpfile t "$_SCRATCH/cl-touched.json" "$_JQ_CLAIMS_V3_DEFS $_JQ_CLAIMS_V3_PLAN" \
    "$_SCRATCH/cl-claims.json" > "$plan"

  # Each candidate file (test.file, else the node's path) of a claim that is
  # not frozen, once. Contained in every mode: the adapter reads the work tree.
  _claims_jq v3-paths -j '[.[] | select(.frozen | not) | .file // .prefix] | unique | .[] | . + "\u0000"' \
    "$plan" > "$z"
  while IFS= read -r -d '' p <&3; do
    safe=false
    exists=false
    if _claims_safe_relpath "$p" && _claims_contained_path "$p"; then
      safe=true
      if _claims_read "$p" >/dev/null; then exists=true; fi
    fi
    _claims_jq v3-path-row -nc --arg p "$p" --argjson s "$safe" --argjson e "$exists" \
      '{path: $p, safe: $s, exists: $e}' >> "$paths"
  done 3< "$z"

  # One list call per runner, its files as separate arguments.
  _claims_jq v3-calls -c --slurpfile paths "$paths" "$_JQ_CLAIMS_V3_DEFS $_JQ_CLAIMS_V3_CALLS" "$plan" > "$calls"
  while IFS= read -r call <&3; do
    runner=$(_claims_jq v3-runner -j '.runner' <<<"$call") || _claims_propagate $?
    _claims_jq v3-files -j '.files[] | . + "\u0000"' <<<"$call" > "$filesz"
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < "$filesz"
    adapter=$(_claims_runner_adapter "$runner") || _claims_propagate $?
    rc=0
    _claims_adapter_call "$out" "$adapter" list ${files[@]+"${files[@]}"} || rc=$?
    _claims_parse_list "$out" "$rc" > "$one"
    _claims_jq v3-list-row -c --argjson call "$call" '. + {runner: $call.runner}' "$one" >> "$lists"
  done 3< "$calls"

  # Each checked mutant's file: unsafe (never read), absent, or find's count.
  _claims_jq v3-mutants -j "$_JQ_CLAIMS_V3_DEFS $_JQ_CLAIMS_V3_MUTANTS" "$plan" > "$z"
  while IFS= read -r -d '' i <&3 && IFS= read -r -d '' f <&3; do
    state=count
    n=0
    if ! _claims_safe_relpath "$f" || { [ "$_CL_MODE" = all ] && ! _claims_contained_path "$f"; }; then
      state=unsafe
    elif ! _claims_read "$f" > "$mraw"; then
      state=absent
    else
      n=$(_claims_jq v3-count -Rsr --slurpfile plan "$plan" --argjson i "$i" \
        '$plan[0][$i].nonvacuity.mutant.find as $f | if . == "" then 0 else (split($f) | length) - 1 end' \
        "$mraw") || _claims_propagate $?
    fi
    _claims_jq v3-mutant-row -nc --argjson i "$i" --arg s "$state" --argjson n "$n" \
      '{i: $i, state: $s, n: $n}' >> "$muts"
  done 3< "$z"

  b1=false
  if _claims_b1_on; then b1=true; fi
  _claims_jq v3 -nc --slurpfile plan "$plan" --slurpfile paths "$paths" --slurpfile lists "$lists" \
    --slurpfile mut "$muts" --argjson b1 "$b1" "$_JQ_CLAIMS_V3_DEFS $_JQ_CLAIMS_V3" > "$res"
  _claims_jq v3-findings -c 'select(has("reason") | not)' "$res" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq v3-indeterminate -c 'select(has("reason"))' "$res" >> "$_SCRATCH/cl-indet.jsonl"
  if [ "$b1" = true ] && _claims_recorded_ok; then _claims_v3_config; fi
}

# --- Spec claims: lint, V4 -------------------------------------------------------
#
# A lint claim (enforced_by lint) carries lint {pattern, paths, expect,
# selftest: {violates, clean}}; V1 owns its shape, and a lint that is not
# well shaped (cl_lint_ok) is left to V1 here. The check is
# _claims_lint_eval: grep -E for the pattern (a pattern holding a newline is
# several patterns to grep, any one matching), pass when expect is present
# and it matches, or expect is absent and it does not. V4 checks each
# eligible, touched lint claim that is not retired. Each selftest string,
# written to a scratch file as a line (cl_as_line: its text and a newline,
# unless it ends in one — so "" is one empty line, which .* matches, never
# a 0-byte file no pattern matches), must fail (violates) and pass (clean)
# the lint: else "vacuous pattern". Then its lint.paths files in the
# proposed tree (_claims_read: the index under --staged) are concatenated
# (_claims_lint_tree) and evaluated: a built or gated claim's lint must
# pass, a diverged claim's fail, an unbuilt claim's either; anything else
# contradicts the status. Each path must be a safe repo path
# (_claims_safe_relpath; in the work tree _claims_contained_path too): else
# a finding whatever the status, the path is never read, and the lint is not
# evaluated. Each must be a file of the proposed tree too: else a finding —
# except for an unbuilt claim, where an absent file is an allowed failure
# (the status table: unbuilt is "any failure, or no check yet"), so its lint
# evaluates as fail. A frozen claim is validated structurally: its path
# strings go through _claims_safe_relpath, and nothing is read or
# evaluated. A pattern grep -E rejects (grep exit 2, not 1: no match) is a
# finding, "invalid pattern" (cl_invalid_pattern), never a pass or a fail;
# so is a pattern holding a NUL byte, which no argument can carry. claims
# run evaluates the same tree, the working tree's, for each lint claim
# (pass → pass, fail → assert-fail; an unsafe path, an absent one of a claim
# that is not unbuilt, or an invalid pattern is a finding there too, not
# indeterminate).
#
# Scratch: cl-v4-plan.json (one entry per checked claim), cl-v4-rows.jsonl
# ({i, violates, clean, tree, bad} per entry), cl-v4-violates and
# cl-v4-clean (the selftests), cl-lint-tree (the concatenated paths) and
# cl-lint-bad.jsonl (a {message} row per unusable path).

# Shared by V4 and run. cl_lint_ok: a lint V1 accepts. cl_nonul: no NUL
# byte (the shell reads these values NUL-separated, and grep takes the
# pattern as an argument). cl_as_line: a selftest string as the line written
# for grep. cl_invalid_pattern / cl_nul_pattern: on a lint, the finding
# message validate and run both report.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_LINT_DEFS='def cl_lint_ok: type == "object"
   and (.pattern | type) == "string" and .pattern != ""
   and (.paths | type) == "array" and (.paths | length) > 0
   and all(.paths[]; type == "string" and . != "")
   and (.expect == "present" or .expect == "absent")
   and (.selftest | type) == "object"
   and (.selftest.violates | type) == "string" and (.selftest.clean | type) == "string";
 def cl_nonul: (split("\u0000") | length) <= 1;
 def cl_as_line: if endswith("\n") then . else . + "\n" end;
 def cl_invalid_pattern: "invalid pattern: grep -E rejects lint.pattern \(.pattern | tojson): fix the pattern";
 def cl_nul_pattern: "invalid pattern: lint.pattern holds a NUL byte, which grep cannot take";'

# _claims_lint_eval <pattern> <expect> <file>: print pass or fail. With
# expect present, pass when grep -Eq -- <pattern> <file> matches; with
# absent, when it does not. grep's exit 1 is "no match"; any other failure
# (2: an invalid pattern, an unreadable file), or an expect that is neither,
# returns 2 and prints nothing: never a pass or a fail.
_claims_lint_eval() {
  local rc=0
  grep -Eq -- "$1" "$3" 2>/dev/null || rc=$?
  case "$rc:$2" in
    0:present|1:absent) echo pass ;;
    1:present|0:absent) echo fail ;;
    *) return 2 ;;
  esac
}

# _claims_lint_tree <entries-file> <i>: the lint.paths files of entry <i> of
# <entries-file> (a JSON array of entries holding a cl_lint_ok .lint, a
# status and, for V4, frozen), concatenated into cl-lint-tree, a newline
# after each file that lacks one (no line of one file runs into the next's).
# Returns 0 when every path was read; 1 when a path is unusable — not a safe
# repo path (in the work tree: contained too), or, for a claim that is not
# unbuilt, not a file of the proposed tree (_claims_read, by mode) — each
# such path never read and named by a {message} row in cl-lint-bad.jsonl;
# 2 when every path is safe but one is absent and the claim is unbuilt (its
# allowed failure: the lint evaluates as fail). A frozen entry's paths get
# _claims_safe_relpath alone (a string check): nothing is read, and it
# returns 0 or 1. A NUL in a path is written as the text \u0000, so the path
# names no file.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_lint_tree() {
  local tree="$_SCRATCH/cl-lint-tree" bad="$_SCRATCH/cl-lint-bad.jsonl" one="$_SCRATCH/cl-lint-one"
  local z="$_SCRATCH/cl-lint-paths.z" p msg nl status frozen absent=0 rc=0
  local unsafe="is not a safe repo path (absolute, an empty, . or .. segment, or reached through a symbolic link): it is never read"
  : > "$tree"
  : > "$bad"
  _claims_jq lint-paths -j --argjson i "$2" '.[$i] | "\(.status)\u0000\(.frozen == true)\u0000",
      (.lint.paths[] | split("\u0000") | join("\\u0000") | . + "\u0000")' "$1" > "$z"
  {
    if ! { IFS= read -r -d '' status <&4 && IFS= read -r -d '' frozen <&4; }; then
      _claims_die "lint-paths: no status for entry $2"
    fi
    while IFS= read -r -d '' p <&4; do
      msg=""
      if [ "$frozen" = true ]; then
        _claims_safe_relpath "$p" || msg="lint.paths entry $p $unsafe"
      elif ! _claims_safe_relpath "$p" || { [ "$_CL_MODE" = all ] && ! _claims_contained_path "$p"; }; then
        msg="lint.paths entry $p $unsafe"
      elif ! _claims_read "$p" > "$one"; then
        if [ "$status" = unbuilt ]; then absent=1; else msg="lint.paths entry $p is not a file in the proposed tree"; fi
      else
        cat "$one" >> "$tree" || _claims_die "cannot write $tree"
        nl=$(tail -c 1 "$one" | wc -l)
        if [ -s "$one" ] && [ $((nl)) -eq 0 ]; then printf '\n' >> "$tree"; fi
      fi
      if [ -n "$msg" ]; then
        rc=1
        _claims_jq lint-bad -nc --arg m "$msg" '{message: $m}' >> "$bad"
      fi
    done
  } 4< "$z"
  if [ "$rc" = 0 ] && [ "$absent" = 1 ]; then rc=2; fi
  return "$rc"
}

# cl-claims.json → the plan: the lint claims V4 checks ($t: cl-touched.json),
# in sidecar order.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V4_PLAN='$t[0] as $touched
 | [.[] | select(.eligible and (.claim.id | type) == "string")
    | select(.claim.id as $i | any($touched[]; . == $i))
    | .doc as $doc | .claim
    | select(.enforced_by == "lint" and .status != "retired" and (.lint | cl_lint_ok))
    | {claim: .id, doc: $doc, status, frozen: ((.frozen_at | type) == "string" and .frozen_at != ""), lint}]'

# V4 over the plan ($plan) and its rows ($rows: {i, violates, clean: pass |
# fail | error; tree: pass | fail | "" (not evaluated); bad: messages}) →
# finding rows. Run after _JQ_CLAIMS_LINT_DEFS.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V4='def v4($e; $msg): {check: "V4", claim: $e.claim, doc: $e.doc, message: $msg};
 $plan[0] as $plan
 | $rows[] | . as $r | $plan[$r.i] as $e | $e.lint as $l
 | "lint (grep -E \($l.pattern | tojson), expect \($l.expect))" as $lint
 | ($l.paths | join(", ")) as $paths
 | if $r.violates == "error" or $r.clean == "error" then
     v4($e; $l | cl_invalid_pattern)
   else
     (if $r.violates == "pass"
      then v4($e; "vacuous pattern: selftest.violates passes the \($lint): the pattern cannot catch the violation it is for")
      else empty end),
     (if $r.clean == "fail"
      then v4($e; "vacuous pattern: selftest.clean fails the \($lint): the pattern flags conforming code")
      else empty end),
     ($r.bad[] | v4($e; .)),
     (if ($e.status == "built" or $e.status == "gated") and $r.tree == "fail" then
        v4($e; "pattern contradicts status: a \($e.status) claim'"'"'s lint must pass, but it fails over \($paths): \($lint)")
      elif $e.status == "diverged" and $r.tree == "pass" then
        v4($e; "pattern contradicts status: a diverged claim'"'"'s lint must fail (the code diverges from states), but it passes over \($paths): \($lint); if the code now does what states says, move it to built (a reviewed status edit: claims promote proves test claims only)")
      else empty end)
   end'

# V4 (see the section comment): the plan; per entry, the selftests and
# (pattern valid) the paths checked and (not frozen) evaluated in the shell;
# then one jq for the findings. The shell loop runs over that short list.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v4() {
  local plan="$_SCRATCH/cl-v4-plan.json" rows="$_SCRATCH/cl-v4-rows.jsonl" z="$_SCRATCH/cl-v4.z"
  local vio="$_SCRATCH/cl-v4-violates" cln="$_SCRATCH/cl-v4-clean"
  local i pattern expect frozen v c t rc
  : > "$rows"
  _claims_jq v4-plan -c --slurpfile t "$_SCRATCH/cl-touched.json" "$_JQ_CLAIMS_LINT_DEFS $_JQ_CLAIMS_V4_PLAN" \
    "$_SCRATCH/cl-claims.json" > "$plan"
  _claims_jq v4-nul -c "$_JQ_CLAIMS_LINT_DEFS"' .[] | select(.lint.pattern | cl_nonul | not)
      | {check: "V4", claim, doc, message: (.lint | cl_nul_pattern)}' \
    "$plan" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq v4-entries -j "$_JQ_CLAIMS_LINT_DEFS"' range(length) as $i | .[$i] | select(.lint.pattern | cl_nonul)
      | "\($i)\u0000\(.lint.pattern)\u0000\(.lint.expect)\u0000\(.frozen)\u0000"' "$plan" > "$z"
  while IFS= read -r -d '' i <&3 && IFS= read -r -d '' pattern <&3 \
      && IFS= read -r -d '' expect <&3 && IFS= read -r -d '' frozen <&3; do
    _claims_jq v4-violates -j --argjson i "$i" "$_JQ_CLAIMS_LINT_DEFS"' .[$i].lint.selftest.violates | cl_as_line' \
      "$plan" > "$vio"
    _claims_jq v4-clean -j --argjson i "$i" "$_JQ_CLAIMS_LINT_DEFS"' .[$i].lint.selftest.clean | cl_as_line' \
      "$plan" > "$cln"
    v=$(_claims_lint_eval "$pattern" "$expect" "$vio") || v=error
    c=$(_claims_lint_eval "$pattern" "$expect" "$cln") || c=error
    t=""
    : > "$_SCRATCH/cl-lint-bad.jsonl"
    if [ "$v" != error ] && [ "$c" != error ]; then
      rc=0
      _claims_lint_tree "$plan" "$i" || rc=$?
      if [ "$rc" = 2 ]; then
        t=fail
      elif [ "$rc" = 0 ] && [ "$frozen" = false ]; then
        t=$(_claims_lint_eval "$pattern" "$expect" "$_SCRATCH/cl-lint-tree") \
          || _claims_die "grep failed evaluating the lint of plan entry $i over its paths"
      fi
    fi
    _claims_jq v4-row -nc --argjson i "$i" --arg v "$v" --arg c "$c" --arg t "$t" \
      --slurpfile bad "$_SCRATCH/cl-lint-bad.jsonl" '{i: $i, violates: $v, clean: $c, tree: $t, bad: [$bad[].message]}' \
      >> "$rows"
  done 3< "$z"
  _claims_jq v4 -nc --slurpfile plan "$plan" --slurpfile rows "$rows" "$_JQ_CLAIMS_LINT_DEFS $_JQ_CLAIMS_V4" \
    >> "$_SCRATCH/cl-findings.jsonl"
}

# --- Spec claims: normative coverage, V8 ----------------------------------------
#
# V8 lists the normative text of a governing doc that no claim covers.
# _claims_sections classes each line of a doc by the heading it sits under;
# _claims_added_lines names the lines a change added. A line examined — an
# added one under --staged and over a gate range, every one under --all — is
# uncovered when it is
#   - normative, its live normalised text (claims_doc's: struck text and the
#     status block are not live) holds a letter or a digit, and no claim of
#     the doc has an occurrence of its normalised quote — the
#     quote_occurrence-th, or any one without quote_occurrence — whose span
#     hits the line (claims_occ, claims_lines_hit);
#   - openq, and a data row of a table (outside code fences: a row holding
#     a "|", a delimiter row under it, then each following row holding a
#     "|") whose header row names a column matching
#     resolved|resolution|answer|decision (the first such, case-insensitive),
#     that cell's normalised text is not empty, and no claim's normalised
#     quote is a substring of it, nor holds it in an occurrence that hits
#     this row's line (a short cell, "No.", is in many a quote elsewhere).
# Each is one finding row "<doc>:<line>: normative text no claim covers"
# (claim null). V8 is not in the default blocking list, so validate reports
# its findings as advisories (_JQ_CLAIMS_EMIT); gate (_CL_ALL_BLOCKING)
# blocks on them. The docs examined:
#   --staged  each staged path that is governing and present in the index;
#   --all     each eligible doc with a sidecar (cl-sidecars.json skip null),
#             read in the work tree only through a safe, contained path;
#   <range>   each path of the range's path set (_claims_range_paths) that
#             is governing and present at the range's end: a doc outside the
#             set is the branch's no more than trunk's.
# The claims are those of cl-claims.json whose doc is the doc examined. The
# heading EREs of the config (normative_headings, descriptive_headings) must
# each be a non-empty string awk compiles: otherwise V8 does not run, and is
# indeterminate, naming the key. Scratch: cl-v8-*, cl-sec-*, cl-added-*.

# The default normative headings (Design clarifications), matched against
# the whole lower-cased heading text by awk; an ADR's Decision is among them.
_CL_V8_DEFAULT_RE='^(design|requirements?|invariants?|interfaces?|inputs?|outputs?|inputs? and outputs?|decisions?|.*(phase|stage) contracts?)$'

_CL_SEC_STATE=""  # "" until _claims_sections_init runs; then ok, or why the heading EREs are unusable
_CL_SEC_NORM=""   # config normative_headings, lower-cased by awk, one per line
_CL_SEC_DESC=""   # config descriptive_headings, the same

# _claims_sections_init: read and check the config's heading EREs once (in
# the main shell). 0 when they are usable; else 1, with _CL_SEC_STATE the
# reason (a value that is not an array of non-empty strings, an entry
# holding a newline, or one awk cannot compile once lower-cased: awk's own
# dialect, under LC_ALL=C, is the host ERE's definition).
_claims_sections_init() {
  local key list p rc
  if [ -n "$_CL_SEC_STATE" ]; then
    [ "$_CL_SEC_STATE" = ok ]
    return
  fi
  for key in normative_headings descriptive_headings; do
    list=$(_claims_jq sections-res -r --arg k "$key" \
      '.[$k] | if type != "array" then "!not an array"
               elif any(.[]; type != "string") then "!holds a value that is not a string"
               elif any(.[]; . == "") then "!holds an empty string"
               elif any(.[]; test("\n")) then "!holds an entry with a newline"
               else .[] end' "$_SCRATCH/cl-config.json") || _claims_propagate $?
    case "$list" in
      '!'*)
        _CL_SEC_STATE="config $key ${list#!}: it must be a list of EREs"
        return 1
        ;;
    esac
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      rc=0
      CL_SEC_RE=$p LC_ALL=C awk 'BEGIN { if ("" ~ tolower(ENVIRON["CL_SEC_RE"])) n = 1; exit 0 }' \
        </dev/null >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        _CL_SEC_STATE="config $key: '$p' is not an ERE awk can compile"
        return 1
      fi
    done <<EOF
$list
EOF
    if [ "$key" = normative_headings ]; then _CL_SEC_NORM=$list; else _CL_SEC_DESC=$list; fi
  done
  _CL_SEC_STATE=ok
}

# A raw doc (on _JQ_CLAIMS_NORM) → one line per doc line for the awk pass,
# "<c><TAB><text>": c "s" in a status block (claims_status_ranges), "f" in
# a code fence or a fence delimiter (claims_fence_kinds), else "o". CRLF
# reads as LF; a final newline ends the last line, opening none.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_SECTIONS='gsub("\r\n"; "\n") | (if endswith("\n") then .[:-1] else . end) as $t
 | ($t | claims_status_ranges) as $r
 | ($t | claims_fence_kinds) as $k
 | range(0; $k | length) as $i
 | (if any($r[]; .[0] <= $i and $i <= .[1]) then "s" elif $k[$i].k == "out" then "o" else "f" end)
   + "\t" + $k[$i].t'

# The awk pass of _claims_sections (see its comment), on _JQ_CLAIMS_SECTIONS'
# lines; the EREs in ENVIRON (CL_SEC_NORM, CL_SEC_DESC: one per line;
# CL_SEC_DEFAULT). cls[1..6] holds each heading level's class.
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_CLAIMS_SECTIONS='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function cur(    i) { for (i = 6; i >= 1; i--) if (cls[i] != "") return cls[i]; return "other" }
function hclass(x,    l, i) {
  l = tolower(x)
  for (i = 1; i <= nd; i++) if (l ~ dre[i]) return "descriptive"
  for (i = 1; i <= nn; i++) if (l ~ nre[i]) return "normative"
  sub(/^[0-9]+(\.[0-9]+)*\.?[ \t]+/, "", l)
  gsub(/[*_`]/, "", l)
  l = trim(l)
  sub(/[ \t]*:$/, "", l)
  if (l ~ /^open questions?$/) return "openq"
  if (l ~ /^implementation notes?$/) return "descriptive"
  if (l ~ defre) return "normative"
  return ""
}
BEGIN {
  nn = split(ENVIRON["CL_SEC_NORM"], nre, "\n")
  nd = split(ENVIRON["CL_SEC_DESC"], dre, "\n")
  for (i = 1; i <= nn; i++) nre[i] = tolower(nre[i])
  for (i = 1; i <= nd; i++) dre[i] = tolower(dre[i])
  defre = ENVIRON["CL_SEC_DEFAULT"]
  pend = 0
}
{
  c = substr($0, 1, 1)
  t = substr($0, 3)
  if (c == "s") { print NR "\tother"; next }
  if (c == "f") { pend = 0; print NR "\t" cur(); next }
  if (t ~ /^[ \t]*$/) { print NR "\t" cur(); next }
  if (pend && t ~ /^ ? ? ?<!-- spec-claims:descriptive -->[ \t]*$/) {
    cls[pend] = "descriptive"
    pend = 0
    print NR "\tother"
    next
  }
  pend = 0
  s = t
  k = 0
  while (k < 3 && substr(s, 1, 1) == " ") { s = substr(s, 2); k++ }
  h = 0
  while (h < 7 && substr(s, h + 1, 1) == "#") h++
  if (h >= 1 && h <= 6 && (length(s) == h || substr(s, h + 1, 1) == " " || substr(s, h + 1, 1) == "\t")) {
    x = trim(substr(s, h + 1))
    if (x ~ /^#+$/) x = ""
    else sub(/[ \t]+#+$/, "", x)
    cls[h] = hclass(x)
    for (i = 1; i < h; i++) if (cls[i] == "descriptive") cls[h] = "descriptive"
    for (i = h + 1; i <= 6; i++) cls[i] = ""
    pend = h
    print NR "\tother"
    next
  }
  if (t ~ /^[ \t]*<!--/ && t ~ /-->[ \t]*$/) {
    x = t
    sub(/^[ \t]*<!--/, "", x)
    sub(/-->[ \t]*$/, "", x)
    if (index(x, "-->") == 0) { print NR "\tother"; next }
  }
  print NR "\t" cur()
}'

# _claims_sections <doc-file>: the class of each line of the raw doc
# <doc-file>, one "<line><TAB><class>" per line, class normative,
# descriptive, openq or other. The same lines as claims_doc's: CRLF reads as
# LF, and a final newline opens no line. An ATX heading (up to three spaces,
# one to six #, then a space, a tab or the line's end) outside a code fence
# — the one fence rule, claims_fence_kinds, applied by a jq pass before the
# awk one, so a ``` line inside a ```` fence stays fenced — sets its level's
# class and clears every deeper level's. A line takes the class of the
# deepest level that has one (a ### heading with none of its own inherits
# its parent's: Requirements' subsections are normative), else other.
# Descriptive is sticky downward: under a descriptive heading every deeper
# heading is descriptive, whatever its text (an Interfaces subsection of
# Implementation Notes describes; it does not specify). Otherwise a
# heading's class, from its text (closing #s dropped; compared lower-cased):
#   1. descriptive, when a <!-- spec-claims:descriptive --> line (up to three
#      leading spaces) follows it before any other non-blank line;
#   2. descriptive, when a config descriptive_headings ERE matches it;
#   3. normative, when a config normative_headings ERE matches it;
#   4. the whole text, a leading section number ("3.", "3.1") and *, _ and `
#      removed and a final ":" dropped: open questions? → openq;
#      implementation notes? → descriptive; _CL_V8_DEFAULT_RE → normative.
# The heading line itself, the marker line, a line that is one HTML comment
# and nothing else (a template's placeholder) and every line of a status block (markers
# included; a heading inside it is not read) are other. A fenced line takes
# the class it sits under. Run _claims_sections_init first: an unusable ERE
# dies here.
_claims_sections() {
  local pre="$_SCRATCH/cl-sec.pre"
  _claims_sections_init || _claims_die "$_CL_SEC_STATE"
  _claims_jq sections -Rsr "$_JQ_CLAIMS_NORM $_JQ_CLAIMS_SECTIONS" "$1" > "$pre"
  CL_SEC_NORM=$_CL_SEC_NORM CL_SEC_DESC=$_CL_SEC_DESC CL_SEC_DEFAULT=$_CL_V8_DEFAULT_RE \
    LC_ALL=C awk "$_AWK_CLAIMS_SECTIONS" "$pre" || _claims_die "awk failed classing the sections of $1"
}

_CL_ADDED_RANGE=""  # the range whose merges _claims_added_lines has read
_CL_ADDED_A=""      # its <a> and <b>, full commit ids
_CL_ADDED_B=""

# The config git blame reads, pinned: no clone's ignore list (and its
# markers), root or boundary setting, or indent heuristic changes which
# commit a line is blamed on. With --no-ignore-revs-file, --no-textconv and
# --diff-algorithm=myers on the command line, and no -w, -M or -C. The empty
# blame.ignoreRevsFile alone does not clear a clone's list (git sorts the
# files, so the reset is read first): --no-ignore-revs-file does.
_CL_BLAME_CFG=(-c blame.ignoreRevsFile= -c blame.markUnblamableLines=false -c blame.markIgnoredLines=false
  -c blame.showRoot=false -c blame.blankBoundary=false -c diff.indentHeuristic=true)

# `git blame --porcelain` → the final line numbers of the lines blamed on a
# commit that is neither a boundary nor listed in ENVIRON["CL_SKIP"] (one id
# per line). A header line is "<id> <orig> <final>[ <count>]"; a commit's
# keys (boundary among them) follow its first header only; a line's text
# follows a TAB.
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_CLAIMS_BLAME='
BEGIN { n = split(ENVIRON["CL_SKIP"], s, "\n"); for (i = 1; i <= n; i++) if (s[i] != "") skip[s[i]] = 1 }
/^[0-9a-f]+ [0-9]+ [0-9]+( [0-9]+)?$/ && length($1) >= 40 { id = $1; fl = $3; next }
$0 == "boundary" { bnd[id] = 1; next }
/^\t/ { if (!(id in bnd) && !(id in skip)) print fl }'

# _claims_added_lines <doc> --staged | <range>: the numbers of the lines
# <doc> gains, one per line.
#   --staged  the new-side lines of each hunk of the doc's staged change
#             against HEAD (the empty tree before the first commit): `git
#             diff -U0 --cached` (_CL_DIFF_OPTS, then --unified=0), its
#             "@@ -a,b +c,d @@" headers read by awk (c..c+d-1; d is 1 when
#             absent).
#   <range>   (a gate's <from>..HEAD, by the range rule) the lines of the doc
#             at the range's end that `git blame --first-parent --porcelain
#             <a>..<b>` (_CL_BLAME_CFG) blames on a commit in the range:
#             every line numbered as it stands at <b> — never in one commit's
#             post-image — and no boundary line. A line blamed on a
#             first-parent merge counts only when the doc is one of that
#             merge's hand resolutions (_claims_merge_files): trunk's lines,
#             merged in cleanly, are not the branch's; inside a resolved doc
#             every line the merge brought counts (conservative). The doc
#             must be present at <b>. The range's merges and their
#             resolutions are read once per range (cl-added-*).
# A git or awk failure dies (exit 2): an added set that could not be read
# is never taken as empty.
_claims_added_lines() {
  local doc="$1" how="$2" raw="$_SCRATCH/cl-added.raw" ms="$_SCRATCH/cl-added-merges" base m p hit skip=""
  if [ "$how" = --staged ]; then
    base=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || base=$(_claims_empty_tree) \
      || _claims_propagate $?
    git -c core.quotePath=true --literal-pathspecs diff --cached "${_CL_DIFF_OPTS[@]}" --unified=0 \
      "$base" -- "$doc" > "$raw" 2>/dev/null || _claims_die "git diff --cached failed reading the added lines of $doc"
    LC_ALL=C awk '/^@@ / {
        s = $3
        sub(/^\+/, "", s)
        n = split(s, p, ",")
        d = (n > 1) ? p[2] + 0 : 1
        for (i = 0; i < d; i++) print p[1] + i
      }' "$raw" || _claims_die "awk failed reading the hunks of $doc"
    return 0
  fi
  if [ "$_CL_ADDED_RANGE" != "$how" ]; then
    _claims_range_merges "$how" "$ms"
    _CL_ADDED_A=$_CL_RANGE_A
    _CL_ADDED_B=$_CL_RANGE_B
    while IFS= read -r m <&3; do
      _claims_merge_files "$m" "$_SCRATCH/cl-added-mf-$m"
    done 3< "$ms"
    _CL_ADDED_RANGE=$how
  fi
  while IFS= read -r m <&3; do
    hit=0
    while IFS= read -r -d '' p; do
      if [ "$p" = "$doc" ]; then hit=1; break; fi
    done < "$_SCRATCH/cl-added-mf-$m"
    if [ "$hit" = 0 ]; then skip="$skip$m"$'\n'; fi
  done 3< "$ms"
  git "${_CL_BLAME_CFG[@]}" blame --porcelain --first-parent --no-ignore-revs-file --no-textconv --diff-algorithm=myers \
    "$_CL_ADDED_A..$_CL_ADDED_B" -- "$doc" > "$raw" 2>/dev/null \
    || _claims_die "git blame failed reading the added lines of $doc over $how"
  CL_SKIP=$skip LC_ALL=C awk "$_AWK_CLAIMS_BLAME" "$raw" || _claims_die "awk failed reading the blame of $doc"
}

# V8 over one doc (raw on stdin; run after _JQ_CLAIMS_NORM): $doc its path,
# $sec its _claims_sections lines, $added its added line numbers (one per
# line) unless $all is 1 (every line), $c cl-claims.json. $qs: each claim's
# normalised quote and the lines its occurrence(s) hit. One finding row per
# uncovered line (see the section comment).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V8='def cl_cells: sub("^[ \t]*\\|"; "") | sub("\\|[ \t]*$"; "") | split("|");
 def cl_delim_row: test("^[ \t]*\\|?[ \t]*:?-+:?[ \t]*(\\|[ \t]*:?-+:?[ \t]*)*\\|?[ \t]*$");
 claims_doc as $d
 | (claims_live | split("\n")) as $live
 | (gsub("\r\n"; "\n") | claims_fence_kinds) as $src
 | (reduce ($sec | split("\n")[] | select(. != "") | split("\t")) as $x ({}; .[$x[0]] = $x[1])) as $cls
 | [$c[0][] | select(.doc == $doc) | .claim
    | select(type == "object" and (.quote | type) == "string")
    | {q: (.quote | claims_norm), k: .quote_occurrence} | select(.q != "")
    | . as $x
    | .lines = [if ($x.k | type) == "number" then $d | claims_lines_hit($x.q; $x.k)[]
                else ($d | claims_occ($x.q) | length) as $n | range(1; $n + 1) as $j
                  | $d | claims_lines_hit($x.q; $j)[] end]] as $qs
 | (reduce $qs[].lines[] as $n ({}; .[$n | tostring] = true)) as $hit
 | (reduce range(0; $live | length) as $i ({hdr: null, col: null, body: false, rows: {}};
      $live[$i] as $t
      | if $src[$i].k != "out" or ($t | test("\\|") | not) then .hdr = null | .col = null | .body = false
        elif .body then
          (if .col == null then . else .rows[($i + 1) | tostring] = (($t | cl_cells)[.col] // "" | claims_norm_line) end)
        elif .hdr != null and ($t | cl_delim_row) then
          .body = true
          | .col = (first(.hdr | to_entries[]
              | select(.value | claims_norm_line | ascii_downcase | test("resolved|resolution|answer|decision")) | .key) // null)
        else .hdr = ($t | cl_cells) | .col = null end)
    | .rows) as $rows
 | (if $all == 1 then range(1; ($live | length) + 1)
    else $added | split("\n")[] | select(. != "") | tonumber end) as $n
 | ($n | tostring) as $s
 | select(
     ($cls[$s] == "normative" and ($live[$n - 1] // "" | claims_norm_line | test("[[:alnum:]]")) and ($hit[$s] | not))
     or ($cls[$s] == "openq" and (($rows[$s] // "") as $cell
           | $cell != "" and (any($qs[]; .q as $q
               | ($cell | contains($q)) or (($q | contains($cell)) and any(.lines[]; . == $n))) | not))))
 | {check: "V8", claim: null, doc: $doc, message: "\($doc):\($n): normative text no claim covers"}'

# _claims_sect_scan <V8|V8n> --staged | --all | <range> <findings-file>:
# the doc loop V8 and V8n share (see the section comments), run over the
# docs of <how> with the jq program of <check> (_JQ_CLAIMS_V8, or
# _JQ_CLAIMS_V8N): each doc is read, classed (_claims_sections) and its
# added lines named (_claims_added_lines) the same way, and both programs
# get the same arguments (V8n alone reads $sc, the DOC-IDs). The finding
# rows go to <findings-file>.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_sect_scan() {
  local check="$1" how="$2" dest="$3" cand="$_SCRATCH/cl-v8-cand.z" docs="$_SCRATCH/cl-v8-docs.z"
  local raw="$_SCRATCH/cl-v8-doc.raw" sec="$_SCRATCH/cl-v8-sec.tsv" added="$_SCRATCH/cl-v8-added" all=0 end="" doc prog
  case "$check" in
    V8) prog=$_JQ_CLAIMS_V8 ;;
    V8n) prog=$_JQ_CLAIMS_V8N ;;
    *) _claims_die "_claims_sect_scan: unknown check $check" ;;
  esac
  if ! _claims_sections_init; then
    _claims_indeterminate "$check" - "$_CL_SEC_STATE"
    return 0
  fi
  case "$how" in
    --staged)
      _claims_jq v8-staged -j '.[] | select((split("\u0000") | length) == 1) | . + "\u0000"' \
        "$_SCRATCH/cl-staged.json" > "$cand" ;;
    --all)
      all=1
      _claims_jq v8-sidecar-docs -j '.[] | select(.skip == null) | .doc | strings
          | select((split("\u0000") | length) == 1) | . + "\u0000"' "$_SCRATCH/cl-sidecars.json" > "$cand" ;;
    *)
      _claims_range_paths "$how" "$cand"
      end=$_CL_RANGE_B ;;
  esac
  # The NUL list reaches jq as a file, never as argv.
  _claims_jq v8-docs -Rsj 'split("\u0000") | map(select(. != "")) | unique | .[] | . + "\u0000"' "$cand" > "$docs"
  while IFS= read -r -d '' doc <&3; do
    _claims_safe_relpath "$doc" || continue
    case "$how" in
      --staged)
        _claims_is_governing "$doc" || continue
        _claims_read "$doc" > "$raw" || continue
        _claims_added_lines "$doc" --staged > "$added"
        ;;
      --all)
        _claims_contained_path "$doc" || continue
        _claims_read "$doc" > "$raw" || continue
        : > "$added"
        ;;
      *)
        _claims_is_governing "$doc" || continue
        _claims_read_at "$end" "$doc" > "$raw" || continue
        _claims_added_lines "$doc" "$how" > "$added"
        ;;
    esac
    [ "$all" = 1 ] || [ -s "$added" ] || continue
    _claims_sections "$raw" > "$sec"
    _claims_jq "$check" -Rsc --arg doc "$doc" --argjson all "$all" --rawfile sec "$sec" --rawfile added "$added" \
      --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile sc "$_SCRATCH/cl-sidecars.json" \
      "$_JQ_CLAIMS_NORM $prog" "$raw" >> "$dest"
  done 3< "$docs"
}

# _claims_v8 --staged | --all | <range> [<findings-file>]: V8 (see the
# section comment), its finding rows added to <findings-file> (default the
# verdict's findings). validate passes --staged or --all; gate passes
# "<from>..HEAD" and its own file (the record's checks.V8).
_claims_v8() {
  _claims_sect_scan V8 "$1" "${2:-$_SCRATCH/cl-findings.jsonl}"
}

# --- Spec claims: descriptive conformance lines, V8n ----------------------------
#
# V8n lists the descriptive text that asserts conformance with nothing
# behind it. The lines examined are V8's (_claims_sect_scan: the added ones
# under --staged and over a gate range, every one under --all, of the same
# docs), but of class descriptive: Implementation Notes, a section under the
# <!-- spec-claims:descriptive --> marker, a host descriptive_headings
# match, and every heading below one. Such a line is a conformance line when
# its live normalised text (claims_norm_line: emphasis and code marks
# stripped, blockquote markers dropped) matches, in any case,
#   as specified|conforms|aligned with|matches §|implemented per
# No other wording is read: a pointer at a normative section ("see
# §Interfaces") is never flagged. The claim ids of the line (its citations)
# are the tokens
#   <P>#[a-z0-9][a-z0-9-]*      <P> a run of [A-Za-z0-9_.-]
# matched exactly, in that case (jq regex, "g": not a shell glob, whose
# bracket ranges collate by locale), each starting at a boundary: not after
# a letter, digit, _, ., /, # or - (an Oniguruma lookbehind, in jq 1.6 too),
# so a path (docs/README#install) or a URL (/API#intro) holds no token, and
# whose <P> is a DOC-ID: the DOC-ID of a proposed sidecar's doc
# (cl-sidecars.json's doc_id, a governing_extra file stem included), or of
# the ADR or SPEC id shape (ADR-[0-9]+, SPEC-[A-Z]+-[0-9]+, whole). Any other
# token — README#install, C#sharp, a word's tail (fooBAR#x), a file anchor
# (guide.md#setup) — is no citation. A known id is the id of a claim of any
# sidecar in the proposed tree (cl-claims.json, retired claims included).
#   - Each distinct unknown id of a conformance line is one finding, "cites
#     unknown claim <id>", whatever else the line carries.
#   - A conformance line with no id at all is one finding, "asserts
#     conformance with no claim id or (unverified)", unless it holds the
#     text (unverified), exactly.
#   - So a known id (or "(unverified)") exempts the line from the second
#     finding only: a mistyped id beside a good one is still reported.
# V8n is not in the default blocking list, so validate reports its findings
# as advisories; gate (_CL_ALL_BLOCKING) blocks on them. A heading ERE that
# is unusable makes V8n indeterminate, as it does V8 (_claims_sections_init).

# V8n over one doc (raw on stdin; run after _JQ_CLAIMS_NORM): the same
# arguments as _JQ_CLAIMS_V8, and $sc (cl-sidecars.json: the DOC-IDs).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V8N='(claims_live | split("\n")) as $live
 | (reduce ($sec | split("\n")[] | select(. != "") | split("\t")) as $x ({}; .[$x[0]] = $x[1])) as $cls
 | [$c[0][] | .claim | objects | .id | strings] as $known
 | [$sc[0][] | .doc_id | strings] as $docids
 | (if $all == 1 then range(1; ($live | length) + 1)
    else $added | split("\n")[] | select(. != "") | tonumber end) as $n
 | select($cls[$n | tostring] == "descriptive")
 | ($live[$n - 1] // "" | claims_norm_line) as $t
 | select($t | test("as specified|conforms|aligned with|matches \u00a7|implemented per"; "i"))
 | ([$t | match("(?<![A-Za-z0-9_./#-])([A-Za-z0-9_.-]+)#[a-z0-9][a-z0-9-]*"; "g")
     | select(.captures[0].string as $p
         | ($p | test("^(ADR-[0-9]+|SPEC-[A-Z]+-[0-9]+)$")) or any($docids[]; . == $p))
     | .string] | unique) as $ids
 | ($ids - $known) as $unknown
 | ($unknown[] | {check: "V8n", claim: null, doc: $doc, message: "\($doc):\($n): cites unknown claim \(.)"}),
   (select(($ids | length) == 0 and ($t | contains("(unverified)") | not))
    | {check: "V8n", claim: null, doc: $doc,
       message: "\($doc):\($n): descriptive line asserts conformance with no claim id or (unverified)"})'

# _claims_v8n --staged | --all | <range> [<findings-file>]: V8n (see the
# section comment), its finding rows added to <findings-file> (default the
# verdict's findings). validate passes --staged or --all; gate passes
# "<from>..HEAD" and its own file (the record's checks.V8n).
_claims_v8n() {
  _claims_sect_scan V8n "$1" "${2:-$_SCRATCH/cl-findings.jsonl}"
}

# --- Spec claims: claim-bound test edits, V9 ------------------------------------
#
# V9 lists the claims whose bound tests a change edits, to be adjudicated:
# states still holds (gate --holds <id> --by <principal>), or a ruling. Each
# configured runner's adapter is called `edited-bound-tests <arg>` (§D), <arg> being
# --staged under validate --staged, <merge-base>..HEAD under validate --all
# (skipped when _CL_MB is empty: _claims_init's base-unresolvable row covers
# it) and <from>..HEAD under gate. It prints one claim id per line. Each id
# of a claim in the proposed tree (cl-claims.json) is one V9 finding, however
# many runners or lines name it; any other id is ignored. A call that exits
# non-zero (126: a missing adapter, R6) or prints a line that is no plausible
# id (empty, or holding a CR or a NUL) is indeterminate (adapter-exit-<rc>,
# malformed-adapter-output), and its ids are not used: an edit list that
# could not be read is never taken as empty. V9 is not in the default
# blocking list, so validate reports its findings as advisories (central, in
# _JQ_CLAIMS_EMIT); gate (_CL_ALL_BLOCKING) blocks on them.
# A range (validate --all, gate) is read by the range rule (see "The range
# rule"): the adapter is handed the range string (§D's contract), so when the
# range holds a first-parent merge — the one case in which its plain diff
# differs from the branch's own work — each id is checked against the
# range's path set (_claims_range_paths): a claim whose bound test files
# (cl_test_files) are all files at the range's end, none of them in the path
# set, was edited only by trunk merged in, and is the advisory
# outside-branch-work instead of a finding. A claim with a test file that is
# not a file there (a node naming no path) stays a finding: nothing shows it
# is not the branch's. Scratch: cl-v9-calls.jsonl, one {ok, reason, ids} per
# call; cl-v9-rows.jsonl, the rows before that check.

# An edited-bound-tests call's stdout ($out: its lines, -R), its rc and $nul
# (1: the output holds a NUL byte) → {ok, reason, ids}.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V9_PARSE='[inputs] as $lines
 | if $rc != 0 then {ok: false, reason: "adapter-exit-\($rc)", ids: []}
   elif $nul == 1 or any($lines[]; . == "" or (split("\r") | length) > 1)
   then {ok: false, reason: "malformed-adapter-output", ids: []}
   else {ok: true, reason: null, ids: $lines} end'

# The calls ($calls) over cl-claims.json (.) → the V9 finding rows, one per
# known claim id an ok call printed, each with the claim's bound test files
# (files: cl_test_files, for the range rule's check). Run after
# _JQ_CLAIMS_MUTANT_DEFS.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V9='([$calls[] | select(.ok) | .ids[]] | unique) as $ids
 | [.[] | select((.claim | type) == "object" and (.claim.id | type) == "string")
        | select(.claim.id as $i | any($ids[]; . == $i))]
 | unique_by(.claim.id)[]
 | {check: "V9", claim: .claim.id, doc, message: $msg,
    files: (.claim.test | if type == "object" then cl_test_files(.file; .node) else [] end)}'

# The V9 rows (.) of a range with a first-parent merge, given $paths (its
# path set) and $at (the bound test files that are files at its end), both
# slurped ($pathsf, $atf): a row whose files are all in $at and none in
# $paths → the advisory outside-branch-work ($out "advisories"); every other
# row → the finding ($out "findings"). files dropped.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V9_RANGE='def in_list($l): . as $x | any($l[]; . == $x);
 $pathsf[0] as $paths | $atf[0] as $at
 | ((.files | length) > 0 and all(.files[]; in_list($at)) and (any(.files[]; in_list($paths)) | not)) as $trunk
 | if $out == "advisories" then
     select($trunk) | {check, claim, code: "outside-branch-work",
       message: "bound test edited only by trunk merged into the range (\(.files | join(", ")) is in none of the branch'"'"'s own commits): not this branch'"'"'s change"}
   else select($trunk | not) | del(.files) end'

# _claims_v9 <arg> [<findings-file>]: V9 over one edited-bound-tests call
# per configured runner (see the section comment), its finding rows added to
# <findings-file> (default the verdict's findings), its advisories and
# indeterminate rows to the verdict's. validate passes --staged or
# "$_CL_MB..HEAD"; gate passes "<from>..HEAD" and its own file, to tell the
# held ids apart.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v9() {
  local arg="$1" dest="${2:-$_SCRATCH/cl-findings.jsonl}" z="$_SCRATCH/cl-v9-runners.z" out="$_SCRATCH/cl-v9-out"
  local calls="$_SCRATCH/cl-v9-calls.jsonl" rows="$_SCRATCH/cl-v9-rows.jsonl" ms="$_SCRATCH/cl-v9-merges"
  local pz="$_SCRATCH/cl-v9-paths.z" fz="$_SCRATCH/cl-v9-files.z" pj="$_SCRATCH/cl-v9-paths.json"
  local aj="$_SCRATCH/cl-v9-at.json" afz="$_SCRATCH/cl-v9-at.z" runner adapter rc nul p
  local atfiles=()
  : > "$calls"
  # A runner name holding a NUL cannot reach the shell: a missing adapter.
  _claims_jq v9-nul-runners -c '.runners | objects | keys[] | select((split("\u0000") | length) > 1)
      | {ok: false, reason: "adapter-exit-126", ids: []}' "$_SCRATCH/cl-config.json" >> "$calls"
  _claims_jq v9-runners -j '.runners | objects | keys[] | select((split("\u0000") | length) <= 1) | . + "\u0000"' \
    "$_SCRATCH/cl-config.json" > "$z"
  while IFS= read -r -d '' runner <&3; do
    adapter=$(_claims_runner_adapter "$runner") || _claims_propagate $?
    rc=0
    _claims_adapter_call "$out" "$adapter" edited-bound-tests "$arg" || rc=$?
    nul=0
    if ! LC_ALL=C tr -d '\000' < "$out" | cmp -s - "$out"; then nul=1; fi
    _claims_jq v9-parse -ncR --argjson rc "$rc" --argjson nul "$nul" "$_JQ_CLAIMS_V9_PARSE" < "$out" >> "$calls"
  done 3< "$z"
  _claims_jq v9-indeterminate -c 'select(.ok | not) | {check: "V9", claim: null, reason}' "$calls" \
    >> "$_SCRATCH/cl-indet.jsonl"
  _claims_jq v9 -c --slurpfile calls "$calls" \
    --arg msg "bound test edited: adjudicate (states still holds → gate --holds <id> --by <principal>, else a ruling)" \
    "$_JQ_CLAIMS_MUTANT_DEFS $_JQ_CLAIMS_V9" "$_SCRATCH/cl-claims.json" > "$rows"
  if [ "$arg" != --staged ] && [ -s "$rows" ]; then
    _claims_range_merges "$arg" "$ms"
  else
    : > "$ms"
  fi
  if [ ! -s "$ms" ]; then
    _claims_jq v9-rows -c 'del(.files)' "$rows" >> "$dest"
    return 0
  fi
  # The range rule: the path set, and which bound test files are files at
  # the range's end (_CL_RANGE_B, set by _claims_range_merges).
  _claims_range_paths "$arg" "$pz"
  # The NUL lists reach jq as files, never as argv: jq reads an option-like
  # argument (a file named --arg) as an option even after --args.
  _claims_jq v9-paths -Rsc 'split("\u0000") | map(select(. != ""))' "$pz" > "$pj"
  _claims_jq v9-files -j '.files[] | select((split("\u0000") | length) == 1) | . + "\u0000"' "$rows" > "$fz"
  while IFS= read -r -d '' p; do
    if _claims_safe_relpath "$p" && [ "$(git cat-file -t "$_CL_RANGE_B:$p" 2>/dev/null)" = blob ]; then atfiles+=("$p"); fi
  done < "$fz"
  for p in ${atfiles[@]+"${atfiles[@]}"}; do printf '%s\0' "$p"; done > "$afz"
  _claims_jq v9-at -Rsc 'split("\u0000") | map(select(. != ""))' "$afz" > "$aj"
  _claims_jq v9-range-findings -c --slurpfile pathsf "$pj" --slurpfile atf "$aj" --arg out findings \
    "$_JQ_CLAIMS_V9_RANGE" "$rows" >> "$dest"
  _claims_jq v9-range-advisories -c --slurpfile pathsf "$pj" --slurpfile atf "$aj" --arg out advisories \
    "$_JQ_CLAIMS_V9_RANGE" "$rows" >> "$_SCRATCH/cl-advisories.jsonl"
}

# --- Spec claims: the plan parser, V12 -------------------------------------------
#
# A plan is a file matching one of config plans. _claims_plan_parse reads one
# — from the index, the work tree or a commit — and prints its structure:
#   {path, stem, completed, chunked, specs: [{path, role}],
#    chunks: [{n, tasks: [{title, kind, line, claims, claims_none, files, links}]}]}
# Fenced lines are blanked first, by the one fence rule (claims_fence_kinds:
# CommonMark pairing, so a ``` line inside a ```` fence stays fenced), CRLF
# read as LF and line numbers kept; an awk pass then emits one TSV record per
# recognised line, and jq assembles them:
#   - `## Chunk <n>:` opens chunk n (chunked true). Without one (chunked
#     false; spec-inject then treats each `### Task` as a chunk boundary),
#     each impl task opens chunk 1, 2, … in order, and the injected tasks
#     after it belong to it.
#   - `### Task <x>: <title>`: kind by the title, compared with the
#     _CL_*_TITLE constants as fixed strings: gate (starts with
#     _CL_GATE_TITLE_PREFIX; its chunk is the digits before ")"),
#     final-gate, spec-update, amendment (starts with _CL_AMEND_TITLE_PREFIX),
#     finalize; any other title is impl — an orchestrator's own task
#     ("Reuse gate (chunk N)") included. A task runs to the next task, chunk
#     or level-1/2 heading.
#   - in a task, `**Claims:** <ids, comma-separated>` or `**Claims:** none —
#     <reason>` (claims / claims_none); `- Create|Modify|Test: \`<path>\``
#     (the line's first backticked path, a :N-M suffix stripped: files; prose
#     after it is not a file); and
#     on every other line of the task, its title included, each path-like
#     token starting with one of config source_doc_patterns (links). A Files
#     line is not a link: a task editing an issue or a design doc does not
#     take its behaviour from it.
#   - specs: the `- <path> — <target|constraint|amends|infer>` lines of each
#     `**Specs**` block (it ends at a blank line after its items, or at any
#     other line), and the front matter's `governing_specs:` items
#     `- <path>[:role]` (no suffix: infer); each {path, role} pair once.
#   - completed: a `**Status**: Completed` / `**Status:** Completed` line,
#     or front matter `status: completed` (any case).
#
# V12 (validate) checks each plan staged (--staged; a staged deletion is not
# checked) or present in the work tree (--all) that has governing specs and
# is new (absent at _CL_MB) or gate-carrying (a gate or final-gate task); a
# pre-claims plan edited later is exempt, and so is every plan without
# governing specs. With _CL_MB unresolvable (already indeterminate), only a
# gate-carrying plan is checked, and not its move to Completed. Findings:
#   - chunked: a spec-update task with no gate task for its chunk (the gate's
#     chunk number equal to the chunk's) before it in the chunk; chunkless:
#     a spec-update task whose immediately preceding task is not its chunk's
#     gate;
#   - a finalize task with no final-gate task before it;
#   - an unbuilt claim (cl-claims.json) of a target or infer spec named on
#     no task's Claims line;
#   - an impl task whose files include a code path (_claims_is_code_path)
#     without a Claims line;
#   - an impl task with Claims none that has links (the decision must be
#     promoted into a governing doc first);
#   - a move to Completed (completed now, and not at _CL_MB or the plan
#     absent there) that docs/spec-claims/gates/<stem>/final.json (read
#     from the proposed tree) does not cover (_claims_v12_final).
# A plan already completed at _CL_MB is history: none of these checks runs
# on it, staged or not.
# Scratch: cl-plan.* (the parser's raw, masked and record files),
# cl-plans.z (the plan list, _claims_plan_paths), cl-v12-* (the parses, the code
# paths, the final record).

# The injected task titles (references/spec-lifecycle-actions.md,
# spec-inject --phase=plan), one single-quoted line each: the parser passes
# them to awk with -v and compares them as fixed strings, never as a regex.
_CL_GATE_TITLE_PREFIX='Claims gate (chunk '
_CL_FINAL_GATE_TITLE='Final claims gate'
_CL_SPEC_UPDATE_TITLE='Update governing specs for this chunk'
_CL_AMEND_TITLE_PREFIX='Land the spec amendment for '
_CL_FINALIZE_TITLE='Finalize all governing specs'

_CL_CODE_READY=0  # 1: _CL_CODE_ROOTS holds config code_roots
_CL_CODE_ROOTS="" # config code_roots, one per line
_CL_V12_FINAL=""  # _claims_v12_final's answer

# Read config code_roots once, in the main shell (so a later $(…) finds
# them set).
_claims_code_init() {
  [ "$_CL_CODE_READY" = 0 ] || return 0
  _CL_CODE_ROOTS=$(_claims_jq code-roots -r \
    '.code_roots | if type == "array" then .[] | strings | select(. != "" and (test("\n") | not)) else empty end' \
    "$_SCRATCH/cl-config.json") || _claims_propagate $?
  _CL_CODE_READY=1
}

# _claims_is_code_path <path>: 0 when <path> is code. With config
# code_roots empty, every path outside docs/; otherwise a path matching a
# code_roots entry as a glob (_claims_glob_match) or as a prefix (the entry
# itself, or under it as a directory).
_claims_is_code_path() {
  local r
  _claims_code_init
  if [ -z "$_CL_CODE_ROOTS" ]; then
    case "$1" in
      docs/*) return 1 ;;
    esac
    return 0
  fi
  while IFS= read -r r; do
    if _claims_glob_match "$1" "$r"; then return 0; fi
    r=${r%/}
    [ -n "$r" ] || continue
    [ "$1" != "$r" ] || return 0
    case "$1" in
      "$r"/*) return 0 ;;
    esac
  done <<EOF
$_CL_CODE_ROOTS
EOF
  return 1
}

# A plan (on _JQ_CLAIMS_NORM) → the same lines, CRLF read as LF and every
# fenced line (a fence's delimiters and its content) blanked.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PLAN_MASK='gsub("\r\n"; "\n") | claims_fence_kinds | map(if .k == "out" then .t else "" end) | join("\n")'

# The masked plan → TSV records: C <n> (a chunk), T <line> <kind> <title> (a
# task), E (a heading ending the task), L <value> (a Claims line), F <path>,
# K <path> (a link), S <path> <role> (a governing spec), D (completed). The
# titles arrive with -v (gp, fg, su, ap, fz), the source_doc_patterns in
# ENVIRON["CL_PLAN_PATTERNS"], one per line. Run under LC_ALL=C (bytes: the
# em dash is matched as its UTF-8 bytes).
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_CLAIMS_PLAN='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function links(s,    tok, i) {
  while (match(s, /[A-Za-z0-9_.\/~+-]+/)) {
    tok = substr(s, RSTART, RLENGTH)
    s = substr(s, RSTART + RLENGTH)
    sub(/^\.\//, "", tok)
    sub(/\.+$/, "", tok)
    for (i = 1; i <= npat; i++)
      if (pat[i] != "" && index(tok, pat[i]) == 1) { print "K\t" tok; break }
  }
}
BEGIN { npat = split(ENVIRON["CL_PLAN_PATTERNS"], pat, "\n"); fm = 0; intask = 0; specs = 0 }
{ sub(/\r$/, ""); gsub(/\t/, " ") }
NR == 1 && /^---[ ]*$/ { fm = 1; next }
fm == 1 {
  if ($0 ~ /^(---|\.\.\.)[ ]*$/) { fm = 2; next }
  if ($0 ~ /^[^ #-]/) fmlist = 0
  if (tolower($0) ~ /^status[ ]*:[ ]*["\047]?completed["\047]?[ ]*$/) print "D"
  if ($0 ~ /^governing_specs[ ]*:[ ]*$/) { fmlist = 1; next }
  if (fmlist && $0 ~ /^[ ]*-[ ]+/) {
    v = $0
    sub(/^[ ]*-[ ]+/, "", v)
    v = trim(v)
    sub(/^["\047]/, "", v)
    sub(/["\047]$/, "", v)
    role = "infer"
    if (match(v, /:(target|constraint|amends|infer)$/)) { role = substr(v, RSTART + 1); v = substr(v, 1, RSTART - 1) }
    if (v != "") print "S\t" v "\t" role
  }
  next
}
tolower($0) ~ /^[ ]*([-+*][ ]+)?\*\*status(\*\*:|:\*\*)[ ]*completed([^a-z]|$)/ { print "D" }
specs {
  if ($0 ~ /^- [^ ]+ — (target|constraint|amends|infer)[ ]*$/) {
    p = $0
    sub(/^- /, "", p)
    r = p
    sub(/ — .*$/, "", p)
    gsub(/`/, "", p)
    sub(/^.* — /, "", r)
    print "S\t" p "\t" trim(r)
    seen = 1
    next
  }
  if ($0 ~ /^[ ]*$/) { if (seen) specs = 0; next }
  specs = 0
}
/^\*\*Specs\*\*/ { specs = 1; seen = 0; next }
/^## Chunk [0-9]+:/ {
  n = $0
  sub(/^## Chunk /, "", n)
  sub(/:.*$/, "", n)
  print "C\t" n
  intask = 0
  next
}
/^##? / || /^##?$/ { if (intask) print "E"; intask = 0; next }
/^### Task [^:]+: / {
  t = $0
  sub(/^### Task [^:]+: /, "", t)
  t = trim(t)
  kind = "impl"
  if (index(t, gp) == 1) kind = "gate"
  else if (t == fg) kind = "final-gate"
  else if (t == su) kind = "spec-update"
  else if (index(t, ap) == 1) kind = "amendment"
  else if (t == fz) kind = "finalize"
  print "T\t" NR "\t" kind "\t" t
  intask = 1
  links(t)
  next
}
!intask { next }
/^\*\*Claims:\*\* / {
  v = $0
  sub(/^\*\*Claims:\*\* /, "", v)
  print "L\t" trim(v)
  links(v)
  next
}
/^- (Create|Modify|Test): `[^`]+`/ {
  v = $0
  match(v, /`[^`]+`/)
  p = substr(v, RSTART + 1, RLENGTH - 2)
  sub(/:[0-9]+(-[0-9]+)?$/, "", p)
  print "F\t" p
  next
}
{ links($0) }'

# _claims_plan_parse's records (read with -R) → the plan object (see the
# section comment). L, F and K belong to the last task (the awk pass emits
# them only inside one).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PLAN='def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
 [inputs | select(. != "") | split("\t")] as $r
 | any($r[]; .[0] == "C") as $chunked
 | reduce $r[] as $x ({chunks: [], specs: [], completed: false};
     ((.chunks | length) - 1) as $c
     | if $x[0] == "C" then .chunks += [{n: ($x[1] | tonumber), tasks: []}]
       elif $x[0] == "T" then
         (if $chunked then (if $c < 0 then .chunks += [{n: 0, tasks: []}] else . end)
          elif $x[2] == "impl" or $c < 0 then .chunks += [{n: ($c + 2), tasks: []}]
          else . end)
         | ((.chunks | length) - 1) as $c
         | .chunks[$c].tasks += [{title: ($x[3] // ""), kind: $x[2], line: ($x[1] | tonumber),
                                  claims: [], claims_none: null, files: [], links: []}]
       elif $x[0] == "S" then .specs += [{path: $x[1], role: $x[2]}]
       elif $x[0] == "D" then .completed = true
       elif $c < 0 or (.chunks[$c].tasks | length) == 0 then .
       else ((.chunks[$c].tasks | length) - 1) as $t
         | ($x[1] // "") as $v
         | if $x[0] == "L" then
             (if $v | test("^none([^A-Za-z0-9_#-]|$)")
              then .chunks[$c].tasks[$t].claims_none = ($v | sub("^none[ \t]*(—|--?|:)?[ \t]*"; ""))
              else .chunks[$c].tasks[$t].claims += [$v | split(",")[] | gsub("^[ \t`]+|[ \t`]+$"; "") | select(. != "")]
              end)
           elif $x[0] == "F" then .chunks[$c].tasks[$t].files += [$v]
           elif $x[0] == "K" then .chunks[$c].tasks[$t].links += [$v]
           else . end
       end)
 | {path: $path, stem: $stem, completed, chunked: $chunked, specs: (.specs | uniq),
    chunks: [.chunks[] | .tasks |= map(.claims |= uniq | .files |= uniq | .links |= uniq)]}'

# _claims_plan_parse <plan> <staged|all|rev:<sha>>: print the plan's object
# (see the section comment), read from the index, the work tree or <sha>.
# An absent plan dies: callers check presence first.
_claims_plan_parse() {
  local plan="$1" src="$2" praw="$_SCRATCH/cl-plan.raw" masked="$_SCRATCH/cl-plan.masked"
  local recs="$_SCRATCH/cl-plan.tsv" pats base
  case "$src" in
    staged) git cat-file blob ":$plan" > "$praw" 2>/dev/null || _claims_die "cannot read $plan from the index (plan parser)" ;;
    all)
      [ -f "$plan" ] || _claims_die "cannot read $plan (plan parser)"
      cat -- "$plan" > "$praw" || _claims_die "cannot read $plan (plan parser)"
      ;;
    rev:?*) _claims_read_at "${src#rev:}" "$plan" > "$praw" || _claims_die "cannot read $plan at ${src#rev:} (plan parser)" ;;
    *) _claims_die "_claims_plan_parse: unknown source '$src'" ;;
  esac
  _claims_jq plan-mask -Rsj "$_JQ_CLAIMS_NORM $_JQ_CLAIMS_PLAN_MASK" "$praw" > "$masked"
  pats=$(_claims_jq plan-patterns -r \
    '.source_doc_patterns | if type == "array" then .[] | strings | select(. != "" and (test("\n") | not)) else empty end' \
    "$_SCRATCH/cl-config.json") || _claims_propagate $?
  CL_PLAN_PATTERNS=$pats LC_ALL=C awk -v gp="$_CL_GATE_TITLE_PREFIX" -v fg="$_CL_FINAL_GATE_TITLE" \
    -v su="$_CL_SPEC_UPDATE_TITLE" -v ap="$_CL_AMEND_TITLE_PREFIX" -v fz="$_CL_FINALIZE_TITLE" \
    "$_AWK_CLAIMS_PLAN" "$masked" > "$recs" || _claims_die "awk failed parsing $plan (plan parser)"
  base=${plan##*/}
  _claims_jq plan-parse -nRc --arg path "$plan" --arg stem "${base%.*}" "$_JQ_CLAIMS_PLAN" < "$recs"
}

# V12 over one parsed plan ($plan; run with $c: cl-claims.json, $code: the
# impl tasks' code paths, $final: _claims_v12_final's answer or "", $gp:
# _CL_GATE_TITLE_PREFIX). One finding object per line.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_V12='def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
 def in_list($l): . as $x | any($l[]; . == $x);
 $plan[0] as $p
 | [$p.chunks[] | .n as $n | .tasks[]
    | . + {chunk: $n,
           gate_n: (if .kind == "gate"
                    then [.title | ltrimstr($gp) | capture("^(?<d>[0-9]+)\\)") | .d | tonumber][0]
                    else null end)}] as $ts
 | [range(0; $ts | length)] as $ix
 | def gate_of($i; $n): $ts[$i].kind == "gate" and $ts[$i].gate_n == $n;
   ([$p.specs[] | select(cl_targets) | .path] | uniq) as $targets
 | ([$ts[] | .claims[]] | uniq) as $named
 | ((if $p.chunked then
       [$ix[] | select($ts[.].kind == "spec-update") | . as $i | $ts[$i].chunk as $n
        | select((any($ix[]; . < $i and $ts[.].chunk == $n and gate_of(.; $n))) | not)
        | "chunk \($n): no claims gate before the spec-update task"] | uniq[]
     else
       [$ix[] | select($ts[.].kind == "spec-update") | . as $i | $ts[$i].chunk as $n
        | select(($i > 0 and gate_of($i - 1; $n)) | not)
        | "chunk \($n): the claims gate must immediately precede the spec-update task"] | uniq[]
     end),
    ([$ix[] | select($ts[.].kind == "finalize") | . as $i
      | select((any($ix[]; . < $i and $ts[.].kind == "final-gate")) | not)]
     | if length > 0 then "no final claims gate before the finalize task" else empty end),
    ($c[0][] | select((.doc | type) == "string" and (.doc | in_list($targets))) | .doc as $doc | .claim
     | select(.status == "unbuilt" and (.id | type) == "string" and (.id | in_list($named) | not))
     | "unbuilt claim \(.id) of target spec \($doc) is named on no **Claims:** line of the plan: name it on the task that builds it"),
    ($ts[] | select(.kind == "impl") | . as $t
     | [.files[] | select(in_list($code))]
     | select(length > 0 and ($t.claims | length) == 0 and $t.claims_none == null)
     | "task \"\($t.title)\" (line \($t.line)) changes code (\(join(", "))) but has no **Claims:** line: name the claims it builds, or write **Claims:** none — <reason>"),
    ($ts[] | select(.kind == "impl" and .claims_none != null and (.links | length) > 0)
     | "task \"\(.title)\" (line \(.line)) has **Claims:** none but links \(.links | join(", ")) as the source of its behaviour: promote the decision into a governing doc first, then name its claim"),
    (if $final != "" then $final else empty end))
 | {check: "V12", claim: null, doc: $p.path, message: .}'

# _claims_v12_final <stem>: _CL_V12_FINAL = why the plan's move to
# Completed is not covered by its final gate record
# (docs/spec-claims/gates/<stem>/final.json, read from the proposed tree),
# or "" when it is: the record is one JSON object with result "pass" and a
# head that is a commit, an ancestor of HEAD or HEAD itself, and no commit in
# `git rev-list --no-merges HEAD ^<head> ^_CL_MB` — the branch's own commits
# after the final gate that the base does not hold — touches a code path
# (_claims_is_code_path). A merge commit is not counted: a merge of the base
# carries trunk's changes, which are not this plan's. Under --staged the
# commit being made counts too: a staged code path is a finding.
_claims_v12_final() {
  local rec="docs/spec-claims/gates/$1/final.json" fraw="$_SCRATCH/cl-v12-final.json"
  local commits="$_SCRATCH/cl-v12-commits" paths="$_SCRATCH/cl-v12-paths.z" out head c p
  _CL_V12_FINAL=""
  # The record's path is built from the plan's file stem, which may be ".."
  # (a plan named ...md) or sit behind a linked directory: it is read like
  # any other repo path of the proposed tree, or not at all.
  if ! _claims_safe_relpath "$rec"; then
    _CL_V12_FINAL="plan marked Completed, but its final gate record $rec is not a safe repo path: it is never read"
    return 0
  fi
  if [ "$_CL_MODE" = all ] && ! _claims_contained_path "$rec"; then
    _CL_V12_FINAL="plan marked Completed, but its final gate record $rec is reached through a symbolic link or leaves the work tree: it is never read"
    return 0
  fi
  if ! _claims_read "$rec" > "$fraw"; then
    _CL_V12_FINAL="plan marked Completed without a final gate record: $rec is absent (claims attest --final writes it)"
    return 0
  fi
  # Its status is the answer (not one JSON object), so not _claims_jq.
  out=$(jq -r -s 'if length == 1 and (.[0] | type) == "object" then .[0]
      | if .result != "pass" then "result\t" + (.result | tojson)
        elif (.head | type) != "string" or (.head | test("^[0-9a-f]{7,64}$") | not) then "head\t" + (.head | tojson)
        else "ok\t" + .head end
    else "malformed\t" end' "$fraw" 2>/dev/null) || out="malformed"$'\t'
  # Empty output: jq 1.6 -s on a record it cannot parse (it exits 0).
  [ -n "$out" ] || out="malformed"$'\t'
  head=${out#*$'\t'}
  case "$out" in
    result*) _CL_V12_FINAL="plan marked Completed, but its final gate record $rec does not pass (result: $head)"; return 0 ;;
    head*) _CL_V12_FINAL="plan marked Completed, but its final gate record $rec names no commit head (head: $head)"; return 0 ;;
    malformed*) _CL_V12_FINAL="plan marked Completed, but its final gate record $rec is not one JSON object"; return 0 ;;
  esac
  if ! c=$(git rev-parse -q --verify "$head^{commit}" 2>/dev/null); then
    _CL_V12_FINAL="plan marked Completed, but its final gate record's head $head is not a commit here"
    return 0
  fi
  head=$c
  if ! git merge-base --is-ancestor "$head" HEAD 2>/dev/null; then
    _CL_V12_FINAL="plan marked Completed, but its final gate record's head $head is not an ancestor of HEAD: re-run the final gate"
    return 0
  fi
  git rev-list --no-merges HEAD "^$head" "^$_CL_MB" > "$commits" \
    || _claims_die "git rev-list failed listing the commits after the final gate"
  while IFS= read -r c <&3; do
    [ -n "$c" ] || continue
    git diff-tree --root -r -z --no-commit-id --name-only --no-renames "$c" > "$paths" \
      || _claims_die "git diff-tree failed on $c"
    while IFS= read -r -d '' p <&4; do
      if _claims_is_code_path "$p"; then
        _CL_V12_FINAL="plan marked Completed, but commit $c, after the final gate at $head, changes code ($p): re-run the final gate"
        return 0
      fi
    done 4< "$paths"
  done 3< "$commits"
  if [ "$_CL_MODE" = staged ]; then
    _claims_jq v12-staged-paths -j '.[] | . + "\u0000"' "$_SCRATCH/cl-staged.json" > "$paths"
    while IFS= read -r -d '' p <&4; do
      if _claims_is_code_path "$p"; then
        _CL_V12_FINAL="plan marked Completed, but this commit changes code ($p) after the final gate at $head: commit the code first, then re-run the final gate"
        return 0
      fi
    done 4< "$paths"
  fi
}

# _claims_v12_plan <plan>: V12 over one plan (see the section comment).
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_v12_plan() {
  local plan="$1" src=all pj="$_SCRATCH/cl-v12-plan.json" bj="$_SCRATCH/cl-v12-base.json"
  local flist="$_SCRATCH/cl-v12-files.z" code="$_SCRATCH/cl-v12-code.jsonl" facts base at_base=unknown base_done=false f
  [ "$_CL_MODE" != staged ] || src=staged
  _claims_plan_parse "$plan" "$src" > "$pj"
  # "<has governing specs> <gate-carrying> <completed>"
  facts=$(_claims_jq v12-facts -r \
    '[(.specs | length) > 0, any(.chunks[].tasks[]; .kind == "gate" or .kind == "final-gate"), .completed]
     | map(tostring) | join(" ")' "$pj") || _claims_propagate $?
  case "$facts" in
    true*) ;;
    *) return 0 ;;
  esac
  if [ -n "$_CL_MB" ]; then
    if _claims_read_at "$_CL_MB" "$plan" >/dev/null; then at_base=present; else at_base=absent; fi
  fi
  # In scope when new or gate-carrying; with _CL_MB unresolvable, newness
  # is unknown, so gate-carrying only.
  case "$at_base:$facts" in
    absent:*|*:"true true "*) ;;
    *) return 0 ;;
  esac
  # A plan already completed at _CL_MB is history: none of V12 re-judges it
  # (a later feature may add an unbuilt claim to a spec it targeted).
  if [ "$at_base" = present ]; then
    _claims_plan_parse "$plan" "rev:$_CL_MB" > "$bj"
    base_done=$(_claims_jq v12-base-completed -r '.completed' "$bj") || _claims_propagate $?
    [ "$base_done" != true ] || return 0
  fi
  : > "$code"
  _claims_jq v12-files -j '[.chunks[].tasks[] | select(.kind == "impl") | .files[]] | unique | .[] | . + "\u0000"' \
    "$pj" > "$flist"
  while IFS= read -r -d '' f <&3; do
    if _claims_is_code_path "$f"; then
      _claims_jq v12-code -nc --arg f "$f" '$f' >> "$code"
    fi
  done 3< "$flist"
  _CL_V12_FINAL=""
  case "$at_base:$facts" in
    *:*" true")
      if [ "$at_base" != unknown ]; then
        base=${plan##*/}
        _claims_v12_final "${base%.*}"
      fi
      ;;
  esac
  _claims_jq v12 -nc --slurpfile plan "$pj" --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile code "$code" \
    --arg final "$_CL_V12_FINAL" --arg gp "$_CL_GATE_TITLE_PREFIX" "$_JQ_CLAIMS_ROLES $_JQ_CLAIMS_V12" >> "$_SCRATCH/cl-findings.jsonl"
}

# The plans in scope — matching config plans, and staged (--staged; present
# in the index) or present in the work tree (--all: tracked or untracked,
# not ignored; a safe path reached through no symbolic link) —
# _claims_plan_paths writes to $_SCRATCH/cl-plans.z, NUL-separated. Under
# --staged it lists the plans this commit changes (V12 judges what is being
# committed); "_claims_plan_paths indexed" lists every plan in the index
# (V6's direction policy asks which plans exist, not which changed). Under --all, ls-files is
# narrowed by the globs as pathspecs (a pathspec's * matches "/" too, as
# _claims_glob_match's does: a superset), each under :(top), with the
# environment's pathspec overrides (literal, glob: * no longer matching "/")
# off; _claims_glob_any then decides.
_claims_plan_paths() {
  local scope="${1:-changed}" list="$_SCRATCH/cl-plans-all.z" out="$_SCRATCH/cl-plans.z" globs g p prev=""
  local -a specs=() flags=()
  : > "$out"
  globs=$(_claims_jq plans -r \
    '.plans | if type == "array" then .[] | strings | select(. != "" and (test("\n") | not)) else empty end' \
    "$_SCRATCH/cl-config.json") || _claims_propagate $?
  [ -n "$globs" ] || return 0
  if [ "$_CL_MODE" = staged ] && [ "$scope" = changed ]; then
    _claims_jq plans-staged -j '.[] | . + "\u0000"' "$_SCRATCH/cl-staged.json" > "$list"
  else
    while IFS= read -r g; do
      specs+=(":(top)$g")
    done <<EOF
$globs
EOF
    flags=(--cached --others --exclude-standard)
    [ "$_CL_MODE" != staged ] || flags=(--cached)
    GIT_LITERAL_PATHSPECS=0 GIT_GLOB_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 \
      git ls-files -z ${flags[@]+"${flags[@]}"} -- ${specs[@]+"${specs[@]}"} > "$list" \
      || _claims_die "git ls-files failed listing the plans"
  fi
  while IFS= read -r -d '' p <&3; do
    # ls-files lists an unmerged path once per stage.
    [ "$p" != "$prev" ] || continue
    prev=$p
    _claims_glob_any "$p" "$globs" || continue
    _claims_safe_relpath "$p" || continue
    if [ "$_CL_MODE" = staged ]; then
      git cat-file -e ":$p" 2>/dev/null || continue
    else
      [ -f "$p" ] || continue
      _claims_contained_path "$p" || continue
    fi
    printf '%s\0' "$p" >> "$out"
  done 3< "$list"
}

# V12: each plan _claims_plan_paths lists.
_claims_v12() {
  local p
  _claims_code_init
  _claims_plan_paths
  while IFS= read -r -d '' p <&3; do
    _claims_v12_plan "$p"
  done 3< "$_SCRATCH/cl-plans.z"
}

# --- Spec claims: promote, the nonvacuity proofs -------------------------------
#
# claims promote <id> is the one path into built (§C). It refuses a dirty
# tree (_claims_refuse_dirty: exit 2, dirty-tree), so HEAD is the tree it
# proves, and the claim record it reads is the one it proves (its
# fingerprint, promotion.proved, is what V6, gate and attest compare with;
# promotion.at = HEAD is a record only, never read back). The
# claim must be a test claim, not frozen, with a bound test and a proof —
# nonvacuity.mutant {file, find, replace}, nonvacuity.observed_red <sha>, or
# both (then both must hold) — whose status is unbuilt, diverged
# or gated — or built whose verdict check is not ok (a field differs from
# promotion.proved, e.g. a DOC-STALE amendment changed its states, or the
# verdict is in another clone's store):
# re-proving is always safe. A built claim whose verdict is ok is "already
# promoted". Then:
#   1. the bound node runs at HEAD (the clean work tree, --root its top
#      level) through its runner adapter: it must pass ("not green");
#   2. for each proof, the mutant first, in a throwaway worktree of its own
#      at HEAD (_claims_worktree_add; a fresh one per proof, so neither
#      proof's change reaches the other's runs) the node runs unmodified
#      with --root the worktree: it must pass there too ("not green in a
#      clean checkout": the work tree's untracked files are not in it), so
#      the red run differs from a green one only by the proof's change; then
#      the change is made and the node runs again: it must fail by an
#      assertion (pass: "<proof> stays green"; error or not-found: "<proof>
#      error is not an assertion failure"). The mutant's change:
#      _claims_mutate (literal, exactly once, on UTF-8 text only — "mutant
#      file is not UTF-8 text"). observed_red's (<sha> must be a full
#      object id, lowercase hex and as long as HEAD's — "observed_red is not
#      a full commit id" — naming a commit — "observed_red is not a
#      commit"): each subject path removed in the worktree, then checked
#      out from <sha> when <sha> holds it — absent there, it stays removed
#      (the test-first case) — while the bound test stays at HEAD
#      (_claims_promote_swap);
#   3. the verdict (see "the verdict store") is stored, then the sidecar is
#      rewritten atomically — status → status_to (built; gated, with the
#      configuration extension on, when the recorded configuration at HEAD,
#      the config adapter's recorded --rev HEAD, does not satisfy the claim's
#      when: claims_when_ok), promotion → {at: HEAD, verdict_sha256:
#      <digest>, proved: _claims_proved of the claim} — and the doc's
#      status block rendered. That recorded call
#      runs before step 1; when it fails, promote is indeterminate.
# Everything that can refuse runs before anything is written: the mutant
# file must not be the bound test's own file, must be a safe repo path,
# contained in the worktree (no symbolic link
# on its way, physically under the worktree's root) and a file there; each
# subject path must be at HEAD (its object id goes into subject_oids), and
# with an observed_red must neither be nor hold the bound test's own file,
# and is a safe repo path contained in its worktree whenever it is removed
# or checked out there (an earlier subject's checkout may have put a
# symbolic link on its way); the doc's markers must render. An
# indeterminate run exits 2. Every finding blocks. Re-promoting replaces
# promotion with the new digest. The worktrees are removed on every exit
# path (cleanup). Results: one row {claim, status_from, status_to, green,
# red, verdict_sha256} for a promotion.
#
# promote --reverify (§G's scheduled re-verification) takes the same path,
# _claims_prove, so the two cannot diverge: for each claim it is asked for
# (<id>…, or --all: every built or gated claim with a promotion, a frozen
# one reported skipped) at HEAD, in a clean tree, steps 1 and 2 with every
# guard; then the verdict of the claim as it stands (status_to its own
# status: built or gated) is stored under its own digest. It never writes
# the sidecar or the doc — the promotion still names the verdict promote
# stored — and needs no stored verdict (a fresh clone, CI). A named claim
# that is not built or gated with a promotion is a finding ("not
# promoted"); an unknown id is a usage error before anything runs. Each
# claim's worktrees are removed before the next claim runs. Results: one
# row {claim, verdict} per claim, verdict ok, finding, indeterminate or
# skipped.
# Scratch: cl-promote.json (the claim's plan), cl-promote-* (the run calls,
# the subject paths and ids, the verdict, the sidecar and doc rewritten),
# cl-swap.err (observed_red's checkouts), cl-reverify.z (--reverify's
# claims).

# _claims_refuse_dirty <verb>: the gate precondition (Design
# clarifications): when `git status --porcelain --untracked-files=no` lists
# anything outside docs/spec-claims/gates/ (the index or the work tree
# differing from HEAD; untracked files do not count), the run is refused —
# indeterminate dirty-tree, exit 2 — before anything runs.
_claims_refuse_dirty() {
  local st="$_SCRATCH/cl-dirty"
  GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=no -- . ':(exclude)docs/spec-claims/gates/' \
    > "$st" || _claims_die "git status failed (the dirty-tree check)"
  [ -s "$st" ] || return 0
  {
    echo "claims $1: the tracked files differ from HEAD (commit them first):"
    head -n 10 "$st"
  } >&2 || true
  _claims_indeterminate "$1" - dirty-tree
  _claims_emit "$1"
}

_CL_WT=""     # the last worktree _claims_worktree_add made
_CL_WT_N=0    # how many it made (their names: wt.<n>)

# _claims_worktree_add <rev>: a throwaway worktree, detached at <rev>, in the
# scratch dir; its path in _CL_WT, registered in _CL_WTS (before the add, so
# a half-made one is removed too) for cleanup, which removes it on every exit
# path. Call it in the main shell, never inside $(…). The host's hooks do not
# run in it (core.hooksPath=/dev/null: no post-checkout).
_claims_worktree_add() {
  local wt="$_SCRATCH/wt.$_CL_WT_N" err="$_SCRATCH/cl-wt.err" msg
  _CL_WT_N=$((_CL_WT_N + 1))
  _CL_WTS+=("$wt")
  if ! git -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "$1" >/dev/null 2>"$err"; then
    msg=$(head -n 1 "$err" 2>/dev/null) || msg=""
    _claims_die "git worktree add failed at $1${msg:+: $msg}"
  fi
  _CL_WT=$wt
}

_CL_MUTATE_ERR=""  # why _claims_mutate refused

# _claims_mutate <file> <find> <replace>: rewrite <file> with its one
# occurrence of <find> replaced by <replace> — literal and glob-free (jq
# split and join: no pattern, no backreference; never bash's ${s/…/…}). The
# rest of the file stays byte for byte only because the file must be UTF-8
# text that jq reads back unchanged (jq -Rs replaces each invalid UTF-8 byte
# with U+FFFD, and the mutant would then change more than find → replace):
# its jq -j -Rs . round trip must be cmp-identical, else it returns 2, <file>
# untouched. -j adds no newline and no JSON quoting. Returns 1, <file>
# untouched, when <find> is empty or does not occur exactly once:
# _CL_MUTATE_ERR = "find matches <n> times" (an empty file: 0). Written
# through _tmp_beside + _replace_file.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_mutate() {
  local file="$1" err="$_SCRATCH/cl-mutate.err" rc=0
  _CL_MUTATE_ERR=""
  if [ -z "$2" ]; then
    _CL_MUTATE_ERR="find is empty"
    return 1
  fi
  _tmp_beside "$file"
  jq -j -Rs . < "$file" > "$_TMP" 2> "$err" || _claims_die "jq failed (mutate: reading $file)"
  if ! cmp -s "$_TMP" "$file"; then
    rm -f "$_TMP"
    _CL_MUTATE_ERR="not UTF-8 text"
    return 2
  fi
  jq -j -Rs --arg f "$2" --arg r "$3" \
    'if . == "" then [""] else split($f) end
     | if length != 2 then error("find matches \(length - 1) times") else join($r) end' \
    < "$file" > "$_TMP" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$_TMP"
    # 5: the program's error(); anything else is jq failing.
    [ "$rc" -eq 5 ] || _claims_die "jq failed (mutate, rc $rc)"
    _CL_MUTATE_ERR=$(sed -n '1s/^jq: error (at [^)]*): //p' "$err") || _CL_MUTATE_ERR=""
    [ -n "$_CL_MUTATE_ERR" ] || _CL_MUTATE_ERR=$(head -n 1 "$err") || _CL_MUTATE_ERR=""
    [ -n "$_CL_MUTATE_ERR" ] || _CL_MUTATE_ERR="find does not match exactly once"
    return 1
  fi
  _replace_file "$_TMP" "$file"
}

# The claim promote is asked for (cl-claims.json, $id): {unknown: true} when
# no claim has the id; else {unknown: false, sidecar, doc, status, claim,
# refuse}, refuse the first precondition it fails (a finding message), or
# null.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_PROMOTE_PLAN='def nes: type == "string" and length > 0;
 def nonul: (split("\u0000") | length) <= 1;
 [.[] | select(.claim.id == $id)] as $m
 | if ($m | length) == 0 then {unknown: true}
   elif ($m | length) > 1 then {unknown: false, doc: $m[0].doc,
     refuse: "\($m | length) claims have the id \($id): give each its own id first (V1)"}
   else $m[0] as $e | $e.claim as $c
   | ($c.nonvacuity | if type == "object" then . else {} end) as $nv
   | $nv.mutant as $mu | $nv.observed_red as $ord
   | {unknown: false, sidecar: $e.sidecar, doc: $e.doc, status: $c.status, claim: $c,
      refuse: (
        if ($e.eligible | not) then "its doc \($e.doc | tojson) is missing or not a governing doc here: nothing to promote"
        elif $c.status == "retired" then "status retired: a retired claim is not promoted"
        elif $c.frozen_at | nes then "frozen (frozen_at \($c.frozen_at)): a frozen claim is never run, so promote cannot prove it"
        elif $c.enforced_by != "test" then "enforced_by \($c.enforced_by | tojson): promote proves a test claim (its bound test passes, and fails under a mutant)"
        elif ($c.test | type) != "object" or ($c.test.runner | nes | not) or ($c.test.node | nes | not)
        then "test \($c.test | tojson) is not {runner, node}: bind the claim'"'"'s test first"
        elif [$c.test.runner, $c.test.node] | all(nonul) | not then "test.runner or test.node holds a NUL byte"
        elif any("unbuilt", "diverged", "gated", "built"; . == $c.status) | not
        then "status \($c.status | tojson) cannot be promoted (unbuilt, diverged, gated or built only)"
        elif ($c.subject | type) != "array" or (all($c.subject[]; nes and nonul) | not)
        then "subject \($c.subject | tojson) is not a list of repo paths"
        elif $mu == null and $ord == null
        then "no nonvacuity proof: promote needs nonvacuity.mutant {file, find, replace} (a change under which the bound test fails by an assertion) or nonvacuity.observed_red <sha> (a commit whose subject files make it fail by one)"
        elif $ord != null and (($ord | nes | not) or ($ord | nonul | not))
        then "nonvacuity.observed_red is not a full commit id: \($ord | tojson) (give the full lowercase hex id of a commit)"
        elif $mu != null and (($mu | type) != "object" or ($mu.file | nes | not) or ($mu.find | nes | not) or ($mu.replace | type) != "string")
        then "nonvacuity.mutant \($mu | tojson) is not {file, find, replace}"
        elif $mu != null and ([$mu.file, $mu.find, $mu.replace] | all(nonul) | not) then "nonvacuity.mutant holds a NUL byte"
        elif $mu != null and ($mu.file | cl_mutant_is_test($c.test.file; $c.test.node)) then $mu.file | cl_mutant_test_msg
        elif $ord != null and any($c.subject[]; cl_subject_holds_test($c.test.file; $c.test.node))
        then first($c.subject[] | select(cl_subject_holds_test($c.test.file; $c.test.node))) | cl_subject_test_msg
        else null end)}
   end'

# Why promote calls a path unsafe (_claims_safe_relpath, _claims_contained_path).
_CL_PROMOTE_UNSAFE="(absolute, an empty, . or .. segment, or reached through a symbolic link)"

_CL_PR_OUTCOME=""  # _claims_promote_run's outcome
_CL_PR_REASON=""   # …and its reason ("" when none)

# _claims_promote_run <root> <runner> <node>: one run call, --root <root>,
# for <node> (the adapter run from the repo root, as claims run calls it);
# its outcome and reason into _CL_PR_OUTCOME / _CL_PR_REASON. Call it in the
# main shell.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_promote_run() {
  local req="$_SCRATCH/cl-promote-req.json" out="$_SCRATCH/cl-promote-out" row="$_SCRATCH/cl-promote-row.json"
  local adapter rc=0
  _claims_jq promote-req -nc --arg n "$3" '[$n]' > "$req"
  adapter=$(_claims_runner_adapter "$2") || _claims_propagate $?
  _claims_adapter_call "$out" "$adapter" run --root "$1" "$3" || rc=$?
  _claims_parse_run "$out" "$req" "$rc" > "$row"
  _CL_PR_OUTCOME=$(_claims_jq promote-outcome -r '.outcome' "$row") || _claims_propagate $?
  _CL_PR_REASON=$(_claims_jq promote-reason -r '.reason // ""' "$row") || _claims_propagate $?
}

# _claims_promote_clean <id> <doc> <runner> <node>: the node run unmodified
# in the worktree $_CL_WT; 0 when it passes, else 1 with its finding ("not
# green in a clean checkout") or indeterminate row added.
_claims_promote_clean() {
  local why
  _claims_promote_run "$_CL_WT" "$3" "$4"
  why=${_CL_PR_REASON:+ ($_CL_PR_REASON)}
  case "$_CL_PR_OUTCOME" in
    pass) return 0 ;;
    indeterminate) _claims_indeterminate promote "$1" "${_CL_PR_REASON:-indeterminate}" ;;
    *) _claims_finding promote "$1" "$2" "not green in a clean checkout: the bound test passes in the work tree but gives $_CL_PR_OUTCOME$why in a checkout of HEAD (it reads something HEAD does not hold: an untracked or ignored file?)" ;;
  esac
  return 1
}

# _claims_promote_red <id> <doc> <runner> <node> <proof> <under>: the node
# run in $_CL_WT, the proof's change made; 0 when it fails by an assertion,
# else 1 with its finding ("<proof> stays green", "<proof> error is not an
# assertion failure") or indeterminate row added. <under> says what the run
# saw ("under the mutant of <file>").
_claims_promote_red() {
  local why
  _claims_promote_run "$_CL_WT" "$3" "$4"
  why=${_CL_PR_REASON:+ ($_CL_PR_REASON)}
  case "$_CL_PR_OUTCOME" in
    assert-fail) return 0 ;;
    indeterminate) _claims_indeterminate promote "$1" "${_CL_PR_REASON:-indeterminate}" ;;
    pass) _claims_finding promote "$1" "$2" "$5 stays green: $6 the bound test still passes, so it does not check what the claim states" ;;
    *) _claims_finding promote "$1" "$2" "$5 error is not an assertion failure: $6 the bound test gives $_CL_PR_OUTCOME$why" ;;
  esac
  return 1
}

# _claims_promote_swap <id> <doc> <sha> <subjects>: in the worktree $_CL_WT,
# each subject path (<subjects>: NUL-separated) made as at commit <sha>:
# removed (rm -rf), then checked out from <sha> when <sha> holds it (git
# cat-file -e) — a path absent there is the test-first case, and stays
# removed. Before anything touches a path it must be a safe repo path
# contained in the worktree (_claims_contained_path, in a subshell that
# takes the worktree for the work tree): no symbolic link on its way, which
# an earlier path's checkout may have put there. Else 1, a finding added,
# and nothing more touched. Pathspecs are literal; the host's hooks do not
# run.
_claims_promote_swap() {
  local p rc err="$_SCRATCH/cl-swap.err" msg
  while IFS= read -r -d '' p <&3; do
    rc=0
    if _claims_safe_relpath "$p"; then
      # shellcheck disable=SC2030  # the subshell's own _CL_ROOT, on purpose
      (cd "$_CL_WT" && _CL_ROOT=$_CL_WT && _CL_ROOT_PHYS="" && _claims_contained_path "$p") || rc=$?
    else
      rc=1
    fi
    case "$rc" in
      0) ;;
      1)
        _claims_finding promote "$1" "$2" "subject $p is not a safe repo path $_CL_PROMOTE_UNSAFE in the worktree as at observed_red: it is never removed or checked out"
        return 1
        ;;
      *) _claims_propagate "$rc" ;;
    esac
    rm -rf -- "${_CL_WT:?}/$p" || _claims_die "cannot remove $p in the throwaway worktree (observed_red)"
    if git cat-file -e "$3:$p" 2>/dev/null; then
      if ! git -c core.hooksPath=/dev/null -C "$_CL_WT" --literal-pathspecs checkout -q "$3" -- "$p" \
          >/dev/null 2>"$err"; then
        msg=$(head -n 1 "$err" 2>/dev/null) || msg=""
        _claims_die "git checkout of $p at $3 failed in the throwaway worktree${msg:+: $msg}"
      fi
    fi
  done 3< "$4"
  return 0
}

_CL_PV_DOC=""      # the claim _claims_prove was asked for: its doc ("-" when none)
_CL_PV_SIDECAR=""  # …its sidecar
_CL_PV_STATUS=""   # …its status
_CL_PV_HEAD=""     # …HEAD, which its proofs ran at
_CL_PV_DIGEST=""   # …its verdict's digest (the bytes in cl-promote-verdict.json)
_CL_PV_TO=""       # …its verdict's status_to
_CL_PV_PROVED=""   # …the fingerprint of the record it proved (_claims_proved)

# _claims_prove <mode> <id>: the proof path promote and --reverify share
# (see the section comment), <mode> promote or reverify, so the two cannot
# diverge. An unknown id is a usage error. Then the claim's preconditions —
# reverify first needs it built or gated with a promotion ("not promoted");
# promote refuses a built claim whose verdict is ok ("already promoted"),
# unless the configuration extension is on and the recorded configuration
# at HEAD no longer satisfies its when (it is re-proved, and re-gated) —
# its subject at HEAD, the green run in the work tree, and each proof in a
# throwaway worktree of its own, every guard included. 0: proved — its
# verdict in cl-promote-verdict.json (status_to, also in _CL_PV_TO: built
# for promote — gated when the configuration extension is on and the
# recorded configuration at HEAD does not satisfy the claim's when — the
# claim's own status for reverify), the digest in _CL_PV_DIGEST, the
# claim's proved fingerprint in _CL_PV_PROVED, nothing written outside the
# scratch dir. 1: refused, its finding (or indeterminate row) added.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_prove() {
  local mode="$1" id="$2" plan="$_SCRATCH/cl-promote.json" z="$_SCRATCH/cl-promote.z"
  local oids="$_SCRATCH/cl-promote-oids.jsonl" subj="$_SCRATCH/cl-promote-subjects.z"
  local vfile="$_SCRATCH/cl-promote-verdict.json"
  local x refuse doc status claim runner="" node="" mfile="" mfind="" mrepl="" ored="" rsha=""
  local head p oid v rc green why ss to unsafe="$_CL_PROMOTE_UNSAFE" munsafe
  local whenp="$_JQ_CLAIMS_WHEN"' .claim | if claims_when_ok($rec[0]) then "built" else "gated" end'
  _CL_PV_DOC=- _CL_PV_SIDECAR="" _CL_PV_STATUS="" _CL_PV_HEAD="" _CL_PV_DIGEST="" _CL_PV_TO="" _CL_PV_PROVED=""
  _claims_jq promote-plan -c --arg id "$id" "$_JQ_CLAIMS_MUTANT_DEFS $_JQ_CLAIMS_PROMOTE_PLAN" \
    "$_SCRATCH/cl-claims.json" > "$plan"
  x=$(_claims_jq promote-unknown -r '.unknown' "$plan") || _claims_propagate $?
  [ "$x" = false ] || _usage_error "claims promote" "no claim has the id $id"
  doc=$(_claims_jq promote-doc -r '.doc | strings' "$plan") || _claims_propagate $?
  [ -n "$doc" ] || doc=-
  _CL_PV_DOC=$doc
  if [ "$mode" = reverify ]; then
    # (A duplicated id has no claim here: the plan's refusal names it.)
    refuse=$(_claims_jq reverify-promoted -r 'select(has("claim")) | .claim
        | select(((.status == "built" or .status == "gated") and (.promotion | type) == "object") | not)
        | "not promoted: status \(.status | tojson), promotion \(.promotion | tojson): --reverify re-proves the promotion of a built or gated claim (claims promote makes one)"' \
      "$plan") || _claims_propagate $?
    if [ -n "$refuse" ]; then
      _claims_finding promote "$id" "$doc" "$refuse"
      return 1
    fi
  fi
  refuse=$(_claims_jq promote-refuse -r '.refuse | strings' "$plan") || _claims_propagate $?
  if [ -n "$refuse" ]; then
    _claims_finding promote "$id" "$doc" "$refuse"
    return 1
  fi
  _CL_PV_SIDECAR=$(_claims_jq promote-sidecar -r '.sidecar' "$plan") || _claims_propagate $?
  status=$(_claims_jq promote-status -r '.status' "$plan") || _claims_propagate $?
  _CL_PV_STATUS=$status
  claim=$(_claims_jq promote-claim -c '.claim' "$plan") || _claims_propagate $?
  # NUL-separated and read with read -d '': find and replace keep every byte,
  # trailing newlines included ($(…) would strip them).
  # A proof the claim does not give reads as "" (mfile, ored): the plan
  # refused an empty mutant.file or observed_red.
  _claims_jq promote-fields -j '.claim | .test.runner, .test.node, .nonvacuity.mutant.file,
      .nonvacuity.mutant.find, .nonvacuity.mutant.replace, .nonvacuity.observed_red | . + "\u0000"' "$plan" > "$z"
  { IFS= read -r -d '' runner && IFS= read -r -d '' node && IFS= read -r -d '' mfile \
      && IFS= read -r -d '' mfind && IFS= read -r -d '' mrepl && IFS= read -r -d '' ored; } < "$z" \
    || _claims_die "cannot read the claim's test and proofs (promote)"
  munsafe="mutant file $mfile is not a safe repo path $unsafe: name it by its path from the repo root"

  to=""
  if [ "$mode" = promote ] && [ "$status" = built ]; then
    v=$(_claims_verdict_check "$claim") || _claims_propagate $?
    if [ "$v" = ok ]; then
      # With the configuration extension on, a built claim whose when the
      # recorded configuration at HEAD no longer satisfies is not refused:
      # it is re-proved, and re-gated (V3's "…: gated"; V10's "ruling owed"
      # comes first). A claim without a when costs no recorded call.
      x=$(_claims_jq promote-has-when -r '.claim.when | type == "object" and length > 0' "$plan") \
        || _claims_propagate $?
      if [ "$x" = true ] && _claims_b1_on; then
        _claims_recorded --rev HEAD || return 1
        to=$(_claims_jq promote-when -r --slurpfile rec "$_SCRATCH/cl-recorded.json" "$whenp" "$plan") \
          || _claims_propagate $?
      fi
      if [ "$to" != gated ]; then
        _claims_finding promote "$id" "$doc" "already promoted: built, and its verdict matches the claim (promote again after a field promotion.proved records changes)"
        return 1
      fi
    fi
  fi
  if [ -n "$mfile" ] && ! _claims_safe_relpath "$mfile"; then
    _claims_finding promote "$id" "$doc" "$munsafe"
    return 1
  fi
  head=$(git rev-parse -q --verify 'HEAD^{commit}') || _claims_die "cannot resolve HEAD"
  if [ -n "$ored" ]; then
    # The proof names one commit for good (--reverify re-runs it): a full
    # object id, lowercase hex, as long as HEAD's (sha1 or sha256) — never
    # a ref, an abbreviation or an option. Then it must be a commit.
    case "$ored" in
      *[!0123456789abcdef]*) x=0 ;;
      *) x=${#ored} ;;
    esac
    if [ "$x" -ne "${#head}" ]; then
      _claims_finding promote "$id" "$doc" "nonvacuity.observed_red is not a full commit id: $ored (give the full lowercase hex id of a commit, as git rev-parse prints it: a ref or an abbreviation could name another commit when the proof is re-verified)"
      return 1
    fi
    if ! rsha=$(git rev-parse -q --verify "$ored^{commit}" 2>/dev/null) || [ "$rsha" != "$ored" ]; then
      _claims_finding promote "$id" "$doc" "nonvacuity.observed_red is not a commit: $ored (it must name a commit of this repository: fetch it, or correct the id)"
      return 1
    fi
  fi
  : > "$oids"
  _claims_jq promote-subjects -j '.claim.subject[] | . + "\u0000"' "$plan" > "$subj"
  while IFS= read -r -d '' p <&3; do
    if ! _claims_safe_relpath "$p"; then
      _claims_finding promote "$id" "$doc" "subject $p is not a safe repo path $unsafe"
      return 1
    fi
    if ! oid=$(git rev-parse -q --verify "HEAD:$p" 2>/dev/null); then
      _claims_finding promote "$id" "$doc" "subject not at HEAD: $p (the verdict records each subject path's object at HEAD; commit it, or correct the path)"
      return 1
    fi
    _claims_jq promote-oid -nc --arg p "$p" --arg o "$oid" '{($p): $o}' >> "$oids"
  done 3< "$subj"

  # The status the proof leads to: reverify keeps the claim's own; promote
  # writes built — or, with the configuration extension on (§B.1), gated
  # when the recorded configuration at HEAD does not satisfy its when (a
  # re-gated built claim's was decided above).
  if [ "$mode" != promote ]; then
    to=$status
  elif [ -z "$to" ]; then
    to=built
    if _claims_b1_on; then
      _claims_recorded --rev HEAD || return 1
      to=$(_claims_jq promote-when -r --slurpfile rec "$_SCRATCH/cl-recorded.json" "$whenp" "$plan") \
        || _claims_propagate $?
    fi
  fi
  _CL_PV_TO=$to

  # 1. Green at HEAD.
  # shellcheck disable=SC2031  # the main shell's _CL_ROOT (a worktree check's subshell sets its own)
  _claims_promote_run "$_CL_ROOT" "$runner" "$node"
  green=$_CL_PR_OUTCOME
  why=${_CL_PR_REASON:+ ($_CL_PR_REASON)}
  case "$green" in
    pass) ;;
    indeterminate)
      _claims_indeterminate promote "$id" "${_CL_PR_REASON:-indeterminate}"
      return 1
      ;;
    *)
      _claims_finding promote "$id" "$doc" "not green: the bound test gives $green at HEAD$why; promote proves a passing test"
      return 1
      ;;
  esac

  # 2. Each proof the claim gives, in a throwaway worktree of its own at
  # HEAD (so one proof's change never reaches the other's runs): there the
  # node runs unmodified first and must pass — so its red run differs from
  # a green run only by the proof's change (the work tree may hold untracked
  # files a test reads; the worktree does not) — then under the change, and
  # must fail by an assertion. The mutant: its file is checked inside the
  # worktree (a subshell that takes it for the work tree) before anything
  # is written.
  if [ -n "$mfile" ]; then
    _claims_worktree_add "$head"
    rc=0
    (cd "$_CL_WT" && _CL_ROOT=$_CL_WT && _CL_ROOT_PHYS="" && _claims_contained_path "$mfile") || rc=$?
    case "$rc" in
      0) ;;
      1)
        _claims_finding promote "$id" "$doc" "$munsafe"
        return 1
        ;;
      *) _claims_propagate "$rc" ;;
    esac
    if [ ! -f "$_CL_WT/$mfile" ]; then
      _claims_finding promote "$id" "$doc" "mutant file $mfile is not a file at HEAD: nothing to mutate"
      return 1
    fi
    _claims_promote_clean "$id" "$doc" "$runner" "$node" || return 1
    rc=0
    _claims_mutate "$_CL_WT/$mfile" "$mfind" "$mrepl" || rc=$?
    case "$rc" in
      0) ;;
      2)
        _claims_finding promote "$id" "$doc" "mutant file is not UTF-8 text: $mfile (jq would rewrite its invalid bytes, so the mutant would change more than find → replace)"
        return 1
        ;;
      *)
        _claims_finding promote "$id" "$doc" "mutant: $_CL_MUTATE_ERR in $mfile (find must match exactly once)"
        return 1
        ;;
    esac
    _claims_promote_red "$id" "$doc" "$runner" "$node" mutant "under the mutant of $mfile" || return 1
  fi
  # observed_red: the subject as at <sha> (_claims_promote_swap), the test
  # still at HEAD.
  if [ -n "$rsha" ]; then
    _claims_worktree_add "$head"
    _claims_promote_clean "$id" "$doc" "$runner" "$node" || return 1
    _claims_promote_swap "$id" "$doc" "$rsha" "$subj" || return 1
    _claims_promote_red "$id" "$doc" "$runner" "$node" observed_red "with the subject as at observed_red $ored" \
      || return 1
  fi

  # 3. The verdict: the claim as proved at HEAD, with the fingerprint of
  # that record (proved).
  ss=$(_claims_states_sha256 "$claim") || _claims_propagate $?
  _CL_PV_PROVED=$(_claims_proved "$claim") || _claims_propagate $?
  _claims_jq promote-verdict -ncS --slurpfile p "$plan" --slurpfile o "$oids" --arg ss "$ss" --arg head "$head" \
    --arg to "$to" --argjson pr "$_CL_PV_PROVED" \
    '$p[0].claim as $c
     | {claim: $c.id, states_sha256: $ss, test: $c.test, nonvacuity: $c.nonvacuity, proved: $pr, head: $head,
        subject_oids: ($o | add // {}), green: "pass", red: "assert-fail", status_to: $to}' > "$vfile"
  _CL_PV_DIGEST=$(_claims_sha256 "$vfile") || _claims_propagate $?
  _CL_PV_HEAD=$head
  return 0
}

# _claims_store_verdict: the verdict _claims_prove proved
# (cl-promote-verdict.json) stored as <store>/<_CL_PV_DIGEST>.json, the store
# created when missing.
_claims_store_verdict() {
  local store
  store=$(_claims_store_dir) || _claims_propagate $?
  mkdir -p "$store" 2>/dev/null || _claims_die "cannot create the verdict store $store"
  _tmp_beside "$store/$_CL_PV_DIGEST.json"
  cat "$_SCRATCH/cl-promote-verdict.json" > "$_TMP" || _claims_die "cannot write the verdict $store/$_CL_PV_DIGEST.json"
  _replace_file "$_TMP" "$store/$_CL_PV_DIGEST.json"
}

# _claims_promote <id>: promote one claim (see the section comment). A
# refusal adds its finding (or indeterminate row) and returns; the caller
# emits.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_promote() {
  local id="$1" sc_old="$_SCRATCH/cl-promote-sidecar.old" sc_new="$_SCRATCH/cl-promote-sidecar.new"
  local doc_new="$_SCRATCH/cl-promote-doc.new" sidecar doc row
  _claims_prove promote "$id" || return 0
  sidecar=$_CL_PV_SIDECAR
  doc=$_CL_PV_DOC

  # 3. (continued) The sidecar and the doc, each prepared (and the render
  # checked) before the first write: the verdict, then the sidecar, then the
  # doc.
  if ! _claims_safe_relpath "$sidecar" || ! _claims_contained_path "$sidecar"; then
    _claims_die "refusing to write $sidecar: not a safe repo path"
  fi
  if ! _claims_safe_relpath "$doc" || ! _claims_contained_path "$doc"; then
    _claims_die "refusing to render $doc: not a safe repo path"
  fi
  _claims_read "$sidecar" > "$sc_old" || _claims_die "cannot read $sidecar (promote)"
  _claims_jq promote-rewrite --arg id "$id" --arg to "$_CL_PV_TO" --arg at "$_CL_PV_HEAD" --arg d "$_CL_PV_DIGEST" \
    --argjson pr "$_CL_PV_PROVED" \
    '.claims |= map(if type == "object" and .id == $id
                    then .status = $to | .promotion = {at: $at, verdict_sha256: $d, proved: $pr} else . end)' \
    "$sc_old" > "$sc_new"
  if ! _claims_render_doc "$doc" "$sc_new" > "$doc_new"; then
    _claims_finding V11 "$id" "$doc" "$_CL_RENDER_ERR"
    return 0
  fi

  _claims_store_verdict
  _tmp_beside "$sidecar"
  cat "$sc_new" > "$_TMP" || _claims_die "cannot write $sidecar"
  _replace_file "$_TMP" "$sidecar"
  if ! cmp -s "$doc_new" "$_SCRATCH/cl-render.raw"; then
    _tmp_beside "$doc"
    cat "$doc_new" > "$_TMP" || _claims_die "cannot write the render of $doc"
    _replace_file "$_TMP" "$doc"
  fi
  row=$(_claims_jq promote-result -nc --arg c "$id" --arg from "$_CL_PV_STATUS" --arg to "$_CL_PV_TO" \
    --arg d "$_CL_PV_DIGEST" \
    '{claim: $c, status_from: $from, status_to: $to, green: "pass", red: "assert-fail", verdict_sha256: $d}') \
    || _claims_propagate $?
  _claims_result "$row"
}

# _claims_reverify <id>: re-prove one promoted claim (_claims_prove
# reverify) at HEAD; when it holds, store its fresh verdict (its own digest).
# Never writes the sidecar or the doc: the claim's promotion still names the
# verdict promote stored. Its worktrees are removed before the next claim's.
# Results: {claim, verdict} — ok, finding (its finding names the claim) or
# indeterminate.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_reverify() {
  local id="$1" n v row indet="$_SCRATCH/cl-indet.jsonl"
  n=$(($(wc -l < "$indet")))
  if _claims_prove reverify "$id"; then
    _claims_store_verdict
    v=ok
  elif [ "$(($(wc -l < "$indet")))" -gt "$n" ]; then
    v=indeterminate
  else
    v=finding
  fi
  _claims_worktrees_remove
  row=$(_claims_jq reverify-result -nc --arg c "$id" --arg v "$v" '{claim: $c, verdict: $v}') \
    || _claims_propagate $?
  _claims_result "$row"
}

# The claims --reverify --all re-proves (cl-claims.json): each built or gated
# claim with a promotion object, by id, once each, in sidecar order; NUL
# terminated, prefixed r (re-prove) or s (frozen: never run, reported
# skipped).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_REVERIFY_ALL='def nes: type == "string" and length > 0;
 reduce (.[] | .claim | objects
         | select((.id | nes) and (.id | split("\u0000") | length) == 1
                  and (.status == "built" or .status == "gated") and (.promotion | type) == "object")) as $c
   ([]; if any(.[]; .id == $c.id) then . else . + [{id: $c.id, frozen: ($c.frozen_at | nes)}] end)
 | .[] | (if .frozen then "s" else "r" end) + .id + "\u0000"'

# --- Spec claims: the chunk gate ------------------------------------------------
#
# claims gate --plan <p> --chunk <n> [--from <rev>] [--holds <id>…] [--by
# <principal>] runs one plan chunk's claims gate at HEAD (§E) and records it
# in docs/spec-claims/gates/<plan-stem>/chunk-<n>.json:
#   1. Refused before anything runs: a --chunk that is not a positive integer
#      without a leading zero, a plan path or record path that is not a safe
#      repo path of the gate-record shape (_JQ_CLAIMS_GATE_PATH), --holds
#      without --by or naming no claim (usage, exit 3); a dirty tree
#      (_claims_refuse_dirty), a plan absent at HEAD or without chunk <n>, a
#      gates directory reached through a symbolic link (exit 2).
#   2. from: --from, else the head of chunk-<n-1>.json (read from the work
#      tree, where the previous gate wrote it, as attest reads a record:
#      exactly one JSON object, its head a hex commit id), else _CL_MB. A
#      from that is not a commit, or not an ancestor of HEAD, and a
#      chunk-<n-1>.json that is not one JSON object or whose head is not
#      hex, are indeterminate (exit 2) and no record is written:
#      <from>..HEAD would not be this branch's work, and is never taken as
#      empty.
#   3. The claims the chunk names on its **Claims:** lines, plus the
#      --planes-of selection of <from>..HEAD and each lint, log or judge
#      claim in the plan's scope that <from>..HEAD moved into built or gated
#      (_JQ_CLAIMS_GATE_EDITED: its reviewed status edit, which step 6
#      records as reconciled), run through the run core
#      (_claims_run_selected): the record's claims and verdicts.
#   4. A named id no claim has is a finding; so is a named claim still
#      unbuilt that no DOC-STALE ruling included in this record covers
#      ("chunk was meant to build it: promote, rule, or defer"; a deferral
#      moves it to diverged and a RETIRE to retired, so neither leaves it
#      unbuilt; a CODE-DIVERGES ruling alone never clears it), and a run
#      claim for which _claims_repromote_owed prints owed ("re-promote
#      owed"), even when its check passes (decided by promotion.proved, so
#      the same in a fresh clone).
#   5. V8 (_claims_v8: the lines the range added, by blame), V8n
#      (_claims_v8n: the same lines, the descriptive ones) and V9 over
#      <from>..HEAD, read by the range rule; every finding
#      blocks (_CL_ALL_BLOCKING). A V9 id given in --holds is held: no
#      finding, and a states-holds reconciliation by --by.
#   6. Reconciliations: the record-inclusion rule (claims_reconciliations,
#      shared with attest's final.json) over the sidecar changes from <from>
#      to HEAD on the claims in scope — those run, every claim the plan names
#      on any Claims line, and every claim of a doc the plan's Specs lists
#      name. Each change it does not include is unrecorded: a finding
#      "silent reconciliation". An included promotion whose verdict is not
#      in the local store adds the advisory unverifiable-here; inclusion is
#      by digest, never by the store.
#   7. The record {schema: 1, plan, chunk, base, from, head, tree, commits
#      (_claims_patch_ids <from>..HEAD), claims, verdicts, checks {V8, V8n,
#      V9}, reconciliations, unrecorded, result} is written atomically, even
#      when red: result red (a finding), else indeterminate (an
#      indeterminate row), else pass. The verdict object carries it too
#      (with its path as record; base is the verdict's own).
# Scratch: cl-gate-* (the plan, the selections, the from-tree claims, the
# reconciliations, the check rows and the record).

# The record-inclusion rule. claims_reconciliations($record_path), on {from,
# head, scope} (from, head: cl-claims entries of the sidecars at <from> and
# at HEAD; scope: claim ids), compares each claim in scope (by id, its first
# record at HEAD) with its record at <from> — one pass over the two
# revisions — and returns {reconciliations, unrecorded}:
#   - each new ruling (JSON-equal to none of the claim's rulings at <from>)
#     is included only when its record is $record_path;
#   - a new promotion (a promotion object that differs from the one at
#     <from>) is always included, storing its verdict_sha256 (attest
#     matches a sidecar promotion by that digest, never by the local store);
#   - a status change (a claim new since <from> counts from unbuilt) is
#     included only when the claim has an included ruling or promotion, or
#     when it moves a lint, log or judge claim into built or gated (its
#     reviewed status edit: such a claim is never promoted, and the gate
#     runs its check, _JQ_CLAIMS_GATE_EDITED);
#   - every change not included is unrecorded {claim, kind, ruling}.
# An included entry is {claim, kind (ruling | promotion | status), ruling
# (the ruling, or null), from_status (null for a claim new since <from>),
# to_status, verdict_sha256 (the promotion's, or null)}. It reads only the
# sidecars and the record path, so every clone gives the same answer.
# claims_changes($record_path) is the same pass's every change, each such an
# entry plus inc (whether it is included): attest reads all the changes from
# _CL_MB with it ($record_path null, scope null for every claim). cl_rul (a
# claim's rulings, [] when it has none) and cl_by_id (cl-claims entries →
# {<id>: the first claim record with that id}) are shared with the amendment
# batch (_JQ_CLAIMS_RULINGS).
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RECONCILE='def cl_rul: if type == "object" and (.rulings | type) == "array" then .rulings else [] end;
def cl_by_id: reduce (.[] | .claim | select(type == "object" and (.id | type) == "string")) as $c
  ({}; if has($c.id) then . else .[$c.id] = $c end);
def claims_changes($record_path):
  (.from | cl_by_id) as $was
  | .scope as $scope
  | (.head | cl_by_id) as $now
  | [$now[] | select(.id as $i | $scope == null or any($scope[]; . == $i))]
  | [.[] | . as $c | $was[$c.id] as $o
     | ($o | cl_rul) as $old
     | [$c | cl_rul | .[] | . as $r | select(any($old[]; . == $r) | not)] as $new
     | (($c.promotion | type) == "object" and $c.promotion != $o.promotion) as $promoted
     | (if $o == null then $c.status != "unbuilt" else $o.status != $c.status end) as $moved
     | ($c.enforced_by as $t | any("lint", "log", "judge"; . == $t)
        and ($c.status == "built" or $c.status == "gated")) as $edited
     | [$new[] | {claim: $c.id, kind: "ruling", ruling: ., from_status: $o.status, to_status: $c.status,
                  verdict_sha256: null, inc: (type == "object" and .record == $record_path)}] as $rs
     | ($rs | any(.[]; .inc)) as $ruled
     | $rs[],
       (if $promoted then {claim: $c.id, kind: "promotion", ruling: null, from_status: $o.status,
          to_status: $c.status, inc: true,
          verdict_sha256: ($c.promotion.verdict_sha256 | if type == "string" then . else null end)}
        else empty end),
       (if $moved then {claim: $c.id, kind: "status", ruling: null, from_status: $o.status,
          to_status: $c.status, verdict_sha256: null, inc: ($ruled or $promoted or $edited)}
        else empty end)];
def claims_reconciliations($record_path):
  claims_changes($record_path)
  | {reconciliations: [.[] | select(.inc) | del(.inc)],
     unrecorded: [.[] | select(.inc | not) | {claim, kind, ruling}]};'

# The claims a gate runs for their reviewed status edits ($f, $h: cl-claims
# entries at <from> and HEAD; $s: the plan's scope; after
# _JQ_CLAIMS_RECONCILE): each lint, log or judge claim in scope that
# <from>..HEAD moved into built or gated (new since <from>: from unbuilt).
# The record-inclusion rule records that move as reconciled, so the chunk
# gate (from: its <from>) and attest (from: _CL_MB) run its check whether or
# not a Claims line names it.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_GATE_EDITED='($f[0] | cl_by_id) as $was
 | [$h[0] | cl_by_id | .[]
    | select(.id as $i | any($s[0][]; . == $i))
    | select(.enforced_by as $t | any("lint", "log", "judge"; . == $t))
    | select(.status == "built" or .status == "gated")
    | select(($was[.id] // null) as $o | $o == null or $o.status != .status)
    | .id]'

# _claims_plan_scope <plan-json> <ids-json> <out-file>: the claims a plan
# answers for, as a sorted JSON array of ids — those of <ids-json> (a file
# holding a JSON array), every id a **Claims:** line of the plan names, and
# every claim (cl-claims.json) of a doc its Specs lists (or governing_specs:)
# name. The gate's reconciliation scope (<ids-json>: the claims it ran) and
# attest's cross-check scope: one definition, so the two cannot disagree.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_plan_scope() {
  _claims_jq plan-scope -nc --slurpfile p "$1" --slurpfile x "$2" --slurpfile c "$_SCRATCH/cl-claims.json" \
    '($x[0] + [$p[0].chunks[].tasks[].claims[]]
      + [$c[0][] | select(.doc as $d | any($p[0].specs[]; .path == $d)) | .claim.id | strings]) | unique' > "$3"
}

# The rule gate and attest share for the claims a plan names ($c:
# cl-claims entries; $all: the included reconciliations; on the named ids).
# cl_named_findings($c; $all; $check; $unknown; $unbuilt): a finding row
# {check, claim, doc, message} for each named id no claim has (message
# $unknown) and each named claim still unbuilt that no DOC-STALE ruling among
# $all covers (message $unbuilt). A CODE-DIVERGES ruling must defer the claim
# to diverged, a RETIRE retire it: neither leaves it unbuilt, so only a
# recorded DOC-STALE ruling (the doc amended to what was built) clears it.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_NAMED='def cl_named_findings($c; $all; $check; $unknown; $unbuilt):
  .[] | . as $i | (first($c[] | select(.claim.id == $i)) // null) as $e
  | if $e == null then {check: $check, claim: $i, doc: null, message: $unknown}
    elif $e.claim.status == "unbuilt"
         and (any($all[]; .claim == $i and .kind == "ruling"
                  and (.ruling | type) == "object" and .ruling.direction == "DOC-STALE") | not)
    then {check: $check, claim: $i, doc: $e.doc, message: $unbuilt}
    else empty end;'

# _claims_promotions_unverifiable <check> <recon-file>: for each promotion
# among the reconciliations in <recon-file> (a JSON array) whose verdict is
# not in the local store (_claims_verdict_check: missing), the advisory
# unverifiable-here. Inclusion is by digest, never by the store: this only
# says the store cannot confirm it here.
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_promotions_unverifiable() {
  local check="$1" list="$_SCRATCH/cl-unverifiable-ids" id x
  _claims_jq promotions -r '.[] | select(.kind == "promotion") | .claim | select(test("\n") | not)' "$2" > "$list"
  while IFS= read -r id <&3; do
    x=$(_claims_jq promoted -c --arg id "$id" 'first(.[] | select(.claim.id == $id) | .claim)' \
      "$_SCRATCH/cl-claims.json") || _claims_propagate $?
    x=$(_claims_verdict_check "$x") || _claims_propagate $?
    if [ "$x" = missing ]; then
      _claims_advisory "$check" "$id" unverifiable-here \
        "the promotion's verdict is not in the local verdict store (promoted in another clone?): it is recorded by its digest; the scheduled run re-verifies it"
    fi
  done 3< "$list"
}

# _claims_owed_findings <check> <since-rev>: for each claim the last run
# planned and did not skip (cl-run-plan.json), _claims_repromote_owed: owed
# is a finding "re-promote owed".
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_owed_findings() {
  local check="$1" since="$2" list="$_SCRATCH/cl-owed-ids" id x
  _claims_jq owed-ids -r '.[] | select(.action != "skip") | .claim | select(test("\n") | not)' \
    "$_SCRATCH/cl-run-plan.json" > "$list"
  while IFS= read -r id <&3; do
    x=$(_claims_repromote_owed "$id" "$since") || _claims_propagate $?
    if [ "$x" = owed ]; then
      _claims_finding "$check" "$id" - "re-promote owed: run claims promote $id"
    fi
  done 3< "$list"
}

# _claims_gate_path_ok <record> <stem>: 0 when <record> is a safe repo path
# of the gate-record shape whose stem is <stem> (cl_gate_stem).
# shellcheck disable=SC2016  # jq program, not shell expansion
_claims_gate_path_ok() {
  _claims_safe_relpath "$1" || return 1
  # Its status is the answer, so not _claims_jq.
  jq -e -n --arg p "$1" --arg s "$2" "$_JQ_CLAIMS_GATE_PATH"' $p | cl_gate_stem == $s' >/dev/null 2>&1
}

# _claims_gate_indet <reason>: the gate could not run: indeterminate, the
# verdict printed (exit 2), no record written.
_claims_gate_indet() {
  _claims_indeterminate gate - "$1"
  _claims_emit gate
}

# _claims_gate_write <record> <file>: <file> installed as the work tree's
# <record> (the directory made first), atomically; never through a
# symbolic link or out of the work tree.
_claims_gate_write() {
  _claims_safe_relpath "$1" || _claims_die "refusing to write $1: not a safe repo path"
  _claims_contained_path "$1" || _claims_die "refusing to write $1: reached through a symbolic link or outside the work tree"
  mkdir -p "${1%/*}" 2>/dev/null || _claims_die "cannot create ${1%/*}"
  _claims_contained_path "$1" || _claims_die "refusing to write $1: reached through a symbolic link or outside the work tree"
  _tmp_beside "$1"
  cat "$2" > "$_TMP" || _claims_die "cannot write $1"
  _replace_file "$_TMP" "$1"
}

# gate: see the section comment.
# shellcheck disable=SC2016  # jq programs, not shell expansion
cmd_claims_gate() {
  local plan="$_OPT_plan" n="$_OPT_chunk" by="$_OPT_by" stem rec prev head from x id range tree result
  _CL_ALL_BLOCKING=1
  _claims_init head
  [ -n "$plan" ] || _usage_error "claims gate" "requires --plan <plan>"
  [ -n "$n" ] || _usage_error "claims gate" "requires --chunk <n>"
  case "$n" in
    0*|*[!0123456789]*|??????????*)
      _usage_error "claims gate" "--chunk must be a positive integer without a leading zero, at most 9 digits (got '$n')" ;;
  esac
  _claims_no_args "claims gate" "$@"
  _claims_safe_relpath "$plan" \
    || _usage_error "claims gate" "--plan must be a repo path: relative, with no empty, . or .. segment (got '$plan')"
  stem=${plan##*/}
  stem=${stem%.*}
  rec="docs/spec-claims/gates/$stem/chunk-$n.json"
  _claims_gate_path_ok "$rec" "$stem" || _usage_error "claims gate" "--plan '$plan' gives no gate record path ($rec)"
  if [ ${#_OPTV_holds[@]} -gt 0 ] && [ -z "$by" ]; then
    _usage_error "claims gate" "--holds needs --by <principal>: who adjudicated that the claim's states still holds"
  fi
  local pj="$_SCRATCH/cl-gate-plan.json" named="$_SCRATCH/cl-gate-named.json" psel="$_SCRATCH/cl-gate-planes.json"
  local sel="$_SCRATCH/cl-gate-sel.json" holds="$_SCRATCH/cl-gate-holds.json" list="$_SCRATCH/cl-gate-list"
  local fromc="$_SCRATCH/cl-gate-from.json" scope="$_SCRATCH/cl-gate-scope.json" recon="$_SCRATCH/cl-gate-recon.json"
  local included="$_SCRATCH/cl-gate-included.json" edited="$_SCRATCH/cl-gate-edited.json"
  local v8="$_SCRATCH/cl-gate-v8.jsonl" v8n="$_SCRATCH/cl-gate-v8n.jsonl" v9="$_SCRATCH/cl-gate-v9.jsonl"
  local v9c="$_SCRATCH/cl-gate-v9-checks.jsonl" commits="$_SCRATCH/cl-gate-commits.json" out="$_SCRATCH/cl-gate-record.json"
  _claims_load
  if [ ${#_OPTV_holds[@]} -gt 0 ]; then
    printf '%s\n' "${_OPTV_holds[@]}" > "$list"
  else
    : > "$list"
  fi
  _claims_jq gate-holds -Rsc 'split("\n") | map(select(. != "")) | reduce .[] as $h ([]; if any(.[]; . == $h) then . else . + [$h] end)' \
    "$list" > "$holds"
  x=$(_claims_jq gate-holds-unknown -r --slurpfile c "$_SCRATCH/cl-claims.json" \
    '[.[] | select(. as $i | any($c[0][]; .claim.id == $i) | not)] | join(", ")' "$holds") || _claims_propagate $?
  [ -z "$x" ] || _usage_error "claims gate" "--holds: no claim has the id $x"

  # 1. The preconditions that are not usage.
  _claims_refuse_dirty gate
  _claims_contained_path "$rec" || _claims_die "refusing to write $rec: reached through a symbolic link or outside the work tree"
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || _claims_die "cannot resolve HEAD"
  [ "$(git cat-file -t "$head:$plan" 2>/dev/null)" = blob ] || _claims_die "plan $plan is not at HEAD (commit it first)"
  _claims_plan_parse "$plan" "rev:$head" > "$pj"
  if ! jq -e --argjson n "$n" 'any(.chunks[]; .n == $n)' "$pj" >/dev/null 2>&1; then
    _claims_die "plan $plan has no chunk $n"
  fi

  # 2. from.
  prev="docs/spec-claims/gates/$stem/chunk-$((n - 1)).json"
  if [ -n "$_OPT_from" ]; then
    from=$(git rev-parse -q --verify "$_OPT_from^{commit}" 2>/dev/null) \
      || _claims_gate_indet "--from '$_OPT_from' is not a commit"
    x="--from $_OPT_from"
  elif [ "$n" -gt 1 ] && { [ -e "$prev" ] || [ -L "$prev" ]; }; then
    _claims_contained_path "$prev" && [ -f "$prev" ] \
      || _claims_gate_indet "chunk $((n - 1))'s record $prev is reached through a symbolic link or is not a file"
    # Its output is the answer (a record jq cannot parse: not JSON), so not
    # _claims_jq. Read as attest reads a record: slurped, exactly one object,
    # so a valid prefix with more after it (garbage, which jq 1.6 reads past
    # and exits 0; a second value) is never taken for the record; and its
    # head a hex commit id (attest's hexid), so a ref name or a symbolic
    # head ("HEAD": the empty range HEAD..HEAD) is never resolved. "=" leads
    # a usable head and "!" any other (as JSON); empty output (jq 1.6 -s
    # exits 0 on input it cannot parse) is neither.
    x=$(jq -r -s 'def hexid: type == "string" and test("^[0-9a-f]{7,64}$");
        if length == 1 and (.[0] | type) == "object"
        then .[0].head | if hexid then "=" + . else "!" + tojson end else "" end' "$prev" 2>/dev/null) || x=""
    case "$x" in
      =*) x=${x#=} ;;
      "!"*) _claims_gate_indet "chunk $((n - 1))'s record $prev names no commit head (head: ${x#"!"})" ;;
      *) _claims_gate_indet "chunk $((n - 1))'s record $prev is not one JSON object" ;;
    esac
    from=$(git rev-parse -q --verify "$x^{commit}" 2>/dev/null) || from=""
    [ -n "$from" ] || _claims_gate_indet "chunk $((n - 1))'s record $prev names no commit head (head: ${x:-none})"
    x="the head of $prev"
  else
    # _claims_init already reported an unresolvable base.
    [ -n "$_CL_MB" ] || _claims_emit gate
    from=$_CL_MB
    x="the merge-base"
  fi
  git merge-base --is-ancestor "$from" "$head" 2>/dev/null \
    || _claims_gate_indet "from $from ($x) is not an ancestor of HEAD: $from..HEAD would not be this branch's work"
  range="$from..HEAD"

  # 3. The chunk's named claims, the --planes-of selection, and the lint,
  # log and judge claims the range moved into built or gated, run.
  _claims_jq gate-named -c --argjson n "$n" '[.chunks[] | select(.n == $n) | .tasks[] | .claims[]] | unique' "$pj" > "$named"
  _claims_planes_sel "$range" "$psel"
  _claims_load_tree "$from" "$_SCRATCH/cl-gate-sidecars-from.jsonl"
  _claims_jq gate-from-claims -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" \
    "$_SCRATCH/cl-gate-sidecars-from.jsonl" > "$fromc"
  _claims_plan_scope "$pj" "$named" "$scope"
  _claims_jq gate-edited -nc --slurpfile f "$fromc" --slurpfile h "$_SCRATCH/cl-claims.json" --slurpfile s "$scope" \
    "$_JQ_CLAIMS_RECONCILE $_JQ_CLAIMS_GATE_EDITED" > "$edited"
  _claims_jq gate-sel -nc --slurpfile a "$named" --slurpfile b "$psel" --slurpfile e "$edited" \
    --slurpfile c "$_SCRATCH/cl-claims.json" \
    '$a[0] + $b[0] + $e[0] | unique | map(select(. as $i | any($c[0][]; .claim.id == $i)))' > "$sel"
  _claims_run_selected "$sel" 0

  # 6. (first: step 4 reads it) The reconciliations, over the claims in scope.
  _claims_jq gate-run-ids -c '[.[].claim]' "$_SCRATCH/cl-run-plan.json" > "$list"
  _claims_plan_scope "$pj" "$list" "$scope"
  _claims_jq gate-reconcile -nc --slurpfile f "$fromc" --slurpfile h "$_SCRATCH/cl-claims.json" \
    --slurpfile s "$scope" --slurpfile hold "$holds" --arg rec "$rec" --arg by "$by" \
    "$_JQ_CLAIMS_RECONCILE"' {from: $f[0], head: $h[0], scope: $s[0]} | claims_reconciliations($rec)
     | .reconciliations += [$hold[0][] | {claim: ., kind: "states-holds", by: $by}]' > "$recon"
  _claims_jq gate-unrecorded -c --arg rec "$rec" \
    '.unrecorded[] | {check: "gate", claim, doc: null,
      message: "silent reconciliation: this \(.kind) since the chunk began is not recorded in \($rec) (a ruling made during the chunk must name \($rec) as its record; a status change needs a ruling or a promotion recorded there, unless it moves a lint, log or judge claim into built or gated)"}' \
    "$recon" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq gate-recon-included -c '.reconciliations' "$recon" > "$included"
  _claims_promotions_unverifiable gate "$included"

  # 4. The named claims, and re-promotions owed by the claims run.
  _claims_jq gate-named-findings -c --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile r "$included" \
    --arg unknown "named on chunk $n's **Claims:** line, but no claim has this id" \
    "$_JQ_CLAIMS_NAMED"' cl_named_findings($c[0]; $r[0]; "gate"; $unknown;
       "chunk was meant to build it: promote, rule, or defer")' "$named" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_owed_findings gate "$from"

  # 5. V8, V8n and V9 over the range; --holds ids held.
  : > "$v8"
  : > "$v8n"
  : > "$v9"
  _claims_v8 "$range" "$v8"
  _claims_v8n "$range" "$v8n"
  _claims_v9 "$range" "$v9"
  cat "$v8" "$v8n" >> "$_SCRATCH/cl-findings.jsonl" || _claims_die "cannot write the findings"
  _claims_jq gate-v9-held -c --slurpfile h "$holds" '. + {held: (.claim as $c | any($h[0][]; . == $c))}' "$v9" > "$v9c"
  _claims_jq gate-v9-findings -c 'select(.held | not) | del(.held)' "$v9c" >> "$_SCRATCH/cl-findings.jsonl"

  # 7. The record, even when red.
  result=pass
  if [ -s "$_SCRATCH/cl-findings.jsonl" ]; then
    result=red
  elif [ -s "$_SCRATCH/cl-indet.jsonl" ]; then
    result=indeterminate
  fi
  tree=$(git rev-parse -q --verify "$head^{tree}" 2>/dev/null) || _claims_die "cannot resolve HEAD's tree"
  _claims_patch_ids "$range" > "$commits"
  _claims_jq gate-record -n --arg plan "$plan" --argjson chunk "$n" --arg base "$_CL_MB" --arg from "$from" \
    --arg head "$head" --arg tree "$tree" --arg result "$result" --slurpfile commits "$commits" \
    --slurpfile rp "$_SCRATCH/cl-run-plan.json" --slurpfile res "$_SCRATCH/cl-run-results.json" \
    --slurpfile v8 "$v8" --slurpfile v8n "$v8n" --slurpfile v9 "$v9c" --slurpfile recon "$recon" \
    '{schema: 1, plan: $plan, chunk: $chunk, base: (if $base == "" then null else $base end),
      from: $from, head: $head, tree: $tree, commits: $commits[0], claims: [$rp[0][].claim],
      verdicts: [$res[0][] | {claim, status, outcome, verdict}],
      checks: {V8: $v8, V8n: $v8n, V9: $v9},
      reconciliations: $recon[0].reconciliations, unrecorded: $recon[0].unrecorded, result: $result}' > "$out"
  _claims_gate_write "$rec" "$out"
  x=$(_claims_jq gate-extra -c --arg p "$rec" 'del(.base) + {record: $p}' "$out") || _claims_propagate $?
  _claims_emit gate "$x"
}

cmd_claims_validate() {
  local mode=all kv
  if [ "$_OPT_staged" = 1 ]; then mode=staged; fi
  _claims_init "$mode"
  if [ "$_OPT_staged" = "$_OPT_all" ]; then
    _usage_error "claims validate" "give exactly one of --staged and --all"
  fi
  _claims_no_args "claims validate" "$@"
  # --config KEY=VALUE (repeatable): V10 over a configuration change made
  # outside git, so the configuration extension must be on.
  for kv in ${_OPTV_config[@]+"${_OPTV_config[@]}"}; do
    case "${kv%%=*}" in
      "$kv"|'') _usage_error "claims validate" "--config takes KEY=VALUE, KEY not empty (got '$kv')" ;;
      *$'\n'*) _usage_error "claims validate" "--config: KEY holds a newline (got '$kv')" ;;
    esac
  done
  if [ ${#_OPTV_config[@]} -gt 0 ] && ! _claims_b1_on; then
    _usage_error "claims validate" "--config needs the configuration extension (config config_adapter names an adapter)"
  fi
  _claims_v1_config
  _claims_load
  _claims_touched
  # The configuration extension (§B.1): one recorded call, V1 and V3 share it.
  printf 'null\n' > "$_SCRATCH/cl-recorded.json" || _claims_die "cannot write cl-recorded.json"
  if _claims_b1_on; then
    if [ "$mode" = staged ]; then _claims_recorded --staged || true; else _claims_recorded || true; fi
  fi
  _claims_v1
  _claims_v2
  _claims_v3
  _claims_v4
  _claims_v5
  _claims_v6
  _claims_v7
  if [ "$mode" = staged ]; then
    _claims_v8 --staged
    _claims_v8n --staged
  else
    _claims_v8 --all
    _claims_v8n --all
  fi
  if [ "$mode" = staged ]; then
    _claims_v9 --staged
  elif [ -n "$_CL_MB" ]; then
    _claims_v9 "$_CL_MB..HEAD"
  fi
  _claims_v10
  _claims_v12
  _claims_blocks validate
  _claims_emit validate
}

# promote <id> (see "promote, the nonvacuity proofs"). The base is never
# read, so an unresolvable one is not indeterminate here.
# promote --reverify (<id>… | --all): each claim re-proved (_claims_reverify)
# at HEAD in a clean tree; --all takes _JQ_CLAIMS_REVERIFY_ALL's claims (a
# frozen one reported skipped), and each <id> named must be a claim (else a
# usage error, before anything runs).
cmd_claims_promote() {
  local ids x id
  local sel=()
  _CL_ALL_BLOCKING=1
  _CL_BASE_UNUSED=1
  _claims_init head
  if [ "$_OPT_reverify" = 1 ]; then
    if [ "$_OPT_all" = 1 ]; then
      [ $# -eq 0 ] || _usage_error "claims promote" "--reverify --all takes no <id> (got '$1')"
    else
      [ $# -gt 0 ] || _usage_error "claims promote" "--reverify requires <id>... or --all"
    fi
    _claims_refuse_dirty promote
    _claims_load
    ids="$_SCRATCH/cl-reverify.z"
    if [ "$_OPT_all" = 1 ]; then
      _claims_jq reverify-all -j "$_JQ_CLAIMS_REVERIFY_ALL" "$_SCRATCH/cl-claims.json" > "$ids"
    else
      : > "$ids"
      for id in "$@"; do
        # shellcheck disable=SC2016  # jq program, not shell expansion
        x=$(_claims_jq reverify-known -r --arg id "$id" 'any(.[]; .claim.id == $id)' "$_SCRATCH/cl-claims.json") \
          || _claims_propagate $?
        [ "$x" = true ] || _usage_error "claims promote" "no claim has the id $id"
        printf 'r%s\0' "$id" >> "$ids"
      done
    fi
    while IFS= read -r -d '' id; do sel+=("$id"); done < "$ids"
    for id in ${sel[@]+"${sel[@]}"}; do
      case "$id" in
        s*)
          # shellcheck disable=SC2016  # jq program, not shell expansion
          x=$(_claims_jq reverify-skipped -nc --arg c "${id#s}" '{claim: $c, verdict: "skipped"}') \
            || _claims_propagate $?
          _claims_result "$x"
          ;;
        *) _claims_reverify "${id#r}" ;;
      esac
    done
    _claims_emit promote
  fi
  [ "$_OPT_all" != 1 ] || _usage_error "claims promote" "--all requires --reverify"
  [ $# -eq 1 ] || _usage_error "claims promote" "requires exactly one claim <id> (got $#)"
  _claims_refuse_dirty promote
  _claims_load
  _claims_promote "$1"
  _claims_emit promote
}

# render: every eligible sidecar's doc gets its status block (_claims_blocks).
# Every finding blocks: --check exits 1 on any doc that differs. The base is
# never read, so an unresolvable one is not indeterminate here.
cmd_claims_render() {
  _CL_ALL_BLOCKING=1
  _CL_BASE_UNUSED=1
  _claims_init all
  _claims_no_args "claims render" "$@"
  _claims_load
  _claims_touched
  if [ "$_OPT_check" = 1 ]; then
    _claims_blocks check
  else
    _claims_blocks write
  fi
  _claims_emit render
}

# --- Spec claims: claims attest, the final gate; claims rulings ----------------
#
# claims attest --plan <p> [--final] [--deep] checks a plan's gate records
# against the branch at HEAD: the claims as HEAD holds them (mode head),
# their checks run in the work tree, which --final requires clean
# (_claims_refuse_dirty: exit 2, nothing written; the gate records'
# directory aside). The plan is read from HEAD. Every finding blocks.
#   1. Records: each chunk of the plan with a gate task needs its record
#      docs/spec-claims/gates/<stem>/chunk-<n>.json, read from the work tree
#      (never through a symbolic link): one JSON object of this plan and
#      chunk, with a commit head, a commits list of {sha, patch_id} and a
#      reconciliations list (_JQ_CLAIMS_ATTEST_RECORD). Else a finding
#      "chunk <n>: no gate record" (or why the record is unusable), and the
#      record counts for nothing. Its commits are matched by patch_id
#      against _claims_patch_ids "$_CL_MB..HEAD" (the range rule): one
#      unmatched (a squash, a rebase that changed a patch) marks the record
#      rebased "re-verified" — step 2 re-runs its claims at HEAD — never a
#      finding; a clean rebase keeps every patch id, and no mark.
#   2. Claims: every claim a **Claims:** line of the plan names, and each
#      lint, log or judge claim in the plan's scope that _CL_MB..HEAD moved
#      into built or gated (_JQ_CLAIMS_GATE_EDITED: its reviewed status
#      edit), runs at HEAD (_claims_run_selected: built and gated must pass,
#      diverged fail by an assertion); a named diverged claim also needs its CODE-DIVERGES
#      ruling and an open tracker (V5). A named id no claim has is a
#      finding; so is a named claim still unbuilt ("named claim still
#      unbuilt at the final gate") unless an included reconciliation — of a
#      chunk record, or of final.json (step 3) — holds a DOC-STALE ruling on
#      it: a CODE-DIVERGES ruling must defer it to diverged, a RETIRE retire
#      it. _claims_repromote_owed <id> on each claim run: owed is a finding
#      ("re-promote owed"), even when its check passes. The answer comes
#      from promotion.proved, never from the verdict store or history, so a
#      plan that converged locally passes in a fresh clone or CI, and after
#      a squash or rebase merge.
#   3. Reconciliations. final.json's are rebuilt on every run by the
#      record-inclusion rule (claims_reconciliations with final.json's
#      path) over the sidecars from <from> — the last usable chunk record's
#      head — to HEAD, on the plan's scope (_claims_plan_scope, the gate's:
#      the claims the plan names, and every claim of a doc its Specs lists
#      name). A ruling counts there only when its record is final.json: one
#      citing an issue doc or a chunk record is never absorbed. The
#      cross-check: every change on those claims from _CL_MB to HEAD
#      (claims_changes) must be among the reconciliations of a chunk record
#      or of final.json — a ruling by JSON equality, a promotion by its
#      verdict_sha256 (the digest the record stored, never the local store),
#      a status change by a status entry for the claim with the same
#      to_status — else the finding "silent reconciliation"
#      (cross_check.unrecorded {claim, kind, ruling}); so is each change
#      final.json's own pass leaves unrecorded (a change since <from> it
#      does not include, though the cross-check matched it). Each ruling a chunk
#      record reconciled must still be one of its claim's rulings at HEAD,
#      else "reconciliation reverted at HEAD" (cross_check.reverted {claim,
#      record, ruling}). An included promotion whose verdict is not in the
#      local store adds the advisory unverifiable-here, as at the gate.
#   4. Amendments: the amendment batch of _CL_MB..HEAD (_claims_rulings_rows,
#      what claims rulings lists).
#   5. render --check (V11): render_check ok, or failed with its findings.
# <from> is the last usable record's head when that is a commit here. A
# rebased branch's old head that is not (a fresh clone) maps only to its
# rebased twin: the one first-parent non-merge commit of _CL_MB..HEAD whose
# patch id is that of the head's own entry in the record's commits
# (advisory from-remapped). No twin — the head is not one of the record's
# own commits (a merge, a chunk with no commit), no branch commit carries
# its patch, or several do — makes the run indeterminate (exit 2, nothing
# written: re-run that chunk's gate). The window is never widened: an
# earlier <from> would absorb into final.json a ruling made before the last
# chunk's gate. With no usable record it is _CL_MB. An unresolvable base
# makes the run indeterminate too.
# --deep re-runs each usable record's claims in a throwaway worktree at its
# head (_claims_worktree_add, removed after each record; never a repository
# -wide prune): each claim as that head holds it, judged by its status
# there, its runner's adapter called with --root the worktree. Lint claims
# are reported skipped (--deep re-runs test claims), log and judge claims
# too, as run skips them. A head that is not a commit here (a missing
# object) is indeterminate; a record whose tree is not its head's tree is a
# finding.
# --final writes docs/spec-claims/gates/<stem>/final.json — {schema: 1,
# plan, base, head, tree, from, chunks [{chunk, record, rebased}], claims
# [{claim, status, verdict}], reconciliations, cross_check {unrecorded,
# reverted}, amendments, render_check, result} with result pass, fail (a
# finding) or indeterminate — atomically (_claims_gate_write), even when the
# result is not pass, so a ruling made at the final gate can cite it before
# the re-run. The verdict object carries the same (base is its own; with
# --final, record names the file).
# Scratch: cl-attest-* (the plan, the records, the scope, the
# reconciliations, the cross-check, the batch, the record), cl-deep-*
# (--deep's claims, plan and runs) and cl-rulings-* (the batch's trees).

# The amendment batch over two revisions' claims ($a, $b: cl-claims
# entries, slurped; after _JQ_CLAIMS_RECONCILE): one row per DOC-STALE or
# RETIRE ruling of a claim at <b> that no ruling of the same claim at <a>
# equals (JSON), in sidecar order — {claim, doc, direction, by, date,
# reason, approved: {quote, states} as <a> holds the claim (null for a claim
# new since <a>), new: {quote, states} as <b> holds it}.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RULINGS='($a[0] | cl_by_id) as $was
 | [$b[0][] | select((.claim | type) == "object" and (.claim.id | type) == "string")
    | .doc as $doc | .claim as $c | $was[$c.id] as $o | ($o | cl_rul) as $old
    | $c | cl_rul | .[]
    | select(type == "object" and (.direction == "DOC-STALE" or .direction == "RETIRE"))
    | . as $r | select(any($old[]; . == $r) | not)
    | {claim: $c.id, doc: $doc, direction, by, date, reason,
       approved: (if $o == null then null else {quote: $o.quote, states: $o.states} end),
       new: {quote: $c.quote, states: $c.states}}]'

# The batch's rows as Markdown for a PR description: "## Spec amendments
# (N)", then per row "### <claim> — <direction>", **Approved:** (the
# states at <a>), **New:** (at <b>) and **Reason:**, each its own paragraph.
# A value that is not a string is its JSON; a newline is a space.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_RULINGS_MD='def md: if type == "string" then gsub("\r?\n"; " ") else tojson end;
 "## Spec amendments (\(length))",
 (.[] | "", "### \(.claim | md) — \(.direction | md)", "",
   "**Approved:** \(if .approved == null then "(none: a claim new in this range)" else (.approved.states | md) end)", "",
   "**New:** \(.new.states | md)", "",
   "**Reason:** \(.reason | md)")'

# _claims_rulings_rows <a> <b> <out-file>: the amendment batch of commits <a>
# and <b> (_JQ_CLAIMS_RULINGS), a JSON array, into <out-file>.
_claims_rulings_rows() {
  local ta="$_SCRATCH/cl-rulings-a.jsonl" tb="$_SCRATCH/cl-rulings-b.jsonl"
  _claims_gov_init
  _claims_load_tree "$1" "$ta"
  _claims_load_tree "$2" "$tb"
  _claims_jq rulings-a -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$ta" > "$ta.json"
  _claims_jq rulings-b -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$tb" > "$tb.json"
  _claims_jq rulings -nc --slurpfile a "$ta.json" --slurpfile b "$tb.json" \
    "$_JQ_CLAIMS_RECONCILE $_JQ_CLAIMS_RULINGS" > "$3"
}

# A chunk record (slurped; $plan, $n, $r its path) → "" when attest can use
# it, else why not.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_ATTEST_RECORD='def hexid: type == "string" and test("^[0-9a-f]{7,64}$");
 if length != 1 or (.[0] | type) != "object" then "gate record \($r) is not one JSON object"
 else .[0]
   | if .plan != $plan or .chunk != $n
     then "gate record \($r) is not chunk \($n) of \($plan) (plan \(.plan | tojson), chunk \(.chunk | tojson))"
     elif .head | hexid | not then "gate record \($r) names no commit head (head: \(.head | tojson))"
     elif (.commits | type) != "array" or (all(.commits[]; type == "object" and (.patch_id | type) == "string") | not)
     then "gate record \($r) has no commits list of {sha, patch_id}"
     elif (.reconciliations | type) != "array" or (all(.reconciliations[]; type == "object") | not)
     then "gate record \($r) has no reconciliations list"
     else "" end
 end'

# The cross-check ($recs: the usable records {chunk, record, data}; $f:
# final.json's rebuilt reconciliations; $fu: the changes that rebuild left
# unrecorded; $base, $h: cl-claims entries at _CL_MB and HEAD; $s: the
# scope; after _JQ_CLAIMS_RECONCILE) → {unrecorded, reverted} (see the
# section comment). unrecorded also holds each of $fu, once.
# shellcheck disable=SC2016  # jq program, not shell expansion
_JQ_CLAIMS_ATTEST_CROSS='([$recs[] | .data.reconciliations[]] + $f[0]) as $all
 | ($h[0] | cl_by_id) as $now
 | {unrecorded: ([{from: $base[0], head: $h[0], scope: $s[0]} | claims_changes(null) | .[] | . as $x
      | select(if .kind == "ruling" then
                 any($all[]; .kind == "ruling" and .claim == $x.claim and .ruling == $x.ruling)
               elif .kind == "promotion" then
                 $x.verdict_sha256 != null
                 and any($all[]; .kind == "promotion" and .claim == $x.claim and .verdict_sha256 == $x.verdict_sha256)
               else any($all[]; .kind == "status" and .claim == $x.claim and .to_status == $x.to_status) end
               | not)
      | {claim, kind, ruling}] + $fu[0] | unique),
    reverted: [$recs[] | .record as $rec | .data.reconciliations[] | select(.kind == "ruling") | . as $x
      | select((.claim | type) != "string" or (($now[$x.claim] | cl_rul) | any(.[]; . == $x.ruling) | not))
      | {claim, record: $rec, ruling}]}'

# _claims_attest_deep <n> <record-file>: --deep for chunk <n>'s usable
# record (see the section comment). Result rows {chunk, claim, status, node,
# outcome, verdict, message}; findings and indeterminate rows name the chunk.
# shellcheck disable=SC2016  # jq programs, not shell expansion
_claims_attest_deep() {
  local n="$1" rec="$2" h at t runner adapter rc node
  local scz="$_SCRATCH/cl-deep-sidecars.jsonl" cl="$_SCRATCH/cl-deep-claims.json" dsel="$_SCRATCH/cl-deep-sel.json"
  local plan="$_SCRATCH/cl-deep-plan.json" rows="$_SCRATCH/cl-deep-rows.jsonl" req="$_SCRATCH/cl-deep-req.json"
  local nodesz="$_SCRATCH/cl-deep-nodes" out="$_SCRATCH/cl-deep-out" one="$_SCRATCH/cl-deep-one.jsonl"
  local list="$_SCRATCH/cl-deep-list" res="$_SCRATCH/cl-deep-results.json"
  local nodes=()
  h=$(_claims_jq deep-head -r '.head' "$rec") || _claims_propagate $?
  if ! at=$(git rev-parse -q --verify "$h^{commit}" 2>/dev/null); then
    _claims_indeterminate attest - \
      "chunk $n: --deep: the recorded head $h is not a commit here (a missing object: fetch it, or re-run the chunk's gate)"
    return 0
  fi
  t=$(_claims_jq deep-tree -r '.tree | strings' "$rec") || _claims_propagate $?
  if [ "$t" != "$(git rev-parse -q --verify "$at^{tree}" 2>/dev/null)" ]; then
    _claims_finding attest - - "chunk $n: the record's tree ${t:-(none)} is not the tree of its head $at"
    return 0
  fi
  _claims_load_tree "$at" "$scz"
  _claims_jq deep-claims -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" "$scz" > "$cl"
  _claims_jq deep-sel -c '[.claims | if type == "array" then .[] | strings else empty end]' "$rec" > "$dsel"
  _claims_jq deep-plan -c --slurpfile sel "$dsel" --argjson scheduled 0 \
    "$_JQ_CLAIMS_LINT_DEFS"' $sel[0] as $sel | '"$_JQ_CLAIMS_RUN_PLAN"'
     | map(if .action == "lint" then .action = "skip" | .message = "lint: --deep re-runs test claims only" else . end)' \
    "$cl" > "$plan"
  : > "$rows"
  _claims_jq deep-runners -r '[.[] | select(.action == "test") | .runner] | unique | .[] | select(test("\n") | not)' \
    "$plan" > "$list"
  if [ -s "$list" ]; then
    _claims_worktree_add "$at"
    while IFS= read -r runner <&3; do
      _claims_jq deep-nodes -c --arg r "$runner" '[.[] | select(.action == "test" and .runner == $r) | .node] | unique' \
        "$plan" > "$req"
      _claims_jq deep-nodes-z -j '.[] | . + "\u0000"' "$req" > "$nodesz"
      nodes=()
      while IFS= read -r -d '' node; do nodes+=("$node"); done < "$nodesz"
      adapter=$(_claims_runner_adapter "$runner") || _claims_propagate $?
      rc=0
      _claims_adapter_call "$out" "$adapter" run --root "$_CL_WT" ${nodes[@]+"${nodes[@]}"} || rc=$?
      _claims_parse_run "$out" "$req" "$rc" > "$one"
      _claims_jq deep-rows -c --arg r "$runner" '. + {runner: $r}' "$one" >> "$rows"
    done 3< "$list"
    _claims_worktrees_remove
  fi
  _claims_jq deep-results -nc --slurpfile plan "$plan" --slurpfile rows "$rows" \
    "$_JQ_CLAIMS_EXPECT $_JQ_CLAIMS_RUN_RESULTS" > "$res"
  _claims_jq deep-result-rows -c --argjson n "$n" '.[] | {chunk: $n, claim, status, node, outcome, verdict, message}' \
    "$res" >> "$_SCRATCH/cl-results.jsonl"
  _claims_jq deep-findings -c --argjson n "$n" --arg at "$at" '.[] | select(.verdict == "finding")
      | {check: "attest", claim, doc, message: "chunk \($n), at its recorded head \($at): \(.message)"}' \
    "$res" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq deep-indeterminate -c --argjson n "$n" '.[] | select(.verdict == "indeterminate")
      | {check: "attest", claim, reason: "chunk \($n), at its recorded head: \(.reason // "indeterminate")"}' \
    "$res" >> "$_SCRATCH/cl-indet.jsonl"
}

# attest: see the section comment.
# shellcheck disable=SC2016  # jq programs, not shell expansion
cmd_claims_attest() {
  local plan="$_OPT_plan" stem fin head tree from x c n r i k id result render=ok
  _CL_ALL_BLOCKING=1
  _claims_init head
  [ -n "$plan" ] || _usage_error "claims attest" "requires --plan <plan>"
  _claims_no_args "claims attest" "$@"
  _claims_safe_relpath "$plan" \
    || _usage_error "claims attest" "--plan must be a repo path: relative, with no empty, . or .. segment (got '$plan')"
  stem=${plan##*/}
  stem=${stem%.*}
  fin="docs/spec-claims/gates/$stem/final.json"
  _claims_gate_path_ok "$fin" "$stem" || _usage_error "claims attest" "--plan '$plan' gives no gate record path ($fin)"
  local pj="$_SCRATCH/cl-attest-plan.json" named="$_SCRATCH/cl-attest-named.json" asel="$_SCRATCH/cl-attest-sel.json"
  local list="$_SCRATCH/cl-attest-list" branch="$_SCRATCH/cl-attest-branch.json" recs="$_SCRATCH/cl-attest-records.jsonl"
  local rows="$_SCRATCH/cl-attest-chunks.jsonl" one="$_SCRATCH/cl-attest-one.json" scope="$_SCRATCH/cl-attest-scope.json"
  local fromc="$_SCRATCH/cl-attest-from.json" frecon="$_SCRATCH/cl-attest-final-recon.json"
  local cross="$_SCRATCH/cl-attest-cross.json" amend="$_SCRATCH/cl-attest-amend.json"
  local saved="$_SCRATCH/cl-attest-results.jsonl" out="$_SCRATCH/cl-attest-record.json"
  local edited="$_SCRATCH/cl-attest-edited.json"
  local included="$_SCRATCH/cl-attest-included.json"

  # The preconditions that are not usage.
  if [ "$_OPT_final" = 1 ]; then
    _claims_refuse_dirty attest
    _claims_contained_path "$fin" || _claims_die "refusing to write $fin: reached through a symbolic link or outside the work tree"
  fi
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || _claims_die "cannot resolve HEAD"
  [ "$(git cat-file -t "$head:$plan" 2>/dev/null)" = blob ] || _claims_die "plan $plan is not at HEAD (commit it first)"
  # _claims_init already reported an unresolvable base: nothing to attest against.
  [ -n "$_CL_MB" ] || _claims_emit attest
  _claims_load
  _claims_touched
  _claims_plan_parse "$plan" "rev:$head" > "$pj"
  _claims_patch_ids "$_CL_MB..HEAD" > "$branch"

  # 1. The chunk records, matched by patch id.
  : > "$recs"
  : > "$rows"
  _claims_jq attest-gate-chunks -r '[.chunks[] | select(any(.tasks[]; .kind == "gate")) | .n] | unique | .[]' \
    "$pj" > "$list"
  while IFS= read -r n <&3; do
    r="docs/spec-claims/gates/$stem/chunk-$n.json"
    if [ ! -e "$r" ] && [ ! -L "$r" ]; then
      x="no gate record ($r: claims gate --plan $plan --chunk $n writes it)"
    elif ! _claims_contained_path "$r" || [ ! -f "$r" ]; then
      x="gate record $r is reached through a symbolic link or is not a file: it is never read"
    else
      # Its output is the answer (a record jq cannot parse: not JSON), so not
      # _claims_jq. "=" leads every answer, so empty output (jq 1.6 -s exits
      # 0 on input it cannot parse) is never read as "usable".
      x=$(jq -r -s --arg plan "$plan" --argjson n "$n" --arg r "$r" "$_JQ_CLAIMS_ATTEST_RECORD"' | "=" + .' "$r" \
        2>/dev/null) || x=""
      case "$x" in
        =*) x=${x#=} ;;
        *) x="gate record $r is not one JSON object" ;;
      esac
    fi
    if [ -n "$x" ]; then
      _claims_finding attest - - "chunk $n: $x"
      _claims_jq attest-chunk-unusable -nc --argjson n "$n" '{chunk: $n, record: null, rebased: null}' >> "$rows"
      continue
    fi
    _claims_jq attest-record-line -c -s --argjson n "$n" --arg r "$r" '{chunk: $n, record: $r, data: .[0]}' "$r" >> "$recs"
  done 3< "$list"
  _claims_jq attest-rebased -c --slurpfile b "$branch" \
    '{chunk, record, rebased: (if all(.data.commits[]; .patch_id as $p | any($b[0][]; .patch_id == $p)) then null
                               else "re-verified" end)}' "$recs" >> "$rows"

  # from: the last usable record's head, or its rebased twin (see the
  # section comment); never a wider window.
  from=$_CL_MB
  if [ -s "$recs" ]; then
    x=$(_claims_jq attest-last-head -r -s '.[-1].data.head' "$recs") || _claims_propagate $?
    if c=$(git rev-parse -q --verify "$x^{commit}" 2>/dev/null); then
      from=$c
    else
      # "<twin sha>", or "-<why not>".
      c=$(_claims_jq attest-from-twin -r -s --slurpfile b "$branch" \
        '.[-1].data as $d
         | [$d.commits[] | select(.sha == $d.head)] as $own
         | if ($own | length) != 1 then "-its head is not one of its own commits (a merge, or a chunk with no commit)"
           else [$b[0][] | select(.patch_id == $own[0].patch_id) | .sha] as $t
             | if ($t | length) == 1 then $t[0]
               elif ($t | length) == 0 then "-no commit of the branch carries its head'"'"'s patch"
               else "-\($t | length) commits of the branch carry its head'"'"'s patch" end
           end' "$recs") || _claims_propagate $?
      n=$(_claims_jq attest-last-chunk -r -s '.[-1].chunk' "$recs") || _claims_propagate $?
      case "$c" in
        -*)
          _claims_indeterminate attest - \
            "chunk $n's record names head $x, which is not a commit here, and it has no rebased twin: ${c#-}: re-run the gate for chunk $n (claims gate --plan $plan --chunk $n)"
          _claims_emit attest
          ;;
      esac
      from=$c
      _claims_advisory attest - from-remapped \
        "chunk $n's record names head $x, which is not a commit here (a rebased branch's old head): final.json's reconciliations are read from its rebased twin $from, the one branch commit with the head's patch id"
    fi
  fi

  # 2. The named claims, and the lint, log and judge claims the branch moved
  # into built or gated, run at HEAD; V5 on the diverged ones.
  _claims_jq attest-named -c '[.chunks[].tasks[].claims[]] | unique' "$pj" > "$named"
  _claims_plan_scope "$pj" "$named" "$scope"
  _claims_jq attest-edited -nc --slurpfile f "$_SCRATCH/cl-claims-base.json" --slurpfile h "$_SCRATCH/cl-claims.json" \
    --slurpfile s "$scope" "$_JQ_CLAIMS_RECONCILE $_JQ_CLAIMS_GATE_EDITED" > "$edited"
  _claims_jq attest-sel -c --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile e "$edited" \
    '. + $e[0] | unique | map(select(. as $i | any($c[0][]; .claim.id == $i)))' "$named" > "$asel"
  _claims_run_selected "$asel" 0
  _claims_jq attest-diverged -c --slurpfile s "$asel" \
    '[.[] | .claim | select(.status == "diverged" and (.id as $i | any($s[0][]; . == $i))) | .id] | unique' \
    "$_SCRATCH/cl-claims.json" > "$_SCRATCH/cl-touched.json"
  _claims_v5

  # 3. final.json's reconciliations, rebuilt; the cross-check.
  _claims_load_tree "$from" "$_SCRATCH/cl-attest-sidecars-from.jsonl"
  _claims_jq attest-from-claims -s --arg what claims "$_JQ_CLAIMS_SIDECAR $_JQ_CLAIMS_LOAD" \
    "$_SCRATCH/cl-attest-sidecars-from.jsonl" > "$fromc"
  _claims_jq attest-final-recon -nc --slurpfile f "$fromc" --slurpfile h "$_SCRATCH/cl-claims.json" \
    --slurpfile s "$scope" --arg rec "$fin" \
    "$_JQ_CLAIMS_RECONCILE"' {from: $f[0], head: $h[0], scope: $s[0]} | claims_reconciliations($rec)' \
    > "$frecon.all"
  _claims_jq attest-final-recon-included -c '.reconciliations' "$frecon.all" > "$frecon"
  _claims_jq attest-final-unrecorded -c '.unrecorded' "$frecon.all" > "$frecon.unrecorded"
  _claims_jq attest-cross -nc --slurpfile base "$_SCRATCH/cl-claims-base.json" --slurpfile h "$_SCRATCH/cl-claims.json" \
    --slurpfile s "$scope" --slurpfile f "$frecon" --slurpfile recs "$recs" --slurpfile fu "$frecon.unrecorded" \
    "$_JQ_CLAIMS_RECONCILE $_JQ_CLAIMS_ATTEST_CROSS" > "$cross"
  _claims_jq attest-unrecorded -c --arg fin "$fin" '.unrecorded[] | {check: "attest", claim, doc: null,
      message: "silent reconciliation: this \(.kind) on \(.claim) since the merge-base is in no chunk record and not in \($fin) (a ruling made at the final gate must name \($fin) as its record; a ruling citing anything else is never absorbed into it; a status change needs a recorded ruling or promotion)"}' \
    "$cross" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_jq attest-reverted -c '.reverted[] | {check: "attest", claim, doc: null,
      message: "reconciliation reverted at HEAD: \(.record) reconciled a \((.ruling | objects | .direction) // "?") ruling on \(.claim) that the claim no longer holds"}' \
    "$cross" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_promotions_unverifiable attest "$frecon"

  # 2, continued (it reads step 3's reconciliations): the named claims, and
  # re-promotions owed.
  _claims_jq attest-included -nc --slurpfile recs "$recs" --slurpfile f "$frecon" \
    '[$recs[] | .data.reconciliations[]] + $f[0]' > "$included"
  _claims_jq attest-named-findings -c --slurpfile c "$_SCRATCH/cl-claims.json" --slurpfile r "$included" \
    "$_JQ_CLAIMS_NAMED"' cl_named_findings($c[0]; $r[0]; "attest";
       "named on a **Claims:** line of the plan, but no claim has this id";
       "named claim still unbuilt at the final gate: promote it, rule DOC-STALE (recorded in a gate record), or defer it as diverged")' \
    "$named" >> "$_SCRATCH/cl-findings.jsonl"
  _claims_owed_findings attest "$_CL_MB"

  # 4. The amendment batch.
  _claims_rulings_rows "$_CL_MB" "$head" "$amend"

  # 5. render --check; its {doc, changed} rows stay out of the results.
  cat "$_SCRATCH/cl-results.jsonl" > "$saved" || _claims_die "cannot write $saved"
  k=$(wc -l < "$_SCRATCH/cl-findings.jsonl") || _claims_die "cannot read the findings"
  _claims_blocks check
  cat "$saved" > "$_SCRATCH/cl-results.jsonl" || _claims_die "cannot write the results"
  i=$(wc -l < "$_SCRATCH/cl-findings.jsonl") || _claims_die "cannot read the findings"
  if [ "$((i))" -ne "$((k))" ]; then render=failed; fi

  # --deep: each usable record's claims at its head.
  if [ "$_OPT_deep" = 1 ]; then
    k=$(_claims_jq attest-records-count -s 'length' "$recs") || _claims_propagate $?
    i=0
    while [ "$i" -lt "$k" ]; do
      _claims_jq attest-deep-record -s --argjson i "$i" '.[$i].data' "$recs" > "$one"
      n=$(_claims_jq attest-deep-chunk -s --argjson i "$i" '.[$i].chunk' "$recs") || _claims_propagate $?
      _claims_attest_deep "$n" "$one"
      i=$((i + 1))
    done
  fi

  # The record, even when it does not pass.
  result=pass
  if [ -s "$_SCRATCH/cl-findings.jsonl" ]; then
    result=fail
  elif [ -s "$_SCRATCH/cl-indet.jsonl" ]; then
    result=indeterminate
  fi
  tree=$(git rev-parse -q --verify "$head^{tree}" 2>/dev/null) || _claims_die "cannot resolve HEAD's tree"
  _claims_jq attest-record -n --arg plan "$plan" --arg base "$_CL_MB" --arg head "$head" --arg tree "$tree" \
    --arg from "$from" --arg render "$render" --arg result "$result" --slurpfile chunks "$rows" \
    --slurpfile res "$_SCRATCH/cl-run-results.json" --slurpfile f "$frecon" --slurpfile cross "$cross" \
    --slurpfile amend "$amend" \
    '{schema: 1, plan: $plan, base: $base, head: $head, tree: $tree, from: $from,
      chunks: ($chunks | sort_by(.chunk)), claims: [$res[0][] | {claim, status, verdict}],
      reconciliations: $f[0], cross_check: $cross[0], amendments: $amend[0],
      render_check: $render, result: $result}' > "$out"
  if [ "$_OPT_final" = 1 ]; then
    _claims_gate_write "$fin" "$out"
    x=$(_claims_jq attest-extra -c --arg p "$fin" 'del(.base) + {record: $p}' "$out") || _claims_propagate $?
  else
    x=$(_claims_jq attest-extra -c 'del(.base)' "$out") || _claims_propagate $?
  fi
  _claims_emit attest "$x"
}

# rulings: the amendment batch of <a>..<b> (_claims_rulings_rows; the range
# resolved by _claims_range_parse, so <a>...<b> reads from their
# merge-base, and an <a> that is no ancestor of <b> exits 2), one result row
# per ruling. --format markdown prints it as Markdown instead
# (_JQ_CLAIMS_RULINGS_MD; the heading always, N = 0 included). The base is
# never read.
cmd_claims_rulings() {
  local format="${_OPT_format:-json}" range="$_OPT_range" rows text
  _CL_BASE_UNUSED=1
  _claims_init head
  case "$format" in
    json|markdown) ;;
    *) _usage_error "claims rulings" "--format must be json or markdown (got '$format')" ;;
  esac
  [ -n "$range" ] || _usage_error "claims rulings" "requires --range <a>..<b>"
  case "$range" in
    ..*|*..) _usage_error "claims rulings" "--range must be <a>..<b> (got '$range')" ;;
    *..*) ;;
    *) _usage_error "claims rulings" "--range must be <a>..<b> (got '$range')" ;;
  esac
  _claims_no_args "claims rulings" "$@"
  rows="$_SCRATCH/cl-rulings.json"
  _claims_range_parse "$range"
  _claims_rulings_rows "$_CL_RANGE_A" "$_CL_RANGE_B" "$rows"
  if [ "$format" = markdown ]; then
    text=$(_claims_jq rulings-markdown -r "$_JQ_CLAIMS_RULINGS_MD" "$rows") || _claims_propagate $?
    _claims_mark_emitted 0
    _claims_out "$text"
    _exit_ok
  fi
  _claims_jq rulings-results -c '.[]' "$rows" >> "$_SCRATCH/cl-results.jsonl"
  _claims_emit rulings
}

# --- Main ---

_main "$@"
# Reached only when the run finished: see _on_exit.
_EXIT_OK=1

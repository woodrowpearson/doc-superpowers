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
# ancestor of HEAD (only the verify commit was cherry-picked, a branch that
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
# verified. Before schema v3 it was stale when the newest commit touching the
# refs had a different id from the stored code_commit — and a commit id is a
# poor proxy for content: squash merges, rebase-merges, cherry-picks and
# reverts mint new ids for identical bytes; a shallow clone's graft poses as
# the last commit; a commit cannot contain its own id, so verifying a doc in
# the same commit as the code never matched; and every doc paid its own
# history walks (O(N·H): 117 s at N=4,000 docs, H=3,000 commits).
#
# Writers (build-index, add-entry, update-index) store per ref the git object
# id of its content — a blob for a file, a tree for a directory, the commit
# for a submodule, "missing" when there is none — in code_oids, captured from the WORKING TREE, which is
# what the verifier read, staged or not (through a private index: git's own is
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
#     writer re-verifies it. The first write bumps schema_version to 3.

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
# `add -A` stages untracked files too — new files under a ref are code the
# verifier read — so an untracked file (not ignored) under a ref is part of
# the verified content, and HEAD lacks it: the doc reads stale until it is
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
#   worktree  (update-index, the one verb that attests) the working tree the
#             verifier read (_worktree_tree); code_commit from HEAD
#   doc       (build-index, add-entry, set-code-refs: they verify nothing) the
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
# is null when the entry has none (never verified).
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
  if [ -n "$_SCRATCH" ]; then rm -rf "$_SCRATCH"; fi
  return 0
}

# EXIT: clean up, then end with the status that ended the run — except that
# a run which claims 0 without having finished is a crash, and exits 1. bash
# 3.2 (macOS's /bin/bash) runs the EXIT trap of a fatal shell error, such as a
# `set -u` unbound variable, with $? = 0, so such a crash used to exit 0: a
# silent success. A run finishes by returning from _main, or by _exit_ok
# (an intended exit 0, such as --help); both set _EXIT_OK first.
_EXIT_OK=0
_on_exit() {
  local rc=$?
  cleanup
  if [ "$rc" -eq 0 ] && [ "$_EXIT_OK" != 1 ]; then
    rc=1
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
    ''|*[!0-9]*) return 1 ;;
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
#   v  changed, but in last_verified alone (update-index re-attesting a doc
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
  lines"). Each entry is recorded as add-entry records one: unverified.
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
  from what was verified (code_oids). Without --tree, the working copy's
  index and docs are judged against the refs in HEAD. --tree <tree-ish>
  judges one snapshot: the index, the docs (present or missing, and
  doc_modified) and the refs all as that tree holds them. A pre-commit check
  wants the staged tree, --tree "$(git write-tree)", so an update-index
  whose index is not staged does not count. A tree without the index falls
  back to the working copy's index and docs, with a note on stderr. An
  entry without code_oids (pre-v3) keeps the old commit comparison, at
  HEAD, until update-index re-verifies it.
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
  Verify indexed docs — the one subcommand that attests a doc matches its
  code: re-hash, record code_oids (each code ref's content in the working
  tree) and code_commit, stamp last_verified. A deprecated entry stays
  deprecated. Reports Refreshed (something recorded changed), Re-verified
  (only last_verified did) or Unchanged (verified this second already). A
  doc whose file is gone is skipped with advice. A path that is not
  indexed is reported and skipped; the others are still applied, and the
  run exits 1.
add-entry|cmd_add_entry|repo|
  < mapping-lines
  Add new entries from mapping lines on stdin (same format as
  build-index). Indexing is not verifying: last_verified is null, and
  each ref's content is recorded as of the doc's own last commit (the
  working tree for a doc git has never committed), so code that changed
  since the doc was written reads stale until update-index verifies it. A
  key already indexed is skipped (update-index re-verifies it,
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
  place, no duplicate made) with the matching code_oids key, whose recorded
  object id is kept (a rename keeps the content, so a doc citing the moved
  one stays as fresh as it was; an entry without code_oids, written before
  schema 3, keeps the commit comparison until update-index). Use this, not
  remove-entry + add-entry, for a rename, which would drop the freshness
  metadata. --stdin moves a batch in one index write: one "<old><TAB><new>"
  pair per line (blank lines skipped, a trailing CR removed), taken as one
  simultaneous rename, so a path one pair vacates may be another's target.
  Every pair is checked first; one bad pair writes nothing (exit 1).
set-code-refs|cmd_set_code_refs|repo|refs=
  <doc_path> --refs <ref>[,<ref>...]
  Replace an indexed doc's code_refs in place (--refs '' leaves none); the
  same refs (compared as paths) write nothing. Not a verification: the
  entry keeps its position and every other field (last_verified,
  content_hash, status, …). code_oids is re-derived: a ref the entry
  already had keeps its recorded content (for a pre-v3 entry, the content
  in its code_commit); a new one is recorded as add-entry records it (as
  of the doc's last commit), so the doc reads stale if that code changed
  since, until update-index verifies it. code_commit (the commits_behind
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
  the same type writes nothing. Not a verification. doc_type decides
  whether a doc is a record (plan, issue, audit, design-spec: never
  reported stale) or a living doc compared with its code, so <doc_type>
  must be a known type — architecture, api-contracts, data-layer, infra,
  ci-cd, workflows, agentic, guide, codebase-guide, conventions, spec,
  adr, plan, issue, audit or design-spec — or one this index already
  uses (a project's own vocabulary); anything else (a typo) exits 1,
  writing nothing. Use it, not remove-entry + add-entry, which would drop
  the entry's verification, deprecation and links.
deprecate-entry|cmd_deprecate_entry|repo|superseded-by=
  [--superseded-by <doc_path>] <doc_path>...
  Mark entries deprecated, optionally naming the doc that supersedes them;
  that successor's replaces is set to the (first) deprecated doc unless it
  already names one. last_verified is not touched: deprecating is not
  verifying. A path that is not indexed is reported and skipped; the
  others are still applied, and the run exits 1 (so an archive step that
  names the old path after move-entry, deprecating nothing, fails).
status|cmd_status|repo|tree=
  [--tree <tree-ish>] <doc_path>
  Freshness of one doc (read-only, JSON): the same verdict check-freshness
  reports for it (with the same --tree, read from that one snapshot), plus
  its path.
audit-merges|cmd_audit_merges|repo|
  <since> [<until>]
  Find merges that silently lost an index change (read-only, JSON). Every
  merge commit in <since>..<until> (until: HEAD) whose parents' indexes
  differ is replayed through this plugin's merge driver, as an oracle, and
  its result compared with the index the merge recorded, entry by entry.
  A finding is an entry whose recorded value differs: "kept": "parent 1"
  or "parent 2" means the merge kept that parent's whole entry where the
  three-way merge keeps the other parent's change (a silent revert, e.g.
  by a driver that is not base-aware on a last_verified tie); "neither"
  means the merge commit itself rewrote it (a hand resolution or a
  re-verification: review it). "refused": the driver would leave the merge
  in conflict; "unreadable": the recorded index is not valid. A stored
  status "current"/"stale" is not compared (freshness is derived), nor are
  top-level fields. Exits 1 on any finding. Repair a revert with the verb
  that made the lost change.
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
  exits 0. An option a subcommand does not take is an error (exit 2), never
  silently ignored.

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
  ignored) files under a ref are part of what is verified: writers name
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
  update-index as the working tree holds it (what the verifier read);
  build-index, add-entry and set-code-refs as of the doc's own last commit
  (the code it was written against; the working tree for a doc git has
  never committed). A doc is stale when one differs in the compared tree
  (HEAD, or --tree, which also supplies the index and the docs). So squash
  merges, rebase-merges, cherry-picks and reverts to
  the verified bytes stay current, as does a doc verified in the same
  commit as its code; a submodule bump reads stale. code_refs_changed lists
  exactly the refs that differ. commits_behind counts the commits touching
  the refs since code_commit, and is null when that commit is not an
  ancestor of HEAD here (a deleted squash-merged branch, a shallow clone, a
  cherry-picked verification). In a shallow clone writers record no
  code_commit (null, with a warning). The doc-index itself is never part of
  a ref's content.

Stored state (who may attest):
  Only update-index writes last_verified: it is the one subcommand that
  claims a doc was checked against its code. The other writers leave it as
  it is, and a new entry has null. status is stored only as "deprecated";
  current and stale are always computed (a stored "current" or "stale" from
  an older index reads as absent, and the next write drops it). A record
  doc — doc_type plan, issue, audit or design-spec, or any path under
  docs/archive/ — describes a point in time, so it is never reported
  stale: check-freshness reports it current with "record": true (and
  commits_behind null: not evaluated). set-doc-type retypes an entry in
  place (an index written before v3 typed design specs "spec": retype them
  design-spec). Archiving a doc is git mv into docs/archive/<type>/, then
  move-entry, then deprecate-entry.

Exit status:
  0  success
  1  the operation failed or was refused (an invalid mapping line, a path
     outside the repo, a key not in the index, an unknown doc_type,
     build-index over a non-empty index without --force, …).
     update-index and deprecate-entry report and skip a path not in the
     index, apply the rest, then exit 1. The one exception: remove-entry
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
    ''|*[!a-z-]*) return 1 ;;
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

# A command-line error: say what is wrong and where the usage is; exit 2.
_usage_error() {
  echo "ERROR: $1: $2" >&2
  echo "       See: doc-tools.sh $1 --help" >&2
  exit 2
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
    echo "ERROR: $1 must run inside a git repository (run doc-tools.sh from the repo root)." >&2
    exit 2
  fi
  prefix=$(git rev-parse --show-prefix 2>/dev/null) || prefix=""
  if [ -n "$prefix" ]; then
    echo "ERROR: $1 must run from the repository's top level, not from ${prefix%/}/ (doc paths are keyed from the root). Run: cd \"\$(git rev-parse --show-toplevel)\"" >&2
    exit 2
  fi
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
    repo) check_deps || exit 1; _require_repo "$verb" ;;
    deps) check_deps || exit 1 ;;
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
# writing an entry is not verifying its doc — only update-index attests.
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
  # batch, so one typo in a list of 20 re-verified nothing.) Refs are kept in
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

  # Verify: re-hash, re-read code_commit and code_oids, stamp last_verified
  # (update-index is the ONE verb that attests), capture implementation
  # (each entry's text: no indent, no "- ", wrapped lines joined).
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
  # Every one is a verification, and stamps last_verified:
  #   Refreshed    something it records changed too — the doc's hash, its
  #                code's content (code_oids, code_commit) or its
  #                Implementation: bullets
  #   Re-verified  nothing but last_verified changed: a real write, so never
  #                reported as unchanged
  #   Unchanged    verified in this same second already: nothing was written
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
  while IFS= read -r -d '' k; do
    refs_repointed+=("$k")
  done < <(jq -j --slurpfile mv "$map" '$mv[0] as $m | .docs | to_entries[]
      | select((.value | type) == "object" and (.value.code_refs | type) == "array")
      | select(any(.value.code_refs[]; type == "string" and $m[.] != null))
      | (if $m[.key] != null then $m[.key].new else .key end) + "\u0000"' < "$snap")

  # Each entry object is carried over WHOLESALE (`.value + {content_hash: …}`)
  # rather than field-by-field, so a field this code has never heard of still
  # survives a move. Only content_hash is adjusted: code_commit, code_oids and
  # last_verified are deliberately PRESERVED, because a move is not a
  # verification — re-deriving either would make the entry assert a freshness
  # nobody confirmed. Run update-index afterwards for a genuine re-verify.
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
  # (GH #22). A code_refs list is rewritten in place, first occurrence kept, so
  # a list that already named the new path gains no duplicate. Its code_oids
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
             then .code_refs |= reduce .[] as $r ([];
                    ($r | if type == "string" and $m[.] != null then $m[.].new else . end) as $n
                    | if any(.[]; . == $n) then . else . + [$n] end)
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
  # not re-verified, so nothing else about it changes.
  _FACT_KEYS=("$doc_path")
  _FACT_REFSETS=("$joined")
  _entry_facts 1 doc

  # A ref the entry already had keeps its recorded content (it may have been
  # verified): its code_oids id, or — for a pre-v3 entry, which records
  # content only as code_commit (the newest commit touching the refs when it
  # was verified) — its object id in that commit's tree, looked up the way
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
  #          line (only the verify commit was cherry-picked) already reads
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
# verification, deprecation and links.
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
  # same key contract as the entries themselves.
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

  # Deprecating is not verifying: last_verified is left as it is.
  _scratch_init
  local patch="$_SCRATCH/deprecate-patch.jsonl"
  # shellcheck disable=SC2016  # jq program, not shell expansion
  jq -nc --argjson superseded_by "$superseded_by" \
    '$ARGS.positional[] | {key: ., merge: {status: "deprecated", superseded_by: $superseded_by}}' \
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
# every file it writes is under $_SCRATCH.
_am_index_at() { git show "$1:$INDEX_FILE" > "$2" 2>/dev/null || : > "$2"; }

cmd_audit_merges() {
  [ $# -ge 1 ] && [ $# -le 2 ] || _usage_error audit-merges "requires <since> [<until>] (got $# arguments)"
  local since="$1" until="${2:-HEAD}" r
  for r in "$since" "$until"; do
    git rev-parse --verify --quiet "$r^{commit}" >/dev/null \
      || { echo "ERROR: '$r' is not a commit." >&2; exit 1; }
  done
  local driver="$SCRIPT_DIR/merge-doc-index.sh"
  [ -f "$driver" ] || _die "the merge driver is not beside doc-tools.sh ($driver)"

  _scratch_init
  local dir="$_SCRATCH/audit-merges" found="$_SCRATCH/audit-merges.jsonl"
  mkdir -p "$dir" || _die "cannot create a scratch directory"
  : > "$found"
  local m p1 p2 base checked=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    p1=$(git rev-parse "$m^1") || continue
    p2=$(git rev-parse --verify --quiet "$m^2") || continue
    # Only a merge whose parents' indexes differ ran the driver. (Not
    # `git log -- $INDEX_FILE`: history simplification hides exactly the merge
    # that kept one parent's index whole.)
    git diff --quiet "$p1" "$p2" -- "$INDEX_FILE" 2>/dev/null && continue
    checked=$((checked + 1))
    base=$(git merge-base "$p1" "$p2" 2>/dev/null) || base=""
    if [ -n "$base" ]; then _am_index_at "$base" "$dir/base"; else : > "$dir/base"; fi
    _am_index_at "$p1" "$dir/p1"
    _am_index_at "$p2" "$dir/p2"
    _am_index_at "$m" "$dir/rec"
    cp "$dir/p1" "$dir/out"
    if ! "$BASH" "$driver" "$dir/base" "$dir/out" "$dir/p2" >/dev/null 2>&1; then
      jq -cn --arg m "$m" '{merge: $m, refused: true}' >> "$found"
      continue
    fi
    if ! jq -e '.docs | type == "object"' "$dir/rec" >/dev/null 2>&1; then
      jq -cn --arg m "$m" '{merge: $m, unreadable: true}' >> "$found"
      continue
    fi
    # shellcheck disable=SC2016  # jq program, not shell expansion
    jq -cn --arg m "$m" --slurpfile a "$dir/out" --slurpfile b "$dir/rec" \
        --slurpfile x "$dir/p1" --slurpfile y "$dir/p2" '
      def norm: if type == "object" and (.status == "current" or .status == "stale")
                 then del(.status) else . end;
      def docs($f): if ($f | length) > 0 and ($f[0] | type) == "object" then ($f[0].docs // {}) else {} end;
      docs($a) as $A | docs($b) as $B | docs($x) as $X | docs($y) as $Y
      | ([$A, $B] | map(keys) | add | unique)[] as $k
      | ($A[$k] | norm) as $va | ($B[$k] | norm) as $vb
      | select($va != $vb)
      | {merge: $m, key: $k,
         kept: (if $vb == ($X[$k] | norm) then "parent 1"
                elif $vb == ($Y[$k] | norm) then "parent 2" else "neither" end)}' \
      >> "$found" || _die "cannot compare merge $m with the driver's result"
  done < <(git log --merges --format=%H "$since..$until")

  local count
  count=$(grep -c . "$found" || true)
  jq -s --arg r "$since..$until" --argjson n "$checked" \
    '{range: $r, merges_checked: $n, findings: .}' "$found" || _die "cannot render the findings"
  echo "audit-merges: $checked merge(s) replayed, $count finding(s)" >&2
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
    '' | *[!0-9]*) return 1 ;;
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

# --- Main ---

_main "$@"
# Reached only when the run finished: see _on_exit.
_EXIT_OK=1

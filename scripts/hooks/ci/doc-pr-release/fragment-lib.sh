#!/usr/bin/env bash
# The release-notes fragment line rules the CI helpers share — sourced, never
# run, by commit-and-push.sh and extract-context.sh (beside this file) and by
# ../doc-superpowers-steps/verify-fragment.sh. `tools install` ships it with
# the doc-pr-release helpers.
#
# A fragment (RELEASE-NOTES.next/README.md):
#   line 1  <!-- doc-superpowers:fragment PR-<N> -->
#   line 2  a hash line — <!-- doc-superpowers:hash --> or
#           <!-- doc-superpowers:hash <token> --> (FRAG_HASH_LINE_RE). It is
#           sealed when <token> is the lowercase hex sha256 of the file's
#           bytes from line 3 on (FRAG_HASH_RE captures it).
#   notes   from line 3 when line 2 is a hash line, else from line 2 (the
#           hash line was deleted by hand).
# Marker lines are compared less one trailing CR and trailing blanks.
#
# doc-tools.sh's consumer (`fragments list|merge`) applies the same rules, but
# it is vendored as one self-contained file, so it keeps its own copies:
# _FRAG_HASH_LINE_RE and _FRAG_HASH_RE there are byte-identical to the two
# constants below (scripts/test-doc-pr-release.sh pins that, and feeds the
# same line-2 fixtures to both).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "fragment-lib.sh is a library: source it, do not run it" >&2
  exit 2
fi

# shellcheck disable=SC2034  # read by the scripts that source this file
FRAG_HASH_LINE_RE='^<!-- doc-superpowers:hash( [^ ]*)? -->$'
# shellcheck disable=SC2034
FRAG_HASH_RE='^<!-- doc-superpowers:hash ([0-9a-f]+) -->$'

# frag_marker <N>: line 1 of PR-<N>'s fragment.
frag_marker() {
  printf '<!-- doc-superpowers:fragment PR-%s -->' "$1"
}

# frag_trimmed <line>: the line less one trailing CR and trailing blanks.
frag_trimmed() {
  local l="${1%$'\r'}"
  while :; do
    case "$l" in
      *[' '$'\t']) l="${l%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$l"
}

# frag_sha256: the lowercase hex sha256 of stdin (the digest only).
frag_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256) || return 1
  else
    echo "neither sha256sum nor shasum is installed" >&2
    return 1
  fi
  printf '%s' "${out%% *}"
}

# frag_lines <file>: set FRAG_L1 and FRAG_L2 to its lines 1 and 2, trimmed.
frag_lines() {
  local l1="" l2=""
  { IFS= read -r l1 || true; IFS= read -r l2 || true; } < "$1"
  FRAG_L1=$(frag_trimmed "$l1")
  FRAG_L2=$(frag_trimmed "$l2")
}

# frag_is_hash_line <trimmed line>: 0 when it is a hash line.
frag_is_hash_line() {
  [[ $1 =~ $FRAG_HASH_LINE_RE ]]
}

# frag_stored <trimmed line>: the hash it records ("" unless it is
# <!-- doc-superpowers:hash <hex> -->).
frag_stored() {
  if [[ $1 =~ $FRAG_HASH_RE ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# frag_notes <file> <out>: write the notes' bytes to <out>. Sets FRAG_L1/L2.
frag_notes() {
  frag_lines "$1"
  if frag_is_hash_line "$FRAG_L2"; then
    tail -n +3 "$1" > "$2"
  else
    tail -n +2 "$1" > "$2"
  fi
}

# frag_sealed <file>: 0 when line 2 records the sha256 of the bytes from
# line 3 on. Sets FRAG_L1/L2.
frag_sealed() {
  local stored actual
  frag_lines "$1"
  stored=$(frag_stored "$FRAG_L2")
  [ -n "$stored" ] || return 1
  actual=$(tail -n +3 "$1" | frag_sha256) || return 1
  [ "$stored" = "$actual" ]
}

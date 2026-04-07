#!/usr/bin/env bash
# doc-superpowers: custom git merge driver for docs/.doc-index.json
# Automatically resolves timestamp/commit/entry conflicts during merge/rebase.
#
# Git calls: merge-doc-index.sh %O %A %B
#   %O = ancestor (base)
#   %A = current branch (ours) — also the OUTPUT file
#   %B = other branch (theirs)
#
# Exit 0 = merge succeeded (result written to %A)
# Exit non-zero = merge failed, git falls back to normal conflict markers
#
# Resolution rules:
#   - generated_at/build_commit: regenerate to current time/HEAD
#   - Entry in both sides: take the one with newer last_verified
#   - Entry in only one side (added): include it (union merge)
#   - Entry deleted from one side (was in base): deletion wins
#   - Keys sorted alphabetically for deterministic output

set -euo pipefail

BASE="$1"    # %O — ancestor
OURS="$2"    # %A — current branch (output goes here)
THEIRS="$3"  # %B — other branch

# Validate inputs exist and are valid JSON
for f in "$BASE" "$OURS" "$THEIRS"; do
  if [ ! -f "$f" ]; then
    echo "merge-doc-index: missing input file: $f" >&2
    exit 1
  fi
  if ! jq empty "$f" 2>/dev/null; then
    echo "merge-doc-index: invalid JSON in: $f" >&2
    exit 1
  fi
done

# Generate fresh metadata
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Three-way merge in a single jq invocation
MERGED=$(jq --slurpfile base "$BASE" \
            --slurpfile theirs "$THEIRS" \
            --arg now "$NOW" \
            --arg build_commit "$BUILD_COMMIT" '
def newer_entry:
  if .[0].last_verified == null and .[1].last_verified == null then .[0]
  elif .[0].last_verified == null then .[1]
  elif .[1].last_verified == null then .[0]
  elif .[0].last_verified >= .[1].last_verified then .[0]
  else .[1]
  end;

($base[0].docs // {}) as $base_docs |
(.docs // {}) as $ours_docs |
($theirs[0].docs // {}) as $theirs_docs |
([$base_docs, $ours_docs, $theirs_docs] | map(keys) | add | unique) as $all_keys |
(reduce ($all_keys[]) as $key (
  {};
  ($base_docs | has($key)) as $in_base |
  ($ours_docs | has($key)) as $in_ours |
  ($theirs_docs | has($key)) as $in_theirs |
  if ($in_ours and $in_theirs) then
    . + {($key): ([$ours_docs[$key], $theirs_docs[$key]] | newer_entry)}
  elif ($in_ours and ($in_base | not)) then
    . + {($key): $ours_docs[$key]}
  elif ($in_theirs and ($in_base | not)) then
    . + {($key): $theirs_docs[$key]}
  elif ($in_ours and $in_base and ($in_theirs | not)) then .
  elif ($in_theirs and $in_base and ($in_ours | not)) then .
  elif $in_ours then . + {($key): $ours_docs[$key]}
  elif $in_theirs then . + {($key): $theirs_docs[$key]}
  else . end
)) as $merged_docs |
($merged_docs | to_entries | sort_by(.key) | from_entries) as $sorted_docs |
{
  version: ([.version, $base[0].version, $theirs[0].version] | map(. // 0) | max),
  generated_by: "doc-superpowers",
  generated_at: $now,
  build_commit: $build_commit,
  docs: $sorted_docs
}
' "$OURS")

# Write result to the "ours" file (git expects merged output here)
echo "$MERGED" > "$OURS"

exit 0

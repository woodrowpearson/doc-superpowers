#!/usr/bin/env bash
# Tests for merge-doc-index.sh — custom git merge driver
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_DRIVER="$SCRIPT_DIR/merge-doc-index.sh"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=== merge-doc-index.sh tests ==="

# --- Helpers: write JSON directly to files ---

# Write a doc entry JSON to stdout (compact, single-line)
entry_json() {
  local lv="${1:-2026-04-01T00:00:00Z}" ch="${2:-sha256:aaa}" cc="${3:-commit1}"
  printf '{"content_hash":"%s","code_refs":["Sources/"],"code_commit":"%s","doc_type":"spec","status":"current","replaces":null,"superseded_by":null,"last_verified":"%s"}' "$ch" "$cc" "$lv"
}

# Write a complete doc-index JSON to a file
write_index() {
  local file="$1" ga="${2:-2026-04-01T00:00:00Z}" bc="${3:-abc123}"
  shift 3
  # Remaining args are pairs: doc_path entry_json
  local docs="{"
  local first=true
  while [ $# -ge 2 ]; do
    local path="$1" entry="$2"
    shift 2
    if [ "$first" = true ]; then
      first=false
    else
      docs="$docs,"
    fi
    docs="$docs\"$path\":$entry"
  done
  docs="$docs}"
  printf '{"version":1,"generated_by":"doc-superpowers","generated_at":"%s","build_commit":"%s","docs":%s}' "$ga" "$bc" "$docs" > "$file"
}

# Temp files for each test
B="/tmp/mdm-base.json"
O="/tmp/mdm-ours.json"
T="/tmp/mdm-theirs.json"

# ===================================================================
# Test 1: Timestamp conflict — takes newer entry, regenerates metadata
# ===================================================================
echo ""
echo "--- Test: timestamp conflict resolution ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base111" \
  "docs/spec.md" "$(entry_json '2026-04-01T00:00:00Z')"
write_index "$O" "2026-04-05T12:00:00Z" "ours222" \
  "docs/spec.md" "$(entry_json '2026-04-05T12:00:00Z')"
write_index "$T" "2026-04-03T08:00:00Z" "theirs333" \
  "docs/spec.md" "$(entry_json '2026-04-03T08:00:00Z')"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "doc-superpowers" "$(echo "$RESULT" | jq -r '.generated_by')" "generated_by preserved"
assert_eq "2026-04-05T12:00:00Z" "$(echo "$RESULT" | jq -r '.docs["docs/spec.md"].last_verified')" "takes entry with newer last_verified (ours)"
# generated_at should be regenerated to NOW, not either branch
RESULT_GA=$(echo "$RESULT" | jq -r '.generated_at')
assert_not_contains "$RESULT_GA" "2026-04-05T12" "generated_at regenerated (not ours)"
assert_not_contains "$RESULT_GA" "2026-04-03T08" "generated_at regenerated (not theirs)"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 2: Union merge — both sides add different entries
# ===================================================================
echo ""
echo "--- Test: union merge of new entries ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base" \
  "docs/shared.md" "$(entry_json '2026-04-01T00:00:00Z')"
write_index "$O" "2026-04-02T00:00:00Z" "ours" \
  "docs/shared.md" "$(entry_json '2026-04-01T00:00:00Z')" \
  "docs/ours-only.md" "$(entry_json '2026-04-02T00:00:00Z' 'sha256:bbb')"
write_index "$T" "2026-04-03T00:00:00Z" "theirs" \
  "docs/shared.md" "$(entry_json '2026-04-01T00:00:00Z')" \
  "docs/theirs-only.md" "$(entry_json '2026-04-03T00:00:00Z' 'sha256:ccc')"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "3" "$(echo "$RESULT" | jq '.docs | length')" "merged index has 3 entries"
assert_eq "sha256:bbb" "$(echo "$RESULT" | jq -r '.docs["docs/ours-only.md"].content_hash')" "ours-only entry preserved"
assert_eq "sha256:ccc" "$(echo "$RESULT" | jq -r '.docs["docs/theirs-only.md"].content_hash')" "theirs-only entry preserved"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 3: Deletion wins — entry removed from one side
# ===================================================================
echo ""
echo "--- Test: deletion wins over preservation ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base" \
  "docs/keep.md" "$(entry_json '2026-04-01T00:00:00Z' 'sha256:aaa')" \
  "docs/delete-me.md" "$(entry_json '2026-04-01T00:00:00Z' 'sha256:bbb')"
write_index "$O" "2026-04-02T00:00:00Z" "ours" \
  "docs/keep.md" "$(entry_json '2026-04-01T00:00:00Z' 'sha256:aaa')" \
  "docs/delete-me.md" "$(entry_json '2026-04-01T00:00:00Z' 'sha256:bbb')"
write_index "$T" "2026-04-02T00:00:00Z" "theirs" \
  "docs/keep.md" "$(entry_json '2026-04-01T00:00:00Z' 'sha256:aaa')"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "1" "$(echo "$RESULT" | jq '.docs | length')" "only 1 entry remains"
assert_eq "null" "$(echo "$RESULT" | jq -r '.docs["docs/delete-me.md"] // "null"')" "deleted entry is gone"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 4: Both sides add same path — newer last_verified wins
# ===================================================================
echo ""
echo "--- Test: both sides add same path — newer wins ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base"
write_index "$O" "2026-04-02T10:00:00Z" "ours" \
  "docs/new.md" "$(entry_json '2026-04-02T10:00:00Z' 'sha256:ours-hash')"
write_index "$T" "2026-04-03T15:00:00Z" "theirs" \
  "docs/new.md" "$(entry_json '2026-04-03T15:00:00Z' 'sha256:theirs-hash')"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "sha256:theirs-hash" "$(echo "$RESULT" | jq -r '.docs["docs/new.md"].content_hash')" "theirs wins (newer last_verified)"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 5: Keys sorted alphabetically
# ===================================================================
echo ""
echo "--- Test: output keys sorted alphabetically ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base"
write_index "$O" "2026-04-02T00:00:00Z" "ours" \
  "docs/zebra.md" "$(entry_json)" \
  "docs/alpha.md" "$(entry_json)"
write_index "$T" "2026-04-02T00:00:00Z" "theirs" \
  "docs/middle.md" "$(entry_json)"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "docs/alpha.md" "$(echo "$RESULT" | jq -r '.docs | keys[0]')" "first key alphabetically first"
assert_eq "docs/zebra.md" "$(echo "$RESULT" | jq -r '.docs | keys[-1]')" "last key alphabetically last"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 6: Invalid JSON exits non-zero (fallback to conflict markers)
# ===================================================================
echo ""
echo "--- Test: invalid JSON exits non-zero ---"

echo "not json" > "$B"
echo '{}' > "$O"
echo '{}' > "$T"

set +e
"$MERGE_DRIVER" "$B" "$O" "$T" 2>/dev/null
EXIT_CODE=$?
set -e

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$EXIT_CODE" -ne 0 ]; then
  PASS=$((PASS + 1))
  printf "${GREEN}  PASS${NC}: invalid JSON exits non-zero (code=$EXIT_CODE)\n"
else
  FAIL=$((FAIL + 1))
  printf "${RED}  FAIL${NC}: invalid JSON should exit non-zero\n"
fi

# ===================================================================
# Test 7: Empty base — union of both sides
# ===================================================================
echo ""
echo "--- Test: empty base produces union ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

write_index "$B" "2026-04-01T00:00:00Z" "base"
write_index "$O" "2026-04-02T00:00:00Z" "ours" \
  "docs/a.md" "$(entry_json)"
write_index "$T" "2026-04-02T00:00:00Z" "theirs" \
  "docs/b.md" "$(entry_json)"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "2" "$(echo "$RESULT" | jq '.docs | length')" "empty base: both entries kept"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 8: Version takes max
# ===================================================================
echo ""
echo "--- Test: version takes maximum ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"
echo x > f && git add -A && git commit -m "init" --quiet

printf '{"version":1,"generated_by":"x","generated_at":"2026-01-01T00:00:00Z","build_commit":"x","docs":{}}' > "$B"
printf '{"version":2,"generated_by":"x","generated_at":"2026-01-01T00:00:00Z","build_commit":"x","docs":{}}' > "$O"
printf '{"version":1,"generated_by":"x","generated_at":"2026-01-01T00:00:00Z","build_commit":"x","docs":{}}' > "$T"

"$MERGE_DRIVER" "$B" "$O" "$T"
RESULT=$(cat "$O")

assert_eq "2" "$(echo "$RESULT" | jq '.version')" "version takes max (2)"

cd / && rm -rf "$TEST_DIR"

# ===================================================================
# Test 9: Real git merge uses driver automatically
# ===================================================================
echo ""
echo "--- Test: real git merge uses driver automatically ---"

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet && git config user.email "t@t" && git config user.name "T"

# Register merge driver
git config merge.doc-index.name "test merger"
git config merge.doc-index.driver "$MERGE_DRIVER %O %A %B"
echo "docs/.doc-index.json merge=doc-index" > .gitattributes

# Create base
mkdir -p docs
write_index "docs/.doc-index.json" "2026-04-01T00:00:00Z" "base" \
  "docs/shared.md" "$(entry_json '2026-04-01T00:00:00Z')"
git add -A && git commit -m "base" --quiet

# Branch A: add entry + update timestamp
git checkout -b branch-a --quiet
write_index "docs/.doc-index.json" "2026-04-02T00:00:00Z" "branch-a" \
  "docs/shared.md" "$(entry_json '2026-04-02T00:00:00Z')" \
  "docs/from-a.md" "$(entry_json '2026-04-02T00:00:00Z' 'sha256:aaa')"
git add -A && git commit -m "branch-a adds entry" --quiet

# Branch B (from main): add different entry + different timestamp
git checkout main --quiet 2>/dev/null || git checkout master --quiet 2>/dev/null
git checkout -b branch-b --quiet
write_index "docs/.doc-index.json" "2026-04-03T00:00:00Z" "branch-b" \
  "docs/shared.md" "$(entry_json '2026-04-03T00:00:00Z')" \
  "docs/from-b.md" "$(entry_json '2026-04-03T00:00:00Z' 'sha256:bbb')"
git add -A && git commit -m "branch-b adds entry" --quiet

# Merge — should auto-resolve via custom driver
set +e
git merge branch-a -m "merge test" 2>/dev/null
MERGE_EXIT=$?
set -e

RESULT=$(cat docs/.doc-index.json)

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$MERGE_EXIT" -eq 0 ]; then
  PASS=$((PASS + 1))
  printf "${GREEN}  PASS${NC}: git merge succeeded without conflicts\n"
else
  FAIL=$((FAIL + 1))
  printf "${RED}  FAIL${NC}: git merge should have succeeded (exit=$MERGE_EXIT)\n"
fi

assert_eq "3" "$(echo "$RESULT" | jq '.docs | length')" "merged index has all 3 entries"
assert_eq "sha256:aaa" "$(echo "$RESULT" | jq -r '.docs["docs/from-a.md"].content_hash')" "branch-a entry present"
assert_eq "sha256:bbb" "$(echo "$RESULT" | jq -r '.docs["docs/from-b.md"].content_hash')" "branch-b entry present"

cd / && rm -rf "$TEST_DIR"

# Cleanup
rm -f "$B" "$O" "$T"

print_summary

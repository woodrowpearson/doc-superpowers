#!/usr/bin/env bash
# Tests for doc-pr-release helpers.
#
# Each helper is tested in isolation. The harness builds /tmp fixture state
# and mocks `gh` via a PATH shim when needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPERS_DIR="$REPO_ROOT/scripts/hooks/ci/doc-pr-release"

[ -x "$HELPERS_DIR/update-pr-body.sh" ] || {
  echo "FAIL: $HELPERS_DIR/update-pr-body.sh not found or not executable" >&2
  exit 1
}

PASS=0; FAIL=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "  --- expected ---"
    printf '%s\n' "$expected"
    echo "  --- actual ---"
    printf '%s\n' "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================================
# update-pr-body.sh tests
# ============================================================================
echo "=== update-pr-body.sh ==="

UPDATE_SCRIPT="$HELPERS_DIR/update-pr-body.sh"

test_insert_new_section() {
  echo "Test: insert markers into a body that has none"
  local existing="## Summary
User wrote this."
  local new_section="### Added
- new thing"
  local expected="## Summary
User wrote this.

<!-- doc-superpowers:start -->
### Added
- new thing
<!-- doc-superpowers:end -->"
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  assert_eq "insert_new_section" "$expected" "$actual"
}

test_replace_existing_section() {
  echo "Test: replace existing managed section, preserve user content"
  local existing="## Summary
User prose.

<!-- doc-superpowers:start -->
### Added
- old thing
<!-- doc-superpowers:end -->

More user prose below."
  local new_section="### Added
- new thing
### Fixed
- bug"
  local expected="## Summary
User prose.

<!-- doc-superpowers:start -->
### Added
- new thing
### Fixed
- bug
<!-- doc-superpowers:end -->

More user prose below."
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  assert_eq "replace_existing_section" "$expected" "$actual"
}

test_empty_body() {
  echo "Test: empty existing body"
  local new_section="### Added
- one"
  local expected="<!-- doc-superpowers:start -->
### Added
- one
<!-- doc-superpowers:end -->"
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  assert_eq "empty_body" "$expected" "$actual"
}

test_noop_when_unchanged() {
  echo "Test: no-op exit code when content unchanged"
  local existing="<!-- doc-superpowers:start -->
### Added
- same
<!-- doc-superpowers:end -->"
  local new_section="### Added
- same"
  local rc=0
  DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section" >/dev/null || rc=$?
  assert_eq "noop_exit_code" "0" "$rc"
}

test_malformed_markers_fails() {
  echo "Test: malformed body (start without end) — fail closed"
  local existing="## Summary
<!-- doc-superpowers:start -->
### Added
- dangling"
  local rc=0
  DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"### Added" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  PASS: malformed_markers_fails (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: malformed_markers_fails — expected non-zero rc"
    FAIL=$((FAIL + 1))
  fi
}

test_trailing_newline_noop() {
  echo "Test: existing body with trailing newline + same content = no-op"
  local existing
  existing=$'<!-- doc-superpowers:start -->\n### Added\n- same\n<!-- doc-superpowers:end -->\n'
  local new_section=$'### Added\n- same'
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  local trimmed="${existing%$'\n'}"
  assert_eq "trailing_newline_noop" "$trimmed" "$actual"
}

test_crlf_normalized() {
  echo "Test: CRLF line endings in existing body do not corrupt replace path"
  local existing
  existing=$'## Summary\r\n<!-- doc-superpowers:start -->\r\n### Added\r\n- old\r\n<!-- doc-superpowers:end -->\r\n'
  local new_section=$'### Added\n- new'
  local expected
  expected=$'## Summary\n<!-- doc-superpowers:start -->\n### Added\n- new\n<!-- doc-superpowers:end -->'
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  assert_eq "crlf_normalized" "$expected" "$actual"
}

test_marker_injection_rejected() {
  echo "Test: NEW_SECTION containing a literal marker is rejected (exit 1)"
  local new_section=$'### Added\n- malicious\n<!-- doc-superpowers:end -->\nextra'
  local rc=0
  DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  PASS: marker_injection_rejected (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: marker_injection_rejected — expected rc=1, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_insert_new_section
test_replace_existing_section
test_empty_body
test_noop_when_unchanged
test_malformed_markers_fails
test_trailing_newline_noop
test_crlf_normalized
test_marker_injection_rejected

# ============================================================================
# extract-context.sh tests
# ============================================================================
echo
echo "=== extract-context.sh ==="

EXTRACT_SCRIPT="$HELPERS_DIR/extract-context.sh"
[ -x "$EXTRACT_SCRIPT" ] || {
  echo "FAIL: $EXTRACT_SCRIPT not found or not executable" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "FAIL: jq required for tests" >&2
  exit 1
}

assert_jq() {
  local name="$1" expr="$2" expected="$3" json="$4"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$expr")
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expr:     $expr"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

test_extract_context_full() {
  WORKDIR=$(mktemp -d)
  # Build fixture repo
  (
    cd "$WORKDIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "seed" > seed.txt
    git add seed.txt
    git commit -q -m "chore: seed"
    BASE_SHA=$(git rev-parse HEAD)
    git checkout -q -b feature/x
    echo "a" > a.txt
    git add a.txt
    git commit -q -m "feat: add a"
    echo "b" > b.txt
    git add b.txt
    git commit -q -m "fix: add b"
    echo "$BASE_SHA" > "$WORKDIR/.expected_base"
    git rev-parse HEAD > "$WORKDIR/.expected_head"
  )

  # Mock gh
  SHIM_DIR=$(mktemp -d)
  cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat <<JSON
{"number": 42, "body": "## Summary\nExisting body.", "headRefName": "feature/x", "baseRefName": "main"}
JSON
  exit 0
fi
echo "mock gh: unhandled args: $*" >&2
exit 1
EOF
  chmod +x "$SHIM_DIR/gh"
  PATH_BACKUP="$PATH"
  export PATH="$SHIM_DIR:$PATH"

  BASE_SHA=$(cat "$WORKDIR/.expected_base")
  HEAD_SHA=$(cat "$WORKDIR/.expected_head")

  (
    cd "$WORKDIR"
    JSON=$(PR_NUMBER=42 BASE_REF=main "$EXTRACT_SCRIPT")
    echo "$JSON" > /tmp/extract-ctx-1.json
  )

  JSON=$(cat /tmp/extract-ctx-1.json)
  assert_jq "pr_number"        '.pr_number'                  "42"               "$JSON"
  assert_jq "head_sha"         '.head_sha'                   "$HEAD_SHA"        "$JSON"
  assert_jq "base_sha"         '.base_sha'                   "$BASE_SHA"        "$JSON"
  assert_jq "existing_fragment_null" '.existing_fragment // "null"' "null"     "$JSON"
  assert_jq "full_commits_len" '.full_commits | length'      "2"                "$JSON"
  assert_jq "new_commits_len"  '.new_commits | length'       "2"                "$JSON"
  assert_jq "first_subject"    '.full_commits[0].subject'    "feat: add a"      "$JSON"
  assert_jq "second_subject"   '.full_commits[1].subject'    "fix: add b"       "$JSON"

  # Add fragment + sentinel commit; new_commits should shrink.
  (
    cd "$WORKDIR"
    mkdir -p RELEASE-NOTES.next
    cat > RELEASE-NOTES.next/PR-42.md <<'FRAG'
<!-- doc-superpowers:fragment PR-42 -->
<!-- doc-superpowers:hash deadbeef -->
### Added
- a
FRAG
    git add RELEASE-NOTES.next/PR-42.md
    git commit -q -m "[doc-superpowers] sync PR-42 release notes"
    echo "c" > c.txt
    git add c.txt
    git commit -q -m "chore: post-frag commit"

    JSON2=$(PR_NUMBER=42 BASE_REF=main "$EXTRACT_SCRIPT")
    echo "$JSON2" > /tmp/extract-ctx-2.json
  )

  JSON2=$(cat /tmp/extract-ctx-2.json)
  assert_jq "existing_fragment_present" '.existing_fragment | startswith("<!-- doc-superpowers:fragment")' "true" "$JSON2"
  assert_jq "new_commits_after_frag" '.new_commits | length' "1" "$JSON2"
  assert_jq "new_commit_subject" '.new_commits[0].subject' "chore: post-frag commit" "$JSON2"

  export PATH="$PATH_BACKUP"
  rm -rf "$WORKDIR" "$SHIM_DIR" /tmp/extract-ctx-1.json /tmp/extract-ctx-2.json
}

test_extract_context_rejects_zero() {
  echo "Test: PR_NUMBER=0 is rejected"
  local rc=0
  PR_NUMBER=0 BASE_REF=main "$EXTRACT_SCRIPT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "  PASS: rejects_zero (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: rejects_zero — expected rc=2, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_extract_context_full
test_extract_context_rejects_zero

# commit-and-push.sh tests are appended in Task A5.

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

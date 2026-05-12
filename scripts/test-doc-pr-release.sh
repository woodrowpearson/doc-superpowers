#!/usr/bin/env bash
# Tests for doc-pr-release helpers.
#
# Each helper is tested in isolation. The harness builds /tmp fixture state
# and mocks `gh` via a PATH shim when needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPERS_DIR="$REPO_ROOT/scripts/hooks/ci/doc-pr-release"

# Collect tempdirs and tempfiles for trap-based cleanup so we don't litter
# /tmp if a test aborts before its inline cleanup runs.
DOC_PR_TEST_TMP_PATHS=()
register_tmp() {
  DOC_PR_TEST_TMP_PATHS+=("$1")
}
cleanup_tmp() {
  local p
  for p in "${DOC_PR_TEST_TMP_PATHS[@]:-}"; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    rm -rf "$p"
  done
}
trap cleanup_tmp EXIT INT TERM

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

test_midline_marker_rejected() {
  echo "Test: existing body has start-marker inside a line (not on its own) — rejected"
  # The leading "x " keeps the marker off start-of-line. The previous
  # grep -oF count would treat this as a valid managed section; we now
  # reject it so awk's $0 == start (line-anchored) replace path agrees
  # with the count.
  local existing="user prose x <!-- doc-superpowers:start --> still prose
<!-- doc-superpowers:end -->"
  local rc=0
  DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"### Added" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  PASS: midline_marker_rejected (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: midline_marker_rejected — expected rc=1, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_trailing_whitespace_no_double_blank() {
  echo "Test: existing body with multiple trailing newlines stays at one blank-line separator"
  local existing
  existing=$'## Summary\nUser prose.\n\n\n'
  local new_section=$'### Added\n- one'
  local expected=$'## Summary\nUser prose.\n\n<!-- doc-superpowers:start -->\n### Added\n- one\n<!-- doc-superpowers:end -->'
  local actual
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section")
  assert_eq "trailing_whitespace_no_double_blank" "$expected" "$actual"
}

test_insert_new_section
test_replace_existing_section
test_empty_body
test_noop_when_unchanged
test_malformed_markers_fails
test_trailing_newline_noop
test_crlf_normalized
test_marker_injection_rejected
test_midline_marker_rejected
test_trailing_whitespace_no_double_blank

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
  WORKDIR=$(mktemp -d); register_tmp "$WORKDIR"
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
  SHIM_DIR=$(mktemp -d); register_tmp "$SHIM_DIR"
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
  # Per-test cleanup is now handled by the trap registered above; we still
  # rm the named tempfiles eagerly for tests that examine them later.
  rm -f /tmp/extract-ctx-1.json /tmp/extract-ctx-2.json
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

test_extract_context_corrupt_fragment() {
  echo "Test: malformed existing fragment is flagged with existing_fragment_corrupt=true"
  local work
  work=$(mktemp -d); register_tmp "$work"
  local shim
  shim=$(mktemp -d); register_tmp "$shim"
  cat > "$shim/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"number": 7, "body": "", "headRefName": "feat/x", "baseRefName": "main"}'
  exit 0
fi
exit 1
EOF
  chmod +x "$shim/gh"
  (
    cd "$work"
    git init -q -b main
    git config user.email t@t.com
    git config user.name t
    echo "s" > s.txt
    git add s.txt
    git -c commit.gpgsign=false commit -q -m "seed"
    git checkout -q -b feat/x
    echo "a" > a.txt
    git add a.txt
    git -c commit.gpgsign=false commit -q -m "feat: a"
    mkdir -p RELEASE-NOTES.next
    # Malformed: missing the hash marker on line 2.
    printf '%s\n%s\n%s\n' \
      '<!-- doc-superpowers:fragment PR-7 -->' \
      'this is not a hash marker' \
      '### Added' \
      > RELEASE-NOTES.next/PR-7.md
    PATH="$shim:$PATH" PR_NUMBER=7 BASE_REF=main "$EXTRACT_SCRIPT" > "$work/out.json"
  )
  local corrupt
  corrupt=$(jq -r '.existing_fragment_corrupt' "$work/out.json")
  if [ "$corrupt" = "true" ]; then
    echo "  PASS: corrupt_fragment_flagged"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: corrupt_fragment_flagged — got '$corrupt'"
    FAIL=$((FAIL + 1))
  fi
}

test_extract_context_oversized_fragment() {
  echo "Test: oversized fragment (>1 MiB) is flagged as corrupt"
  local work
  work=$(mktemp -d); register_tmp "$work"
  local shim
  shim=$(mktemp -d); register_tmp "$shim"
  cat > "$shim/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "pr" ] && [ "$2" = "view" ] && echo '{"number": 8, "body": "", "headRefName": "feat/y", "baseRefName": "main"}' && exit 0
exit 1
EOF
  chmod +x "$shim/gh"
  (
    cd "$work"
    git init -q -b main
    git config user.email t@t.com
    git config user.name t
    echo s > s.txt
    git add s.txt
    git -c commit.gpgsign=false commit -q -m seed
    git checkout -q -b feat/y
    mkdir -p RELEASE-NOTES.next
    # 1.1 MiB of zeros — over the 1 MiB cap.
    dd if=/dev/zero of=RELEASE-NOTES.next/PR-8.md bs=1024 count=1126 status=none
    PATH="$shim:$PATH" PR_NUMBER=8 BASE_REF=main "$EXTRACT_SCRIPT" > "$work/out.json" 2>"$work/err"
  )
  local corrupt
  corrupt=$(jq -r '.existing_fragment_corrupt' "$work/out.json")
  if [ "$corrupt" = "true" ]; then
    echo "  PASS: oversized_fragment_flagged"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: oversized_fragment_flagged — got '$corrupt'"
    FAIL=$((FAIL + 1))
  fi
}

test_extract_context_well_formed_fragment() {
  echo "Test: well-formed existing fragment leaves existing_fragment_corrupt=false"
  local work
  work=$(mktemp -d); register_tmp "$work"
  local shim
  shim=$(mktemp -d); register_tmp "$shim"
  cat > "$shim/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "pr" ] && [ "$2" = "view" ] && echo '{"number": 9, "body": "", "headRefName": "feat/z", "baseRefName": "main"}' && exit 0
exit 1
EOF
  chmod +x "$shim/gh"
  (
    cd "$work"
    git init -q -b main
    git config user.email t@t.com
    git config user.name t
    echo s > s.txt; git add s.txt
    git -c commit.gpgsign=false commit -q -m seed
    git checkout -q -b feat/z
    mkdir -p RELEASE-NOTES.next
    printf '%s\n%s\n%s\n' \
      '<!-- doc-superpowers:fragment PR-9 -->' \
      '<!-- doc-superpowers:hash deadbeef -->' \
      '### Added' > RELEASE-NOTES.next/PR-9.md
    PATH="$shim:$PATH" PR_NUMBER=9 BASE_REF=main "$EXTRACT_SCRIPT" > "$work/out.json"
  )
  local corrupt
  corrupt=$(jq -r '.existing_fragment_corrupt' "$work/out.json")
  if [ "$corrupt" = "false" ]; then
    echo "  PASS: well_formed_fragment_ok"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: well_formed_fragment_ok — got '$corrupt'"
    FAIL=$((FAIL + 1))
  fi
}

test_extract_context_full
test_extract_context_rejects_zero
test_extract_context_corrupt_fragment
test_extract_context_oversized_fragment
test_extract_context_well_formed_fragment

# ============================================================================
# commit-and-push.sh smoke tests
# ============================================================================
echo
echo "=== commit-and-push.sh ==="

COMMIT_SCRIPT="$HELPERS_DIR/commit-and-push.sh"
[ -x "$COMMIT_SCRIPT" ] || {
  echo "FAIL: $COMMIT_SCRIPT not found or not executable" >&2
  exit 1
}

test_commit_no_args() {
  echo "Test: no args → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "  PASS: no_args_rc2 (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: no_args_rc2 — expected rc=2, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_nonnumeric() {
  echo "Test: non-numeric PR number → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" abc >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "  PASS: nonnumeric_rc2 (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: nonnumeric_rc2 — expected rc=2, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_zero_rejected() {
  echo "Test: PR_NUMBER=0 → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" 0 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "  PASS: zero_rc2 (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: zero_rc2 — expected rc=2, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_no_fragment_rc0() {
  echo "Test: fragment file missing → rc=0 with no-op message"
  # Run in a temp dir so we don't accidentally commit anything here.
  local rc=0
  local tmp
  tmp=$(mktemp -d); register_tmp "$tmp"
  local rc_file="$tmp/.rc"
  (
    cd "$tmp"
    git init -q -b main >/dev/null 2>&1
    local inner_rc=0
    "$COMMIT_SCRIPT" 999 >/dev/null 2>&1 || inner_rc=$?
    echo "$inner_rc" > "$rc_file"
  )
  if [ -f "$rc_file" ]; then
    rc=$(cat "$rc_file")
  fi
  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS: no_fragment_rc0 (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: no_fragment_rc0 — expected rc=0, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_unset_head_ref_rc1() {
  echo "Test: GITHUB_HEAD_REF unset + fragment present → rc=1 (refuses push)"
  local rc=0
  local tmp
  tmp=$(mktemp -d); register_tmp "$tmp"
  # Subshell can't propagate rc back to parent; persist via sentinel file.
  local rc_file="$tmp/.rc"
  (
    cd "$tmp"
    git init -q -b main >/dev/null 2>&1
    mkdir -p RELEASE-NOTES.next
    echo "<!-- doc-superpowers:fragment PR-7 -->" > RELEASE-NOTES.next/PR-7.md
    echo "### Added" >> RELEASE-NOTES.next/PR-7.md
    echo "- thing" >> RELEASE-NOTES.next/PR-7.md
    # Don't stage — script will git add itself. But we need a HEAD commit
    # for git rev-parse --short to work.
    git -c user.name=t -c user.email=t@t.com commit --allow-empty -q -m "init"
    local inner_rc=0
    # shellcheck disable=SC1007  # intentional: clear GITHUB_HEAD_REF for the command only
    GITHUB_HEAD_REF= "$COMMIT_SCRIPT" 7 >/dev/null 2>&1 || inner_rc=$?
    echo "$inner_rc" > "$rc_file"
  )
  if [ -f "$rc_file" ]; then
    rc=$(cat "$rc_file")
  fi
  rm -rf "$tmp"
  if [ "$rc" -eq 1 ]; then
    echo "  PASS: unset_head_ref_rc1 (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: unset_head_ref_rc1 — expected rc=1, got rc=$rc"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_push_rebase_on_nonff() {
  echo "Test: non-fast-forward push triggers fetch+rebase, succeeds on retry"
  local tmp
  tmp=$(mktemp -d); register_tmp "$tmp"
  local origin="$tmp/origin.git"
  local local_a="$tmp/a"
  local local_b="$tmp/b"
  local rc=0
  (
    # Bare origin repo (the "remote").
    git init -q --bare "$origin"

    # Clone A — simulates the human's checkout.
    git clone -q "$origin" "$local_a"
    cd "$local_a"
    git config user.email t@t.com
    git config user.name t
    git checkout -q -b main
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m seed
    git push -q origin main
    git checkout -q -b feature
    echo a > a.txt
    git add a.txt
    git -c commit.gpgsign=false commit -q -m "feat: a"
    git push -q -u origin feature

    # Clone B — simulates the CI checkout at HEAD of feature.
    cd ..
    git clone -q --branch feature "$origin" "$local_b"
    cd "$local_b"
    git config user.email t@t.com
    git config user.name t

    # Meanwhile, in clone A, a human pushes another commit to feature.
    cd "$local_a"
    git checkout -q feature
    echo human > human.txt
    git add human.txt
    git -c commit.gpgsign=false commit -q -m "human push"
    git push -q origin feature

    # Now commit-and-push.sh runs in clone B. It commits a fragment and
    # pushes — the push should be rejected as non-FF, then the script
    # fetches, rebases, and retries.
    cd "$local_b"
    mkdir -p RELEASE-NOTES.next
    printf '<!-- doc-superpowers:fragment PR-3 -->\n<!-- doc-superpowers:hash 00 -->\n### Added\n- thing\n' > RELEASE-NOTES.next/PR-3.md
    GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 3 >/dev/null 2>&1
    echo $? > "$tmp/rc"

    # Confirm origin now has BOTH the human commit AND the fragment commit.
    cd "$origin"
    git log feature --format=%s > "$tmp/origin_log"
  )
  rc=$(cat "$tmp/rc" 2>/dev/null || echo 99)
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL: push_rebase_on_nonff — script exited rc=$rc"
    FAIL=$((FAIL + 1))
    return
  fi
  local logged
  logged=$(cat "$tmp/origin_log")
  if printf '%s\n' "$logged" | grep -q '^\[doc-superpowers\] sync PR-3 release notes' \
     && printf '%s\n' "$logged" | grep -q '^human push$'; then
    echo "  PASS: push_rebase_on_nonff"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: push_rebase_on_nonff — origin log missing expected commits"
    echo "  --- origin log ---"
    printf '%s\n' "$logged"
    FAIL=$((FAIL + 1))
  fi
}

test_commit_no_args
test_commit_nonnumeric
test_commit_zero_rejected
test_commit_no_fragment_rc0
test_commit_unset_head_ref_rc1
test_commit_push_rebase_on_nonff

# ============================================================================
# Workflow YAML placeholder-substitution sanity
# ============================================================================
echo
echo "=== workflow YAML placeholder substitution ==="

test_workflow_yaml_placeholders() {
  echo "Test: installer substitutes __BASE_BRANCH__ + __VERSION__ in all AI workflow templates"
  local template_dir="$REPO_ROOT/scripts/hooks/ci"
  local tmp
  tmp=$(mktemp -d); register_tmp "$tmp"
  local fail=0
  local f
  for f in "$template_dir"/doc-*.yml; do
    local name
    name=$(basename "$f")
    sed -e 's/__BASE_BRANCH__/main/g' -e 's/__VERSION__/9.9.9/g' -e 's/__CRON_SCHEDULE__/0 0 * * 0/g' -e 's/__CI_STRICT__/false/g' "$f" > "$tmp/$name"
    if grep -E '__BASE_BRANCH__|__VERSION__|__CRON_SCHEDULE__|__CI_STRICT__' "$tmp/$name" >/dev/null; then
      echo "  FAIL: $name still contains an unsubstituted placeholder"
      fail=1
    fi
    if ! python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/$name" 2>/dev/null; then
      echo "  FAIL: $name does not parse as YAML after substitution"
      fail=1
    fi
  done
  if [ "$fail" -eq 0 ]; then
    echo "  PASS: workflow_yaml_placeholders"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}
test_workflow_yaml_placeholders

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

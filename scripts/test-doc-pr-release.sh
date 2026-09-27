#!/usr/bin/env bash
# Tests for the CI workflow helper scripts (doc-pr-release + doc-release) and
# the two templates that call them.
#
# Each helper is tested in isolation against throwaway git fixtures under the
# shared harness's private suite root (test-helpers.sh: isolated git config,
# private HOME, counted asserts, cleanup on EXIT/INT/TERM). `gh` is mocked via
# a PATH shim where a helper needs it. Every helper runs under $BASH_BIN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/scripts/hooks/ci"
HELPERS_DIR="$TEMPLATE_DIR/doc-pr-release"
STEPS_DIR="$TEMPLATE_DIR/doc-superpowers-steps"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

for _h in "$HELPERS_DIR"/update-pr-body.sh "$HELPERS_DIR"/extract-context.sh \
          "$HELPERS_DIR"/commit-and-push.sh "$STEPS_DIR"/sentinel-check.sh \
          "$STEPS_DIR"/write-context.sh "$STEPS_DIR"/resolve-auth.sh \
          "$STEPS_DIR"/verify-fragment.sh "$STEPS_DIR"/precheck.sh; do
  [ -x "$_h" ] || { echo "FAIL: $_h not found or not executable" >&2; exit 1; }
done
command -v jq >/dev/null || { echo "FAIL: jq required for tests" >&2; exit 1; }

# Shimmed so each helper runs under the interpreter this suite was launched
# with, not whatever its shebang resolves to. See bash_bin_shim().
UPDATE_SCRIPT="$(bash_bin_shim "$HELPERS_DIR/update-pr-body.sh")"
EXTRACT_SCRIPT="$(bash_bin_shim "$HELPERS_DIR/extract-context.sh")"
COMMIT_SCRIPT="$(bash_bin_shim "$HELPERS_DIR/commit-and-push.sh")"
SENTINEL_SCRIPT="$(bash_bin_shim "$STEPS_DIR/sentinel-check.sh")"
WRITE_CONTEXT_SCRIPT="$(bash_bin_shim "$STEPS_DIR/write-context.sh")"
AUTH_SCRIPT="$(bash_bin_shim "$STEPS_DIR/resolve-auth.sh")"
VERIFY_SCRIPT="$(bash_bin_shim "$STEPS_DIR/verify-fragment.sh")"
PRECHECK_SCRIPT="$(bash_bin_shim "$STEPS_DIR/precheck.sh")"

SENTINEL_SUBJECT_RE='^\[doc-superpowers\] sync PR-[0-9]+ release notes'

# --- fixture helpers ---------------------------------------------------------

# A throwaway repo with one seed commit on `main`; echoes its path.
new_repo() {
  local dir
  dir=$(harness_mktemp_d repo)
  (
    cd "$dir"
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git config user.email t@t.com
    git config user.name t
    git config commit.gpgsign false
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m "chore: seed"
  )
  printf '%s' "$dir"
}

# commit_file <repo> <path> <content> <subject>
commit_file() {
  (
    cd "$1"
    mkdir -p "$(dirname "$2")"
    printf '%s\n' "$3" > "$2"
    git add "$2"
    git commit -q -m "$4"
  )
}

# A `gh` shim answering `gh pr view` with the given PR JSON; echoes its dir.
gh_shim() {
  local dir
  dir=$(harness_mktemp_d gh-shim)
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  cat <<'JSON'
$1
JSON
  exit 0
fi
echo "mock gh: unhandled args: \$*" >&2
exit 1
EOF
  chmod +x "$dir/gh"
  printf '%s' "$dir"
}

# run_extract <repo> <gh-shim-dir> <pr> <out-file> — never aborts the suite.
run_extract() {
  local rc=0
  ( cd "$1" && PATH="$2:$PATH" PR_NUMBER="$3" BASE_REF=main "$EXTRACT_SCRIPT" > "$4" 2>"$4.err" ) || rc=$?
  return "$rc"
}

# The subjects of a commits array, '|'-joined, from a context JSON file.
subjects() {
  jq -r "[.$2[].subject] | join(\"|\")" "$1" 2>/dev/null || echo "<unreadable $1>"
}

# ============================================================================
# update-pr-body.sh tests
# ============================================================================
echo "=== update-pr-body.sh ==="

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
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  assert_eq "0" "$rc" "insert_new_section exits 0"
  assert_eq "$expected" "$actual" "insert_new_section"
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
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  assert_eq "0" "$rc" "replace_existing_section exits 0"
  assert_eq "$expected" "$actual" "replace_existing_section"
}

test_empty_body() {
  echo "Test: empty existing body"
  local new_section="### Added
- one"
  local expected="<!-- doc-superpowers:start -->
### Added
- one
<!-- doc-superpowers:end -->"
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  assert_eq "0" "$rc" "empty_body exits 0"
  assert_eq "$expected" "$actual" "empty_body"
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
  assert_eq "0" "$rc" "noop_exit_code"
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
  assert_eq "1" "$rc" "malformed_markers_fails (rc=1)"
}

test_trailing_newline_noop() {
  echo "Test: existing body with trailing newline + same content = no-op"
  local existing
  existing=$'<!-- doc-superpowers:start -->\n### Added\n- same\n<!-- doc-superpowers:end -->\n'
  local new_section=$'### Added\n- same'
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  local trimmed="${existing%$'\n'}"
  assert_eq "0" "$rc" "trailing_newline_noop exits 0"
  assert_eq "$trimmed" "$actual" "trailing_newline_noop"
}

test_crlf_normalized() {
  echo "Test: CRLF line endings in existing body do not corrupt replace path"
  local existing
  existing=$'## Summary\r\n<!-- doc-superpowers:start -->\r\n### Added\r\n- old\r\n<!-- doc-superpowers:end -->\r\n'
  local new_section=$'### Added\n- new'
  local expected
  expected=$'## Summary\n<!-- doc-superpowers:start -->\n### Added\n- new\n<!-- doc-superpowers:end -->'
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  assert_eq "0" "$rc" "crlf_normalized exits 0"
  assert_eq "$expected" "$actual" "crlf_normalized"
}

test_marker_injection_rejected() {
  echo "Test: NEW_SECTION containing a literal marker is rejected (exit 1)"
  local new_section=$'### Added\n- malicious\n<!-- doc-superpowers:end -->\nextra'
  local rc=0
  DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section" >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "marker_injection_rejected (rc=1)"
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
  assert_eq "1" "$rc" "midline_marker_rejected (rc=1)"
}

test_trailing_whitespace_no_double_blank() {
  echo "Test: existing body with multiple trailing newlines stays at one blank-line separator"
  local existing
  existing=$'## Summary\nUser prose.\n\n\n'
  local new_section=$'### Added\n- one'
  local expected=$'## Summary\nUser prose.\n\n<!-- doc-superpowers:start -->\n### Added\n- one\n<!-- doc-superpowers:end -->'
  local actual rc=0
  actual=$(DOC_SUPERPOWERS_DRY_RUN=1 \
    DOC_SUPERPOWERS_EXISTING_BODY="$existing" \
    "$UPDATE_SCRIPT" 999 <<<"$new_section") || rc=$?
  assert_eq "0" "$rc" "trailing_whitespace_no_double_blank exits 0"
  assert_eq "$expected" "$actual" "trailing_whitespace_no_double_blank"
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

test_extract_context_full() {
  echo "Test: linear history — commit ranges, then the post-fragment range"
  local work shim out
  work=$(new_repo)
  local base_sha head_sha
  base_sha=$(git -C "$work" rev-parse HEAD)
  git -C "$work" checkout -q -b feature/x
  commit_file "$work" a.txt a "feat: add a"
  commit_file "$work" b.txt b "fix: add b"
  head_sha=$(git -C "$work" rev-parse HEAD)
  shim=$(gh_shim '{"number": 42, "body": "## Summary\nExisting body.", "headRefName": "feature/x", "baseRefName": "main"}')

  out="$work/ctx-1.json"
  local rc=0
  run_extract "$work" "$shim" 42 "$out" || rc=$?
  assert_eq "0" "$rc" "extract-context exits 0 (linear)"
  local json
  json=$(cat "$out")
  assert_json_field "$json" '.pr_number' "42" "pr_number"
  assert_json_field "$json" '.head_sha' "$head_sha" "head_sha"
  assert_json_field "$json" '.base_sha' "$base_sha" "base_sha"
  assert_json_field "$json" '.existing_fragment // "null"' "null" "existing_fragment_null"
  assert_json_field "$json" '.full_commits | length' "2" "full_commits_len"
  assert_json_field "$json" '.new_commits | length' "2" "new_commits_len"
  assert_json_field "$json" '.full_commits[0].subject' "feat: add a" "first_subject"
  assert_json_field "$json" '.full_commits[1].subject' "fix: add b" "second_subject"

  # Add fragment + sentinel commit; new_commits should shrink.
  (
    cd "$work"
    mkdir -p RELEASE-NOTES.next
    printf '%s\n' '<!-- doc-superpowers:fragment PR-42 -->' '<!-- doc-superpowers:hash deadbeef -->' \
      '### Added' '- a' > RELEASE-NOTES.next/PR-42.md
    git add RELEASE-NOTES.next/PR-42.md
    git commit -q -m "[doc-superpowers] sync PR-42 release notes"
  )
  commit_file "$work" c.txt c "chore: post-frag commit"

  out="$work/ctx-2.json"
  rc=0
  run_extract "$work" "$shim" 42 "$out" || rc=$?
  assert_eq "0" "$rc" "extract-context exits 0 (after fragment)"
  json=$(cat "$out")
  assert_json_field "$json" '.existing_fragment | startswith("<!-- doc-superpowers:fragment")' "true" "existing_fragment_present"
  assert_json_field "$json" '.new_commits | length' "1" "new_commits_after_frag"
  assert_json_field "$json" '.new_commits[0].subject' "chore: post-frag commit" "new_commit_subject"
}

test_extract_context_update_branch() {
  # GitHub's "Update branch" button merges the base INTO the PR branch. The
  # merge commit is not PR work and must never reach the agent.
  echo "Test: 'Update branch' merge — merge commit and base-only commits stay out of full_commits"
  local work shim out rc=0
  work=$(new_repo)
  git -C "$work" checkout -q -b feature/x
  commit_file "$work" a.txt a "feat: add a"
  git -C "$work" checkout -q main
  commit_file "$work" main1.txt m1 "chore: main-only 1"
  git -C "$work" checkout -q feature/x
  git -C "$work" merge -q --no-ff --no-edit -m "Merge branch 'main' into feature/x" main
  shim=$(gh_shim '{"number": 42, "body": "", "headRefName": "feature/x", "baseRefName": "main"}')

  out="$work/ctx-1.json"
  run_extract "$work" "$shim" 42 "$out" || rc=$?
  assert_eq "0" "$rc" "extract-context exits 0 after an Update-branch merge"
  assert_eq "feat: add a" "$(subjects "$out" full_commits)" \
    "full_commits = PR work only (no merge commit, no base-only commit)"
  assert_eq "feat: add a" "$(subjects "$out" new_commits)" \
    "new_commits = PR work only before any fragment exists"

  # Fragment synced, then the base moves and is merged in again, then more PR
  # work. The watermark is the last commit touching the fragment, so a base
  # commit merged in after it leaks into new_commits — the known I-9 base-range
  # defect (T10: "extract-context excludes base-branch commits").
  (
    cd "$work"
    mkdir -p RELEASE-NOTES.next
    printf '%s\n' '<!-- doc-superpowers:fragment PR-42 -->' '<!-- doc-superpowers:hash deadbeef -->' \
      '### Added' '- a' > RELEASE-NOTES.next/PR-42.md
    git add RELEASE-NOTES.next/PR-42.md
    git commit -q -m "[doc-superpowers] sync PR-42 release notes"
    git checkout -q main
  )
  commit_file "$work" main2.txt m2 "chore: main-only 2"
  git -C "$work" checkout -q feature/x
  git -C "$work" merge -q --no-ff --no-edit -m "Merge branch 'main' into feature/x" main
  commit_file "$work" b.txt b "fix: add b"

  out="$work/ctx-2.json"
  rc=0
  run_extract "$work" "$shim" 42 "$out" || rc=$?
  assert_eq "0" "$rc" "extract-context exits 0 after a second Update-branch merge"
  assert_not_contains "$(subjects "$out" new_commits)" "Merge branch" \
    "new_commits never carries the Update-branch merge commit"
  assert_eq_known_bug "T10/I-9" "fix: add b" "chore: main-only 2|fix: add b" "$(subjects "$out" new_commits)" \
    "new_commits after a fragment sync = PR work only (base commit merged in later excluded)"
}

test_extract_context_human_fragment_edit() {
  # A human rewords the bot's fragment and commits it. The markers stay valid
  # (so it is not "corrupt"; the agent's hash check is what detects the edit),
  # the human text is what the agent sees, and the new-commit range starts
  # after the human's edit, the last commit that touched the fragment.
  echo "Test: human fragment edit — human text surfaced, not corrupt, range restarts after the edit"
  local work shim out rc=0
  work=$(new_repo)
  git -C "$work" checkout -q -b feature/x
  commit_file "$work" a.txt a "feat: add a"
  (
    cd "$work"
    mkdir -p RELEASE-NOTES.next
    printf '%s\n' '<!-- doc-superpowers:fragment PR-42 -->' '<!-- doc-superpowers:hash deadbeef -->' \
      '### Added' '- a (bot wording)' > RELEASE-NOTES.next/PR-42.md
    git add RELEASE-NOTES.next/PR-42.md
    git commit -q -m "[doc-superpowers] sync PR-42 release notes"
    printf '%s\n' '<!-- doc-superpowers:fragment PR-42 -->' '<!-- doc-superpowers:hash deadbeef -->' \
      '### Added' '- a, reworded by a human' > RELEASE-NOTES.next/PR-42.md
    git commit -q -am "docs: reword the release note"
  )
  commit_file "$work" c.txt c "feat: add c"
  shim=$(gh_shim '{"number": 42, "body": "", "headRefName": "feature/x", "baseRefName": "main"}')

  out="$work/ctx.json"
  run_extract "$work" "$shim" 42 "$out" || rc=$?
  assert_eq "0" "$rc" "extract-context exits 0 on a human-edited fragment"
  local json
  json=$(cat "$out")
  assert_json_field "$json" '.existing_fragment | contains("reworded by a human")' "true" \
    "existing_fragment is the human's text"
  assert_json_field "$json" '.existing_fragment_corrupt' "false" \
    "a human edit with intact markers is not flagged corrupt"
  assert_eq "feat: add c" "$(subjects "$out" new_commits)" \
    "new_commits restart after the human's fragment edit"
}

test_extract_context_rejects_zero() {
  echo "Test: PR_NUMBER=0 is rejected"
  local rc=0
  PR_NUMBER=0 BASE_REF=main "$EXTRACT_SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "rejects_zero (rc=2)"
}

# expect_corrupt <pr> <expected true|false> <msg> — fragment already in $work.
_extract_corrupt_flag() {
  local work="$1" pr="$2" shim out rc=0
  shim=$(gh_shim "{\"number\": $pr, \"body\": \"\", \"headRefName\": \"feat/x\", \"baseRefName\": \"main\"}")
  out="$work/out.json"
  run_extract "$work" "$shim" "$pr" "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'extract-context rc=%s: %s' "$rc" "$(cat "$out.err" 2>/dev/null)"
    return 0
  fi
  jq -r '.existing_fragment_corrupt' "$out" 2>/dev/null || echo "<unreadable>"
}

# fragment_repo <pr> <file-lines...> — repo on feat/x with PR-<pr>.md uncommitted.
fragment_repo() {
  local pr="$1" work
  shift
  work=$(new_repo)
  (
    cd "$work"
    git checkout -q -b feat/x
    mkdir -p RELEASE-NOTES.next
    printf '%s\n' "$@" > "RELEASE-NOTES.next/PR-$pr.md"
  )
  printf '%s' "$work"
}

test_extract_context_corrupt_fragment() {
  echo "Test: malformed existing fragment (bad line 2) is flagged existing_fragment_corrupt=true"
  local work
  work=$(fragment_repo 7 '<!-- doc-superpowers:fragment PR-7 -->' 'this is not a hash marker' '### Added')
  assert_eq "true" "$(_extract_corrupt_flag "$work" 7)" "corrupt_fragment_flagged"
}

test_extract_context_wrong_line1() {
  echo "Test: fragment whose line 1 names another PR is flagged corrupt"
  local work
  work=$(fragment_repo 42 '<!-- doc-superpowers:fragment PR-41 -->' '<!-- doc-superpowers:hash deadbeef -->' '### Added' '- x')
  assert_eq "true" "$(_extract_corrupt_flag "$work" 42)" "wrong_pr_on_line1_flagged"
}

test_extract_context_too_few_lines() {
  echo "Test: fragment with both markers but no content line is flagged corrupt"
  local work
  work=$(fragment_repo 43 '<!-- doc-superpowers:fragment PR-43 -->' '<!-- doc-superpowers:hash deadbeef -->')
  assert_eq "true" "$(_extract_corrupt_flag "$work" 43)" "two_line_fragment_flagged"
}

test_extract_context_oversized_fragment() {
  echo "Test: oversized fragment (>1 MiB) is flagged as corrupt"
  local work
  work=$(new_repo)
  (
    cd "$work"
    git checkout -q -b feat/x
    mkdir -p RELEASE-NOTES.next
    # 1.1 MiB of zeros — over the 1 MiB cap.
    dd if=/dev/zero of=RELEASE-NOTES.next/PR-8.md bs=1024 count=1126 2>/dev/null
  )
  assert_eq "true" "$(_extract_corrupt_flag "$work" 8)" "oversized_fragment_flagged"
}

test_extract_context_well_formed_fragment() {
  echo "Test: well-formed existing fragment leaves existing_fragment_corrupt=false"
  local work
  work=$(fragment_repo 9 '<!-- doc-superpowers:fragment PR-9 -->' '<!-- doc-superpowers:hash deadbeef -->' '### Added')
  assert_eq "false" "$(_extract_corrupt_flag "$work" 9)" "well_formed_fragment_ok"
}

test_extract_context_full
test_extract_context_update_branch
test_extract_context_human_fragment_edit
test_extract_context_rejects_zero
test_extract_context_corrupt_fragment
test_extract_context_wrong_line1
test_extract_context_too_few_lines
test_extract_context_oversized_fragment
test_extract_context_well_formed_fragment

# ============================================================================
# commit-and-push.sh tests
# ============================================================================
echo
echo "=== commit-and-push.sh ==="

test_commit_no_args() {
  echo "Test: no args → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "no_args_rc2"
}

test_commit_nonnumeric() {
  echo "Test: non-numeric PR number → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" abc >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "nonnumeric_rc2"
}

test_commit_zero_rejected() {
  echo "Test: PR_NUMBER=0 → rc=2"
  local rc=0
  "$COMMIT_SCRIPT" 0 >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "zero_rc2"
}

test_commit_no_fragment_rc0() {
  echo "Test: fragment file missing → rc=0 with no-op message"
  local work rc=0
  work=$(new_repo)
  ( cd "$work" && "$COMMIT_SCRIPT" 999 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "no_fragment_rc0"
}

test_commit_unset_head_ref_rc1() {
  echo "Test: GITHUB_HEAD_REF unset + fragment present → rc=1 (refuses push)"
  local work rc=0
  work=$(new_repo)
  (
    cd "$work"
    mkdir -p RELEASE-NOTES.next
    printf '%s\n' '<!-- doc-superpowers:fragment PR-7 -->' '### Added' '- thing' > RELEASE-NOTES.next/PR-7.md
    # shellcheck disable=SC1007  # intentional: clear GITHUB_HEAD_REF for the command only
    GITHUB_HEAD_REF= "$COMMIT_SCRIPT" 7 >/dev/null 2>&1
  ) || rc=$?
  assert_eq "1" "$rc" "unset_head_ref_rc1"
}

# A bare origin plus a clone checked out on `feature` (pushed); echoes the
# parent dir: <dir>/origin.git and <dir>/clone.
origin_and_clone() {
  local dir
  dir=$(harness_mktemp_d remote)
  (
    git init -q --bare "$dir/origin.git"
    git init -q -b main "$dir/seed" 2>/dev/null || { git init -q "$dir/seed" && git -C "$dir/seed" symbolic-ref HEAD refs/heads/main; }
    cd "$dir/seed"
    git config user.email t@t.com
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m seed
    git checkout -q -b feature
    echo a > a.txt
    git add a.txt
    git -c commit.gpgsign=false commit -q -m "feat: a"
    git remote add origin "$dir/origin.git"
    git push -q origin main feature
    git clone -q --branch feature "$dir/origin.git" "$dir/clone"
    cd "$dir/clone"
    git config user.email t@t.com
    git config user.name t
  )
  printf '%s' "$dir"
}

write_fragment_file() {
  mkdir -p "$1/RELEASE-NOTES.next"
  printf '<!-- doc-superpowers:fragment PR-%s -->\n<!-- doc-superpowers:hash 00 -->\n### Added\n- %s\n' \
    "$2" "$3" > "$1/RELEASE-NOTES.next/PR-$2.md"
}

test_commit_push_rebase_on_nonff() {
  echo "Test: non-fast-forward push triggers fetch+rebase, succeeds on retry"
  local dir rc=0
  dir=$(origin_and_clone)
  # Meanwhile a human pushes another commit to feature from the seed clone.
  (
    cd "$dir/seed"
    echo human > human.txt
    git add human.txt
    git -c commit.gpgsign=false commit -q -m "human push"
    git push -q origin feature
  )
  write_fragment_file "$dir/clone" 3 thing
  ( cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 3 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "push_rebase_on_nonff exits 0"
  local logged
  logged=$(git -C "$dir/origin.git" log feature --format=%s)
  assert_true "origin has the fragment sync commit" grep -qE "$SENTINEL_SUBJECT_RE" <<<"$logged"
  assert_true "origin keeps the human's concurrent commit" grep -qx 'human push' <<<"$logged"
}

test_commit_stages_only_fragment() {
  # The bot must never sweep a checkout's other changes into its commit: the
  # CI workspace can hold agent scratch files, and the job pushes to a human's
  # PR branch.
  echo "Test: commits only its own fragment path (tracked edits + untracked files left alone)"
  local dir rc=0
  dir=$(origin_and_clone)
  (
    cd "$dir/clone"
    echo "local edit" >> seed.txt
    echo stray > stray.txt
  )
  write_fragment_file "$dir/clone" 5 thing
  ( cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 5 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "commit-and-push exits 0"
  assert_eq "RELEASE-NOTES.next/PR-5.md" \
    "$(git -C "$dir/clone" show --name-only --format= HEAD)" \
    "the sync commit contains only RELEASE-NOTES.next/PR-5.md"
  local status
  status=$(git -C "$dir/clone" status --porcelain)
  assert_contains "$status" " M seed.txt" "unrelated tracked edit left unstaged"
  assert_contains "$status" "?? stray.txt" "untracked file left untracked"
  assert_true "sync commit pushed to origin/feature" \
    grep -qE "$SENTINEL_SUBJECT_RE" <<<"$(git -C "$dir/origin.git" log -1 --format=%s feature)"
}

test_commit_prestaged_file_excluded() {
  # A file already in the index when the helper runs is swept into the bot's
  # commit: `git commit` without a pathspec commits the whole index. T10
  # (I-9) owns "commits only the fragment path".
  echo "Test: a pre-staged unrelated file is not swept into the sync commit"
  local dir rc=0
  dir=$(origin_and_clone)
  ( cd "$dir/clone" && echo staged > staged.txt && git add staged.txt )
  write_fragment_file "$dir/clone" 6 thing
  ( cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 6 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "commit-and-push exits 0 with a pre-staged file"
  assert_eq_known_bug "T10/I-9" "RELEASE-NOTES.next/PR-6.md" "RELEASE-NOTES.next/PR-6.md staged.txt" \
    "$(git -C "$dir/clone" show --name-only --format= HEAD | tr '\n' ' ' | sed 's/ $//')" \
    "the sync commit contains only the fragment even when the index holds other changes"
}

test_commit_noop_unchanged_fragment() {
  echo "Test: fragment already committed and unchanged → rc=0, no commit, no push"
  local dir rc=0 out
  dir=$(origin_and_clone)
  write_fragment_file "$dir/clone" 4 thing
  ( cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 4 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "first run commits and pushes"
  local head_before origin_before
  head_before=$(git -C "$dir/clone" rev-parse HEAD)
  origin_before=$(git -C "$dir/origin.git" rev-parse feature)
  rc=0
  out=$(cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 4 2>&1) || rc=$?
  assert_eq "0" "$rc" "second run with an unchanged fragment exits 0"
  assert_contains "$out" "Fragment unchanged" "second run reports the no-op"
  assert_eq "$head_before" "$(git -C "$dir/clone" rev-parse HEAD)" "no new local commit"
  assert_eq "$origin_before" "$(git -C "$dir/origin.git" rev-parse feature)" "nothing pushed"
}

test_commit_no_args
test_commit_nonnumeric
test_commit_zero_rejected
test_commit_no_fragment_rc0
test_commit_unset_head_ref_rc1
test_commit_push_rebase_on_nonff
test_commit_stages_only_fragment
test_commit_prestaged_file_excluded
test_commit_noop_unchanged_fragment

# ============================================================================
# Workflow step helpers (extracted from the templates' inline run: bodies)
# ============================================================================
echo
echo "=== workflow step helpers ==="

# run_step <out-var-file> <cmd...> — runs with a fresh $GITHUB_OUTPUT; the
# combined stdout+stderr lands in "$1.log". Returns the step's rc.
run_step() {
  local out_file="$1"
  shift
  : > "$out_file"
  local rc=0
  GITHUB_OUTPUT="$out_file" "$@" > "$out_file.log" 2>&1 || rc=$?
  return "$rc"
}

test_sentinel_check() {
  echo "Test: sentinel-check.sh — skip only when HEAD is the bot's sync commit"
  local work out rc
  work=$(new_repo)
  out="$work/gh-output"

  rc=0
  ( cd "$work" && run_step "$out" "$SENTINEL_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "exits 0 on an ordinary head"
  assert_eq "skip=false" "$(cat "$out")" "ordinary head → skip=false"

  git -C "$work" commit -q --allow-empty -m "[doc-superpowers] sync PR-12 release notes (abc1234)"
  rc=0
  ( cd "$work" && run_step "$out" "$SENTINEL_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "exits 0 on a sentinel head"
  assert_eq "skip=true" "$(cat "$out")" "sentinel head → skip=true"

  git -C "$work" commit -q --allow-empty -m 'Revert "[doc-superpowers] sync PR-12 release notes (abc1234)"'
  rc=0
  ( cd "$work" && run_step "$out" "$SENTINEL_SCRIPT" ) || rc=$?
  assert_eq "skip=false" "$(cat "$out")" "sentinel text not at subject start → skip=false"
}

test_write_context() {
  echo "Test: write-context.sh — writes context.json and new_commits_len (new, not full, commits)"
  local work shim out rc=0
  work=$(new_repo)
  git -C "$work" checkout -q -b feat/x
  commit_file "$work" a.txt a "feat: a"
  commit_file "$work" RELEASE-NOTES.next/PR-21.md "$(printf '%s\n' '<!-- doc-superpowers:fragment PR-21 -->' \
    '<!-- doc-superpowers:hash deadbeef -->' '### Added' '- a')" "[doc-superpowers] sync PR-21 release notes"
  commit_file "$work" b.txt b "feat: b"
  commit_file "$work" c.txt c "feat: c"
  shim=$(gh_shim '{"number": 21, "body": "", "headRefName": "feat/x", "baseRefName": "main"}')
  out="$work/gh-output"
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=21 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "exits 0"
  assert_eq "new_commits_len=2" "$(cat "$out")" "new_commits_len (2 since the fragment sync, of 4) written to GITHUB_OUTPUT"
  assert_json_field "$(cat "$work/.doc-pr-release/context.json" 2>/dev/null)" '.pr_number' "21" \
    "context.json written under .doc-pr-release/"

  rc=0
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=0 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_true "extract-context failure fails the step (rc=$rc)" test "$rc" -ne 0
  assert_eq "" "$(cat "$out")" "no new_commits_len written when extraction fails"
}

test_resolve_auth() {
  echo "Test: resolve-auth.sh — OAuth wins, API key falls back, neither fails"
  local dir out rc
  dir=$(harness_mktemp_d auth)
  out="$dir/gh-output"

  rc=0
  OAUTH=tok API_KEY= run_step "$out" "$AUTH_SCRIPT" || rc=$?
  assert_eq "0" "$rc" "OAuth only → exits 0"
  assert_eq "use_oauth=true" "$(cat "$out")" "OAuth only → use_oauth=true"
  assert_not_contains "$(cat "$out.log")" "::notice::" "OAuth only → no both-set notice"

  rc=0
  OAUTH=tok API_KEY=key run_step "$out" "$AUTH_SCRIPT" || rc=$?
  assert_eq "use_oauth=true" "$(cat "$out")" "both set → OAuth wins"
  assert_contains "$(cat "$out.log")" "::notice::Both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set" \
    "both set → notice"

  rc=0
  OAUTH= API_KEY=key run_step "$out" "$AUTH_SCRIPT" || rc=$?
  assert_eq "0" "$rc" "API key only → exits 0"
  assert_eq "use_oauth=false" "$(cat "$out")" "API key only → use_oauth=false"

  rc=0
  OAUTH= API_KEY= run_step "$out" "$AUTH_SCRIPT" || rc=$?
  assert_eq "1" "$rc" "neither set → exits 1"
  assert_contains "$(cat "$out.log")" "::error::Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY" \
    "neither set → ::error:: annotation"
  assert_eq "" "$(cat "$out")" "neither set → no output written"
}

test_verify_fragment() {
  echo "Test: verify-fragment.sh — fails closed when the agent produced nothing"
  local work out rc
  work=$(new_repo)
  out="$work/gh-output"

  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "no sync commit and no fragment → exits 1"
  assert_contains "$(cat "$out.log")" "silently skipped" "no-fragment case explains itself"

  write_fragment_file "$work" 31 thing
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "existing fragment, no sync commit (agent no-op / human edit) → exits 0"

  ( cd "$work" && git add RELEASE-NOTES.next && git commit -q -m "[doc-superpowers] sync PR-31 release notes (abc1234)" )
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "sync commit with its fragment → exits 0"

  ( cd "$work" && git rm -q RELEASE-NOTES.next/PR-31.md && git commit -q -m "[doc-superpowers] sync PR-31 release notes (def5678)" )
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "sync commit but fragment missing on disk → exits 1"
}

test_release_precheck() {
  echo "Test: precheck.sh (doc-release) — skip only when nothing is unreleased"
  local work out rc
  work=$(new_repo)
  out="$work/gh-output"

  rc=0
  ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "no tags → exits 0"
  assert_eq "skip=false" "$(cat "$out")" "no tags (first release) → skip=false"

  git -C "$work" tag v1.0.0
  rc=0
  ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "skip=true" "$(cat "$out")" "HEAD is the last tag → skip=true"

  commit_file "$work" a.txt a "feat: a"
  commit_file "$work" b.txt b "fix: b"
  rc=0
  ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "skip=false" "$(cat "$out")" "commits after the tag → skip=false"
  assert_contains "$(cat "$out.log")" "2 commits since v1.0.0" "reports the unreleased count"
}

test_sentinel_check
test_write_context
test_resolve_auth
test_verify_fragment
test_release_precheck

# ============================================================================
# Workflow templates: YAML validity, structure, and wiring
# ============================================================================
echo
echo "=== workflow templates ==="

# Name of an available YAML parser, or empty if there is none.
#
# PyYAML is present on the ubuntu runner but NOT on the macOS one; Ruby's psych
# is stdlib and present on both runner images, so it is the fallback. The
# lookup runs with the caller's real HOME so a per-user PyYAML install is still
# found despite the harness's private HOME.
_yaml_parser() {
  if HOME="$_HARNESS_REAL_HOME" python3 -c 'import yaml' >/dev/null 2>&1; then
    echo python3
  elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
    echo ruby
  fi
}
YAML_PARSER=$(_yaml_parser)

# No parser → a loud, counted SKIP locally. CI sets
# DOC_SP_REQUIRE_YAML_PARSER=1 (tests.yml), which turns the SKIP into a FAIL so
# a missing parser can never become a silent CI pass.
yaml_unavailable() {
  if [ -n "$YAML_PARSER" ]; then
    return 1
  fi
  if [ "${DOC_SP_REQUIRE_YAML_PARSER:-0}" = "1" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    FAIL=$((FAIL + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: %s — no YAML parser (need python3 with PyYAML, or ruby) and DOC_SP_REQUIRE_YAML_PARSER=1\n" "$1"
  else
    record_skip "$1 — no YAML parser (need python3 with PyYAML, or ruby)"
  fi
  return 0
}

# _yaml_parse <file> — prints the parser's own error on failure.
_yaml_parse() {
  case "$YAML_PARSER" in
    python3) HOME="$_HARNESS_REAL_HOME" python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1" 2>&1 ;;
    ruby)    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" 2>&1 ;;
    *)       echo "no YAML parser selected"; return 1 ;;
  esac
}

# _yaml_get <file> <dotted.key.path> — scalar as text, other values as JSON.
_yaml_get() {
  case "$YAML_PARSER" in
    python3) HOME="$_HARNESS_REAL_HOME" python3 -c '
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(d if isinstance(d, str) else json.dumps(d))' "$1" "$2" 2>&1 ;;
    ruby) ruby -ryaml -rjson -e '
d = YAML.load_file(ARGV[0])
ARGV[1].split(".").each { |k| d = d[k] }
puts(d.is_a?(String) ? d : d.to_json)' "$1" "$2" 2>&1 ;;
  esac
}

# _yaml_runs <file> — one JSON object per step with a run: key:
# {"job":…, "step":…, "run":…}
_yaml_runs() {
  case "$YAML_PARSER" in
    python3) HOME="$_HARNESS_REAL_HOME" python3 -c '
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job, spec in d["jobs"].items():
    for st in spec.get("steps", []):
        if "run" in st:
            print(json.dumps({"job": job, "step": st.get("name", ""), "run": st["run"]}))' "$1" 2>&1 ;;
    ruby) ruby -ryaml -rjson -e '
d = YAML.load_file(ARGV[0])
d["jobs"].each do |job, spec|
  (spec["steps"] || []).each do |st|
    puts({"job" => job, "step" => (st["name"] || ""), "run" => st["run"]}.to_json) if st.key?("run")
  end
end' "$1" 2>&1 ;;
  esac
}

test_workflow_yaml_placeholders() {
  echo "Test: installer substitutes __BASE_BRANCH__ + __VERSION__ in all AI workflow templates"
  yaml_unavailable "workflow_yaml_placeholders" && return 0
  echo "  (YAML parser: $YAML_PARSER)"
  local tmp f name parse_err fail=0 detail=""
  tmp=$(harness_mktemp_d yaml)
  for f in "$TEMPLATE_DIR"/doc-*.yml; do
    name=$(basename "$f")
    sed -e 's/__BASE_BRANCH__/main/g' -e 's/__VERSION__/9.9.9/g' -e 's/__CRON_SCHEDULE__/0 0 * * 0/g' -e 's/__CI_STRICT__/false/g' "$f" > "$tmp/$name"
    if grep -E '__BASE_BRANCH__|__VERSION__|__CRON_SCHEDULE__|__CI_STRICT__' "$tmp/$name" >/dev/null; then
      detail="${detail}    $name still contains an unsubstituted placeholder"$'\n'
      fail=1
    fi
    if ! parse_err=$(_yaml_parse "$tmp/$name"); then
      detail="${detail}    $name does not parse as YAML after substitution: $parse_err"$'\n'
      fail=1
    fi
  done
  [ "$fail" -eq 0 ] || printf '%s' "$detail"
  assert_eq "0" "$fail" "workflow_yaml_placeholders (every template substitutes and parses)"
}

test_workflow_structure_guards() {
  echo "Test: template structure guards that no run: body can express"
  yaml_unavailable "workflow_structure_guards" && return 0
  # Cancelling an in-flight run between `git commit` and `git push` leaves an
  # orphan local commit (see the template comment); must stay false.
  assert_eq "false" "$(_yaml_get "$TEMPLATE_DIR/doc-pr-release.yml" concurrency.cancel-in-progress)" \
    "doc-pr-release.yml: concurrency.cancel-in-progress is false"
  # The job-level guard is what stops the bot's own release-notes commit from
  # re-running the release job.
  assert_contains "$(_yaml_get "$TEMPLATE_DIR/doc-release.yml" jobs.release-notes.if)" \
    "!contains(github.event.head_commit.message, '[doc-superpowers]')" \
    "doc-release.yml: release-notes job skips the bot's own commits"
}

test_workflow_helper_wiring() {
  echo "Test: every run: step is a shipped helper call (no untested inline body)"
  yaml_unavailable "workflow_helper_wiring" && return 0
  local tpl line step run dir helper bad=""
  for tpl in doc-pr-release.yml doc-release.yml; do
    while IFS= read -r line; do
      step=$(jq -r '.step' <<<"$line")
      run=$(jq -r '.run' <<<"$line")
      case "$run" in
        .github/scripts/*/*.sh)
          dir=${run#.github/scripts/}
          helper="$TEMPLATE_DIR/$dir"
          [ -x "$helper" ] || bad="${bad}    $tpl / $step: $run has no executable source at scripts/hooks/ci/$dir"$'\n'
          ;;
        *)
          # Two sanctioned inline steps: the pre-checkout resolver (tested
          # below straight from the template) and a one-line echo.
          case "$step" in
            "Resolve PR number and head ref"|"Skip if no new commits since last fragment update") ;;
            *) bad="${bad}    $tpl / $step: inline run: body (extract it into a tested helper)"$'\n' ;;
          esac
          ;;
      esac
    done < <(_yaml_runs "$TEMPLATE_DIR/$tpl")
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "doc-pr-release.yml + doc-release.yml run: steps all resolve to shipped helpers"
}

test_resolve_pr_inline_step() {
  echo "Test: doc-pr-release.yml 'Resolve PR number and head ref' (inline; runs before checkout)"
  yaml_unavailable "resolve_pr_inline_step" && return 0
  local dir body out rc shim
  dir=$(harness_mktemp_d resolve-pr)
  body="$dir/step.sh"
  _yaml_runs "$TEMPLATE_DIR/doc-pr-release.yml" \
    | jq -r 'select(.step == "Resolve PR number and head ref") | .run' > "$body"
  assert_contains "$(cat "$body")" 'echo "number=${number}" >> "$GITHUB_OUTPUT"' "inline body extracted from the template"
  out="$dir/gh-output"
  shim=$(gh_shim '{"headRefName": "feat/from-gh"}')
  # gh --jq is applied by the real gh; the shim answers with the bare value.
  printf '#!/usr/bin/env bash\necho feat/from-gh\n' > "$shim/gh"

  rc=0
  PR_FROM_EVENT=5 PR_FROM_INPUT= HEAD_REF_FROM_EVENT=feat/ev run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq "0" "$rc" "pull_request event → exits 0"
  assert_eq $'number=5\nhead_ref=feat/ev' "$(cat "$out")" "pull_request event → number + head ref from the event"

  rc=0
  PR_FROM_EVENT=5 PR_FROM_INPUT=9 HEAD_REF_FROM_EVENT=feat/ev run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq $'number=5\nhead_ref=feat/ev' "$(cat "$out")" "event number wins over a dispatch input"

  rc=0
  PATH="$shim:$PATH" GITHUB_REPOSITORY=o/r PR_FROM_EVENT= PR_FROM_INPUT=7 HEAD_REF_FROM_EVENT= \
    run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq "0" "$rc" "workflow_dispatch → exits 0"
  assert_eq $'number=7\nhead_ref=feat/from-gh' "$(cat "$out")" "workflow_dispatch → input number, head ref via gh"

  rc=0
  PR_FROM_EVENT= PR_FROM_INPUT= HEAD_REF_FROM_EVENT= run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq "1" "$rc" "no PR number → exits 1"
  assert_contains "$(cat "$out.log")" "Could not determine PR number" "no PR number → explains"

  printf '#!/usr/bin/env bash\necho\n' > "$shim/gh"
  rc=0
  PATH="$shim:$PATH" GITHUB_REPOSITORY=o/r PR_FROM_EVENT= PR_FROM_INPUT=7 HEAD_REF_FROM_EVENT= \
    run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq "1" "$rc" "gh resolves no head ref → exits 1"
  assert_contains "$(cat "$out.log")" "Could not resolve head ref for PR #7" "empty head ref → explains"
}

test_workflow_yaml_placeholders
test_workflow_structure_guards
test_workflow_helper_wiring
test_resolve_pr_inline_step

print_summary

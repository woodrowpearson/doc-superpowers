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
DOC_TOOLS_SCRIPT="$(bash_bin_shim "$REPO_ROOT/scripts/doc-tools.sh")"

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

# _payload_sha <file>: sha256 of the file's bytes from line 3 on (the line-2 hash).
_payload_sha() {
  tail -n +3 "$1" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
}

# sealed_fragment <file> <pr> <payload>: a fragment whose hash matches.
sealed_fragment() {
  local hash
  mkdir -p "$(dirname "$1")"
  hash=$(printf '%s' "$3" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')
  printf '<!-- doc-superpowers:fragment PR-%s -->\n<!-- doc-superpowers:hash %s -->\n%s' "$2" "$hash" "$3" > "$1"
}

# gh_shim_file <json-file>: a `gh pr view` shim answering with the file.
gh_shim_file() {
  local dir
  dir=$(harness_mktemp_d gh-file)
  printf '#!/bin/sh\n[ "$1" = pr ] && [ "$2" = view ] && exec cat "%s"\necho "mock gh: $*" >&2\nexit 1\n' "$1" > "$dir/gh"
  chmod +x "$dir/gh"
  printf '%s' "$dir"
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
  # work. A base commit merged in after the sync is not this PR's work: it
  # stays out of new_commits (I-9: extract-context excludes base-branch
  # commits).
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
  assert_eq "fix: add b" "$(subjects "$out" new_commits)" \
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

test_commit_superseded_by_a_human_push() {
  # A push to the branch during the run starts a newer run of this workflow
  # (the write group queues it); this run's fragment is stale. I-9: no rebase
  # — nothing is committed or pushed, and the step exits 0 (superseded), like
  # commit-changes.sh.
  echo "Test: someone pushed during the run → superseded: exit 0, nothing pushed (no rebase)"
  local dir rc=0 out tip
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  (
    cd "$dir/seed"
    echo human > human.txt
    git add human.txt
    git -c commit.gpgsign=false commit -q -m "human push"
    git push -q origin feature
  )
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  write_fragment_file "$dir/clone" 3 thing
  ( cd "$dir/clone" && GITHUB_OUTPUT="$out" GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 3 > "$out.log" 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "exits 0"
  assert_eq "$tip" "$(git -C "$dir/origin.git" rev-parse feature)" "origin keeps the human's tip; no sync commit pushed"
  assert_contains "$(cat "$out")" "superseded=true" "superseded=true in GITHUB_OUTPUT"
  assert_contains "$(cat "$out.log")" "superseded" "…and a notice says so"
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
  # A file already in the index when the helper runs stays out of the bot's
  # commit (I-9: commit-and-push commits only the fragment path).
  echo "Test: a pre-staged unrelated file is not swept into the sync commit"
  local dir rc=0
  dir=$(origin_and_clone)
  ( cd "$dir/clone" && echo staged > staged.txt && git add staged.txt )
  write_fragment_file "$dir/clone" 6 thing
  ( cd "$dir/clone" && GITHUB_HEAD_REF=feature "$COMMIT_SCRIPT" 6 >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "commit-and-push exits 0 with a pre-staged file"
  assert_eq "RELEASE-NOTES.next/PR-6.md" \
    "$(git -C "$dir/clone" show --name-only --format= HEAD | tr '\n' ' ' | sed 's/ $//')" \
    "the sync commit contains only the fragment even when the index holds other changes"
  assert_eq "A  staged.txt" "$(git -C "$dir/clone" status --porcelain -- staged.txt)" "…and the other file stays staged"
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
test_commit_superseded_by_a_human_push
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
  assert_eq $'new_commits_len=2\nrun=true' "$(cat "$out")" "new_commits_len (2 since the fragment sync, of 4) and run=true written to GITHUB_OUTPUT"
  assert_json_field "$(cat "$work/.doc-pr-release/context.json" 2>/dev/null)" '.pr_number' "21" \
    "context.json written under .doc-pr-release/"

  rc=0
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=0 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_true "extract-context failure fails the step (rc=$rc)" test "$rc" -ne 0
  assert_eq "" "$(cat "$out")" "no output written when extraction fails (so no later step runs)"

  # Nothing new since the last sync: run=false.
  commit_file "$work" RELEASE-NOTES.next/PR-21.md "$(printf '%s\n' '<!-- doc-superpowers:fragment PR-21 -->' \
    '<!-- doc-superpowers:hash deadbeef -->' '### Added' '- a, b, c')" "[doc-superpowers] sync PR-21 release notes"
  rc=0
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=21 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_eq $'0|new_commits_len=0\nrun=false' "$rc|$(cat "$out")" "no new commits: run=false"

  # I-9: a no-notes fragment a human wrote (not sealed) opts the PR out.
  commit_file "$work" d.txt d "feat: d"
  commit_file "$work" RELEASE-NOTES.next/PR-21.md "$(printf '%s\n' '<!-- doc-superpowers:fragment PR-21 -->' \
    '<!-- doc-superpowers:no-notes -->')" "docs: no release notes for this PR"
  commit_file "$work" e.txt e "feat: e"
  rc=0
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=21 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_eq "0|run=false" "$rc|$(sed -n 's/^\(run=.*\)/\1/p' "$out")" "a hand-written no-notes fragment: run=false (opted out)"
  assert_contains "$(cat "$out.log")" "no-notes" "…and the log says why"
  # The bot's own (sealed) no-notes fragment does not opt out: new work may need notes.
  sealed_fragment "$work/RELEASE-NOTES.next/PR-21.md" 21 $'<!-- doc-superpowers:no-notes -->\n'
  git -C "$work" add RELEASE-NOTES.next && git -C "$work" commit -q -m "[doc-superpowers] sync PR-21 release notes"
  commit_file "$work" f.txt f "feat: f"
  rc=0
  ( cd "$work" && PATH="$shim:$PATH" PR_NUMBER=21 BASE_REF=main run_step "$out" "$WRITE_CONTEXT_SCRIPT" ) || rc=$?
  assert_eq "0|run=true" "$rc|$(sed -n 's/^\(run=.*\)/\1/p' "$out")" "a sealed no-notes fragment + new work: run=true"
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

  rc=0
  ( cd "$work" && PR_NUMBER=31 SUPERSEDED=true run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "superseded (someone pushed during the run; nothing committed) → exits 0"

  sealed_fragment "$work/RELEASE-NOTES.next/PR-31.md" 31 $'### Added\n- thing\n'
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "existing fragment, no sync commit (agent no-op / human edit) → exits 0"

  ( cd "$work" && git add RELEASE-NOTES.next && git commit -q -m "[doc-superpowers] sync PR-31 release notes (abc1234)" )
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "0" "$rc" "sync commit with its sealed fragment → exits 0"

  # I-9: the sync commit's fragment must carry a matching hash.
  write_fragment_file "$work" 31 "wrong hash"
  ( cd "$work" && git add RELEASE-NOTES.next && git commit -q -m "[doc-superpowers] sync PR-31 release notes (bad0000)" )
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "sync commit whose fragment hash does not match → exits 1"

  ( cd "$work" && git rm -q RELEASE-NOTES.next/PR-31.md && git commit -q -m "[doc-superpowers] sync PR-31 release notes (def5678)" )
  rc=0
  ( cd "$work" && PR_NUMBER=31 run_step "$out" "$VERIFY_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "sync commit but fragment missing on disk → exits 1"
}

test_release_precheck() {
  echo "Test: precheck.sh (doc-release) — skip only when nothing is unreleased"
  local work out rc
  local DOC_TOOLS="$DOC_TOOLS_SCRIPT"
  export DOC_TOOLS
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

  # I-9: only a release tag (v[0-9]*) is the last release, not any tag.
  git -C "$work" tag deploy-marker
  rc=0
  ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=false" "$rc|$(cat "$out")" "a non-release tag at HEAD does not skip"
  assert_contains "$(cat "$out.log")" "2 commits since v1.0.0" "…the last release is still v1.0.0"

  # I-9: skip on the exact subject of the bot's own release-notes commit
  # (rebase-, squash- or merge-merged), and only on it.
  local subj
  for subj in "[doc-superpowers] draft release notes" "[doc-superpowers] draft release notes (#12)" \
      "Merge pull request #12 from octo/doc-superpowers/release-notes-9876"; do
    git -C "$work" commit -q --allow-empty -m "$subj"
    rc=0
    ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
    assert_eq "0|skip=true" "$rc|$(cat "$out")" "HEAD '$subj' → skip=true"
  done
  git -C "$work" commit -q --allow-empty -m "feat: squash of PR 5 (#5)" -m $'* feat: x\n* [doc-superpowers] sync PR-5 release notes (abc1234)'
  rc=0
  ( cd "$work" && run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=false" "$rc|$(cat "$out")" "a squash commit whose body lists the bot's sync commits → skip=false"
}

test_release_precheck_needs_the_last_release_merged() {
  # I-9: consumption is recorded by deleting fragments in the release commit;
  # a release whose commit never reached this branch would be re-consumed.
  echo "Test: precheck.sh (doc-release) — refuses while an earlier release's commit has not reached the branch"
  local work out rc
  work=$(new_repo)
  out="$work/gh-output"
  git -C "$work" tag v0.9.0
  sealed_fragment "$work/RELEASE-NOTES.next/PR-1.md" 1 $'### Added\n- one\n'
  git -C "$work" add -A && git -C "$work" commit -q -m "PR-1"
  git -C "$work" checkout -q -b release/1.0
  git -C "$work" rm -q RELEASE-NOTES.next/PR-1.md
  git -C "$work" commit -q -m "release: v1.0.0"
  git -C "$work" tag v1.0.0
  git -C "$work" checkout -q main
  commit_file "$work" a.txt a "feat: a"
  rc=0
  ( cd "$work" && DOC_TOOLS="$DOC_TOOLS_SCRIPT" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "the v1.0.0 release commit is not on this branch: exits 1"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  assert_contains "$(cat "$out.log")" "v1.0.0" "…naming the release"
  git -C "$work" merge -q --no-ff --no-edit -m "Merge release/1.0" release/1.0
  commit_file "$work" b.txt b "feat: b"
  rc=0
  ( cd "$work" && DOC_TOOLS="$DOC_TOOLS_SCRIPT" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=false" "$rc|$(cat "$out")" "once the release branch is merged: exits 0"
  # Fix round 1: only the refusal (exit 3) is diagnosed as an unmerged
  # release; any other failure of the tool is reported as a failure.
  local stub
  stub=$(harness_mktemp_d stub)
  printf '#!/bin/sh\necho "stub: some other failure" >&2\nexit 1\n' > "$stub/dt1"
  printf '#!/bin/sh\necho "stub: refused" >&2\nexit 3\n' > "$stub/dt3"
  chmod +x "$stub/dt1" "$stub/dt3"
  rc=0
  ( cd "$work" && DOC_TOOLS="$stub/dt1" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "fragments merge fails (exit 1): exits 1 …"
  assert_contains "$(cat "$out.log")" "fragments merge failed (exit 1" "…reporting the failure"
  assert_not_contains "$(cat "$out.log")" "earlier release" "…not as an unmerged release"
  rc=0
  ( cd "$work" && DOC_TOOLS="$stub/dt3" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "1" "$rc" "fragments merge refuses (exit 3): exits 1 …"
  assert_contains "$(cat "$out.log")" "an earlier release has not reached this branch" "…naming the cause"
}

test_sentinel_check
test_write_context
test_resolve_auth
test_verify_fragment
test_release_precheck
test_release_precheck_needs_the_last_release_merged

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
  # The job-level guard stops the bot's own release-notes commit from
  # re-running the release job — by its exact subject: a `contains` over the
  # whole message also skipped a release branch cut at a squash commit that
  # merely lists the bot's sync commits (I-9).
  local rif
  rif=$(_yaml_get "$TEMPLATE_DIR/doc-release.yml" jobs.release-notes.if)
  assert_contains "$rif" "!startsWith(github.event.head_commit.message, '[doc-superpowers] draft release notes')" \
    "doc-release.yml: release-notes job skips the bot's own release-notes commit"
  assert_not_contains "$rif" "contains(" "doc-release.yml: …and only that commit (no substring match)"
}

test_workflow_helper_wiring() {
  echo "Test: every run: step of every template is one shipped helper call (no untested inline body)"
  yaml_unavailable "workflow_helper_wiring" && return 0
  local tpl name line step run cmd dir bad=""
  for tpl in "$TEMPLATE_DIR"/doc-*.yml; do
    name=$(basename "$tpl")
    while IFS= read -r line; do
      step=$(jq -r '.step' <<<"$line")
      run=$(jq -r '.run' <<<"$line")
      cmd=${run%%[[:space:]]*}
      # prepare-agent.sh's pre-agent snapshot of a step script runs as
      # "$RUNNER_TEMP"/doc-superpowers-steps/<name>.sh.
      case "$cmd" in
        '"$RUNNER_TEMP"/doc-superpowers-steps/'*.sh) cmd=".github/scripts/${cmd#'"$RUNNER_TEMP"/'}" ;;
      esac
      case "$cmd" in
        .github/scripts/*/*.sh)
          dir=${cmd#.github/scripts/}
          [ -x "$TEMPLATE_DIR/$dir" ] || bad="${bad}    $name / $step: $cmd has no executable source at scripts/hooks/ci/$dir"$'\n'
          case "$run" in
            *$'\n'?* | *'&&'* | *';'* | *'|'*) bad="${bad}    $name / $step: more than one command around the helper call"$'\n' ;;
          esac
          ;;
        *)
          # One sanctioned inline step: the pre-checkout resolver (tested
          # below straight from the template).
          case "$name / $step" in
            "doc-pr-release.yml / Resolve PR number and head ref") ;;
            *) bad="${bad}    $name / $step: inline run: body (extract it into a tested helper)"$'\n' ;;
          esac
          ;;
      esac
    done < <(_yaml_runs "$tpl")
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "every template's run: steps resolve to shipped helpers"
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
  # gh --jq is applied by the real gh; the shim answers with its result:
  # "<isCrossRepository> <headRefName>".
  printf '#!/usr/bin/env bash\necho "false feat/from-gh"\n' > "$shim/gh"

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

  # FW S-M3: a fork's PR number (workflow_dispatch): its branch name would
  # check out and push to this repository's unrelated same-named branch.
  printf '#!/usr/bin/env bash\necho "true main"\n' > "$shim/gh"
  rc=0
  PATH="$shim:$PATH" GITHUB_REPOSITORY=o/r PR_FROM_EVENT= PR_FROM_INPUT=8 HEAD_REF_FROM_EVENT= \
    run_step "$out" "$BASH_BIN" -e "$body" || rc=$?
  assert_eq "1" "$rc" "workflow_dispatch with a fork's PR → exits 1"
  assert_contains "$(cat "$out.log")" "comes from a fork" "…saying why"
  assert_not_contains "$(cat "$out")" "head_ref=" "…and resolves no head ref"
  assert_contains "$(cat "$body")" "isCrossRepository" "the step asks gh whether the PR is cross-repository"
}

test_workflow_yaml_placeholders
test_workflow_structure_guards
test_workflow_helper_wiring
test_resolve_pr_inline_step

# ============================================================================
# CI templates as the installer renders them (I-8)
# ============================================================================
echo
echo "=== CI templates as installed (I-8) ==="

INSTALLER="$REPO_ROOT/scripts/hooks/install.sh"
# A PATH whose `bash` is $BASH_BIN: the installed helpers and the vendored
# doc-tools.sh start `bash` by name (#!/usr/bin/env bash).
_BASH_PATH_DIR=$(harness_mktemp_d bashpath)
ln -s "$(type -P "$BASH_BIN" || printf '%s' "$BASH_BIN")" "$_BASH_PATH_DIR/bash"
BASH_PATH="$_BASH_PATH_DIR:$PATH"

# installed_repo <install args…>: new_repo with the installer run in it;
# echoes its path. Returns 1 (the installer's output on stderr) on failure.
installed_repo() {
  local dir log rc=0
  dir=$(new_repo)
  log=$(harness_mktemp install-log)
  ( cd "$dir" && PATH="$BASH_PATH" "$BASH_BIN" "$INSTALLER" install "$@" ) > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    { echo "  installed_repo: install $* exited $rc:"; sed 's/^/    /' "$log"; } >&2
    return 1
  fi
  printf '%s' "$dir"
}

# _yaml_json <file> — the whole document as JSON. YAML 1.1 reads the `on:`
# key as `true`, so triggers are (.on // .true).
_yaml_json() {
  case "$YAML_PARSER" in
    python3) HOME="$_HARNESS_REAL_HOME" python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1" ;;
    ruby) ruby -ryaml -rjson -e 'puts YAML.load_file(ARGV[0]).to_json' "$1" ;;
  esac
}

AI_WORKFLOWS="doc-audit-update doc-review-pr doc-release doc-spec-verify doc-pr-full-cycle doc-pr-release"
AI_USES="anthropics/claude-code-action@"
ALL_REPO=$(installed_repo --all --workflows=all) || ALL_REPO=""

# _need_all_repo <label>: a FAIL, and 1, when the install --all fixture failed.
_need_all_repo() {
  [ -n "$ALL_REPO" ] && return 0
  assert_true "$1: install --all --workflows=all succeeded" false
  return 1
}

# The claude-code-action steps of <workflow file>, one JSON object per line:
# {wf, job, step, if, with}.
_ai_steps() {
  _yaml_json "$1" | jq -c --arg wf "$(basename "$1" .yml)" --arg u "$AI_USES" '
    .jobs | to_entries[] | .key as $job | .value.steps[]?
    | select((.uses // "") | startswith($u))
    | {wf: $wf, job: $job, step: (.name // ""), if: (.if // ""), with: (.with // {})}'
}

# jq: the entries of claude_args' --allowedTools "<csv>" ([] when absent).
# shellcheck disable=SC2016  # jq program
_JQ_TOOLS='def tools: (.with.claude_args // "") | [capture("--allowedTools[ =]\"(?<t>[^\"]*)\"").t] | (.[0] // "")
  | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));'

test_i8_writers_check_out_the_branch() {
  echo "Test: every template that commits to a branch checks out the branch (a queued run starts from its tip), not the event commit"
  yaml_unavailable "i8_writers_check_out_the_branch" && return 0
  _need_all_repo "i8_writers_check_out_the_branch" || return 0
  local wf ref
  for wf in doc-audit-update doc-pr-full-cycle doc-pr-release; do
    ref=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml" | jq -r \
      '[.jobs[].steps[]? | select((.uses // "") | startswith("actions/checkout@")) | .with.ref // ""] | first // ""')
    case "$ref" in
      *github.ref_name* | *github.head_ref* | *steps.pr.outputs.head_ref*)
        assert_true "$wf: checkout ref is the branch ($ref)" true ;;
      *) assert_true "$wf: checkout ref is the branch (got '$ref')" false ;;
    esac
  done
}

test_i8_installed_no_placeholder() {
  echo "Test: install --all --workflows=all — no __PLACEHOLDER__ survives in a workflow or a shipped helper"
  _need_all_repo "i8_installed_no_placeholder" || return 0
  local hits
  hits=$(grep -rlE '__[A-Z][A-Z0-9_]*__' "$ALL_REPO/.github/workflows" "$ALL_REPO/.github/scripts/doc-superpowers-steps" \
    "$ALL_REPO/.github/scripts/doc-pr-release" 2>/dev/null || true)
  assert_eq "" "$hits" "no placeholder in the installed workflows or helpers"
}

test_i8_ai_steps_runnable_and_scoped() {
  echo "Test: every installed AI step passes github_token, the pinned plugin, a scoped --allowedTools and --max-turns (GH #5)"
  yaml_unavailable "i8_ai_steps_runnable_and_scoped" && return 0
  _need_all_repo "i8_ai_steps_runnable_and_scoped" || return 0
  local wf line out bad="" n=0
  for wf in $AI_WORKFLOWS; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      # shellcheck disable=SC2016  # jq program
      out=$(jq -r "$_JQ_TOOLS"'
        "\(.wf) / \(.job) / \(.step)" as $id
        | ( (if .with.github_token != "${{ github.token }}" then "github_token is not ${{ github.token }}" else empty end),
            (if ((.with.plugins // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | any(. == "doc-superpowers@doc-superpowers")) | not
             then "plugins does not install doc-superpowers@doc-superpowers" else empty end),
            (if ((.with.plugin_marketplaces // "") | test("^\\$\\{\\{ *steps\\.[A-Za-z0-9_-]+\\.outputs\\.marketplace *\\}\\}$")) | not
             then "plugin_marketplaces is not the pinned checkout (steps.<id>.outputs.marketplace)" else empty end),
            (if ((.with.claude_args // "") | test("--max-turns[ =][0-9]+")) | not then "claude_args has no --max-turns" else empty end),
            (if (tools | length) == 0 then "claude_args has no --allowedTools \"…\" list" else empty end),
            (tools[] | select(. == "Bash" or . == "*" or test("^Bash\\((\\*|:\\*)?\\)$") or test("git (commit|push)") or test("commit-and-push"))
             | "unscoped or committing tool: \(.)")
          ) | "    \($id): \(.)"' <<<"$line")
      [ -z "$out" ] || bad="$bad$out"$'\n'
    done < <(_ai_steps "$ALL_REPO/.github/workflows/$wf.yml")
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "AI steps can run (token, pinned plugin) and are least-privilege (scoped tools, turn cap)"
  assert_eq "7" "$n" "7 AI steps checked (6 templates; doc-review-pr has a PR job and a comment job)"
  assert_eq "" "$(grep -l 'id-token' "$ALL_REPO"/.github/workflows/*.yml || true)" "no workflow asks for id-token (GH #5 is fixed with github_token)"
  assert_eq "" "$(grep -L 'DOC_SUPERPOWERS_VERSION: "v' $(for wf in $AI_WORKFLOWS; do printf '%s ' "$ALL_REPO/.github/workflows/$wf.yml"; done) || true)" \
    "every AI workflow carries the installed version its plugin step pins"
}

test_i8_every_job_has_a_timeout() {
  echo "Test: every job of every installed workflow has timeout-minutes"
  yaml_unavailable "i8_every_job_has_a_timeout" && return 0
  _need_all_repo "i8_every_job_has_a_timeout" || return 0
  local f out bad="" n=0
  for f in "$ALL_REPO"/.github/workflows/doc-*.yml; do
    n=$((n + 1))
    out=$(_yaml_json "$f" | jq -r --arg wf "$(basename "$f")" \
      '.jobs | to_entries[] | select((.value["timeout-minutes"] | type) != "number") | "    \($wf) / \(.key)"')
    [ -z "$out" ] || bad="$bad$out"$'\n'
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "no job without timeout-minutes"
  assert_eq "8" "$n" "8 installed workflows checked"
}

test_i8_pins_carry_exact_versions() {
  echo "Test: every uses: is a SHA pin with its exact version comment"
  _need_all_repo "i8_pins_carry_exact_versions" || return 0
  local f l bad=""
  for f in "$ALL_REPO"/.github/workflows/doc-*.yml; do
    while IFS= read -r l; do
      case "$l" in
        *"uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1") ;;
        *"uses: actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b # v7.1.0") ;;
        *"uses: anthropics/claude-code-action@1eddb334cfa79fdb21ecbe2180ca1a016e8e7d47 # v1.0.88") ;;
        *) bad="${bad}    $(basename "$f"):$l"$'\n' ;;
      esac
    done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$f")
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "checkout # v4.3.1, github-script # v7.1.0, claude-code-action # v1.0.88"
}

test_i8_freshness_workflows_read_the_report_file() {
  echo "Test: the freshness workflows pass only scalars through step outputs; github-script reads the report from a file"
  yaml_unavailable "i8_freshness_workflows_read_the_report_file" && return 0
  _need_all_repo "i8_freshness_workflows_read_the_report_file" || return 0
  local wf json envs scripts runs
  for wf in doc-freshness-pr doc-freshness-schedule; do
    json=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml")
    envs=$(jq -r '[.jobs[].steps[] | (.env // {}) | to_entries[] | .value | tostring] | join("\n")' <<<"$json")
    assert_not_contains "$envs" "outputs.result" "$wf: no step reads an index-sized outputs.result"
    assert_not_contains "$envs" "outputs.files" "$wf: no step reads a PR-sized outputs.files"
    scripts=$(jq -r '[.jobs[].steps[] | select((.uses // "") | startswith("actions/github-script@")) | .with.script] | join("\n")' <<<"$json")
    assert_contains "$scripts" "fs.readFileSync(process.env.REPORT" "$wf: github-script reads the report file"
    assert_contains "$scripts" "github.paginate(" "$wf: github-script reads every page"
    assert_contains "$scripts" "github-actions[bot]" "$wf: github-script only touches the bot's own comment/issue"
    runs=$(jq -r '[.jobs[].steps[] | .run // empty] | join("\n")' <<<"$json")
    assert_contains "$runs" ".github/scripts/doc-superpowers-steps/freshness-check.sh" "$wf: the check is the tested helper"
    assert_not_contains "$runs" "GITHUB_OUTPUT" "$wf: no inline body writes step outputs"
  done
  json=$(_yaml_json "$ALL_REPO/.github/workflows/doc-freshness-pr.yml")
  local cif
  cif=$(jq -r '.jobs[].steps[] | select((.uses // "") | startswith("actions/github-script@")) | .if' <<<"$json")
  assert_contains "$cif" "!cancelled()" "doc-freshness-pr: the comment is upserted even when STRICT failed the check step"
  assert_contains "$cif" "github.event.pull_request.head.repo.full_name == github.repository" \
    "doc-freshness-pr: no comment attempt on a fork PR (read-only token)"
  assert_contains "$(jq -r '[.jobs[].steps[] | .with.script // empty] | join("\n")' <<<"$json")" "doc-superpowers:freshness-report" \
    "doc-freshness-pr: the comment is found by its hidden marker"
}

test_i8_schedule_closes_only_after_a_good_check() {
  echo "Test: doc-freshness-schedule creates/closes the issue only after a successful check"
  yaml_unavailable "i8_schedule_closes_only_after_a_good_check" && return 0
  _need_all_repo "i8_schedule_closes_only_after_a_good_check" || return 0
  local json close_if create_if
  json=$(_yaml_json "$ALL_REPO/.github/workflows/doc-freshness-schedule.yml")
  close_if=$(jq -r '.jobs[].steps[] | select(.name == "Close issue if all clear") | .if' <<<"$json")
  create_if=$(jq -r '.jobs[].steps[] | select(.name == "Create or update issue") | .if' <<<"$json")
  assert_contains "$close_if" "steps.freshness.outputs.status == 'ok'" "close: gated on a successful check"
  assert_contains "$close_if" "steps.freshness.outputs.count == '0'" "close: …and nothing stale or missing"
  assert_contains "$create_if" "steps.freshness.outputs.status == 'ok'" "create/update: gated on a successful check"
}

test_i8_review_pr_split() {
  echo "Test: doc-review-pr — a fixed-prompt pull_request job and a tag-mode job for @claude PR comments"
  yaml_unavailable "i8_review_pr_split" && return 0
  _need_all_repo "i8_review_pr_split" || return 0
  local json
  json=$(_yaml_json "$ALL_REPO/.github/workflows/doc-review-pr.yml")
  assert_eq "1" "$(jq --arg c "github.event_name == 'pull_request'" --arg u "$AI_USES" \
    '[.jobs[] | select((.if // "") | contains($c)) | .steps[]? | select((.uses // "") | startswith($u)) | select((.with.prompt // "") != "")] | length' <<<"$json")" \
    "one job, gated on pull_request events, runs a fixed prompt"
  assert_eq "1" "$(jq --arg at "'@claude'" --arg u "$AI_USES" \
    '[.jobs[] | select((.if // "") | contains("github.event.issue.pull_request") and contains($at))
      | .steps[]? | select((.uses // "") | startswith($u)) | select(.with | has("prompt") | not)] | length' <<<"$json")" \
    "one job, gated on a PR comment mentioning @claude, runs tag mode (no prompt:)"
  assert_eq "true" "$(jq '(.on // .true) | has("issue_comment")' <<<"$json")" "issue_comment still triggers it"
}

test_i8_same_repo_guard() {
  echo "Test: every PR-triggered AI job runs only for same-repository PRs"
  yaml_unavailable "i8_same_repo_guard" && return 0
  _need_all_repo "i8_same_repo_guard" || return 0
  local wf out bad=""
  for wf in doc-review-pr doc-spec-verify doc-pr-full-cycle doc-pr-release; do
    out=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml" | jq -r --arg wf "$wf" --arg u "$AI_USES" \
      --arg g "github.event.pull_request.head.repo.full_name == github.repository" --arg sr "same_repo == 'true'" '
      .jobs | to_entries[] | .key as $job | .value as $j
      | select([$j.steps[]? | (.uses // "") | startswith($u)] | any)
      | if (($j.if // "") | contains("github.event.issue.pull_request")) then
          if ([$j.steps[] | (.run // "") | startswith(".github/scripts/doc-superpowers-steps/pr-guard.sh")] | any)
             and ([$j.steps[] | select((.uses // "") | startswith($u)) | (.if // "") | contains($sr)] | all)
          then empty else "    \($wf) / \($job): comment job without the pr-guard.sh same-repository check" end
        elif (($j.if // "") | contains($g)) then empty
        else "    \($wf) / \($job): no same-repository guard in the job if:" end')
    [ -z "$out" ] || bad="$bad$out"$'\n'
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "fork PRs never reach an AI step (no secrets, no push)"
}

test_i8_one_write_group_per_branch() {
  echo "Test: the templates that commit to a branch share one non-cancelling concurrency group per branch"
  yaml_unavailable "i8_one_write_group_per_branch" && return 0
  _need_all_repo "i8_one_write_group_per_branch" || return 0
  local wf json g groups=""
  for wf in doc-audit-update doc-pr-full-cycle doc-pr-release; do
    json=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml")
    g=$(jq -r '.concurrency.group // ""' <<<"$json")
    assert_eq "false" "$(jq -r '.concurrency["cancel-in-progress"] | tostring' <<<"$json")" "$wf: cancel-in-progress false"
    assert_contains "$g" "doc-superpowers-write-" "$wf: the shared write group ($g)"
    assert_eq "max" "$(jq -r '.concurrency.queue // ""' <<<"$json")" \
      "$wf: queue: max (pending runs of the three wait in order instead of cancelling each other)"
    assert_true "$wf: a comment tells GHES users without concurrency queue support to drop the key" \
      grep -qE '^[[:space:]]*#.*(GHES|GitHub Enterprise Server).*queue' "$ALL_REPO/.github/workflows/$wf.yml"
    groups="$groups$g"$'\n'
  done
  assert_eq "1" "$(printf '%s' "$groups" | sort -u | grep -c .)" "one group expression for all three"
}

test_i8_no_code_path_filters() {
  echo "Test: no AI template hard-codes code paths; the doc-scoped ones gate in the job on check-freshness --code-refs-from"
  yaml_unavailable "i8_no_code_path_filters" && return 0
  _need_all_repo "i8_no_code_path_filters" || return 0
  local wf json out bad=""
  for wf in $AI_WORKFLOWS; do
    json=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml")
    assert_eq "[]" "$(jq -c '[(.on // .true) | .. | objects | select(has("paths")) | .paths] | add // []' <<<"$json")" "$wf: no paths: trigger filter"
    assert_eq "[]" "$(jq -c '[(.on // .true) | .. | objects | select(has("paths-ignore")) | .["paths-ignore"][]] | map(select(startswith("RELEASE-NOTES") | not))' <<<"$json")" \
      "$wf: paths-ignore names only the release-notes files"
  done
  for wf in doc-audit-update doc-review-pr doc-spec-verify doc-pr-full-cycle; do
    out=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml" | jq -r --arg wf "$wf" --arg u "$AI_USES" '
      .jobs | to_entries[]
      | select((.value.if // "") | contains("github.event.issue.pull_request") | not)
      | .key as $job | .value.steps as $s
      | ([$s | to_entries[] | select((.value.uses // "") | startswith($u)) | .key] | first) as $ai
      | select($ai != null)
      | ([$s | to_entries[] | select((.value.run // "") | startswith(".github/scripts/doc-superpowers-steps/freshness-check.sh scope")) | .key] | first) as $sc
      | if $sc == null or $sc > $ai then "    \($wf) / \($job): no freshness-check.sh scope step before the AI step"
        elif (($s[$ai].if // "") | contains("steps.\($s[$sc].id).outputs.")) | not then "    \($wf) / \($job): the AI step is not gated on the scope step"
        else empty end')
    [ -z "$out" ] || bad="$bad$out"$'\n'
  done
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "the doc-scoped AI jobs run only when the change touches an indexed doc or its code"
}

# How a template runs prepare-agent.sh's pre-agent snapshot of the checker
# (the agent can edit the checkout's copy; it runs before the commit step).
CHECKER_RUN='"$RUNNER_TEMP"/doc-superpowers-steps/commit-changes.sh'

test_i8_commit_is_a_deterministic_step() {
  echo "Test: the writing templates commit in a deterministic step after the agent that asserts the diff paths"
  yaml_unavailable "i8_commit_is_a_deterministic_step" && return 0
  _need_all_repo "i8_commit_is_a_deterministic_step" || return 0
  local wf out bad=""
  for wf in doc-audit-update doc-pr-full-cycle doc-release; do
    out=$(_yaml_json "$ALL_REPO/.github/workflows/$wf.yml" | jq -r --arg wf "$wf" --arg u "$AI_USES" --arg cc "$CHECKER_RUN" '
      .jobs | to_entries[] | .key as $job | .value.steps as $s
      | ([$s | to_entries[] | select((.value.uses // "") | startswith($u)) | .key] | first) as $ai
      | select($ai != null)
      | ([$s | to_entries[] | select((.value.run // "") | startswith(".github/scripts/doc-superpowers-steps/prepare-agent.sh")) | .key] | first) as $prep
      | ([$s | to_entries[] | select(.key > $ai) | .value.run // ""
          | select(startswith($cc + " ")) | select(contains("--check-only") | not)] | length) as $n
      | if $n != 1 then "    \($wf) / \($job): \($n) snapshot commit-changes.sh step(s) after the AI step (want 1)"
        elif $prep == null or $prep > $ai then "    \($wf) / \($job): no prepare-agent.sh (the checker snapshot) before the AI step"
        else empty end')
    [ -z "$out" ] || bad="$bad$out"$'\n'
  done
  out=$(_yaml_json "$ALL_REPO/.github/workflows/doc-pr-release.yml" | jq -r --arg u "$AI_USES" --arg cc "$CHECKER_RUN" '
    .jobs | to_entries[] | .key as $job | .value.steps as $s
    | ([$s | to_entries[] | select((.value.uses // "") | startswith($u)) | .key] | first) as $ai
    | select($ai != null)
    | ([$s | to_entries[] | select((.value.run // "") | startswith($cc + " --check-only")) | .key] | first) as $chk
    | ([$s | to_entries[] | select((.value.run // "") | startswith(".github/scripts/doc-pr-release/commit-and-push.sh")) | .key] | first) as $cp
    | ([$s | to_entries[] | select((.value.run // "") | startswith(".github/scripts/doc-superpowers-steps/prepare-agent.sh")) | .key] | first) as $prep
    | if $chk == null or $cp == null or $chk < $ai or $cp < $chk then "    doc-pr-release / \($job): want the AI step, then the snapshot commit-changes.sh --check-only, then commit-and-push.sh"
      elif $prep == null or $prep > $chk then "    doc-pr-release / \($job): prepare-agent.sh (the checker snapshot) does not run before the --check-only step"
      elif (($s[$ai].with.prompt // "") | contains("commit-and-push.sh")) then "    doc-pr-release / \($job): the prompt still has the agent run commit-and-push.sh"
      elif ($s[$cp].env // {}) as $e | ($e.GIT_CONFIG_COUNT != "2" or $e.GIT_CONFIG_KEY_0 != "core.hooksPath" or $e.GIT_CONFIG_VALUE_0 != "/dev/null"
            or $e.GIT_CONFIG_KEY_1 != "core.fsmonitor" or $e.GIT_CONFIG_VALUE_1 != "false")
        then "    doc-pr-release / \($job): commit-and-push.sh runs git with the hooks and fsmonitor the agent could have planted"
      else empty end')
  [ -z "$out" ] || bad="$bad$out"$'\n'
  [ -z "$bad" ] || printf '%s' "$bad"
  assert_eq "" "$bad" "no agent commits or pushes; a checked step does"
}

test_i8_installed_no_placeholder
test_i8_writers_check_out_the_branch
test_i8_ai_steps_runnable_and_scoped
test_i8_every_job_has_a_timeout
test_i8_pins_carry_exact_versions
test_i8_freshness_workflows_read_the_report_file
test_i8_schedule_closes_only_after_a_good_check
test_i8_review_pr_split
test_i8_same_repo_guard
test_i8_one_write_group_per_branch
test_i8_no_code_path_filters
test_i8_commit_is_a_deterministic_step

# ============================================================================
# I-8 step helpers, run as a workflow step runs them
# ============================================================================
echo
echo "=== I-8 step helpers ==="

# run_installed <repo> <out> [VAR=value…] -- <script> [args…]: run <script>
# the way a workflow step does: cwd the checkout, `bash` on PATH is
# $BASH_BIN, a fresh $GITHUB_OUTPUT (<out>) and $RUNNER_TEMP (<out>.tmp);
# stdout+stderr land in <out>.log. Returns the step's exit code.
run_installed() {
  local repo="$1" out="$2" envs=() rc=0
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  : > "$out"
  rm -rf "$out.tmp"
  mkdir -p "$out.tmp"
  ( cd "$repo" && env PATH="$BASH_PATH" GITHUB_OUTPUT="$out" RUNNER_TEMP="$out.tmp" ${envs[@]+"${envs[@]}"} "$BASH_BIN" "$@" ) \
    > "$out.log" 2>&1 || rc=$?
  return "$rc"
}

# _out <GITHUB_OUTPUT file> <key>: the last value written for <key>.
_out() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

FRESHNESS=.github/scripts/doc-superpowers-steps/freshness-check.sh

# freshness_repo: the CI tier installed; docs/a.md cites src/, docs/b.md
# cites lib/, both verified at the base commit; the head commit changes
# src/a.js and deletes docs/b.md (its index entry left behind). Echoes the
# path; the two SHAs are in .git/fx-base and .git/fx-head.
freshness_repo() {
  local dir
  dir=$(installed_repo --ci) || return 1
  (
    cd "$dir" || exit 1
    mkdir -p docs src lib
    echo a > src/a.js
    echo b > lib/b.js
    echo '# A' > docs/a.md
    echo '# B' > docs/b.md
    git add -A && git commit -q -m "base files"
    printf 'docs/a.md:src/:arch\ndocs/b.md:lib/:arch\n' | PATH="$BASH_PATH" .github/scripts/doc-tools.sh build-index >/dev/null 2>&1
    PATH="$BASH_PATH" .github/scripts/doc-tools.sh update-index docs/a.md docs/b.md >/dev/null 2>&1
    git add -A && git commit -q -m "base"
    git rev-parse HEAD > .git/fx-base
    echo a2 > src/a.js
    git rm -q docs/b.md
    git commit -q -a -m "head"
    git rev-parse HEAD > .git/fx-head
  ) || return 1
  printf '%s' "$dir"
}

test_i8_freshness_gate() {
  echo "Test: freshness-check.sh gate — stale AND missing counted for the PR's changes; a tool failure is never '0 stale'"
  local repo out rng rc report
  repo=$(freshness_repo) || { assert_true "freshness fixture" false; return 0; }
  out="$(harness_mktemp_d step)/out"
  rng="$(cat "$repo/.git/fx-base")...$(cat "$repo/.git/fx-head")"

  rc=0
  run_installed "$repo" "$out" RANGE="$rng" DOC_SUPERPOWERS_STRICT=0 -- "$FRESHNESS" gate || rc=$?
  assert_eq "0" "$rc" "not STRICT: exits 0"
  assert_eq "ok|1|1|2" "$(_out "$out" status)|$(_out "$out" stale)|$(_out "$out" missing)|$(_out "$out" count)" \
    "status ok; the stale doc (its code changed) and the missing one (deleted by the change) both count"
  report=$(_out "$out" report)
  assert_eq "docs/a.md=stale docs/b.md=missing" \
    "$(jq -r '[.docs | to_entries[] | "\(.key)=\(.value.status)"] | join(" ")' "$report" 2>/dev/null)" \
    "the report file holds exactly the stale and missing docs"
  assert_eq "$out.tmp/freshness.json" "$(ls "$out.tmp/freshness.json" 2>/dev/null)" "the raw result is \$RUNNER_TEMP/freshness.json"
  assert_eq "" "$(grep -vE '^[a-z_]+=[^[:space:]]*$' "$out" || true)" "every step output is one key=value line (no heredoc, nothing index-sized)"

  rc=0
  run_installed "$repo" "$out" RANGE="$rng" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "1" "$rc" "STRICT: 2 docs out of date fail the step"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error:: annotation"
  assert_eq "ok|2" "$(_out "$out" status)|$(_out "$out" count)" "…after writing the outputs (the PR comment still runs)"

  rc=0
  run_installed "$repo" "$out" RANGE="$(cat "$repo/.git/fx-base")...$(cat "$repo/.git/fx-base")" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "0|ok|0" "$rc|$(_out "$out" status)|$(_out "$out" count)" "STRICT, a change that touches no indexed doc or code: passes with count 0"

  echo '{broken' > "$repo/docs/.doc-index.json"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" DOC_SUPERPOWERS_STRICT=0 -- "$FRESHNESS" gate || rc=$?
  assert_eq "0" "$rc" "tool failure, not STRICT: exits 0 …"
  assert_contains "$(cat "$out.log")" "::warning::" "…with a ::warning::"
  assert_eq "failed|" "$(_out "$out" status)|$(_out "$out" count)" "…status failed and NO count (never '0 stale')"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "1" "$rc" "tool failure, STRICT: exits 1 …"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  assert_eq "failed|" "$(_out "$out" status)|$(_out "$out" count)" "…status failed, no count"
  git -C "$repo" checkout -q -- docs/.doc-index.json

  mv "$repo/.github/scripts/doc-tools.sh" "$repo/.github/scripts/doc-tools.sh.off"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "1|failed" "$rc|$(_out "$out" status)" "STRICT, the vendored doc-tools.sh missing: a failure, not a pass"
  mv "$repo/.github/scripts/doc-tools.sh.off" "$repo/.github/scripts/doc-tools.sh"

  ( cd "$repo" && git rm -q docs/.doc-index.json && git commit -q -m "drop the index" )
  rc=0
  run_installed "$repo" "$out" RANGE="$(cat "$repo/.git/fx-base")...$(git -C "$repo" rev-parse HEAD)" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "1|failed" "$rc|$(_out "$out" status)" "STRICT, a change that deletes the index: a failure, not 'no index'"

  local bare
  bare=$(installed_repo --ci) || { assert_true "bare fixture" false; return 0; }
  rc=0
  run_installed "$bare" "$out" DOC_SUPERPOWERS_STRICT=1 -- "$FRESHNESS" gate || rc=$?
  assert_eq "0|no-index" "$rc|$(_out "$out" status)" "a repository that never ran init: status no-index, exits 0"
}

test_i8_freshness_output_is_bounded() {
  echo "Test: freshness-check.sh — the step outputs stay a few scalars however large the report (the E2BIG fix)"
  local repo out rc i map
  repo=$(installed_repo --ci) || { assert_true "fixture" false; return 0; }
  (
    cd "$repo" || exit 1
    mkdir -p docs src
    echo a > src/a.js
    map=""
    i=1
    while [ "$i" -le 60 ]; do
      printf '# Doc %s\n' "$i" > "docs/doc-with-a-long-descriptive-name-$i.md"
      map="${map}docs/doc-with-a-long-descriptive-name-$i.md:src/:architecture"$'\n'
      i=$((i + 1))
    done
    git add -A && git commit -q -m base
    printf '%s' "$map" | PATH="$BASH_PATH" .github/scripts/doc-tools.sh build-index >/dev/null 2>&1
    # shellcheck disable=SC2046  # the doc list
    PATH="$BASH_PATH" .github/scripts/doc-tools.sh update-index $(cd docs && ls doc-*.md | sed 's|^|docs/|') >/dev/null 2>&1
    git add -A && git commit -q -m index
    git rev-parse HEAD > .git/fx-base
    echo a2 > src/a.js
    git commit -q -a -m change
  ) || { assert_true "fixture" false; return 0; }
  out="$(harness_mktemp_d step)/out"
  rc=0
  run_installed "$repo" "$out" RANGE="$(cat "$repo/.git/fx-base")...HEAD" DOC_SUPERPOWERS_STRICT=0 -- "$FRESHNESS" gate || rc=$?
  assert_eq "0|60" "$rc|$(_out "$out" stale)" "60 stale docs found"
  assert_true "the report file is large ($(wc -c < "$(_out "$out" report)" 2>/dev/null) bytes)" \
    test "$(wc -c < "$(_out "$out" report)" 2>/dev/null || echo 0)" -gt 6000
  assert_true "\$GITHUB_OUTPUT stays small ($(wc -c < "$out") bytes, ≤ 400)" test "$(wc -c < "$out")" -le 400
}

test_i8_freshness_audit() {
  echo "Test: freshness-check.sh audit — the whole index; a tool failure always fails the run (the issue is never closed on it)"
  local repo out rc
  repo=$(freshness_repo) || { assert_true "freshness fixture" false; return 0; }
  out="$(harness_mktemp_d step)/out"
  rc=0
  run_installed "$repo" "$out" -- "$FRESHNESS" audit || rc=$?
  assert_eq "0|ok|1|1|2" "$rc|$(_out "$out" status)|$(_out "$out" stale)|$(_out "$out" missing)|$(_out "$out" count)" \
    "the whole index: 1 stale + 1 missing"
  echo '{broken' > "$repo/docs/.doc-index.json"
  rc=0
  run_installed "$repo" "$out" -- "$FRESHNESS" audit || rc=$?
  assert_eq "1|failed|" "$rc|$(_out "$out" status)|$(_out "$out" count)" "a tool failure: exits 1, status failed, no count"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
}

test_i8_freshness_scope() {
  echo "Test: freshness-check.sh scope — the AI jobs' gate: docs the change touches (by code ref or by path); fails closed"
  local repo out rc rng
  repo=$(freshness_repo) || { assert_true "freshness fixture" false; return 0; }
  out="$(harness_mktemp_d step)/out"
  rng="$(cat "$repo/.git/fx-base")...$(cat "$repo/.git/fx-head")"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" -- "$FRESHNESS" scope || rc=$?
  assert_eq "0|ok|2" "$rc|$(_out "$out" status)|$(_out "$out" affected)" "docs/a.md (cites changed code) and docs/b.md (changed itself) are affected"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" SCOPE_DOCS='^docs/specs/(.*/)?SPEC-[^/]*\.md$' -- "$FRESHNESS" scope || rc=$?
  assert_eq "0|0" "$rc|$(_out "$out" affected)" "SCOPE_DOCS narrows it: no spec is affected"
  assert_contains "$(cat "$out.log")" "::notice::" "…and the skip is announced"
  rc=0
  run_installed "$repo" "$out" RANGE="$(cat "$repo/.git/fx-base")...$(cat "$repo/.git/fx-base")" -- "$FRESHNESS" scope || rc=$?
  assert_eq "0|0" "$rc|$(_out "$out" affected)" "an empty change affects nothing"
  rc=0
  run_installed "$repo" "$out" RANGE="...$(cat "$repo/.git/fx-head")" -- "$FRESHNESS" scope || rc=$?
  assert_eq "0|2" "$rc|$(_out "$out" affected)" "no base (a manual run): the whole index is in scope"
  rc=0
  run_installed "$repo" "$out" RANGE="nosuchref...$(cat "$repo/.git/fx-head")" -- "$FRESHNESS" scope || rc=$?
  assert_eq "1|failed|" "$rc|$(_out "$out" status)|$(_out "$out" affected)" "an unresolvable range fails closed (no affected output)"
  echo '{broken' > "$repo/docs/.doc-index.json"
  rc=0
  run_installed "$repo" "$out" RANGE="$rng" -- "$FRESHNESS" scope || rc=$?
  assert_eq "1|failed|" "$rc|$(_out "$out" status)|$(_out "$out" affected)" "a tool failure fails closed (the AI step never runs on a guess)"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
}

# marketplace_remote <version>: a bare repository (a file:// URL) holding the
# plugin's manifests at <version>, tagged v<version> — plus v9.0.0 on the same
# commit, whose manifests do not say 9.0.0. Echoes the URL.
marketplace_remote() {
  local dir
  dir=$(harness_mktemp_d market)
  (
    git init -q -b main "$dir/src" 2>/dev/null || { git init -q "$dir/src" && git -C "$dir/src" symbolic-ref HEAD refs/heads/main; }
    cd "$dir/src" || exit 1
    git config user.email t@t.com
    git config user.name t
    mkdir -p .claude-plugin
    printf '{"name": "doc-superpowers", "plugins": [{"name": "doc-superpowers", "source": "./"}]}\n' > .claude-plugin/marketplace.json
    printf '{"name": "doc-superpowers", "version": "%s"}\n' "$1" > .claude-plugin/plugin.json
    git add -A && git -c commit.gpgsign=false commit -q -m plugin
    git tag "v$1"
    git tag v9.0.0
    git init -q --bare "$dir/market.git"
    git push -q "$dir/market.git" main --tags
  ) >/dev/null 2>&1 || return 1
  printf 'file://%s' "$dir/market.git"
}

test_i8_prepare_agent() {
  echo "Test: prepare-agent.sh — the plugin marketplace at exactly the installed version's tag, and the checkout's head"
  local url repo out rc mp v
  url=$(marketplace_remote 1.2.3) || { assert_true "marketplace fixture" false; return 0; }
  repo=$(new_repo)
  out="$(harness_mktemp_d step)/out"
  rc=0
  run_installed "$repo" "$out" DOC_SUPERPOWERS_VERSION=v1.2.3 DOC_SUPERPOWERS_MARKETPLACE_URL="$url" -- "$STEPS_DIR/prepare-agent.sh" || rc=$?
  assert_eq "0" "$rc" "the installed version's tag → exits 0"
  mp=$(_out "$out" marketplace)
  case "$mp" in
    "$out.tmp"/*) assert_true "the marketplace is an absolute path under \$RUNNER_TEMP" true ;;
    *) assert_true "the marketplace is an absolute path under \$RUNNER_TEMP (got '$mp')" false ;;
  esac
  assert_file_exists "$mp/.claude-plugin/marketplace.json" "…holding the marketplace manifest"
  assert_eq "1.2.3" "$(jq -r .version "$mp/.claude-plugin/plugin.json" 2>/dev/null)" "…at the pinned version"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$(_out "$out" head)" "head = the checkout's HEAD before the agent runs"
  assert_eq "$out.tmp/doc-superpowers-steps/commit-changes.sh" "$(_out "$out" checker)" \
    "checker = the commit checker snapshotted under \$RUNNER_TEMP before the agent runs"
  assert_true "…a byte copy of commit-changes.sh" cmp -s "$STEPS_DIR/commit-changes.sh" "$out.tmp/doc-superpowers-steps/commit-changes.sh"
  assert_true "…executable" test -x "$out.tmp/doc-superpowers-steps/commit-changes.sh"
  for v in vunknown v1.2 ""; do
    rc=0
    run_installed "$repo" "$out" DOC_SUPERPOWERS_VERSION="$v" DOC_SUPERPOWERS_MARKETPLACE_URL="$url" -- "$STEPS_DIR/prepare-agent.sh" || rc=$?
    assert_eq "1|" "$rc|$(_out "$out" marketplace)" "version '$v' is not a release: exits 1, no marketplace"
    assert_contains "$(cat "$out.log")" "::error::" "version '$v': an ::error:: says why"
  done
  rc=0
  run_installed "$repo" "$out" DOC_SUPERPOWERS_VERSION=v2.0.0 DOC_SUPERPOWERS_MARKETPLACE_URL="$url" -- "$STEPS_DIR/prepare-agent.sh" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" marketplace)" "no such tag: exits 1, no marketplace"
  rc=0
  run_installed "$repo" "$out" DOC_SUPERPOWERS_VERSION=v9.0.0 DOC_SUPERPOWERS_MARKETPLACE_URL="$url" -- "$STEPS_DIR/prepare-agent.sh" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" marketplace)" "a tag whose manifests name another version: exits 1"
  assert_contains "$(cat "$out.log")" "1.2.3" "…naming the version found"
}

# cc_fixture: origin_and_clone plus, on feature (pushed), an index whose keys
# are docs/d.md, docs/e.md, docs/f.md and README.md. Echoes the parent dir.
cc_fixture() {
  local dir
  dir=$(origin_and_clone)
  (
    cd "$dir/clone" || exit 1
    mkdir -p docs src
    echo '# D' > docs/d.md
    echo '# E' > docs/e.md
    echo '# F' > docs/f.md
    echo '# R' > README.md
    echo 'x' > src/x.js
    printf '{"version": 3, "docs": {"docs/d.md": {"code_refs": ["src/"]}, "docs/e.md": {"code_refs": []}, "docs/f.md": {"code_refs": []}, "README.md": {"code_refs": []}}}\n' > docs/.doc-index.json
    git add -A && git -c commit.gpgsign=false commit -q -m docs
    git push -q origin feature
  ) >/dev/null 2>&1 || return 1
  printf '%s' "$dir"
}

# _cc_reset <dir>: the clone back at origin's feature, clean (for the next case).
_cc_reset() {
  git -C "$1/clone" fetch -q origin 2>/dev/null
  git -C "$1/clone" reset -q --hard origin/feature
  git -C "$1/clone" clean -qfdx
}

test_i8_commit_changes() {
  echo "Test: commit-changes.sh — commits and pushes only allowed paths; refuses an agent commit or any other path"
  local dir clone out rc head cc="$STEPS_DIR/commit-changes.sh"
  local args=(--allow docs/ --allow-index-keys --message "[doc-superpowers] update stale docs" --push-to feature)
  dir=$(cc_fixture) || { assert_true "fixture" false; return 0; }
  clone="$dir/clone"
  out="$(harness_mktemp_d step)/out"
  head=$(git -C "$clone" rev-parse HEAD)

  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|false|false" "$rc|$(_out "$out" changed)|$(_out "$out" committed)" "nothing changed: exits 0, no commit"
  assert_eq "$head" "$(git -C "$dir/origin.git" rev-parse feature)" "…nothing pushed"

  echo '# D2' > "$clone/docs/d.md"
  echo '# R2' > "$clone/README.md"
  echo '# N' > "$clone/docs/new.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|true|true" "$rc|$(_out "$out" changed)|$(_out "$out" committed)" "docs/ and an indexed doc: committed"
  assert_eq "[doc-superpowers] update stale docs" "$(git -C "$dir/origin.git" log -1 --format=%s feature)" "…and pushed with the given subject"
  assert_eq "README.md docs/d.md docs/new.md" \
    "$(git -C "$dir/origin.git" show --name-only --format= feature | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "…exactly those paths"

  # Deletions: one the agent staged (git rm — doc-release's consumed
  # fragments), one only in the work tree; a staged file of the workflow's
  # scratch (ignored) stays out of the commit.
  head=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" rm -q docs/e.md
  rm -f "$clone/docs/f.md"
  mkdir -p "$clone/.scratch"
  echo '{}' > "$clone/.scratch/context.json"
  git -C "$clone" add -f .scratch/context.json
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" --ignore .scratch/ || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" committed)" "a staged (git rm) and a work-tree deletion: committed"
  assert_eq "D	docs/e.md D	docs/f.md" \
    "$(git -C "$dir/origin.git" show --name-status --format= feature | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
    "…exactly the two deletions (the staged scratch file is not in the commit)"
  assert_eq "A  .scratch/context.json" "$(git -C "$clone" status --porcelain -- .scratch)" "…and stays staged, uncommitted"
  _cc_reset "$dir"

  head=$(git -C "$clone" rev-parse HEAD)
  echo 'y' > "$clone/src/x.js"
  echo '# D3' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1" "$rc" "a change outside the allowed paths: exits 1"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error:: …"
  assert_contains "$(cat "$out.log")" "src/x.js" "…naming the path"
  assert_eq "$head|$head" "$(git -C "$clone" rev-parse HEAD)|$(git -C "$dir/origin.git" rev-parse feature)" "…nothing committed or pushed"
  _cc_reset "$dir"

  echo 'y' > "$clone/src/y.md"
  jq '.docs["src/y.md"] = {code_refs: []}' "$clone/docs/.doc-index.json" > "$clone/docs/.doc-index.json.new" \
    && mv "$clone/docs/.doc-index.json.new" "$clone/docs/.doc-index.json"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1" "$rc" "a key the agent added to the index does not authorize its path (only HEAD's keys count)"
  _cc_reset "$dir"

  ( cd "$clone" && echo z > z.txt && git add z.txt && git -c commit.gpgsign=false commit -q -m "agent commit" )
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1" "$rc" "HEAD moved (the agent committed): exits 1"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  _cc_reset "$dir"

  mkdir -p "$clone/.scratch" "$clone/.scratch-x"
  echo '{}' > "$clone/.scratch/context.json"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" --check-only --allow docs/d.md --ignore .scratch || rc=$?
  assert_eq "0|false" "$rc|$(_out "$out" changed)" "--check-only, only ignored scratch: nothing changed"
  echo 'x' > "$clone/.scratch-x/other"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" --check-only --allow docs/d.md --ignore .scratch || rc=$?
  assert_eq "1" "$rc" "--ignore .scratch is the directory .scratch/, not every path starting .scratch (.scratch-x/ is a violation)"
  rm -rf "$clone/.scratch-x"
  echo '# D4' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" --check-only --allow docs/d.md --ignore .scratch/ || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" changed)" "--check-only, an allowed change: exits 0, changed=true …"
  assert_eq "$head" "$(git -C "$clone" rev-parse HEAD)" "…and commits nothing"
  _cc_reset "$dir"

  # Hooks and an fsmonitor the agent could plant in .git never run.
  local marks="$dir/marks" evil="$dir/evil-hooks"
  mkdir -p "$marks" "$evil"
  for h in pre-commit commit-msg post-commit pre-push; do
    printf '#!/bin/sh\ntouch "%s/%s"\nexit 1\n' "$marks" "$h" > "$clone/.git/hooks/$h"
    chmod +x "$clone/.git/hooks/$h"
  done
  printf '#!/bin/sh\ntouch "%s/fsmonitor"\nexit 1\n' "$marks" > "$dir/fsmon"
  chmod +x "$dir/fsmon"
  git -C "$clone" config core.fsmonitor "$dir/fsmon"
  echo '# D6' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" committed)" "planted .git hooks (exit 1) and core.fsmonitor: the commit still goes through"
  assert_eq "" "$(ls "$marks")" "…and none of them ran"
  git -C "$clone" config core.hooksPath "$evil"
  cp "$clone/.git/hooks/pre-commit" "$evil/pre-commit"
  head=$(git -C "$clone" rev-parse HEAD)
  echo '# D7' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|" "$rc|$(ls "$marks")" "a planted core.hooksPath is overridden too"
  git -C "$clone" config --unset core.hooksPath
  git -C "$clone" config --unset core.fsmonitor
  rm -f "$clone"/.git/hooks/pre-commit "$clone"/.git/hooks/commit-msg "$clone"/.git/hooks/post-commit "$clone"/.git/hooks/pre-push
  _cc_reset "$dir"

  # The branch moved during the run. Superseded (exit 0, nothing committed)
  # only when someone other than doc-superpowers pushed: a queued run of the
  # write group starts from the branch tip, so doc-superpowers' own commits
  # moving it mid-run are never a reason to drop this run's work.
  _seed_push() { # <file> <subject>
    (
      cd "$dir/seed" || exit 1
      git fetch -q origin 2>/dev/null
      git reset -q --hard origin/feature
      echo "$1" > "$1.txt"
      git add "$1.txt"
      git -c commit.gpgsign=false commit -q -m "$2"
      git push -q origin HEAD:feature
    ) >/dev/null 2>&1
  }
  local tip
  head=$(git -C "$clone" rev-parse HEAD)
  _seed_push human "human push"
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  echo '# D5' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|true|false|true" "$rc|$(_out "$out" changed)|$(_out "$out" committed)|$(_out "$out" superseded)" \
    "someone pushed to the branch during the run: superseded, exits 0, no commit"
  assert_contains "$(cat "$out.log")" "superseded: feature received new commits during this run (${head:0:12}..${tip:0:12})" \
    "…with a notice that says what happened"
  assert_not_contains "$(cat "$out.log")" "newer run" "…and claims no newer run (doc-pr-full-cycle has none)"
  assert_not_contains "$(cat "$out.log")" "::error::" "…and no error"
  assert_eq "$tip|$head" "$(git -C "$dir/origin.git" rev-parse feature)|$(git -C "$clone" rev-parse HEAD)" \
    "…the newer tip is kept, nothing committed or pushed"
  _cc_reset "$dir"

  head=$(git -C "$clone" rev-parse HEAD)
  _seed_push bot1 "[doc-superpowers] sync PR-7 release notes (abc1234)"
  _seed_push bot2 "[doc-superpowers] update stale docs"
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  echo '# D5b' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" superseded)" \
    "the branch moved only by [doc-superpowers] commits: a visible failure (exit 1), not a green discard"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error:: annotation"
  assert_eq "$tip|$head" "$(git -C "$dir/origin.git" rev-parse feature)|$(git -C "$clone" rev-parse HEAD)" \
    "…nothing committed or pushed"
  _cc_reset "$dir"

  head=$(git -C "$clone" rev-parse HEAD)
  _seed_push bot3 "[doc-superpowers] sync PR-8 release notes (def5678)"
  _seed_push human2 "fix: a human change"
  echo '# D5c' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" superseded)" "a doc-superpowers commit and a human one in the range: superseded"
  _cc_reset "$dir"

  # A branch reset behind the checkout: no commit in head..tip says who moved
  # it, so that is a failure too.
  head=$(git -C "$clone" rev-parse HEAD)
  git -C "$dir/origin.git" update-ref refs/heads/feature "$(git -C "$clone" rev-parse HEAD~1)"
  echo '# D5d' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" superseded)" "the branch moved behind the checkout (head..tip empty): exits 1, not superseded"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  git -C "$dir/origin.git" update-ref refs/heads/feature "$head"
  _cc_reset "$dir"

  # origin cannot be asked: the ::error:: annotation reaches the log (it was
  # swallowed by the command substitution that called err).
  head=$(git -C "$clone" rev-parse HEAD)
  local url
  url=$(git -C "$clone" remote get-url origin)
  git -C "$clone" remote set-url origin "$dir/no-such-origin.git"
  echo '# D5e' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1" "$rc" "origin cannot be asked for the branch: exits 1"
  assert_contains "$(cat "$out.log")" "::error::doc-superpowers: cannot ask origin for feature" "…and the ::error:: annotation is printed"
  git -C "$clone" remote set-url origin "$url"
  _cc_reset "$dir"

  # A push that fails for another reason is a failure.
  head=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" remote set-url --push origin "$dir/no-such-remote.git"
  echo '# D8' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" superseded)" "a push that fails while the branch is still at the checkout: exits 1, not 'superseded'"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  git -C "$clone" remote set-url --delete --push origin "$dir/no-such-remote.git"
  _cc_reset "$dir"

  local shim
  shim=$(harness_mktemp_d gh-pr)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\necho https://github.com/o/r/pull/9\n' "$shim" > "$shim/gh"
  chmod +x "$shim/gh"
  echo '# D9' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" PATH="$shim:$BASH_PATH" -- "$cc" --allow docs/ \
    --message "[doc-superpowers] draft release notes" --push-to doc-superpowers/release-notes-1 --open-pr feature || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" committed)" "--open-pr: committed to a new branch …"
  assert_eq "[doc-superpowers] draft release notes" "$(git -C "$dir/origin.git" log -1 --format=%s doc-superpowers/release-notes-1 2>/dev/null)" "…pushed"
  assert_contains "$(cat "$shim/calls" 2>/dev/null)" "pr create --base feature --head doc-superpowers/release-notes-1" "…and a PR opened against the base"
  _cc_reset "$dir"
  echo '# D10' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" PATH="$shim:$BASH_PATH" -- "$cc" --allow docs/ \
    --message "[doc-superpowers] draft release notes" --push-to doc-superpowers/release-notes-1 --open-pr feature || rc=$?
  assert_eq "1" "$rc" "--open-pr onto a branch that already exists: exits 1 (it only ever creates one)"
  _cc_reset "$dir"

  # The branch was deleted (the PR merged) while the run waited: nothing to recreate.
  git -C "$dir/origin.git" update-ref -d refs/heads/feature
  echo '# D11' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|false" "$rc|$(_out "$out" committed)" "the target branch is gone: exits 0, commits nothing …"
  assert_eq "" "$(git -C "$dir/origin.git" for-each-ref refs/heads/feature)" "…and does not recreate it"
}

test_i8_pr_guard() {
  echo "Test: pr-guard.sh — a PR comment runs the agent only for a same-repository PR"
  local repo out rc shim
  repo=$(new_repo)
  out="$(harness_mktemp_d step)/out"
  shim=$(harness_mktemp_d gh-guard)
  printf '#!/usr/bin/env bash\n[ "${FAKE_GH_RC:-0}" = 0 ] || exit "$FAKE_GH_RC"\nprintf "%%s\\n" "$FAKE_HEAD_REPO"\n' > "$shim/gh"
  chmod +x "$shim/gh"
  rc=0
  run_installed "$repo" "$out" PATH="$shim:$BASH_PATH" GITHUB_REPOSITORY=o/r PR_NUMBER=5 FAKE_HEAD_REPO=o/r -- "$STEPS_DIR/pr-guard.sh" || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" same_repo)" "same repository: same_repo=true"
  rc=0
  run_installed "$repo" "$out" PATH="$shim:$BASH_PATH" GITHUB_REPOSITORY=o/r PR_NUMBER=5 FAKE_HEAD_REPO=fork/r -- "$STEPS_DIR/pr-guard.sh" || rc=$?
  assert_eq "0|false" "$rc|$(_out "$out" same_repo)" "a fork: same_repo=false …"
  assert_contains "$(cat "$out.log")" "::notice::" "…announced"
  rc=0
  run_installed "$repo" "$out" PATH="$shim:$BASH_PATH" GITHUB_REPOSITORY=o/r PR_NUMBER=5 FAKE_GH_RC=1 -- "$STEPS_DIR/pr-guard.sh" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" same_repo)" "gh fails: exits 1, no answer"
  rc=0
  run_installed "$repo" "$out" PATH="$shim:$BASH_PATH" GITHUB_REPOSITORY=o/r PR_NUMBER=abc FAKE_HEAD_REPO=o/r -- "$STEPS_DIR/pr-guard.sh" || rc=$?
  assert_eq "1|" "$rc|$(_out "$out" same_repo)" "a non-numeric PR number: exits 1"
}

test_i8_freshness_gate
test_i8_freshness_output_is_bounded
test_i8_freshness_audit
test_i8_freshness_scope
test_i8_prepare_agent
test_i8_commit_changes
test_i8_pr_guard

# ============================================================================
# I-9: the fragment producer (extract-context, commit-and-push, update-pr-body)
# ============================================================================
echo
echo "=== I-9 fragment producer ==="

test_i9_extract_context_watermark_is_the_recorded_checkout() {
  # The old rebase-retry left sentinels on top of commits pushed mid-run; the
  # sentinel records the checkout it was drafted from, and that — not the
  # last commit touching the fragment — is where "new" starts.
  echo "Test: I-9 extract-context — new_commits start at the checkout the last sentinel recorded; bot commits are not PR work"
  local work shim out rc s form
  for form in trailer subject; do
    work=$(new_repo)
    git -C "$work" checkout -q -b feature/x
    commit_file "$work" a.txt a "feat: a"
    commit_file "$work" b.txt b "feat: b"
    s=$(git -C "$work" rev-parse HEAD)
    commit_file "$work" c.txt c "feat: mid-run push"
    sealed_fragment "$work/RELEASE-NOTES.next/PR-42.md" 42 $'### Added\n- a, b\n'
    git -C "$work" add RELEASE-NOTES.next
    if [ "$form" = trailer ]; then
      git -C "$work" commit -q -m "[doc-superpowers] sync PR-42 release notes (${s:0:7})" -m "Doc-Superpowers-Drafted-From: $s"
    else
      git -C "$work" commit -q -m "[doc-superpowers] sync PR-42 release notes (${s:0:7})"
    fi
    commit_file "$work" d.txt d "feat: d"
    shim=$(gh_shim '{"number": 42, "body": "", "headRefName": "feature/x", "baseRefName": "main"}')
    out="$work/ctx.json"
    rc=0
    run_extract "$work" "$shim" 42 "$out" || rc=$?
    assert_eq "0" "$rc" "($form) exits 0"
    assert_eq "feat: mid-run push|feat: d" "$(subjects "$out" new_commits)" \
      "($form) new_commits = everything after the recorded checkout (the mid-run push included)"
    assert_eq "feat: a|feat: b|feat: mid-run push|feat: d" "$(subjects "$out" full_commits)" \
      "($form) full_commits leaves out the bot's sync commit"
  done
}

test_i9_extract_context_hash_state() {
  echo "Test: I-9 extract-context — existing_fragment_hash_valid and existing_fragment_no_notes are computed, not left to the agent"
  local work
  work=$(new_repo)
  git -C "$work" checkout -q -b feat/x
  sealed_fragment "$work/RELEASE-NOTES.next/PR-9.md" 9 $'### Added\n- nine\n'
  local shim out rc=0
  shim=$(gh_shim '{"number": 9, "body": "", "headRefName": "feat/x", "baseRefName": "main"}')
  out="$work/ctx.json"
  run_extract "$work" "$shim" 9 "$out" || rc=$?
  assert_eq "0|true|false|false" \
    "$rc|$(jq -r '.existing_fragment_hash_valid' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_no_notes' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_corrupt' "$out" 2>/dev/null)" \
    "a sealed fragment: hash valid, not no-notes, not corrupt"
  printf '<!-- doc-superpowers:fragment PR-9 -->\n<!-- doc-superpowers:hash deadbeef -->\n### Added\n- nine\n' > "$work/RELEASE-NOTES.next/PR-9.md"
  rc=0
  run_extract "$work" "$shim" 9 "$out" || rc=$?
  assert_eq "0|false" "$rc|$(jq -r '.existing_fragment_hash_valid' "$out" 2>/dev/null)" "a hand-edited fragment: hash not valid"
  sealed_fragment "$work/RELEASE-NOTES.next/PR-9.md" 9 $'<!-- doc-superpowers:no-notes -->\n'
  rc=0
  run_extract "$work" "$shim" 9 "$out" || rc=$?
  assert_eq "0|true|true" "$rc|$(jq -r '.existing_fragment_no_notes' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_hash_valid' "$out" 2>/dev/null)" \
    "the no-notes marker: no_notes true"
  rm -f "$work/RELEASE-NOTES.next/PR-9.md"
  rc=0
  run_extract "$work" "$shim" 9 "$out" || rc=$?
  assert_eq "0|false|false" "$rc|$(jq -r '.existing_fragment_hash_valid' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_no_notes' "$out" 2>/dev/null)" \
    "no fragment: both false"
}

test_i9_extract_context_never_reads_a_symlink() {
  echo "Test: I-9 extract-context — a fragment that is a symbolic link is corrupt and never read"
  local work shim out rc=0
  work=$(new_repo)
  git -C "$work" checkout -q -b feat/x
  printf 'TOP-SECRET-TOKEN\n' > "$work/secret.txt"
  mkdir -p "$work/RELEASE-NOTES.next"
  ln -s ../secret.txt "$work/RELEASE-NOTES.next/PR-5.md"
  shim=$(gh_shim '{"number": 5, "body": "", "headRefName": "feat/x", "baseRefName": "main"}')
  out="$work/ctx.json"
  run_extract "$work" "$shim" 5 "$out" || rc=$?
  assert_eq "0|true|null" "$rc|$(jq -r '.existing_fragment_corrupt' "$out" 2>/dev/null)|$(jq -r '.existing_fragment' "$out" 2>/dev/null)" \
    "exits 0; corrupt, not read"
  assert_not_contains "$(cat "$out")" "TOP-SECRET" "the link target never reaches context.json"
}

test_i9_extract_context_large_payloads() {
  # Payloads go to jq through files, never argv: one argument is capped at
  # 128 KiB on Linux and argv+env at ~1 MiB on macOS.
  echo "Test: I-9 extract-context — a 1.2 MB PR body and a 600 KB fragment (E2BIG through argv)"
  local work json shim out rc=0 big
  work=$(new_repo)
  git -C "$work" checkout -q -b feat/x
  commit_file "$work" a.txt a "feat: a"
  json=$(harness_mktemp big-pr)
  big=$(harness_mktemp big-body)
  head -c 1200000 /dev/zero | tr '\0' 'x' > "$big"
  jq -n --rawfile b "$big" '{number: 7, body: $b, headRefName: "feat/x", baseRefName: "main"}' > "$json"
  sealed_fragment "$work/RELEASE-NOTES.next/PR-7.md" 7 "$(printf '### Added\n'; head -c 600000 /dev/zero | tr '\0' 'y'; printf '\n')"
  shim=$(gh_shim_file "$json")
  out="$work/ctx.json"
  run_extract "$work" "$shim" 7 "$out" || rc=$?
  assert_eq "0" "$rc" "exits 0 (stderr: $(head -c 200 "$out.err" 2>/dev/null))"
  assert_eq "1200000|false|true" \
    "$(jq -r '.pr_body | length' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_corrupt' "$out" 2>/dev/null)|$(jq -r '.existing_fragment_hash_valid' "$out" 2>/dev/null)" \
    "the whole body and the fragment reach context.json"
}

# cp_run <clone> <out> <pr> [VAR=value…]: commit-and-push.sh as the step runs it.
cp_run() {
  local clone="$1" out="$2" pr="$3" rc=0
  shift 3
  : > "$out"
  ( cd "$clone" && env GITHUB_OUTPUT="$out" GITHUB_HEAD_REF=feature "$@" "$COMMIT_SCRIPT" "$pr" ) > "$out.log" 2>&1 || rc=$?
  return "$rc"
}

test_i9_commit_never_restores_a_force_push() {
  # The P1: a human force-pushes away a commit (here one that leaked a
  # secret) while the run drafts. The old fast-forward push and its rebase
  # retry both put it back.
  echo "Test: I-9 commit-and-push — a force-push during the run is never undone"
  local dir out rc tip
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  ( cd "$dir/seed" && echo leak > secret.txt && git add secret.txt && git -c commit.gpgsign=false commit -q -m "oops: secret" && git push -q origin feature )
  git -C "$dir/clone" pull -q origin feature
  # Removed: the branch is reset behind the checkout.
  git -C "$dir/origin.git" update-ref refs/heads/feature "$(git -C "$dir/clone" rev-parse HEAD~1)"
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  write_fragment_file "$dir/clone" 11 thing
  rc=0
  cp_run "$dir/clone" "$out" 11 || rc=$?
  assert_eq "1" "$rc" "the branch was reset behind the checkout: exits 1 (a visible refusal)"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  assert_eq "$tip" "$(git -C "$dir/origin.git" rev-parse feature)" "…and the removed commit is not pushed back"
  # Rewritten: the secret commit replaced by an amended one.
  (
    cd "$dir/seed" && git fetch -q origin && git reset -q --hard origin/feature
    echo fixed > fixed.txt && git add fixed.txt && git -c commit.gpgsign=false commit -q -m "fix: without the secret"
    git push -q origin HEAD:feature
  )
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  rc=0
  cp_run "$dir/clone" "$out" 11 || rc=$?
  assert_eq "0" "$rc" "the branch was rewritten with new work: superseded, exits 0"
  assert_contains "$(cat "$out")" "superseded=true" "…superseded=true"
  assert_eq "$tip" "$(git -C "$dir/origin.git" rev-parse feature)" "…and nothing is pushed on top of it"
  assert_true "…the secret never returns to the branch" test -z "$(git -C "$dir/origin.git" log --format=%s feature | grep -x 'oops: secret' || true)"
}

test_i9_commit_moved_only_by_the_bot() {
  echo "Test: I-9 commit-and-push — the branch moved only by [doc-superpowers] commits: exit 1 (commit-changes.sh's rule)"
  local dir out rc=0
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  ( cd "$dir/seed" && echo x > x.txt && git add x.txt && git -c commit.gpgsign=false commit -q -m "[doc-superpowers] update stale docs" && git push -q origin feature )
  write_fragment_file "$dir/clone" 12 thing
  cp_run "$dir/clone" "$out" 12 || rc=$?
  assert_eq "1|" "$rc|$(sed -n 's/^superseded=//p' "$out")" "exits 1, not superseded"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
}

test_i9_commit_seals_the_fragment() {
  echo "Test: I-9 commit-and-push — writes the line-2 hash itself and records the checkout in the sentinel"
  local dir out rc=0 head f
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  head=$(git -C "$dir/clone" rev-parse HEAD)
  f="$dir/clone/RELEASE-NOTES.next/PR-13.md"
  mkdir -p "$(dirname "$f")"
  printf '<!-- doc-superpowers:fragment PR-13 -->\n<!-- doc-superpowers:hash -->\n### Added\n- thirteen\n' > "$f"
  cp_run "$dir/clone" "$out" 13 || rc=$?
  assert_eq "0" "$rc" "exits 0 (log: $(head -c 300 "$out.log"))"
  git -C "$dir/origin.git" show feature:RELEASE-NOTES.next/PR-13.md > "$dir/pushed.md" 2>/dev/null || true
  assert_eq "<!-- doc-superpowers:hash $(_payload_sha "$dir/pushed.md") -->" "$(sed -n 2p "$dir/pushed.md")" \
    "the pushed fragment's line 2 is the hash of lines 3+"
  assert_eq $'<!-- doc-superpowers:fragment PR-13 -->\n### Added\n- thirteen' "$(sed 2d "$dir/pushed.md")" "…and the rest is as written"
  assert_true "the sync subject is the sentinel form" grep -qE "$SENTINEL_SUBJECT_RE" <<<"$(git -C "$dir/origin.git" log -1 --format=%s feature)"
  assert_contains "$(git -C "$dir/origin.git" log -1 --format=%B feature)" "Doc-Superpowers-Drafted-From: $head" \
    "…and records the checkout it was drafted from"
  assert_contains "$(cat "$out")" "committed=true" "committed=true in GITHUB_OUTPUT"
  # Line 2 left out altogether: inserted.
  printf '<!-- doc-superpowers:fragment PR-13 -->\n### Added\n- thirteen, reworded\n' > "$f"
  rc=0
  cp_run "$dir/clone" "$out" 13 || rc=$?
  git -C "$dir/origin.git" show feature:RELEASE-NOTES.next/PR-13.md > "$dir/pushed.md" 2>/dev/null || true
  assert_eq "0|<!-- doc-superpowers:hash $(_payload_sha "$dir/pushed.md") -->|- thirteen, reworded" \
    "$rc|$(sed -n 2p "$dir/pushed.md")|$(sed -n 4p "$dir/pushed.md")" "no hash line written: one is inserted"
}

test_i9_commit_never_overwrites_a_hand_edit() {
  echo "Test: I-9 commit-and-push — never overwrites a fragment a human edited (its hash no longer matches)"
  local dir out rc head before
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  (
    cd "$dir/clone" || exit 1
    mkdir -p RELEASE-NOTES.next
    printf '<!-- doc-superpowers:fragment PR-14 -->\n<!-- doc-superpowers:hash 0000 -->\n### Added\n- worded by a human\n' > RELEASE-NOTES.next/PR-14.md
    git add RELEASE-NOTES.next && git -c commit.gpgsign=false commit -q -m "docs: my own wording" && git push -q origin feature
  )
  head=$(git -C "$dir/clone" rev-parse HEAD)
  before=$(hash_file "$dir/clone/RELEASE-NOTES.next/PR-14.md")
  rc=0
  cp_run "$dir/clone" "$out" 14 || rc=$?
  assert_eq "0|$before" "$rc|$(hash_file "$dir/clone/RELEASE-NOTES.next/PR-14.md")" \
    "left alone: exits 0 and the file is not re-sealed"
  printf '<!-- doc-superpowers:fragment PR-14 -->\n<!-- doc-superpowers:hash -->\n### Added\n- the bot rewrote it\n' > "$dir/clone/RELEASE-NOTES.next/PR-14.md"
  rc=0
  cp_run "$dir/clone" "$out" 14 || rc=$?
  assert_eq "1" "$rc" "rewritten by the agent: refused (exit 1)"
  assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::"
  assert_eq "$head|$head" "$(git -C "$dir/clone" rev-parse HEAD)|$(git -C "$dir/origin.git" rev-parse feature)" "…nothing committed or pushed"
}

test_i9_commit_refuses_a_malformed_fragment() {
  echo "Test: I-9 commit-and-push — a wrong line-1 marker, an empty body or a symbolic link is refused"
  local dir out rc head f
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  head=$(git -C "$dir/clone" rev-parse HEAD)
  f="$dir/clone/RELEASE-NOTES.next/PR-15.md"
  mkdir -p "$(dirname "$f")"
  printf '<!-- doc-superpowers:fragment PR-51 -->\n<!-- doc-superpowers:hash -->\n### Added\n- x\n' > "$f"
  rc=0; cp_run "$dir/clone" "$out" 15 || rc=$?
  assert_eq "1" "$rc" "line 1 names another PR: exits 1"
  printf '<!-- doc-superpowers:fragment PR-15 -->\n<!-- doc-superpowers:hash -->\n\n' > "$f"
  rc=0; cp_run "$dir/clone" "$out" 15 || rc=$?
  assert_eq "1" "$rc" "no notes under the markers: exits 1"
  rm -f "$f"
  ln -s ../seed.txt "$f"
  rc=0; cp_run "$dir/clone" "$out" 15 || rc=$?
  assert_eq "1" "$rc" "a symbolic link: exits 1"
  assert_eq "$head" "$(git -C "$dir/origin.git" rev-parse feature)" "nothing pushed"
}

test_i9_pr_release_queued_behind_itself() {
  # T9 hand-off: run(P1) checked out before P2 landed. It used to rebase its
  # fragment onto P2 and push, so run(P2) found a sentinel at HEAD and skipped
  # — the fragment never saw P2. Now run(P1) is superseded and run(P2)
  # drafts from the tip.
  echo "Test: I-9 two queued pr-release runs — the fragment ends up drafted from the final tip"
  local dir out rc p2 shim clone2
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  shim=$(gh_shim '{"number": 3, "body": "", "headRefName": "feature", "baseRefName": "main"}')
  ( cd "$dir/seed" && echo b > b.txt && git add b.txt && git -c commit.gpgsign=false commit -q -m "feat: b (P2)" && git push -q origin feature )
  p2=$(git -C "$dir/origin.git" rev-parse feature)
  # run(P1): its checkout predates P2.
  write_fragment_file "$dir/clone" 3 "a only"
  rc=0; cp_run "$dir/clone" "$out" 3 || rc=$?
  assert_eq "0|$p2" "$rc|$(git -C "$dir/origin.git" rev-parse feature)" "run(P1): superseded, pushes nothing"
  # run(P2): checks out the tip.
  clone2="$dir/clone2"
  git clone -q --branch feature "$dir/origin.git" "$clone2"
  git -C "$clone2" config user.email t@t.com
  git -C "$clone2" config user.name t
  rc=0; ( cd "$clone2" && run_step "$out" "$SENTINEL_SCRIPT" ) || rc=$?
  assert_eq "skip=false" "$(cat "$out")" "run(P2): HEAD is P2, not a sentinel — it drafts"
  rc=0; run_extract "$clone2" "$shim" 3 "$dir/ctx.json" || rc=$?
  assert_eq "0|feat: a|feat: b (P2)" "$rc|$(subjects "$dir/ctx.json" new_commits)" "run(P2): new_commits carry P2"
  write_fragment_file "$clone2" 3 "a and b"
  rc=0; cp_run "$clone2" "$out" 3 || rc=$?
  assert_eq "0" "$rc" "run(P2): commits and pushes"
  assert_contains "$(git -C "$dir/origin.git" log -1 --format=%B feature)" "Doc-Superpowers-Drafted-From: $p2" "the pushed fragment was drafted from P2"
  assert_eq "$p2" "$(git -C "$dir/origin.git" rev-parse feature~1)" "…and sits directly on P2"
  # A later push: the watermark is P2, so only the new commit is new.
  ( cd "$dir/seed" && git fetch -q origin && git reset -q --hard origin/feature && echo c > c.txt && git add c.txt && git -c commit.gpgsign=false commit -q -m "feat: c (P3)" && git push -q origin HEAD:feature )
  git -C "$clone2" pull -q origin feature
  rc=0; run_extract "$clone2" "$shim" 3 "$dir/ctx.json" || rc=$?
  assert_eq "0|feat: c (P3)" "$rc|$(subjects "$dir/ctx.json" new_commits)" "the next run: only P3 is new"
}

test_i9_update_pr_body_order_and_fences() {
  echo "Test: I-9 update-pr-body — END before START is refused; markers inside code fences are ignored"
  local body out rc=0
  body=$'intro\n<!-- doc-superpowers:end -->\nmiddle\n<!-- doc-superpowers:start -->\noutro'
  out=$(printf 'x' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq "1" "$rc" "END before START: exits 1"
  assert_contains "$out" "before" "…saying the markers are out of order"
  body=$'How to use it:\n```\n<!-- doc-superpowers:start -->\nexample\n<!-- doc-superpowers:end -->\n```\nend of prose'
  rc=0
  out=$(printf 'managed' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq "0" "$rc" "only fenced markers: exits 0"
  assert_eq "$body"$'\n\n<!-- doc-superpowers:start -->\nmanaged\n<!-- doc-superpowers:end -->' "$out" \
    "…the fenced example is left intact and a new section is appended"
  body=$'~~~\necho "<!-- doc-superpowers:start -->"\n~~~\n<!-- doc-superpowers:start -->\nold\n<!-- doc-superpowers:end -->'
  rc=0
  out=$(printf 'new' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq "0" "$rc" "a fenced mid-line marker is not an error"
  assert_eq $'~~~\necho "<!-- doc-superpowers:start -->"\n~~~\n<!-- doc-superpowers:start -->\nnew\n<!-- doc-superpowers:end -->' "$out" \
    "…and only the real section is replaced"
}

test_i9_pr_release_template() {
  echo "Test: I-9 doc-pr-release.yml — gated on run == 'true'; the agent computes no hash; verify knows 'superseded'"
  yaml_unavailable "i9_pr_release_template" && return 0
  local json gates ai tools prompt verify_env
  json=$(_yaml_json "$TEMPLATE_DIR/doc-pr-release.yml")
  assert_eq "" "$(jq -r '[.jobs[].steps[] | .if // empty | select(contains("new_commits_len"))] | join(" ; ")' <<<"$json")" \
    "no step gates on new_commits_len (a skipped context step left it '', and '' != '0' ran the agent)"
  gates=$(jq -r '[.jobs[].steps[] | select(.id != "pr" and .id != "sentinel" and .id != "context")
    | select((.uses // "") | startswith("actions/checkout@") | not) | (.if // "none")] | unique | join(" ; ")' <<<"$json")
  assert_eq "steps.context.outputs.run == 'true'" "$gates" "every step after the context step runs only when run == 'true'"
  ai=$(jq -c --arg u "$AI_USES" '[.jobs[].steps[] | select((.uses // "") | startswith($u))][0]' <<<"$json")
  tools=$(jq -r "$_JQ_TOOLS"' tools | join(",")' <<<"$ai")
  prompt=$(jq -r '.with.prompt' <<<"$ai")
  for t in sha256sum shasum tail openssl; do
    assert_not_contains "$tools" "Bash($t" "the agent is not given $t (commit-and-push.sh seals the fragment)"
  done
  for t in sha256sum shasum "tail -n" openssl; do
    assert_not_contains "$prompt" "$t" "the prompt does not ask for $t"
  done
  assert_contains "$prompt" ".existing_fragment_hash_valid" "the prompt reads the computed hash state"
  assert_contains "$prompt" "doc-superpowers:no-notes" "the prompt knows the explicit no-notes state"
  assert_eq "commit" "$(jq -r '.jobs[].steps[] | select((.run // "") | startswith(".github/scripts/doc-pr-release/commit-and-push.sh")) | .id' <<<"$json")" \
    "the commit step has id: commit"
  verify_env=$(jq -r '.jobs[].steps[] | select((.run // "") | startswith(".github/scripts/doc-superpowers-steps/verify-fragment.sh")) | .env.SUPERSEDED // ""' <<<"$json")
  assert_eq '${{ steps.commit.outputs.superseded }}' "$verify_env" "verify-fragment gets the commit step's superseded output"
}

test_i9_pr_release_template

test_i9_extract_context_watermark_is_the_recorded_checkout
test_i9_extract_context_hash_state
test_i9_extract_context_never_reads_a_symlink
test_i9_extract_context_large_payloads
test_i9_commit_never_restores_a_force_push
test_i9_commit_moved_only_by_the_bot
test_i9_commit_seals_the_fragment
test_i9_commit_never_overwrites_a_hand_edit
test_i9_commit_refuses_a_malformed_fragment
test_i9_pr_release_queued_behind_itself
test_i9_update_pr_body_order_and_fences

test_i9_update_pr_body_unclosed_fence() {
  # Fix round 1: a body ending inside an unclosed fence hid the markers, so
  # every run appended one more section (inside the code block).
  echo "Test: I-9 update-pr-body — an unclosed fence: refused rather than appended; a section before it is still replaced"
  local body out rc=0 again
  body=$'Repro:\n```\nstack trace line 1\nstack trace line 2'
  out=$(printf 'managed' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq "1" "$rc" "no section and an unclosed fence: exits 1 (nothing appended)"
  assert_contains "$out" "unclosed code fence" "…saying why"
  body=$'<!-- doc-superpowers:start -->\nold\n<!-- doc-superpowers:end -->\nRepro:\n```\nstack trace'
  rc=0
  out=$(printf 'new' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq $'0|<!-- doc-superpowers:start -->\nnew\n<!-- doc-superpowers:end -->\nRepro:\n```\nstack trace' "$rc|$out" \
    "a section before the unclosed fence is replaced in place"
  rc=0
  again=$(printf 'new' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$out" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
  assert_eq "0|$out" "$rc|$again" "…and a second run changes nothing (one section, idempotent)"
}

test_i9_fence_parser_is_one_parser() {
  # doc-tools.sh is vendored as one self-contained file, so it keeps its own
  # copy of update-pr-body.sh's fence parser: the same text, and the same
  # verdicts on the same fixtures.
  echo "Test: I-9 the fence parser of doc-tools.sh and update-pr-body.sh — identical text, identical verdicts"
  local a b fx opener closer fenced closes dir list secs problem body out rc dt_fenced dt_closes ub_fenced ub_closes
  a=$(sed -n '/^# --- fence parser (/,/^# --- end fence parser$/p' "$REPO_ROOT/scripts/doc-tools.sh" 2>/dev/null) || a=""
  b=$(sed -n '/^# --- fence parser (/,/^# --- end fence parser$/p' "$HELPERS_DIR/update-pr-body.sh" 2>/dev/null) || b=""
  assert_true "doc-tools.sh carries the marked fence parser" test -n "$a"
  assert_eq "$a" "$b" "update-pr-body.sh carries it byte for byte"
  # <opener>|<closer>|<is the line after the opener fenced>|<does the closer close it>
  for fx in '```|```|y|y' '~~~|~~~|y|y' '````|```|y|n' '```|````|y|y' '```js|```|y|y' '  ```|```|y|y' \
            '~~~|```|y|n' '```|``` x|y|n' '``` `x`|```|n|-'; do
    opener=${fx%%|*}; fx=${fx#*|}; closer=${fx%%|*}; fx=${fx#*|}; fenced=${fx%%|*}; closes=${fx#*|}
    dir=$(harness_mktemp_d fence)
    mkdir -p "$dir/RELEASE-NOTES.next"
    printf '<!-- doc-superpowers:fragment PR-1 -->\n<!-- doc-superpowers:hash -->\n### Added\n- a\n%s\n### Inside\n%s\n' \
      "$opener" "$closer" > "$dir/RELEASE-NOTES.next/PR-1.md"
    list=$(cd "$dir" && "$DOC_TOOLS_SCRIPT" fragments list 2>/dev/null) || list="[]"
    secs=$(jq -r '.[0].sections | join(",")' <<<"$list")
    problem=$(jq -r '.[0].problem // ""' <<<"$list")
    dt_fenced=y; [ "$secs" = "Added" ] || dt_fenced=n
    dt_closes=y; [ "$problem" != "an unclosed code fence" ] || dt_closes=n
    body=$(printf 'intro\n%s\n<!-- doc-superpowers:start -->\nold\n<!-- doc-superpowers:end -->\n%s' "$opener" "$closer")
    rc=0
    out=$(printf 'new' | DOC_SUPERPOWERS_DRY_RUN=1 DOC_SUPERPOWERS_EXISTING_BODY="$body" "$UPDATE_SCRIPT" 1 2>&1) || rc=$?
    ub_fenced=n; ub_closes=y
    case "$out" in *$'\nold\n'*) ub_fenced=y ;; esac
    if [ "$rc" -ne 0 ]; then ub_fenced=y; ub_closes=n; fi
    assert_eq "$fenced|$fenced" "$dt_fenced|$ub_fenced" "'$opener' … '$closer': both see the next line as fenced=$fenced"
    if [ "$closes" != "-" ]; then
      assert_eq "$closes|$closes" "$dt_closes|$ub_closes" "'$opener' … '$closer': both see it closed=$closes"
    fi
  done
}

test_i9_hash_line_rule_is_one_rule() {
  echo "Test: I-9 the line-2 hash-line rule — one form in fragment-lib.sh and doc-tools.sh, same verdicts"
  local lib="$HELPERS_DIR/fragment-lib.sh" n v1 v2 fx line want lib_says dt_says dir list
  for n in HASH_LINE_RE HASH_RE; do
    v1=$(sed -n "s/^FRAG_${n}=//p" "$lib" 2>/dev/null) || v1=""
    v2=$(sed -n "s/^_FRAG_${n}=//p" "$REPO_ROOT/scripts/doc-tools.sh" 2>/dev/null) || v2=""
    assert_true "fragment-lib.sh defines FRAG_$n" test -n "$v1"
    assert_eq "$v1" "$v2" "doc-tools.sh's _FRAG_$n is byte-identical"
  done
  # <line 2>|<is it a hash line>
  for fx in '<!-- doc-superpowers:hash -->|y' '<!-- doc-superpowers:hash abc123 -->|y' \
            '<!-- doc-superpowers:hash a>b -->|y' '<!-- doc-superpowers:hash abc -->  |y' \
            '<!-- doc-superpowers:hash x y -->|n' '<!-- doc-superpowers:hash-->|n' \
            '<!-- doc-superpowers:hashes abc -->|n' '<!-- doc-superpowers:hash abc --> x|n'; do
    line=${fx%|*}; want=${fx##*|}
    lib_says=$("$BASH_BIN" -c '. "$1"; if frag_is_hash_line "$(frag_trimmed "$2")"; then echo y; else echo n; fi' _ "$lib" "$line" 2>/dev/null) \
      || lib_says="<fragment-lib.sh failed>"
    dir=$(harness_mktemp_d hashline)
    mkdir -p "$dir/RELEASE-NOTES.next"
    printf '<!-- doc-superpowers:fragment PR-1 -->\n%s\n### Added\n- x\n' "$line" > "$dir/RELEASE-NOTES.next/PR-1.md"
    list=$(cd "$dir" && "$DOC_TOOLS_SCRIPT" fragments list 2>/dev/null) || list="[]"
    # Not a hash line: it is the first line of the notes — text before the first heading.
    dt_says=y; [ "$(jq -r '.[0].problem // ""' <<<"$list")" != "text before the first ### heading" ] || dt_says=n
    assert_eq "$want|$want" "$lib_says|$dt_says" "line 2 '$line': a hash line=$want for the helpers and the consumer"
  done
}

test_i9_fragment_lib_ships_with_the_helpers() {
  echo "Test: I-9 fragment-lib.sh ships wherever the doc-pr-release helpers do, and the installed helpers find it"
  local repo rc out
  repo=$(new_repo)
  rc=0
  ( cd "$repo" && "$DOC_TOOLS_SCRIPT" tools install --helper doc-pr-release >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "tools install --helper doc-pr-release exits 0"
  assert_file_exists "$repo/.github/scripts/doc-pr-release/fragment-lib.sh" "…and ships fragment-lib.sh"
  _need_all_repo "i9_fragment_lib_ships_with_the_helpers" || return 0
  assert_file_exists "$ALL_REPO/.github/scripts/doc-pr-release/fragment-lib.sh" "install --ci (doc-pr-release) ships fragment-lib.sh"
  out="$(harness_mktemp_d step)/out"
  rc=0
  run_installed "$ALL_REPO" "$out" PR_NUMBER=5 -- .github/scripts/doc-superpowers-steps/verify-fragment.sh || rc=$?
  assert_eq "1" "$rc" "the installed verify-fragment.sh runs (no fragment: exit 1) …"
  assert_contains "$(cat "$out.log")" "silently skipped" "…for the right reason, having sourced ../doc-pr-release/fragment-lib.sh"
  rc=0
  run_installed "$ALL_REPO" "$out" -- .github/scripts/doc-pr-release/commit-and-push.sh 5 || rc=$?
  assert_eq "0" "$rc" "the installed commit-and-push.sh runs (no fragment: exit 0) …"
  assert_contains "$(cat "$out.log")" "No fragment" "…having sourced both of its libraries"
}

test_i9_commit_rejected_push() {
  # Fix round 1: the path after origin rejects the push. A pre-receive hook
  # on origin does what a concurrent writer would (move or delete the
  # branch) and rejects this push.
  echo "Test: I-9 commit-and-push — a rejected push: branch deleted → 0; moved by someone → superseded; by the bot → 1; unchanged → 1"
  local dir out rc head human bot c
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  (
    cd "$dir/seed" || exit 1
    git fetch -q origin && git reset -q --hard origin/feature
    echo h > h.txt && git add h.txt && git -c commit.gpgsign=false commit -q -m "fix: a human push"
    git push -q origin HEAD:refs/heads/human-side
    git reset -q --hard HEAD~1
    echo b > b.txt && git add b.txt && git -c commit.gpgsign=false commit -q -m "[doc-superpowers] update stale docs"
    git push -q origin HEAD:refs/heads/bot-side
  ) >/dev/null 2>&1
  human=$(git -C "$dir/origin.git" rev-parse human-side)
  bot=$(git -C "$dir/origin.git" rev-parse bot-side)
  head=$(git -C "$dir/clone" rev-parse HEAD)
  printf '#!/bin/sh\nunset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\ncase "$(cat "%s/hook-action" 2>/dev/null)" in\n  delete) git update-ref -d refs/heads/feature ;;\n  human) git update-ref refs/heads/feature %s ;;\n  bot) git update-ref refs/heads/feature %s ;;\nesac\necho "pre-receive: rejected by the test" >&2\nexit 1\n' \
    "$dir" "$human" "$bot" > "$dir/origin.git/hooks/pre-receive"
  chmod +x "$dir/origin.git/hooks/pre-receive"
  for c in delete human bot none; do
    git -C "$dir/origin.git" update-ref refs/heads/feature "$head"
    git -C "$dir/clone" reset -q --hard "$head"
    git -C "$dir/clone" clean -qfd
    echo "$c" > "$dir/hook-action"
    write_fragment_file "$dir/clone" 21 thing
    rc=0
    cp_run "$dir/clone" "$out" 21 || rc=$?
    case "$c" in
      delete)
        assert_eq "0|committed=false|" "$rc|$(grep '^committed=' "$out" | tail -n 1)|$(git -C "$dir/origin.git" for-each-ref refs/heads/feature)" \
          "rejected, the branch deleted meanwhile: exit 0, nothing pushed, not recreated"
        assert_contains "$(cat "$out.log")" "was deleted at origin during this run" "…with a notice" ;;
      human)
        assert_eq "0|superseded=true|$human" "$rc|$(grep '^superseded=' "$out" | tail -n 1)|$(git -C "$dir/origin.git" rev-parse feature)" \
          "rejected, someone pushed meanwhile: superseded, exit 0, their tip kept" ;;
      bot)
        assert_eq "1|$bot" "$rc|$(git -C "$dir/origin.git" rev-parse feature)" \
          "rejected, moved only by a [doc-superpowers] commit: exit 1"
        assert_contains "$(cat "$out.log")" "::error::" "…with an ::error::" ;;
      none)
        assert_eq "1|$head" "$rc|$(git -C "$dir/origin.git" rev-parse feature)" \
          "rejected while the branch is still at the checkout: exit 1, nothing forced"
        assert_contains "$(cat "$out.log")" "failed while the branch was still at the checkout" "…saying so" ;;
    esac
  done
}

test_i9_update_pr_body_unclosed_fence
test_i9_fence_parser_is_one_parser
test_i9_hash_line_rule_is_one_rule
test_i9_fragment_lib_ships_with_the_helpers
test_i9_commit_rejected_push


# --- Final review fix wave (CI) ----------------------------------------------

test_fw_superseded_fails_for_full_cycle() {
  # F2: superseded ends green only where the superseding push runs the
  # workflow again (doc-audit-update on push, doc-pr-release on synchronize).
  # doc-pr-full-cycle runs only when the PR is opened: its superseded run fails.
  echo "Test: FW S-I3 commit-changes.sh --superseded-fails: someone's push during the run fails it (re-run), nothing committed"
  local dir clone out rc head tip cc="$STEPS_DIR/commit-changes.sh"
  local args=(--allow docs/ --allow-index-keys --message "[doc-superpowers] pr docs: review, update, diagrams, sync" --push-to feature)
  dir=$(cc_fixture) || { assert_true "fixture" false; return 0; }
  clone="$dir/clone"
  out="$(harness_mktemp_d step)/out"
  head=$(git -C "$clone" rev-parse HEAD)
  (
    cd "$dir/seed" || exit 1
    git fetch -q origin 2>/dev/null
    git reset -q --hard origin/feature
    echo human > human.txt
    git add human.txt
    git -c commit.gpgsign=false commit -q -m "human push"
    git push -q origin HEAD:feature
  ) >/dev/null 2>&1
  tip=$(git -C "$dir/origin.git" rev-parse feature)
  echo '# D9' > "$clone/docs/d.md"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" --superseded-fails || rc=$?
  assert_eq "1|true|false|true" "$rc|$(_out "$out" changed)|$(_out "$out" committed)|$(_out "$out" superseded)" \
    "--superseded-fails: someone pushed during the run → exits 1 (superseded=true, no commit)"
  assert_contains "$(cat "$out.log")" "::error::doc-superpowers: superseded: feature received new commits during this run (${head:0:12}..${tip:0:12}); nothing was committed" \
    "…an ::error:: that says what happened"
  assert_contains "$(cat "$out.log")" "Re-run this workflow" "…and asks for a re-run"
  assert_eq "$tip|$head" "$(git -C "$dir/origin.git" rev-parse feature)|$(git -C "$clone" rev-parse HEAD)" \
    "…the newer tip is kept, nothing committed or pushed"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" "${args[@]}" || rc=$?
  assert_eq "0|true" "$rc|$(_out "$out" superseded)" "without the flag: superseded ends green (exit 0), as before"
  _cc_reset "$dir"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" --allow docs/ --check-only --superseded-fails || rc=$?
  assert_eq "2" "$rc" "--superseded-fails with --check-only: a usage error (exit 2)"
  rc=0
  run_installed "$clone" "$out" EXPECTED_HEAD="$head" -- "$cc" --allow docs/ --message m --push-to new-branch --open-pr feature --superseded-fails || rc=$?
  assert_eq "2" "$rc" "--superseded-fails with --open-pr (a new branch cannot be superseded): exit 2"
}

test_fw_templates_superseded_policy() {
  echo "Test: FW S-I3 only doc-pr-full-cycle (runs on 'opened' only) passes --superseded-fails"
  local wf run
  for wf in doc-audit-update doc-pr-full-cycle doc-release; do
    run=$(grep -E '^[[:space:]]*run: .*commit-changes\.sh' "$TEMPLATE_DIR/$wf.yml" || true)
    assert_true "$wf: its commit step runs commit-changes.sh" test -n "$run"
    case "$wf" in
      doc-pr-full-cycle) assert_contains "$run" "--superseded-fails" "$wf: a superseded run fails (nothing re-runs it)" ;;
      *) assert_not_contains "$run" "--superseded-fails" "$wf: a superseded run ends green (the push re-runs it, or none can supersede)" ;;
    esac
  done
  assert_true "doc-pr-full-cycle triggers on opened only" grep -qE '^[[:space:]]*types: \[opened\]$' "$TEMPLATE_DIR/doc-pr-full-cycle.yml"
  # S-M5: a corrupt fragment (a symlink, >1 MiB: existing_fragment is null)
  # is left alone too, not overwritten under "Otherwise write".
  assert_true "doc-pr-release's Step 1 keys the hands-off branch on existing_fragment_corrupt alone" \
    grep -qF 'If `.existing_fragment_corrupt` is true, or `.existing_fragment` is' "$TEMPLATE_DIR/doc-pr-release.yml"
  # S-M2: doc-audit-update skips Dependabot (no secrets) and its own commits by
  # subject prefix (a squash commit listing them is work like any other).
  assert_true "doc-audit-update skips Dependabot's pushes" grep -qF "github.actor != 'dependabot[bot]'" "$TEMPLATE_DIR/doc-audit-update.yml"
  assert_true "…and matches its own commits by prefix" grep -qF "!startsWith(github.event.head_commit.message, '[doc-superpowers]')" "$TEMPLATE_DIR/doc-audit-update.yml"
  assert_true "…never by substring" test -z "$(grep -F "contains(github.event.head_commit.message, '[doc-superpowers]')" "$TEMPLATE_DIR/doc-audit-update.yml" || true)"
}

test_fw_commit_refuses_what_the_release_would_skip() {
  echo "Test: FW S-M6 commit-and-push — a fragment the release would skip (text before ###, a ## heading, an unclosed fence) is refused before sealing"
  local dir out rc head f case_body
  dir=$(origin_and_clone)
  out="$dir/gh-output"
  head=$(git -C "$dir/clone" rev-parse HEAD)
  f="$dir/clone/RELEASE-NOTES.next/PR-16.md"
  mkdir -p "$(dirname "$f")"
  for case_body in $'Intro text.\n### Added\n- x\n' $'## Notes\n### Added\n- x\n' $'### Fixed\n- y\n```\nopen fence\n'; do
    printf '<!-- doc-superpowers:fragment PR-16 -->\n<!-- doc-superpowers:hash -->\n%s' "$case_body" > "$f"
    rc=0
    cp_run "$dir/clone" "$out" 16 || rc=$?
    assert_eq "1" "$rc" "'$(head -n 1 <<<"$case_body")…': refused (exit 1)"
    assert_contains "$(cat "$out.log")" "would be skipped by the release" "…saying the release would skip it"
    assert_eq "$head|$head" "$(git -C "$dir/clone" rev-parse HEAD)|$(git -C "$dir/origin.git" rev-parse feature)" "…nothing committed or pushed"
    assert_eq "" "$(sed -n 2p "$f" | sed -n '/hash [0-9a-f]\{64\}/p')" "…and the file is not sealed"
  done
  printf '<!-- doc-superpowers:fragment PR-16 -->\n<!-- doc-superpowers:hash -->\n### Added\n- fine\n' > "$f"
  rc=0
  cp_run "$dir/clone" "$out" 16 || rc=$?
  assert_eq "0" "$rc" "a well-formed fragment: committed (log: $(head -c 300 "$out.log"))"
  printf '<!-- doc-superpowers:fragment PR-16 -->\n<!-- doc-superpowers:hash -->\n<!-- doc-superpowers:no-notes -->\n' > "$f"
  rc=0
  cp_run "$dir/clone" "$out" 16 || rc=$?
  assert_eq "0" "$rc" "a no-notes fragment: committed"
}

test_fw_precheck_untagged_release() {
  # P-I2: the latest version in RELEASE-NOTES.md without its tag. The nearest
  # tag (v1.0.0) took the untagged v1.1.0 release's commits for unreleased.
  echo "Test: FW P-I2 precheck.sh — an untagged release is still the last release (the commit that added its heading)"
  local work out rc stub rel
  work=$(new_repo)
  out="$work/gh-output"
  stub=$(harness_mktemp_d dtstub)
  printf '#!/bin/sh\necho "$*" >> "%s/args"\n' "$stub" > "$stub/dt"
  chmod +x "$stub/dt"
  commit_file "$work" RELEASE-NOTES.md $'# Release Notes\n\n## v1.0.0 (2026-01-01)\n\n- first' "release: v1.0.0"
  git -C "$work" tag v1.0.0
  commit_file "$work" a.txt a "feat!: drop the old API"
  commit_file "$work" RELEASE-NOTES.md $'# Release Notes\n\n## v1.1.0 (2026-02-01)\n\n- second\n\n## v1.0.0 (2026-01-01)\n\n- first' "release: v1.1.0"
  rel=$(git -C "$work" rev-parse HEAD)
  rc=0
  ( cd "$work" && DOC_TOOLS="$stub/dt" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=true" "$rc|$(cat "$out")" "HEAD is the untagged v1.1.0 release commit → skip=true"
  assert_contains "$(cat "$out.log")" "v1.1.0" "…naming the release"
  commit_file "$work" b.txt b "fix: b"
  : > "$stub/args"
  rc=0
  ( cd "$work" && DOC_TOOLS="$stub/dt" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=false" "$rc|$(cat "$out")" "one commit after it → skip=false"
  assert_contains "$(cat "$out.log")" "1 commits since v1.1.0" "…one unreleased commit, not the feat! before the release"
  assert_eq "fragments merge $rel HEAD" "$(cat "$stub/args")" "…and fragments merge starts at the release commit (never v1.0.0 or ROOT)"
  # Tagged: the tag wins.
  git -C "$work" tag v1.1.0 "$rel"
  : > "$stub/args"
  ( cd "$work" && DOC_TOOLS="$stub/dt" run_step "$out" "$PRECHECK_SCRIPT" ) || true
  assert_eq "fragments merge v1.1.0 HEAD" "$(cat "$stub/args")" "once tagged, the range starts at the tag"
  # A version heading inside a code fence is not an entry.
  work=$(new_repo)
  commit_file "$work" RELEASE-NOTES.md $'# Release Notes\n\n```\n## v9.9.9\n```' "docs: example"
  commit_file "$work" c.txt c "feat: c"
  : > "$stub/args"
  rc=0
  ( cd "$work" && DOC_TOOLS="$stub/dt" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
  assert_eq "0|skip=false|fragments merge ROOT HEAD" "$rc|$(cat "$out")|$(cat "$stub/args")" \
    "no version entry (a fenced heading is none) and no tag: the first release, from ROOT"
}

test_fw_release_branch_per_attempt() {
  echo "Test: FW 318 doc-release names its branch per run attempt, and the precheck skips a merge of either form"
  local work out rc subj
  assert_true "BRANCH carries github.run_attempt" \
    grep -qF 'BRANCH: doc-superpowers/release-notes-${{ github.run_id }}-${{ github.run_attempt }}' "$TEMPLATE_DIR/doc-release.yml"
  work=$(new_repo)
  out="$work/gh-output"
  for subj in "Merge pull request #12 from octo/doc-superpowers/release-notes-9876-2" \
      "Merge pull request #12 from octo/doc-superpowers/release-notes-9876"; do
    git -C "$work" commit -q --allow-empty -m "$subj"
    rc=0
    ( cd "$work" && DOC_TOOLS="$DOC_TOOLS_SCRIPT" run_step "$out" "$PRECHECK_SCRIPT" ) || rc=$?
    assert_eq "0|skip=true" "$rc|$(cat "$out")" "HEAD '$subj' → skip=true"
  done
}

test_fw_freshness_scope_quoted_names() {
  # S-M1: git quotes a name holding '"', a backslash or a tab even with
  # core.quotePath=false, and a quoted name matches no ref: the doc citing
  # it went unjudged. The scope step lists the change with `git diff -z`.
  echo "Test: FW S-M1 freshness-check.sh scope — a changed file whose name git quotes still reaches the doc citing it"
  local dir out rc base head
  dir=$(installed_repo --ci) || { assert_true "freshness fixture" false; return 0; }
  (
    cd "$dir" || exit 1
    mkdir -p docs src
    echo a > src/a.js
    echo '# A' > docs/a.md
    git add -A && git commit -q -m "base files"
    printf 'docs/a.md:src/:arch\n' | PATH="$BASH_PATH" .github/scripts/doc-tools.sh build-index >/dev/null 2>&1
    PATH="$BASH_PATH" .github/scripts/doc-tools.sh update-index docs/a.md >/dev/null 2>&1
    git add -A && git commit -q -m "base"
    git rev-parse HEAD > .git/fx-base
    echo q > 'src/we"ird.js'
    git add -A && git commit -q -m "head"
    git rev-parse HEAD > .git/fx-head
  ) || { assert_true "freshness fixture commits" false; return 0; }
  base=$(cat "$dir/.git/fx-base")
  head=$(cat "$dir/.git/fx-head")
  out="$(harness_mktemp_d step)/out"
  rc=0
  run_installed "$dir" "$out" RANGE="$base...$head" -- "$FRESHNESS" scope || rc=$?
  assert_eq "0|ok|1" "$rc|$(_out "$out" status)|$(_out "$out" affected)" "src/we\"ird.js changed: docs/a.md (cites src/) is affected"
}

echo
echo "=== Final review fix wave (CI) ==="
test_fw_superseded_fails_for_full_cycle
test_fw_templates_superseded_policy
test_fw_commit_refuses_what_the_release_would_skip
test_fw_precheck_untagged_release
test_fw_release_branch_per_attempt
test_fw_freshness_scope_quoted_names

print_summary

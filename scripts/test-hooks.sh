#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"
DOC_TOOLS="$SCRIPT_DIR/doc-tools.sh"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Build a doc-index for testing. Requires: docs/ and src/ exist with committed files.
build_test_index() {
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
}

# --- pre-commit hook tests ---

test_pre_commit_exits_0_no_index() {
  echo "test: pre-commit exits 0 when no doc-index exists"
  setup
  # No index built — hook should skip silently
  local output exit_code
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with no index"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_exits_0_no_stale() {
  echo "test: pre-commit exits 0 when docs are current"
  setup
  build_test_index
  # Stage a file that is NOT a code_ref for any doc
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with no stale docs"
  teardown
}

test_pre_commit_warns_on_stale() {
  echo "test: pre-commit warns when staged files make docs stale"
  setup
  build_test_index
  # Modify src/ (which is a code_ref) and commit to make docs stale
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  # Now stage another change — docs are now stale relative to code
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (warn mode)"
  assert_contains "$output" "doc-superpowers" "mentions doc-superpowers"
  assert_contains "$output" "stale" "mentions stale"
  teardown
}

test_pre_commit_blocks_in_strict_mode() {
  echo "test: pre-commit exits 1 in strict mode when stale"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_STRICT=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 in strict mode"
  assert_contains "$output" "stale" "mentions stale"
  teardown
}

test_pre_commit_skip_env() {
  echo "test: pre-commit exits 0 when DOC_SUPERPOWERS_SKIP=1"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with SKIP"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_quiet_mode() {
  echo "test: pre-commit suppresses output in quiet mode"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_QUIET=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 in quiet mode"
  assert_eq "" "$output" "produces no output in quiet mode"
  teardown
}

test_pre_commit_exits_0_no_doc_tools() {
  echo "test: pre-commit exits 0 when doc-tools.sh is missing"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="/nonexistent/doc-tools.sh" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with missing doc-tools"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_exits_0_corrupted_index() {
  echo "test: pre-commit exits 0 with corrupted doc-index"
  setup
  echo "NOT VALID JSON{{{" > docs/.doc-index.json
  echo "changed" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with corrupted index"
  teardown
}

echo ""
echo "=== Git Hook: pre-commit ==="
test_pre_commit_exits_0_no_index
test_pre_commit_exits_0_no_stale
test_pre_commit_warns_on_stale
test_pre_commit_blocks_in_strict_mode
test_pre_commit_skip_env
test_pre_commit_quiet_mode
test_pre_commit_exits_0_no_doc_tools
test_pre_commit_exits_0_corrupted_index

# --- post-merge hook tests ---

test_post_merge_silent_no_stale() {
  echo "test: post-merge silent when no stale docs"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

test_post_merge_reports_stale() {
  echo "test: post-merge reports stale docs"
  setup
  build_test_index
  # Make code change to trigger staleness
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale docs"
  assert_contains "$output" "doc-superpowers" "identifies source"
  teardown
}

test_post_merge_skip_env() {
  echo "test: post-merge respects SKIP env"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Git Hook: post-merge ==="
test_post_merge_silent_no_stale
test_post_merge_reports_stale
test_post_merge_skip_env

# --- post-checkout hook tests ---

test_post_checkout_skips_file_checkout() {
  echo "test: post-checkout skips file checkouts (flag=0)"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  # $1=prev_head $2=new_head $3=flag (0=file, 1=branch)
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 0 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent on file checkout"
  teardown
}

test_post_checkout_reports_on_branch_switch() {
  echo "test: post-checkout reports stale on branch switch (flag=1)"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 1 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale docs"
  teardown
}

test_post_checkout_silent_when_current() {
  echo "test: post-checkout silent when docs current"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 1 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

echo ""
echo "=== Git Hook: post-checkout ==="
test_post_checkout_skips_file_checkout
test_post_checkout_reports_on_branch_switch
test_post_checkout_silent_when_current

# --- prepare-commit-msg hook tests ---

test_prepare_commit_msg_appends_stale() {
  echo "test: prepare-commit-msg appends stale doc comments"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  # Create a temp commit message file (git passes this as $1)
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$content" "my commit message" "preserves original message"
  assert_contains "$content" "# Doc freshness" "appends freshness comment"
  assert_contains "$content" "stale" "mentions stale docs"
  teardown
}

test_prepare_commit_msg_skips_when_current() {
  echo "test: prepare-commit-msg does nothing when docs current"
  setup
  build_test_index
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$content" "Doc freshness" "does not append when current"
  teardown
}

test_prepare_commit_msg_skips_no_index() {
  echo "test: prepare-commit-msg skips when no index"
  setup
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$content" "Doc freshness" "does not append without index"
  teardown
}

echo ""
echo "=== Git Hook: prepare-commit-msg ==="
test_prepare_commit_msg_appends_stale
test_prepare_commit_msg_skips_when_current
test_prepare_commit_msg_skips_no_index

# --- pre-push hook tests ---

test_pre_push_silent_few_commits() {
  echo "test: pre-push silent when <=5 commits since tag"
  setup
  git tag v1.0.0
  echo "change" > src/index.js
  git add src/index.js && git commit -m "one change" --quiet
  set +e
  output=$(bash "$HOOKS_DIR/git/pre-push" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with few commits"
  teardown
}

test_pre_push_warns_many_commits() {
  echo "test: pre-push warns when >5 commits since tag"
  setup
  git tag v1.0.0
  for i in $(seq 1 6); do
    echo "change $i" > src/index.js
    git add src/index.js && git commit -m "change $i" --quiet
  done
  set +e
  output=$(bash "$HOOKS_DIR/git/pre-push" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "6 commits since v1.0.0" "reports commit count"
  assert_contains "$output" "release" "suggests release"
  teardown
}

test_pre_push_silent_no_tags() {
  echo "test: pre-push silent when no tags exist"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/git/pre-push" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with no tags"
  teardown
}

test_pre_push_skip_env() {
  echo "test: pre-push respects SKIP"
  setup
  git tag v1.0.0
  for i in $(seq 1 6); do
    echo "change $i" > src/index.js
    git add src/index.js && git commit -m "change $i" --quiet
  done
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 bash "$HOOKS_DIR/git/pre-push" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with SKIP"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Git Hook: pre-push ==="
test_pre_push_silent_few_commits
test_pre_push_warns_many_commits
test_pre_push_silent_no_tags
test_pre_push_skip_env

# --- Claude Code Hook: pre-commit-gate ---

test_claude_gate_skips_non_commit() {
  echo "test: claude pre-commit-gate skips non-commit bash commands"
  setup
  build_test_index
  # Simulate tool input that is NOT a git commit
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"ls -la"}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 for non-commit"
  assert_eq "" "$output" "silent for non-commit"
  teardown
}

test_claude_gate_warns_on_stale_commit() {
  echo "test: claude pre-commit-gate warns when committing with stale docs"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (warn mode)"
  assert_contains "$output" "stale" "warns about stale docs"
  teardown
}

test_claude_gate_blocks_strict() {
  echo "test: claude pre-commit-gate blocks in strict mode"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_STRICT=1 DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 in strict mode"
  teardown
}

test_claude_gate_skip_env() {
  echo "test: claude pre-commit-gate respects SKIP"
  setup
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"test\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Claude Code Hook: pre-commit-gate ==="
test_claude_gate_skips_non_commit
test_claude_gate_warns_on_stale_commit
test_claude_gate_blocks_strict
test_claude_gate_skip_env

# --- Claude Code Hook: session-summary ---

test_session_summary_reports_stale() {
  echo "test: session-summary reports stale docs"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale"
  assert_contains "$output" "doc-superpowers" "identifies source"
  teardown
}

test_session_summary_silent_when_current() {
  echo "test: session-summary silent when docs current"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

test_session_summary_skip_env() {
  echo "test: session-summary respects SKIP"
  setup
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Claude Code Hook: session-summary ==="
test_session_summary_reports_stale
test_session_summary_silent_when_current
test_session_summary_skip_env

# --- Claude Code Hook: post-commit-sync ---

test_post_commit_sync_skips_non_commit() {
  echo "test: post-commit-sync skips non-commit bash commands"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"ls -la"}' bash "$HOOKS_DIR/claude/post-commit-sync.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 for non-commit"
  assert_eq "" "$output" "silent for non-commit"
  teardown
}

test_post_commit_sync_reports_stale_after_commit() {
  echo "test: post-commit-sync reports stale docs after commit"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/post-commit-sync.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "doc-superpowers" "identifies source"
  assert_contains "$output" "update" "suggests update"
  teardown
}

test_post_commit_sync_silent_when_current() {
  echo "test: post-commit-sync silent when docs current"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/post-commit-sync.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # No stale docs, so output should be empty (update-index runs silently)
  assert_eq "" "$output" "silent when current"
  teardown
}

test_post_commit_sync_skip_env() {
  echo "test: post-commit-sync respects SKIP"
  setup
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"test\""}' bash "$HOOKS_DIR/claude/post-commit-sync.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with SKIP"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Claude Code Hook: post-commit-sync ==="
test_post_commit_sync_skips_non_commit
test_post_commit_sync_reports_stale_after_commit
test_post_commit_sync_silent_when_current
test_post_commit_sync_skip_env

# --- Installer tests ---

test_install_git_creates_hooks() {
  echo "test: install --git creates hook files in .git/hooks/"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/pre-commit" "pre-commit installed"
  assert_file_exists ".git/hooks/post-merge" "post-merge installed"
  assert_file_exists ".git/hooks/post-checkout" "post-checkout installed"
  assert_file_exists ".git/hooks/prepare-commit-msg" "prepare-commit-msg installed"
  assert_file_exists ".git/hooks/pre-push" "pre-push installed"
  # Verify marker
  assert_contains "$(head -2 .git/hooks/pre-commit)" "doc-superpowers hook v1" "has marker"
  # Verify DOC_TOOLS path was substituted
  assert_not_contains "$(cat .git/hooks/pre-commit)" "__DOC_TOOLS_PATH__" "path substituted"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-tools.sh" "has real path"
  teardown
}

test_install_git_preserves_existing_hook() {
  echo "test: install --git does not overwrite foreign hooks"
  setup
  printf '#!/bin/bash\necho existing\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$(cat .git/hooks/pre-commit)" "existing" "original preserved"
  assert_contains "$output" "Integrated" "reports integration into existing hook"
  teardown
}

test_install_git_overwrites_own_hook() {
  echo "test: install --git overwrites existing doc-superpowers hooks"
  setup
  mkdir -p .git/hooks
  printf '#!/bin/bash\n# doc-superpowers hook v1\necho old\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "echo old" "old content replaced"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers hook v1" "new marker present"
  teardown
}

test_uninstall_git_removes_hooks() {
  echo "test: uninstall --git removes doc-superpowers hooks"
  setup
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  assert_file_exists ".git/hooks/pre-commit" "hook exists before uninstall"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".git/hooks/pre-commit" "pre-commit removed"
  assert_file_not_exists ".git/hooks/post-merge" "post-merge removed"
  teardown
}

test_uninstall_git_preserves_foreign_hooks() {
  echo "test: uninstall --git preserves foreign hooks"
  setup
  printf '#!/bin/bash\necho foreign\n' > .git/hooks/post-merge
  chmod +x .git/hooks/post-merge
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/post-merge" "foreign hook preserved"
  assert_contains "$(cat .git/hooks/post-merge)" "foreign" "content preserved"
  teardown
}

test_uninstall_git_removes_integrated_hooks() {
  echo "test: uninstall --git cleanly removes integrated hook blocks"
  setup
  # Create a pre-existing hook
  printf '#!/bin/bash\necho "existing pre-commit"\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  # Install (auto-integrates into existing hook)
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  # Verify integration block exists
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers:begin" "begin marker present"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers:end" "end marker present"
  assert_file_exists ".git/hooks/.doc-superpowers-pre-commit" "local hook copy exists"
  # Uninstall
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # Verify clean removal: original hook intact, no orphaned lines
  assert_file_exists ".git/hooks/pre-commit" "original hook preserved"
  assert_contains "$(cat .git/hooks/pre-commit)" "existing pre-commit" "original content intact"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers" "no doc-superpowers lines remain"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "DOC_SP_HOOK" "no DOC_SP_HOOK variable remains"
  assert_file_not_exists ".git/hooks/.doc-superpowers-pre-commit" "local hook copy removed"
  teardown
}

test_install_claude_creates_settings() {
  echo "test: install --claude creates settings and copies scripts"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".claude/settings.local.json" "settings file created"
  assert_file_exists ".claude/hooks/doc-superpowers/pre-commit-gate.sh" "pre-commit-gate script copied"
  assert_file_exists ".claude/hooks/doc-superpowers/post-commit-sync.sh" "post-commit-sync script copied"
  assert_file_exists ".claude/hooks/doc-superpowers/session-summary.sh" "session-summary script copied"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_contains "$settings" "PreToolUse" "has PreToolUse hook"
  assert_contains "$settings" "PostToolUse" "has PostToolUse hook"
  assert_contains "$settings" "Stop" "has Stop hook"
  assert_contains "$settings" "pre-commit-gate" "has pre-commit-gate"
  assert_contains "$settings" "post-commit-sync" "has post-commit-sync"
  assert_contains "$settings" "session-summary" "has session-summary"
  # Verify hooks array structure (not flat command)
  assert_contains "$settings" '"hooks"' "uses hooks array format"
  assert_contains "$settings" '"type"' "has type field"
  assert_contains "$settings" '"matcher"' "has matcher field"
  # Verify relative paths (not absolute)
  assert_contains "$settings" ".claude/hooks/doc-superpowers/" "uses relative path"
  assert_not_contains "$settings" "/Users/" "no absolute home path"
  # Verify placeholder substitution in copied scripts
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__DOC_TOOLS_PATH__" "DOC_TOOLS path substituted"
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__INSTALL_DATE__" "install date substituted"
  teardown
}

test_install_claude_preserves_existing() {
  echo "test: install --claude preserves existing settings"
  setup
  mkdir -p .claude
  echo '{"permissions":{"allow":["Read"]}}' > .claude/settings.local.json
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_contains "$settings" "permissions" "preserves existing"
  assert_contains "$settings" "PreToolUse" "adds hooks"
  teardown
}

test_uninstall_claude_removes_hooks() {
  echo "test: uninstall --claude removes hooks and copied scripts"
  setup
  bash "$HOOKS_DIR/install.sh" install --claude >/dev/null 2>&1
  assert_file_exists ".claude/hooks/doc-superpowers/pre-commit-gate.sh" "script exists before uninstall"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_not_contains "$settings" "pre-commit-gate" "hooks removed from settings"
  assert_not_contains "$settings" "PostToolUse" "PostToolUse removed from settings"
  assert_file_not_exists ".claude/hooks/doc-superpowers/pre-commit-gate.sh" "script removed"
  assert_file_not_exists ".claude/hooks/doc-superpowers/post-commit-sync.sh" "script removed"
  assert_file_not_exists ".claude/hooks/doc-superpowers/session-summary.sh" "script removed"
  teardown
}

test_install_ci_creates_workflows() {
  echo "test: install --ci creates workflow files"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "PR workflow"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "schedule workflow"
  assert_file_exists ".github/workflows/doc-index-update.yml" "index workflow"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__BASE_BRANCH__" "base branch substituted"
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__VERSION__" "version substituted"
  assert_not_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "__CRON_SCHEDULE__" "cron schedule substituted"
  teardown
}

test_install_ci_with_custom_base_branch() {
  echo "test: install --ci --base-branch substitutes custom branch"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci --base-branch develop 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local pr_workflow
  pr_workflow=$(cat .github/workflows/doc-freshness-pr.yml)
  assert_contains "$pr_workflow" "develop" "base branch substituted"
  assert_not_contains "$pr_workflow" "__BASE_BRANCH__" "placeholder removed"
  teardown
}

test_install_ci_with_custom_cron() {
  echo "test: install --ci --cron substitutes custom schedule"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci --cron '0 12 * * *' 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local schedule_workflow
  schedule_workflow=$(cat .github/workflows/doc-freshness-schedule.yml)
  assert_contains "$schedule_workflow" "0 12 * * *" "custom cron substituted"
  assert_not_contains "$schedule_workflow" "__CRON_SCHEDULE__" "placeholder removed"
  teardown
}

test_install_ci_strict_enables_strict() {
  echo "test: install --ci --ci-strict sets strict mode in workflow"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci --ci-strict 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local pr_workflow
  pr_workflow=$(cat .github/workflows/doc-freshness-pr.yml)
  assert_contains "$pr_workflow" 'DOC_SUPERPOWERS_STRICT: "1"' "strict mode enabled"
  assert_not_contains "$pr_workflow" "__CI_STRICT__" "placeholder removed"
  teardown
}

test_install_ci_default_strict_disabled() {
  echo "test: install --ci without --ci-strict defaults to non-strict"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local pr_workflow
  pr_workflow=$(cat .github/workflows/doc-freshness-pr.yml)
  assert_contains "$pr_workflow" 'DOC_SUPERPOWERS_STRICT: "0"' "strict mode disabled by default"
  teardown
}

test_install_ci_creates_claude_powered_workflows() {
  echo "test: install --ci creates Claude-powered workflow files"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-audit-update.yml" "audit-update workflow"
  assert_file_exists ".github/workflows/doc-review-pr.yml" "review-pr workflow"
  assert_file_exists ".github/workflows/doc-release.yml" "release workflow"
  assert_file_exists ".github/workflows/doc-spec-verify.yml" "spec-verify workflow"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-audit-update.yml)" "__BASE_BRANCH__" "base branch substituted in audit-update"
  assert_not_contains "$(cat .github/workflows/doc-audit-update.yml)" "__VERSION__" "version substituted in audit-update"
  assert_not_contains "$(cat .github/workflows/doc-review-pr.yml)" "__BASE_BRANCH__" "base branch substituted in review-pr"
  assert_not_contains "$(cat .github/workflows/doc-release.yml)" "__VERSION__" "version substituted in release"
  assert_not_contains "$(cat .github/workflows/doc-spec-verify.yml)" "__BASE_BRANCH__" "base branch substituted in spec-verify"
  teardown
}

test_install_ci_claude_workflows_have_marker() {
  echo "test: Claude-powered workflows start with workflow marker"
  setup
  for template in doc-audit-update.yml doc-review-pr.yml doc-release.yml doc-spec-verify.yml; do
    local first_line
    first_line=$(head -1 "$HOOKS_DIR/ci/$template")
    assert_contains "$first_line" "doc-superpowers workflow v1" "marker in $template"
  done
  teardown
}

test_install_ci_claude_workflows_reference_api_key() {
  echo "test: Claude-powered workflows reference ANTHROPIC_API_KEY"
  setup
  for template in doc-audit-update.yml doc-review-pr.yml doc-release.yml doc-spec-verify.yml; do
    assert_contains "$(cat "$HOOKS_DIR/ci/$template")" "ANTHROPIC_API_KEY" "API key in $template"
  done
  teardown
}

test_install_ci_api_key_message() {
  echo "test: install --ci prints API key message for Claude-powered workflows"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "ANTHROPIC_API_KEY" "API key reminder shown"
  teardown
}

test_uninstall_ci_removes_claude_workflows() {
  echo "test: uninstall --ci removes Claude-powered workflows"
  setup
  bash "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  assert_file_exists ".github/workflows/doc-audit-update.yml" "installed first"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".github/workflows/doc-audit-update.yml" "audit-update removed"
  assert_file_not_exists ".github/workflows/doc-review-pr.yml" "review-pr removed"
  assert_file_not_exists ".github/workflows/doc-release.yml" "release removed"
  assert_file_not_exists ".github/workflows/doc-spec-verify.yml" "spec-verify removed"
  teardown
}

test_uninstall_no_flags_non_tty_fails() {
  echo "test: uninstall without flags in non-TTY context exits 1"
  setup
  bash "$HOOKS_DIR/install.sh" install --all >/dev/null 2>&1
  set +e
  output=$(echo "" | bash "$HOOKS_DIR/install.sh" uninstall 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 without tier flags"
  assert_contains "$output" "specify tier flags" "shows error message"
  teardown
}

test_status_reports_installed() {
  echo "test: status reports installed hooks"
  setup
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" status 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "pre-commit" "shows pre-commit"
  assert_contains "$output" "installed" "shows installed status"
  teardown
}

test_status_reports_not_installed() {
  echo "test: status reports when nothing installed"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" status 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "not installed" "shows not installed"
  teardown
}

test_install_all_installs_git_and_claude_and_ci() {
  echo "test: install --all installs all tiers"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --all 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/pre-commit" "git tier"
  assert_file_exists ".claude/settings.local.json" "claude tier"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "ci tier"
  teardown
}

test_install_no_git_dir() {
  echo "test: install --git fails when not a git repo"
  local tmpdir
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "not a git repo" "error message"
  cd /
  rm -rf "$tmpdir"
}

test_no_args_prints_usage() {
  echo "test: no args prints usage"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "Usage" "prints usage"
  teardown
}

test_install_git_core_hookspath() {
  echo "test: install --git respects core.hooksPath"
  setup
  mkdir -p .custom-hooks
  git config core.hooksPath .custom-hooks
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".custom-hooks/pre-commit" "hook in custom dir"
  assert_file_not_exists ".git/hooks/pre-commit" "not in default dir"
  assert_contains "$output" ".custom-hooks" "reports custom dir"
  teardown
}

test_install_git_core_hookspath_creates_dir() {
  echo "test: install --git creates core.hooksPath dir if missing"
  setup
  git config core.hooksPath .nonexistent-hooks
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".nonexistent-hooks/pre-commit" "hook in created dir"
  teardown
}

test_install_git_githooks_dir() {
  echo "test: install --git uses .githooks/ when present"
  setup
  mkdir -p .githooks
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".githooks/pre-commit" "hook in .githooks"
  assert_contains "$output" ".githooks" "reports .githooks dir"
  teardown
}

test_install_git_idempotent() {
  echo "test: install --git twice is idempotent"
  setup
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 on reinstall"
  assert_file_exists ".git/hooks/pre-commit" "hook still exists"
  assert_contains "$(head -2 .git/hooks/pre-commit)" "doc-superpowers hook v1" "marker intact"
  teardown
}

test_integration_does_not_terminate_parent() {
  echo "test: integrated hook does not terminate parent hook"
  setup
  # Create a parent hook with code after the integration point
  printf '#!/bin/bash\necho "before"\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  # Install (will integrate via bash subprocess)
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  # Run the parent hook — code before exit 0 should still execute
  set +e
  output=$(bash .git/hooks/pre-commit 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "parent hook exits 0"
  assert_contains "$output" "before" "parent code runs"
  teardown
}

test_base_branch_missing_value() {
  echo "test: --base-branch without value gives clear error"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci --base-branch 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "--base-branch requires a value" "clear error message"
  teardown
}

test_cron_missing_value() {
  echo "test: --cron without value gives clear error"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci --cron 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "--cron requires a value" "clear error message"
  teardown
}

echo ""
echo "=== Installer ==="
test_install_git_creates_hooks
test_install_git_preserves_existing_hook
test_install_git_overwrites_own_hook
test_uninstall_git_removes_hooks
test_uninstall_git_preserves_foreign_hooks
test_uninstall_git_removes_integrated_hooks
test_install_claude_creates_settings
test_install_claude_preserves_existing
test_uninstall_claude_removes_hooks
test_install_ci_creates_workflows
test_install_ci_with_custom_base_branch
test_install_ci_with_custom_cron
test_install_ci_strict_enables_strict
test_install_ci_default_strict_disabled
test_install_ci_creates_claude_powered_workflows
test_install_ci_claude_workflows_have_marker
test_install_ci_claude_workflows_reference_api_key
test_install_ci_api_key_message
test_uninstall_ci_removes_claude_workflows
test_uninstall_no_flags_non_tty_fails
test_status_reports_installed
test_status_reports_not_installed
test_install_all_installs_git_and_claude_and_ci
test_install_no_git_dir
test_no_args_prints_usage
test_install_git_core_hookspath
test_install_git_core_hookspath_creates_dir
test_install_git_githooks_dir
test_install_git_idempotent
test_integration_does_not_terminate_parent
test_base_branch_missing_value
test_cron_missing_value

print_summary

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Shimmed so that BOTH this suite's direct calls and the hooks' own
# `"$DOC_TOOLS"` invocations run under $BASH_BIN. See bash_bin_shim().
DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"

# Build a doc-index for testing. Requires: docs/ and src/ exist with committed files.
build_test_index() {
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
}

# --- Real hook contracts ------------------------------------------------------
#
# The hooks are driven the way their callers drive them, never as templates
# with an injected environment:
#   - the git hooks by git itself: `git commit`, `git merge`, `git checkout`
#     run the copies the installer put in .git/hooks, with git's own
#     arguments, stdin and GIT_INDEX_FILE;
#   - the Claude Code hooks through the command string the installer
#     registered in .claude/settings.local.json, run as Claude Code runs a
#     command hook: `sh -c <command>`, the event as JSON on stdin, TOOL_INPUT
#     unset, cwd the project.
# Both start `bash` by name (`#!/usr/bin/env bash`, `bash -c`), so PATH begins
# with a directory whose `bash` is $BASH_BIN, the interpreter under test.
_REAL_BIN="$_SHIM_DIR/realbin"
mkdir -p "$_REAL_BIN"
ln -s "$(type -P "$BASH_BIN" || printf '%s' "$BASH_BIN")" "$_REAL_BIN/bash"
REAL_PATH="$_REAL_BIN:$PATH"

# Install the git and Claude tiers into the current fixture (or only the tiers
# named), keeping what the installer writes out of the fixture's commits.
install_tiers() {
  [ "$#" -gt 0 ] || set -- --git --claude
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" install "$@" >/dev/null 2>&1 \
    || { echo "install_tiers: installer failed" >&2; return 1; }
  printf '.claude/\n.gitattributes\n' >> .git/info/exclude
}

# A fixture whose doc cites <refs> (default src/), verified and committed, so
# the tree is clean and the doc current; src/util.js exists for file refs.
# Then the git and Claude tiers are installed.
hooked_fixture() {
  setup
  echo "util" > src/util.js
  git add src/util.js && git commit -qm "util"
  echo "docs/architecture.md:${1:-src/}:architecture" | "$DOC_TOOLS" build-index >/dev/null 2>&1
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  git add docs/.doc-index.json && git commit -qm "index"
  install_tiers
}

# run_hooked [VAR=value ...] -- <command...>
# Run <command> in the fixture with the environment the installed hooks see:
# DOC_TOOLS and PATH as above (a VAR=value pair overrides them; DOC_TOOLS=
# makes a hook resolve doc-tools.sh itself), TOOL_INPUT unset, stdin from the
# file $RUN_STDIN. Sets RUN_RC, RUN_OUT (stdout) and RUN_ERR (stderr).
RUN_STDIN=/dev/null
run_hooked() {
  local errf envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  errf=$(harness_mktemp run.err)
  RUN_RC=0
  RUN_OUT=$(
    unset TOOL_INPUT
    env DOC_TOOLS="$DOC_TOOLS" PATH="$REAL_PATH" ${envs[@]+"${envs[@]}"} "$@" <"$RUN_STDIN" 2>"$errf"
  ) || RUN_RC=$?
  RUN_ERR=$(cat "$errf")
  rm -f "$errf"
}

# The command the installer registered for <event> whose script is <name>.
registered_cmd() {
  jq -r --arg e "$1" --arg s "$2" \
    '[.hooks[$e][]?.hooks[]? | select(.command | contains($s)) | .command][0] // empty' \
    .claude/settings.local.json
}

# run_claude_hook <event> <script> <payload-json> [VAR=value ...]
run_claude_hook() {
  local event="$1" script="$2" payload="$3" cmd
  shift 3
  cmd=$(registered_cmd "$event" "$script")
  if [ -z "$cmd" ]; then
    RUN_RC=99 RUN_OUT="" RUN_ERR="no $event hook registered for $script"
    return 0
  fi
  RUN_STDIN=$(harness_mktemp payload)
  printf '%s' "$payload" > "$RUN_STDIN"
  run_hooked CLAUDE_PROJECT_DIR="$TEST_DIR" ${1+"$@"} -- sh -c "$cmd"
  rm -f "$RUN_STDIN"
  RUN_STDIN=/dev/null
}

pretool_json() {
  jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}
posttool_json() {
  jq -cn --arg c "$1" '{session_id: "t", hook_event_name: "PostToolUse", tool_name: "Bash",
    tool_input: {command: $c}, tool_response: {stdout: "", stderr: "", interrupted: false}}'
}
STOP_JSON='{"session_id":"t","hook_event_name":"Stop","stop_hook_active":false}'

# Non-empty lines in $1.
line_count() {
  awk 'NF { n++ } END { print n + 0 }' <<<"$1"
}

# A PATH without jq — the launchd PATH macOS (<= 14) GUI git clients run hooks
# with — holding every other tool the hooks and doc-tools.sh call.
make_nojq_path() {
  local dir t p
  dir=$(harness_mktemp_d nojq)
  ln -s "$(type -P "$BASH_BIN" || printf '%s' "$BASH_BIN")" "$dir/bash"
  for t in sh env git awk sed gsed tr sort tail head cat cut wc grep mktemp rm cp mv \
    mkdir ln date dirname basename xargs shasum sha256sum uname sleep ls readlink chmod \
    find expr tee touch kill; do
    p=$(type -P "$t" 2>/dev/null) || continue
    [ -e "$dir/$t" ] || ln -s "$p" "$dir/$t"
  done
  printf '%s' "$dir"
}

# --- pre-commit hook tests ---

test_pre_commit_exits_0_no_index() {
  echo "test: pre-commit exits 0 when no doc-index exists"
  setup
  # No index built — hook should skip silently
  local output exit_code
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_SUPERPOWERS_STRICT=1 DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_SUPERPOWERS_QUIET=1 DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
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
  output=$(DOC_TOOLS="/nonexistent/doc-tools.sh" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with missing doc-tools"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_exits_0_corrupted_index() {
  echo "test: pre-commit exits 0 with corrupted doc-index, but says the check failed"
  setup
  echo "NOT VALID JSON{{{" > docs/.doc-index.json
  echo "changed" > src/index.js
  git add src/index.js
  local errf
  errf=$(harness_mktemp err)
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/pre-commit" 2>"$errf")
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with corrupted index"
  assert_eq "1" "$(line_count "$(cat "$errf")")" "one stderr line: tooling failing is not tooling absent"
  assert_contains "$(cat "$errf")" "doc-superpowers" "the line names its source"
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
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-merge" 2>&1)
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
  # The hook scopes to ORIG_HEAD..HEAD, so a real merge must bring in the
  # code change. Change src/ on a feature branch and merge it (git merge
  # sets ORIG_HEAD), making the src/-referencing doc stale within the range.
  base=$(git rev-parse --abbrev-ref HEAD)
  git checkout -b feature --quiet
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  git checkout "$base" --quiet
  git merge --no-ff feature -m "merge feature" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale docs"
  assert_contains "$output" "doc-superpowers" "identifies source"
  teardown
}

test_post_merge_silent_when_merge_untouched_code() {
  echo "test: post-merge silent when merge changed no referenced code"
  setup
  build_test_index
  # Merge brings in only an unrelated file — scoped check finds nothing stale.
  base=$(git rev-parse --abbrev-ref HEAD)
  git checkout -b feature --quiet
  echo "unrelated" > unrelated.txt
  git add unrelated.txt && git commit -m "unrelated" --quiet
  git checkout "$base" --quiet
  git merge --no-ff feature -m "merge feature" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent — merge touched no referenced code"
  teardown
}

test_post_merge_skip_env() {
  echo "test: post-merge respects SKIP env"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-merge" 2>&1)
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
test_post_merge_silent_when_merge_untouched_code
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
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-checkout" abc123 def456 0 2>&1)
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
  # The hook scopes to the diff between the two checked-out revisions ($1,$2),
  # so pass the real prev/new SHAs spanning the src/ change.
  prev=$(git rev-parse HEAD)
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  new=$(git rev-parse HEAD)
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-checkout" "$prev" "$new" 1 2>&1)
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
  output=$(DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/post-checkout" abc123 def456 1 2>&1)
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
  DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
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
  DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
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
  DOC_TOOLS="$DOC_TOOLS" "$BASH_BIN" "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
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

# git feeds pre-push one "<local ref> <local oid> <remote ref> <remote oid>"
# line per ref being pushed; the reminder is about what is pushed, not HEAD.
ZERO_OID=0000000000000000000000000000000000000000
# push_line <local-branch> → the stdin line pushing that branch to origin.
push_line() {
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$(git rev-parse "$1")" "$1" "$ZERO_OID"
}
# run_pre_push <stdin-text> [VAR=value ...]
run_pre_push() {
  local text="$1"
  shift
  RUN_STDIN=$(harness_mktemp push)
  printf '%s' "$text" > "$RUN_STDIN"
  run_hooked ${1+"$@"} -- "$BASH_BIN" "$HOOKS_DIR/git/pre-push" origin https://example.invalid/r.git
  rm -f "$RUN_STDIN"
  RUN_STDIN=/dev/null
}

commit_n() {
  local i
  for i in $(seq 1 "$1"); do
    echo "change $i" > src/index.js
    git add src/index.js && git commit -m "change $i" --quiet
  done
}

test_pre_push_silent_few_commits() {
  echo "test: pre-push silent when <=5 commits since tag"
  setup
  git tag v1.0.0
  commit_n 1
  run_pre_push "$(push_line main)"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with few commits"
  teardown
}

test_pre_push_warns_many_commits() {
  echo "test: pre-push warns when >5 commits since tag"
  setup
  git tag v1.0.0
  commit_n 6
  run_pre_push "$(push_line main)"
  assert_eq "0" "$RUN_RC" "always exits 0"
  assert_contains "$RUN_OUT" "6 commits since v1.0.0" "reports commit count"
  assert_contains "$RUN_OUT" "release" "suggests release"
  teardown
}

test_pre_push_silent_no_tags() {
  echo "test: pre-push silent when no tags exist"
  setup
  run_pre_push "$(push_line main)"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with no tags"
  teardown
}

test_pre_push_skip_env() {
  echo "test: pre-push respects SKIP"
  setup
  git tag v1.0.0
  commit_n 6
  run_pre_push "$(push_line main)" DOC_SUPERPOWERS_SKIP=1
  assert_eq "0" "$RUN_RC" "exits 0 with SKIP"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with SKIP"
  teardown
}

test_pre_push_reads_pushed_refs() {
  echo "test: pre-push counts the commits of the refs being pushed (stdin), not HEAD"
  setup
  git tag v1.0.0
  git checkout -q -b feature
  commit_n 6
  git checkout -q main
  commit_n 1
  run_pre_push "$(push_line feature)"
  assert_contains "$RUN_OUT" "6 commits since v1.0.0" "the pushed branch's 6 commits, although HEAD has 1"
  run_pre_push "$(push_line main)"
  assert_eq "" "$RUN_OUT$RUN_ERR" "pushing main (1 commit since the tag) is silent, although feature has 6"
  run_pre_push "refs/heads/feature $ZERO_OID refs/heads/feature $(git rev-parse feature)"
  assert_eq "" "$RUN_OUT$RUN_ERR" "a branch deletion (null local oid) is silent"
  run_pre_push ""
  assert_eq "0" "$RUN_RC" "nothing pushed: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "nothing pushed: silent"
  teardown
}

test_pre_push_silent_without_doc_tools() {
  echo "test: pre-push is silent when doc-tools.sh is absent (the skill was removed)"
  setup
  git tag v1.0.0
  commit_n 6
  run_pre_push "$(push_line main)" DOC_TOOLS=/nonexistent/doc-tools.sh
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "tooling absent: silent"
  teardown
}

echo ""
echo "=== Git Hook: pre-push ==="
test_pre_push_silent_few_commits
test_pre_push_warns_many_commits
test_pre_push_silent_no_tags
test_pre_push_skip_env
test_pre_push_reads_pushed_refs
test_pre_push_silent_without_doc_tools

# --- Claude Code hooks: the real contract ---
#
# Every test below drives the INSTALLED copy through the command the installer
# REGISTERED, with the event JSON on stdin and TOOL_INPUT unset (run_claude_hook).
# The earlier tests injected a TOOL_INPUT variable Claude Code never sets, so
# they passed while the gate and the sync hook never fired.

# Stage a change under src/: the doc citing src/ is stale in the staged tree.
stage_stale_change() {
  echo "changed ${1:-}" > src/index.js
  git add src/index.js
}

# The JSON field <jq-path> of $RUN_OUT ("" when stdout is not JSON).
out_field() {
  jq -r "$1 // empty" <<<"$RUN_OUT" 2>/dev/null || true
}

test_claude_gate_skips_non_commit() {
  echo "test: claude pre-commit-gate skips non-commit bash commands"
  hooked_fixture
  stage_stale_change
  local c
  for c in 'ls -la' 'git commit-graph write' 'git log --oneline -1' 'git status'; do
    run_claude_hook PreToolUse pre-commit-gate "$(pretool_json "$c")" DOC_SUPERPOWERS_STRICT=1
    assert_eq "0" "$RUN_RC" "'$c': exits 0, even under STRICT"
    assert_eq "" "$RUN_OUT$RUN_ERR" "'$c': silent"
  done
  teardown
}

test_claude_gate_reports_through_json() {
  echo "test: claude pre-commit-gate reads the PreToolUse JSON on stdin and reports through its JSON channels"
  hooked_fixture
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
  assert_eq "0" "$RUN_RC" "exits 0 (advisory)"
  assert_json_field "$RUN_OUT" '.hookSpecificOutput.hookEventName' "PreToolUse" "stdout is one PreToolUse hookSpecificOutput object"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "additionalContext (read by Claude) names the stale doc"
  assert_contains "$(out_field .systemMessage)" "stale" "systemMessage (shown to the user) says stale"
  teardown
}

test_claude_gate_blocks_strict() {
  echo "test: claude pre-commit-gate blocks under STRICT: exit 2 with the reason on stderr"
  hooked_fixture
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "exits 2 in strict mode"
  assert_contains "$RUN_ERR" "docs/architecture.md" "stderr (fed to Claude) names the stale doc"
  assert_contains "$RUN_ERR" "stale" "stderr says why"
  teardown
}

test_claude_gate_matches_git_options() {
  echo "test: claude pre-commit-gate recognizes 'git -C <dir> commit' and 'git -c k=v commit'"
  hooked_fixture
  stage_stale_change
  local c
  for c in 'git -C . commit -m x' 'git -c user.name=t commit -m x' 'cd . && git commit -m x'; do
    run_claude_hook PreToolUse pre-commit-gate "$(pretool_json "$c")" DOC_SUPERPOWERS_STRICT=1
    assert_eq "2" "$RUN_RC" "'$c': gated (exit 2 under STRICT)"
  done
  teardown
}

test_claude_gate_silent_when_current() {
  echo "test: claude pre-commit-gate is silent when the staged tree leaves every doc current"
  hooked_fixture
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent"
  teardown
}

test_claude_gate_skip_env() {
  echo "test: claude pre-commit-gate respects SKIP"
  hooked_fixture
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_SKIP=1 DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with SKIP"
  teardown
}

test_claude_gate_defers_commands_that_stage() {
  echo "test: claude pre-commit-gate defers 'git add … && git commit' / 'commit -a' to the git pre-commit hook"
  hooked_fixture
  echo "changed" > src/index.js   # not staged: the gate cannot see it before the command runs
  local c ctx
  for c in 'git add -A && git commit -m x' 'git commit -am x' 'git commit -a -m x' \
    'git commit -m x -- src/index.js' 'bash scripts/doc-tools.sh update-index docs/a.md && git commit -m x'; do
    run_claude_hook PreToolUse pre-commit-gate "$(pretool_json "$c")" DOC_SUPERPOWERS_STRICT=1
    ctx=$(out_field .hookSpecificOutput.additionalContext)
    assert_eq "0" "$RUN_RC" "'$c': the gate does not decide (it cannot see the commit yet)"
    assert_contains "$ctx" "git pre-commit hook" "'$c': it says the git pre-commit hook decides"
    assert_not_contains "$RUN_OUT$RUN_ERR" "current" "'$c': never a false 'all current'"
  done
  # …and the installed git pre-commit hook does decide, on the real index.
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- sh -c 'git add -A && git commit -qm x'
  assert_eq "1" "$RUN_RC" "'git add -A && git commit': blocked by the git pre-commit hook under STRICT"
  assert_contains "$RUN_ERR" "docs/architecture.md" "the git hook names the stale doc"
  git reset -q
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qam x
  assert_eq "1" "$RUN_RC" "'git commit -am': blocked by the git pre-commit hook under STRICT"
  assert_contains "$RUN_ERR" "docs/architecture.md" "the git hook names the stale doc"
  teardown
}

test_claude_gate_defer_without_git_tier() {
  echo "test: claude pre-commit-gate warns when no git pre-commit hook will check a staging commit"
  hooked_fixture
  rm -f .git/hooks/pre-commit
  echo "changed" > src/index.js
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "no doc-superpowers git pre-commit hook" "context: nothing will check this commit"
  assert_contains "$(out_field .systemMessage)" "no doc-superpowers git pre-commit hook" "STRICT: the user is told too"
  teardown
}

test_claude_gate_jq_missing() {
  echo "test: claude pre-commit-gate with jq missing from PATH prints one line instead of passing silently"
  hooked_fixture
  stage_stale_change
  local nojq
  nojq=$(make_nojq_path)
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" PATH="$nojq"
  assert_eq "0" "$RUN_RC" "exits 0 (not STRICT)"
  assert_eq "1" "$(line_count "$RUN_ERR")" "one stderr line"
  assert_contains "$RUN_ERR" "jq" "it names jq"
  assert_contains "$(out_field .systemMessage)" "jq" "and the user sees it (systemMessage)"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" PATH="$nojq" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "STRICT: a check that cannot run blocks"
  assert_contains "$RUN_ERR" "jq" "STRICT: the reason names jq"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'ls -la')" PATH="$nojq"
  assert_eq "" "$RUN_OUT$RUN_ERR" "a non-commit command stays silent"
  teardown
}

test_claude_gate_tests_command_before_resolving_doc_tools() {
  echo "test: claude pre-commit-gate decides 'not a commit' before resolving doc-tools.sh"
  hooked_fixture
  local probe log
  probe=$(harness_mktemp_d probe)
  log="$probe/sort.log"
  printf '#!/bin/sh\necho called >> "%s"\nexec "%s" "$@"\n' "$log" "$(type -P sort)" > "$probe/sort"
  chmod +x "$probe/sort"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'ls -la')" DOC_TOOLS= PATH="$probe:$REAL_PATH"
  assert_file_not_exists "$log" "no doc-tools.sh resolution for a non-commit command"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS= PATH="$probe:$REAL_PATH"
  assert_file_exists "$log" "a commit does resolve it (the probe is live)"
  teardown
}

echo ""
echo "=== Claude Code Hook: pre-commit-gate ==="
test_claude_gate_skips_non_commit
test_claude_gate_reports_through_json
test_claude_gate_blocks_strict
test_claude_gate_matches_git_options
test_claude_gate_silent_when_current
test_claude_gate_skip_env
test_claude_gate_defers_commands_that_stage
test_claude_gate_defer_without_git_tier
test_claude_gate_jq_missing
test_claude_gate_tests_command_before_resolving_doc_tools

# --- Claude Code Hook: session-summary (Stop) ---
#
# Stop fires every time Claude finishes a response, not at session end, so the
# hook is scoped to the working tree's changes (tracked and untracked) and
# judges them as the working tree holds them.

test_session_summary_reports_working_tree_staleness() {
  echo "test: session-summary reports docs whose code changed in the working tree (systemMessage)"
  hooked_fixture
  echo "changed" > src/index.js
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "0" "$RUN_RC" "always exits 0"
  assert_contains "$(out_field .systemMessage)" "docs/architecture.md" "systemMessage names the doc"
  assert_not_contains "$RUN_OUT" "session ending" "does not claim the session is ending"
  teardown
}

test_session_summary_untracked_file_in_scope() {
  echo "test: session-summary counts an untracked file under a doc's ref"
  hooked_fixture
  echo "new" > src/new.js
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_contains "$(out_field .systemMessage)" "docs/architecture.md" "an untracked src/new.js makes the src/ doc stale"
  teardown
}

test_session_summary_silent_when_tree_clean() {
  echo "test: session-summary is silent on a clean working tree, even with a doc stale at HEAD"
  hooked_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent: nothing changed in the working tree"
  teardown
}

test_session_summary_silent_after_reverify() {
  echo "test: session-summary is silent once the changed code's doc is re-verified in the working tree"
  hooked_fixture
  echo "changed" > src/index.js
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent: the doc was verified against this working tree"
  teardown
}

test_session_summary_skip_env() {
  echo "test: session-summary respects SKIP"
  hooked_fixture
  echo "changed" > src/index.js
  run_claude_hook Stop session-summary "$STOP_JSON" DOC_SUPERPOWERS_SKIP=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with SKIP"
  teardown
}

test_session_summary_timeout_note() {
  echo "test: session-summary gives up after its budget with a one-line note, and kills the whole check"
  hooked_fixture
  echo "changed" > src/index.js
  local stubdir start elapsed pid gone i
  stubdir=$(harness_mktemp_d slow)
  printf '#!/bin/sh\nsleep 30 &\necho $! > "%s/child.pid"\nwait\n' "$stubdir" > "$stubdir/doc-tools.sh"
  chmod +x "$stubdir/doc-tools.sh"
  start=$SECONDS
  run_claude_hook Stop session-summary "$STOP_JSON" DOC_TOOLS="$stubdir/doc-tools.sh"
  elapsed=$((SECONDS - start))
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "1" "$(line_count "$(out_field .systemMessage)")" "a one-line note"
  assert_contains "$(out_field .systemMessage)" "longer than" "it says the check ran out of time"
  assert_true "returns within its budget, not the check's 30 s (took ${elapsed}s)" test "$elapsed" -lt 10
  pid=$(cat "$stubdir/child.pid" 2>/dev/null || echo "")
  gone=no
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then gone=yes; break; fi
    sleep 0.2
  done
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  assert_eq "yes" "$gone" "the check's own children are killed too (process group)"
  teardown
}

test_session_summary_releases_output_promptly() {
  echo "test: session-summary does not hold its output open for the timeout watchdog"
  hooked_fixture
  echo "changed" > src/index.js
  local start elapsed
  start=$SECONDS
  run_claude_hook Stop session-summary "$STOP_JSON"
  elapsed=$((SECONDS - start))
  assert_contains "$(out_field .systemMessage)" "docs/architecture.md" "the check completed"
  assert_true "done well inside the budget (took ${elapsed}s)" test "$elapsed" -lt 2
  teardown
}

echo ""
echo "=== Claude Code Hook: session-summary ==="
test_session_summary_reports_working_tree_staleness
test_session_summary_untracked_file_in_scope
test_session_summary_silent_when_tree_clean
test_session_summary_silent_after_reverify
test_session_summary_skip_env
test_session_summary_timeout_note
test_session_summary_releases_output_promptly

# --- Claude Code Hook: post-commit-sync (PostToolUse) ---

test_post_commit_sync_skips_non_commit() {
  echo "test: post-commit-sync skips non-commit bash commands"
  hooked_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'ls -la')"
  assert_eq "0" "$RUN_RC" "exits 0 for non-commit"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent for non-commit"
  teardown
}

test_post_commit_sync_reports_stale_after_commit() {
  echo "test: post-commit-sync reports the docs the commit left stale, through its JSON channels"
  hooked_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')"
  assert_eq "0" "$RUN_RC" "always exits 0"
  assert_json_field "$RUN_OUT" '.hookSpecificOutput.hookEventName' "PostToolUse" "stdout is one PostToolUse hookSpecificOutput object"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "additionalContext names the doc"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "update" "and suggests updating it"
  assert_contains "$(out_field .systemMessage)" "stale" "systemMessage tells the user"
  teardown
}

test_post_commit_sync_silent_when_current() {
  echo "test: post-commit-sync silent when the commit left every doc current"
  hooked_fixture
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  DOC_SUPERPOWERS_SKIP=1 git commit -qm "unrelated"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -m unrelated')"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent when current"
  teardown
}

test_post_commit_sync_skip_env() {
  echo "test: post-commit-sync respects SKIP"
  hooked_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')" DOC_SUPERPOWERS_SKIP=1
  assert_eq "0" "$RUN_RC" "exits 0 with SKIP"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent with SKIP"
  teardown
}

test_post_commit_sync_root_commit() {
  echo "test: post-commit-sync handles a repository's first commit (git diff-tree --root)"
  setup
  rm -rf .git
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  printf 'home/\nxdg/\n' >> .git/info/exclude
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index >/dev/null 2>&1
  echo "changed before the first commit" > src/index.js
  git add -A && git commit -qm "root"
  install_tiers
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -qm root')"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "the root commit's stale doc is reported"
  teardown
}

echo ""
echo "=== Claude Code Hook: post-commit-sync ==="
test_post_commit_sync_skips_non_commit
test_post_commit_sync_reports_stale_after_commit
test_post_commit_sync_silent_when_current
test_post_commit_sync_skip_env
test_post_commit_sync_root_commit

# --- Every hook: no attestation, no index writes, visible failures ---

test_claude_hooks_never_run_update_index() {
  echo "test: the Claude hooks never run update-index (it would attest docs nobody read)"
  hooked_fixture
  local wrap log
  wrap=$(harness_mktemp_d wrap)
  log="$wrap/calls.log"
  printf '#!/bin/sh\necho "$1" >> "%s"\nexec "%s" "$@"\n' "$log" "$DOC_TOOLS" > "$wrap/doc-tools.sh"
  chmod +x "$wrap/doc-tools.sh"
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  echo "changed again" > src/index.js
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')" DOC_TOOLS="$wrap/doc-tools.sh"
  run_claude_hook Stop session-summary "$STOP_JSON" DOC_TOOLS="$wrap/doc-tools.sh"
  git add src/index.js
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS="$wrap/doc-tools.sh"
  local calls
  calls=$(cat "$log" 2>/dev/null || true)
  assert_contains "$calls" "check-freshness" "they check freshness"
  assert_not_contains "$calls" "update-index" "they never verify"
  teardown
}

test_hooks_leave_the_index_byte_identical() {
  echo "test: every hook leaves docs/.doc-index.json byte-identical"
  hooked_fixture
  local h0
  h0=$(hash_file docs/.doc-index.json)
  stage_stale_change 1
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after pre-commit-gate"
  run_hooked -- git commit -qm x
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after git commit (pre-commit, prepare-commit-msg)"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -m x')"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after post-commit-sync"
  echo "changed 2" > src/index.js
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after session-summary"
  git checkout -q -- src/index.js
  run_hooked -- git checkout -q -b feature
  stage_stale_change 3
  run_hooked -- git commit -qm y
  run_hooked -- git checkout -q main
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after post-checkout"
  run_hooked -- git merge -q --no-ff -m merge feature
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after post-merge"
  run_pre_push "$(push_line main)"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after pre-push"
  teardown
}

echo ""
echo "=== Every hook: no attestation, no index writes ==="
test_claude_hooks_never_run_update_index
test_hooks_leave_the_index_byte_identical

# --- Git hooks: the real contract (git runs the installed hooks) ---

test_git_commit_m_never_gains_comment_lines() {
  echo "test: git commit -m / -F / --amend --no-edit never gain '#' lines"
  hooked_fixture
  stage_stale_change 1
  run_hooked -- git commit -qm x
  assert_eq "0" "$RUN_RC" "commit -m succeeds (warn mode)"
  assert_not_contains "$(git log -1 --format=%B)" "#" "commit -m: no '#' line in the message"
  local msgf
  msgf=$(harness_mktemp msg)
  printf 'from a file\n' > "$msgf"
  stage_stale_change 2
  run_hooked -- git commit -q -F "$msgf"
  assert_not_contains "$(git log -1 --format=%B)" "#" "commit -F: no '#' line"
  stage_stale_change 3
  run_hooked -- git commit -q --amend --no-edit
  assert_eq "from a file" "$(git log -1 --format=%B)" "commit --amend --no-edit: the message is unchanged"
  teardown
}

test_editor_commit_gets_the_note_and_git_strips_it() {
  echo "test: an editor commit shows the 'already stale' note in the editor; git strips it"
  hooked_fixture
  stage_stale_change
  local ed seen
  ed=$(harness_mktemp_d editor)
  seen="$ed/seen"
  printf '#!/bin/sh\ncp "$1" "%s"\n{ printf "edited message\\n"; cat "%s"; } > "$1"\n' "$seen" "$seen" > "$ed/editor"
  chmod +x "$ed/editor"
  run_hooked GIT_EDITOR="$ed/editor" -- git commit -q
  assert_eq "0" "$RUN_RC" "the commit succeeds"
  assert_contains "$(cat "$seen" 2>/dev/null)" "already stale" "the editor shows the note"
  assert_contains "$(cat "$seen" 2>/dev/null)" "docs/architecture.md" "naming the doc"
  assert_eq "edited message" "$(git log -1 --format=%B)" "the committed message has no '#' line"
  teardown
}

test_pre_commit_reports_the_commit_being_made() {
  echo "test: pre-commit reports a staged change that makes a doc stale, in that commit"
  hooked_fixture
  stage_stale_change
  local head
  head=$(git rev-parse HEAD)
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "STRICT: this commit is blocked (not the next one)"
  assert_eq "$head" "$(git rev-parse HEAD)" "STRICT: nothing was committed"
  assert_contains "$RUN_ERR" "docs/architecture.md" "STRICT: it names the doc"
  run_hooked -- git commit -qm x
  assert_eq "0" "$RUN_RC" "warn mode: committed"
  assert_contains "$RUN_ERR" "docs/architecture.md" "warn mode: the doc is reported in this commit"
  assert_contains "$RUN_ERR" "stale" "warn mode: as stale"
  teardown
}

test_pre_commit_code_doc_and_reverify_in_one_commit() {
  echo "test: code + doc + update-index in one commit passes pre-commit under STRICT"
  hooked_fixture
  echo "changed" > src/index.js
  echo "# Architecture v2" > docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  git add -A
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm "code + doc"
  assert_eq "0" "$RUN_RC" "committed"
  assert_not_contains "$RUN_ERR" "stale" "nothing reported"
  teardown
}

test_git_mv_puts_the_old_path_in_scope() {
  echo "test: git mv of a cited file puts the doc citing the old path in scope (pre-commit and post-merge)"
  hooked_fixture src/util.js
  git mv src/util.js src/helpers.js
  run_hooked -- git commit -qm "move"
  assert_contains "$RUN_ERR" "docs/architecture.md" "pre-commit: the doc citing src/util.js is reported"
  teardown
  hooked_fixture src/util.js
  DOC_SUPERPOWERS_SKIP=1 git checkout -q -b feature
  git mv src/util.js src/helpers.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qm "move"
  DOC_SUPERPOWERS_SKIP=1 git checkout -q main
  run_hooked -- git merge -q --no-ff -m merge feature
  assert_contains "$RUN_OUT$RUN_ERR" "docs/architecture.md" "post-merge: the doc citing the old path is reported"
  teardown
}

test_pre_commit_failing_tooling_is_one_line() {
  echo "test: a corrupted index makes pre-commit print one stderr line, not pass silently"
  hooked_fixture
  echo "NOT VALID JSON{{{" > docs/.doc-index.json
  stage_stale_change 1
  run_hooked -- git commit -qm x
  assert_eq "0" "$RUN_RC" "warn mode: the commit goes through"
  assert_eq "1" "$(line_count "$RUN_ERR")" "exactly one stderr line"
  assert_contains "$RUN_ERR" "doc-superpowers" "naming its source"
  stage_stale_change 2
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm y
  assert_eq "1" "$RUN_RC" "STRICT: a check that cannot run blocks"
  assert_eq "1" "$(line_count "$RUN_ERR")" "STRICT: one line"
  teardown
}

test_pre_commit_jq_missing_is_one_line() {
  echo "test: jq missing from a git hook's PATH (GUI-client launchd PATH) prints one line"
  hooked_fixture
  stage_stale_change
  local nojq
  nojq=$(make_nojq_path)
  run_hooked PATH="$nojq" -- git commit -qm x
  assert_eq "0" "$RUN_RC" "warn mode: the commit goes through"
  assert_eq "1" "$(line_count "$RUN_ERR")" "exactly one stderr line"
  assert_contains "$RUN_ERR" "jq" "it names jq"
  stage_stale_change 2
  run_hooked PATH="$nojq" DOC_SUPERPOWERS_STRICT=1 -- git commit -qm y
  assert_eq "1" "$RUN_RC" "STRICT: blocked"
  assert_contains "$RUN_ERR" "jq" "STRICT: the reason names jq"
  teardown
}

test_hooks_ignore_doc_index_knob() {
  echo "test: the undocumented DOC_INDEX knob is gone (it could switch the hooks off)"
  hooked_fixture
  stage_stale_change
  run_hooked DOC_INDEX=/nonexistent/index.json -- git commit -qm x
  assert_contains "$RUN_ERR" "docs/architecture.md" "pre-commit still checks docs/.doc-index.json"
  teardown
}

test_post_merge_no_whole_index_untracked() {
  echo "test: post-merge does not report the whole index's untracked docs"
  hooked_fixture
  echo "# New" > docs/new.md
  git add docs/new.md && DOC_SUPERPOWERS_SKIP=1 git commit -qm "an unindexed doc"
  DOC_SUPERPOWERS_SKIP=1 git checkout -q -b feature
  echo "unrelated" > unrelated.txt
  git add unrelated.txt && DOC_SUPERPOWERS_SKIP=1 git commit -qm "unrelated"
  DOC_SUPERPOWERS_SKIP=1 git checkout -q main
  run_hooked -- git merge -q --no-ff -m merge feature
  assert_eq "0" "$RUN_RC" "merged"
  assert_not_contains "$RUN_OUT$RUN_ERR" "untracked" "no whole-index untracked report"
  assert_not_contains "$RUN_OUT$RUN_ERR" "doc-superpowers" "silent: the merge touched no cited code"
  teardown
}

test_post_checkout_list_has_no_trailing_comma() {
  echo "test: post-checkout's doc list has no trailing comma"
  setup
  echo "# Other" > docs/other.md
  git add docs/other.md && git commit -qm "other"
  printf 'docs/architecture.md:src/:architecture\ndocs/other.md:src/:guide\n' | "$DOC_TOOLS" build-index >/dev/null 2>&1
  local prev new
  prev=$(git rev-parse HEAD)
  echo "changed" > src/index.js
  git add src/index.js && git commit -qm "change"
  new=$(git rev-parse HEAD)
  run_hooked -- "$BASH_BIN" "$HOOKS_DIR/git/post-checkout" "$prev" "$new" 1
  assert_contains "$RUN_OUT" "docs/other.md" "both docs listed"
  assert_eq "0" "$(grep -c ',$' <<<"$RUN_OUT" || true)" "no line ends with a comma"
  teardown
}

echo ""
echo "=== Git hooks: real contract (git runs the installed hooks) ==="
test_git_commit_m_never_gains_comment_lines
test_editor_commit_gets_the_note_and_git_strips_it
test_pre_commit_reports_the_commit_being_made
test_pre_commit_code_doc_and_reverify_in_one_commit
test_git_mv_puts_the_old_path_in_scope
test_pre_commit_failing_tooling_is_one_line
test_pre_commit_jq_missing_is_one_line
test_hooks_ignore_doc_index_knob
test_post_merge_no_whole_index_untracked
test_post_checkout_list_has_no_trailing_comma

# --- Harness self-test: fixtures must not inherit the caller's git config ---

# A contributor with a global `core.hooksPath` used to have this suite install
# doc-superpowers hooks into that real, machine-wide directory: every fixture
# inherited the caller's global config, and `install --git` resolves
# core.hooksPath first. setup() now pins GIT_CONFIG_GLOBAL=/dev/null and a
# private HOME, so the planted global dir must stay empty.
test_harness_ignores_global_hooks_path() {
  echo "test: harness: fixtures ignore a global core.hooksPath (suite never writes outside \$TEST_DIR)"
  local scratch
  scratch=$(harness_mktemp_d globalcfg)
  mkdir -p "$scratch/global"
  printf '[core]\n\thooksPath = %s\n' "$scratch/global" > "$scratch/gitconfig"
  (
    export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
    setup
    "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1 || true
    teardown
  ) || true
  local planted
  planted=$(ls -A "$scratch/global")
  assert_eq "" "$planted" "planted global hooks dir left empty after setup + install --git"
  rm -rf "$scratch"
}

# --- Installer tests ---

test_install_git_creates_hooks() {
  echo "test: install --git creates hook files in .git/hooks/"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  assert_not_contains "$(cat .git/hooks/pre-commit)" "__DOC_TOOLS_PARENT__" "parent substituted"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-tools.sh" "has real path"
  # v2.12.2: hook resolves the latest plugin-cache version at runtime instead of
  # pinning the install-time version. Check the resolver fragment is present.
  assert_contains "$(cat .git/hooks/pre-commit)" "sort -V | tail -1" "uses runtime version resolver"
  teardown
}

test_install_git_preserves_existing_hook() {
  echo "test: install --git does not overwrite foreign hooks"
  setup
  printf '#!/bin/bash\necho existing\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  assert_file_exists ".git/hooks/pre-commit" "hook exists before uninstall"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  # Verify integration block exists
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers:begin" "begin marker present"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers:end" "end marker present"
  assert_file_exists ".git/hooks/.doc-superpowers-pre-commit" "local hook copy exists"
  # Uninstall
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
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

test_install_git_registers_merge_driver() {
  echo "test: install --git registers merge driver in git config and .gitattributes"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # Verify git config entries
  local driver_config
  driver_config=$(git config --local --get merge.doc-index.driver 2>/dev/null || echo "")
  assert_contains "$driver_config" "merge-doc-index.sh" "merge driver registered in git config"
  local name_config
  name_config=$(git config --local --get merge.doc-index.name 2>/dev/null || echo "")
  assert_eq "doc-superpowers index merger" "$name_config" "merge driver name set"
  # Verify .gitattributes entry
  assert_file_exists ".gitattributes" ".gitattributes created"
  assert_contains "$(cat .gitattributes)" "merge=doc-index" ".gitattributes has merge driver entry"
  # Verify no leading blank line when .gitattributes was created fresh
  local first_char
  first_char=$(head -c 1 .gitattributes)
  assert_eq "#" "$first_char" "no leading blank line in fresh .gitattributes"
  teardown
}

test_uninstall_git_removes_merge_driver() {
  echo "test: uninstall --git removes merge driver from git config and .gitattributes"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  # Verify installed first
  assert_contains "$(git config --local --get merge.doc-index.driver 2>/dev/null)" "merge-doc-index.sh" "driver present before uninstall"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # Verify git config entries removed
  local driver_config
  driver_config=$(git config --local --get merge.doc-index.driver 2>/dev/null || echo "UNSET")
  assert_eq "UNSET" "$driver_config" "merge driver removed from git config"
  # Verify .gitattributes entry removed
  assert_not_contains "$(cat .gitattributes 2>/dev/null)" "merge=doc-index" "merge driver removed from .gitattributes"
  assert_contains "$output" "Unregistered merge driver" "reports unregistration"
  teardown
}

test_status_reports_merge_driver() {
  echo "test: status reports merge driver state"
  setup
  # Before install: not registered
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status 2>&1)
  set -e
  assert_contains "$output" "merge-driver" "shows merge-driver line"
  assert_contains "$output" "not registered" "shows not registered before install"
  # After install: registered
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status 2>&1)
  set -e
  assert_contains "$output" "registered" "shows registered after install"
  assert_contains "$output" "configured" "shows .gitattributes configured"
  teardown
}

test_status_warns_stale_merge_driver_path() {
  echo "test: status warns when merge driver script path is stale"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  # Point git config at a non-existent path
  git config --local merge.doc-index.driver "/nonexistent/merge-doc-index.sh %O %A %B"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status 2>&1)
  set -e
  assert_contains "$output" "script missing" "warns about missing driver script"
  teardown
}

test_install_claude_creates_settings() {
  echo "test: install --claude creates settings and copies scripts"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --claude 2>&1)
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
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__DOC_TOOLS_PARENT__" "DOC_TOOLS parent substituted"
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__INSTALL_DATE__" "install date substituted"
  # v2.12.2: claude-side hook also resolves the latest plugin-cache version at runtime
  assert_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "sort -V | tail -1" "uses runtime version resolver"
  teardown
}

test_install_claude_preserves_existing() {
  echo "test: install --claude preserves existing settings"
  setup
  mkdir -p .claude
  echo '{"permissions":{"allow":["Read"]}}' > .claude/settings.local.json
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --claude 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --claude >/dev/null 2>&1
  assert_file_exists ".claude/hooks/doc-superpowers/pre-commit-gate.sh" "script exists before uninstall"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --claude 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "PR workflow"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "schedule workflow"
  assert_file_exists ".github/workflows/doc-index-update.yml" "index workflow"
  assert_file_exists ".github/scripts/doc-tools.sh" "vendored doc-tools.sh"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__BASE_BRANCH__" "base branch substituted"
  assert_not_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "__CRON_SCHEDULE__" "cron schedule substituted"
  # Verify no remote curl in shell-based workflows
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "curl" "no remote fetch in PR workflow"
  assert_not_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "curl" "no remote fetch in schedule workflow"
  assert_not_contains "$(cat .github/workflows/doc-index-update.yml)" "curl" "no remote fetch in index workflow"
  teardown
}

test_install_ci_with_custom_base_branch() {
  echo "test: install --ci --base-branch substitutes custom branch"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --base-branch develop 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --cron '0 12 * * *' 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --ci-strict 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-audit-update.yml" "audit-update workflow"
  assert_file_exists ".github/workflows/doc-review-pr.yml" "review-pr workflow"
  assert_file_exists ".github/workflows/doc-release.yml" "release workflow"
  assert_file_exists ".github/workflows/doc-spec-verify.yml" "spec-verify workflow"
  assert_file_exists ".github/workflows/doc-pr-full-cycle.yml" "pr-full-cycle workflow"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-audit-update.yml)" "__BASE_BRANCH__" "base branch substituted in audit-update"
  assert_not_contains "$(cat .github/workflows/doc-audit-update.yml)" "__VERSION__" "version substituted in audit-update"
  assert_not_contains "$(cat .github/workflows/doc-review-pr.yml)" "__BASE_BRANCH__" "base branch substituted in review-pr"
  assert_not_contains "$(cat .github/workflows/doc-release.yml)" "__VERSION__" "version substituted in release"
  assert_not_contains "$(cat .github/workflows/doc-spec-verify.yml)" "__BASE_BRANCH__" "base branch substituted in spec-verify"
  assert_not_contains "$(cat .github/workflows/doc-pr-full-cycle.yml)" "__BASE_BRANCH__" "base branch substituted in pr-full-cycle"
  assert_not_contains "$(cat .github/workflows/doc-pr-full-cycle.yml)" "__VERSION__" "version substituted in pr-full-cycle"
  teardown
}

test_install_ci_claude_workflows_have_marker() {
  echo "test: Claude-powered workflows start with workflow marker"
  setup
  for template in doc-audit-update.yml doc-review-pr.yml doc-release.yml doc-spec-verify.yml doc-pr-full-cycle.yml; do
    local first_line
    first_line=$(head -1 "$HOOKS_DIR/ci/$template")
    assert_contains "$first_line" "doc-superpowers workflow v1" "marker in $template"
  done
  teardown
}

test_install_ci_claude_workflows_reference_api_key() {
  echo "test: Claude-powered workflows reference ANTHROPIC_API_KEY"
  setup
  for template in doc-audit-update.yml doc-review-pr.yml doc-release.yml doc-spec-verify.yml doc-pr-full-cycle.yml; do
    assert_contains "$(cat "$HOOKS_DIR/ci/$template")" "ANTHROPIC_API_KEY" "API key in $template"
  done
  teardown
}

test_install_ci_api_key_message() {
  echo "test: install --ci prints API key message for Claude-powered workflows"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "ANTHROPIC_API_KEY" "API key reminder shown"
  teardown
}

test_install_ci_vendors_doc_tools() {
  echo "test: install --ci vendors doc-tools.sh into .github/scripts"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh vendored"
  assert_contains "$output" "Vendored doc-tools.sh" "vendor message shown"
  # Verify the vendored file is executable
  assert_true "doc-tools.sh is executable" test -x ".github/scripts/doc-tools.sh"
  # Verify workflows reference the local copy
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" ".github/scripts/doc-tools.sh" "PR workflow uses local script"
  assert_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" ".github/scripts/doc-tools.sh" "schedule workflow uses local script"
  assert_contains "$(cat .github/workflows/doc-index-update.yml)" ".github/scripts/doc-tools.sh" "index workflow uses local script"
  teardown
}

test_uninstall_ci_removes_claude_workflows() {
  echo "test: uninstall --ci removes Claude-powered workflows"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  assert_file_exists ".github/workflows/doc-audit-update.yml" "installed first"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".github/workflows/doc-audit-update.yml" "audit-update removed"
  assert_file_not_exists ".github/workflows/doc-review-pr.yml" "review-pr removed"
  assert_file_not_exists ".github/workflows/doc-release.yml" "release removed"
  assert_file_not_exists ".github/workflows/doc-spec-verify.yml" "spec-verify removed"
  assert_file_not_exists ".github/workflows/doc-pr-full-cycle.yml" "pr-full-cycle removed"
  teardown
}

test_uninstall_ci_removes_vendored_doc_tools() {
  echo "test: uninstall --ci removes vendored doc-tools.sh"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  assert_file_exists ".github/scripts/doc-tools.sh" "vendored first"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".github/scripts/doc-tools.sh" "doc-tools.sh removed"
  # .github/scripts/ dir should be cleaned up if empty
  assert_true "scripts dir cleaned up" test ! -d ".github/scripts"
  teardown
}

test_uninstall_no_flags_non_tty_fails() {
  echo "test: uninstall without flags in non-TTY context exits 1"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --all >/dev/null 2>&1
  set +e
  output=$(echo "" | "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 without tier flags"
  assert_contains "$output" "specify tier flags" "shows error message"
  teardown
}

test_status_reports_installed() {
  echo "test: status reports installed hooks"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --all 2>&1)
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
  tmpdir=$(harness_mktemp_d not-a-repo)
  cd "$tmpdir"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --base-branch 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --cron 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "--cron requires a value" "clear error message"
  teardown
}

# --- Granular install --ci (Feature B + state-respect Feature C) ---

test_install_ci_workflows_csv_installs_subset_only() {
  echo "test: install --ci --workflows=csv installs ONLY the listed workflows"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-pr-release,doc-index-update 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-pr-release.yml" "doc-pr-release installed"
  assert_file_exists ".github/workflows/doc-index-update.yml" "doc-index-update installed"
  assert_file_not_exists ".github/workflows/doc-freshness-pr.yml" "doc-freshness-pr NOT installed"
  assert_file_not_exists ".github/workflows/doc-audit-update.yml" "doc-audit-update NOT installed"
  assert_file_not_exists ".github/workflows/doc-release.yml" "doc-release NOT installed"
  # doc-tools.sh is still vendored even with selective install.
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh vendored"
  teardown
}

test_install_ci_workflows_none_skips_all_but_vendors_tools() {
  echo "test: install --ci --workflows=none skips workflow files but vendors doc-tools.sh"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=none 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".github/workflows/doc-freshness-pr.yml" "no workflows installed"
  assert_file_not_exists ".github/workflows/doc-release.yml" "no workflows installed"
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh STILL vendored"
  teardown
}

test_uninstall_ci_workflows_none_keeps_workflows() {
  echo "test: uninstall --ci --workflows=none removes no workflows (helpers/tools handled separately)"
  setup
  # Install everything first.
  set +e
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  set -e
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "precondition: installed"
  assert_file_exists ".github/workflows/doc-pr-release.yml" "precondition: installed"

  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=none 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # All workflow files should still be on disk.
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "doc-freshness-pr preserved"
  assert_file_exists ".github/workflows/doc-pr-release.yml" "doc-pr-release preserved"
  # vendored doc-tools.sh should NOT have been removed (partial uninstall).
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh preserved on partial uninstall"
  # And no spurious state flips for individual workflows.
  local state
  state=$(jq -r '.tiers.ci.workflows."doc-freshness-pr".state' .claude/doc-superpowers/installed.json)
  assert_eq "installed" "$state" "doc-freshness-pr state unchanged"
  teardown
}

test_install_ci_workflows_bogus_errors_with_valid_set() {
  echo "test: install --ci --workflows=bogus errors with clear message listing valid names"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=bogus 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "unknown workflow name: bogus" "clear error"
  assert_contains "$output" "doc-freshness-pr" "lists valid names"
  assert_contains "$output" "doc-release" "lists valid names (multiple)"
  # And no partial state should have been written.
  assert_file_not_exists ".github/workflows/doc-freshness-pr.yml" "no workflows created on error"
  teardown
}

# Everything install could write in a fixture: work tree (minus the harness's
# own home/ and xdg/), git hooks dir, and local git config.
_fixture_snapshot() {
  find . -path ./.git -prune -o -path ./home -prune -o -path ./xdg -prune -o -print | sort
  ls -A .git/hooks
  git config --local --list
}

test_install_ci_helpers_false_refuses_doc_pr_release() {
  # doc-pr-release.yml runs update-pr-body.sh / commit-and-push.sh directly and
  # its context step runs extract-context.sh — all three are the --helpers-gated
  # producer helpers. --helpers=false with doc-pr-release selected would install
  # a workflow that fails at runtime, so install refuses before writing anything.
  echo "test: install --helpers=false refuses when doc-pr-release is selected (non-zero, clear error, nothing written)"
  setup
  local before after output exit_code args
  before=$(_fixture_snapshot)
  for args in "--ci --workflows=doc-pr-release" "--ci --workflows=doc-release,doc-pr-release" "--ci" "--all"; do
    exit_code=0
    # shellcheck disable=SC2086  # intentional word-splitting of the flag set
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install $args --helpers=false 2>&1 >/dev/null) || exit_code=$?
    assert_eq "1" "$exit_code" "install $args --helpers=false exits 1"
    assert_contains "$output" "doc-pr-release" "install $args --helpers=false: stderr names the workflow"
    assert_contains "$output" "drop --helpers=false or deselect doc-pr-release" "install $args --helpers=false: stderr names the fix"
    after=$(_fixture_snapshot)
    assert_eq "$before" "$after" "install $args --helpers=false: nothing written"
  done
  teardown
}

test_install_ci_ships_step_scripts_with_workflow() {
  # The step scripts are the templates' run: bodies. They follow the workflow,
  # never --helpers, and stay while either consumer workflow remains.
  echo "test: install --ci ships .github/scripts/doc-superpowers-steps/ with its workflows; uninstall follows"
  setup
  local output exit_code=0 steps=".github/scripts/doc-superpowers-steps"
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-release 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "install doc-release exits 0"
  assert_contains "$output" "workflow step scripts in $steps/" "reports the step-script install"
  assert_true "precheck.sh installed executable" test -x "$steps/precheck.sh"
  assert_true "resolve-auth.sh installed executable" test -x "$steps/resolve-auth.sh"
  assert_true "doc-pr-release producer helpers NOT installed for doc-release alone" test ! -d ".github/scripts/doc-pr-release"
  exit_code=0
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-pr-release >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "install doc-pr-release exits 0"
  exit_code=0
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-release >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "uninstall doc-release exits 0"
  assert_true "step scripts kept while doc-pr-release.yml remains" test -x "$steps/sentinel-check.sh"
  exit_code=0
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-pr-release >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "uninstall doc-pr-release exits 0"
  assert_true "step scripts removed with the last workflow that runs them" test ! -d "$steps"
  teardown
}

# _assert_installed_workflows_wired <label> — every `.github/scripts/...` path an
# installed workflow runs exists and is executable; no placeholder survives.
_assert_installed_workflows_wired() {
  local label="$1" refs missing="" ref
  refs=$(grep -hoE '\.github/scripts/[A-Za-z0-9_./-]+\.sh' .github/workflows/doc-*.yml | sort -u)
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -x "$ref" ] || missing="${missing} ${ref}"
  done <<<"$refs"
  assert_eq "" "$missing" "$label: every script an installed workflow runs is installed and executable"
  assert_eq "" "$(grep -lE '__(BASE_BRANCH|VERSION|CRON_SCHEDULE|CI_STRICT)__' .github/workflows/doc-*.yml || true)" \
    "$label: no placeholder survives in installed workflows"
}

test_install_ci_every_referenced_helper_is_installed() {
  # Installer output, not templates: after a default `install --ci`, every
  # `.github/scripts/...` path an installed workflow runs must exist.
  echo "test: install --ci — every script an installed workflow runs is on disk"
  setup
  local exit_code=0 refs
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "install --ci exits 0"
  refs=$(grep -hoE '\.github/scripts/[A-Za-z0-9_./-]+\.sh' .github/workflows/doc-*.yml | sort -u)
  assert_contains "$refs" ".github/scripts/doc-superpowers-steps/precheck.sh" "doc-release.yml runs its precheck step"
  assert_contains "$refs" ".github/scripts/doc-superpowers-steps/verify-fragment.sh" "doc-pr-release.yml runs its verify step"
  _assert_installed_workflows_wired "install --ci"
  teardown
}

test_install_ci_helpers_false_still_wires_steps() {
  # Every --helpers=false install that is allowed (no doc-pr-release selected)
  # must leave every installed workflow with all the scripts it runs.
  echo "test: install --ci --helpers=false without doc-pr-release — every installed workflow is fully wired"
  local others="" wf exit_code
  for wf in "$HOOKS_DIR"/ci/doc-*.yml; do
    wf=$(basename "$wf" .yml)
    [ "$wf" = "doc-pr-release" ] && continue
    others="${others:+$others,}$wf"
  done
  for wf in doc-release "$others"; do
    setup
    exit_code=0
    "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows="$wf" --helpers=false >/dev/null 2>&1 || exit_code=$?
    assert_eq "0" "$exit_code" "install --workflows=$wf --helpers=false exits 0"
    _assert_installed_workflows_wired "--workflows=$wf --helpers=false"
    assert_true "--workflows=$wf --helpers=false: producer helpers not installed" test ! -d ".github/scripts/doc-pr-release"
    teardown
  done
}

test_install_ci_writes_state_file_on_first_install() {
  echo "test: install --ci writes .claude/doc-superpowers/installed.json"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".claude/doc-superpowers/installed.json" "state file created"
  # Every workflow listed by state_known_workflows should be marked installed.
  # Source state.sh in a subshell so we get the canonical list rather than
  # duplicating it here (drift risk).
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    local state
    state=$(jq -r --arg n "$n" '.tiers.ci.workflows[$n].state' .claude/doc-superpowers/installed.json)
    assert_eq "installed" "$state" "$n marked installed in state file"
  done < <(SCRIPT_DIR="$HOOKS_DIR" "$BASH_BIN" -c "source '$HOOKS_DIR/state.sh' && state_known_workflows")
  teardown
}

test_install_ci_bootstraps_state_from_filesystem() {
  echo "test: install --ci infers state from filesystem on first run (migration)"
  setup
  # Pre-install one workflow manually (simulate prior install w/o state file).
  mkdir -p .github/workflows
  sed -e "s|__BASE_BRANCH__|main|g" -e "s|__VERSION__|v2.0|g" \
      -e "s|__CRON_SCHEDULE__|0 9 * * 1|g" -e "s|__CI_STRICT__|0|g" \
      "$HOOKS_DIR/ci/doc-freshness-pr.yml" > .github/workflows/doc-freshness-pr.yml
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  # Bootstrap should have detected the pre-existing workflow.
  assert_file_exists ".claude/doc-superpowers/installed.json" "state file created"
  local state
  state=$(jq -r '.tiers.ci.workflows."doc-freshness-pr".state' .claude/doc-superpowers/installed.json)
  assert_eq "installed" "$state" "pre-existing workflow detected as installed"
  teardown
}

test_install_ci_malformed_state_file_falls_back_with_warn() {
  echo "test: install --ci with malformed state file warns + falls back to filesystem"
  setup
  mkdir -p .claude/doc-superpowers
  echo "{not valid json" > .claude/doc-superpowers/installed.json
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (graceful fallback)"
  assert_contains "$output" "malformed" "WARN emitted"
  # And the install still ran.
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "install proceeded"
  teardown
}

test_uninstall_install_cycle_respects_intentional_uninstall() {
  echo "test: uninstall --ci then install --ci keeps intentionally-removed workflows uninstalled"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-release >/dev/null 2>&1
  assert_file_not_exists ".github/workflows/doc-release.yml" "uninstall removed doc-release"
  # State should say intentional.
  local intentional
  intentional=$(jq -r '.tiers.ci.workflows."doc-release".intentional' .claude/doc-superpowers/installed.json)
  assert_eq "true" "$intentional" "marked intentional"
  # Now re-install — doc-release should stay GONE.
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "install exits 0"
  assert_file_not_exists ".github/workflows/doc-release.yml" "doc-release stays uninstalled"
  assert_contains "$output" "skipping doc-release.yml" "skip message shown"
  assert_contains "$output" "--workflows=doc-release" "override hint shown"
  # Other workflows should be re-installed.
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "other workflows present"
  teardown
}

test_uninstall_transient_then_install_reinstalls() {
  echo "test: uninstall --ci --transient lets next install --ci re-install"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-release --transient >/dev/null 2>&1
  local intentional
  intentional=$(jq -r '.tiers.ci.workflows."doc-release".intentional' .claude/doc-superpowers/installed.json)
  assert_eq "false" "$intentional" "marked transient"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-release.yml" "doc-release re-installed"
  assert_not_contains "$output" "skipping doc-release.yml" "no skip message"
  teardown
}

test_install_force_bypasses_intentional_uninstall() {
  echo "test: install --ci --force re-installs intentionally-uninstalled workflows"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-release >/dev/null 2>&1
  assert_file_not_exists ".github/workflows/doc-release.yml" "uninstall removed doc-release"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --force 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-release.yml" "doc-release re-installed via --force"
  assert_not_contains "$output" "skipping doc-release.yml" "no skip message with --force"
  teardown
}

test_install_explicit_workflows_overrides_state() {
  echo "test: install --ci --workflows=<name> beats state-respect (explicit > implicit)"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-release >/dev/null 2>&1
  # Explicit re-add — should NOT skip even though state says intentional:uninstalled.
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-release 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-release.yml" "doc-release re-installed via explicit --workflows"
  teardown
}

test_install_ci_helpers_invalid_value_errors() {
  echo "test: install --ci --helpers=garbage errors with clear message"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --helpers=garbage 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "--helpers must be" "clear error"
  teardown
}

echo ""
echo "=== Installer ==="
test_harness_ignores_global_hooks_path
test_install_git_creates_hooks
test_install_git_preserves_existing_hook
test_install_git_overwrites_own_hook
test_uninstall_git_removes_hooks
test_uninstall_git_preserves_foreign_hooks
test_uninstall_git_removes_integrated_hooks
test_install_git_registers_merge_driver
test_uninstall_git_removes_merge_driver
test_status_reports_merge_driver
test_status_warns_stale_merge_driver_path
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
test_install_ci_vendors_doc_tools
test_uninstall_ci_removes_claude_workflows
test_uninstall_ci_removes_vendored_doc_tools
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

echo ""
echo "=== Granular install --ci (v2.12.0+) ==="
test_install_ci_workflows_csv_installs_subset_only
test_install_ci_workflows_none_skips_all_but_vendors_tools
test_uninstall_ci_workflows_none_keeps_workflows
test_install_ci_workflows_bogus_errors_with_valid_set
test_install_ci_helpers_false_refuses_doc_pr_release
test_install_ci_ships_step_scripts_with_workflow
test_install_ci_every_referenced_helper_is_installed
test_install_ci_helpers_false_still_wires_steps
test_install_ci_writes_state_file_on_first_install
test_install_ci_bootstraps_state_from_filesystem
test_install_ci_malformed_state_file_falls_back_with_warn
test_uninstall_install_cycle_respects_intentional_uninstall
test_uninstall_transient_then_install_reinstalls
test_install_force_bypasses_intentional_uninstall
test_install_explicit_workflows_overrides_state
test_install_ci_helpers_invalid_value_errors

print_summary

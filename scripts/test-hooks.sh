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
indexed_fixture() {
  setup
  echo "util" > src/util.js
  git add src/util.js && git commit -qm "util"
  echo "docs/architecture.md:${1:-src/}:architecture" | "$DOC_TOOLS" build-index >/dev/null 2>&1
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  git add docs/.doc-index.json && git commit -qm "index"
}

# indexed_fixture, then the git and Claude tiers installed.
hooked_fixture() {
  indexed_fixture "$@"
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
  for t in sh env git awk sed tr sort tail head cat cut wc grep mktemp rm cp mv \
    mkdir ln date dirname basename xargs shasum sha256sum uname sleep ls readlink chmod \
    find expr tee touch kill; do
    p=$(type -P "$t" 2>/dev/null) || continue
    [ -e "$dir/$t" ] || ln -s "$p" "$dir/$t"
  done
  printf '%s' "$dir"
}

# A copy of the plugin at <dir> (scripts/, SKILL.md, RELEASE-NOTES.md): a
# plugin-cache version dir when <dir> is named like 1.2.3, a checkout otherwise.
plugin_copy() {
  mkdir -p "$1/skills/doc-superpowers"
  cp -R "$SCRIPT_DIR" "$1/scripts"
  cp "$SCRIPT_DIR/../skills/doc-superpowers/SKILL.md" "$1/skills/doc-superpowers/"
  cp "$SCRIPT_DIR/../RELEASE-NOTES.md" "$1/"
}

# inst [--from <install.sh>] <args…>: run the installer from the cwd.
# Sets IRC and IOUT (stdout + stderr).
inst() {
  local sh="$HOOKS_DIR/install.sh"
  if [ "${1:-}" = "--from" ]; then
    sh="$2"
    shift 2
  fi
  IRC=0
  IOUT=$(PATH="$REAL_PATH" "$BASH_BIN" "$sh" "$@" 2>&1) || IRC=$?
}

# Everything an install could touch, content included: the work tree (minus
# the harness's home/ and xdg/), git's hooks/ and info/, the local config.
_tree_state() {
  local f
  {
    find . -path ./.git -prune -o -path ./home -prune -o -path ./xdg -prune -o -print
    find .git/hooks .git/info 2>/dev/null || true
  } | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      printf '%s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -f "$f" ]; then
      printf '%s %s\n' "$f" "$(cksum < "$f")"
    else
      printf '%s/\n' "$f"
    fi
  done
  git config --local --list 2>/dev/null || true
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
  # The index was never committed, so doc-tools notes its fallback first; the
  # line must carry the error, not that note.
  assert_contains "$(cat "$errf")" "not a valid doc-index" "…and the cause (the error, not the fallback note)"
  assert_not_contains "$(cat "$errf")" "NOTE:" "…not the fallback note"
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
  # Resolution is observable (a sort) only for a plugin-cache install: a
  # checkout install names its own doc-tools.sh (no process to watch).
  local probe log cache
  cache="$(harness_mktemp_d cache)/doc-superpowers"
  plugin_copy "$cache/1.0.0"
  PATH="$REAL_PATH" "$BASH_BIN" "$cache/1.0.0/scripts/hooks/install.sh" install --claude >/dev/null 2>&1
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

test_claude_gate_ignores_commit_text_that_is_not_a_command() {
  echo "test: claude pre-commit-gate ignores 'git commit' that is not in command position"
  hooked_fixture
  stage_stale_change
  local c
  for c in 'echo git commit' 'echo "git commit -m x"' 'legit commit' \
    'gh pr create --body "run git commit -m first"' 'grep "git commit -m" .'; do
    run_claude_hook PreToolUse pre-commit-gate "$(pretool_json "$c")" DOC_SUPERPOWERS_STRICT=1
    assert_eq "0" "$RUN_RC" "'$c': not gated, even under STRICT with a stale change staged"
    assert_eq "" "$RUN_OUT$RUN_ERR" "'$c': silent"
    run_claude_hook PostToolUse post-commit-sync "$(posttool_json "$c")"
    assert_eq "" "$RUN_OUT$RUN_ERR" "'$c': post-commit-sync silent too"
  done
  teardown
}

test_claude_gate_matches_commit_in_command_position() {
  echo "test: claude pre-commit-gate gates 'git commit' wherever the shell would run it"
  hooked_fixture
  stage_stale_change
  local c
  for c in 'GIT_AUTHOR_NAME=t git commit -m x' '/usr/bin/git commit -m x' \
    'if true; then git commit -m x; fi' '(git commit -m x)' '{ git commit -m x; }' \
    "ls"$'\n'"git commit -m x" 'x=$(git commit -m x)' \
    "git commit -m \"\$(cat <<'EOF'"$'\n'"subject"$'\n'"EOF"$'\n'")\""; do
    run_claude_hook PreToolUse pre-commit-gate "$(pretool_json "$c")" DOC_SUPERPOWERS_STRICT=1
    assert_eq "2" "$RUN_RC" "'$c': gated (exit 2 under STRICT)"
  done
  teardown
}

test_claude_hooks_share_one_commit_regex() {
  echo "test: the gate and post-commit-sync define the same commit regex"
  local a b
  a=$(grep '^re_commit=' "$HOOKS_DIR/claude/pre-commit-gate.sh")
  b=$(grep '^re_commit=' "$HOOKS_DIR/claude/post-commit-sync.sh")
  assert_true "the gate defines re_commit" test -n "$a"
  assert_eq "$a" "$b" "one definition, byte for byte"
}

test_claude_gate_quiet_strict_still_gives_the_reason() {
  echo "test: under QUIET, a STRICT block still gives Claude its reason on stderr"
  hooked_fixture
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1 DOC_SUPERPOWERS_QUIET=1
  assert_eq "2" "$RUN_RC" "blocked"
  assert_contains "$RUN_ERR" "docs/architecture.md" "stderr (Claude's feedback) names the doc"
  assert_eq "" "$RUN_OUT" "nothing on stdout"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_QUIET=1
  assert_eq "0" "$RUN_RC" "not STRICT: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "not STRICT: QUIET silences the advisory"
  teardown
}

test_claude_gate_judges_the_staged_index() {
  echo "test: the gate and git pre-commit judge the staged doc-index, not the working copy's (update-index without git add)"
  hooked_fixture
  stage_stale_change
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1   # not staged
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "gate: the commit would record the old index, so it is blocked"
  assert_contains "$RUN_ERR" "docs/architecture.md" "gate: names the doc"
  local head
  head=$(git rev-parse HEAD)
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "git pre-commit: blocked"
  assert_eq "$head" "$(git rev-parse HEAD)" "git pre-commit: nothing committed"
  git add docs/.doc-index.json
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "0" "$RUN_RC" "with the re-verified index staged: committed"
  assert_eq "current" "$("$DOC_TOOLS" check-freshness | jq -r '.docs["docs/architecture.md"].status')" "…and HEAD reads current"
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
test_claude_gate_ignores_commit_text_that_is_not_a_command
test_claude_gate_matches_commit_in_command_position
test_claude_hooks_share_one_commit_regex
test_claude_gate_quiet_strict_still_gives_the_reason
test_claude_gate_judges_the_staged_index

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
  # The watchdog sleeps the hook's BUDGET. A shim `sleep` stretches exactly
  # that sleep to 60 s (any other sleep runs as asked), so a watchdog left
  # holding the hook's stdout would keep the caller waiting a minute — a gap
  # no machine load closes — while the check itself is never cut short. (The
  # old bound, "< 2 s" of wall time against the 2 s budget, failed on a
  # loaded machine.)
  local budget shim real start elapsed
  budget=$(sed -n 's/^BUDGET=//p' .claude/hooks/doc-superpowers/session-summary.sh)
  assert_true "precondition: the installed hook has a numeric BUDGET ($budget)" \
    grep -qxE '[0-9]+' <<<"$budget"
  shim=$(harness_mktemp_d sleep-shim)
  real=$(command -v sleep)
  printf '#!/bin/sh\nif [ "$1" = "%s" ]; then exec "%s" 60; fi\nexec "%s" "$@"\n' "$budget" "$real" "$real" > "$shim/sleep"
  chmod +x "$shim/sleep"
  start=$SECONDS
  run_claude_hook Stop session-summary "$STOP_JSON" PATH="$shim:$REAL_PATH"
  elapsed=$((SECONDS - start))
  assert_contains "$(out_field .systemMessage)" "docs/architecture.md" "the check completed"
  assert_true "returned without waiting out the watchdog's sleep (took ${elapsed}s; a held output takes >= 60 s)" \
    test "$elapsed" -lt 30
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

test_post_commit_sync_stdin_edge_cases() {
  echo "test: post-commit-sync with empty stdin exits at once; with a 1 MB tool_response it still reports"
  hooked_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  local cmd big
  cmd=$(registered_cmd PostToolUse post-commit-sync)
  run_hooked CLAUDE_PROJECT_DIR="$TEST_DIR" -- sh -c "$cmd"
  assert_eq "0" "$RUN_RC" "empty stdin: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "empty stdin: silent"
  big=$(harness_mktemp big)
  awk 'BEGIN { s = "0123456789abcdef"; for (i = 0; i < 16; i++) s = s s; print s }' > "$big.out"
  jq -cn --rawfile o "$big.out" '{tool_name: "Bash", tool_input: {command: "git commit -am code"},
    tool_response: {stdout: $o, stderr: "", interrupted: false}}' > "$big"
  RUN_STDIN="$big"
  run_hooked CLAUDE_PROJECT_DIR="$TEST_DIR" -- sh -c "$cmd"
  RUN_STDIN=/dev/null
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "1 MB payload: the stale doc is reported"
  teardown
}

echo ""
echo "=== Claude Code Hook: post-commit-sync ==="
test_post_commit_sync_skips_non_commit
test_post_commit_sync_reports_stale_after_commit
test_post_commit_sync_silent_when_current
test_post_commit_sync_skip_env
test_post_commit_sync_root_commit
test_post_commit_sync_stdin_edge_cases

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
  local h0 g0
  h0=$(hash_file docs/.doc-index.json)
  # git's own index too, around the Claude hooks (outside any git command):
  # with a stat-dirty entry, porcelain `git diff` would refresh and rewrite it.
  touch -t 202001010000 src/util.js
  stage_stale_change 1
  g0=$(hash_file .git/index)
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after pre-commit-gate"
  assert_eq "$g0" "$(hash_file .git/index)" "after pre-commit-gate: git's index untouched"
  run_hooked -- git commit -qm x
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after git commit (pre-commit, prepare-commit-msg)"
  touch -t 202001010000 src/util.js
  g0=$(hash_file .git/index)
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -m x')"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after post-commit-sync"
  assert_eq "$g0" "$(hash_file .git/index)" "after post-commit-sync: git's index untouched"
  echo "changed 2" > src/index.js
  touch -t 202001010000 src/util.js
  g0=$(hash_file .git/index)
  local s0
  s0=$(git ls-files -s --debug)
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "$h0" "$(hash_file docs/.doc-index.json)" "after session-summary"
  assert_eq "$g0" "$(hash_file .git/index)" "after session-summary: git's index untouched (no stat refresh)"
  assert_eq "$s0" "$(git ls-files -s --debug)" "after session-summary: ls-files -s --debug unchanged"
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
  # Staged: pre-commit judges the index the commit carries (the working copy's
  # would not be read while the staged tree holds a valid one).
  echo "NOT VALID JSON{{{" > docs/.doc-index.json
  git add docs/.doc-index.json
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
  # The hook resolves doc-tools.sh by the merge driver's rule: newest
  # version-named sibling in numeric order (plugin cache) or the pinned path
  # (a checkout) — never GNU `sort -V`, never any sibling directory.
  assert_contains "$(cat .git/hooks/pre-commit)" "sort -t. -k1,1n -k2,2n -k3,3n" "uses the numeric version resolver"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "sort -V" "no GNU sort -V"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "__DOC_TOOLS_RESOLVE__" "resolver substituted"
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
  # Commands name the scripts through $CLAUDE_PROJECT_DIR (not the cwd, not an
  # absolute path of this machine).
  assert_contains "$settings" '\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/doc-superpowers/' "commands run the scripts under \$CLAUDE_PROJECT_DIR"
  assert_not_contains "$settings" "$TEST_DIR" "no absolute path of this machine"
  # Verify placeholder substitution in copied scripts
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__DOC_TOOLS_RESOLVE__" "DOC_TOOLS resolver substituted"
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "__INSTALL_DATE__" "install date substituted"
  assert_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "sort -t. -k1,1n -k2,2n -k3,3n" "uses the numeric version resolver"
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/pre-commit-gate.sh)" "sort -V" "no GNU sort -V"
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
  # The install created the settings file and held nothing else in it: no residue.
  assert_file_not_exists ".claude/settings.local.json" "settings file the install created is removed"
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
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "no index workflow (retired in v3.0.0)"
  assert_file_exists ".github/scripts/doc-tools.sh" "vendored doc-tools.sh"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__BASE_BRANCH__" "base branch substituted"
  assert_not_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "__CRON_SCHEDULE__" "cron schedule substituted"
  # Verify no remote curl in shell-based workflows
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "curl" "no remote fetch in PR workflow"
  assert_not_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "curl" "no remote fetch in schedule workflow"
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
  echo "test: install --ci --workflows=all creates the Claude-powered workflow files (opt-in by name)"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all 2>&1)
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-release 2>&1)
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
  assert_contains "$output" "doc-tools.sh → .github/scripts/doc-tools.sh" "vendor message shown (doc-tools.sh tools install)"
  # Verify the vendored file is executable
  assert_true "doc-tools.sh is executable" test -x ".github/scripts/doc-tools.sh"
  # Verify workflows run the local copy (through the vendored step script)
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" ".github/scripts/doc-superpowers-steps/freshness-check.sh" "PR workflow runs the vendored step script"
  assert_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" ".github/scripts/doc-superpowers-steps/freshness-check.sh" "schedule workflow runs the vendored step script"
  assert_contains "$(cat .github/scripts/doc-superpowers-steps/freshness-check.sh 2>/dev/null)" 'DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"' "…which runs the vendored doc-tools.sh"
  teardown
}

test_uninstall_ci_removes_claude_workflows() {
  echo "test: uninstall --ci removes Claude-powered workflows"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all >/dev/null 2>&1
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
  # git runs hooks from `git rev-parse --git-path hooks`; a .githooks/ that no
  # core.hooksPath names is never run, so a hook there was a false "installed".
  echo "test: install --git ignores a .githooks/ that core.hooksPath does not name (installs where git runs hooks)"
  setup
  mkdir -p .githooks
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/pre-commit" "hook in .git/hooks, where git runs it"
  assert_file_not_exists ".githooks/pre-commit" "nothing in the unconfigured .githooks/"
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
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-pr-release,doc-freshness-schedule 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-pr-release.yml" "doc-pr-release installed"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "doc-freshness-schedule installed"
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
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all >/dev/null 2>&1
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
  for args in "--ci --workflows=doc-pr-release" "--ci --workflows=doc-release,doc-pr-release" "--ci --workflows=all" "--all --workflows=all"; do
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
  assert_contains "$output" "doc-superpowers-steps helpers → $steps/" "reports the step-script install (doc-tools.sh tools install)"
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
  assert_eq "" "$(grep -lE '__[A-Z][A-Z0-9_]*__' .github/workflows/doc-*.yml || true)" \
    "$label: no placeholder survives in installed workflows"
}

test_install_ci_every_referenced_helper_is_installed() {
  # Installer output, not templates: after a default `install --ci`, every
  # `.github/scripts/...` path an installed workflow runs must exist.
  echo "test: install --ci --workflows=all — every script an installed workflow runs is on disk"
  setup
  local exit_code=0 refs
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "install --ci --workflows=all exits 0"
  refs=$(grep -hoE '\.github/scripts/[A-Za-z0-9_./-]+\.sh' .github/workflows/doc-*.yml | sort -u)
  assert_contains "$refs" ".github/scripts/doc-superpowers-steps/precheck.sh" "doc-release.yml runs its precheck step"
  assert_contains "$refs" ".github/scripts/doc-superpowers-steps/verify-fragment.sh" "doc-pr-release.yml runs its verify step"
  _assert_installed_workflows_wired "install --ci --workflows=all"
  teardown
}

test_install_ci_version_comes_from_doc_tools() {
  # install.sh:22 took the first "## vX.Y.Z" SUBSTRING of RELEASE-NOTES.md,
  # and under pipefail a file without one aborted the installer silently, so
  # its "unknown version" fallback was unreachable. The version is now
  # doc-tools.sh's one parse (tools version): the first release heading,
  # line-anchored and outside code fences.
  echo "test: install --ci — the substituted version is doc-tools.sh's; no RELEASE-NOTES.md falls back, never aborts"
  setup
  local root exit_code out
  root=$(harness_mktemp_d plugin)
  mkdir -p "$root/skills/doc-superpowers"
  cp "$SCRIPT_DIR/../skills/doc-superpowers/SKILL.md" "$root/skills/doc-superpowers/"
  cp -R "$SCRIPT_DIR" "$root/scripts"
  printf '%s\n' '# Release Notes' '' 'See ## v8.8.8 below.' '' '```md' '## v9.9.9 (example)' '```' '' \
    '## v1.2.3 (2026-01-01)' > "$root/RELEASE-NOTES.md"
  exit_code=0
  out=$("$BASH_BIN" "$root/scripts/hooks/install.sh" install --ci --workflows=doc-release 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "install exits 0"
  assert_contains "$(cat .github/workflows/doc-release.yml 2>/dev/null)" 'DOC_SUPERPOWERS_VERSION: "v1.2.3"' \
    "the version is the first release heading at a line start, outside a fence"
  rm -rf .github .claude "$root/RELEASE-NOTES.md"
  exit_code=0
  out=$("$BASH_BIN" "$root/scripts/hooks/install.sh" install --ci --workflows=doc-release 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "a plugin without RELEASE-NOTES.md still installs (the fallback is reachable)"
  assert_contains "$(cat .github/workflows/doc-release.yml 2>/dev/null)" 'DOC_SUPERPOWERS_VERSION: "vunknown"' \
    "…with the version unknown"
  assert_not_contains "$out" "ERROR" "…and no ERROR line in an install that succeeds"
  assert_eq "1" "$(grep -c 'WARN.*version' <<<"$out" || true)" "…one WARN about the version, where it is used"

  # Only rendering a template needs the version: status, uninstall and usage
  # never start doc-tools.sh for it (a log of every doc-tools.sh call proves
  # it), and so never warn about it.
  local log="$TEST_DIR/doc-tools-calls.log"
  mv "$root/scripts/doc-tools.sh" "$root/scripts/doc-tools.real.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "%s" "$@"\n' \
    "$log" "$BASH_BIN" "$root/scripts/doc-tools.real.sh" > "$root/scripts/doc-tools.sh"
  : > "$log"
  out=$("$BASH_BIN" "$root/scripts/hooks/install.sh" status 2>&1) || true
  out="$out$("$BASH_BIN" "$root/scripts/hooks/install.sh" uninstall --ci 2>&1)" || true
  out="$out$("$BASH_BIN" "$root/scripts/hooks/install.sh" help 2>&1)" || true
  assert_eq "" "$(grep 'tools version' "$log" || true)" "status / uninstall / usage never look the version up"
  assert_not_contains "$out" "RELEASE-NOTES" "…and say nothing about it"
  exit_code=0
  "$BASH_BIN" "$root/scripts/hooks/install.sh" install --ci --workflows=doc-release >/dev/null 2>&1 || exit_code=$?
  assert_eq "1" "$(grep -c '^tools version$' "$log" || true)" "a CI install looks it up once (precondition: the log sees the call)"
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
  echo "test: install --ci writes .claude/doc-superpowers/installed.json (the default set + the choices)"
  setup
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".claude/doc-superpowers/installed.json" "state file created"
  local f=.claude/doc-superpowers/installed.json
  assert_eq "doc-freshness-pr doc-freshness-schedule" \
    "$(jq -r '[.tiers.ci.workflows | to_entries[] | select(.value.state == "installed") | .key] | sort | join(" ")' "$f")" \
    "the two shell workflows (the default set) are recorded installed, nothing else"
  assert_eq "main|0 9 * * 1|false" "$(jq -r '.tiers.ci | "\(.base_branch)|\(.cron)|\(.ci_strict)"' "$f")" "the choices are recorded"
  assert_eq "null|null" "$(jq -r '.tiers.ci | "\(.tools)|\(.helpers)"' "$f")" "no write-only tools/helpers records"
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
  # The old fallback rebuilt the file from disk, so a merge-conflicted state
  # lost every "removed on purpose" record and the workflows came back.
  echo "test: install --ci refuses to overwrite an unparsable state file (nothing written)"
  setup
  mkdir -p .claude/doc-superpowers
  echo "{not valid json" > .claude/doc-superpowers/installed.json
  local before
  before=$(_fixture_snapshot)
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "installed.json.corrupt" "says how to recover (move it aside)"
  assert_eq "{not valid json" "$(cat .claude/doc-superpowers/installed.json)" "the state file is untouched"
  assert_eq "$before" "$(_fixture_snapshot)" "nothing written"
  teardown
}

test_uninstall_install_cycle_respects_intentional_uninstall() {
  echo "test: uninstall --ci then install --ci keeps intentionally-removed workflows uninstalled"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-freshness-schedule >/dev/null 2>&1
  assert_file_not_exists ".github/workflows/doc-freshness-schedule.yml" "uninstall removed doc-freshness-schedule"
  # State should say intentional.
  local intentional
  intentional=$(jq -r '.tiers.ci.workflows."doc-freshness-schedule".intentional' .claude/doc-superpowers/installed.json)
  assert_eq "true" "$intentional" "marked intentional"
  # Now re-install — doc-freshness-schedule should stay GONE.
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "install exits 0"
  assert_file_not_exists ".github/workflows/doc-freshness-schedule.yml" "doc-freshness-schedule stays uninstalled"
  assert_contains "$output" "skipping doc-freshness-schedule.yml" "skip message shown"
  assert_contains "$output" "--workflows=doc-freshness-schedule" "override hint shown"
  # Other workflows should be re-installed.
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "other workflows present"
  teardown
}

test_uninstall_transient_then_install_reinstalls() {
  echo "test: uninstall --ci --transient lets next install --ci re-install"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-freshness-schedule --transient >/dev/null 2>&1
  local intentional
  intentional=$(jq -r '.tiers.ci.workflows."doc-freshness-schedule".intentional' .claude/doc-superpowers/installed.json)
  assert_eq "false" "$intentional" "marked transient"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "doc-freshness-schedule re-installed"
  assert_not_contains "$output" "skipping doc-freshness-schedule.yml" "no skip message"
  teardown
}

test_install_force_bypasses_intentional_uninstall() {
  echo "test: install --ci --force re-installs intentionally-uninstalled workflows"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-freshness-schedule >/dev/null 2>&1
  assert_file_not_exists ".github/workflows/doc-freshness-schedule.yml" "uninstall removed doc-freshness-schedule"
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --force 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "doc-freshness-schedule re-installed via --force"
  assert_not_contains "$output" "skipping doc-freshness-schedule.yml" "no skip message with --force"
  teardown
}

test_install_explicit_workflows_overrides_state() {
  echo "test: install --ci --workflows=<name> beats state-respect (explicit > implicit)"
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-freshness-schedule >/dev/null 2>&1
  # Explicit re-add — should NOT skip even though state says intentional:uninstalled.
  set +e
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-schedule 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "doc-freshness-schedule re-installed via explicit --workflows"
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

# --- I-7: installer ownership, placement, integration, state -----------------
#
# The installer used to guess: any settings group mentioning "doc-superpowers"
# was its own; cwd was the top and .git a directory; the host hook was bash;
# every sibling of the skill dir was a plugin version; writes followed links;
# "installed" was all the state. Each test below pins the real rule.

# The Claude gate's entries in .claude/settings.local.json.
_gate_entries() {
  jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains(".claude/hooks/doc-superpowers/pre-commit-gate.sh"))] | length' \
    .claude/settings.local.json
}

test_i7_claude_user_groups_survive() {
  echo "test: I-7 install/uninstall --claude own hook ENTRIES by exact path: user groups mentioning doc-superpowers survive byte-for-byte"
  setup
  local f=.claude/settings.local.json orig
  orig=$(harness_mktemp settings)
  mkdir -p .claude
  jq -n '{
    permissions: {allow: ["Read"]},
    hooks: {
      PreToolUse: [
        {matcher: "Bash", hooks: [{type: "command", command: "echo doc-superpowers-lint"}]},
        {matcher: "Edit", hooks: [{type: "prompt", prompt: "check the doc-superpowers docs"}]}
      ],
      Stop: [{matcher: "", hooks: [{type: "command", command: "notify \"doc-superpowers done\""}]}]
    }
  }' > "$f"
  cp "$f" "$orig"
  inst install --claude
  assert_eq "0" "$IRC" "install exits 0 (a type:prompt hook no longer crashes the merge)"
  assert_eq "$(jq -c '.hooks.PreToolUse[0:2]' "$orig")" "$(jq -c '.hooks.PreToolUse[0:2]' "$f")" "install: your PreToolUse groups are intact"
  assert_eq "$(jq -c '.hooks.Stop[0]' "$orig")" "$(jq -c '.hooks.Stop[0]' "$f")" "install: your Stop group is intact"
  assert_eq "1" "$(_gate_entries)" "install: one gate entry"
  inst install --claude
  assert_eq "1" "$(_gate_entries)" "re-install: still one gate entry"
  assert_eq "$(jq -c '.hooks.PreToolUse[0:2]' "$orig")" "$(jq -c '.hooks.PreToolUse[0:2]' "$f")" "re-install: your groups are intact"
  inst uninstall --claude
  assert_eq "0" "$IRC" "uninstall exits 0"
  assert_true "uninstall: the settings file is byte-identical to before the install" cmp -s "$orig" "$f"
  # An entry of yours put into the group the installer created is yours.
  inst install --claude
  jq '.hooks.PreToolUse |= map(if any(.hooks[]; (.command // "") | contains("doc-superpowers/pre-commit-gate.sh"))
        then .hooks += [{type: "command", command: "echo mine"}] else . end)' "$f" > "$f.new"
  mv "$f.new" "$f"
  inst uninstall --claude
  assert_contains "$(cat "$f")" "echo mine" "your entry inside the installer's group survives uninstall"
  assert_not_contains "$(cat "$f")" "doc-superpowers/pre-commit-gate.sh" "…while the installer's entries are gone"
  teardown
}

test_i7_claude_settings_edge_files() {
  echo "test: I-7 install --claude: a 0-byte settings file gets the hooks; an unreadable one is refused, nothing written"
  setup
  mkdir -p .claude
  : > .claude/settings.local.json
  inst install --claude
  assert_eq "0" "$IRC" "0-byte settings: exits 0"
  assert_eq "1" "$(_gate_entries 2>/dev/null || echo none)" "0-byte settings: the gate is registered (not an 'install' into an empty file)"
  teardown
  local body before
  for body in '{"hooks": ' '{"hooks": {"PreToolUse": {"not": "an array"}}}' '[1, 2]'; do
    setup
    mkdir -p .claude
    printf '%s\n' "$body" > .claude/settings.local.json
    before=$(_tree_state)
    inst install --claude
    assert_eq "1" "$IRC" "settings '$body': exits 1"
    assert_contains "$IOUT" "settings.local.json" "settings '$body': names the file"
    assert_eq "$before" "$(_tree_state)" "settings '$body': nothing written (no scripts, no exclude entry)"
    teardown
  done
}

test_i7_symlinked_write_targets_refused() {
  echo "test: I-7 a committed symlink at a write target (file, dangling, parent dir) makes install refuse; nothing written, nothing through the link"
  local spec link kind tier outside before seen t
  for spec in \
    ".claude|dir|--claude" \
    ".claude/hooks|dir|--claude" \
    ".claude/settings.local.json|file|--claude" \
    ".github|dir|--ci" \
    ".github/workflows|dir|--ci" \
    ".github/workflows/doc-freshness-pr.yml|file|--ci" \
    ".github/scripts/doc-tools.sh|dangling|--ci" \
    ".claude/doc-superpowers/installed.json|file|--ci" \
    ".gitattributes|file|--git" \
    ".githooks/pre-commit|file|--git"; do
    IFS='|' read -r link kind tier <<<"$spec"
    setup
    outside=$(harness_mktemp_d outside)
    mkdir -p "$outside/d"
    echo keep > "$outside/d/keep"
    echo "export PS1=mine" > "$outside/f"
    mkdir -p "$(dirname "$link")"
    case "$kind" in
      dir) ln -s "$outside/d" "$link" ;;
      file) ln -s "$outside/f" "$link" ;;
      dangling) ln -s "$outside/missing" "$link" ;;
    esac
    if [ "$link" = ".githooks/pre-commit" ]; then
      git config core.hooksPath .githooks
    fi
    git add -A && git commit -qm "a committed link"
    before=$(_tree_state)
    seen=$(find "$outside" | LC_ALL=C sort; cat "$outside/f" "$outside/d/keep")
    for t in "$tier" --all; do
      inst install "$t"
      assert_eq "1" "$IRC" "$link ($kind): install $t exits 1"
      assert_contains "$IOUT" "symbolic link" "$link ($kind): install $t says why"
      assert_eq "$before" "$(_tree_state)" "$link ($kind): install $t writes nothing in the repository"
      assert_eq "$seen" "$(find "$outside" | LC_ALL=C sort; cat "$outside/f" "$outside/d/keep")" \
        "$link ($kind): install $t writes nothing through the link"
    done
    teardown
  done
}

test_i7_uninstall_never_deletes_through_links() {
  echo "test: I-7 uninstall --ci refuses a symlinked .github/scripts (it would delete the link target's files)"
  setup
  inst install --ci
  local outside
  outside=$(harness_mktemp_d outside)
  cp .github/scripts/doc-tools.sh "$outside/doc-tools.sh"
  rm -rf .github/scripts
  ln -s "$outside" .github/scripts
  inst uninstall --ci
  assert_eq "1" "$IRC" "exits 1"
  assert_contains "$IOUT" "symbolic link" "says why"
  assert_file_exists "$outside/doc-tools.sh" "the file behind the link is not deleted"
  teardown
}

test_i7_integration_posix_host() {
  echo "test: I-7 integration into a #!/bin/sh hook: ours runs with git's arguments; its STRICT exit code stops the commit; yours still runs"
  local shell
  for shell in /bin/sh /bin/dash; do
    if [ ! -x "$shell" ]; then
      record_skip "integration under $shell (not installed)"
      continue
    fi
    indexed_fixture
    printf '#!%s\necho "host ran" >> "$(git rev-parse --git-dir)/host.log"\nexit 0\n' "$shell" > .git/hooks/pre-commit
    printf '#!%s\necho "host:$1:$2" >> "$(git rev-parse --git-dir)/host-msg.log"\n' "$shell" > .git/hooks/prepare-commit-msg
    chmod +x .git/hooks/pre-commit .git/hooks/prepare-commit-msg
    install_tiers --git
    # Ours, replaced by a probe that logs what the block hands it.
    printf '#!/bin/sh\necho "ours:$1:$2" >> "$(git rev-parse --git-dir)/ours-msg.log"\n' > .git/hooks/.doc-superpowers-prepare-commit-msg
    stage_stale_change
    run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
    assert_eq "1" "$RUN_RC" "$shell host: the STRICT stale commit is blocked (our exit code propagates)"
    assert_contains "$RUN_ERR" "docs/architecture.md" "$shell host: our report reaches you (stderr kept)"
    assert_not_contains "$RUN_ERR" "not found" "$shell host: no bash-only syntax in the block"
    run_hooked -- git commit -qm y
    assert_eq "0" "$RUN_RC" "$shell host: the advisory commit goes through"
    assert_contains "$(cat .git/host.log 2>/dev/null)" "host ran" "$shell host: your pre-commit still runs"
    assert_contains "$(cat .git/ours-msg.log 2>/dev/null)" "COMMIT_EDITMSG:message" "$shell host: ours gets git's arguments"
    assert_contains "$(cat .git/host-msg.log 2>/dev/null)" "COMMIT_EDITMSG:message" "$shell host: yours still gets them"
    teardown
  done
}

test_i7_integration_exec_host() {
  echo "test: I-7 integration into a hook that ends in exec (the pre-commit framework's shape): ours runs first"
  indexed_fixture
  printf '#!/usr/bin/env bash\n# generated by a hook framework\nexec true "$@"\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  install_tiers --git
  stage_stale_change
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "the STRICT stale commit is blocked: the block runs before the exec"
  teardown
}

test_i7_integration_pre_push_stdin() {
  echo "test: I-7 integration into pre-push: ours and yours both get git's arguments and the ref lines on stdin"
  setup
  printf '#!/bin/sh\n{ echo "args:$1:$2"; cat; } > "$(git rev-parse --git-dir)/host-push.log"\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  install_tiers --git
  printf '#!/bin/sh\n{ echo "args:$1:$2"; cat; } > "$(git rev-parse --git-dir)/ours-push.log"\n' > .git/hooks/.doc-superpowers-pre-push
  local refs="refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 0000000000000000000000000000000000000000"
  printf '%s\n' "$refs" | PATH="$REAL_PATH" sh .git/hooks/pre-push origin /srv/remote.git >/dev/null 2>&1 || true
  assert_eq "args:origin:/srv/remote.git
$refs" "$(cat .git/ours-push.log 2>/dev/null)" "ours: the arguments and the ref lines"
  assert_eq "args:origin:/srv/remote.git
$refs" "$(cat .git/host-push.log 2>/dev/null)" "yours: the arguments and the same ref lines"
  teardown
}

test_i7_integration_once_and_exact_inverse() {
  echo "test: I-7 one block after the #! line (an early exit 0 gets none); re-install refreshes our copy; uninstall restores your hook byte-for-byte"
  setup
  local orig
  orig=$(harness_mktemp host)
  printf '#!/bin/sh\n[ -n "$SKIP_ME" ] && exit 0\necho host\nexit 0\n' > .git/hooks/post-merge
  chmod 750 .git/hooks/post-merge
  cp -p .git/hooks/post-merge "$orig"
  inst install --git
  assert_eq "1" "$(grep -c '^# doc-superpowers:begin' .git/hooks/post-merge)" "exactly one block"
  assert_eq "#!/bin/sh" "$(sed -n 1p .git/hooks/post-merge)" "your #! line stays first"
  assert_contains "$(sed -n 2p .git/hooks/post-merge)" "# doc-superpowers:begin" "the block comes right after it"
  echo "# tampered" >> .git/hooks/.doc-superpowers-post-merge
  inst install --git
  assert_eq "1" "$(grep -c '^# doc-superpowers:begin' .git/hooks/post-merge)" "re-install: still one block"
  assert_not_contains "$(cat .git/hooks/.doc-superpowers-post-merge)" "# tampered" "re-install refreshes our local copy"
  assert_contains "$(head -3 .git/hooks/.doc-superpowers-post-merge)" "doc-superpowers hook v1" "…with the current hook"
  inst uninstall --git
  assert_true "uninstall restores your hook byte-for-byte" cmp -s "$orig" .git/hooks/post-merge
  assert_eq "$(ls -l "$orig" | cut -c1-10)" "$(ls -l .git/hooks/post-merge | cut -c1-10)" "…and its mode"
  assert_file_not_exists ".git/hooks/.doc-superpowers-post-merge" "our local copy is removed"
  teardown
}

test_i7_integration_skips_non_shell_host() {
  echo "test: I-7 a hook of yours in another language is left alone (a shell block would break it)"
  setup
  local orig
  orig=$(harness_mktemp host)
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  cp .git/hooks/pre-commit "$orig"
  inst install --git
  assert_eq "0" "$IRC" "exits 0"
  assert_true "your python hook is byte-identical" cmp -s "$orig" .git/hooks/pre-commit
  assert_contains "$IOUT" "not a shell script" "says why it was skipped"
  assert_file_not_exists ".git/hooks/.doc-superpowers-pre-commit" "no orphan local copy"
  teardown
}

test_i7_integration_upgrades_legacy_block() {
  echo "test: I-7 re-install replaces the pre-3.0 block (it dropped args and the exit code); uninstall leaves your original hook"
  setup
  local orig
  orig=$(harness_mktemp host)
  printf '#!/bin/bash\necho "existing"\nexit 0\n' > "$orig"
  # What the pre-3.0 installer made of it: its block before `exit 0`, and a blank line.
  printf '#!/bin/bash\necho "existing"\n# doc-superpowers:begin\nDOC_SP_HOOK="$(dirname "$0")/.doc-superpowers-pre-commit"\nif [[ -f "$DOC_SP_HOOK" ]]; then\n    bash "$DOC_SP_HOOK" 2>/dev/null || true\nfi\n# doc-superpowers:end\n\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  echo "old copy" > .git/hooks/.doc-superpowers-pre-commit
  inst install --git
  assert_eq "0" "$IRC" "exits 0"
  assert_eq "1" "$(grep -c '^# doc-superpowers:begin' .git/hooks/pre-commit)" "one block"
  assert_not_contains "$(cat .git/hooks/pre-commit)" '2>/dev/null || true' "the old block is gone"
  assert_contains "$(cat .git/hooks/pre-commit)" 'bash "$DOC_SP_HOOK" "$@" || exit $?' "the current block is in"
  assert_not_contains "$(cat .git/hooks/.doc-superpowers-pre-commit)" "old copy" "the local copy is refreshed"
  inst uninstall --git
  assert_true "uninstall leaves your hook as it was before any doc-superpowers install" cmp -s "$orig" .git/hooks/pre-commit
  teardown
}

test_i7_placement_linked_worktree() {
  echo "test: I-7 install from a linked worktree: hooks where git runs them (the common dir), files at the worktree's top"
  indexed_fixture
  git worktree add -q -b wt "$TEST_DIR/wt" >/dev/null 2>&1
  echo "wt/" >> .git/info/exclude
  cd "$TEST_DIR/wt" || return 1
  inst install --git --ci
  assert_eq "0" "$IRC" "exits 0"
  assert_file_exists "$TEST_DIR/.git/hooks/pre-commit" "pre-commit in the common hooks dir"
  assert_file_exists "$TEST_DIR/wt/.github/workflows/doc-freshness-pr.yml" "workflows at the worktree's top"
  assert_file_not_exists "$TEST_DIR/.github/workflows/doc-freshness-pr.yml" "…not in the main work tree"
  printf '.github/\n.gitattributes\n.claude/\n' >> "$TEST_DIR/.git/info/exclude"
  stage_stale_change
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "a commit in the worktree runs the installed hook (STRICT blocks it)"
  cd "$TEST_DIR" || return 1
  teardown
}

test_i7_placement_submodule() {
  echo "test: I-7 install from a submodule: hooks in its git dir (the superproject's .git/modules/<name>/hooks)"
  setup
  local src hd
  src=$(harness_mktemp_d subsrc)
  (cd "$src" && git init -q -b main && echo x > f && git add f && git commit -qm s) >/dev/null 2>&1
  git -c protocol.file.allow=always submodule add -q "$src" sub >/dev/null 2>&1
  git commit -qm "add sub"
  cd sub || return 1
  inst install --git
  assert_eq "0" "$IRC" "exits 0"
  hd=$(git rev-parse --git-path hooks)
  assert_file_exists "$hd/pre-commit" "pre-commit where git runs the submodule's hooks"
  assert_contains "$hd" "modules/sub" "…the superproject's .git/modules/sub/hooks"
  cd "$TEST_DIR" || return 1
  teardown
}

test_i7_placement_subdirectory() {
  echo "test: I-7 install --all from a subdirectory writes at the repository top"
  setup
  cd src || return 1
  inst install --all
  cd "$TEST_DIR" || return 1
  assert_eq "0" "$IRC" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "workflows at the top"
  assert_file_exists ".claude/settings.local.json" "Claude settings at the top"
  assert_file_exists ".git/hooks/pre-commit" "git hooks where git runs them"
  assert_true "nothing written under src/" test ! -e src/.github -a ! -e src/.claude -a ! -e src/.gitattributes
  teardown
}

test_i7_hooks_path_scope() {
  echo "test: I-7 a global core.hooksPath is refused (it is every repository's hooks dir); a local '~/…' one is expanded"
  setup
  local g before
  g=$(harness_mktemp_d global)
  mkdir -p "$g/hooks"
  printf '[core]\n\thooksPath = %s\n' "$g/hooks" > "$g/config"
  before=$(_tree_state)
  export GIT_CONFIG_GLOBAL="$g/config"
  inst install --git
  local rc="$IRC" out="$IOUT"
  inst status
  local status_out="$IOUT"
  export GIT_CONFIG_GLOBAL=/dev/null
  assert_eq "1" "$rc" "install --git exits 1"
  assert_contains "$out" "core.hooksPath" "names core.hooksPath"
  assert_contains "$out" "global" "…and its scope"
  assert_eq "" "$(ls -A "$g/hooks")" "the global hooks dir stays empty"
  assert_eq "$before" "$(_tree_state)" "nothing written (no .gitattributes, no merge driver)"
  assert_contains "$status_out" "global" "status says the hooks dir is a global one"
  git config core.hooksPath '~/myhooks'
  inst install --git
  assert_eq "0" "$IRC" "local '~/myhooks': exits 0"
  assert_file_exists "$HOME/myhooks/pre-commit" "…installed in \$HOME/myhooks, where git runs it"
  assert_true "…no literal '~' directory" test ! -e "./~"
  teardown
}

test_i7_doc_tools_resolution_plugin_cache() {
  echo "test: I-7 hooks of a plugin-cache install (path with a space) run the newest version-named sibling's doc-tools.sh, never another sibling"
  indexed_fixture
  local cache sent v
  cache="$(harness_mktemp_d cache)/plugin cache/doc-superpowers"
  plugin_copy "$cache/1.0.0"
  sent=$(harness_mktemp sentinel)
  mkdir -p "$cache/zzz/scripts"
  printf '#!/bin/sh\necho zzz >> "%s"\nexit 0\n' "$sent" > "$cache/zzz/scripts/doc-tools.sh"
  chmod +x "$cache/zzz/scripts/doc-tools.sh"
  inst --from "$cache/1.0.0/scripts/hooks/install.sh" install --git
  assert_eq "0" "$IRC" "install exits 0"
  printf '.gitattributes\n' >> .git/info/exclude
  stage_stale_change
  run_hooked DOC_TOOLS= DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "the hook found 1.0.0's doc-tools.sh (a path with spaces) and blocked the stale commit"
  assert_eq "" "$(cat "$sent")" "the non-version sibling 'zzz' never ran"
  for v in 1.9.0 1.10.0; do
    mkdir -p "$cache/$v/scripts"
    printf '#!/bin/sh\necho %s >> "%s"\nexit 0\n' "$v" "$sent" > "$cache/$v/scripts/doc-tools.sh"
    chmod +x "$cache/$v/scripts/doc-tools.sh"
  done
  run_hooked DOC_TOOLS= -- git commit -qm y
  assert_eq "1.10.0" "$(cat "$sent")" "a plugin update is picked up in numeric order (1.10.0 > 1.9.0), no re-install"
  teardown
}

test_i7_doc_tools_resolution_checkout() {
  echo "test: I-7 hooks of a checkout install run its own doc-tools.sh (path quoted), never a version-named sibling"
  indexed_fixture
  local root sent
  root="$(harness_mktemp_d co)/my checkout"
  plugin_copy "$root/doc superpowers"
  sent=$(harness_mktemp sentinel)
  mkdir -p "$root/9.9.9/scripts"
  printf '#!/bin/sh\necho 9.9.9 >> "%s"\nexit 0\n' "$sent" > "$root/9.9.9/scripts/doc-tools.sh"
  chmod +x "$root/9.9.9/scripts/doc-tools.sh"
  inst --from "$root/doc superpowers/scripts/hooks/install.sh" install --git
  assert_eq "0" "$IRC" "install exits 0"
  printf '.gitattributes\n' >> .git/info/exclude
  stage_stale_change
  run_hooked DOC_TOOLS= DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "the pinned path (with spaces) resolves and the stale commit is blocked"
  assert_eq "" "$(cat "$sent")" "the sibling 9.9.9 never ran"
  teardown
}

test_i7_ci_values_validated() {
  echo "test: I-7 install --ci rejects a --base-branch / --cron that would corrupt a workflow; nothing written"
  setup
  local before
  before=$(_tree_state)
  _bad_ci() {
    inst install --ci "$@"
    assert_eq "1" "$IRC" "install --ci $*: exits 1"
    assert_eq "$before" "$(_tree_state)" "install --ci $*: nothing written"
  }
  _bad_ci --base-branch 'a|b'
  _bad_ci --base-branch "a'b"
  _bad_ci --base-branch 'a..b'
  _bad_ci --base-branch 'x]'
  _bad_ci --cron '0|9 * * * *'
  _bad_ci --cron '0 9 * *'
  _bad_ci --cron "0 9 * * 1'"
  assert_contains "$IOUT" "--cron" "the message names the option"
  teardown
}

# The rendered workflows and the state file, by content.
_ci_snapshot() {
  local f
  for f in .github/workflows/*.yml .claude/doc-superpowers/installed.json; do
    [ -f "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"
  done
}

test_i7_plain_reinstall_reproduces_choices() {
  echo "test: I-7 a plain 'install --ci' reproduces the recorded choices (strict, branch, cron, workflow set); no file churn"
  setup
  inst install --ci --ci-strict --base-branch develop --cron '0 6 * * 1' --workflows=doc-freshness-pr,doc-freshness-schedule,doc-release
  assert_eq "0" "$IRC" "first install exits 0"
  local snap
  snap=$(_ci_snapshot)
  inst install --ci
  assert_eq "0" "$IRC" "plain re-install exits 0"
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" 'DOC_SUPERPOWERS_STRICT: "1"' "strict kept"
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "branches: [develop]" "base branch kept"
  assert_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "0 6 * * 1" "cron kept"
  assert_file_exists ".github/workflows/doc-release.yml" "the opted-in AI workflow is kept"
  assert_eq "doc-freshness-pr.yml doc-freshness-schedule.yml doc-release.yml" \
    "$(cd .github/workflows && printf '%s ' *.yml | sed 's/ $//')" "exactly the recorded set (nothing added)"
  assert_eq "$snap" "$(_ci_snapshot)" "workflows and state file byte-identical (no timestamp rewrite)"
  local f=.claude/doc-superpowers/installed.json
  assert_eq "develop|0 6 * * 1|true" "$(jq -r '.tiers.ci | "\(.base_branch)|\(.cron)|\(.ci_strict)"' "$f")" "the choices are recorded"
  inst install --ci --ci-strict=false
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" 'DOC_SUPERPOWERS_STRICT: "0"' "--ci-strict=false changes the recorded choice"
  teardown
}

test_i7_legacy_install_choices_inferred() {
  echo "test: I-7 upgrading a pre-3.0 install (state without choices): the rendered workflows' choices are kept"
  setup
  mkdir -p .github/workflows .claude/doc-superpowers
  sed -e 's|__BASE_BRANCH__|develop|g' -e 's|__CI_STRICT__|1|g' "$HOOKS_DIR/ci/doc-freshness-pr.yml" > .github/workflows/doc-freshness-pr.yml
  sed -e "s|__CRON_SCHEDULE__|0 5 * * 2|g" "$HOOKS_DIR/ci/doc-freshness-schedule.yml" > .github/workflows/doc-freshness-schedule.yml
  printf '%s\n' '{"schema_version": 1, "tiers": {"ci": {"workflows": {"doc-freshness-pr": {"state": "installed", "installed_at": "2025-01-01T00:00:00Z"}, "doc-freshness-schedule": {"state": "installed", "installed_at": "2025-01-01T00:00:00Z"}}, "tools": {"state": "installed"}}}}' \
    > .claude/doc-superpowers/installed.json
  inst install --ci
  assert_eq "0" "$IRC" "exits 0"
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" 'DOC_SUPERPOWERS_STRICT: "1"' "strict kept (read from the installed workflow)"
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "branches: [develop]" "base branch kept"
  assert_contains "$(cat .github/workflows/doc-freshness-schedule.yml)" "0 5 * * 2" "cron kept"
  assert_eq "doc-freshness-pr.yml doc-freshness-schedule.yml" \
    "$(cd .github/workflows && printf '%s ' *.yml | sed 's/ $//')" "the installed set is kept"
  local f=.claude/doc-superpowers/installed.json
  assert_eq "develop|0 5 * * 2|true|2025-01-01T00:00:00Z|null" \
    "$(jq -r '.tiers.ci | "\(.base_branch)|\(.cron)|\(.ci_strict)|\(.workflows["doc-freshness-pr"].installed_at)|\(.tools)"' "$f")" \
    "the choices are now recorded; installed_at kept; the write-only tools record dropped"
  teardown
}

test_i7_uninstall_unknown_workflow_fails() {
  echo "test: I-7 uninstall --ci --workflows=<typo> exits non-zero and changes nothing"
  setup
  inst install --ci
  local before
  before=$(_tree_state)
  inst uninstall --ci --workflows=doc-freshnes-pr
  assert_eq "1" "$IRC" "exits 1"
  assert_contains "$IOUT" "unknown workflow name: doc-freshnes-pr" "names the typo"
  assert_eq "$before" "$(_tree_state)" "nothing changed"
  teardown
}

test_i7_install_uninstall_leaves_no_residue() {
  echo "test: I-7 install --all then uninstall --all leaves nothing behind but the state file"
  setup
  local before after
  before=$(_tree_state)
  inst install --all
  assert_eq "0" "$IRC" "install --all exits 0"
  inst uninstall --all
  assert_eq "0" "$IRC" "uninstall --all exits 0"
  after=$(_tree_state | grep -v -e '^\./\.claude/$' -e '^\./\.claude/doc-superpowers/$' -e '^\./\.claude/doc-superpowers/installed\.json ')
  assert_eq "$before" "$after" "work tree, hooks, info/exclude and git config are as before"
  assert_file_exists ".claude/doc-superpowers/installed.json" "the state file stays (it records the removal)"
  teardown
}

test_i7_default_ci_set_and_help() {
  echo "test: I-7 install --ci defaults to the two shell workflows; help lists every hook and workflow"
  setup
  inst install --ci
  assert_eq "0" "$IRC" "exits 0"
  assert_eq "doc-freshness-pr.yml doc-freshness-schedule.yml" \
    "$(cd .github/workflows && printf '%s ' *.yml | sed 's/ $//')" "the two shell workflows, no AI template"
  inst help
  assert_eq "0" "$IRC" "help exits 0"
  local n
  for n in pre-commit post-merge post-checkout prepare-commit-msg pre-push pre-commit-gate post-commit-sync session-summary \
    $(cd "$HOOKS_DIR/ci" && for w in *.yml; do printf '%s ' "${w%.yml}"; done); do
    assert_contains "$IOUT" "$n" "help lists $n"
  done
  teardown
}

test_i7_flags_outside_scope_exit_2() {
  echo "test: I-7 a flag outside the command's scope exits 2 and changes nothing"
  setup
  inst install --ci
  local before args
  before=$(_tree_state)
  for args in "status --ci --workflows=bogus" "status --force" "uninstall --ci --helpers=false" "uninstall --ci --force" \
    "uninstall --git --transient" "install --git --transient" "install --git --base-branch=dev" "install --claude --ci-strict"; do
    # shellcheck disable=SC2086  # intentional word-splitting of the flag set
    inst $args
    assert_eq "2" "$IRC" "$args: exits 2"
    assert_eq "$before" "$(_tree_state)" "$args: nothing changed"
  done
  teardown
}

test_i7_workflows_csv_edges() {
  echo "test: I-7 --workflows=, and --workflows= are errors; a repeated name installs once"
  setup
  local before
  before=$(_tree_state)
  inst install --ci --workflows=,
  assert_eq "1" "$IRC" "--workflows=, exits 1"
  assert_contains "$IOUT" "names no workflow" "…and says so"
  inst install --ci --workflows=
  assert_eq "1" "$IRC" "--workflows= exits 1"
  assert_eq "$before" "$(_tree_state)" "nothing written"
  inst install --ci --workflows=doc-freshness-pr,doc-freshness-pr
  assert_eq "0" "$IRC" "a repeated name: exits 0"
  assert_contains "$IOUT" "1 installed" "…and installs it once"
  teardown
}

test_i7_unreadable_state_refused_and_recovery() {
  echo "test: I-7 an unreadable state file is never overwritten; status warns once; moved aside, nothing absent on disk is installed"
  setup
  inst install --ci --workflows=doc-freshness-pr
  local f=.claude/doc-superpowers/installed.json before
  printf '<<<<<<< ours\n{}\n=======\n{"x": 1}\n>>>>>>> theirs\n' > "$f"
  before=$(_tree_state)
  inst install --ci
  assert_eq "1" "$IRC" "install: exits 1"
  inst uninstall --ci
  assert_eq "1" "$IRC" "uninstall: exits 1"
  assert_eq "$before" "$(_tree_state)" "install / uninstall wrote nothing"
  inst status
  assert_eq "0" "$IRC" "status exits 0"
  assert_eq "1" "$(grep -c 'installed.json' <<<"$IOUT")" "status warns once"
  printf '{"tiers": 5}\n' > "$f"
  inst install --ci
  assert_eq "1" "$IRC" "valid JSON of the wrong shape: install exits 1"
  inst status
  assert_eq "0" "$IRC" "…status still exits 0"
  mv "$f" "$f.corrupt"
  inst install --ci
  assert_eq "0" "$IRC" "moved aside: install exits 0"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "…the workflow on disk is refreshed"
  assert_file_not_exists ".github/workflows/doc-freshness-schedule.yml" "…nothing absent on disk is installed"
  assert_eq "installed" "$(jq -r '.tiers.ci.workflows["doc-freshness-pr"].state' "$f")" "…the state is rebuilt from disk"
  teardown
}

test_i7_uninstall_without_workflows_dir() {
  echo "test: I-7 uninstall --ci with no .github/workflows/ still removes the vendored tool"
  setup
  inst install --ci --workflows=none
  rm -rf .github/workflows
  inst uninstall --ci
  assert_eq "0" "$IRC" "exits 0"
  assert_file_not_exists ".github/scripts/doc-tools.sh" "the vendored doc-tools.sh is removed"
  teardown
}

test_i7_state_reconciled_with_disk() {
  echo "test: I-7 a managed workflow on disk is installed, whatever the state says: status shows it, a plain install refreshes it"
  setup
  inst install --ci --ci-strict
  inst uninstall --ci --workflows=doc-freshness-pr
  sed -e 's|__BASE_BRANCH__|main|g' -e 's|__CI_STRICT__|0|g' "$HOOKS_DIR/ci/doc-freshness-pr.yml" > .github/workflows/doc-freshness-pr.yml
  inst status
  assert_contains "$(grep 'doc-freshness-pr.yml' <<<"$IOUT")" "installed" "status: installed"
  assert_not_contains "$(grep 'doc-freshness-pr.yml' <<<"$IOUT")" "uninstalled" "…not 'uninstalled'"
  inst install --ci
  assert_eq "0" "$IRC" "install exits 0"
  assert_contains "$(cat .github/workflows/doc-freshness-pr.yml)" 'DOC_SUPERPOWERS_STRICT: "1"' "refreshed with the recorded choices"
  assert_eq "installed" "$(jq -r '.tiers.ci.workflows["doc-freshness-pr"].state' .claude/doc-superpowers/installed.json)" "state reconciled"
  teardown
}

test_i7_claude_tier_is_per_user() {
  echo "test: I-7 the Claude tier is per-user: its files are git-excluded (info/exclude), its commands use \$CLAUDE_PROJECT_DIR"
  setup
  local orig
  orig=$(harness_mktemp exclude)
  cp .git/info/exclude "$orig"
  inst install --claude
  assert_eq "0" "$IRC" "exits 0"
  assert_contains "$(cat .git/info/exclude)" ".claude/settings.local.json" "settings.local.json is excluded"
  assert_contains "$(cat .git/info/exclude)" ".claude/hooks/doc-superpowers/" "the hook scripts are excluded"
  assert_eq "" "$(git status --porcelain --untracked-files=all -- .claude)" "nothing under .claude/ is offered to git add"
  assert_contains "$(registered_cmd PreToolUse pre-commit-gate)" '"$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/pre-commit-gate.sh' "commands use \$CLAUDE_PROJECT_DIR"
  inst uninstall --claude
  assert_true "uninstall restores info/exclude byte-for-byte" cmp -s "$orig" .git/info/exclude
  # An exclude entry cannot hide a tracked file: the installer says so.
  mkdir -p .claude
  echo '{}' > .claude/settings.local.json
  git add .claude/settings.local.json && git commit -qm "tracked settings"
  inst install --claude
  assert_contains "$IOUT" "is tracked by git" "a tracked settings.local.json is reported (untrack it to stay per-user)"
  teardown
}

test_i7_claude_hooks_run_from_path_with_spaces() {
  echo "test: I-7 the registered Claude commands work in a project whose path has spaces"
  setup
  local p="$TEST_DIR/my project"
  mkdir -p "$p/docs" "$p/src"
  cd "$p" || return 1
  git init -q -b main
  echo "# A" > docs/architecture.md
  echo "x" > src/index.js
  git add -A && git commit -qm init
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index >/dev/null 2>&1
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  git add docs/.doc-index.json && git commit -qm index
  inst install --claude
  assert_eq "0" "$IRC" "install exits 0"
  stage_stale_change
  local cmd
  cmd=$(registered_cmd PreToolUse pre-commit-gate)
  RUN_STDIN=$(harness_mktemp payload)
  pretool_json 'git commit -m x' > "$RUN_STDIN"
  run_hooked CLAUDE_PROJECT_DIR="$p" DOC_SUPERPOWERS_STRICT=1 -- sh -c "$cmd"
  RUN_STDIN=/dev/null
  assert_eq "2" "$RUN_RC" "the gate ran from '$p' and blocked the stale commit"
  cd "$TEST_DIR" || return 1
  teardown
}

test_i7_gate_probe_agrees_with_integration_block() {
  echo "test: I-7 the Claude gate counts the git pre-commit as checking only when it is ours or holds the current block + its copy"
  hooked_fixture
  echo "changed" > src/index.js
  local ours ctx
  ours=$(harness_mktemp ours)
  mv .git/hooks/pre-commit "$ours"
  printf '#!/bin/sh\n# see the doc-superpowers docs\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "no doc-superpowers git pre-commit hook" "a hook that only mentions doc-superpowers checks nothing"
  printf '#!/bin/bash\n# doc-superpowers:begin\nDOC_SP_HOOK="$(dirname "$0")/.doc-superpowers-pre-commit"\nif [[ -f "$DOC_SP_HOOK" ]]; then\n    bash "$DOC_SP_HOOK" 2>/dev/null || true\nfi\n# doc-superpowers:end\nexit 0\n' > .git/hooks/pre-commit
  cp "$ours" .git/hooks/.doc-superpowers-pre-commit
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "no doc-superpowers git pre-commit hook" "the pre-3.0 block (it dropped the exit code) does not count"
  printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
  rm -f .git/hooks/.doc-superpowers-pre-commit
  inst install --git
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')"
  ctx=$(out_field .hookSpecificOutput.additionalContext)
  assert_contains "$ctx" "The doc-superpowers git pre-commit hook checks the staged tree" "the current block counts"
  teardown
}

test_i7_ci_vendoring_through_tools() {
  echo "test: I-7 install --ci vendors through doc-tools.sh tools (exec bits restored); uninstall keeps an edited helper and says so"
  setup
  inst install --ci --workflows=doc-release
  chmod -x .github/scripts/doc-tools.sh .github/scripts/doc-superpowers-steps/precheck.sh
  inst install --ci
  assert_true "doc-tools.sh is executable again" test -x .github/scripts/doc-tools.sh
  assert_true "precheck.sh is executable again" test -x .github/scripts/doc-superpowers-steps/precheck.sh
  echo "# a local edit" >> .github/scripts/doc-superpowers-steps/precheck.sh
  inst uninstall --ci
  assert_eq "0" "$IRC" "uninstall exits 0"
  assert_contains "$IOUT" "Kept" "it reports the file it kept"
  assert_file_exists ".github/scripts/doc-superpowers-steps/precheck.sh" "the edited helper is kept"
  assert_file_not_exists ".github/scripts/doc-tools.sh" "the unmodified tool is removed"
  teardown
}

test_i7_gitattributes_owned_block() {
  echo "test: I-7 .gitattributes: only the marked block is the installer's (your own merge=doc-index line survives uninstall)"
  setup
  local orig
  orig=$(harness_mktemp attrs)
  printf '*.png binary\ndocs/.doc-index.json merge=doc-index\n' > .gitattributes
  cp .gitattributes "$orig"
  inst install --git
  assert_eq "1" "$(grep -c '^# doc-superpowers:begin' .gitattributes)" "the marked block is added"
  inst uninstall --git
  assert_true "uninstall leaves your .gitattributes byte-for-byte" cmp -s "$orig" .gitattributes
  printf '*.png binary\n\n# doc-superpowers: auto-resolve doc-index.json merge conflicts\ndocs/.doc-index.json merge=doc-index\n' > .gitattributes
  inst install --git
  assert_eq "1" "$(grep -c '^# doc-superpowers:begin' .gitattributes)" "the pre-3.0 lines become the marked block"
  assert_not_contains "$(cat .gitattributes)" "auto-resolve doc-index.json" "…the old comment is gone"
  inst uninstall --git
  assert_eq "*.png binary" "$(cat .gitattributes)" "uninstall leaves only your line"
  teardown
}

test_i7_reinstall_reregisters_merge_driver() {
  echo "test: I-7 re-install --git replaces a pre-3.0 merge-driver registration; uninstall leaves no config section"
  setup
  inst install --git
  git config --local merge.doc-index.driver "/old/pinned/merge-doc-index.sh %O %A %B"
  inst install --git
  assert_contains "$(git config --local --get merge.doc-index.driver)" "t='" "re-registered in the resolve-at-merge-time form"
  inst uninstall --git
  assert_eq "0" "$(grep -c 'doc-index' .git/config)" "no merge.doc-index section left in .git/config"
  teardown
}

test_i7_helpers_false_is_state_aware() {
  echo "test: I-7 --helpers=false is refused while doc-pr-release is (or stays) installed, allowed once it was removed on purpose"
  setup
  inst install --ci --workflows=doc-pr-release
  local before
  before=$(_tree_state)
  inst install --ci --workflows=doc-release --helpers=false
  assert_eq "1" "$IRC" "doc-pr-release on disk: exits 1"
  assert_contains "$IOUT" "doc-pr-release" "…names it"
  assert_eq "$before" "$(_tree_state)" "…nothing written"
  inst uninstall --ci --workflows=doc-pr-release
  inst install --ci --workflows=all --helpers=false
  assert_eq "0" "$IRC" "doc-pr-release removed on purpose: --workflows=all --helpers=false exits 0"
  assert_file_not_exists ".github/workflows/doc-pr-release.yml" "…doc-pr-release stays removed"
  assert_true "…and its producer helpers are not installed" test ! -d .github/scripts/doc-pr-release
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
test_install_ci_version_comes_from_doc_tools
test_install_ci_writes_state_file_on_first_install
test_install_ci_bootstraps_state_from_filesystem
test_install_ci_malformed_state_file_falls_back_with_warn
test_uninstall_install_cycle_respects_intentional_uninstall
test_uninstall_transient_then_install_reinstalls
test_install_force_bypasses_intentional_uninstall
test_install_explicit_workflows_overrides_state
test_install_ci_helpers_invalid_value_errors

echo ""
echo "=== Installer: ownership, placement, integration, state (I-7) ==="
test_i7_claude_user_groups_survive
test_i7_claude_settings_edge_files
test_i7_symlinked_write_targets_refused
test_i7_uninstall_never_deletes_through_links
test_i7_integration_posix_host
test_i7_integration_exec_host
test_i7_integration_pre_push_stdin
test_i7_integration_once_and_exact_inverse
test_i7_integration_skips_non_shell_host
test_i7_integration_upgrades_legacy_block
test_i7_placement_linked_worktree
test_i7_placement_submodule
test_i7_placement_subdirectory
test_i7_hooks_path_scope
test_i7_doc_tools_resolution_plugin_cache
test_i7_doc_tools_resolution_checkout
test_i7_ci_values_validated
test_i7_plain_reinstall_reproduces_choices
test_i7_legacy_install_choices_inferred
test_i7_uninstall_unknown_workflow_fails
test_i7_install_uninstall_leaves_no_residue
test_i7_default_ci_set_and_help
test_i7_flags_outside_scope_exit_2
test_i7_workflows_csv_edges
test_i7_unreadable_state_refused_and_recovery
test_i7_uninstall_without_workflows_dir
test_i7_state_reconciled_with_disk
test_i7_claude_tier_is_per_user
test_i7_claude_hooks_run_from_path_with_spaces
test_i7_gate_probe_agrees_with_integration_block
test_i7_ci_vendoring_through_tools
test_i7_gitattributes_owned_block
test_i7_reinstall_reregisters_merge_driver
test_i7_helpers_false_is_state_aware


# --- I-8: CI templates — the retired doc-index-update, step scripts ----------
#
# doc-index-update.yml re-verified every doc edited on the base branch without
# anyone reading it, and failed every run. It is retired: no template, no
# default, no --workflows name; an install the installer owns is removed on
# upgrade (ownership = the workflow marker, the rule for every managed
# workflow); one it cannot show it owns is kept and reported.

# A pre-3.0 install's doc-index-update.yml (its marker makes it ours) and its
# state entry, next to the current install.
_plant_retired_index_update() {
  printf '%s\n' '# doc-superpowers workflow v1' '# Auto-update doc index after docs change on main' \
    '# Installed by doc-superpowers hooks installer' '' 'name: Doc Index Update' 'on:' '  push:' '    branches: [main]' \
    > .github/workflows/doc-index-update.yml
  local f=.claude/doc-superpowers/installed.json tmp
  tmp=$(jq '.tiers.ci.workflows["doc-index-update"] = {state: "installed", installed_at: "2025-01-01T00:00:00Z"}' "$f")
  printf '%s\n' "$tmp" > "$f"
}

test_i8_doc_index_update_retired() {
  echo "test: I-8 doc-index-update is retired: no template, not in the default set, the help or --workflows"
  setup
  assert_file_not_exists "$HOOKS_DIR/ci/doc-index-update.yml" "the template is gone"
  inst install --ci
  assert_eq "0" "$IRC" "install --ci exits 0"
  assert_eq "doc-freshness-pr.yml doc-freshness-schedule.yml" \
    "$(cd .github/workflows && printf '%s ' *.yml | sed 's/ $//')" "the default set is the two shell workflows"
  inst install --ci --workflows=doc-index-update
  assert_eq "1" "$IRC" "install --workflows=doc-index-update exits 1"
  assert_contains "$IOUT" "retired" "…and says the workflow was retired"
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "…writing no such workflow"
  inst help
  assert_not_contains "$IOUT" "doc-index-update" "help does not offer it"
  teardown
}

test_i8_retired_workflow_removed_on_upgrade() {
  echo "test: I-8 an install --ci removes a doc-index-update.yml the installer owns (marker) and drops its state entry"
  setup
  inst install --ci
  _plant_retired_index_update
  inst install --ci
  assert_eq "0" "$IRC" "install --ci exits 0"
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "the retired workflow is removed"
  assert_contains "$IOUT" "doc-index-update.yml" "the removal is reported"
  local f=.claude/doc-superpowers/installed.json
  assert_eq "null" "$(jq -c '.tiers.ci.workflows["doc-index-update"]' "$f")" "its state entry is dropped"
  assert_eq "installed installed" \
    "$(jq -r '[.tiers.ci.workflows["doc-freshness-pr"].state, .tiers.ci.workflows["doc-freshness-schedule"].state] | join(" ")' "$f")" \
    "the other workflows' state is untouched"
  # Any install --ci is an upgrade, --workflows=none included.
  _plant_retired_index_update
  inst install --ci --workflows=none
  assert_eq "0" "$IRC" "install --ci --workflows=none exits 0"
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "--workflows=none also removes it"
  assert_eq "null" "$(jq -c '.tiers.ci.workflows["doc-index-update"]' "$f")" "…and drops its entry"
  teardown
}

test_i8_retired_foreign_file_kept() {
  echo "test: I-8 a doc-index-update.yml without the marker (not provably ours) is kept and reported, never deleted"
  setup
  inst install --ci
  printf 'name: my own index job\n' > .github/workflows/doc-index-update.yml
  inst install --ci
  assert_eq "0" "$IRC" "install --ci exits 0"
  assert_eq "name: my own index job" "$(cat .github/workflows/doc-index-update.yml)" "kept byte-for-byte"
  assert_contains "$IOUT" "Kept .github/workflows/doc-index-update.yml" "…and reported"
  inst uninstall --ci
  assert_eq "0" "$IRC" "uninstall --ci exits 0"
  assert_eq "name: my own index job" "$(cat .github/workflows/doc-index-update.yml)" "a full uninstall keeps it too"
  teardown
}

test_i8_retired_status_and_uninstall() {
  echo "test: I-8 status names an owned retired workflow; uninstall (full or by name) removes it and its entry"
  setup
  inst install --ci
  _plant_retired_index_update
  inst status
  assert_eq "0" "$IRC" "status exits 0"
  assert_contains "$(grep 'doc-index-update' <<<"$IOUT" || true)" "retired" "status marks it retired"
  local f=.claude/doc-superpowers/installed.json
  inst uninstall --ci --workflows=doc-index-update
  assert_eq "0" "$IRC" "uninstall --workflows=doc-index-update exits 0"
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "removed by name"
  assert_eq "null" "$(jq -c '.tiers.ci.workflows["doc-index-update"]' "$f")" "…its entry dropped"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "…the others kept"
  _plant_retired_index_update
  inst uninstall --ci
  assert_eq "0" "$IRC" "a full uninstall exits 0"
  assert_file_not_exists ".github/workflows/doc-index-update.yml" "a full uninstall removes it (no residue)"
  assert_eq "null" "$(jq -c '.tiers.ci.workflows["doc-index-update"]' "$f")" "…and drops its entry"
  teardown
}

test_i8_no_placeholder_survives_install_all() {
  echo "test: I-8 install --all --workflows=all leaves no __PLACEHOLDER__ in a workflow, a hook or a shipped helper"
  setup
  inst install --all --workflows=all
  assert_eq "0" "$IRC" "install --all --workflows=all exits 0"
  local files=() f hits
  for f in .github/workflows/*.yml .github/scripts/doc-superpowers-steps/*.sh .github/scripts/doc-pr-release/*.sh \
    .git/hooks/pre-commit .git/hooks/post-merge .git/hooks/post-checkout .git/hooks/prepare-commit-msg .git/hooks/pre-push \
    .claude/hooks/doc-superpowers/*.sh; do
    [ -f "$f" ] && files+=("$f")
  done
  assert_true "installed files found (${#files[@]})" test "${#files[@]}" -ge 20
  hits=$(grep -lE '__[A-Z][A-Z0-9_]*__' ${files[@]+"${files[@]}"} || true)
  assert_eq "" "$hits" "no placeholder survives"
  _assert_installed_workflows_wired "install --all --workflows=all"
  teardown
}

test_i8_default_set_ships_its_step_scripts() {
  echo "test: I-8 the default set's workflows run step scripts, so install --ci ships them (and only the producer helpers with doc-pr-release)"
  setup
  inst install --ci
  assert_eq "0" "$IRC" "install --ci exits 0"
  assert_true "freshness-check.sh is vendored executable" test -x .github/scripts/doc-superpowers-steps/freshness-check.sh
  assert_true "no producer helpers without doc-pr-release" test ! -d .github/scripts/doc-pr-release
  _assert_installed_workflows_wired "install --ci (default set)"
  inst uninstall --ci
  assert_true "uninstall removes the step scripts with the last workflow" test ! -d .github/scripts/doc-superpowers-steps
  teardown
}

echo ""
echo "=== CI templates: retired doc-index-update, step scripts (I-8) ==="
test_i8_doc_index_update_retired
test_i8_retired_workflow_removed_on_upgrade
test_i8_retired_foreign_file_kept
test_i8_retired_status_and_uninstall
test_i8_no_placeholder_survives_install_all
test_i8_default_set_ships_its_step_scripts

print_summary

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
# Every run is also held to the contract Claude Code relies on (see
# _claude_hook_contract): a violation is a FAIL of the test that ran it.
CLAUDE_HOOK_RUNS=0 CLAUDE_HOOK_BREACHES=0
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
  _claude_hook_contract "$script" ${1+"$@"}
}

# One JSON object, or nothing, on stdout.
stdout_is_one_json_object() {
  [ -z "$RUN_OUT" ] || [ "$(jq -cs 'length == 1 and (.[0] | type == "object")' <<<"$RUN_OUT" 2>/dev/null)" = "true" ]
}

# _claude_hook_contract <script> [VAR=value ...]: the exit code is 0, or 2
# (a block) only when DOC_SUPERPOWERS_STRICT=1 was set — a syntax error also
# exits 2, and a PreToolUse hook's exit 2 blocks the commit, so a broken hook
# must never pass as a block — and stdout is one JSON object or nothing (stray
# output breaks the JSON Claude Code parses). Silent when held, so the
# assertion counts stay fixed; test_claude_hook_contract_held reports the tally.
_claude_hook_contract() {
  local script="$1" strict=0 a
  shift
  for a in "$@"; do
    [ "$a" = DOC_SUPERPOWERS_STRICT=1 ] && strict=1
  done
  CLAUDE_HOOK_RUNS=$((CLAUDE_HOOK_RUNS + 1))
  if ! { [ "$RUN_RC" = 0 ] || { [ "$RUN_RC" = 2 ] && [ "$strict" = 1 ]; }; }; then
    CLAUDE_HOOK_BREACHES=$((CLAUDE_HOOK_BREACHES + 1))
    assert_eq "0$([ "$strict" = 1 ] && echo ' or 2')" "$RUN_RC" "$script: contract: exit code (stderr: $(head -c 300 <<<"$RUN_ERR"))"
  fi
  if ! stdout_is_one_json_object; then
    CLAUDE_HOOK_BREACHES=$((CLAUDE_HOOK_BREACHES + 1))
    assert_eq "one JSON object or nothing" "$(head -c 300 <<<"$RUN_OUT")" "$script: contract: stdout"
  fi
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

# --- Git hooks: the claims legs ---
#
# claims_hook_fixture: indexed_fixture (its doc citing src/util.js only, so
# the claims files leave it current), plus one governing spec whose one
# sidecar claim (unbuilt, tracked) is bound to a /bin/sh stub runner's node,
# and docs/spec-claims/config.json naming `main` as the base and the stub as
# runner "stub" (paths src/, tests/). The spec carries its rendered status
# block, so V11 holds. All committed on main, then `feature` checked out and
# the git tier installed. The stub is this suite's own (test-spec-claims.sh
# is not sourced): `list` cats tools/claims/list.jsonl (the node bound to the
# claim, so V3 holds), `run [--root <dir>] <node>…` reports each node
# $STUB_OUTCOME (default assert-fail: the unbuilt claim's check is red, as it
# should be; pass makes it a finding), anything else prints nothing. Every
# call appends its subcommand, its arguments (one per line) and
# "stdin <bytes it read>" to $STUB_LOG, a harness_mktemp file outside the
# work tree.
CLAIMS_NODE="tests/test_token.py::test_ttl"
CLAIMS_ID="SPEC-AUTH-001#token-ttl"
CLAIMS_DOC="docs/specs/SPEC-AUTH-001-token.md"

claims_hook_fixture() {
  indexed_fixture src/util.js
  mkdir -p docs/specs docs/issues docs/spec-claims src/auth tools/claims
  cat > "$CLAIMS_DOC" <<'EOF'
# SPEC-AUTH-001: Token lifetimes

**Status**: Draft
**Created**: 2026-10-10

## Summary

How long issued tokens stay valid.

<!-- spec-claims:status:begin -->
## Claim status

| Claim | Status | Tracker |
|---|---|---|
| `SPEC-AUTH-001#token-ttl` | unbuilt | docs/issues/token-ttl.md |

<!-- spec-claims:status:end -->
## Requirements

- Access tokens expire after 15 minutes.
- Refresh tokens are single-use.
EOF
  printf 'TTL_SECONDS = 900\n' > src/auth/token.py
  cat > docs/issues/token-ttl.md <<'EOF'
# Token TTL

**Status**: Open

Build the 15-minute access-token expiry (SPEC-AUTH-001#token-ttl).
EOF
  jq -n '{schema: 1, base: "main",
    runners: {stub: {adapter: "tools/claims/runner", paths: ["src/", "tests/"]}}}' \
    > docs/spec-claims/config.json
  jq -n --arg id "$CLAIMS_ID" --arg doc "$CLAIMS_DOC" --arg node "$CLAIMS_NODE" '{
    schema: 1, doc: $doc,
    claims: [{
      id: $id, quote: "Access tokens expire after 15 minutes",
      states: "An issued access token is rejected 15 minutes after issue.",
      kind: "behaviour", subject: ["src/auth/token.py"], status: "unbuilt",
      enforced_by: "test", test: {runner: "stub", node: $node}, nonvacuity: null,
      promotion: null, tracker: "docs/issues/token-ttl.md", frozen_at: null,
      restates: [], rulings: []
    }]
  }' > docs/spec-claims/SPEC-AUTH-001.json
  cat > tools/claims/runner <<'EOF'
#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
log=${STUB_LOG:-/dev/null}
sub=${1:-}
[ $# -eq 0 ] || shift
n=$(cat | wc -c | tr -d ' ')
{
  printf '%s\n' "$sub"
  for a in "$@"; do printf '%s\n' "$a"; done
  printf 'stdin %s\n' "$n"
} >> "$log"
case $sub in
  list) cat "$dir/list.jsonl" ;;
  run)
    if [ "${1:-}" = --root ]; then shift 2; fi
    for node in "$@"; do
      printf '{"node":"%s","outcome":"%s","reason":null}\n' "$node" "${STUB_OUTCOME:-assert-fail}"
    done
    ;;
esac
exit 0
EOF
  chmod 755 tools/claims/runner
  jq -nc --arg id "$CLAIMS_ID" --arg node "$CLAIMS_NODE" \
    '{id: $id, node: $node, file: ($node | split("::")[0]), in_gate: true, subject_imports_ok: true, when: null}' \
    > tools/claims/list.jsonl
  git add -A && git commit -qm "claims fixture"
  git checkout -qb feature
  install_tiers --git
  STUB_LOG=$(harness_mktemp claims-stub)
  export STUB_LOG
}

# A commit made in a test's setup, past the installed hooks.
fixture_commit() {
  DOC_SUPERPOWERS_SKIP=1 git commit -qm "$1"
}

# run_pre_commit [VAR=value ...]: the installed pre-commit, run as git runs
# it (cwd the top level, the staged index), its stdout in RUN_OUT.
run_pre_commit() {
  run_hooked ${1+"$@"} -- "$BASH_BIN" .git/hooks/pre-commit
}

# Stage an edit that breaks the claim's quote (15 → 30 minutes): V2.
stage_quote_break() {
  local tmp
  tmp=$(harness_mktemp doc)
  awk '{ sub(/expire after 15 minutes/, "expire after 30 minutes"); print }' "$CLAIMS_DOC" > "$tmp"
  cat "$tmp" > "$CLAIMS_DOC"
  git add "$CLAIMS_DOC"
}

# A doc-tools.sh wrapper that appends its argv (one line per call) to <log>,
# then runs the shim; echoes its path.
argv_logging_doc_tools() {
  local wrap
  wrap="$(harness_mktemp_d dt-wrap)/doc-tools.sh"
  cat > "$wrap" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$1"
exec "$DOC_TOOLS" "\$@"
EOF
  chmod 755 "$wrap"
  printf '%s' "$wrap"
}

test_pre_commit_claims_inert_without_dir() {
  echo "test: pre-commit — no docs/spec-claims/: the claims leg never runs"
  hooked_fixture
  local log wrap
  log=$(harness_mktemp dt-argv)
  wrap=$(argv_logging_doc_tools "$log")
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  run_pre_commit DOC_TOOLS="$wrap"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent"
  assert_contains "$(cat "$log")" "check-freshness" "the freshness leg ran through the wrapper (the log is live)"
  assert_eq "0" "$(grep -c '^claims' "$log" || true)" "no doc-tools call starts with 'claims'"
  teardown
}

test_pre_commit_claims_blocks_on_v2() {
  echo "test: pre-commit — a staged doc edit breaking a claim's quote blocks (V2)"
  claims_hook_fixture
  stage_quote_break
  run_pre_commit
  assert_eq "1" "$RUN_RC" "exits 1: a finding blocks, without STRICT"
  assert_contains "$RUN_OUT" "V2" "the finding names its check"
  assert_contains "$RUN_OUT" "doc-superpowers: claims: V2 $CLAIMS_ID: quote not found" "one line per finding: check, claim, message"
  assert_contains "$RUN_OUT" "  Commit blocked (claims). Fix, or rule the direction — see references/spec-claims.md. DOC_SUPERPOWERS_CLAIMS_SKIP=1 bypasses." "the block line"
  run_pre_commit DOC_SUPERPOWERS_QUIET=1
  assert_eq "1" "$RUN_RC" "QUIET: still exits 1"
  assert_eq "" "$RUN_OUT$RUN_ERR" "QUIET: silent"
  local head
  head=$(git rev-parse HEAD)
  run_hooked -- git commit -qm "break the quote"
  assert_true "git commit is refused (rc $RUN_RC)" test "$RUN_RC" -ne 0
  assert_eq "$head" "$(git rev-parse HEAD)" "…and nothing is committed"
  teardown
}

test_pre_commit_claims_advisory_v8_does_not_block() {
  echo "test: pre-commit — an advisory (V8: normative text no claim covers) prints, never blocks"
  claims_hook_fixture
  printf -- '- Sessions last one day.\n' >> "$CLAIMS_DOC"
  git add "$CLAIMS_DOC"
  run_pre_commit
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$RUN_OUT" "doc-superpowers: claims: V8: $CLAIMS_DOC:" "the advisory is printed (no claim: none named)"
  assert_not_contains "$RUN_OUT" "Commit blocked" "no block line"
  run_pre_commit DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "STRICT: an advisory still does not block"
  run_pre_commit DOC_SUPERPOWERS_QUIET=1
  assert_eq "0" "$RUN_RC" "QUIET: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "QUIET: silent"
  teardown
}

test_pre_commit_claims_indeterminate_warns() {
  echo "test: pre-commit — a claims check that cannot run warns; blocks only under STRICT"
  claims_hook_fixture
  local tmp
  tmp=$(harness_mktemp cfg)
  jq '.base = "nope"' docs/spec-claims/config.json > "$tmp"
  cat "$tmp" > docs/spec-claims/config.json
  git add docs/spec-claims/config.json
  run_pre_commit
  assert_eq "0" "$RUN_RC" "exit 2 from validate: the commit goes on"
  assert_contains "$RUN_ERR" "doc-superpowers: pre-commit: claims check could not run: base-unresolvable" "one line on stderr, with the first indeterminate reason"
  assert_eq "1" "$(line_count "$RUN_ERR")" "…one line"
  assert_eq "" "$RUN_OUT" "nothing on stdout"
  run_pre_commit DOC_SUPERPOWERS_STRICT=1
  assert_eq "1" "$RUN_RC" "STRICT: exits 1"
  assert_contains "$RUN_ERR" "claims check could not run: base-unresolvable" "STRICT: the same reason"
  run_pre_commit DOC_SUPERPOWERS_QUIET=1
  assert_eq "0" "$RUN_RC" "QUIET: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "QUIET: silent"
  # A doc-tools.sh older than the claims verb (3.1.0 exits 2: unknown subcommand).
  git checkout -q HEAD -- docs/spec-claims/config.json
  local old
  old="$(harness_mktemp_d dt-old)/doc-tools.sh"
  cat > "$old" <<EOF
#!/bin/sh
if [ "\$1" = claims ]; then echo "ERROR: unknown subcommand 'claims'." >&2; exit 2; fi
exec "$DOC_TOOLS" "\$@"
EOF
  chmod 755 "$old"
  stage_quote_break
  run_pre_commit DOC_TOOLS="$old"
  assert_eq "0" "$RUN_RC" "an older doc-tools.sh: the commit goes on"
  assert_contains "$RUN_ERR" "doc-superpowers: pre-commit: claims check could not run: unknown subcommand 'claims'" "…saying why"
  run_pre_commit DOC_TOOLS="$old" DOC_SUPERPOWERS_STRICT=1
  assert_eq "1" "$RUN_RC" "an older doc-tools.sh under STRICT: exits 1"
  teardown
}

test_pre_commit_claims_skip_env() {
  echo "test: pre-commit — DOC_SUPERPOWERS_CLAIMS_SKIP=1 bypasses the claims leg alone"
  claims_hook_fixture
  stage_quote_break
  run_pre_commit DOC_SUPERPOWERS_CLAIMS_SKIP=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_not_contains "$RUN_OUT$RUN_ERR" "claims" "no claims output"
  assert_eq "" "$(cat "$STUB_LOG")" "the claims check never ran (no adapter call)"
  # The freshness leg still runs: a stale doc is still reported.
  echo "changed" > src/util.js
  git add src/util.js
  run_pre_commit DOC_SUPERPOWERS_CLAIMS_SKIP=1
  assert_contains "$RUN_OUT" "stale" "the freshness leg still reports"
  teardown
}

test_pre_commit_claims_runs_without_doc_index() {
  echo "test: pre-commit — the claims leg runs without docs/.doc-index.json"
  claims_hook_fixture
  git rm -q docs/.doc-index.json
  fixture_commit "no doc-index"
  stage_quote_break
  run_pre_commit
  assert_eq "1" "$RUN_RC" "exits 1"
  assert_contains "$RUN_OUT" "doc-superpowers: claims: V2 $CLAIMS_ID" "blocks on V2"
  teardown
}

# A commit on the current branch touching src/ (a stub runner path), so
# claims run --planes-of selects the stub's test claims.
claims_code_commit() {
  printf 'TTL_SECONDS = %s\n' "$1" > src/auth/token.py
  git add src/auth/token.py
  fixture_commit "ttl $1"
}

# The stub's run calls: the number of "run" lines in $STUB_LOG.
stub_runs() {
  grep -c '^run$' "$STUB_LOG" || true
}

test_pre_push_claims_advisory_never_blocks() {
  echo "test: pre-push — a red claim is reported, never blocks"
  claims_hook_fixture
  claims_code_commit 901
  run_pre_push "$(push_line feature)" STUB_OUTCOME=pass
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$RUN_OUT" "doc-superpowers: claims (advisory): 1 red, 0 indeterminate" "the tally"
  assert_contains "$RUN_OUT" "  run $CLAIMS_ID: passes: promote" "…and the finding line"
  assert_eq "1" "$(stub_runs)" "one run call"
  run_pre_push "$(push_line feature)"
  assert_eq "0" "$RUN_RC" "nothing red: exits 0"
  assert_contains "$RUN_OUT" "doc-superpowers: claims (advisory): 0 red, 0 indeterminate" "nothing red or indeterminate: the tally still prints"
  : > "$STUB_LOG"
  run_pre_push "$(push_line feature)" STUB_OUTCOME=pass DOC_SUPERPOWERS_CLAIMS_SKIP=1
  assert_eq "0" "$RUN_RC" "CLAIMS_SKIP: exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "CLAIMS_SKIP: silent"
  assert_eq "0" "$(stub_runs)" "CLAIMS_SKIP: no run call"
  run_pre_push "$(push_line feature)" STUB_OUTCOME=indeterminate
  assert_eq "0" "$RUN_RC" "an indeterminate outcome: exits 0"
  assert_contains "$RUN_OUT" "doc-superpowers: claims (advisory): 0 red, 1 indeterminate" "…counted indeterminate"
  run_pre_push "refs/heads/feature $(git rev-parse feature) refs/heads/feature $(git rev-parse feature~1)" STUB_OUTCOME=pass
  assert_contains "$RUN_OUT" "claims (advisory): 1 red" "an existing remote branch: <remote oid>..<local oid>"
  run_pre_push "refs/heads/feature $(git rev-parse feature) refs/heads/feature $(git rev-parse main)" STUB_OUTCOME=pass DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "STRICT: still exits 0"
  teardown
}

test_pre_push_claims_could_not_run() {
  echo "test: pre-push — a claims check that cannot run is counted indeterminate, never blocks"
  claims_hook_fixture
  claims_code_commit 901
  local tmp old
  tmp=$(harness_mktemp cfg)
  jq '.base = "nope"' docs/spec-claims/config.json > "$tmp"
  cat "$tmp" > docs/spec-claims/config.json
  run_pre_push "$(push_line feature)" DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "an unresolvable base, under STRICT: exits 0"
  assert_contains "$RUN_OUT" "claims (advisory): 0 red, 1 indeterminate" "…counted indeterminate"
  assert_contains "$RUN_OUT" "  claims run could not run: 'nope'" "…saying why"
  git checkout -q -- docs/spec-claims/config.json
  old="$(harness_mktemp_d dt-old)/doc-tools.sh"
  cat > "$old" <<'EOF'
#!/bin/sh
echo "ERROR: unknown subcommand 'claims'." >&2
exit 2
EOF
  chmod 755 "$old"
  run_pre_push "$(push_line feature)" DOC_TOOLS="$old"
  assert_eq "0" "$RUN_RC" "an older doc-tools.sh: exits 0"
  assert_contains "$RUN_OUT" "  claims run could not run: unknown subcommand 'claims'" "…saying why"
  teardown
}

test_pre_push_claims_force_push_ranges_from_merge_base() {
  echo "test: pre-push — a remote oid that is not an ancestor (force-push, unfetched): from the merge-base"
  claims_hook_fixture
  claims_code_commit 901
  claims_code_commit 902
  local remote
  remote=$(git rev-parse HEAD)
  git reset -q --hard HEAD~1
  # remote..local is empty here: only the merge-base range reaches 901's change.
  run_pre_push "refs/heads/feature $(git rev-parse HEAD) refs/heads/feature $remote" STUB_OUTCOME=pass
  assert_eq "0" "$RUN_RC" "a force-push: exits 0"
  assert_contains "$RUN_OUT" "claims (advisory): 1 red, 0 indeterminate" "a force-push: the branch's own commits are run"
  run_pre_push "refs/heads/feature $(git rev-parse HEAD) refs/heads/feature 1234567890abcdef1234567890abcdef12345678" STUB_OUTCOME=pass
  assert_eq "0" "$RUN_RC" "an unfetched remote oid: exits 0"
  assert_contains "$RUN_OUT" "claims (advisory): 1 red, 0 indeterminate" "an unfetched remote oid: from the merge-base too"
  teardown
}

test_pre_push_claims_runs_without_tags() {
  echo "test: pre-push — the claims leg runs where the release reminder stops (no tag)"
  claims_hook_fixture
  claims_code_commit 901
  assert_eq "" "$(git tag)" "the fixture has no tag"
  run_pre_push "$(push_line feature)"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$RUN_OUT" "doc-superpowers: claims (advisory): 0 red, 0 indeterminate" "the claims line is printed"
  assert_eq "1" "$(stub_runs)" "…after the claims ran"
  assert_not_contains "$RUN_OUT" "commits since" "no release reminder"
  teardown
}

test_pre_push_claims_two_refs_both_processed() {
  echo "test: pre-push — two pushed refs: the claims leg runs for both, reading none of the ref lines"
  claims_hook_fixture
  claims_code_commit 901
  DOC_SUPERPOWERS_SKIP=1 git checkout -qb feature2 main
  claims_code_commit 902
  DOC_SUPERPOWERS_SKIP=1 git checkout -q feature
  local stdin
  stdin="$(push_line feature)
refs/heads/feature2 $(git rev-parse feature2) refs/heads/feature2 $(git rev-parse main)"
  # DOC_TOOLS logs the stdin bytes each doc-tools call received: a call the
  # hook made without </dev/null would read (and so drop) the next ref line.
  local log wrap
  log=$(harness_mktemp dt-stdin)
  wrap="$(harness_mktemp_d dt-wrap)/doc-tools.sh"
  cat > "$wrap" <<EOF
#!/bin/sh
n=\$(cat | wc -c | tr -d ' ')
printf '%s stdin %s\n' "\$1 \$2" "\$n" >> "$log"
exec "$DOC_TOOLS" "\$@"
EOF
  chmod 755 "$wrap"
  run_pre_push "$stdin" STUB_OUTCOME=pass DOC_TOOLS="$wrap"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "2" "$(grep -c 'claims (advisory): 1 red' <<<"$RUN_OUT" || true)" "a claims line per ref"
  assert_eq "2" "$(grep -c '^claims run stdin ' "$log" || true)" "doc-tools saw two claims run calls"
  assert_eq "0" "$(grep -vc ' stdin 0$' "$log" || true)" "every doc-tools call read 0 stdin bytes"
  assert_eq "2" "$(stub_runs)" "the stub ran once per ref"
  assert_eq "0" "$(grep '^stdin ' "$STUB_LOG" | grep -vc '^stdin 0$' || true)" "the stub read no stdin bytes"
  assert_not_contains "$(cat "$STUB_LOG")" "refs/heads/" "no ref line reached the stub"
  teardown
}

test_pre_push_claims_quiet() {
  echo "test: pre-push — DOC_SUPERPOWERS_QUIET=1 silences the claims leg"
  claims_hook_fixture
  claims_code_commit 901
  run_pre_push "$(push_line feature)" STUB_OUTCOME=pass DOC_SUPERPOWERS_QUIET=1
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_eq "" "$RUN_OUT$RUN_ERR" "silent"
  assert_eq "0" "$(stub_runs)" "nothing is run for output nobody sees"
  teardown
}

test_pre_push_claims_attests_open_plans() {
  echo "test: pre-push — each plan with gate records and no final.json is attested, for the branch checked out"
  claims_hook_fixture
  mkdir -p docs/plans docs/spec-claims/gates/p docs/spec-claims/gates/done docs/spec-claims/gates/gone
  # p names the (unbuilt) fixture claim: its attest is red.
  printf '# Plan\n\n## Chunk 1\n\n### Task 1: TTL\n\n**Files:**\n- Modify: `src/auth/token.py`\n\n**Claims:** %s\n' \
    "$CLAIMS_ID" > docs/plans/p.md
  printf '# Done\n' > docs/plans/done.md
  printf '{"schema":1,"plan":"docs/plans/p.md","chunk":1}\n' > docs/spec-claims/gates/p/chunk-1.json
  printf '{"schema":1,"plan":"docs/plans/done.md","chunk":1}\n' > docs/spec-claims/gates/done/chunk-1.json
  printf '{"schema":1}\n' > docs/spec-claims/gates/done/final.json
  printf '{"schema":1,"plan":"docs/plans/gone.md","chunk":1}\n' > docs/spec-claims/gates/gone/chunk-1.json
  git add -A
  fixture_commit "gate records"
  local log wrap
  log=$(harness_mktemp dt-argv)
  wrap=$(argv_logging_doc_tools "$log")
  run_pre_push "$(push_line feature)" DOC_TOOLS="$wrap"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$(cat "$log")" "claims attest --plan docs/plans/p.md" "the open plan is attested"
  assert_eq "1" "$(grep -c '^claims attest' "$log" || true)" "…only it (final.json present, or the plan gone: not attested)"
  assert_contains "$RUN_OUT" "claims (advisory): 1 red, 0 indeterminate" "its findings join the tally"
  assert_contains "$RUN_OUT" "  attest $CLAIMS_ID: named claim still unbuilt" "…and the finding lines"
  : > "$log"
  run_pre_push "$(push_line feature)
refs/heads/feature $(git rev-parse feature) refs/heads/mirror $ZERO_OID" DOC_TOOLS="$wrap"
  assert_eq "2" "$(grep -c '^claims run' "$log" || true)" "HEAD's oid pushed under two names: run per ref"
  assert_eq "1" "$(grep -c '^claims attest' "$log" || true)" "…attest once per push"
  : > "$log"
  DOC_SUPERPOWERS_SKIP=1 git checkout -qb other
  DOC_SUPERPOWERS_SKIP=1 git commit -q --allow-empty -m other
  run_pre_push "$(push_line feature)" DOC_TOOLS="$wrap"
  assert_eq "0" "$RUN_RC" "another branch checked out: exits 0"
  assert_contains "$(cat "$log")" "claims run --planes-of" "the pushed branch's claims still run"
  assert_eq "0" "$(grep -c '^claims attest' "$log" || true)" "…but attest (which judges HEAD) does not"
  teardown
}

echo ""
echo "=== Git Hooks: claims legs ==="
test_pre_commit_claims_inert_without_dir
test_pre_commit_claims_blocks_on_v2
test_pre_commit_claims_advisory_v8_does_not_block
test_pre_commit_claims_indeterminate_warns
test_pre_commit_claims_skip_env
test_pre_commit_claims_runs_without_doc_index
test_pre_push_claims_advisory_never_blocks
test_pre_push_claims_could_not_run
test_pre_push_claims_force_push_ranges_from_merge_base
test_pre_push_claims_runs_without_tags
test_pre_push_claims_two_refs_both_processed
test_pre_push_claims_quiet
test_pre_push_claims_attests_open_plans

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

# --- Claude Code hooks: bounded output, time budget, shared library ---
#
# Claude Code keeps each hook string (systemMessage, additionalContext, the
# stderr of a blocking exit 2) inline only up to 10,000 characters; past that
# the model gets a 2,000-character preview (code.claude.com/docs/en/hooks). So
# these tests measure what the INSTALLED hooks emit, run the way Claude Code
# runs them — never a source file.

# big_report <file>: a check-freshness report of BIG_STALE stale docs (long
# paths, 40 changed refs each) and BIG_MISSING missing ones.
BIG_STALE=1000 BIG_MISSING=300 BIG_ONDISK=150
big_report() {
  jq -n --argjson ns "$BIG_STALE" --argjson nm "$BIG_MISSING" '
    "docs/reference/deeply/nested/section/with/a/rather/long/directory/name/and/then/some/more" as $d
    | "src/very/long/module/path/segment/that/keeps/going/and/going/for/the/sake/of/length" as $s
    | {checked_at: "2026-09-29T00:00:00Z", repo_head: null,
       summary: {current: 0, stale: $ns, missing: $nm, deprecated: 0, untracked: 0},
       untracked_docs: [],
       docs: (([range($ns) | {key: "\($d)/stale-document-with-a-long-descriptive-name-\(.).md",
                 value: {status: "stale", reason: "code_changed", commits_behind: 3,
                   code_refs_changed: [range(40) as $r | "\($s)/component_with_a_long_name_\($r).ts"]}}]
             + [range($nm) | {key: "\($d)/missing-document-with-a-long-descriptive-name-\(.).md",
                 value: {status: "missing"}}]) | from_entries)}' > "$1"
}

# hooked_fixture whose doc-tools.sh (BIG_DT) is a stub printing big_report's
# report: a real check of 1,000 docs takes far longer than a hook's budget,
# and what is under test is the hook's own report. The first BIG_ONDISK
# missing docs are put on disk, untracked (for the gate: "not in this commit").
big_report_fixture() {
  hooked_fixture
  local d f
  d=$(harness_mktemp_d big)
  big_report "$d/report.json"
  printf '#!/bin/sh\ncat >/dev/null\ncat "%s"\n' "$d/report.json" > "$d/doc-tools.sh"
  chmod +x "$d/doc-tools.sh"
  BIG_DT="$d/doc-tools.sh"
  jq -r --argjson n "$BIG_ONDISK" '[.docs | to_entries[] | select(.value.status == "missing") | .key][:$n][]' \
    "$d/report.json" > "$d/ondisk"
  while IFS= read -r f; do
    mkdir -p "${f%/*}"
    echo "on disk" > "$f"
  done < "$d/ondisk"
}

# assert_bounded <label> <text> <needle>...: <text> is emitted, under
# 10,000 characters, and holds every <needle>. (Its own check, not
# assert_contains: a failure must not print a 100 KB haystack.)
_BOUNDED_TEXT=""
_bounded_has() { grep -qF -- "$1" <<<"$_BOUNDED_TEXT"; }
assert_bounded() {
  local label="$1" n
  _BOUNDED_TEXT="$2"
  shift 2
  assert_true "$label: emitted (${#_BOUNDED_TEXT} chars)" test "${#_BOUNDED_TEXT}" -gt 0
  assert_true "$label: under Claude Code's 10,000-char inline limit (${#_BOUNDED_TEXT} chars)" \
    test "${#_BOUNDED_TEXT}" -lt 10000
  for n in "$@"; do
    assert_true "$label: holds '$n'" _bounded_has "$n"
  done
}

HOOK_FULL_LIST_CMD="doc-tools.sh check-freshness"

test_claude_hooks_bound_a_huge_report() {
  echo "test: each Claude hook holds every string it emits under 10,000 chars on a 1,000-stale-doc report, with the counts and the full-list pointer"
  big_report_fixture
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')" DOC_TOOLS="$BIG_DT"
  assert_eq "0" "$RUN_RC" "post-commit-sync: exits 0"
  assert_true "post-commit-sync: stdout is one JSON object" stdout_is_one_json_object
  assert_bounded "post-commit-sync systemMessage" "$(out_field .systemMessage)" \
    "left 1000 doc(s) stale" "300 indexed doc(s) missing" "more" "$HOOK_FULL_LIST_CMD"
  assert_bounded "post-commit-sync additionalContext" "$(out_field .hookSpecificOutput.additionalContext)" \
    "1000 doc(s) affected by this commit" "300 indexed doc(s) missing" "more" "$HOOK_FULL_LIST_CMD" "/doc-superpowers update"

  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS="$BIG_DT"
  assert_eq "0" "$RUN_RC" "pre-commit-gate: exits 0 (advisory)"
  assert_true "pre-commit-gate: stdout is one JSON object" stdout_is_one_json_object
  assert_bounded "pre-commit-gate systemMessage" "$(out_field .systemMessage)" \
    "1000 stale doc(s)" "$BIG_ONDISK indexed doc(s) not in this commit" "$BIG_ONDISK indexed doc(s) missing from disk" "$HOOK_FULL_LIST_CMD"
  assert_bounded "pre-commit-gate additionalContext" "$(out_field .hookSpecificOutput.additionalContext)" \
    "1000 stale doc(s)" "$BIG_ONDISK indexed doc(s) not in this commit" "$BIG_ONDISK indexed doc(s) missing from disk" \
    "$HOOK_FULL_LIST_CMD" "Consider running"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS="$BIG_DT" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "pre-commit-gate STRICT: blocks"
  assert_true "pre-commit-gate STRICT: stdout is one JSON object or nothing" stdout_is_one_json_object
  assert_bounded "pre-commit-gate STRICT stderr" "$RUN_ERR" \
    "1000 stale doc(s)" "$BIG_ONDISK indexed doc(s) not in this commit" "$BIG_ONDISK indexed doc(s) missing from disk" \
    "$HOOK_FULL_LIST_CMD" "Commit blocked by DOC_SUPERPOWERS_STRICT=1"

  run_claude_hook Stop session-summary "$STOP_JSON" DOC_TOOLS="$BIG_DT"
  assert_eq "0" "$RUN_RC" "session-summary: exits 0"
  assert_true "session-summary: stdout is one JSON object" stdout_is_one_json_object
  assert_bounded "session-summary systemMessage" "$(out_field .systemMessage)" \
    "1000 doc(s) cite code changed" "300 indexed doc(s) missing" "$HOOK_FULL_LIST_CMD"
  teardown
}

test_claude_hooks_cap_lists_with_real_doc_tools() {
  echo "test: with the real doc-tools.sh, a commit staling 41 docs is reported as the first few plus '…and N more'"
  hooked_fixture
  # 40 more docs verified like docs/architecture.md (same content, same refs):
  # its index entry, copied under long keys.
  local dir="docs/reference/a/section/whose/directory/names/are/long/enough/to/matter" i keys=""
  mkdir -p "$dir"
  for i in $(seq 1 40); do
    cp docs/architecture.md "$dir/document-number-$i-with-a-descriptive-name.md"
    keys="$keys$dir/document-number-$i-with-a-descriptive-name.md"$'\n'
  done
  jq --rawfile k <(printf '%s' "$keys") \
    '.docs["docs/architecture.md"] as $t | .docs += ([$k | split("\n")[] | select(. != "") | {key: ., value: $t}] | from_entries)' \
    docs/.doc-index.json > docs/.doc-index.json.new && mv docs/.doc-index.json.new docs/.doc-index.json
  git add -A && DOC_SUPERPOWERS_SKIP=1 git commit -qm "41 docs"
  assert_eq "41" "$("$DOC_TOOLS" check-freshness | jq '[.docs[] | select(.status == "current")] | length')" "precondition: 41 current docs"
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')"
  assert_eq "0" "$RUN_RC" "exits 0"
  assert_contains "$(out_field .systemMessage)" "left 41 doc(s) stale" "systemMessage: the count"
  assert_contains "$(out_field .systemMessage)" "…and 31 more" "systemMessage: the first 10, then '…and 31 more'"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "…and 26 more" "additionalContext: the first 15, then '…and 26 more'"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "$HOOK_FULL_LIST_CMD" "additionalContext: where the full list is"
  teardown
}

# A doc-tools.sh that never finishes: it starts a 30 s child and waits for it
# (the child's pid in <dir>/child.pid).
slow_doc_tools() {
  printf '#!/bin/sh\ncat >/dev/null\nsleep 30 &\necho $! > "%s/child.pid"\nwait\n' "$1" > "$1/doc-tools.sh"
  chmod +x "$1/doc-tools.sh"
}

# The timeout the installer registered for <event>'s <script>.
registered_timeout() {
  jq -r --arg e "$1" --arg s "$2" \
    '[.hooks[$e][]?.hooks[]? | select(.command | contains($s)) | .timeout][0] // empty' \
    .claude/settings.local.json
}

# assert_child_gone <dir>: the slow check's child was killed with its group.
assert_child_gone() {
  local pid gone=no i
  pid=$(cat "$1/child.pid" 2>/dev/null || echo "")
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then gone=yes; break; fi
    sleep 0.2
  done
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  assert_eq "yes" "$gone" "$2: the check's own children are killed too (process group)"
}

test_claude_gate_and_sync_budget() {
  echo "test: pre-commit-gate and post-commit-sync give up within their budget, before the registered timeout, and say so"
  hooked_fixture
  local stub start elapsed limit h ev budget
  for h in pre-commit-gate post-commit-sync session-summary; do
    case "$h" in
      pre-commit-gate) ev=PreToolUse ;;
      post-commit-sync) ev=PostToolUse ;;
      *) ev=Stop ;;
    esac
    budget=$(sed -n 's/^BUDGET=//p' ".claude/hooks/doc-superpowers/$h.sh")
    limit=$(registered_timeout "$ev" "$h")
    assert_true "$h: a numeric BUDGET ($budget) under its registered timeout (${limit}s), with room for the report" \
      test -n "$budget" -a -n "$limit" -a "${budget:-99}" -le $(( ${limit:-0} - 2 ))
  done

  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  stub=$(harness_mktemp_d slow-sync)
  slow_doc_tools "$stub"
  limit=$(registered_timeout PostToolUse post-commit-sync)
  start=$SECONDS
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')" DOC_TOOLS="$stub/doc-tools.sh"
  elapsed=$((SECONDS - start))
  assert_eq "0" "$RUN_RC" "post-commit-sync: exits 0"
  assert_true "post-commit-sync: returns before its registered ${limit}s timeout (took ${elapsed}s)" test "$elapsed" -lt "${limit:-10}"
  assert_contains "$(out_field .systemMessage)" "check skipped (budget)" "post-commit-sync: the user is told the check was skipped"
  assert_eq "1" "$(line_count "$(out_field .systemMessage)")" "post-commit-sync: in one line"
  assert_child_gone "$stub" "post-commit-sync"

  stage_stale_change
  stub=$(harness_mktemp_d slow-gate)
  slow_doc_tools "$stub"
  limit=$(registered_timeout PreToolUse pre-commit-gate)
  start=$SECONDS
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS="$stub/doc-tools.sh"
  elapsed=$((SECONDS - start))
  assert_eq "0" "$RUN_RC" "pre-commit-gate: exits 0 (advisory)"
  assert_true "pre-commit-gate: returns before its registered ${limit}s timeout (took ${elapsed}s)" test "$elapsed" -lt "${limit:-10}"
  assert_contains "$(out_field .systemMessage)" "check skipped (budget)" "pre-commit-gate: the user is told the check was skipped"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "check skipped (budget)" "pre-commit-gate: and Claude"
  assert_child_gone "$stub" "pre-commit-gate"

  stub=$(harness_mktemp_d slow-strict)
  slow_doc_tools "$stub"
  start=$SECONDS
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_STRICT=1
  elapsed=$((SECONDS - start))
  assert_eq "2" "$RUN_RC" "pre-commit-gate STRICT: a check that ran out of time blocks (a timed-out hook would let the commit through)"
  assert_true "pre-commit-gate STRICT: blocks before its registered ${limit}s timeout (took ${elapsed}s)" test "$elapsed" -lt "${limit:-10}"
  assert_contains "$RUN_ERR" "budget" "pre-commit-gate STRICT: the reason names the budget"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_SKIP=1" "pre-commit-gate STRICT: and the bypass"
  assert_child_gone "$stub" "pre-commit-gate STRICT"
  teardown
}

test_claude_gate_and_sync_release_output_promptly() {
  echo "test: pre-commit-gate and post-commit-sync do not hold their output open for the watchdog"
  hooked_fixture
  local h budget shim real start elapsed
  shim=$(harness_mktemp_d sleep-shim)
  real=$(command -v sleep)
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  stage_stale_change
  for h in pre-commit-gate post-commit-sync; do
    budget=$(sed -n 's/^BUDGET=//p' ".claude/hooks/doc-superpowers/$h.sh")
    # As in test_session_summary_releases_output_promptly: only the
    # watchdog's own sleep is stretched to 60 s.
    printf '#!/bin/sh\nif [ "$1" = "%s" ]; then exec "%s" 60; fi\nexec "%s" "$@"\n' "$budget" "$real" "$real" > "$shim/sleep"
    chmod +x "$shim/sleep"
    start=$SECONDS
    if [ "$h" = pre-commit-gate ]; then
      run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" PATH="$shim:$REAL_PATH"
    else
      run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')" PATH="$shim:$REAL_PATH"
    fi
    elapsed=$((SECONDS - start))
    assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "$h: the check completed"
    assert_true "$h: returned without waiting out the watchdog's sleep (took ${elapsed}s; a held output takes >= 60 s)" \
      test "$elapsed" -lt 30
  done
  teardown
}

test_claude_hooks_share_one_library() {
  echo "test: the three Claude hooks source one installed hook-lib.sh; without it they say so in valid JSON"
  local h
  for h in pre-commit-gate post-commit-sync session-summary; do
    assert_true "$h: defines no _emit of its own" test -z "$(grep -n '^_emit()' "$HOOKS_DIR/claude/$h.sh")"
    assert_true "$h: sources hook-lib.sh" grep -q 'hook-lib\.sh' "$HOOKS_DIR/claude/$h.sh"
  done
  assert_true "hook-lib.sh defines _emit" grep -q '^_emit()' "$HOOKS_DIR/claude/hook-lib.sh"
  hooked_fixture
  assert_file_exists ".claude/hooks/doc-superpowers/hook-lib.sh" "installed beside the hooks"
  # Line 2 is the install date, as in the hooks: an install made another day
  # is the same install.
  local lib=.claude/hooks/doc-superpowers/hook-lib.sh
  assert_contains "$(sed -n 2p "$lib")" "doc-superpowers hook v1 — installed" "the install date is on line 2"
  sed '2s/.*/# doc-superpowers hook v1 — installed 1999-01-01 — shared by the Claude Code hooks/' "$lib" > "$lib.tmp"
  cat "$lib.tmp" > "$lib"
  rm -f "$lib.tmp"
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" status > "$TEST_DIR/status.out" 2>&1 || true
  assert_contains "$(grep 'pre-commit-gate' "$TEST_DIR/status.out")" "✓" "a library installed another day: status stays ✓"
  echo "# edited" >> "$lib"
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" status > "$TEST_DIR/status.out" 2>&1 || true
  assert_contains "$(grep 'pre-commit-gate' "$TEST_DIR/status.out")" "outdated" "an edited library: outdated"
  rm -f "$lib"
  echo "changed" > src/index.js
  DOC_SUPERPOWERS_SKIP=1 git commit -qam "code"
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -am code')"
  assert_eq "0" "$RUN_RC" "library missing: post-commit-sync exits 0"
  assert_contains "$(out_field .systemMessage)" "install --claude" "library missing: post-commit-sync says to reinstall"
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "library missing: the STRICT gate blocks (the check cannot run)"
  assert_contains "$RUN_ERR" "install --claude" "library missing: the STRICT gate says to reinstall"
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_eq "0" "$RUN_RC" "library missing: session-summary exits 0"
  assert_contains "$(out_field .systemMessage)" "install --claude" "library missing: session-summary says to reinstall"
  # QUIET and an absent doc-index still silence it (never the STRICT block's reason).
  run_claude_hook Stop session-summary "$STOP_JSON" DOC_SUPERPOWERS_QUIET=1
  assert_eq "" "$RUN_OUT$RUN_ERR" "library missing, QUIET: session-summary is silent"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_QUIET=1
  assert_eq "" "$RUN_OUT$RUN_ERR" "library missing, QUIET: the advisory gate is silent"
  mv docs/.doc-index.json docs/index-elsewhere.json
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "library missing, no doc-index: the STRICT gate does not block"
  assert_eq "" "$RUN_OUT$RUN_ERR" "library missing, no doc-index: silent"
  mv docs/index-elsewhere.json docs/.doc-index.json
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" status > "$TEST_DIR/status.out" 2>&1 || true
  assert_contains "$(grep 'pre-commit-gate' "$TEST_DIR/status.out")" "hook-lib.sh" "status names the missing library"
  teardown
}

echo ""
echo "=== Claude Code hooks: bounded output, time budget, shared library ==="
test_claude_hooks_bound_a_huge_report
test_claude_hooks_cap_lists_with_real_doc_tools
test_claude_gate_and_sync_budget
test_claude_gate_and_sync_release_output_promptly
test_claude_hooks_share_one_library

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
  assert_file_exists ".claude/hooks/doc-superpowers/hook-lib.sh" "their shared hook-lib.sh copied"
  assert_not_contains "$(cat .claude/hooks/doc-superpowers/hook-lib.sh)" "__INSTALL_DATE__" "hook-lib.sh: install date substituted"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_not_contains "$settings" "hook-lib" "the library is sourced, never registered"
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
  assert_file_not_exists ".claude/hooks/doc-superpowers/hook-lib.sh" "shared library removed"
  assert_true "no directory left behind" test ! -e .claude/hooks/doc-superpowers
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
  local label="$1" refs missing="" ref wf
  for wf in .github/workflows/doc-*.yml; do
    [ -f "$wf" ] || continue
    refs=$(grep -hoE '\.github/scripts/[A-Za-z0-9_./-]+\.sh' "$wf" | sort -u)
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      # A step guarded by hashFiles('<ref>') != '' runs the script only when
      # another workflow ships it (doc-spec-verify.yml's claims job and
      # doc-pr-release.yml's update-pr-body.sh): not this install's to ship.
      grep -qF "hashFiles('$ref') != ''" "$wf" && continue
      # The ledger helper set ships only on a ledger host (final review
      # OPS-I1); elsewhere ledger-publish.sh runs the verb's inert line.
      case "$ref" in
        .github/scripts/ledger/*|.github/scripts/adapters/*) [ -f docs/ledger/config.json ] || continue ;;
      esac
      [ -x "$ref" ] || missing="${missing} ${ref}"
    done <<<"$refs"
  done
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

# _vendor_snapshot: every file under .github/scripts/ with its mode bits and
# sha256, one line each, sorted — the vendored tree, byte for byte.
_vendor_snapshot() {
  local f
  [ -d .github/scripts ] || return 0
  find .github/scripts -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s %s\n' "$f" "$(if [ -x "$f" ]; then echo x; else echo -; fi)" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"
  done
}

# _claims_templates: the templates whose steps run the claims step script.
_claims_templates() {
  local t
  for t in "$HOOKS_DIR"/ci/*.yml; do
    awk '!/^[ \t]*#/ && index($0, ".github/scripts/doc-superpowers-steps/claims-check.sh") { f = 1 } END { exit !f }' "$t" \
      && basename "$t" .yml
  done
  return 0
}

test_ci_claims_templates_vendor_ledger() {
  # claims-check.sh runs `doc-tools.sh claims …`, whose V5 reads ledger
  # trackers through scripts/ledger/ when docs/ledger/config.json exists
  # (work-ledger design §I). Without the ledger set beside the vendored
  # doc-tools.sh, V5 judges no tracker there (ledger-unavailable). So on a
  # ledger host (the config exists) every workflow that runs the claims step
  # ships the ledger helper set, and the set goes with the last of them; a
  # host without the config gets none and no warning, and a set vendored
  # before goes on the next install --ci (final review OPS-I1, ruled).
  echo "test: install --ci — on a ledger host each workflow running claims-check.sh vendors the ledger helper set (removing the last one removes it, byte for byte); without docs/ledger/config.json none is vendored and status warns nothing"
  local claims w output exit_code f missing before after
  claims=$(_claims_templates | tr '\n' ' ')
  assert_eq "doc-freshness-schedule doc-spec-verify " "$claims" "the claims-running templates"
  for w in $claims; do
    setup
    # No ledger here: no set, no warning.
    exit_code=0
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows="$w" 2>&1) || exit_code=$?
    assert_eq "0" "$exit_code" "$w (no ledger): install exits 0"
    assert_true "$w (no ledger): no ledger modules vendored" test ! -e .github/scripts/ledger
    assert_true "$w (no ledger): …and no adapters" test ! -e .github/scripts/adapters
    assert_not_contains "$output" "ledger helpers" "$w (no ledger): the install reports no ledger set"
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status --ci 2>&1) || true
    assert_not_contains "$output" "without the ledger helper set" "$w (no ledger): status warns nothing"
    # A ledger host: the set ships.
    mkdir -p docs/ledger
    printf '{}\n' > docs/ledger/config.json
    exit_code=0
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows="$w" 2>&1) || exit_code=$?
    assert_eq "0" "$exit_code" "$w: install exits 0"
    missing=""
    for f in "$SCRIPT_DIR"/ledger/*.sh "$SCRIPT_DIR"/ledger/*.awk "$SCRIPT_DIR"/ledger/*.jq "$SCRIPT_DIR"/adapters/*.sh; do
      [ -f "$f" ] || continue
      case "$f" in
        */adapters/*) cmp -s "$f" ".github/scripts/adapters/${f##*/}" || missing="$missing adapters/${f##*/}" ;;
        *) cmp -s "$f" ".github/scripts/ledger/${f##*/}" || missing="$missing ledger/${f##*/}" ;;
      esac
    done
    assert_eq "" "$missing" "$w: the ledger modules and adapters are vendored, byte copies"
    assert_contains "$output" "ledger helpers → .github/scripts/ledger/" "$w: the install reports the ledger set"
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status --ci 2>&1) || true
    assert_contains "$output" "ledger helpers:" "$w: status reports the ledger modules"
    assert_not_contains "$output" "without the ledger helper set" "$w: …and no missing-set warning"
    # The set alone missing (a hand removal, the config added after the
    # install): status says so.
    rm -rf .github/scripts/ledger .github/scripts/adapters
    output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status --ci 2>&1) || true
    assert_contains "$output" "$w.yml runs claims-check.sh without the ledger helper set" "$w: status flags the missing set"
    assert_contains "$output" "install --ci" "$w: …and names the fix"
    "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows="$w" >/dev/null 2>&1
    assert_true "$w: a re-install brings the set back" test -f .github/scripts/ledger/lib.sh
    # The config gone: the next install --ci removes the set.
    rm -f docs/ledger/config.json
    "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows="$w" >/dev/null 2>&1
    assert_true "$w: no config any more: the next install --ci removes the ledger modules" test ! -e .github/scripts/ledger
    assert_true "$w: …and the adapters" test ! -e .github/scripts/adapters
    teardown
  done

  # A set vendored before (3.3.0's first cut, or by hand) on a host without
  # the ledger: the next install --ci removes it, byte for byte.
  setup
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-schedule >/dev/null 2>&1
  before=$(_vendor_snapshot)
  "$BASH_BIN" "$SCRIPT_DIR/doc-tools.sh" tools install --dest .github/scripts --helper ledger >/dev/null 2>&1
  assert_true "a set vendored by hand" test -f .github/scripts/ledger/lib.sh
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-schedule >/dev/null 2>&1
  after=$(_vendor_snapshot)
  assert_eq "$before" "$after" "no config: install --ci removes it, the vendored tree byte-identical to the one before"
  teardown

  # Two claims workflows on a ledger host: the set stays while one remains,
  # and leaves with the last — the vendored tree then byte-identical to the
  # one before.
  setup
  mkdir -p docs/ledger
  printf '{}\n' > docs/ledger/config.json
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-pr >/dev/null 2>&1
  before=$(_vendor_snapshot)
  assert_true "doc-freshness-pr alone vendors no ledger set (it runs no claims step)" test ! -e .github/scripts/ledger
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-schedule,doc-spec-verify >/dev/null 2>&1
  assert_true "two claims workflows: the set is vendored" test -f .github/scripts/ledger/lib.sh
  exit_code=0
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-spec-verify >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "uninstall doc-spec-verify exits 0"
  assert_true "doc-freshness-schedule still runs claims: the set stays" test -f .github/scripts/ledger/lib.sh
  exit_code=0
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-freshness-schedule >/dev/null 2>&1 || exit_code=$?
  assert_eq "0" "$exit_code" "uninstall doc-freshness-schedule exits 0"
  assert_true "the last claims workflow gone: the ledger modules go" test ! -e .github/scripts/ledger
  assert_true "…and the adapters" test ! -e .github/scripts/adapters
  after=$(_vendor_snapshot)
  assert_eq "$before" "$after" "the vendored tree is byte-identical to the one before the claims workflows"
  # The publish workflow beside a claims workflow: the set follows either.
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-ledger-publish,doc-freshness-schedule >/dev/null 2>&1
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-ledger-publish >/dev/null 2>&1
  assert_true "publish removed, doc-freshness-schedule left: the set stays" test -f .github/scripts/ledger/lib.sh
  teardown
}

test_ci_publish_template_vendors_ledger() {
  # doc-ledger-publish.yml runs `doc-tools.sh ledger publish`, which needs the
  # ledger modules beside the vendored doc-tools.sh: the workflow names
  # .github/scripts/ledger/, so install --ci ships the ledger helper set with
  # it (needed_helpers) and takes it away with it.
  echo "test: doc-ledger-publish.yml — every 30 minutes and by hand, contents: write, runs ledger publish; install --ci vendors the ledger helper set with it, uninstall removes it"
  local tpl="$HOOKS_DIR/ci/doc-ledger-publish.yml"
  assert_file_exists "$tpl" "the template exists"
  local t
  t=$(cat "$tpl" 2>/dev/null || true)
  assert_eq "# doc-superpowers workflow v1" "$(head -n 1 "$tpl" 2>/dev/null || true)" "it carries the workflow marker (the installer owns it)"
  assert_contains "$t" "- cron: '*/30 * * * *'" "scheduled every 30 minutes"
  assert_contains "$t" "workflow_dispatch:" "…and runnable by hand"
  assert_contains "$t" "contents: write" "contents: write (it pushes the views branch)"
  assert_contains "$t" ".github/scripts/doc-superpowers-steps/ledger-publish.sh" "its step runs the vendored publish step script"
  assert_contains "$t" ".github/scripts/ledger/" "…and names the vendored ledger helper set"
  assert_contains "$(cat "$HOOKS_DIR/ci/doc-superpowers-steps/ledger-publish.sh" 2>/dev/null || true)" "ledger publish" \
    "…which runs doc-tools.sh ledger publish"
  setup
  local output exit_code=0 f missing=""
  # Named without the ledger: the workflow is installed (it prints "not
  # enabled" until the config exists), the set is not (OPS-I1, ruled).
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-ledger-publish 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "no ledger: install --ci --workflows=doc-ledger-publish exits 0"
  assert_file_exists ".github/workflows/doc-ledger-publish.yml" "no ledger: the named workflow is installed"
  assert_true "no ledger: no ledger set vendored" test ! -e .github/scripts/ledger
  mkdir -p docs/ledger
  printf '{}\n' > docs/ledger/config.json
  exit_code=0
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-ledger-publish 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "install --ci --workflows=doc-ledger-publish exits 0"
  assert_file_exists ".github/workflows/doc-ledger-publish.yml" "the workflow is installed"
  for f in "$SCRIPT_DIR"/ledger/*.sh "$SCRIPT_DIR"/ledger/*.awk "$SCRIPT_DIR"/ledger/*.jq; do
    [ -f "$f" ] || continue
    cmp -s "$f" ".github/scripts/ledger/${f##*/}" || missing="$missing ledger/${f##*/}"
  done
  for f in "$SCRIPT_DIR"/adapters/*.sh; do
    [ -f "$f" ] || continue
    cmp -s "$f" ".github/scripts/adapters/${f##*/}" || missing="$missing adapters/${f##*/}"
  done
  assert_eq "" "$missing" "the ledger modules and adapters are vendored, byte copies"
  assert_true "the publish step script is vendored executable" test -x .github/scripts/doc-superpowers-steps/ledger-publish.sh
  assert_true "doc-pr-release's helpers are not (no workflow runs them)" test ! -e .github/scripts/doc-pr-release
  assert_contains "$output" "ledger helpers → .github/scripts/ledger/" "the install reports the ledger helper set"
  _assert_installed_workflows_wired "install --ci --workflows=doc-ledger-publish"
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" status --ci 2>&1) || true
  assert_contains "$output" "ledger helpers:" "status reports the ledger modules"
  assert_contains "$output" "ledger adapters:" "…and the adapters"
  # Another workflow beside it keeps the step scripts; the ledger set follows
  # the publish workflow alone.
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-freshness-pr >/dev/null 2>&1
  exit_code=0
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci --workflows=doc-ledger-publish 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "uninstall --ci --workflows=doc-ledger-publish exits 0"
  assert_file_not_exists ".github/workflows/doc-ledger-publish.yml" "the workflow is removed"
  assert_true "the ledger modules are removed with it" test ! -e .github/scripts/ledger
  assert_true "…and the adapters" test ! -e .github/scripts/adapters
  assert_true "the step scripts stay (doc-freshness-pr runs them)" test -x .github/scripts/doc-superpowers-steps/freshness-check.sh
  # An adapter of your own in .github/scripts/adapters/ survives the removal.
  "$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-ledger-publish >/dev/null 2>&1
  printf '#!/bin/sh\n' > .github/scripts/adapters/mine.sh
  "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --ci >/dev/null 2>&1 || true
  assert_file_exists ".github/scripts/adapters/mine.sh" "a full uninstall keeps an adapter of your own"
  assert_file_not_exists ".github/scripts/adapters/ledger-items-gh.sh" "…and removes the plugin's"
  teardown
}

test_ci_workflows_all_skips_publish_without_ledger() {
  # --workflows=all would install the every-30-minutes publish cron on a host
  # without the ledger: 48 billed no-op runs a day (final review OPS-I2,
  # ruled). all skips it there, with one note line; naming it installs it.
  echo "test: install --ci --workflows=all skips doc-ledger-publish without docs/ledger/config.json (one note line); with the config it installs it; an explicit name installs it either way"
  local output exit_code w
  setup
  exit_code=0
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "no ledger: --workflows=all exits 0"
  assert_file_not_exists ".github/workflows/doc-ledger-publish.yml" "no ledger: doc-ledger-publish is not installed"
  assert_contains "$output" "skipped doc-ledger-publish: no docs/ledger/config.json (name it in --workflows= to install it anyway)" "…one note line says so"
  assert_eq "1" "$(grep -c 'skipped doc-ledger-publish' <<<"$output")" "…once"
  for w in doc-freshness-pr doc-freshness-schedule doc-audit-update doc-review-pr doc-release doc-spec-verify doc-pr-full-cycle doc-pr-release; do
    assert_file_exists ".github/workflows/$w.yml" "no ledger: --workflows=all installs $w"
  done
  exit_code=0
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=doc-ledger-publish 2>&1) || exit_code=$?
  assert_eq "0" "$exit_code" "no ledger: naming doc-ledger-publish exits 0"
  assert_file_exists ".github/workflows/doc-ledger-publish.yml" "no ledger: the explicit name installs it"
  teardown
  setup
  mkdir -p docs/ledger
  printf '{}\n' > docs/ledger/config.json
  output=$("$BASH_BIN" "$HOOKS_DIR/install.sh" install --ci --workflows=all 2>&1) || true
  assert_file_exists ".github/workflows/doc-ledger-publish.yml" "a ledger host: --workflows=all installs doc-ledger-publish"
  assert_not_contains "$output" "skipped doc-ledger-publish" "…and no note"
  teardown
}

test_install_help_groups_publish_as_shell_optin() {
  # doc-ledger-publish runs no AI and needs no secret: help lists it in a
  # group of its own, not under Claude-powered (final review OPS-I4).
  echo "test: install.sh help — doc-ledger-publish is listed under 'shell, opt-in by name', not under Claude-powered; --workflows=all's help names the exception"
  local out claude optin
  out=$("$BASH_BIN" "$HOOKS_DIR/install.sh" help 2>&1) || true
  optin=$(awk '/^  shell, opt-in by name/ { f = 1; next } /^  [^ ]/ { f = 0 } f' <<<"$out")
  claude=$(awk '/^  Claude-powered/ { f = 1; next } /^  [^ ]/ { f = 0 } f' <<<"$out")
  assert_contains "$optin" "doc-ledger-publish" "doc-ledger-publish under 'shell, opt-in by name'"
  assert_not_contains "$claude" "doc-ledger-publish" "…not under Claude-powered"
  assert_contains "$claude" "doc-review-pr" "Claude-powered still lists the AI workflows"
  assert_contains "$out" "and except doc-ledger-publish on a host without" "--workflows=all's help names the exception"
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
  # doc-pr-release ships RELEASE-NOTES.next/README.md with its helpers; an
  # unmodified one, alone there, goes with them.
  inst install --all --workflows=doc-pr-release
  assert_eq "0" "$IRC" "install --all --workflows=doc-pr-release exits 0"
  assert_file_exists "RELEASE-NOTES.next/README.md" "…ships RELEASE-NOTES.next/README.md"
  inst uninstall --all
  assert_eq "0" "$IRC" "uninstall --all exits 0"
  after=$(_tree_state | grep -v -e '^\./\.claude/$' -e '^\./\.claude/doc-superpowers/$' -e '^\./\.claude/doc-superpowers/installed\.json ')
  assert_eq "$before" "$after" "with doc-pr-release too: nothing left but the state file (RELEASE-NOTES.next/ included)"
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
  assert_contains "$IOUT" "tracked by git" "a tracked settings.local.json is reported (untrack it to stay per-user)"
  assert_contains "$IOUT" "git rm -r --cached" "…with the command that untracks it"
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
test_ci_publish_template_vendors_ledger
test_ci_claims_templates_vendor_ledger
test_ci_workflows_all_skips_publish_without_ledger
test_install_help_groups_publish_as_shell_optin
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


# --- Final review fix wave: installer + hooks ---------------------------------

# The status line of <name> in $IOUT.
_status_line() {
  grep -E "^  [^ ]+ $1 " <<<"$IOUT" || true
}

test_fw_status_flags_outdated_installs() {
  echo "test: FW H-I1 status flags an install another version made (the hook marker is the same): hooks, local copies, Claude scripts, settings commands"
  setup
  # A shell hook of the user's, so post-merge is integrated (our local copy runs from it).
  printf '#!/bin/sh\necho mine\n' > .git/hooks/post-merge
  chmod +x .git/hooks/post-merge
  inst install --git --claude
  assert_eq "0" "$IRC" "install --git --claude exits 0"
  inst status
  assert_not_contains "$IOUT" "outdated" "a fresh install: nothing outdated"
  assert_contains "$(_status_line pre-commit)" "✓" "…pre-commit ✓"
  assert_contains "$(_status_line post-merge)" "✓" "…integrated post-merge ✓"
  assert_contains "$(_status_line pre-commit-gate)" "✓" "…pre-commit-gate ✓"
  # Line 2 is the install date: another date is the same install.
  sed '2s/.*/# doc-superpowers hook v1 — installed 1999-01-01/' .git/hooks/pre-commit > .git/hooks/pc.tmp
  cat .git/hooks/pc.tmp > .git/hooks/pre-commit
  rm -f .git/hooks/pc.tmp
  inst status
  assert_contains "$(_status_line pre-commit)" "✓" "a different install date (line 2) stays ✓"
  # Anything else that differs is another version's hook.
  echo "# v2 body" >> .git/hooks/pre-commit
  echo "# v2 body" >> .git/hooks/.doc-superpowers-post-merge
  echo "# v2 body" >> .claude/hooks/doc-superpowers/session-summary.sh
  # The command the v2 installer registered: a relative path under bash -c.
  local f=.claude/settings.local.json tmp v2cmd
  # shellcheck disable=SC2016  # the v2 installer's literal command
  v2cmd='bash -c '\''cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && exec .claude/hooks/doc-superpowers/pre-commit-gate.sh'\'
  tmp=$(jq --arg c "$v2cmd" '(.hooks.PreToolUse[].hooks[] | select(.command | contains("pre-commit-gate")) | .command) = $c' "$f")
  printf '%s\n' "$tmp" > "$f"
  inst status
  assert_eq "0" "$IRC" "status exits 0"
  assert_contains "$(_status_line pre-commit)" "outdated" "an edited pre-commit: outdated"
  assert_contains "$(_status_line pre-commit)" "re-run install --git" "…re-run install --git"
  assert_contains "$(_status_line post-merge)" "outdated" "an edited local copy of an integrated hook: outdated"
  assert_contains "$(_status_line post-merge)" "re-run install --git" "…re-run install --git"
  assert_contains "$(_status_line session-summary)" "outdated" "an edited Claude script: outdated"
  assert_contains "$(_status_line session-summary)" "re-run install --claude" "…re-run install --claude"
  assert_contains "$(_status_line pre-commit-gate)" "outdated" "a v2 settings command (relative path, bash -c): outdated"
  assert_contains "$(_status_line pre-commit-gate)" "re-run install --claude" "…re-run install --claude"
  assert_contains "$(_status_line post-commit-sync)" "✓" "the untouched ones stay ✓"
  inst install --git --claude
  inst status
  assert_not_contains "$IOUT" "outdated" "re-installing clears every outdated line"
  teardown
}

test_fw_unstaged_indexed_doc_is_not_in_this_commit() {
  echo "test: FW H-I2 a doc the staged index lists but the commit leaves out (on disk, not staged) is 'not in this commit' (git add), never remove-entry advice"
  hooked_fixture
  echo "# New" > docs/new.md
  echo "docs/new.md:src/:guide" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  git add docs/.doc-index.json
  stage_stale_change
  local head
  head=$(git rev-parse HEAD)
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm x
  assert_eq "1" "$RUN_RC" "git pre-commit (STRICT): blocked"
  assert_eq "$head" "$(git rev-parse HEAD)" "…nothing committed"
  assert_contains "$RUN_OUT$RUN_ERR" "not in this commit" "git pre-commit: 'not in this commit'"
  assert_contains "$RUN_OUT$RUN_ERR" "git add" "…with git add advice"
  assert_contains "$RUN_OUT$RUN_ERR" "docs/new.md" "…naming the doc"
  assert_not_contains "$RUN_OUT$RUN_ERR" "remove-entry" "…never remove-entry advice"
  assert_not_contains "$RUN_OUT$RUN_ERR" "missing from disk" "…never 'missing from disk'"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "gate (STRICT): blocked"
  assert_contains "$RUN_ERR" "not in this commit" "gate: 'not in this commit' (Claude's feedback)"
  assert_contains "$RUN_ERR" "git add" "gate: git add advice"
  assert_not_contains "$RUN_ERR" "remove-entry" "gate: never remove-entry advice"
  assert_not_contains "$RUN_ERR" "missing from disk" "gate: never 'missing from disk'"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')"
  assert_contains "$(out_field .systemMessage)" "not in this commit" "gate (advisory): the summary says so too"
  teardown
}

test_fw_index_only_commit_judges_its_new_keys() {
  echo "test: FW 227 a commit staging only the index with a new entry judges that entry (the scope by code refs never reached it)"
  hooked_fixture
  echo "# New" > docs/new.md
  echo "docs/new.md:src/util.js:guide" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  git add docs/.doc-index.json
  local head
  head=$(git rev-parse HEAD)
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm idx
  assert_eq "1" "$RUN_RC" "git pre-commit (STRICT): the index-only commit is blocked"
  assert_eq "$head" "$(git rev-parse HEAD)" "…nothing committed"
  assert_contains "$RUN_OUT$RUN_ERR" "docs/new.md" "…naming the new entry's doc"
  assert_contains "$RUN_OUT$RUN_ERR" "not in this commit" "…as not in this commit"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m idx')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "gate (STRICT): blocked"
  assert_contains "$RUN_ERR" "docs/new.md" "gate: names the doc"
  git add docs/new.md
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m idx')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "0" "$RUN_RC" "gate: with the doc staged, nothing to report"
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm idx
  assert_eq "0" "$RUN_RC" "git pre-commit: with the doc staged, committed"
  # An index change that adds no key keeps the scoped check.
  "$DOC_TOOLS" set-doc-type docs/new.md workflows >/dev/null 2>&1
  git add docs/.doc-index.json
  run_hooked DOC_SUPERPOWERS_STRICT=1 -- git commit -qm retype
  assert_eq "0" "$RUN_RC" "an index change that adds no key: committed"
  teardown
}

test_fw_removed_doc_keeps_move_advice() {
  echo "test: FW H-I2 a doc gone from disk too (git rm, git mv) still gets 'missing from disk' with move-entry advice"
  hooked_fixture
  git rm -q docs/architecture.md
  stage_stale_change
  run_hooked -- git commit -qm rm
  assert_contains "$RUN_OUT$RUN_ERR" "missing from disk" "git rm: 'missing from disk'"
  assert_contains "$RUN_OUT$RUN_ERR" "move-entry" "…move-entry advice"
  assert_not_contains "$RUN_OUT$RUN_ERR" "not in this commit" "…not 'not in this commit'"
  teardown
  hooked_fixture
  git mv docs/architecture.md docs/arch.md
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m mv')" DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "gate (STRICT): blocked"
  assert_contains "$RUN_ERR" "missing from disk" "git mv, gate: 'missing from disk'"
  assert_contains "$RUN_ERR" "move-entry" "…move-entry advice"
  teardown
}

test_fw_claude_note_names_every_tracked_per_user_file() {
  echo "test: FW H-I3 the tracked-file NOTE covers the hook scripts too, untracks both, and warns that pulling deletes them for teammates"
  setup
  mkdir -p .claude/hooks/doc-superpowers
  echo "old" > .claude/hooks/doc-superpowers/pre-commit-gate.sh
  git add .claude && git commit -qm "tracked hook scripts"
  inst install --claude
  assert_eq "0" "$IRC" "exits 0"
  assert_contains "$IOUT" "tracked by git" "NOTE: tracked per-user files"
  assert_contains "$IOUT" ".claude/hooks/doc-superpowers/pre-commit-gate.sh" "…names the tracked hook script"
  assert_contains "$IOUT" "git rm -r --cached" "…untracks with git rm -r --cached"
  assert_contains "$IOUT" "re-run" "…tells teammates to re-run install --claude"
  assert_contains "$IOUT" "install --claude" "…names install --claude"
  assert_contains "$IOUT" "ORIG_HEAD" "…and how to restore a lost allowlist"
  inst uninstall --claude
  git rm -rq --cached .claude
  git commit -qm untrack
  inst install --claude
  assert_not_contains "$IOUT" "tracked by git" "nothing tracked: no NOTE"
  teardown
}

test_fw_hooks_path_scope_worktree_and_uninstall_wording() {
  echo "test: FW H-M4 a worktree-scoped core.hooksPath is this repository's; a global one is refused by uninstall in uninstall's words"
  setup
  git config extensions.worktreeConfig true
  git config --worktree core.hooksPath .wthooks
  inst install --git
  assert_eq "0" "$IRC" "worktree-scoped core.hooksPath: install --git exits 0"
  assert_file_exists ".wthooks/pre-commit" "…installed where git runs hooks"
  inst status
  assert_not_contains "$IOUT" "not this repository's" "…status does not call it another repository's"
  inst uninstall --git
  assert_eq "0" "$IRC" "…uninstall --git exits 0"
  assert_file_not_exists ".wthooks/pre-commit" "…and removes it"
  git config --worktree --unset core.hooksPath
  local g
  g=$(harness_mktemp_d global)
  mkdir -p "$g/hooks"
  printf '[core]\n\thooksPath = %s\n' "$g/hooks" > "$g/config"
  export GIT_CONFIG_GLOBAL="$g/config"
  inst uninstall --git
  export GIT_CONFIG_GLOBAL=/dev/null
  assert_eq "1" "$IRC" "global core.hooksPath: uninstall --git exits 1"
  assert_contains "$IOUT" "uninstall --git does not touch it" "…in uninstall's words"
  assert_not_contains "$IOUT" "installing into it" "…not install's"
  teardown
}

test_fw_helpers_help_is_true() {
  echo "test: FW P-M9/H-M5 the --helpers help says what it does: deprecated, inert but for refusing doc-pr-release"
  setup
  inst help
  assert_contains "$IOUT" "deprecated" "--helpers is deprecated"
  assert_not_contains "$IOUT" "ship the doc-pr-release producer helpers" "no claim that --helpers=true ships anything"
  teardown
}

echo ""
echo "=== Final review fix wave: installer + hooks ==="
test_fw_status_flags_outdated_installs
test_fw_unstaged_indexed_doc_is_not_in_this_commit
test_fw_index_only_commit_judges_its_new_keys
test_fw_removed_doc_keeps_move_advice
test_fw_claude_note_names_every_tracked_per_user_file
test_fw_hooks_path_scope_worktree_and_uninstall_wording
test_fw_helpers_help_is_true

# --- The ledger hook set: install --ledger (work ledger) ----------------------
#
# Two opt-in sets, neither part of --all: --ledger, the git legs as
# "# ledger-superpowers:begin" … ":end" blocks (pre-commit validate --staged,
# pre-push provisional keys, post-commit in-flight push); --ledger-claude, two
# Claude events (SessionStart notices, PostToolUse Write|Edit state-watch),
# never the general --claude tier.

LGH_BEGIN="# ledger-superpowers:begin"
LGH_REG='{"schema":"ledger-registry/1","ledgers":[{"id":"x","title":"X","kind":"service","status":"active"}]}'
LGH_SESSION='{"hook_event_name":"SessionStart","source":"startup"}'

# lgh_fixture [config]: setup, then the ledger enabled — docs/ledger/config.json
# (default {}) and a registry with ledger x — committed.
lgh_fixture() {
  local c='{}'
  if [ $# -gt 0 ]; then c=$1; fi
  setup
  mkdir -p docs/issues docs/ledger
  printf '%s\n' "$c" > docs/ledger/config.json
  printf '%s\n' "$LGH_REG" > docs/ledger/ledgers.json
  git add -A && git commit -qm ledger
}

# lgh_remote: a bare remote "origin" (LGH_REMOTE) holding main, fetched.
lgh_remote() {
  LGH_REMOTE=$(harness_mktemp_d remote).git
  git init -q --bare "$LGH_REMOTE"
  git --git-dir="$LGH_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LGH_REMOTE"
  git push -q origin main
  git fetch -q origin
}

# lgh_item <file> <frontmatter lines…>: an item file with that frontmatter.
lgh_item() {
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n# %s\n' "$(basename "$f" .md)"; } > "$f"
}

# An item no registered ledger holds: validate --staged blocks it.
lgh_bad_item() {
  lgh_item docs/issues/bad.md "key: nope-1" "ledger: nope" "status: Open" "summary: An item in no registered ledger"
}

# The first 4 hex digits of sha256(<path>): a provisional key's suffix.
lgh_hex4() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s' "$1" | sha256sum); else h=$(printf '%s' "$1" | shasum -a 256); fi
  printf '%s' "${h:0:4}"
}

# The number of ledger blocks in <file> (0 when it is absent).
lgh_blocks() {
  if [ -f "$1" ]; then grep -c "^$LGH_BEGIN" "$1" || true; else echo 0; fi
}

# The ledger blocks of the three git legs, "<pre-commit> <pre-push> <post-commit>".
lgh_legs() {
  printf '%s %s %s' "$(lgh_blocks .git/hooks/pre-commit)" "$(lgh_blocks .git/hooks/pre-push)" "$(lgh_blocks .git/hooks/post-commit)"
}

# lgh_wrap <log>: a doc-tools.sh wrapper (its path printed) that appends its
# arguments to <log>, one call per line, then runs the real one.
lgh_wrap() {
  local w
  w=$(harness_mktemp wrap)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$1" "$DOC_TOOLS" > "$w"
  chmod +x "$w"
  printf '%s' "$w"
}

# PostToolUse payloads: Write <path> <content>, Edit <path> <new_string>.
lgh_write_payload() {
  jq -nc --arg p "$1" --arg c "$2" '{hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $p, content: $c}, tool_response: {success: true}}'
}
lgh_edit_payload() {
  jq -nc --arg p "$1" --arg n "$2" '{hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: {file_path: $p, old_string: "a", new_string: $n}}'
}

# lgh_watch <payload> [VAR=value …]: run the state-watch hook; LGH_CTX is its
# additionalContext ("" when silent).
lgh_watch() {
  local p="$1"
  shift
  run_claude_hook PostToolUse ledger-state-watch "$p" ${1+"$@"}
  LGH_CTX=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$RUN_OUT" 2>/dev/null || true)
}

test_ledger_install_requires_config() {
  echo "test: ledger: install --ledger and --ledger-claude refuse without docs/ledger/config.json (exit 1, naming it, nothing written); their uninstalls do not need it"
  setup
  local before
  before=$(_tree_state)
  inst install --ledger
  assert_eq "1" "$IRC" "install --ledger without the config: exit 1"
  assert_contains "$IOUT" "docs/ledger/config.json" "…naming docs/ledger/config.json"
  inst install --ledger-claude
  assert_eq "1" "$IRC" "install --ledger-claude without it: exit 1"
  assert_contains "$IOUT" "docs/ledger/config.json" "…naming it"
  inst install --git --claude --ledger --ledger-claude
  assert_eq "1" "$IRC" "install --git --claude --ledger --ledger-claude without it: exit 1 too"
  assert_eq "$before" "$(_tree_state)" "…and no tier or set wrote anything"
  inst uninstall --ledger --ledger-claude
  assert_eq "0" "$IRC" "uninstall --ledger --ledger-claude without the config: exit 0"
  mkdir -p docs/ledger
  printf '{}\n' > docs/ledger/config.json
  inst install --ledger
  assert_eq "0" "$IRC" "with the config: exit 0"
  assert_eq "1 1 1" "$(lgh_legs)" "one block in each of pre-commit, pre-push and post-commit"
  assert_true "post-commit, which the set created, is executable" test -x .git/hooks/post-commit
  assert_eq "#!/bin/sh" "$(sed -n 1p .git/hooks/post-commit)" "…a #!/bin/sh hook"
  assert_file_not_exists ".claude/settings.local.json" "no Claude event without --ledger-claude"
  teardown
}

test_ledger_all_excludes_ledger() {
  echo "test: ledger: --all includes neither ledger set (install --all adds no block and no ledger event, uninstall --all removes none)"
  lgh_fixture
  inst install --all
  assert_eq "0" "$IRC" "install --all: exit 0"
  assert_eq "0 0 0" "$(lgh_legs)" "…no ledger block"
  assert_not_contains "$(cat .claude/settings.local.json 2>/dev/null)" "ledger-" "…no ledger Claude event"
  inst install --ledger --ledger-claude
  assert_eq "0" "$IRC" "install --ledger --ledger-claude: exit 0"
  inst uninstall --all
  assert_eq "0" "$IRC" "uninstall --all: exit 0"
  assert_eq "1 1 1" "$(lgh_legs)" "uninstall --all keeps every ledger block"
  assert_eq "PostToolUse SessionStart" "$(jq -r '[.hooks | keys[]] | join(" ")' .claude/settings.local.json 2>/dev/null)" "…and the ledger's two Claude events"
  assert_eq "0" "$(jq '[.hooks[][].hooks[].command | select(contains("ledger-") | not)] | length' .claude/settings.local.json 2>/dev/null)" "…alone in the settings"
  assert_file_exists ".claude/hooks/doc-superpowers/hook-lib.sh" "…with the hook-lib.sh they source"
  inst status
  assert_contains "$IOUT" "Ledger git hooks" "plain status reports the ledger git set"
  assert_contains "$IOUT" "Ledger Claude Code hooks" "…and the ledger Claude set"
  inst status --all
  assert_not_contains "$IOUT" "Ledger " "…status --all (the three tiers) reports neither"
  teardown
}

test_ledger_claude_only_no_general_tier() {
  echo "test: ledger: --ledger-claude alone writes the ledger's two Claude entries and nothing of the general Claude tier (no gate, sync or summary) and no git block"
  lgh_fixture
  local h
  inst install --ledger-claude
  assert_eq "0" "$IRC" "install --ledger-claude: exit 0"
  assert_eq "PostToolUse SessionStart" "$(jq -r '[.hooks | keys[]] | join(" ")' .claude/settings.local.json 2>/dev/null)" "two events: SessionStart and PostToolUse"
  assert_eq "ledger-session-notices.sh ledger-state-watch.sh" \
    "$(jq -r '[.hooks[][].hooks[].command | capture("doc-superpowers/(?<n>[a-z-]+[.]sh)").n] | sort | join(" ")' .claude/settings.local.json 2>/dev/null)" "…running the ledger's two scripts, nothing else"
  for h in pre-commit-gate post-commit-sync session-summary; do
    assert_not_contains "$(cat .claude/settings.local.json)" "$h" "no $h entry"
    assert_file_not_exists ".claude/hooks/doc-superpowers/$h.sh" "no $h.sh"
  done
  assert_file_exists ".claude/hooks/doc-superpowers/hook-lib.sh" "hook-lib.sh, which both scripts source"
  assert_eq "0 0 0" "$(lgh_legs)" "no git block"
  assert_file_not_exists .git/hooks/pre-commit "…no git hook at all"
  assert_true "the per-user files are excluded from git" git check-ignore -q .claude/settings.local.json
  inst status --claude
  assert_eq "3" "$(grep -c 'not installed' <<<"$IOUT")" "status --claude: the general tier is not installed"
  inst status --ledger-claude
  assert_eq "2" "$(grep -c '✓' <<<"$IOUT")" "status --ledger-claude: both events ✓"
  teardown
}

test_ledger_claude_flags_independent() {
  echo "test: ledger: --ledger-claude and --claude in either order — each install and uninstall leaves the other set intact"
  lgh_fixture
  local before plain lonly
  plain=$(harness_mktemp_d plain)
  lonly=$(harness_mktemp_d lonly)
  before=$(_tree_state)
  # --claude, then --ledger-claude; uninstall --ledger-claude, then --claude.
  inst install --claude
  jq -S . .claude/settings.local.json > "$plain/settings"
  inst install --ledger-claude
  assert_eq "0" "$IRC" "--ledger-claude after --claude: exit 0"
  assert_eq "PostToolUse PreToolUse SessionStart Stop" "$(jq -r '[.hooks | keys[]] | join(" ")' .claude/settings.local.json)" "both sets' events"
  inst uninstall --ledger-claude
  assert_eq "$(cat "$plain/settings")" "$(jq -S . .claude/settings.local.json)" "uninstall --ledger-claude: the general tier as it was"
  assert_file_exists .claude/hooks/doc-superpowers/session-summary.sh "…its scripts kept"
  assert_file_exists .claude/hooks/doc-superpowers/hook-lib.sh "…and hook-lib.sh"
  inst uninstall --claude
  assert_eq "$before" "$(_tree_state)" "both gone: as before"
  # --ledger-claude, then --claude; uninstall --claude, then --ledger-claude.
  inst install --ledger-claude
  jq -S . .claude/settings.local.json > "$lonly/settings"
  inst install --claude
  assert_eq "0" "$IRC" "--claude after --ledger-claude: exit 0"
  inst uninstall --claude
  assert_eq "$(cat "$lonly/settings")" "$(jq -S . .claude/settings.local.json)" "uninstall --claude: the ledger's events as they were"
  assert_file_exists .claude/hooks/doc-superpowers/ledger-state-watch.sh "…its scripts kept"
  assert_file_exists .claude/hooks/doc-superpowers/hook-lib.sh "…and hook-lib.sh, which they source"
  assert_true "…still excluded from git" git check-ignore -q .claude/settings.local.json
  run_claude_hook PostToolUse ledger-state-watch "$(lgh_write_payload "$HOME/x.md" "next: x-1")"
  assert_eq "0" "$RUN_RC" "…and the ledger hook still runs"
  inst uninstall --ledger-claude
  assert_eq "$before" "$(_tree_state)" "both gone: as before"
  teardown
}

test_ledger_blocks_markers_distinct() {
  echo "test: ledger: the markers are the set's own — the git tier's block code (every '# doc-superpowers:begin' match) never touches a ledger block, nor the reverse; an unpaired one is refused"
  lgh_fixture
  local orig gitonly before
  orig=$(harness_mktemp host)
  gitonly=$(harness_mktemp gitonly)
  inst install --ledger
  assert_contains "$(grep "^$LGH_BEGIN" .git/hooks/pre-commit)" "$LGH_BEGIN" "the block starts with '$LGH_BEGIN'"
  assert_eq "0" "$(grep -c '^# doc-superpowers:begin' .git/hooks/pre-commit || true)" "…no line of it starts with '# doc-superpowers:begin'"
  assert_eq "1" "$(grep -c '^# ledger-superpowers:end' .git/hooks/pre-commit || true)" "…and it ends with '# ledger-superpowers:end'"
  inst status --git
  assert_contains "$(grep ' pre-commit ' <<<"$IOUT")" "not installed" "status --git: a ledger block is not the git tier's"
  cp -p .git/hooks/pre-commit "$orig"
  inst uninstall --git
  assert_true "uninstall --git leaves a ledger-only hook byte-for-byte" cmp -s "$orig" .git/hooks/pre-commit
  inst uninstall --ledger
  # A hook of yours holding both blocks: each uninstall takes only its own.
  printf '#!/bin/sh\n# yours\necho "yours ran"\nexit 0\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  cp -p .git/hooks/pre-push "$orig"
  inst install --git
  cp -p .git/hooks/pre-push "$gitonly"
  inst install --ledger
  assert_eq "1 1" "$(grep -c '^# doc-superpowers:begin' .git/hooks/pre-push) $(lgh_blocks .git/hooks/pre-push)" "your hook holds both blocks"
  inst uninstall --ledger
  assert_true "uninstall --ledger takes only the ledger block" cmp -s "$gitonly" .git/hooks/pre-push
  inst install --ledger
  inst uninstall --git
  assert_eq "0 1" "$(grep -c '^# doc-superpowers:begin' .git/hooks/pre-push || true) $(lgh_blocks .git/hooks/pre-push)" "uninstall --git takes only its block"
  inst uninstall --ledger
  assert_true "…both gone: your hook byte-for-byte" cmp -s "$orig" .git/hooks/pre-push
  # An unpaired ledger marker: refused, nothing changed.
  printf '#!/bin/sh\n%s\necho half\n' "$LGH_BEGIN" > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  before=$(_tree_state)
  inst install --ledger
  assert_eq "1" "$IRC" "an unpaired '$LGH_BEGIN' line: install --ledger exits 1"
  assert_contains "$IOUT" "ledger-superpowers" "…naming the marker"
  assert_eq "$before" "$(_tree_state)" "…nothing changed"
  teardown
}

test_ledger_install_order_git_then_ledger() {
  echo "test: ledger: install --git then --ledger — the block goes into the git tier's hooks after their header comments; status --git stays ✓; re-running either install changes nothing"
  lgh_fixture
  local saved h
  saved=$(harness_mktemp_d saved)
  inst install --git
  inst install --ledger
  assert_eq "0" "$IRC" "exit 0"
  for h in pre-commit pre-push; do
    assert_eq "1" "$(lgh_blocks ".git/hooks/$h")" "$h: one ledger block"
    assert_contains "$(sed -n 2p ".git/hooks/$h")" "doc-superpowers hook v1" "$h: still the git tier's hook (its marker on line 2)"
    assert_eq "#" "$(awk -v b="$LGH_BEGIN" 'index($0, b) == 1 { print substr(prev, 1, 1); exit } { prev = $0 }' ".git/hooks/$h")" "$h: the block right after the header comments"
    cp -p ".git/hooks/$h" "$saved/$h"
  done
  inst status --git
  assert_contains "$(grep ' pre-commit ' <<<"$IOUT")" "✓" "status --git: pre-commit ✓ (the ledger block aside)"
  assert_contains "$(grep ' pre-push ' <<<"$IOUT")" "✓" "…pre-push ✓"
  inst install --git
  inst install --ledger
  for h in pre-commit pre-push; do
    assert_true "$h: re-running install --git and --ledger changes nothing" cmp -s "$saved/$h" ".git/hooks/$h"
  done
  assert_file_not_exists .git/hooks/.doc-superpowers-pre-commit "no local copy (the git tier's hook is whole)"
  lgh_bad_item
  git add -A
  run_hooked -- git commit -qm bad
  assert_eq "1" "$RUN_RC" "the ledger leg blocks an invalid item"
  teardown
}

test_ledger_install_order_ledger_then_git() {
  echo "test: ledger: install --ledger then --git gives the same hooks as --git then --ledger; uninstall --git hands back the ledger-only hooks"
  local saved lonly h
  saved=$(harness_mktemp_d saved)
  lonly=$(harness_mktemp_d lonly)
  lgh_fixture
  inst install --git
  inst install --ledger
  for h in pre-commit pre-push post-commit; do cp ".git/hooks/$h" "$saved/$h"; done
  teardown
  lgh_fixture
  inst install --ledger
  for h in pre-commit pre-push post-commit; do cp -p ".git/hooks/$h" "$lonly/$h"; done
  assert_eq "#!/bin/sh" "$(sed -n 1p .git/hooks/pre-commit)" "--ledger alone: a #!/bin/sh hook…"
  assert_contains "$(sed -n 2p .git/hooks/pre-commit)" "$LGH_BEGIN" "…holding the block"
  inst install --git
  assert_eq "0" "$IRC" "install --git over the ledger's hooks: exit 0"
  for h in pre-commit pre-push post-commit; do
    assert_true "$h: the same file as --git then --ledger" cmp -s "$saved/$h" ".git/hooks/$h"
  done
  assert_file_not_exists .git/hooks/.doc-superpowers-pre-commit "the git tier wrote its hook whole (no local copy)"
  inst status --git
  assert_contains "$(grep ' pre-commit ' <<<"$IOUT")" "✓" "status --git: pre-commit ✓"
  inst uninstall --git
  for h in pre-commit pre-push post-commit; do
    assert_true "$h: uninstall --git hands back the ledger-only hook" cmp -s "$lonly/$h" ".git/hooks/$h"
  done
  teardown
}

test_ledger_uninstall_each_tier_independent() {
  echo "test: ledger: each uninstall takes its own tier or set only — --ledger and --ledger-claude leave git and Claude as a plain install has them, and each other; --git and --claude leave both ledger sets working; all gone leave nothing"
  lgh_fixture
  local plain before h
  plain=$(harness_mktemp_d plain)
  before=$(_tree_state)
  inst install --git --claude
  for h in pre-commit pre-push; do cp ".git/hooks/$h" "$plain/$h"; done
  cp .claude/settings.local.json "$plain/settings"
  cp .git/info/exclude "$plain/exclude"
  inst install --ledger --ledger-claude
  assert_eq "0" "$IRC" "install --ledger --ledger-claude: exit 0"
  assert_contains "$(jq -c '.hooks.SessionStart' .claude/settings.local.json)" "ledger-session-notices.sh" "SessionStart → ledger-session-notices.sh"
  assert_eq '"Write|Edit|MultiEdit"' "$(jq -c '[.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("ledger-state-watch.sh")))][0].matcher' .claude/settings.local.json)" "PostToolUse (Write|Edit|MultiEdit) → ledger-state-watch.sh"
  inst uninstall --ledger
  assert_eq "0" "$IRC" "uninstall --ledger: exit 0"
  for h in pre-commit pre-push; do
    assert_true "$h: as the git tier alone has it" cmp -s "$plain/$h" ".git/hooks/$h"
  done
  assert_file_not_exists .git/hooks/post-commit "post-commit (the set created it) is removed"
  assert_contains "$(jq -c '.hooks.SessionStart' .claude/settings.local.json)" "ledger-session-notices.sh" "…the --ledger-claude set stays"
  inst install --ledger
  inst uninstall --ledger-claude
  assert_eq "0" "$IRC" "uninstall --ledger-claude: exit 0"
  assert_eq "1 1 1" "$(lgh_legs)" "…the --ledger blocks stay"
  inst uninstall --ledger
  assert_eq "$(jq -S . "$plain/settings")" "$(jq -S . .claude/settings.local.json)" "the settings: the Claude tier's entries alone"
  assert_true "info/exclude: as the Claude tier has it" cmp -s "$plain/exclude" .git/info/exclude
  assert_file_not_exists .claude/hooks/doc-superpowers/ledger-state-watch.sh "the ledger scripts are removed"
  assert_file_exists .claude/hooks/doc-superpowers/hook-lib.sh "…hook-lib.sh stays (the Claude tier's)"
  # The other way round: --git and --claude go; the ledger set stays and works.
  inst install --ledger --ledger-claude
  inst uninstall --git
  assert_eq "1 1 1" "$(lgh_legs)" "uninstall --git keeps every ledger block"
  assert_not_contains "$(head -5 .git/hooks/pre-commit)" "doc-superpowers hook v" "…in hooks no longer the git tier's"
  inst uninstall --claude
  assert_eq "0" "$IRC" "uninstall --claude: exit 0"
  assert_eq "PostToolUse SessionStart" "$(jq -r '[.hooks | keys[]] | join(" ")' .claude/settings.local.json 2>/dev/null)" "the ledger's Claude events stay"
  assert_eq "0" "$(jq '[.hooks[][].hooks[].command | select(contains("ledger-") | not)] | length' .claude/settings.local.json 2>/dev/null)" "…alone"
  assert_file_exists .claude/hooks/doc-superpowers/hook-lib.sh "hook-lib.sh stays (the ledger scripts source it)"
  assert_file_not_exists .claude/hooks/doc-superpowers/session-summary.sh "the Claude tier's scripts are gone"
  assert_true "the per-user files stay out of git (the ledger's exclude block)" git check-ignore -q .claude/settings.local.json
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION"
  assert_eq "0|" "$RUN_RC|$RUN_OUT" "the ledger SessionStart hook still runs (in-flight off: silent)"
  lgh_bad_item
  git add -A
  run_hooked -- git commit -qm bad
  assert_eq "1" "$RUN_RC" "the ledger pre-commit leg still blocks an invalid item"
  git reset -q
  rm -f docs/issues/bad.md
  inst uninstall --ledger --ledger-claude
  assert_eq "$before" "$(_tree_state)" "all uninstalled: hooks, settings, info/exclude, git config as before"
  teardown
}

test_ledger_pre_commit_blocks_invalid() {
  echo "test: ledger: pre-commit block — validate --staged exit 1 (findings) or 2 (could not run) blocks; DOC_SUPERPOWERS_LEDGER_SKIP=1 bypasses with a reason line; a valid item passes"
  lgh_fixture
  inst install --ledger
  local head
  head=$(git rev-parse HEAD)
  lgh_bad_item
  git add -A
  run_hooked -- git commit -qm bad
  assert_eq "1" "$RUN_RC" "an item in no registered ledger: the commit is blocked"
  assert_contains "$RUN_OUT$RUN_ERR" "nope" "…the finding names it"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_LEDGER_SKIP=1" "…and says how to bypass"
  assert_eq "$head" "$(git rev-parse HEAD)" "…no commit made"
  run_hooked DOC_SUPERPOWERS_LEDGER_SKIP=1 -- git commit -qm bad
  assert_eq "0" "$RUN_RC" "DOC_SUPERPOWERS_LEDGER_SKIP=1: the commit goes through"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_LEDGER_SKIP=1" "…with a line saying why the check was skipped"
  lgh_item docs/issues/good.md "key: x-1" "ledger: x" "status: Open" "summary: A valid item with its key"
  git add -A
  run_hooked -- git commit -qm good
  assert_eq "0" "$RUN_RC" "a valid item: the commit goes through"
  head=$(git rev-parse HEAD)
  printf 'not json\n' > docs/ledger/config.json
  echo y > src/y.js
  git add src/y.js
  run_hooked -- git commit -qm y
  assert_eq "1" "$RUN_RC" "validate --staged cannot run (exit 2): blocked too"
  assert_contains "$RUN_ERR" "exited 2" "…saying so"
  assert_eq "$head" "$(git rev-parse HEAD)" "…no commit made"
  teardown
}

test_ledger_pre_push_refuses_provisional_cas() {
  echo "test: ledger: pre-push block — keys.mode cas refuses a push adding a provisional key (an existing branch or a new one); DOC_SUPERPOWERS_LEDGER_SKIP=1 bypasses"
  lgh_fixture
  lgh_remote
  inst install --ledger
  local h before
  h=$(lgh_hex4 "docs/issues/n b.md")
  lgh_item "docs/issues/n b.md" "key: x-~$h" "ledger: x" "status: Open" "summary: Filed offline, a provisional key"
  git add -A
  git commit -qm n --no-verify
  before=$(git --git-dir="$LGH_REMOTE" rev-parse main)
  run_hooked -- git push -q origin main
  assert_true "a provisional key in the pushed commits: refused (rc $RUN_RC)" test "$RUN_RC" != 0
  assert_contains "$RUN_OUT$RUN_ERR" "x-~$h" "…naming the key"
  assert_contains "$RUN_OUT$RUN_ERR" "ledger finalize" "…and the fix"
  assert_eq "$before" "$(git --git-dir="$LGH_REMOTE" rev-parse main)" "…the remote is unchanged"
  run_hooked -- git push -q origin main:refs/heads/fresh
  assert_true "a new branch carrying it: refused too (rc $RUN_RC)" test "$RUN_RC" != 0
  assert_eq "" "$(git --git-dir="$LGH_REMOTE" rev-parse -q --verify refs/heads/fresh || true)" "…no branch created"
  run_hooked DOC_SUPERPOWERS_LEDGER_SKIP=1 -- git push -q origin main
  assert_eq "0" "$RUN_RC" "DOC_SUPERPOWERS_LEDGER_SKIP=1: pushed"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_LEDGER_SKIP=1" "…with a reason line"
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LGH_REMOTE" rev-parse main)" "…the remote has it"
  teardown
}

test_ledger_pre_push_refuses_long_provisional_cas() {
  echo "test: ledger: pre-push block — keys.mode cas refuses a push adding a 6-hex provisional key (Task 16c U9: provisional keys are 4–8 hex)"
  lgh_fixture
  lgh_remote
  inst install --ledger
  local before
  lgh_item docs/issues/n.md "key: x-~$(lgh_hex4 docs/issues/n.md)e0" "ledger: x" "status: Open" "summary: Filed offline, a lengthened provisional key"
  git add -A
  git commit -qm n --no-verify
  before=$(git --git-dir="$LGH_REMOTE" rev-parse main)
  run_hooked -- git push -q origin main
  assert_true "a 6-hex provisional key in the pushed commits: refused (rc $RUN_RC)" test "$RUN_RC" != 0
  assert_contains "$RUN_OUT$RUN_ERR" "x-~$(lgh_hex4 docs/issues/n.md)e0" "…naming the key"
  assert_eq "$before" "$(git --git-dir="$LGH_REMOTE" rev-parse main)" "…the remote is unchanged"
  teardown
}

test_ledger_pre_push_allows_provisional_merge_mode() {
  echo "test: ledger: pre-push block — keys.mode merge lets a provisional key through"
  lgh_fixture '{"keys":{"mode":"merge"}}'
  lgh_remote
  inst install --ledger
  local h log wrap old
  log=$(harness_mktemp calls)
  wrap=$(lgh_wrap "$log")
  h=$(lgh_hex4 "docs/issues/n.md")
  lgh_item docs/issues/n.md "key: x-~$h" "ledger: x" "status: Open" "summary: Filed offline, a provisional key"
  git add -A
  git commit -qm n --no-verify
  old=$(git rev-parse origin/main)
  run_hooked DOC_TOOLS="$wrap" -- git push -q origin main
  assert_eq "0" "$RUN_RC" "merge mode: the push goes through"
  assert_contains "$(cat "$log")" "ledger validate --pushed $old..$(git rev-parse HEAD)" "…after the ledger block checked it"
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LGH_REMOTE" rev-parse main)" "…the remote has it"
  teardown
}

test_ledger_pre_push_stdin_replayed() {
  echo "test: ledger: pre-push block — captures the ref lines and replays them, so the git tier's leg and your hook see the same lines"
  lgh_fixture
  lgh_remote
  local log wrap i old new line
  log=$(harness_mktemp calls)
  wrap=$(lgh_wrap "$log")
  # The git tier owning pre-push: its release reminder reads the ref lines.
  git tag v0
  for i in 1 2 3 4 5 6; do
    echo "$i" > "src/f$i.js"
    git add -A
    git commit -qm "c$i"
  done
  inst install --git --ledger
  old=$(git rev-parse origin/main)
  new=$(git rev-parse HEAD)
  run_hooked DOC_TOOLS="$wrap" -- git push origin main
  assert_eq "0" "$RUN_RC" "the push goes through"
  assert_contains "$(cat "$log")" "ledger validate --pushed $old..$new" "the ledger block read the ref line"
  assert_contains "$RUN_OUT$RUN_ERR" "6 commits since v0 on main" "…and the git tier's leg read it after (replayed)"
  # A hook of yours holding both blocks: every part sees the same line.
  inst uninstall --git --ledger
  printf '#!/bin/sh\n# yours\ncat > "$(git rev-parse --git-dir)/yours-push.log"\nexit 0\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  inst install --git --ledger
  printf '#!/bin/sh\ncat > "$(git rev-parse --git-dir)/ours-push.log"\n' > .git/hooks/.doc-superpowers-pre-push
  : > "$log"
  echo 7 > src/f7.js
  git add -A
  git commit -qm c7 --no-verify
  old=$(git rev-parse origin/main)
  new=$(git rev-parse HEAD)
  line="refs/heads/main $new refs/heads/main $old"
  run_hooked DOC_TOOLS="$wrap" -- git push origin main
  assert_eq "0" "$RUN_RC" "the push goes through"
  assert_eq "$line" "$(cat .git/ours-push.log 2>/dev/null)" "the git tier's block: the ref line"
  assert_eq "$line" "$(cat .git/yours-push.log 2>/dev/null)" "your hook: the same line"
  assert_contains "$(cat "$log")" "ledger validate --pushed $old..$new" "the ledger block: the same push"
  teardown
}

test_ledger_pre_push_foreign_stdin_intact() {
  echo "test: ledger: pre-push (R6) — the block goes before your pre-push code, which still reads exactly git's ref lines (a token guard reading stdin is not bypassed); no temp file is left, pushed or refused"
  lgh_fixture
  lgh_remote
  local tmpd want h old
  tmpd=$(harness_mktemp_d pushtmp)
  printf '#!/bin/sh\n# a storage-token guard: reads the pushed refs on stdin\ncat > "$(git rev-parse --git-dir)/guard-saw.log"\nexit 0\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  inst install --ledger
  assert_contains "$(sed -n 3p .git/hooks/pre-push)" "$LGH_BEGIN" "the ledger block goes before your guard's code"
  git branch side
  echo a > src/a.js
  git add -A
  git commit -qm a --no-verify
  git checkout -q side
  echo b > src/b.js
  git add -A
  git commit -qm b --no-verify
  git checkout -q main
  want=$(printf 'refs/heads/main %s refs/heads/main %s\nrefs/heads/side %s refs/heads/side %s\n' \
    "$(git rev-parse main)" "$(git rev-parse origin/main)" "$(git rev-parse side)" 0000000000000000000000000000000000000000 | LC_ALL=C sort)
  run_hooked TMPDIR="$tmpd" -- git push -q origin main side
  assert_eq "0" "$RUN_RC" "two refs pushed: exit 0"
  assert_eq "$want" "$(LC_ALL=C sort .git/guard-saw.log 2>/dev/null)" "your guard read exactly git's two ref lines"
  assert_eq "0" "$(find "$tmpd" -name 'doc-sp-ledger-push.*' | wc -l | tr -d ' ')" "…and no temp file is left"
  h=$(lgh_hex4 "docs/issues/n.md")
  lgh_item docs/issues/n.md "key: x-~$h" "ledger: x" "status: Open" "summary: Filed offline, a provisional key"
  git add -A
  git commit -qm n --no-verify
  rm -f .git/guard-saw.log
  run_hooked TMPDIR="$tmpd" -- git push -q origin main
  assert_true "a provisional key: refused (rc $RUN_RC)" test "$RUN_RC" != 0
  assert_eq "0" "$(find "$tmpd" -name 'doc-sp-ledger-push.*' | wc -l | tr -d ' ')" "…no temp file left either"
  old=$(git rev-parse origin/main)
  run_hooked TMPDIR="$tmpd" DOC_SUPERPOWERS_LEDGER_SKIP=1 -- git push -q origin main
  assert_eq "0" "$RUN_RC" "DOC_SUPERPOWERS_LEDGER_SKIP=1: pushed"
  assert_eq "refs/heads/main $(git rev-parse main) refs/heads/main $old" \
    "$(cat .git/guard-saw.log 2>/dev/null)" "…your guard still read git's ref line"
  teardown
}

# lgh_guard <hook> <#! line>: a foreign pre-push guard that counts the ref
# lines it reads on stdin (to stderr: "guard saw <n> line(s)").
lgh_guard() {
  printf '%s\n# a storage-token guard: reads the pushed refs on stdin\nn=0\nwhile read -r l; do n=$((n + 1)); done\necho "guard saw $n line(s)" >&2\nexit 0\n' "$2" > "$1"
  chmod +x "$1"
}

# lgh_dry_push_full_disk: `git push --dry-run origin main` (pre-push runs; git
# writes no file) with every file write failing (ulimit -f 0), stderr through
# a pipe (a file would fail too); "push-rc=<rc>" closes RUN_OUT.
lgh_dry_push_full_disk() {
  run_hooked TMPDIR="$1" -- sh -c '(ulimit -f 0; git push --dry-run origin main; echo "push-rc=$?") 2>&1 | cat'
}

test_ledger_pre_push_copy_failure_refuses() {
  echo "test: ledger (fix round 1, I1): when git's ref lines cannot be copied (every file write fails), the ledger block and the git tier's integration block refuse the push instead of handing your guard an empty stdin; no temp file is left"
  lgh_fixture
  lgh_remote
  local tmpd
  tmpd=$(harness_mktemp_d pushtmp)
  echo a > src/a.js
  git add -A
  git commit -qm a --no-verify
  # The ledger block, before a bash guard (bash: the suite's interpreter).
  lgh_guard .git/hooks/pre-push '#!/usr/bin/env bash'
  inst install --ledger
  run_hooked TMPDIR="$tmpd" -- sh -c '(git push --dry-run origin main; echo "push-rc=$?") 2>&1 | cat'
  assert_contains "$RUN_OUT" "guard saw 1 line(s)" "control: the guard reads git's ref line"
  assert_contains "$RUN_OUT" "push-rc=0" "…and the dry run goes through"
  lgh_dry_push_full_disk "$tmpd"
  assert_contains "$RUN_OUT" "push-rc=1" "the copy fails: the ledger block refuses the push"
  assert_contains "$RUN_OUT" "ledger: push refused" "…with its reason line"
  assert_not_contains "$RUN_OUT" "guard saw 0 line(s)" "…never handing your guard an empty stdin"
  assert_eq "0" "$(find "$tmpd" -name 'doc-sp-*' | wc -l | tr -d ' ')" "…and no temp file is left"
  # The same block in a POSIX sh guard.
  inst uninstall --ledger
  lgh_guard .git/hooks/pre-push '#!/bin/sh'
  inst install --ledger
  lgh_dry_push_full_disk "$tmpd"
  assert_contains "$RUN_OUT" "push-rc=1" "a #!/bin/sh hook: refused too"
  assert_not_contains "$RUN_OUT" "guard saw 0 line(s)" "…your guard never runs on an empty stdin"
  assert_eq "0" "$(find "$tmpd" -name 'doc-sp-*' | wc -l | tr -d ' ')" "…no temp file left"
  # The git tier's integration block (no ledger), before a bash guard.
  inst uninstall --ledger
  lgh_guard .git/hooks/pre-push '#!/usr/bin/env bash'
  inst install --git
  assert_contains "$(sed -n 2p .git/hooks/pre-push)" "# doc-superpowers:begin" "the git tier's block is in your hook"
  run_hooked TMPDIR="$tmpd" -- sh -c '(git push --dry-run origin main; echo "push-rc=$?") 2>&1 | cat'
  assert_contains "$RUN_OUT" "guard saw 1 line(s)" "control: the guard reads git's ref line after the git tier's block"
  lgh_dry_push_full_disk "$tmpd"
  assert_contains "$RUN_OUT" "push-rc=1" "the copy fails: the git tier's block refuses the push"
  assert_contains "$RUN_OUT" "doc-superpowers: push refused" "…with its reason line"
  assert_not_contains "$RUN_OUT" "guard saw 0 line(s)" "…never handing your guard an empty stdin"
  assert_eq "0" "$(find "$tmpd" -name 'doc-sp-*' | wc -l | tr -d ' ')" "…and no temp file is left"
  teardown
}

test_ledger_git_status_flags_old_pre_push_block() {
  echo "test: ledger (fix round 1, I1): status --git compares the whole integration block, so a pre-push block of the shape that failed open reads as outdated"
  setup
  printf '#!/bin/sh\necho yours\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  inst install --git
  inst status --git
  assert_contains "$(grep ' pre-push ' <<<"$IOUT")" "✓" "the current block: ✓"
  # The earlier block: an unchecked copy of the ref lines.
  awk 'index($0, "  if ! cat > ") == 1 { print "  cat > \"$DOC_SP_IN\"; bash \"$DOC_SP_HOOK\" \"$@\" < \"$DOC_SP_IN\" || true; exec < \"$DOC_SP_IN\"; rm -f \"$DOC_SP_IN\""; skip = 1; next }
       skip && index($0, "  bash ") == 1 { skip = 0; next } { print }' .git/hooks/pre-push > .git/pre-push.old
  cat .git/pre-push.old > .git/hooks/pre-push
  inst status --git
  assert_contains "$(grep ' pre-push ' <<<"$IOUT")" "outdated" "the earlier block: ⚠ outdated (re-run install --git)"
  teardown
}

test_ledger_pre_push_delete_replayed() {
  echo "test: ledger (fix round 1, m3): a delete-only push — the ledger block checks nothing (deletions are skipped) and your guard still reads git's delete line"
  lgh_fixture
  lgh_remote
  local old
  git push -q origin main:refs/heads/side
  old=$(git --git-dir="$LGH_REMOTE" rev-parse side)
  printf '#!/bin/sh\n# a guard\ncat > "$(git rev-parse --git-dir)/guard-saw.log"\nexit 0\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  inst install --ledger
  run_hooked -- git push -q origin :refs/heads/side
  assert_eq "0" "$RUN_RC" "the delete goes through"
  assert_eq "(delete) 0000000000000000000000000000000000000000 refs/heads/side $old" "$(cat .git/guard-saw.log 2>/dev/null)" "your guard read git's delete line"
  assert_eq "" "$(git --git-dir="$LGH_REMOTE" rev-parse -q --verify refs/heads/side || true)" "…and the branch is gone"
  teardown
}

test_ledger_post_commit_batch_ssh() {
  echo "test: ledger (fix round 1, I2): the background in-flight push never prompts — ssh runs with -o BatchMode=yes, following git's precedence (added to GIT_SSH_COMMAND, else core.sshCommand, else — unless GIT_SSH names the program — ssh), GIT_SSH left alone, GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never"
  lgh_fixture
  inst install --ledger
  local wrap out n
  wrap=$(harness_mktemp wrap)
  printf '#!/bin/sh\nif [ "$2" = inflight ]; then\n  { echo "ssh=${GIT_SSH_COMMAND-<unset>}"; echo "gitssh=${GIT_SSH-<unset>}"; echo "prompt=${GIT_TERMINAL_PROMPT-<unset>}"; echo "gcm=${GCM_INTERACTIVE-<unset>}"; } > "$LGH_OUT.tmp" && mv "$LGH_OUT.tmp" "$LGH_OUT"\n  exit 0\nfi\nexec "%s" "$@"\n' "$DOC_TOOLS" > "$wrap"
  chmod +x "$wrap"
  # lgh_env_commit <name> [VAR=value …]: commit; wait (30 s) for the job's env.
  lgh_env_commit() {
    local name="$1"
    shift
    out="$TEST_DIR/.git/env-$name"
    echo "$name" > "src/$name.js"
    git add -A
    (
      unset GIT_SSH GIT_SSH_COMMAND GIT_TERMINAL_PROMPT GCM_INTERACTIVE
      run_hooked DOC_TOOLS="$wrap" LGH_OUT="$out" ${1+"$@"} -- git commit -qm "$name"
    )
    n=0
    while [ ! -e "$out" ] && [ "$n" -lt 300 ]; do
      sleep 0.1
      n=$((n + 1))
    done
  }
  lgh_env_commit plain
  assert_eq "ssh=ssh -o BatchMode=yes|gitssh=<unset>|prompt=0|gcm=never" "$(paste -sd '|' "$out" 2>/dev/null)" "nothing set: ssh -o BatchMode=yes; no prompts"
  git config core.sshCommand "ssh -i key"
  lgh_env_commit sshcommand
  assert_contains "$(cat "$out" 2>/dev/null)" "ssh=ssh -i key -o BatchMode=yes" "core.sshCommand kept, BatchMode added"
  lgh_env_commit preset GIT_SSH_COMMAND="ssh -v"
  assert_contains "$(cat "$out" 2>/dev/null)" "ssh=ssh -v -o BatchMode=yes" "a preset GIT_SSH_COMMAND kept (it wins over core.sshCommand), BatchMode added"
  # git's precedence: GIT_SSH_COMMAND > core.sshCommand > GIT_SSH > ssh. Only
  # when neither of the first two is set does GIT_SSH name the program git runs.
  lgh_env_commit gitsshcore GIT_SSH=/usr/local/bin/my-ssh
  assert_contains "$(cat "$out" 2>/dev/null)" "ssh=ssh -i key -o BatchMode=yes" "GIT_SSH and core.sshCommand set: git runs core.sshCommand, so BatchMode goes on it"
  assert_contains "$(cat "$out" 2>/dev/null)" "gitssh=/usr/local/bin/my-ssh" "…GIT_SSH left alone"
  lgh_env_commit gitsshpreset GIT_SSH=/usr/local/bin/my-ssh GIT_SSH_COMMAND="ssh -v"
  assert_contains "$(cat "$out" 2>/dev/null)" "ssh=ssh -v -o BatchMode=yes" "GIT_SSH and GIT_SSH_COMMAND set: git runs GIT_SSH_COMMAND, so BatchMode goes on it"
  git config --unset core.sshCommand
  lgh_env_commit gitssh GIT_SSH=/usr/local/bin/my-ssh
  assert_contains "$(cat "$out" 2>/dev/null)" "ssh=<unset>" "GIT_SSH alone (no core.sshCommand): GIT_SSH_COMMAND not added"
  assert_contains "$(cat "$out" 2>/dev/null)" "gitssh=/usr/local/bin/my-ssh" "…GIT_SSH left alone"
  assert_contains "$(cat "$out" 2>/dev/null)" "prompt=0" "…and still no terminal prompt"
  teardown
}

test_ledger_session_hook_budget() {
  echo "test: ledger (fix round 1, I3): a SessionStart run past its 2 s budget is cut — the hook returns in about 2 s with the '(budget)' line; in-flight awareness off: doc-tools.sh is not run at all"
  lgh_fixture '{"inflight":{"enabled":true}}'
  inst install --ledger-claude
  local slow log t0 t1
  log=$(harness_mktemp calls)
  slow=$(harness_mktemp slow)
  printf '#!/bin/sh\necho called >> "%s"\nsleep 10\necho "stop late other no PR files:f — x → y"\n' "$log" > "$slow"
  chmod +x "$slow"
  t0=$(date +%s)
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$slow"
  t1=$(date +%s)
  assert_true "it returns well before the 10 s stub ($((t1 - t0)) s; budget 2 s)" test "$((t1 - t0))" -le 5
  assert_contains "$(jq -r '.systemMessage // empty' <<<"$RUN_OUT" 2>/dev/null)" "(budget)" "…with the budget line"
  printf '{}\n' > docs/ledger/config.json
  : > "$log"
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$slow"
  assert_eq "0||" "$RUN_RC|$RUN_OUT|$(cat "$log")" "in-flight awareness off: silent, doc-tools.sh never run"
  teardown
}

test_ledger_claude_tracked_note_names_flag() {
  echo "test: ledger (fix round 1, m1): the tracked-files note from --ledger-claude tells teammates to re-run --ledger-claude (not --claude, which would install the general tier)"
  lgh_fixture
  mkdir -p .claude
  printf '{}\n' > .claude/settings.local.json
  git add -f .claude/settings.local.json
  git commit -qm tracked
  inst install --ledger-claude
  assert_contains "$IOUT" "'install.sh install --ledger-claude' after pulling" "the note names --ledger-claude"
  assert_not_contains "$IOUT" "'install.sh install --claude' after pulling" "…not --claude"
  teardown
}

test_ledger_post_commit_backgrounds() {
  echo "test: ledger: post-commit block — ledger inflight --push runs in the background (the commit does not wait), its output in <git common dir>/doc-superpowers/ledger/push.log; the test waits for it (sentinel, timeout)"
  lgh_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"}}'
  lgh_remote
  inst install --ledger
  git checkout -q -b topic
  local wrap go sent n=0 ref="refs/doc-superpowers/inflight/hosta/topic" log
  go="$TEST_DIR/.git/lgh-go"
  sent="$TEST_DIR/.git/lgh-done"
  wrap=$(harness_mktemp wrap)
  printf '#!/bin/sh\nif [ "$2" = inflight ]; then\n  n=0\n  while [ ! -e "%s" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done\n  "%s" "$@"; rc=$?\n  echo "$rc" > "%s"\n  exit "$rc"\nfi\nexec "%s" "$@"\n' \
    "$go" "$DOC_TOOLS" "$sent" "$DOC_TOOLS" > "$wrap"
  chmod +x "$wrap"
  echo work > work.txt
  git add work.txt
  run_hooked DOC_TOOLS="$wrap" -- git commit -qm "topic work"
  assert_eq "0" "$RUN_RC" "the commit succeeds"
  assert_file_not_exists "$sent" "…and returns while the push still waits (it runs in the background, holding none of the commit's output)"
  : > "$go"
  while [ ! -e "$sent" ] && [ "$n" -lt 300 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  assert_file_exists "$sent" "the background push finished (sentinel, within 30 s)"
  assert_eq "0" "$(cat "$sent" 2>/dev/null)" "…exit 0"
  log="$(git rev-parse --git-common-dir)/doc-superpowers/ledger/push.log"
  assert_contains "$(cat "$log" 2>/dev/null)" "pushed $(git rev-parse --short HEAD) to origin $ref" "its output is in push.log"
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LGH_REMOTE" rev-parse -q --verify "$ref" || true)" "…and the in-flight ref is on the remote"
  teardown
}

test_ledger_session_hook_wraps_verb() {
  echo "test: ledger: SessionStart (Task 16c U4) — a thin wrapper over 'doc-tools.sh ledger notices --hook', offline, the event on its stdin: what the verb prints is the hook's output, verbatim; silent when it prints nothing; a verb that fails (one that predates --hook): one 'cannot list' line; DOC_SUPERPOWERS_LEDGER_SKIP=1: nothing run; the real doc-tools.sh, in-flight awareness off: silent"
  lgh_fixture '{"inflight":{"enabled":true}}'
  inst install --ledger-claude
  local fake log obj
  log=$(harness_mktemp calls)
  fake=$(harness_mktemp fake)
  obj='{"systemMessage":"ledger: 1 in-flight notice(s)","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ledger: 1 in-flight notice(s)"}}'
  cat > "$fake" <<EOF
#!/bin/sh
printf '%s|offline=%s|' "\$*" "\${DOC_TOOLS_LEDGER_OFFLINE:-}" >> "$log"
cat >> "$log"
echo >> "$log"
[ -n "\${FAKE_NONE:-}" ] && exit 0
if [ -n "\${FAKE_OLD:-}" ]; then echo "ERROR: unknown option '--hook'." >&2; exit 3; fi
printf '%s\n' '$obj'
EOF
  chmod +x "$fake"
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake"
  assert_eq "0|$obj" "$RUN_RC|$RUN_OUT" "the verb's object, verbatim"
  assert_eq "ledger notices --hook|offline=1|$LGH_SESSION" "$(cat "$log")" "one call: ledger notices --hook, offline, the SessionStart event on its stdin"
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake" FAKE_NONE=1
  assert_eq "0|" "$RUN_RC|$RUN_OUT" "the verb prints nothing: silent"
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake" FAKE_OLD=1
  assert_eq "0" "$RUN_RC" "a doc-tools.sh that predates --hook: exit 0"
  assert_contains "$(jq -r '.systemMessage // empty' <<<"$RUN_OUT" 2>/dev/null)" "ledger: cannot list the in-flight notices: unknown option '--hook'" "…one 'cannot list' line with its error"
  : > "$log"
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake" DOC_SUPERPOWERS_LEDGER_SKIP=1
  assert_eq "0||" "$RUN_RC|$RUN_OUT|$(cat "$log")" "DOC_SUPERPOWERS_LEDGER_SKIP=1: off (nothing run)"
  printf '{}\n' > docs/ledger/config.json
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION"
  assert_eq "0|" "$RUN_RC|$RUN_OUT" "the real doc-tools.sh, in-flight awareness off: silent"
  teardown
}

test_ledger_state_watch_advisory() {
  echo "test: ledger: PostToolUse(Write|Edit) state-watch — a write under state_watch.paths naming an item key and a state_watch pattern gets one advisory line naming 'doc-tools.sh ledger note <key> \"…\"'; anything else is silent; never blocks"
  lgh_fixture '{"state_watch":{"paths":["~/notes","scratch/*/state"],"patterns":["next:","Approved"]}}'
  inst install --ledger-claude
  lgh_watch "$(lgh_write_payload "$HOME/notes/today.md" "x-12 next: wire the hook")"
  assert_contains "$LGH_CTX" 'doc-tools.sh ledger note x-12 "…"' "a key and a pattern under ~/notes: the advisory names ledger note x-12"
  assert_eq "1" "$(printf '%s\n' "$LGH_CTX" | wc -l | tr -d ' ')" "…in one line"
  lgh_watch "$(lgh_edit_payload "$TEST_DIR/scratch/a/state/s.md" "APPROVED for x-3 by the owner")"
  assert_contains "$LGH_CTX" "ledger note x-3" "an Edit under scratch/*/state (relative, '*' one segment), pattern any case: advisory"
  lgh_watch "$(lgh_write_payload "$HOME/notes/today.md" "x-12 is a fine item")"
  assert_eq "" "$LGH_CTX" "a key but no pattern: silent"
  lgh_watch "$(lgh_write_payload "$HOME/notes/today.md" "next: tidy up")"
  assert_eq "" "$LGH_CTX" "a pattern but no key: silent"
  lgh_watch "$(lgh_write_payload "$HOME/notes/today.md" "next: q-4 on 2026-10-14")"
  assert_eq "" "$LGH_CTX" "only keys of no registered ledger (q-4, a date): silent"
  lgh_watch "$(lgh_write_payload "$HOME/elsewhere/today.md" "x-12 next: wire the hook")"
  assert_eq "" "$LGH_CTX" "outside state_watch.paths: silent"
  lgh_watch "$(lgh_write_payload "$HOME/notes2/today.md" "x-12 next: wire the hook")"
  assert_eq "" "$LGH_CTX" "a sibling sharing the prefix (~/notes2): silent"
  lgh_watch "$(lgh_write_payload "$TEST_DIR/scratch/a/b/state/s.md" "x-12 next: wire the hook")"
  assert_eq "" "$LGH_CTX" "'*' does not cross a '/': silent"
  lgh_watch '{not json'
  assert_eq "0|" "$RUN_RC|$RUN_OUT" "a payload it cannot read: silent, exit 0"
  lgh_watch '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"content":"x-12 next: wire the hook"}}'
  assert_eq "0|" "$RUN_RC|$RUN_OUT" "a payload without file_path: silent, exit 0"
  lgh_watch "$(lgh_write_payload "$HOME/notes/today.md" "x-12 next: wire the hook")" DOC_SUPERPOWERS_LEDGER_SKIP=1
  assert_eq "" "$LGH_CTX" "DOC_SUPERPOWERS_LEDGER_SKIP=1: off"
  teardown
}

test_ledger_legs_honour_both_skips() {
  # Ruling (audit 2026-10-15): DOC_SUPERPOWERS_SKIP=1 bypasses all hooks, the
  # ledger legs included — beside DOC_SUPERPOWERS_LEDGER_SKIP=1, which
  # bypasses the ledger legs alone. The ledger block runs before the git
  # tier's own SKIP exit, so each leg checks both itself.
  echo "test: ledger: DOC_SUPERPOWERS_SKIP=1 and DOC_SUPERPOWERS_LEDGER_SKIP=1 each skip every ledger leg — pre-commit and pre-push with a line naming the variable, post-commit, SessionStart and state-watch silently"
  lgh_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"state_watch":{"paths":["~/notes"],"patterns":["next:"]}}'
  lgh_remote
  inst install --ledger --ledger-claude
  local var head h calls fake wrap n
  calls=$(harness_mktemp calls)
  # A stand-in doc-tools.sh for the post-commit leg: it logs its call and
  # pushes nothing (no background job outlives the test).
  wrap=$(harness_mktemp stub)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$calls" > "$wrap"
  chmod +x "$wrap"
  fake=$(harness_mktemp fake)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nprintf "%%s\\n" %s\n' "$calls" \
    "'{\"systemMessage\":\"x\",\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"x\"}}'" > "$fake"
  chmod +x "$fake"
  for var in DOC_SUPERPOWERS_SKIP DOC_SUPERPOWERS_LEDGER_SKIP; do
    # pre-commit: an item in no registered ledger would block the commit.
    lgh_item "docs/issues/bad-$var.md" "key: nope-1" "ledger: nope" "status: Open" "summary: An item in no registered ledger"
    git add -A
    head=$(git rev-parse HEAD)
    run_hooked "$var=1" -- git commit -qm "bad ($var)"
    assert_eq "0" "$RUN_RC" "$var=1: pre-commit lets the commit through"
    assert_contains "$RUN_ERR" "ledger: validate --staged skipped ($var=1)" "…with a line naming $var"
    # pre-push: a provisional key would refuse the push (keys.mode cas).
    h=$(lgh_hex4 "docs/issues/p-$var.md")
    lgh_item "docs/issues/p-$var.md" "key: x-~$h" "ledger: x" "status: Open" "summary: Filed offline, a provisional key"
    git add -A
    git commit -qm "provisional ($var)" --no-verify
    run_hooked "$var=1" -- git push -q origin HEAD:main
    assert_eq "0" "$RUN_RC" "$var=1: pre-push lets the push through"
    assert_contains "$RUN_ERR" "ledger: pre-push check skipped ($var=1)" "…with a line naming $var"
    assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LGH_REMOTE" rev-parse main)" "…the remote has it"
    # post-commit: no in-flight push is started (a control commit shows one is).
    git checkout -q -b "topic-$var"
    : > "$calls"
    echo "$var" > "skip-$var.txt"
    git add "skip-$var.txt"
    run_hooked "$var=1" DOC_TOOLS="$wrap" -- git commit -qm "skipped push ($var)" --no-verify
    assert_eq "0" "$RUN_RC" "$var=1: the commit succeeds"
    echo control > "control-$var.txt"
    git add "control-$var.txt"
    run_hooked DOC_TOOLS="$wrap" -- git commit -qm "control ($var)" --no-verify
    n=0
    while ! grep -q "inflight --push" "$calls" 2>/dev/null && [ "$n" -lt 300 ]; do
      sleep 0.1
      n=$((n + 1))
    done
    sleep 1
    assert_eq "1" "$(grep -c "inflight --push" "$calls" || true)" "$var=1: post-commit starts no in-flight push (the control commit's is the only one)"
    git checkout -q main
    # SessionStart and state-watch: doc-tools.sh is not run, nothing printed.
    : > "$calls"
    run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake" "$var=1"
    assert_eq "0||" "$RUN_RC|$RUN_OUT|$(cat "$calls")" "$var=1: SessionStart is off (nothing run, nothing printed)"
    run_claude_hook PostToolUse ledger-state-watch "$(lgh_write_payload "$HOME/notes/today.md" "x-1 next: y")" DOC_TOOLS="$fake" "$var=1"
    assert_eq "0||" "$RUN_RC|$RUN_OUT|$(cat "$calls")" "$var=1: state-watch is off (nothing run, nothing printed)"
  done
  # Neither set: the SessionStart and state-watch legs do run (the control).
  run_claude_hook SessionStart ledger-session-notices "$LGH_SESSION" DOC_TOOLS="$fake"
  assert_contains "$(cat "$calls")" "ledger notices --hook" "neither variable: SessionStart runs ledger notices --hook"
  : > "$calls"
  run_claude_hook PostToolUse ledger-state-watch "$(lgh_write_payload "$HOME/notes/today.md" "x-1 next: y")" DOC_TOOLS="$fake"
  assert_contains "$(cat "$calls")" "state-watch --hook" "neither variable: state-watch runs ledger state-watch --hook (final review, Task 17 m6)"
  teardown
}

test_ledger_foreign_hook_runs_ledger_first() {
  echo "test: ledger: a hook of yours ending in 'exit 0' — the block goes after its #! and leading comments, before your code, so the exit cannot skip it; the mode is kept; uninstall restores it byte-for-byte"
  lgh_fixture
  local orig
  orig=$(harness_mktemp host)
  printf '#!/bin/sh\n# managed by the host repo: its own hook blocks\n# (keep this header)\necho "yours ran" >> .git/yours.log\nexit 0\n' > .git/hooks/pre-commit
  chmod 750 .git/hooks/pre-commit
  cp -p .git/hooks/pre-commit "$orig"
  inst install --ledger
  assert_eq "0" "$IRC" "exit 0"
  assert_eq "$(sed -n 1,3p "$orig")" "$(sed -n 1,3p .git/hooks/pre-commit)" "your #! line and leading comments stay first"
  assert_contains "$(sed -n 4p .git/hooks/pre-commit)" "$LGH_BEGIN" "…the block right after them"
  assert_eq "$(tail -n 2 "$orig")" "$(tail -n 2 .git/hooks/pre-commit)" "…your code after it, unchanged"
  assert_eq "$(ls -l "$orig" | cut -c1-10)" "$(ls -l .git/hooks/pre-commit | cut -c1-10)" "the mode is kept"
  lgh_bad_item
  git add -A
  run_hooked -- git commit -qm bad
  assert_eq "1" "$RUN_RC" "an invalid item is blocked although your hook ends in 'exit 0'"
  assert_file_not_exists .git/yours.log "…the ledger ran first"
  git reset -q
  rm -f docs/issues/bad.md
  echo ok > src/ok.js
  git add src/ok.js
  run_hooked -- git commit -qm ok
  assert_eq "0" "$RUN_RC" "a valid commit goes through"
  assert_eq "yours ran" "$(cat .git/yours.log 2>/dev/null)" "…and your hook ran"
  inst install --ledger
  assert_eq "1" "$(lgh_blocks .git/hooks/pre-commit)" "re-install: still one block"
  inst uninstall --ledger
  assert_true "uninstall restores your hook byte-for-byte" cmp -s "$orig" .git/hooks/pre-commit
  assert_eq "$(ls -l "$orig" | cut -c1-10)" "$(ls -l .git/hooks/pre-commit | cut -c1-10)" "…and its mode"
  teardown
}

test_ledger_state_watch_paths_spaces_tilde() {
  echo "test: ledger: state_watch.paths with spaces and '~' inside segments (an iCloud dir) — only a leading '~/' is \$HOME; nothing word-split or glob-expanded; only '*' is special"
  # shellcheck disable=SC2088  # tildes are the config's text, not the shell's
  local icloud='~/Library/Mobile Documents/com~apple~CloudDocs/claude-memory'
  lgh_fixture "$(jq -nc --arg a "$icloud" '{state_watch: {paths: [$a, "/srv/odd [dir]?/m*", "~nobody/x", "~/g*"], patterns: ["next:"]}}')"
  inst install --ledger-claude
  mkdir -p "$HOME/ga" "$HOME/gb"
  lgh_watch "$(lgh_write_payload "$HOME/Library/Mobile Documents/com~apple~CloudDocs/claude-memory/proj/MEMORY.md" "next: x-7 review")"
  assert_contains "$LGH_CTX" 'ledger note x-7 "…"' "spaces and com~apple~CloudDocs under \$HOME: advisory"
  lgh_watch "$(lgh_write_payload "$HOME/Library/Mobile Documents/com/claude-memory/MEMORY.md" "next: x-7 review")"
  assert_eq "" "$LGH_CTX" "…a mid-path '~' is no wildcard"
  lgh_watch "$(lgh_write_payload "/srv/odd [dir]?/memo/f.md" "next: x-7 review")"
  assert_contains "$LGH_CTX" "ledger note x-7" "'[', ']' and '?' are themselves; 'm*' matches memo"
  lgh_watch "$(lgh_write_payload "/srv/odd d?/memo/f.md" "next: x-7 review")"
  assert_eq "" "$LGH_CTX" "…'[dir]' is no character class"
  lgh_watch "$(lgh_write_payload "/srv/odd [dir]x/memo/f.md" "next: x-7 review")"
  assert_eq "" "$LGH_CTX" "…'?' is no wildcard"
  lgh_watch "$(lgh_write_payload "$TEST_DIR/~nobody/x/f.md" "next: x-7 review")"
  assert_contains "$LGH_CTX" "ledger note x-7" "'~nobody/x' (no '/' after '~'): a path in the project"
  lgh_watch "$(lgh_write_payload "$HOME/x/f.md" "next: x-7 review")"
  assert_eq "" "$LGH_CTX" "…never ~user expansion"
  lgh_watch "$(lgh_write_payload "$HOME/gc/f.md" "next: x-7 review")"
  assert_contains "$LGH_CTX" "ledger note x-7" "'~/g*' matches ~/gc, a directory that does not exist (a pattern, not a glob of the disk)"
  lgh_watch "$(lgh_write_payload "/gc/f.md" "next: x-7 review")" HOME=
  assert_eq "0|" "$RUN_RC|$LGH_CTX" "(fix round 1, m5) HOME empty: '~/g*' matches nothing (not /g*)"
  lgh_watch "$(lgh_write_payload "/Library/Mobile Documents/com~apple~CloudDocs/claude-memory/M.md" "next: x-7 review")" HOME=
  assert_eq "" "$LGH_CTX" "…nor does the iCloud entry"
  teardown
}

test_ledger_status_reports_set() {
  echo "test: ledger: status reports each ledger set in its own section (status --ledger, status --ledger-claude; plain status both) — ✓, ⚠ outdated, ✗"
  lgh_fixture
  local h t
  inst status --ledger
  assert_contains "$IOUT" "Ledger git hooks" "status --ledger: its section"
  assert_contains "$(grep ' pre-commit ' <<<"$IOUT")" "not installed" "…✗ before an install"
  assert_not_contains "$IOUT" "Git Hooks" "…and no tier"
  assert_not_contains "$IOUT" "Ledger Claude Code hooks" "…nor the other set"
  inst status --ledger-claude
  assert_contains "$IOUT" "Ledger Claude Code hooks" "status --ledger-claude: its section"
  assert_not_contains "$IOUT" "Ledger git hooks" "…alone"
  inst install --git --claude --ledger --ledger-claude
  inst status --ledger
  for h in pre-commit pre-push post-commit; do
    assert_contains "$(grep " $h " <<<"$IOUT")" "✓" "$h ✓"
  done
  inst status --ledger-claude
  for h in ledger-session-notices ledger-state-watch; do
    assert_contains "$(grep " $h " <<<"$IOUT")" "✓" "$h ✓"
  done
  t=$(harness_mktemp hook)
  awk -v b="$LGH_BEGIN" '{ print } index($0, b) == 1 { print "echo tampered" }' .git/hooks/pre-push > "$t"
  cat "$t" > .git/hooks/pre-push
  inst status --ledger
  assert_contains "$(grep ' pre-push ' <<<"$IOUT")" "outdated" "a changed block: ⚠ outdated"
  inst status
  assert_contains "$IOUT" "Ledger git hooks" "plain status: the ledger git set"
  assert_contains "$IOUT" "Ledger Claude Code hooks" "…the ledger Claude set"
  assert_contains "$IOUT" "Git Hooks" "…beside the tiers"
  teardown
}

test_ledger_state_watch_matcher_multiedit() {
  # 3.3.1 item 4 (final review OPS-m5): the state-watch verb reads
  # MultiEdit's edits[].new_string, so its PostToolUse entry names
  # MultiEdit too; an install made with the old matcher reads outdated.
  echo "test: ledger: --ledger-claude registers state-watch for Write|Edit|MultiEdit; an older install (matcher Write|Edit) reads outdated in status --ledger-claude and status --claude; re-running install --ledger-claude updates it in place"
  lgh_fixture '{"state_watch":{"paths":["~/notes"],"patterns":["next:"]}}'
  local t sel='[.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("ledger-state-watch.sh")))]'
  inst install --ledger-claude
  assert_eq "0" "$IRC" "install --ledger-claude: exit 0"
  assert_eq '"Write|Edit|MultiEdit"' "$(jq -c "$sel[0].matcher" .claude/settings.local.json)" "PostToolUse (Write|Edit|MultiEdit) → ledger-state-watch.sh"
  assert_contains "$IOUT" "Write|Edit|MultiEdit" "…the install line says so"
  lgh_watch "$(jq -nc --arg p "$HOME/notes/today.md" '{hook_event_name: "PostToolUse", tool_name: "MultiEdit", tool_input: {file_path: $p, edits: [{old_string: "a", new_string: "b"}, {old_string: "c", new_string: "x-7 next: ship it"}]}}')"
  assert_contains "$LGH_CTX" "ledger note x-7" "a MultiEdit payload: the advisory reads its edits"
  # An install 3.3.0 made: the same entry, matcher Write|Edit.
  t=$(harness_mktemp settings)
  jq '(.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("ledger-state-watch.sh"))) | .matcher) = "Write|Edit"' \
    .claude/settings.local.json > "$t"
  cat "$t" > .claude/settings.local.json
  inst status --ledger-claude
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "⚠" "status --ledger-claude: the old matcher is ⚠"
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "outdated" "…outdated"
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "Write|Edit|MultiEdit" "…naming the matcher it wants"
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "install --ledger-claude" "…and the command that fixes it"
  assert_contains "$(grep ' ledger-session-notices ' <<<"$IOUT")" "✓" "…the SessionStart entry stays ✓"
  inst status --claude
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "outdated" "status --claude: the ledger set's outdated entry shows too (same settings file)"
  assert_contains "$IOUT" "install --ledger-claude" "…with the command that fixes it"
  inst status --all
  assert_not_contains "$IOUT" "Ledger " "status --all (the three tiers): no ledger set, as before"
  inst install --ledger-claude
  assert_eq "0" "$IRC" "re-run install --ledger-claude: exit 0"
  assert_eq '1|"Write|Edit|MultiEdit"' "$(jq -r "$sel | \"\\(length)|\\(.[0].matcher | tojson)\"" .claude/settings.local.json)" "…one state-watch entry, matcher updated"
  inst status --ledger-claude
  assert_contains "$(grep ' ledger-state-watch ' <<<"$IOUT")" "✓" "…and status reads ✓"
  teardown
}

test_ledger_status_state_watch_paths_without_patterns() {
  # 3.3.1 item 6 (adopter finding): state_watch.patterns defaults to [], so
  # paths alone make a hook that never fires.
  echo "test: ledger: status --ledger-claude with state-watch installed flags state_watch.paths set while state_watch.patterns is empty or absent (the hook never fires); quiet with patterns, and with the set not installed"
  local c
  lgh_fixture '{"state_watch":{"paths":["~/notes"]}}'
  inst status --ledger-claude
  assert_not_contains "$IOUT" "state_watch.patterns" "the set not installed: no warning"
  inst install --ledger-claude
  inst status --ledger-claude
  assert_contains "$IOUT" "⚠ ledger-state-watch never fires" "installed, patterns absent: ⚠ never fires"
  assert_contains "$IOUT" "state_watch.patterns" "…naming state_watch.patterns"
  for c in '{"state_watch":{"paths":["~/notes"],"patterns":[]}}' '{"state_watch":{"paths":["~/notes"],"patterns":[""]}}' \
      '{"state_watch":{"paths":["~/notes"],"patterns":"next:"}}'; do
    printf '%s\n' "$c" > docs/ledger/config.json
    inst status --ledger-claude
    assert_contains "$IOUT" "never fires" "$c: ⚠ never fires"
  done
  for c in '{"state_watch":{"paths":["~/notes"],"patterns":["next:"]}}' '{}' '{"state_watch":{"paths":[],"patterns":[]}}'; do
    printf '%s\n' "$c" > docs/ledger/config.json
    inst status --ledger-claude
    assert_not_contains "$IOUT" "never fires" "$c: no warning"
  done
  teardown
}

test_ledger_status_quiet_without_ledger() {
  # Every 3.3.0 user who never opted in ran plain `status` and read two
  # "⚠ docs/ledger/config.json is missing" lines about legs nobody
  # installed (final review DOCS-I4): with nothing installed and no config,
  # each ledger section is one plain line; the ⚠ stays for an installed leg.
  echo "test: ledger: plain status without docs/ledger/config.json and nothing of the ledger installed — one plain 'not enabled' line per ledger section, no ⚠; an installed leg without the config still gets the ⚠"
  lgh_fixture
  rm -f docs/ledger/config.json
  inst install --git --claude
  inst status
  assert_not_contains "$IOUT" "⚠ docs/ledger/config.json is missing" "no config, nothing installed: no ⚠ about the ledger"
  assert_eq "2" "$(grep -c 'not enabled (no docs/ledger/config.json)' <<<"$IOUT")" "…one plain line in each ledger section"
  assert_not_contains "$(sed -n '/^Ledger git hooks/,/^$/p' <<<"$IOUT")" "✗" "…and no ✗ list of legs nobody asked for"
  printf '{}\n' > docs/ledger/config.json
  inst install --ledger
  rm -f docs/ledger/config.json
  inst status --ledger
  assert_contains "$IOUT" "⚠ docs/ledger/config.json is missing" "a leg installed, the config gone: the ⚠ stays"
  teardown
}

echo ""
echo "=== The ledger hook set (install --ledger) ==="
test_ledger_install_requires_config
test_ledger_status_quiet_without_ledger
test_ledger_all_excludes_ledger
test_ledger_claude_only_no_general_tier
test_ledger_claude_flags_independent
test_ledger_blocks_markers_distinct
test_ledger_install_order_git_then_ledger
test_ledger_install_order_ledger_then_git
test_ledger_uninstall_each_tier_independent
test_ledger_pre_commit_blocks_invalid
test_ledger_pre_push_refuses_provisional_cas
test_ledger_pre_push_refuses_long_provisional_cas
test_ledger_pre_push_allows_provisional_merge_mode
test_ledger_pre_push_stdin_replayed
test_ledger_pre_push_foreign_stdin_intact
test_ledger_pre_push_copy_failure_refuses
test_ledger_git_status_flags_old_pre_push_block
test_ledger_pre_push_delete_replayed
test_ledger_post_commit_backgrounds
test_ledger_post_commit_batch_ssh
test_ledger_session_hook_budget
test_ledger_claude_tracked_note_names_flag
test_ledger_session_hook_wraps_verb
test_ledger_state_watch_advisory
test_ledger_legs_honour_both_skips
test_ledger_foreign_hook_runs_ledger_first
test_ledger_state_watch_paths_spaces_tilde
test_ledger_status_reports_set
test_ledger_state_watch_matcher_multiedit
test_ledger_status_state_watch_paths_without_patterns

# --- doc-search: the launcher and the opt-in --search set ---------------------
#
# scripts/search/launch.sh (POSIX sh) starts the doc-search MCP server through
# uv; install --search copies it to .claude/doc-superpowers/search-mcp.sh and
# registers a "doc-search" server in the project's .mcp.json. Never part of
# --all, refused without docs/search/config.json. No test needs a real uv or
# the real plugin cache: a fake uv prints its arguments, and the plugin cache
# is a directory under the fixture's HOME (or CLAUDE_PLUGIN_CACHE).

SRH_ENTRY='{"command":"sh","args":[".claude/doc-superpowers/search-mcp.sh","serve"]}'
SRH_LAUNCHER=".claude/doc-superpowers/search-mcp.sh"

# srh_fixture [config]: setup, then doc-search enabled — docs/search/config.json
# (default {}) — committed.
srh_fixture() {
  local c='{}'
  if [ $# -gt 0 ]; then c=$1; fi
  setup
  mkdir -p docs/search
  printf '%s\n' "$c" > docs/search/config.json
  git add -A && git commit -qm search
}

# srh_json <jq filter>: a value of the JSON in $IOUT ("" when it is not JSON).
srh_json() {
  jq -r "$1" <<<"$IOUT" 2>/dev/null || true
}

# srh_mode <file>: its octal permission bits.
srh_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# srh_mcp <jq filter>: a value of .mcp.json.
srh_mcp() {
  jq -c "$1" .mcp.json 2>/dev/null || echo "ERR"
}

# A fake uv: prints "uv <its arguments>" and exits 0. SRL_BIN is the directory
# holding it, put in front of the launcher's PATH.
SRL_BIN=$(harness_mktemp_d fakeuv)
printf '#!/bin/sh\nprintf "uv %%s\\n" "$*"\necho "$#" > "$(dirname "$0")/argc"\n' > "$SRL_BIN/uv"
chmod +x "$SRL_BIN/uv"

# srl_root <dir>: <dir> as a doc-superpowers root (a search/pyproject.toml).
srl_root() {
  mkdir -p "$1/search"
  : > "$1/search/pyproject.toml"
}

# srl_run [VAR=value …] -- <launcher args…>: run the launcher (under /bin/sh)
# in the cwd with the fake uv in front. DOC_SUPERPOWERS_ROOT and
# CLAUDE_PLUGIN_CACHE are empty unless given. Sets RUN_RC and RUN_OUT
# (stdout + stderr).
srl_run() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  RUN_RC=0
  RUN_OUT=$(env DOC_SUPERPOWERS_ROOT= CLAUDE_PLUGIN_CACHE= PATH="$SRL_BIN:$REAL_PATH" ${envs[@]+"${envs[@]}"} \
    /bin/sh "$SCRIPT_DIR/search/launch.sh" "$@" 2>&1) || RUN_RC=$?
}

test_launcher_resolution_order() {
  echo "test: launcher: root resolution — DOC_SUPERPOWERS_ROOT, then this repository when it is doc-superpowers, then the newest numeric version in the plugin cache; none: exit 2"
  setup
  local envroot top cache c
  envroot=$(harness_mktemp_d envroot)
  top=$(pwd -P)
  # No root anywhere (an empty plugin cache too).
  srl_run -- serve
  assert_eq "2" "$RUN_RC" "no root: exit 2"
  assert_eq "doc-search: cannot find doc-superpowers (set DOC_SUPERPOWERS_ROOT)" "$RUN_OUT" "…one stderr line, naming the variable"
  # The plugin cache: the newest numeric version dir with search/pyproject.toml.
  cache="$HOME/.claude/plugins/cache"
  for c in mkt/doc-superpowers/9.9.9 mkt/doc-superpowers/10.0.0 mkt/doc-superpowers/10.0.0-rc1 mkt/doc-superpowers/latest other/doc-superpowers/2.0.0; do
    srl_root "$cache/$c"
  done
  mkdir -p "$cache/mkt/doc-superpowers/11.0.0"
  srl_run -- serve
  assert_eq "0" "$RUN_RC" "the plugin cache under HOME: exit 0"
  assert_eq "uv run --project $cache/mkt/doc-superpowers/10.0.0/search --frozen --no-dev doc-search serve" "$RUN_OUT" "…10.0.0 beats 9.9.9 (numeric order), skips a pre-release name, a non-numeric name and 11.0.0 (no search/)"
  srl_root "$cache/mkt/doc-superpowers/11.0.0"
  srl_run -- serve
  assert_contains "$RUN_OUT" "$cache/mkt/doc-superpowers/11.0.0/search" "…once 11.0.0 has search/pyproject.toml it wins"
  # CLAUDE_PLUGIN_CACHE replaces the default location.
  srl_root "$envroot/cache/m/doc-superpowers/3.1.2"
  srl_root "$envroot/cache/m/doc-superpowers/3.10.0"
  srl_run CLAUDE_PLUGIN_CACHE="$envroot/cache" -- serve
  assert_eq "uv run --project $envroot/cache/m/doc-superpowers/3.10.0/search --frozen --no-dev doc-search serve" "$RUN_OUT" "CLAUDE_PLUGIN_CACHE: 3.10.0 beats 3.1.2 (minor, numerically)"
  srl_root "$envroot/cache/n/doc-superpowers/3.10.2"
  srl_root "$envroot/cache/n/doc-superpowers/3.10.10"
  srl_run CLAUDE_PLUGIN_CACHE="$envroot/cache" -- serve
  assert_eq "uv run --project $envroot/cache/n/doc-superpowers/3.10.10/search --frozen --no-dev doc-search serve" "$RUN_OUT" "…3.10.10 beats 3.10.2 (patch, numerically), across marketplaces"
  # This repository, when it is doc-superpowers itself (search/ and scripts/doc-tools.sh).
  srl_root "$top"
  srl_run -- serve
  assert_contains "$RUN_OUT" "$cache/mkt/doc-superpowers/11.0.0/search" "search/ alone is not doc-superpowers: the cache still wins"
  mkdir -p scripts
  : > scripts/doc-tools.sh
  srl_run -- serve
  assert_eq "uv run --project $top/search --frozen --no-dev doc-search serve" "$RUN_OUT" "this repository (search/pyproject.toml and scripts/doc-tools.sh) beats the cache"
  mkdir -p sub
  (cd sub && srl_run -- serve && echo "$RUN_OUT" > "$top/sub.out")
  assert_eq "uv run --project $top/search --frozen --no-dev doc-search serve" "$(cat sub.out)" "…from a subdirectory too (the repository top)"
  rm -f sub.out
  # DOC_SUPERPOWERS_ROOT wins over both, when it holds search/pyproject.toml.
  srl_root "$envroot"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "DOC_SUPERPOWERS_ROOT wins over this repository and the cache"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot/missing" -- serve
  assert_contains "$RUN_OUT" "$top/search" "…but not when it has no search/pyproject.toml (the next rule applies)"
  # The launcher's arguments reach doc-search whole.
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- query "a b" --limit 3
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search query a b --limit 3" "$RUN_OUT" "arguments are passed on after doc-search"
  assert_eq "10" "$(cat "$SRL_BIN/argc")" "…each as one word (\"a b\" is not split)"
  teardown
}

test_launcher_cloud_extra() {
  echo "test: launcher: --extra cloud when docs/search/config.json has a non-null cloud; without jq, --all-extras --no-extra local-transformer; nothing extra otherwise"
  srh_fixture '{"cloud":{"project":"p"}}'
  local envroot nojq
  envroot=$(harness_mktemp_d envroot)
  srl_root "$envroot"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev --extra cloud doc-search serve" "$RUN_OUT" "a cloud object: --extra cloud, between --no-dev and doc-search"
  mkdir -p src/deep
  (cd src/deep && srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve && echo "$RUN_OUT" > "$envroot/deep.out")
  assert_contains "$(cat "$envroot/deep.out")" "--extra cloud" "…read from the repository top, whatever the cwd"
  printf '{"cloud":null}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "cloud null: no extra"
  printf '{}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_not_contains "$RUN_OUT" "extra" "cloud absent: no extra"
  printf '{"cloud":\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "0" "$RUN_RC" "an invalid config: the launcher still starts doc-search (it reports the config itself)"
  assert_not_contains "$RUN_OUT" "extra" "…with no extra"
  rm -f docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "no config: no extra"
  # No jq on PATH: every extra but the transformer's (its onnxruntime has no wheel on older hosts).
  nojq=$(make_nojq_path)
  cp "$SRL_BIN/uv" "$nojq/uv"
  IRC=0
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nojq" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || IRC=$?
  assert_eq "0" "$IRC" "without jq: exit 0"
  assert_eq "uv run --project $envroot/search --frozen --no-dev --all-extras --no-extra local-transformer doc-search serve" "$IOUT" "…no config: --all-extras --no-extra local-transformer"
  printf '{"cloud":{"project":"p"}}\n' > docs/search/config.json
  IRC=0
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nojq" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || IRC=$?
  assert_eq "uv run --project $envroot/search --frozen --no-dev --all-extras --no-extra local-transformer doc-search serve" "$IOUT" "…a cloud config: the cloud extra (in --all-extras), not the transformer's"
  teardown
}

test_launcher_transformer_extra() {
  echo "test: launcher: --extra local-transformer when docs.model starts with transformer:, after --extra cloud when both; nothing extra for another or a non-string model; without jq, --all-extras only when grep finds a transformer: model"
  srh_fixture '{"docs":{"model":"transformer:gte-modernbert-base"}}'
  local envroot nojq
  envroot=$(harness_mktemp_d envroot)
  srl_root "$envroot"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev --extra local-transformer doc-search serve" "$RUN_OUT" "a transformer: docs.model: --extra local-transformer, between --no-dev and doc-search"
  mkdir -p src/deep
  (cd src/deep && srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve && echo "$RUN_OUT" > "$envroot/deep.out")
  assert_contains "$(cat "$envroot/deep.out")" "--extra local-transformer" "…read from the repository top, whatever the cwd"
  printf '{"docs":{"model":"transformer:gte-modernbert-base"},"cloud":{"project":"p"}}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev --extra cloud --extra local-transformer doc-search serve" "$RUN_OUT" "with a cloud object too: --extra cloud, then --extra local-transformer"
  printf '{"docs":{"model":"transformer:gte-modernbert-base"},"cloud":null}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev --extra local-transformer doc-search serve" "$RUN_OUT" "cloud null: the transformer extra alone"
  printf '{"docs":{"model":"minishlab/potion-base-8M"}}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "a model2vec docs.model: no extra"
  printf '{"docs":{"model":7}}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "0" "$RUN_RC" "a non-string docs.model: the launcher still starts doc-search (it reports the config itself)"
  assert_not_contains "$RUN_OUT" "extra" "…with no extra"
  printf '{"docs":"transformer:x"}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "0" "$RUN_RC" "a docs that is not an object: exit 0"
  assert_not_contains "$RUN_OUT" "extra" "…with no extra"
  printf '{"docs":{"model":null},"code":{"model":"transformer:gte-modernbert-base"}}\n' > docs/search/config.json
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_not_contains "$RUN_OUT" "extra" "a transformer: only under code.model (which refuses it): no extra"
  # No jq on PATH: grep looks for a "model" key whose value starts transformer:.
  nojq=$(make_nojq_path)
  cp "$SRL_BIN/uv" "$nojq/uv"
  printf '{\n  "docs": {\n    "model": "transformer:gte-modernbert-base"\n  }\n}\n' > docs/search/config.json
  IRC=0
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nojq" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || IRC=$?
  assert_eq "0" "$IRC" "without jq, a transformer docs.model: exit 0"
  assert_eq "uv run --project $envroot/search --frozen --no-dev --all-extras doc-search serve" "$IOUT" "…--all-extras (the transformer's extra included)"
  printf '{"docs":{"model" : "transformer:gte-modernbert-base"},"cloud":{"project":"p"}}\n' > docs/search/config.json
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nojq" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || true
  assert_eq "uv run --project $envroot/search --frozen --no-dev --all-extras doc-search serve" "$IOUT" "…on one line, spaced around the colon, beside a cloud object"
  printf '{"docs":{"model":"minishlab/potion-base-8M"}}\n' > docs/search/config.json
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nojq" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || true
  assert_eq "uv run --project $envroot/search --frozen --no-dev --all-extras --no-extra local-transformer doc-search serve" "$IOUT" "…a static docs.model: every extra but the transformer's"
  teardown
}

test_launcher_without_uv() {
  echo "test: launcher: no uv on PATH — one stderr line, exit 2"
  setup
  local envroot nouv
  envroot=$(harness_mktemp_d envroot)
  srl_root "$envroot"
  nouv=$(make_nojq_path)
  IRC=0
  IOUT=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$nouv" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>&1) || IRC=$?
  assert_eq "2" "$IRC" "exit 2"
  assert_eq "doc-search: uv not found (https://docs.astral.sh/uv/)" "$IOUT" "…the message, naming where to get uv"
  teardown
}

test_launcher_is_posix_sh() {
  echo "test: launcher: a POSIX sh script — #!/bin/sh, no bashism; runs under every sh on this host"
  assert_eq "#!/bin/sh" "$(sed -n 1p "$SCRIPT_DIR/search/launch.sh")" "the shebang is /bin/sh"
  assert_true "it holds no bash-only construct ([[, arrays, \${//}, <<<, \$'…')" \
    test -z "$(grep -nE '\[\[|<<<|\$'"'"'|\$\{[A-Za-z_]+(//|,,|\^\^|/)|^[[:space:]]*(declare|local -a|mapfile|readarray)[[:space:]]' "$SCRIPT_DIR/search/launch.sh" || true)"
  local sh
  for sh in /bin/sh dash bash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    assert_true "$sh -n parses it" "$sh" -n "$SCRIPT_DIR/search/launch.sh"
  done
}

test_launcher_env_hook() {
  echo "test: launcher: the per-user env hook — \$DOC_SEARCH_ENV_FILE, else \$XDG_CONFIG_HOME/doc-search/env.sh, sourced at every launch before the root is resolved; absent: nothing; unparseable: skipped with one stderr line"
  setup
  local envroot other hookdir bin out
  envroot=$(harness_mktemp_d envroot)
  other=$(harness_mktemp_d other)
  srl_root "$envroot"
  srl_root "$other"
  hookdir="$XDG_CONFIG_HOME/doc-search"
  # No hook anywhere: the launch is unchanged.
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "no hook: unchanged"
  # The default location: it runs before the root is resolved, so what it sets is used.
  mkdir -p "$hookdir"
  printf 'DOC_SUPERPOWERS_ROOT=%s\n' "$other" > "$hookdir/env.sh"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "0" "$RUN_RC" "the default hook: exit 0"
  assert_eq "uv run --project $other/search --frozen --no-dev doc-search serve" "$RUN_OUT" "…\$XDG_CONFIG_HOME/doc-search/env.sh is sourced before the root is resolved"
  srl_run XDG_CONFIG_HOME= DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "…an empty XDG_CONFIG_HOME means \$HOME/.config, where there is none"
  mkdir -p "$HOME/.config/doc-search"
  cp "$hookdir/env.sh" "$HOME/.config/doc-search/env.sh"
  srl_run XDG_CONFIG_HOME= DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_contains "$RUN_OUT" "$other/search" "…and \$HOME/.config/doc-search/env.sh is read then"
  rm -rf "$HOME/.config"
  # DOC_SEARCH_ENV_FILE replaces the default; empty is unset; a missing file is skipped.
  printf 'DOC_SUPERPOWERS_ROOT=%s\n' "$envroot" > "$other/hook.sh"
  srl_run DOC_SEARCH_ENV_FILE="$other/hook.sh" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "DOC_SEARCH_ENV_FILE names the hook (the default one is not read)"
  srl_run DOC_SEARCH_ENV_FILE= -- serve
  assert_contains "$RUN_OUT" "$other/search" "an empty DOC_SEARCH_ENV_FILE is unset: the default hook"
  srl_run DOC_SEARCH_ENV_FILE="$other/missing.sh" DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "a missing DOC_SEARCH_ENV_FILE: skipped, no message"
  (cd "$other" && srl_run DOC_SEARCH_ENV_FILE=hook.sh -- serve && echo "$RUN_OUT" > "$other/bare.out")
  assert_eq "uv run --project $envroot/search --frozen --no-dev doc-search serve" "$(cat "$other/bare.out")" "a bare file name is the one in the cwd (not searched for on PATH)"
  # What it exports reaches doc-search; it is decided at each launch (a marker here).
  bin=$(harness_mktemp_d envuv)
  printf '#!/bin/sh\nprintf "cache=%%s\\n" "${SEMBLE_CACHE_LOCATION:-unset}"\n' > "$bin/uv"
  chmod +x "$bin/uv"
  printf 'if [ -e "%s/ready" ]; then export SEMBLE_CACHE_LOCATION=%s/semble; fi\n' "$other" "$other" > "$hookdir/env.sh"
  srl_run SEMBLE_CACHE_LOCATION= DOC_SUPERPOWERS_ROOT="$envroot" PATH="$bin:$REAL_PATH" -- serve
  assert_eq "cache=unset" "$RUN_OUT" "an export the hook skips: doc-search keeps its default"
  : > "$other/ready"
  srl_run SEMBLE_CACHE_LOCATION= DOC_SUPERPOWERS_ROOT="$envroot" PATH="$bin:$REAL_PATH" -- serve
  assert_eq "cache=$other/semble" "$RUN_OUT" "…the next launch reads the hook again and exports it"
  # Its output never reaches stdout (the MCP stream).
  printf 'echo hook-says-hi\nexport SEMBLE_CACHE_LOCATION=/x\n' > "$hookdir/env.sh"
  out=$(env DOC_SUPERPOWERS_ROOT="$envroot" CLAUDE_PLUGIN_CACHE= PATH="$bin:$REAL_PATH" /bin/sh "$SCRIPT_DIR/search/launch.sh" serve 2>/dev/null)
  assert_eq "cache=/x" "$out" "the hook's output goes to stderr, not stdout"
  # A hook that does not parse: skipped, one stderr line, doc-search still starts.
  printf 'if then fi\nDOC_SUPERPOWERS_ROOT=%s\n' "$other" > "$hookdir/env.sh"
  srl_run DOC_SUPERPOWERS_ROOT="$envroot" -- serve
  assert_eq "0" "$RUN_RC" "an unparseable hook: exit 0"
  assert_eq "doc-search: ignoring the env hook $hookdir/env.sh (it does not parse)
uv run --project $envroot/search --frozen --no-dev doc-search serve" "$RUN_OUT" "…one stderr line naming it, and nothing of it is applied"
  teardown
}

test_search_install_refused_without_config() {
  echo "test: search: install --search refuses without docs/search/config.json (exit 1, the message, nothing written, with any other tier too); uninstall does not need it"
  setup
  local before want
  want="ERROR: install --search needs docs/search/config.json, which this repository does not have: doc-search is not enabled here (doc-search init sets it up). Nothing was changed."
  before=$(_tree_state)
  inst install --search
  assert_eq "1" "$IRC" "install --search without the config: exit 1"
  assert_eq "$want" "$IOUT" "…the message, whole"
  inst install --git --claude --search
  assert_eq "1" "$IRC" "install --git --claude --search without it: exit 1 too"
  assert_eq "$before" "$(_tree_state)" "…and no tier wrote anything"
  mkdir -p docs/ledger
  printf '{}\n' > docs/ledger/config.json
  before=$(_tree_state)
  inst install --ledger --search
  assert_eq "1" "$IRC" "install --ledger --search, the ledger enabled, doc-search not: exit 1"
  assert_eq "$before" "$(_tree_state)" "…the ledger block is not written either (every check runs first)"
  inst uninstall --search
  assert_eq "0" "$IRC" "uninstall --search without the config: exit 0"
  teardown
}

test_search_install_writes_launcher_and_entry() {
  echo "test: search: install --search copies the launcher (755, byte for byte) and sets the doc-search entry in .mcp.json — created when absent, merged per key when present"
  srh_fixture
  inst install --search
  assert_eq "0" "$IRC" "install --search (no .mcp.json): exit 0"
  assert_true "the launcher is the plugin's scripts/search/launch.sh, byte for byte" cmp -s "$SRH_LAUNCHER" "$SCRIPT_DIR/search/launch.sh"
  assert_true "…executable" test -x "$SRH_LAUNCHER"
  assert_eq "755" "$(srh_mode "$SRH_LAUNCHER")" "…mode 755"
  assert_eq "{\"mcpServers\":{\"doc-search\":$SRH_ENTRY}}" "$(srh_mcp .)" ".mcp.json is created with the one entry"
  assert_eq "?? .claude/doc-superpowers/search-mcp.sh
?? .mcp.json" "$(git status --porcelain -uall)" "…and those two files are all it wrote"
  assert_not_contains "$(cat "$SRH_LAUNCHER")" "$TEST_DIR" "the committed copy holds no machine path"
  assert_not_contains "$(cat "$SRH_LAUNCHER")" "$HOME" "…nor the home directory"
  # Another server and other keys survive, in their order.
  inst uninstall --search
  printf '%s\n' '{"mcpServers":{"other":{"command":"x","args":["a","b"],"env":{"K":"v"}}},"extra":[1,{"y":null}]}' | jq . > .mcp.json
  inst install --search
  assert_eq "0" "$IRC" "install --search into an existing .mcp.json: exit 0"
  assert_eq '{"command":"x","args":["a","b"],"env":{"K":"v"}}' "$(srh_mcp '.mcpServers.other')" "another server is untouched"
  assert_eq '[1,{"y":null}]' "$(srh_mcp .extra)" "…and so is another top-level key"
  assert_eq "$SRH_ENTRY" "$(srh_mcp '.mcpServers["doc-search"]')" "the entry is set"
  assert_eq '["other","doc-search"]' "$(srh_mcp '.mcpServers | keys_unsorted')" "…after the existing server"
  # An existing doc-search entry (another command) is replaced in place.
  jq '.mcpServers["doc-search"] = {"command":"uvx","args":["x"]} | .mcpServers.z = {"command":"z"}' .mcp.json > .mcp.tmp && mv .mcp.tmp .mcp.json
  inst install --search
  assert_eq "$SRH_ENTRY" "$(srh_mcp '.mcpServers["doc-search"]')" "a doc-search entry with another command: replaced"
  assert_eq '["other","doc-search","z"]' "$(srh_mcp '.mcpServers | keys_unsorted')" "…in its place, the others kept"
  # An mcpServers that is null counts as absent; an outdated launcher is restored.
  printf '{"mcpServers":null,"k":1}\n' > .mcp.json
  echo "# edited" >> "$SRH_LAUNCHER"
  inst install --search
  assert_eq "0" "$IRC" "mcpServers null: exit 0"
  assert_eq "{\"mcpServers\":{\"doc-search\":$SRH_ENTRY},\"k\":1}" "$(srh_mcp .)" "…treated as {}"
  assert_true "an edited launcher is restored" cmp -s "$SRH_LAUNCHER" "$SCRIPT_DIR/search/launch.sh"
  teardown
}

test_search_install_idempotent() {
  echo "test: search: install --search twice changes nothing (byte for byte, mtimes too); an entry already right leaves a hand-formatted .mcp.json alone"
  srh_fixture
  local a b m1 m2
  inst install --search
  a=$(_tree_state)
  m1=$(stat -c %Y .mcp.json 2>/dev/null || stat -f %m .mcp.json)
  sleep 1
  inst install --search
  assert_eq "0" "$IRC" "second install: exit 0"
  b=$(_tree_state)
  m2=$(stat -c %Y .mcp.json 2>/dev/null || stat -f %m .mcp.json)
  assert_eq "$a" "$b" "the tree is byte for byte the same"
  assert_eq "$m1" "$m2" "….mcp.json was not even rewritten"
  inst uninstall --search
  printf '{ "mcpServers": { "doc-search": {"args": [".claude/doc-superpowers/search-mcp.sh", "serve"], "command": "sh"},\n   "o": {"command":"o"} }\n}\n' > .mcp.json
  a=$(cksum < .mcp.json)
  inst install --search
  assert_eq "$a" "$(cksum < .mcp.json)" "a hand-formatted .mcp.json whose entry is already right: untouched"
  inst install --search
  assert_eq "$a" "$(cksum < .mcp.json)" "…every time"
  teardown
}

test_search_install_refuses_non_object_mcp_json() {
  echo "test: search: a .mcp.json that is not one JSON object (or whose mcpServers is not an object) is refused, exit 1, nothing changed — install and uninstall alike"
  srh_fixture
  local before c
  for c in '[]' '"x"' 'null' '3' '{} {}' 'not json' '' '{"mcpServers":[]}' '{"mcpServers":"x"}'; do
    printf '%s' "$c" > .mcp.json
    before=$(_tree_state)
    inst install --search
    assert_eq "1" "$IRC" "install --search, .mcp.json '$c': exit 1"
    assert_contains "$IOUT" ".mcp.json" "…naming .mcp.json"
    assert_contains "$IOUT" "Nothing was changed" "…and saying nothing was"
    assert_eq "$before" "$(_tree_state)" "…the launcher not written either"
    inst uninstall --search
    assert_eq "1" "$IRC" "uninstall --search, .mcp.json '$c': exit 1"
    assert_eq "$before" "$(_tree_state)" "…nothing changed"
  done
  rm -f .mcp.json
  mkdir .mcp.json
  inst install --search
  assert_eq "1" "$IRC" ".mcp.json a directory: exit 1"
  rmdir .mcp.json
  ln -s elsewhere.json .mcp.json
  inst install --search
  assert_eq "1" "$IRC" ".mcp.json a symbolic link: exit 1"
  assert_contains "$IOUT" "symbolic link" "…the installer never writes through one"
  assert_file_not_exists "$SRH_LAUNCHER" "…nothing written"
  teardown
}

test_search_needs_jq() {
  echo "test: search: without jq on PATH install and uninstall --search stop first (exit 1, naming jq, nothing written, not the launcher alone)"
  srh_fixture
  local before nojq
  nojq=$(make_nojq_path)
  before=$(_tree_state)
  IRC=0
  IOUT=$(PATH="$nojq" "$BASH_BIN" "$HOOKS_DIR/install.sh" install --search 2>&1) || IRC=$?
  assert_eq "1" "$IRC" "install --search without jq: exit 1"
  assert_contains "$IOUT" "jq" "…naming jq"
  assert_contains "$IOUT" "Nothing was changed" "…and saying nothing was"
  assert_eq "$before" "$(_tree_state)" "…no launcher, no .mcp.json"
  IRC=0
  IOUT=$(PATH="$nojq" "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --search 2>&1) || IRC=$?
  assert_eq "1" "$IRC" "uninstall --search without jq: exit 1"
  teardown
}

test_search_never_writes_through_links() {
  echo "test: search: a symbolic link at .claude, .claude/doc-superpowers or the launcher is refused (exit 1, nothing written) — install and uninstall"
  srh_fixture
  local before elsewhere
  elsewhere=$(harness_mktemp_d elsewhere)
  ln -s "$elsewhere" .claude
  before=$(_tree_state)
  inst install --search
  assert_eq "1" "$IRC" ".claude a link: install exit 1"
  assert_contains "$IOUT" "symbolic link" "…named as one"
  assert_eq "$before" "$(_tree_state)" "…nothing written"
  assert_eq "" "$(ls -A "$elsewhere")" "…and nothing through it"
  inst uninstall --search
  assert_eq "1" "$IRC" ".claude a link: uninstall exit 1"
  rm .claude
  mkdir .claude
  ln -s "$elsewhere" .claude/doc-superpowers
  inst install --search
  assert_eq "1" "$IRC" ".claude/doc-superpowers a link: install exit 1"
  assert_eq "" "$(ls -A "$elsewhere")" "…nothing through it"
  rm .claude/doc-superpowers
  mkdir .claude/doc-superpowers
  ln -s "$elsewhere/launcher.sh" "$SRH_LAUNCHER"
  inst install --search
  assert_eq "1" "$IRC" "the launcher a link: install exit 1"
  assert_eq "" "$(ls -A "$elsewhere")" "…nothing through it"
  assert_file_not_exists .mcp.json "…and no .mcp.json written before the refusal"
  teardown
}

test_search_not_in_all() {
  echo "test: search: --all includes the --search set neither way (install --all adds none of it, uninstall --all keeps it, status --all and status --json skip it)"
  srh_fixture
  inst install --all
  assert_eq "0" "$IRC" "install --all: exit 0"
  assert_file_not_exists "$SRH_LAUNCHER" "…no launcher"
  assert_file_not_exists .mcp.json "…no .mcp.json"
  inst install --search
  assert_eq "0" "$IRC" "install --search: exit 0"
  inst uninstall --all
  assert_eq "0" "$IRC" "uninstall --all: exit 0"
  assert_file_exists "$SRH_LAUNCHER" "uninstall --all keeps the launcher"
  assert_eq "$SRH_ENTRY" "$(srh_mcp '.mcpServers["doc-search"]')" "…and the entry"
  inst status --all
  assert_not_contains "$IOUT" "doc-search MCP" "status --all (the three tiers): no search section"
  inst status
  assert_contains "$IOUT" "doc-search MCP (the opt-in --search set):" "plain status: its section, beside the ledger sets"
  inst status --json
  assert_eq "git,claude,ci" "$(srh_json '.tiers | keys_unsorted | join(",")')" "status --json: the three tiers, not the search set"
  inst status --all --json
  assert_eq "null" "$(srh_json '.tiers.search')" "status --all --json: not in it either"
  inst install --all --search
  assert_eq "0" "$IRC" "install --all --search: exit 0 (both)"
  assert_file_exists .git/hooks/pre-commit "…the tiers"
  assert_file_exists "$SRH_LAUNCHER" "…and the set"
  teardown
}

test_search_uninstall_removes_only_ours() {
  echo "test: search: uninstall --search removes the doc-search key and the launcher and nothing else; .mcp.json goes only when it becomes exactly {\"mcpServers\":{}}"
  srh_fixture
  local before
  # Created by the install: gone with it, and the directories it made.
  before=$(_tree_state)
  inst install --search
  inst uninstall --search
  assert_eq "0" "$IRC" "uninstall --search: exit 0"
  assert_eq "$before" "$(_tree_state)" "…the tree as before the install (.mcp.json gone, .claude/ gone)"
  # Another server, another key, a neighbour of the launcher.
  printf '%s\n' '{"mcpServers":{"other":{"command":"x"}},"extra":{"a":[1]}}' | jq . > .mcp.json
  mkdir -p .claude/doc-superpowers
  printf 'advice = off\n' > .claude/doc-superpowers/hooks.conf
  before=$(_tree_state)
  inst install --search
  assert_eq "0" "$IRC" "install --search beside other things: exit 0"
  inst uninstall --search
  assert_eq "0" "$IRC" "uninstall --search: exit 0"
  assert_eq "$before" "$(_tree_state)" "other servers and keys, and hooks.conf beside the launcher, exactly as they were"
  assert_file_exists .claude/doc-superpowers/hooks.conf "…its directory stays while it holds something"
  # An .mcp.json with only an empty mcpServers left: removed; with another key left: kept.
  printf '{"mcpServers":{},"k":1}\n' > .mcp.json
  inst install --search
  inst uninstall --search
  assert_eq '{"mcpServers":{},"k":1}' "$(srh_mcp .)" "an emptied mcpServers with another key: .mcp.json kept"
  printf '{"mcpServers":{}}\n' > .mcp.json
  inst install --search
  inst uninstall --search
  assert_file_not_exists .mcp.json "exactly {\"mcpServers\":{}} afterwards: .mcp.json removed"
  # Uninstalling twice, and with nothing installed.
  inst uninstall --search
  assert_eq "0" "$IRC" "uninstall --search again: exit 0"
  assert_contains "$IOUT" "nothing to uninstall" "…saying so"
  # A doc-search entry of any command goes (the key is the set's); the launcher too.
  printf '{"mcpServers":{"doc-search":{"command":"mine"},"o":{"command":"o"}}}\n' > .mcp.json
  inst uninstall --search
  assert_eq '{"mcpServers":{"o":{"command":"o"}}}' "$(srh_mcp .)" "the doc-search key is removed whatever it ran"
  teardown
}

test_search_status_and_json() {
  echo "test: search: status reports the launcher (installed / outdated / not installed) and the entry (registered / registered with a different command / not registered), as text and as .tiers.search in status --json"
  setup
  inst status --search
  assert_eq "0" "$IRC" "status --search: exit 0"
  assert_contains "$IOUT" "doc-search MCP (the opt-in --search set):" "its header"
  assert_contains "$IOUT" "not enabled (no docs/search/config.json)" "no config, nothing installed: one plain line"
  assert_not_contains "$IOUT" "⚠" "…no warning"
  assert_not_contains "$IOUT" "Git Hooks" "…and no tier"
  teardown
  srh_fixture
  inst status --search
  assert_contains "$IOUT" "launcher: not installed" "config, nothing installed: the launcher"
  assert_contains "$IOUT" "entry: not registered" "…and the entry"
  inst status --search --json
  assert_eq "search" "$(srh_json '.tiers | keys | join(",")')" "status --search --json: the search member alone"
  assert_eq "absent" "$(srh_json .tiers.search.launcher)" "…launcher absent"
  assert_eq "absent" "$(srh_json .tiers.search.mcp_entry)" "…mcp_entry absent"
  assert_eq "doc-superpowers-hooks-status/1" "$(srh_json .schema)" "…the schema unchanged"
  inst install --search
  inst status --search
  assert_contains "$IOUT" "launcher: installed" "installed: the launcher"
  assert_contains "$IOUT" "entry: registered" "…the entry"
  assert_contains "$IOUT" "✓" "…✓"
  assert_not_contains "$IOUT" "⚠" "…no warning"
  inst status --search --json
  assert_eq "installed" "$(srh_json .tiers.search.launcher)" "JSON: launcher installed"
  assert_eq "registered" "$(srh_json .tiers.search.mcp_entry)" "…mcp_entry registered"
  inst status --git --search --json
  assert_eq "git,search" "$(srh_json '.tiers | keys | join(",")')" "--git --search --json: both, nothing else"
  # An outdated launcher.
  echo "# edited" >> "$SRH_LAUNCHER"
  inst status --search
  assert_contains "$IOUT" "launcher: outdated: differs from the plugin's scripts/search/launch.sh" "an edited launcher: outdated, saying against what"
  assert_contains "$IOUT" "install --search" "…and what fixes it"
  inst status --search --json
  assert_eq "outdated" "$(srh_json .tiers.search.launcher)" "JSON: outdated"
  inst install --search
  # A different command, then none.
  jq '.mcpServers["doc-search"].command = "uvx"' .mcp.json > .mcp.tmp && mv .mcp.tmp .mcp.json
  inst status --search
  assert_contains "$IOUT" "entry: registered with a different command" "another command: said so"
  inst status --search --json
  assert_eq "different-command" "$(srh_json .tiers.search.mcp_entry)" "JSON: different-command"
  jq 'del(.mcpServers["doc-search"])' .mcp.json > .mcp.tmp && mv .mcp.tmp .mcp.json
  inst status --search
  assert_contains "$IOUT" "entry: not registered" "the key removed: not registered"
  assert_contains "$IOUT" "launcher: installed" "…the launcher still installed"
  printf '[1]' > .mcp.json
  inst status --search
  assert_eq "0" "$IRC" "an .mcp.json that is not an object: status still exits 0"
  assert_contains "$IOUT" "entry: not registered" "…and reads the entry as not registered"
  inst status --search --json
  assert_eq "absent" "$(srh_json .tiers.search.mcp_entry)" "JSON: absent"
  # Installed, but the config gone.
  rm -f .mcp.json
  inst install --search
  rm -f docs/search/config.json
  inst status --search
  assert_contains "$IOUT" "⚠ docs/search/config.json is missing" "installed without the config: ⚠ (the server answers 'not enabled')"
  inst status --search --json
  assert_eq "installed" "$(srh_json .tiers.search.launcher)" "…and JSON still reports the files"
  inst install --search --json
  assert_eq "2" "$IRC" "install --search --json: exit 2 (--json is status's)"
  teardown
}

echo ""
echo "=== doc-search: the launcher and the opt-in --search set ==="
test_launcher_resolution_order
test_launcher_cloud_extra
test_launcher_transformer_extra
test_launcher_without_uv
test_launcher_is_posix_sh
test_launcher_env_hook
test_search_install_refused_without_config
test_search_install_writes_launcher_and_entry
test_search_install_idempotent
test_search_install_refuses_non_object_mcp_json
test_search_needs_jq
test_search_never_writes_through_links
test_search_not_in_all
test_search_uninstall_removes_only_ours
test_search_status_and_json

# --- Maintainer tooling (#27): scripts/check-ci.sh and the opt-in pre-push ---
#
# Both are for this repository's contributors, not shipped to a consuming
# project. Each runs from a fixture's scripts/ (they resolve the checkout from
# their own location), against stub suites / a stub check-ci.sh that log what
# they were run with.

MT_BEGIN="# doc-superpowers-maintainer:begin"

# mt_fixture: a repo with origin (a bare remote holding main), the maintainer
# hook installer, and a stub check-ci.sh: it logs its arguments and whether
# its stdin had a line to .git/check-ci.log, and exits $STUB_RC (default 0).
mt_fixture() {
  setup
  mkdir -p scripts
  cp "$SCRIPT_DIR/install-maintainer-hooks.sh" scripts/
  # shellcheck disable=SC2016  # the stub's own code
  printf '%s\n' '#!/bin/sh' \
    'log="$(git rev-parse --show-toplevel)/.git/check-ci.log"' \
    'echo "check-ci $*" >> "$log"' \
    'if IFS= read -r l; then echo "stdin: $l" >> "$log"; fi' \
    'exit "${STUB_RC:-0}"' > scripts/check-ci.sh
  printf 'scripts/\n' >> .git/info/exclude
  MT_REMOTE=$(harness_mktemp_d mt-remote)
  git init -q --bare "$MT_REMOTE"
  git remote add origin "$MT_REMOTE"
  git push -q origin main 2>/dev/null
}

# mt_inst <command>: the maintainer installer; sets MT_RC and MT_OUT.
mt_inst() {
  MT_RC=0
  MT_OUT=$(PATH="$REAL_PATH" "$BASH_BIN" scripts/install-maintainer-hooks.sh "$@" 2>&1) || MT_RC=$?
}

# mt_push [VAR=value…]: commit, then push main as a user would (git runs the
# hook); sets MT_RC and MT_OUT.
mt_push() {
  echo "$RANDOM" >> src/index.js
  git commit -qam "change"
  MT_RC=0
  MT_OUT=$(env PATH="$REAL_PATH" "$@" git push origin main 2>&1) || MT_RC=$?
}

test_maintainer_hook_install_push_uninstall() {
  echo "test: maintainer pre-push: install writes a hook that runs check-ci.sh --fast (stdin /dev/null) and refuses the push when it fails; DOC_SP_SKIP_CHECK_CI=1 skips it; re-install keeps one block; uninstall removes the file it wrote"
  mt_fixture
  mt_inst install
  assert_eq "0" "$MT_RC" "install exits 0"
  assert_true "the hook is executable" test -x .git/hooks/pre-push
  assert_eq "#!/bin/sh" "$(head -n 1 .git/hooks/pre-push)" "…a POSIX sh hook"
  assert_contains "$(cat .git/hooks/pre-push)" "$MT_BEGIN" "…holding the marked block"
  mt_inst status
  assert_contains "$MT_OUT" "maintainer pre-push: installed" "status: installed"
  mt_push
  assert_eq "0" "$MT_RC" "a push with check-ci passing goes through"
  assert_eq "check-ci --fast" "$(cat .git/check-ci.log)" "…having run check-ci.sh --fast, with nothing on its stdin"
  mt_push STUB_RC=1
  assert_eq "1" "$MT_RC" "check-ci failing: the push is refused"
  assert_contains "$MT_OUT" "push refused" "…saying so"
  assert_true "…and nothing reached origin" test "$(git rev-parse HEAD)" != "$(git --git-dir="$MT_REMOTE" rev-parse main)"
  mt_push STUB_RC=1 DOC_SP_SKIP_CHECK_CI=1
  assert_eq "0" "$MT_RC" "DOC_SP_SKIP_CHECK_CI=1: the push goes through"
  assert_contains "$MT_OUT" "check-ci skipped (DOC_SP_SKIP_CHECK_CI=1)" "…naming the variable"
  mt_inst install
  assert_eq "1" "$(grep -cF "$MT_BEGIN" .git/hooks/pre-push)" "re-install: one block"
  mt_inst uninstall
  assert_eq "0" "$MT_RC" "uninstall exits 0"
  assert_file_not_exists .git/hooks/pre-push "…and removes the hook it wrote"
  mt_inst status
  assert_contains "$MT_OUT" "not installed" "status: not installed"
  teardown
}

test_maintainer_hook_coexists_with_other_hooks() {
  echo "test: maintainer pre-push: goes after the #! line of a shell hook of yours (which still reads git's ref lines; uninstall restores it byte-for-byte), refuses the git tier's whole-file hook and a non-shell hook (changing nothing), and a later install --git integrates into it: both run, uninstall --git keeps it"
  mt_fixture
  local orig
  orig=$(harness_mktemp mt-orig)
  # shellcheck disable=SC2016  # the hook's own code
  printf '%s\n' '#!/bin/sh' 'while read -r lr lo rr ro; do echo "yours: $lr" >> .git/yours.log; done' 'exit 0' > .git/hooks/pre-push
  chmod 750 .git/hooks/pre-push
  cp -p .git/hooks/pre-push "$orig"
  mt_inst install
  assert_eq "0" "$MT_RC" "a shell hook of yours: install exits 0"
  assert_eq "#!/bin/sh" "$(head -n 1 .git/hooks/pre-push)" "…your #! line stays first"
  assert_contains "$(sed -n 2p .git/hooks/pre-push)" "$MT_BEGIN" "…the block right after it"
  assert_eq "$(ls -l "$orig" | cut -c1-10)" "$(ls -l .git/hooks/pre-push | cut -c1-10)" "…the mode is kept"
  mt_push
  assert_eq "0" "$MT_RC" "the push goes through"
  assert_eq "check-ci --fast" "$(cat .git/check-ci.log)" "…check-ci ran"
  assert_eq "yours: refs/heads/main" "$(cat .git/yours.log)" "…and your hook still read git's ref line"
  mt_inst uninstall
  assert_true "uninstall restores your hook byte-for-byte" cmp -s "$orig" .git/hooks/pre-push

  printf '%s\n' '#!/usr/bin/env python3' 'print("hi")' > .git/hooks/pre-push
  cp -p .git/hooks/pre-push "$orig"
  mt_inst install
  assert_eq "1" "$MT_RC" "a python hook: refused"
  assert_contains "$MT_OUT" "not a shell script" "…saying why"
  assert_true "…and it is unchanged" cmp -s "$orig" .git/hooks/pre-push
  rm -f .git/hooks/pre-push

  install_tiers --git
  assert_contains "$(head -n 5 .git/hooks/pre-push)" "doc-superpowers hook v" "precondition: the git tier's own pre-push"
  cp -p .git/hooks/pre-push "$orig"
  mt_inst install
  assert_eq "1" "$MT_RC" "the git tier's whole-file hook: refused"
  assert_contains "$MT_OUT" "uninstall --git" "…with the order that runs both"
  assert_true "…and it is unchanged" cmp -s "$orig" .git/hooks/pre-push
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git >/dev/null 2>&1

  mt_inst install
  install_tiers --git
  assert_contains "$(cat .git/hooks/pre-push)" "$MT_BEGIN" "install --git after it: the maintainer block is kept"
  assert_contains "$(cat .git/hooks/pre-push)" "# doc-superpowers:begin" "…and the git tier integrated its block"
  assert_true "…the tier's own copy beside it" test -f .git/hooks/.doc-superpowers-pre-push
  : > .git/check-ci.log
  mt_push
  assert_eq "0" "$MT_RC" "the push goes through"
  assert_eq "check-ci --fast" "$(cat .git/check-ci.log)" "…check-ci ran, its stdin still /dev/null"
  PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" uninstall --git >/dev/null 2>&1
  assert_contains "$(cat .git/hooks/pre-push 2>/dev/null)" "$MT_BEGIN" "uninstall --git keeps the maintainer block"
  assert_not_contains "$(cat .git/hooks/pre-push 2>/dev/null)" "# doc-superpowers:begin" "…and removes its own"
  teardown
}

test_maintainer_hook_refuses_global_hooks_path() {
  echo "test: maintainer pre-push: a core.hooksPath from the global config is refused (it would run in every repository)"
  mt_fixture
  local gcfg
  gcfg=$(harness_mktemp mt-gitconfig)
  printf '[core]\n\thooksPath = %s\n' "$TEST_DIR/global-hooks" > "$gcfg"
  MT_RC=0
  MT_OUT=$(GIT_CONFIG_GLOBAL="$gcfg" PATH="$REAL_PATH" "$BASH_BIN" scripts/install-maintainer-hooks.sh install 2>&1) || MT_RC=$?
  assert_eq "1" "$MT_RC" "exit 1"
  assert_contains "$MT_OUT" "global git config" "…naming the scope"
  assert_true "…and nothing is written there" test ! -e "$TEST_DIR/global-hooks/pre-push"
  teardown
}

# ci_fixture: scripts/check-ci.sh with stub suites, check-self-install.sh,
# doc-tools.sh and claude: each logs "<name> <args> BASH_BIN=… NODE=… YAML=…
# SHELLCHECK=…" to $CI_LOG and exits $STUB_RC_<name> (default 0); a suite
# prints a harness result line.
ci_fixture() {
  setup
  mkdir -p scripts stubbin
  cp "$SCRIPT_DIR/check-ci.sh" scripts/
  CI_LOG="$TEST_DIR/ci.log"
  : > "$CI_LOG"
  local s
  for s in doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims ledger; do
    # shellcheck disable=SC2016  # the stub's own code
    printf '%s\n' '#!/bin/sh' \
      "n=$s" 'v=$(echo "$n" | tr - _)' \
      'echo "$n BASH_BIN=$BASH_BIN NODE=$DOC_SP_REQUIRE_NODE YAML=$DOC_SP_REQUIRE_YAML_PARSER SHELLCHECK=$DOC_SP_REQUIRE_SHELLCHECK" >> "'"$CI_LOG"'"' \
      'eval "rc=\${STUB_RC_$v:-0}"' \
      '[ "$rc" = 0 ] || echo "  FAIL: stub $n failed on purpose"' \
      'echo "Results: 3 passed, $rc failed, 3 total"' 'exit "$rc"' > "scripts/test-$s.sh"
  done
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "self-install BASH_BIN=$BASH_BIN" >> "'"$CI_LOG"'"' 'exit "${STUB_RC_self_install:-0}"' > scripts/check-self-install.sh
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "doc-tools.sh $*" >> "'"$CI_LOG"'"' 'exit 0' > scripts/doc-tools.sh
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "claude $*" >> "'"$CI_LOG"'"' 'exit 0' > stubbin/claude
  chmod +x stubbin/claude
  # uv, in a directory of its own so a run can leave it off PATH. A pytest run
  # logs its arguments and where it ran (the project's pytest.ini_options are
  # found from the cwd), prints pytest's closing line, and exits $STUB_RC_search.
  mkdir -p uvbin search
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "uv $* PWD=$PWD UV=$DOC_SP_REQUIRE_UV" >> "'"$CI_LOG"'"' \
    '[ "${STUB_RC_search:-0}" = 0 ] || echo "FAILED tests/test_stub.py::test_on_purpose"' \
    'echo "3 passed in 0.12s"' 'exit "${STUB_RC_search:-0}"' > uvbin/uv
  chmod +x uvbin/uv
}

# path_without <tool>: $REAL_PATH with <tool> hidden. Every directory holding it
# is replaced by a directory of symlinks to everything else in it.
path_without() {
  local tool="$1" shadow out="" d f n=0
  shadow=$(harness_mktemp_d no-"$tool")
  local IFS=:
  for d in $REAL_PATH; do
    if [ -x "$d/$tool" ]; then
      n=$((n + 1))
      mkdir -p "$shadow/$n"
      for f in "$d"/*; do
        [ "${f##*/}" = "$tool" ] || ln -s "$f" "$shadow/$n/" 2>/dev/null || true
      done
      d="$shadow/$n"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# ci_run [VAR=value…] -- <args…>: check-ci.sh; sets CI_RC and CI_OUT.
ci_run() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  CI_RC=0
  CI_OUT=$(cd "$SUITE_TMP" && env PATH="$TEST_DIR/stubbin:$TEST_DIR/uvbin:$REAL_PATH" ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$TEST_DIR/scripts/check-ci.sh" "$@" 2>&1) || CI_RC=$?
}

test_check_ci_runs_what_ci_runs() {
  echo "test: check-ci.sh: each suite under each --bash with BASH_BIN and the three DOC_SP_REQUIRE_* flags at 1 (unless exported 0), a summary line per run, exit 1 naming a failed suite; usage errors exit 2"
  ci_fixture
  local b2
  b2=$(harness_mktemp_d ci-bash2)/bash
  ln -s "$(type -P "$BASH_BIN" || printf '%s' "$BASH_BIN")" "$b2"
  ci_run -- --list
  assert_eq "0" "$CI_RC" "--list exits 0"
  assert_eq "toolchain doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims ledger search self-install check-version tag plugin-validate" \
    "$(printf '%s' "$CI_OUT" | tr '\n' ' ' | sed 's/ $//')" "…the checks: the seven suites among them, then search (the doc-search pytest suite)"
  ci_run -- nope
  assert_eq "2" "$CI_RC" "an unknown check: exit 2"
  ci_run -- --nope
  assert_eq "2" "$CI_RC" "an unknown option: exit 2"
  ci_run -- --bash "$TEST_DIR/no-such-bash" merge-driver
  assert_eq "2" "$CI_RC" "--bash naming no bash: exit 2"
  ci_run -- --bash bash merge-driver
  assert_eq "0" "$CI_RC" "--bash bash (a bare name, as tests.yml's ubuntu leg passes it): exit 0"
  assert_eq "merge-driver BASH_BIN=$_REAL_BIN/bash" "$(cut -d' ' -f1-2 "$CI_LOG")" "…looked up on PATH"
  : > "$CI_LOG"

  ci_run -- --bash "$BASH_BIN" --bash "$b2" merge-driver hooks
  assert_eq "0" "$CI_RC" "two suites under two interpreters: exit 0"
  assert_eq "merge-driver BASH_BIN=$BASH_BIN NODE=1 YAML=1 SHELLCHECK=1
merge-driver BASH_BIN=$b2 NODE=1 YAML=1 SHELLCHECK=1
hooks BASH_BIN=$BASH_BIN NODE=1 YAML=1 SHELLCHECK=1
hooks BASH_BIN=$b2 NODE=1 YAML=1 SHELLCHECK=1" "$(cat "$CI_LOG")" \
    "…each suite under each interpreter, BASH_BIN set, the tools required as in CI"
  assert_contains "$CI_OUT" "PASS  test-hooks.sh  [$b2]  Results: 3 passed, 0 failed, 3 total" "…a summary line per run, with its result line"

  : > "$CI_LOG"
  ci_run DOC_SP_REQUIRE_NODE=0 STUB_RC_merge_driver=1 -- --bash "$BASH_BIN" merge-driver hooks
  assert_eq "1" "$CI_RC" "a failing suite: exit 1"
  assert_contains "$CI_OUT" "FAIL  test-merge-driver.sh  [$BASH_BIN]" "…naming it in the summary"
  assert_contains "$CI_OUT" "FAIL: stub merge-driver failed on purpose" "…with its FAIL lines"
  assert_contains "$CI_OUT" "PASS  test-hooks.sh" "…and the next suite still ran"
  assert_contains "$(cat "$CI_LOG")" "NODE=0" "an exported DOC_SP_REQUIRE_NODE=0 is kept (a local SKIP accepted)"

  : > "$CI_LOG"
  ci_run -- --bash "$BASH_BIN" --verbose spec-status-model
  assert_contains "$CI_OUT" "Results: 3 passed, 0 failed, 3 total" "--verbose streams the suite's output"
  teardown
}

test_check_ci_modes() {
  echo "test: check-ci.sh: --fast runs one interpreter, the quick suites, self-install and check-version; the default run is everything, the tag with --warn; a named tag is strict; plugin-validate runs claude plugin validate ."
  ci_fixture
  ci_run -- --fast
  assert_eq "0" "$CI_RC" "--fast exits 0"
  assert_eq "spec-status-model doc-pr-release merge-driver self-install doc-tools.sh" \
    "$(awk '{ print $1 }' "$CI_LOG" | tr '\n' ' ' | sed 's/ $//')" "…the quick suites, then self-install and check-version, each once (one interpreter); no search (pytest)"
  if [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" = 3 ]; then
    assert_contains "$(head -n 1 "$CI_LOG")" "BASH_BIN=/bin/bash" "…that interpreter: bash 3.2, the floor, when the host has it"
  fi

  : > "$CI_LOG"
  ci_run -- --bash "$BASH_BIN"
  assert_eq "doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims ledger uv self-install doc-tools.sh doc-tools.sh claude" \
    "$(awk '{ print $1 }' "$CI_LOG" | tr '\n' ' ' | sed 's/ $//')" "the default run: the seven suites, search (pytest), self-install, check-version, the tag, plugin-validate"
  assert_contains "$(cat "$CI_LOG")" "doc-tools.sh check-version --tag --warn" "…the tag as a warning (CI checks it on main only)"
  assert_contains "$(cat "$CI_LOG")" "claude plugin validate ." "…and claude plugin validate ."
  # (PASS or FAIL: whether this host has every tool is not this test's business)
  assert_true "…after the toolchain check" grep -qE '^(PASS|FAIL)  toolchain' <<<"$CI_OUT"

  : > "$CI_LOG"
  ci_run -- tag
  assert_eq "doc-tools.sh check-version --tag" "$(cat "$CI_LOG")" "a named tag check: strict, as CI on main"
  : > "$CI_LOG"
  ci_run STUB_RC_self_install=1 -- self-install check-version
  assert_eq "1" "$CI_RC" "a failing self-install: exit 1"
  assert_contains "$CI_OUT" "FAIL  self-install" "…named in the summary"
  assert_contains "$(cat "$CI_LOG")" "doc-tools.sh check-version" "…and check-version still ran"
  teardown
}

test_check_ci_search() {
  echo "test: check-ci.sh search: the doc-search pytest suite runs once, from search/, through uv; a missing uv FAILs unless DOC_SP_REQUIRE_UV=0 (a loud SKIP); a failing run exits 1"
  ci_fixture
  local b2 nouv
  b2=$(harness_mktemp_d ci-bash2)/bash
  ln -s "$(type -P "$BASH_BIN" || printf '%s' "$BASH_BIN")" "$b2"
  nouv=$(path_without uv)

  ci_run -- --bash "$BASH_BIN" --bash "$b2" search
  assert_eq "0" "$CI_RC" "search under two interpreters: exit 0"
  assert_eq "uv run --project $TEST_DIR/search --frozen --all-extras pytest -q PWD=$TEST_DIR/search UV=1" "$(cat "$CI_LOG")" \
    "…uv run on the search project, once (not per interpreter), from search/, DOC_SP_REQUIRE_UV at 1"
  assert_contains "$CI_OUT" "PASS  search (pytest)  3 passed in 0.12s" "…a PASS summary line carrying pytest's own closing line"

  : > "$CI_LOG"
  ci_run -- --bash "$BASH_BIN" --verbose search
  assert_contains "$CI_OUT" "3 passed in 0.12s" "--verbose streams pytest's output"

  : > "$CI_LOG"
  ci_run STUB_RC_search=1 -- --bash "$BASH_BIN" search
  assert_eq "1" "$CI_RC" "a failing pytest run: exit 1"
  assert_contains "$CI_OUT" "FAIL  search (pytest)" "…named in the summary"
  assert_contains "$CI_OUT" "FAILED tests/test_stub.py::test_on_purpose" "…with the failures shown (not just the log's path)"

  : > "$CI_LOG"
  ci_run PATH="$TEST_DIR/stubbin:$nouv" -- --bash "$BASH_BIN" search
  assert_eq "1" "$CI_RC" "no uv on PATH: exit 1 (DOC_SP_REQUIRE_UV defaults to 1)"
  assert_contains "$CI_OUT" "uv not found" "…saying so"
  assert_contains "$CI_OUT" "FAIL  search (pytest)" "…a FAIL summary line"
  assert_eq "" "$(cat "$CI_LOG")" "…and nothing ran"

  ci_run DOC_SP_REQUIRE_UV=0 PATH="$TEST_DIR/stubbin:$nouv" -- --bash "$BASH_BIN" search
  assert_eq "0" "$CI_RC" "no uv, DOC_SP_REQUIRE_UV=0: exit 0"
  assert_contains "$CI_OUT" "SKIP: uv not on PATH" "…a loud SKIP"
  assert_contains "$CI_OUT" "SKIP  search (pytest)" "…a SKIP summary line"
  assert_eq "" "$(cat "$CI_LOG")" "…and nothing ran"

  ci_run DOC_SP_REQUIRE_UV=0 -- --bash "$BASH_BIN" search
  assert_contains "$CI_OUT" "PASS  search (pytest)" "DOC_SP_REQUIRE_UV=0 with uv present: the suite runs"
  assert_contains "$(cat "$CI_LOG")" "UV=0" "…the exported 0 is kept"
  teardown
}

echo ""
echo "=== Maintainer tooling: check-ci.sh and the maintainer pre-push hook ==="
test_maintainer_hook_install_push_uninstall
test_maintainer_hook_coexists_with_other_hooks
test_maintainer_hook_refuses_global_hooks_path
test_check_ci_runs_what_ci_runs
test_check_ci_modes
test_check_ci_search


# --- install --git --merge-driver-only, status --json, print-merge-driver (#20) ---

# The hooks in .git/hooks that are not git's samples, one per line.
real_hooks() {
  find .git/hooks -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | LC_ALL=C sort
}

test_driver_only_install_uninstall() {
  echo "test: #20 install --git --merge-driver-only registers the driver and the .gitattributes block, no hook; uninstall removes only those"
  setup
  # A hook of the user's, which neither command may touch.
  printf '#!/bin/sh\necho mine\nexit 0\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  local before
  before=$(cksum < .git/hooks/pre-commit)
  inst install --git --merge-driver-only
  assert_eq "0" "$IRC" "install --git --merge-driver-only: exit 0"
  assert_contains "$IOUT" "none touched (--merge-driver-only)" "…says no hook was touched"
  assert_eq ".git/hooks/pre-commit" "$(real_hooks)" "…no hook written (the user's alone is there)"
  assert_eq "$before" "$(cksum < .git/hooks/pre-commit)" "…the user's hook byte-for-byte"
  assert_file_not_exists ".git/hooks/.doc-superpowers-pre-commit" "…no local copy"
  inst print-merge-driver
  assert_eq "0" "$IRC" "print-merge-driver: exit 0"
  assert_eq "$IOUT" "$(git config --local --get merge.doc-index.driver)" "the registered driver is the one print-merge-driver prints"
  assert_eq "doc-superpowers index merger" "$(git config --local --get merge.doc-index.name)" "the driver's name is registered"
  assert_eq "docs/.doc-index.json: merge: doc-index" "$(git check-attr merge -- docs/.doc-index.json)" ".gitattributes routes the index to it"
  inst status --git --merge-driver-only
  assert_contains "$IOUT" "✓ merge-driver" "status --git --merge-driver-only: the driver ✓"
  assert_contains "$IOUT" "✓ .gitattributes" "….gitattributes ✓"
  assert_not_contains "$IOUT" "pre-commit" "…no hook line"
  # Next to a full git tier, uninstall --merge-driver-only keeps the hooks.
  rm -f .git/hooks/pre-commit
  inst install --git
  inst uninstall --git --merge-driver-only
  assert_eq "0" "$IRC" "uninstall --git --merge-driver-only: exit 0"
  assert_true "…the driver is unregistered" test -z "$(git config --local --get-regexp '^merge\.doc-index\.' || true)"
  assert_file_not_exists ".gitattributes" "…the .gitattributes it created is gone"
  assert_true "…the hooks stay" grep -q "doc-superpowers hook v" .git/hooks/pre-commit
  inst status --git
  assert_contains "$IOUT" "✓ pre-commit" "…status: the hooks ✓"
  assert_contains "$IOUT" "✗ merge-driver" "…the driver ✗"
  teardown
}

test_driver_only_missing_driver() {
  echo "test: #20 install --git --merge-driver-only with no merge-doc-index.sh beside the skill exits 1, says why, and writes nothing"
  setup
  local root before
  root="$(harness_mktemp_d no-driver)/plugin"
  plugin_copy "$root"
  rm -f "$root/scripts/merge-doc-index.sh"
  before=$(_tree_state)
  inst --from "$root/scripts/hooks/install.sh" install --git --merge-driver-only
  assert_eq "1" "$IRC" "the driver missing: exit 1"
  assert_contains "$IOUT" "merge-doc-index.sh" "…naming the missing script"
  assert_contains "$IOUT" "plugin/scripts/merge-doc-index.sh" "…where it was looked for"
  assert_not_contains "$IOUT" "none touched" "…never the success line"
  assert_eq "$before" "$(_tree_state)" "…nothing written (no git config, no .gitattributes)"
  teardown
}

test_driver_only_flag_rules() {
  echo "test: #20 --merge-driver-only needs the git tier; --json is status's; --json and a ledger set exit 2"
  setup
  inst install --merge-driver-only
  assert_eq "2" "$IRC" "--merge-driver-only without --git: exit 2"
  assert_contains "$IOUT" "add --git" "…naming the fix"
  inst install --claude --merge-driver-only
  assert_eq "2" "$IRC" "--merge-driver-only with --claude alone: exit 2"
  inst install --git --json
  assert_eq "2" "$IRC" "install --json: exit 2"
  inst status --json --ledger
  assert_eq "2" "$IRC" "status --json --ledger: exit 2"
  inst print-merge-driver --git
  assert_eq "2" "$IRC" "print-merge-driver takes no option: exit 2"
  assert_true "nothing was written" test -z "$(real_hooks)$(git config --local --get-regexp '^merge\.doc-index\.' || true)"
  # print-merge-driver needs no repository.
  local out
  out=$(cd "$SUITE_TMP" && PATH="$REAL_PATH" GIT_CEILING_DIRECTORIES="$SUITE_TMP" "$BASH_BIN" "$HOOKS_DIR/install.sh" print-merge-driver 2>&1) || out="FAILED: $out"
  assert_contains "$out" "merge-doc-index.sh" "print-merge-driver outside a repository: the driver command"
  assert_contains "$out" "%O %A %B" "…with git's placeholders"
  teardown
}

test_driver_only_ignores_foreign_hooks_path() {
  echo "test: #20 --merge-driver-only installs no hook, so a global core.hooksPath (which install --git refuses) does not stop it"
  setup
  local gcfg
  gcfg=$(harness_mktemp gitconfig)
  printf '[core]\n\thooksPath = %s/elsewhere\n' "$TEST_DIR" > "$gcfg"
  IRC=0
  IOUT=$(GIT_CONFIG_GLOBAL="$gcfg" PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git 2>&1) || IRC=$?
  assert_eq "1" "$IRC" "install --git: refused (the global hooks path)"
  IRC=0
  IOUT=$(GIT_CONFIG_GLOBAL="$gcfg" PATH="$REAL_PATH" "$BASH_BIN" "$HOOKS_DIR/install.sh" install --git --merge-driver-only 2>&1) || IRC=$?
  assert_eq "0" "$IRC" "install --git --merge-driver-only: exit 0"
  assert_true "…the driver is registered" test -n "$(git config --local --get merge.doc-index.driver)"
  assert_file_not_exists "$TEST_DIR/elsewhere/pre-commit" "…and no hook went to the global hooks path"
  teardown
}

# The value of <jq-path> in $IOUT ("" when it is not JSON).
json_at() {
  jq -r "$1" <<<"$IOUT" 2>/dev/null || true
}

test_status_json_states() {
  echo "test: #20 status --json: one JSON object, every component's state, exit 0; the human status is unchanged"
  hooked_fixture
  inst status --json
  assert_eq "0" "$IRC" "status --json: exit 0"
  assert_eq "true" "$(jq -cs 'length == 1 and (.[0] | type == "object")' <<<"$IOUT" 2>/dev/null)" "…one JSON object on stdout"
  assert_eq "doc-superpowers-hooks-status/1" "$(json_at .schema)" "…its schema"
  assert_eq "installed" "$(json_at '.tiers.git.hooks["pre-commit"].state')" "a hook of ours: installed"
  assert_true "…with its install date" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$(json_at '.tiers.git.hooks["pre-commit"].installed')"
  assert_eq "registered" "$(json_at .tiers.git.merge_driver.state)" "the driver: registered"
  assert_contains "$(json_at .tiers.git.merge_driver.path)" "merge-doc-index.sh" "…with the script a merge runs"
  assert_eq "configured" "$(json_at .tiers.git.gitattributes.state)" ".gitattributes: configured"
  assert_eq "false" "$(json_at .tiers.git.hooks_path_foreign)" "the hooks path is this repository's"
  assert_eq "active" "$(json_at '.tiers.claude.hooks["pre-commit-gate"].state')" "a Claude hook: active"
  assert_eq "PreToolUse" "$(json_at '.tiers.claude.hooks["pre-commit-gate"].event')" "…with its event"
  assert_eq "absent" "$(json_at '.tiers.ci.workflows["doc-freshness-pr"].state')" "a workflow not installed: absent"
  assert_eq "null" "$(json_at '.tiers.ledger // .tiers["ledger-claude"] // null')" "no ledger set in the JSON"
  inst status --git --json
  assert_eq "git" "$(json_at '.tiers | keys | join(",")')" "status --git --json: the git tier alone"
  inst status --git --merge-driver-only --json
  assert_eq "null" "$(json_at '.tiers.git.hooks')" "--merge-driver-only: no hooks object"
  assert_eq "true" "$(json_at '.tiers.git.merge_driver_only')" "…and says so"
  # Every merge-driver state.
  local drv
  drv=$(git config --local --get merge.doc-index.driver)
  git config --local merge.doc-index.driver "$TEST_DIR/src/util.js %O %A %B"
  inst status --git --json
  assert_eq "pinned" "$(json_at .tiers.git.merge_driver.state)" "a pre-3.0 registration whose script exists: pinned"
  assert_eq "$TEST_DIR/src/util.js" "$(json_at .tiers.git.merge_driver.path)" "…with the pinned path"
  git config --local merge.doc-index.driver "$TEST_DIR/gone.sh %O %A %B"
  inst status --git --json
  assert_eq "script-missing" "$(json_at .tiers.git.merge_driver.state)" "a pinned script that is gone: script-missing"
  git config --local merge.doc-index.driver "my-own-driver %O %A %B --flag"
  inst status --git --json
  assert_eq "other" "$(json_at .tiers.git.merge_driver.state)" "another install's driver: other"
  inst status --git
  assert_contains "$IOUT" "registered by another install" "…the human line is the one it always was"
  git config --local --unset merge.doc-index.driver
  inst status --git --json
  assert_eq "absent" "$(json_at .tiers.git.merge_driver.state)" "no registration: absent"
  git config --local merge.doc-index.driver "$drv"
  # Hook states: not executable, foreign, absent; .gitattributes overridden.
  chmod 644 .git/hooks/post-merge
  printf '#!/usr/bin/env python3\nprint("mine")\n' > .git/hooks/post-checkout
  rm -f .git/hooks/pre-push
  printf 'docs/.doc-index.json merge=union\n' > .gitattributes.tmp
  cat .gitattributes .gitattributes.tmp > .gitattributes.new
  mv .gitattributes.new .gitattributes
  rm -f .gitattributes.tmp
  inst status --git --json
  assert_eq "not-executable" "$(json_at '.tiers.git.hooks["post-merge"].state')" "a hook of ours without +x: not-executable"
  assert_eq "foreign" "$(json_at '.tiers.git.hooks["post-checkout"].state')" "a hook of the user's without our block: foreign"
  assert_eq "absent" "$(json_at '.tiers.git.hooks["pre-push"].state')" "no hook: absent"
  assert_eq "other" "$(json_at .tiers.git.gitattributes.state)" "another merge attribute wins: other"
  inst status --git
  assert_contains "$IOUT" "not executable" "the human status: unchanged wording (not executable)"
  assert_contains "$(grep post-checkout <<<"$IOUT")" "✗" "…a foreign hook still reads not installed"
  assert_not_contains "$IOUT" "{" "…and no JSON"
  # Claude states.
  rm -f .claude/hooks/doc-superpowers/session-summary.sh
  inst status --claude --json
  assert_eq "script-missing" "$(json_at '.tiers.claude.hooks["session-summary"].state')" "a registered hook without its script: script-missing"
  echo "# edited" >> .claude/hooks/doc-superpowers/hook-lib.sh
  inst status --claude --json
  assert_eq "lib-outdated" "$(json_at '.tiers.claude.hooks["pre-commit-gate"].state')" "an edited hook-lib.sh: lib-outdated"
  echo "{" > .claude/settings.local.json
  inst status --claude --json
  assert_eq "false" "$(json_at .tiers.claude.settings_readable)" "unreadable settings: settings_readable false"
  assert_eq "absent" "$(json_at '.tiers.claude.hooks["pre-commit-gate"].state')" "…and no hook read as registered"
  teardown
}

test_status_json_ci() {
  echo "test: #20 status --json reports the CI tier's workflows, choices and vendored files"
  setup
  inst install --ci
  inst uninstall --ci --workflows=doc-freshness-schedule
  inst status --ci --json
  assert_eq "0" "$IRC" "status --ci --json: exit 0"
  assert_eq "installed" "$(json_at '.tiers.ci.workflows["doc-freshness-pr"].state')" "an installed workflow: installed"
  assert_eq "uninstalled-intentional" "$(json_at '.tiers.ci.workflows["doc-freshness-schedule"].state')" "one removed on purpose: uninstalled-intentional"
  assert_eq "main" "$(json_at .tiers.ci.choices.base_branch)" "the recorded choices"
  assert_eq "false" "$(json_at .tiers.ci.choices.ci_strict)" "…strict as a boolean"
  assert_eq ".github/scripts/doc-tools.sh" "$(json_at .tiers.ci.doc_tools_vendored)" "the vendored doc-tools.sh"
  assert_true "the step-script helpers are counted" test "$(json_at '.tiers.ci.helpers["doc-superpowers-steps"]')" -gt 0
  rm -f .github/workflows/doc-freshness-pr.yml
  inst status --ci --json
  assert_eq "recorded-missing" "$(json_at '.tiers.ci.workflows["doc-freshness-pr"].state')" "recorded installed, file gone: recorded-missing"
  teardown
}

# --- Git hooks: the time budget, the scoped check, the advice (#24) ---

# The shared settings region of <file>, markers included.
settings_region() {
  awk '/^# >>> shared hook settings/ { on = 1 } on { print } /^# <<< shared hook settings/ { exit }' "$1"
}

test_hook_settings_region_shared() {
  echo "test: #24 every git hook and hook-lib.sh carry the one shared settings region (_hook_conf, _advice, _hook_budget, _bounded, _why), byte for byte"
  local ref f
  ref=$(settings_region "$HOOKS_DIR/claude/hook-lib.sh")
  assert_contains "$ref" "_bounded() {" "hook-lib.sh: the region holds _bounded"
  assert_contains "$ref" "_advice() {" "…and _advice"
  assert_contains "$ref" "# <<< shared hook settings" "…and is closed"
  for f in pre-commit post-merge post-checkout prepare-commit-msg pre-push; do
    assert_eq "$ref" "$(settings_region "$HOOKS_DIR/git/$f")" "git/$f: the same region"
  done
  assert_eq "1" "$(grep -c '^_bounded() {' "$HOOKS_DIR/claude/hook-lib.sh")" "hook-lib.sh defines _bounded once (in the region)"
}

# A doc-tools.sh that sleeps <seconds>, then runs the real one.
sleepy_doc_tools() {
  printf '#!/bin/sh\nsleep %s\nexec "%s" "$@"\n' "$2" "$DOC_TOOLS" > "$1/doc-tools.sh"
  chmod +x "$1/doc-tools.sh"
}

test_git_pre_commit_budget() {
  echo "test: #24 git pre-commit gives up past its budget (env or hooks.conf), says so, and commits; STRICT blocks; 0 is no budget"
  hooked_fixture
  local stub start elapsed head
  stage_stale_change
  stub=$(harness_mktemp_d slow-git-pre-commit)
  slow_doc_tools "$stub"
  start=$SECONDS
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 -- git commit -qm budget
  elapsed=$((SECONDS - start))
  assert_eq "0" "$RUN_RC" "over budget: the commit goes on"
  assert_true "…promptly (took ${elapsed}s, the check sleeps 30 s)" test "$elapsed" -lt 15
  assert_contains "$RUN_ERR" "pre-commit: check skipped (budget)" "…and says the check was skipped"
  assert_contains "$RUN_ERR" "longer than 1s" "…naming the budget"
  assert_contains "$RUN_ERR" "check-freshness" "…and the command to run by hand"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_HOOK_BUDGET" "…and the knob"
  assert_eq "1" "$(line_count "$RUN_ERR")" "…in one line"
  assert_child_gone "$stub" "git pre-commit"

  stage_stale_change again
  head=$(git rev-parse HEAD)
  stub=$(harness_mktemp_d slow-git-strict)
  slow_doc_tools "$stub"
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 DOC_SUPERPOWERS_STRICT=1 -- git commit -qm strict
  assert_eq "1" "$RUN_RC" "STRICT, over budget: the commit is blocked (a check that cannot finish, as one that cannot run)"
  assert_eq "$head" "$(git rev-parse HEAD)" "…nothing committed"
  assert_contains "$RUN_ERR" "budget" "…the reason names the budget"
  assert_contains "$RUN_ERR" "DOC_SUPERPOWERS_SKIP=1" "…and the bypass"
  assert_child_gone "$stub" "git pre-commit STRICT"

  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 DOC_SUPERPOWERS_QUIET=1 -- git commit -qm quiet
  assert_eq "0" "$RUN_RC" "QUIET, over budget: committed"
  assert_eq "" "$RUN_ERR" "…silently"

  # The budget from hooks.conf, the env overriding it.
  stage_stale_change conf
  mkdir -p .claude/doc-superpowers
  printf '# team settings\nhook_budget = 1\n' > .claude/doc-superpowers/hooks.conf
  stub=$(harness_mktemp_d slow-git-conf)
  sleepy_doc_tools "$stub" 3
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" -- git commit -qm conf
  assert_contains "$RUN_ERR" "check skipped (budget): the doc freshness check took longer than 1s" "hooks.conf's hook_budget is the budget"
  stage_stale_change env
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=0 -- git commit -qm unbounded
  assert_eq "0" "$RUN_RC" "DOC_SUPERPOWERS_HOOK_BUDGET=0: committed"
  assert_not_contains "$RUN_ERR" "budget" "…0 is no budget, over hooks.conf's: the slow check finishes"
  assert_contains "$RUN_OUT$RUN_ERR" "stale doc(s) in this commit" "…and reports"
  rm -f .claude/doc-superpowers/hooks.conf
  teardown
}

# _hook_budget <value>: the shared region's reading of DOC_SUPERPOWERS_HOOK_BUDGET.
hook_budget_of() {
  local region
  region=$(settings_region "$HOOKS_DIR/git/pre-commit")
  DOC_SUPERPOWERS_HOOK_BUDGET="$1" "$BASH_BIN" -c 'eval "$1"; _hook_budget' _ "$region" 2>&1
}

# A `sleep` for PATH in <dir> that, as macOS /bin/sleep does, rejects (exit 1
# at once) a negative or non-numeric value or one of 4294967295 s or more —
# whichever sleep the host puts first on PATH.
macos_sleep_shim() {
  cat > "$1/sleep" <<EOF
#!/bin/sh
case "\$1" in "" | *[!0-9.]*) echo "sleep: invalid time interval: \$1" >&2; exit 1 ;; esac
i=\${1%%.*}
i=\$(printf '%s' "\$i" | sed 's/^0*//')
if [ \${#i} -gt 10 ] || { [ \${#i} -eq 10 ] && [ "\$i" -ge 4294967295 ]; }; then
  echo "sleep: invalid time interval: \$1" >&2; exit 1
fi
exec "$(command -v sleep)" "\$@"
EOF
  chmod +x "$1/sleep"
}

test_git_hook_budget_clamp() {
  echo "test: #24 a budget too large for sleep (over 86400 s, or over 6 digits) reads as no budget: the check runs to completion, never skipped at once"
  local v
  assert_eq "20" "$(hook_budget_of 20)" "20 reads as 20"
  assert_eq "20" "$(hook_budget_of 0020)" "leading zeros: 0020 reads as 20"
  assert_eq "86400" "$(hook_budget_of 86400)" "86400 (a day) is the largest budget"
  assert_eq "20" "$(hook_budget_of 2x)" "not digits: the default"
  for v in 86401 999999 1000000 4294967295 99999999999 99999999999999999999 0000086401; do
    assert_eq "0" "$(hook_budget_of "$v")" "$v reads as 0 (no budget)"
  done
  assert_eq "5" "$(hook_budget_of 000000000000000000000000005)" "many leading zeros: still the value (5)"
  assert_eq "0" "$(hook_budget_of 0000)" "all zeros: 0"
  hooked_fixture
  local stub
  stub=$(harness_mktemp_d sleepy-huge-budget)
  sleepy_doc_tools "$stub" 2
  macos_sleep_shim "$stub"
  for v in 4294967295 99999999999999999999; do
    stage_stale_change "$v"
    run_hooked DOC_TOOLS="$stub/doc-tools.sh" PATH="$stub:$REAL_PATH" DOC_SUPERPOWERS_HOOK_BUDGET="$v" -- git commit -qm "huge $v"
    assert_eq "0" "$RUN_RC" "budget $v: committed"
    assert_not_contains "$RUN_ERR" "check skipped (budget)" "budget $v: the check is not skipped at once"
    assert_contains "$RUN_OUT$RUN_ERR" "stale doc(s) in this commit" "budget $v: the check ran to completion and reported"
  done
  # A watchdog whose sleep fails (whatever the reason) never fires.
  stub=$(harness_mktemp_d failing-watchdog-sleep)
  sleepy_doc_tools "$stub" 2
  printf '#!/bin/sh
[ "$1" = 5 ] && exit 1
exec "%s" "$@"
' "$(command -v sleep)" > "$stub/sleep"
  chmod +x "$stub/sleep"
  stage_stale_change failing-sleep
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" PATH="$stub:$REAL_PATH" DOC_SUPERPOWERS_HOOK_BUDGET=5 -- git commit -qm "failing sleep"
  assert_eq "0" "$RUN_RC" "the watchdog's sleep fails: committed"
  assert_not_contains "$RUN_ERR" "check skipped (budget)" "the watchdog's sleep fails: the check is not skipped"
  assert_contains "$RUN_OUT$RUN_ERR" "stale doc(s) in this commit" "the watchdog's sleep fails: the check ran to completion"
  teardown
}

# A `sleep` for PATH that records its PID in <dir>/wd.pid when asked to sleep
# <seconds> (the watchdog's budget), then becomes the real sleep.
watchdog_sleep_shim() {
  printf '#!/bin/sh\n[ "$1" = "%s" ] && echo $$ > "%s/wd.pid"\nexec "%s" "$@"\n' "$2" "$1" "$(command -v sleep)" > "$1/sleep"
  chmod +x "$1/sleep"
}

# assert_pid_gone <pidfile> <label>: the process it names has exited.
assert_pid_gone() {
  local pid gone=no i
  pid=$(cat "$1" 2>/dev/null || echo "")
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then gone=yes; break; fi
    sleep 0.2
  done
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  assert_eq "yes" "$gone" "$2"
}

test_git_hook_signal_kills_check() {
  echo "test: #24 a git hook signalled mid-check (INT, TERM, HUP) kills the check's process group and the watchdog, and exits 128+n"
  hooked_fixture
  local sig num stub hook rc i
  for sig in INT TERM HUP; do
    case "$sig" in INT) num=2 ;; TERM) num=15 ;; HUP) num=1 ;; esac
    stage_stale_change "$sig"
    stub=$(harness_mktemp_d "signal-$sig")
    slow_doc_tools "$stub"
    watchdog_sleep_shim "$stub" 777
    rc=0
    # Job control on, so the hook (a background job here) does not start with
    # SIGINT ignored, as an interactive git commit would not.
    set -m
    env DOC_TOOLS="$stub/doc-tools.sh" PATH="$stub:$REAL_PATH" DOC_SUPERPOWERS_HOOK_BUDGET=777 \
      "$BASH_BIN" .git/hooks/pre-commit </dev/null >/dev/null 2>&1 &
    hook=$!
    set +m
    for i in $(seq 1 50); do
      [ -s "$stub/child.pid" ] && [ -s "$stub/wd.pid" ] && break
      sleep 0.2
    done
    assert_true "$sig: fixture: the check and the watchdog started" test -s "$stub/child.pid" -a -s "$stub/wd.pid"
    kill -s "$sig" "$hook"
    wait "$hook" || rc=$?
    assert_eq "$((128 + num))" "$rc" "$sig: the hook exits 128+$num"
    assert_child_gone "$stub" "$sig"
    assert_pid_gone "$stub/wd.pid" "$sig: the watchdog's sleep is killed too"
  done
  teardown
}

test_git_post_merge_and_checkout_budget() {
  echo "test: #24 post-merge and post-checkout give up past their budget and say so; never block"
  hooked_fixture
  local stub
  git checkout -qb feature
  echo "feature" > src/index.js
  git add src/index.js
  fixture_commit "feature code"
  git checkout -q main
  stub=$(harness_mktemp_d slow-merge)
  slow_doc_tools "$stub"
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 -- git merge -q --no-ff feature -m "merge"
  assert_eq "0" "$RUN_RC" "post-merge over budget: the merge exits 0"
  assert_contains "$RUN_ERR" "post-merge: check skipped (budget)" "…and says the check was skipped"
  assert_child_gone "$stub" "post-merge"
  stub=$(harness_mktemp_d slow-checkout)
  slow_doc_tools "$stub"
  git checkout -q -b other HEAD~1 2>/dev/null || git checkout -q -b other
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 -- git checkout -q main
  assert_eq "0" "$RUN_RC" "post-checkout over budget: the checkout exits 0"
  assert_contains "$RUN_ERR" "post-checkout: check skipped (budget)" "…and says the check was skipped"
  assert_child_gone "$stub" "post-checkout"
  teardown
}

test_git_prepare_commit_msg_budget() {
  echo "test: #24 prepare-commit-msg past its budget adds one comment line saying so"
  hooked_fixture
  local stub msg
  stage_stale_change
  stub=$(harness_mktemp_d slow-pcm)
  slow_doc_tools "$stub"
  msg=$(harness_mktemp msg)
  : > "$msg"
  run_hooked DOC_TOOLS="$stub/doc-tools.sh" DOC_SUPERPOWERS_HOOK_BUDGET=1 -- "$BASH_BIN" .git/hooks/prepare-commit-msg "$msg"
  assert_eq "0" "$RUN_RC" "exit 0"
  assert_contains "$(cat "$msg")" "# doc-superpowers: cannot check doc freshness: check skipped (budget)" "one comment line names the budget"
  assert_eq "1" "$(line_count "$(cat "$msg")")" "…one line"
  assert_child_gone "$stub" "prepare-commit-msg"
  teardown
}

test_git_pre_commit_scopes_added_entries() {
  echo "test: #24 the entries a commit's index adds are judged scoped to their own code refs; unscoped only when one has none"
  hooked_fixture
  local log wrap
  log=$(harness_mktemp argv)
  wrap=$(argv_logging_doc_tools "$log")
  echo "# New" > docs/new.md
  echo "docs/new.md:src/util.js:guide" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  git add docs/.doc-index.json docs/new.md
  run_hooked DOC_TOOLS="$wrap" -- git commit -qm added
  assert_eq "0" "$RUN_RC" "committed"
  assert_eq "2" "$(grep -c '^check-freshness' "$log")" "two checks: the staged paths, then the added entry"
  assert_eq "0" "$(grep -cx 'check-freshness --tree [0-9a-f]*' "$log")" "…neither unscoped"
  # An added entry without a code ref: no filter keeps it, so unscoped.
  : > "$log"
  echo "# Bare" > docs/bare.md
  echo "docs/bare.md:src/util.js:guide" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  jq '.docs["docs/bare.md"].code_refs = []' docs/.doc-index.json > docs/idx.tmp && mv docs/idx.tmp docs/.doc-index.json
  git add docs/.doc-index.json
  run_hooked DOC_TOOLS="$wrap" DOC_SUPERPOWERS_STRICT=1 -- git commit -qm bare
  assert_eq "1" "$(grep -cx 'check-freshness --tree [0-9a-f]*' "$log")" "an added entry with no code ref: the unscoped check"
  assert_contains "$RUN_OUT$RUN_ERR" "docs/bare.md" "…which judges it (not in this commit)"
  teardown
}

test_advice_setting_git_hooks() {
  echo "test: #24 DOC_SUPERPOWERS_ADVICE / hooks.conf advice replaces or drops the git hooks' '/doc-superpowers …' advice"
  hooked_fixture
  stage_stale_change
  run_pre_commit
  assert_contains "$RUN_OUT" "Run '/doc-superpowers update' to refresh" "default: the skill's command"
  run_pre_commit DOC_SUPERPOWERS_ADVICE=off
  assert_not_contains "$RUN_OUT" "/doc-superpowers" "off: no skill command"
  assert_contains "$RUN_OUT" "DOC_SUPERPOWERS_SKIP=1 bypasses." "…the bypass stays"
  assert_contains "$RUN_OUT" "stale doc(s) in this commit" "…and the report"
  run_pre_commit DOC_SUPERPOWERS_ADVICE='make docs-{action}'
  assert_contains "$RUN_OUT" "Run 'make docs-update' to refresh" "a template: {action} replaced"
  run_pre_commit DOC_SUPERPOWERS_ADVICE=off DOC_SUPERPOWERS_STRICT=1
  assert_contains "$RUN_OUT" "Commit blocked (DOC_SUPERPOWERS_STRICT=1). DOC_SUPERPOWERS_SKIP=1 bypasses." "off, STRICT: the block line without the command"
  mkdir -p .claude/doc-superpowers
  printf 'advice = ./tools/docs.sh {action}\n' > .claude/doc-superpowers/hooks.conf
  run_pre_commit
  assert_contains "$RUN_OUT" "Run './tools/docs.sh update' to refresh" "hooks.conf's advice key"
  run_pre_commit DOC_SUPERPOWERS_ADVICE=on
  assert_contains "$RUN_OUT" "Run '/doc-superpowers update'" "the env overrides hooks.conf (on: the default)"
  # prepare-commit-msg names the command in its comment block.
  local msg
  msg=$(harness_mktemp msg)
  : > "$msg"
  run_hooked -- "$BASH_BIN" .git/hooks/prepare-commit-msg "$msg"
  assert_contains "$(cat "$msg")" "Update them with ./tools/docs.sh update, then re-verify" "prepare-commit-msg: the template"
  : > "$msg"
  run_hooked DOC_SUPERPOWERS_ADVICE=off -- "$BASH_BIN" .git/hooks/prepare-commit-msg "$msg"
  assert_contains "$(cat "$msg")" "Update them, then re-verify" "prepare-commit-msg off: no command"
  rm -f .claude/doc-superpowers/hooks.conf
  # post-merge / post-checkout: the audit line.
  git commit -qm stale >/dev/null 2>&1 || DOC_SUPERPOWERS_SKIP=1 git commit -qm stale
  local prev
  prev=$(git rev-parse HEAD~1)
  run_hooked -- "$BASH_BIN" .git/hooks/post-checkout "$prev" "$(git rev-parse HEAD)" 1
  assert_contains "$RUN_OUT" "Run '/doc-superpowers audit' to review." "post-checkout default"
  run_hooked DOC_SUPERPOWERS_ADVICE='x {action}' -- "$BASH_BIN" .git/hooks/post-checkout "$prev" "$(git rev-parse HEAD)" 1
  assert_contains "$RUN_OUT" "Run 'x audit' to review." "post-checkout template"
  run_hooked DOC_SUPERPOWERS_ADVICE=off -- "$BASH_BIN" .git/hooks/post-checkout "$prev" "$(git rev-parse HEAD)" 1
  assert_not_contains "$RUN_OUT" "to review" "post-checkout off: the line is dropped"
  assert_contains "$RUN_OUT" "stale doc(s) on this branch" "…the report stays"
  git update-ref ORIG_HEAD "$prev"
  run_hooked DOC_SUPERPOWERS_ADVICE=off -- "$BASH_BIN" .git/hooks/post-merge 0
  assert_not_contains "$RUN_OUT" "to review" "post-merge off: the line is dropped"
  assert_contains "$RUN_OUT" "became stale after merge" "…the report stays"
  run_hooked DOC_SUPERPOWERS_ADVICE='x {action}' -- "$BASH_BIN" .git/hooks/post-merge 0
  assert_contains "$RUN_OUT" "Run 'x audit' to review." "post-merge template"
  # pre-push: the release reminder.
  git tag v0.0.1 HEAD~1
  DOC_SUPERPOWERS_SKIP=1 commit_n 6
  run_pre_push "$(push_line main)" DOC_SUPERPOWERS_ADVICE=off
  assert_contains "$RUN_OUT" "commits since v0.0.1" "pre-push off: the count stays"
  assert_not_contains "$RUN_OUT" "Consider running" "…the suggestion is dropped"
  run_pre_push "$(push_line main)" DOC_SUPERPOWERS_ADVICE='x {action}'
  assert_contains "$RUN_OUT" "Consider running 'x release'" "pre-push template"
  teardown
}

test_advice_setting_claude_hooks() {
  echo "test: #24 the advice setting reaches the Claude hooks (gate, sync, summary)"
  hooked_fixture
  stage_stale_change
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "Consider running '/doc-superpowers update'" "gate default"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_ADVICE=off
  assert_not_contains "$(out_field .hookSpecificOutput.additionalContext)" "/doc-superpowers" "gate off: no skill command"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "docs/architecture.md" "…the report stays"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_ADVICE='/team-docs {action}'
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "Consider running '/team-docs update'" "gate template"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -m x')" DOC_SUPERPOWERS_ADVICE=off DOC_SUPERPOWERS_STRICT=1
  assert_eq "2" "$RUN_RC" "gate STRICT: blocked"
  assert_not_contains "$RUN_ERR" "/doc-superpowers" "gate STRICT off: no skill command"
  assert_contains "$RUN_ERR" "update the docs and re-verify them" "…the instruction stays"
  # The defer note names the git tier's install command.
  rm -f .git/hooks/pre-commit
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')" DOC_SUPERPOWERS_ADVICE='/team-docs {action}'
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "(install the git tier: /team-docs hooks install --git)" "gate defer note: the template"
  run_claude_hook PreToolUse pre-commit-gate "$(pretool_json 'git commit -am x')" DOC_SUPERPOWERS_ADVICE=off
  assert_not_contains "$(out_field .hookSpecificOutput.additionalContext)" "install the git tier" "gate defer note off: dropped"
  DOC_SUPERPOWERS_SKIP=1 git commit -qm code
  mkdir -p .claude/doc-superpowers
  printf 'advice = off\n' > .claude/doc-superpowers/hooks.conf
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -m code')"
  assert_not_contains "$(out_field .hookSpecificOutput.additionalContext)" "/doc-superpowers" "post-commit-sync, hooks.conf off: no skill command"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "Refresh stale documentation, then re-verify" "…the instruction stays"
  printf 'advice = /team-docs {action}\n' > .claude/doc-superpowers/hooks.conf
  run_claude_hook PostToolUse post-commit-sync "$(posttool_json 'git commit -m code')"
  assert_contains "$(out_field .hookSpecificOutput.additionalContext)" "Run '/team-docs update' to refresh" "post-commit-sync: hooks.conf's template"
  echo "again" > src/index.js
  run_claude_hook Stop session-summary "$STOP_JSON"
  assert_contains "$(out_field .systemMessage)" "Update them (/team-docs update)" "session-summary: the template"
  run_claude_hook Stop session-summary "$STOP_JSON" DOC_SUPERPOWERS_ADVICE=off
  assert_contains "$(out_field .systemMessage)" "Update them and re-verify" "session-summary off"
  assert_not_contains "$(out_field .systemMessage)" "/doc-superpowers" "…no skill command"
  rm -f .claude/doc-superpowers/hooks.conf
  teardown
}

echo ""
echo "=== install --git --merge-driver-only, status --json (#20); hook budgets and advice (#24) ==="
test_driver_only_install_uninstall
test_driver_only_missing_driver
test_driver_only_flag_rules
test_driver_only_ignores_foreign_hooks_path
test_status_json_states
test_status_json_ci
test_hook_settings_region_shared
test_git_pre_commit_budget
test_git_hook_budget_clamp
test_git_hook_signal_kills_check
test_git_post_merge_and_checkout_budget
test_git_prepare_commit_msg_budget
test_git_pre_commit_scopes_added_entries
test_advice_setting_git_hooks
test_advice_setting_claude_hooks

test_claude_hook_contract_held() {
  echo "test: every Claude hook run above held the contract (exit 0, or 2 only under STRICT; stdout one JSON object or nothing)"
  assert_true "Claude hook runs checked: $CLAUDE_HOOK_RUNS (the suite makes over 50)" test "$CLAUDE_HOOK_RUNS" -ge 50
  assert_eq "0" "$CLAUDE_HOOK_BREACHES" "contract breaches (each one is also a FAIL where it ran)"
}

echo ""
echo "=== Every Claude hook run: the exit-code and JSON contract ==="
test_claude_hook_contract_held

print_summary

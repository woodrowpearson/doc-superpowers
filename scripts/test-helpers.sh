#!/usr/bin/env bash
# Shared test helpers for doc-superpowers test suites
# Source this file from test scripts after setting SCRIPT_DIR

# --- Interpreter under test -------------------------------------------------
#
# Every script in this repo is `#!/usr/bin/env bash`, so launching one by its
# shebang re-resolves bash from PATH and silently discards the interpreter the
# suite itself was started with. On a CI leg whose entire purpose is to cover
# bash 3.2 that turns the leg into a second bash-5 run — the exact false green
# that let a `local -A` (bash 4+ only) ship to a release. Scripts under test are
# therefore launched explicitly under $BASH_BIN via a shim, never by shebang.
#
# Defaults to the interpreter running this suite, so a bare
# `./scripts/test-doc-tools.sh` behaves exactly as before; CI sets BASH_BIN per
# matrix leg.
BASH_BIN="${BASH_BIN:-${BASH:-bash}}"

# --- Suite scratch root, cleanup and signal handling ------------------------
#
# Everything a suite writes lives under one private root: the bash shims, the
# per-test fixture repos (setup()), the fake HOME, and any scratch file a test
# needs (harness_mktemp / harness_mktemp_d). Nothing is written to a fixed
# /tmp path, so parallel runs cannot collide and an interrupted run leaves
# nothing behind.
#
# The root is created HERE, at source time, rather than lazily inside a
# helper: callers use `DOC_TOOLS="$(bash_bin_shim …)"`, so a helper body runs
# in a command-substitution subshell — a trap registered there fires the
# instant that subshell ends and deletes the directory out from under the
# suite. Registering the traps in the main shell is the only placement that
# works. Suites must not register their own EXIT/INT/TERM traps; create
# scratch paths with harness_mktemp / harness_mktemp_d instead.
_HARNESS_TMP=$(mktemp -d -t doc-sp-test.XXXXXX) || {
  echo "ERROR: mktemp -d failed for the test harness root" >&2
  exit 1
}
_SHIM_DIR="$_HARNESS_TMP/shim"
SUITE_TMP="$_HARNESS_TMP/tmp"
mkdir -p "$_SHIM_DIR" "$SUITE_TMP" "$_HARNESS_TMP/home" "$_HARNESS_TMP/xdg" || exit 1

# Never inherit a TEST_DIR from the caller's environment: cleanup removes it.
TEST_DIR=""

_harness_cleanup() {
  cd / 2>/dev/null || true
  [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"
  [ -n "${_HARNESS_TMP:-}" ] && rm -rf "$_HARNESS_TMP"
  return 0
}
# INT/TERM must END the run: a handler that only cleans up would return into
# the suite, which then keeps running against a deleted scratch root.
trap '_harness_cleanup' EXIT
trap '_harness_cleanup; exit 130' INT
trap '_harness_cleanup; exit 143' TERM

# Scratch file / directory under the suite root (removed on exit).
harness_mktemp() {
  mktemp "$SUITE_TMP/${1:-tmp}.XXXXXX"
}
harness_mktemp_d() {
  mktemp -d "$SUITE_TMP/${1:-tmp}.XXXXXX"
}

# Signal a background job after a delay, then reap it and return its exit code.
# The portable stand-in for `timeout -s SIG`: stock macOS ships neither
# `timeout` nor `gtimeout`, so interruption tests use a background job + sleep
# + kill instead. Start the job yourself (so `$!` is the process to signal —
# for a background pipeline that is its LAST command), then:
#   "$DOC_TOOLS" build-index < "$map" >/dev/null 2>&1 &
#   rc=0; harness_kill_after 1 TERM "$!" || rc=$?
# HARNESS_KILL_ALIVE is 1 if the job was still running when signalled, 0 if it
# had already exited — assert it, or a fast machine turns the test vacuous.
# Background jobs of a non-interactive shell ignore SIGINT/SIGQUIT (POSIX), so
# INT cannot be delivered this way; use TERM.
HARNESS_KILL_ALIVE=0
harness_kill_after() {
  local secs="$1" sig="$2" pid="$3" rc=0
  sleep "$secs"
  if kill -0 "$pid" 2>/dev/null; then
    HARNESS_KILL_ALIVE=1
    kill "-$sig" "$pid" 2>/dev/null || true
  else
    HARNESS_KILL_ALIVE=0
  fi
  wait "$pid" || rc=$?
  return "$rc"
}

# --- Git / environment isolation --------------------------------------------
#
# A fixture must never see the contributor's git configuration: a global
# `core.hooksPath` made `install --git` write into the real machine-wide hooks
# dir, and a global `init.defaultBranch`, signing key or alias changes what
# the fixtures do. Pin the environment for the whole suite here (covers tests
# that build their own repos), and again per test in setup().
#
# The real HOME is kept only so optional tools installed per-user (e.g. a
# `pip install --user` PyYAML) can still be located; no git call sees it.
_HARNESS_REAL_HOME="${HOME:-}"
_harness_isolate_git_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
}
_harness_isolate_git_env
export HOME="$_HARNESS_TMP/home" XDG_CONFIG_HOME="$_HARNESS_TMP/xdg"

# Leave the caller's cwd (usually the real repo): a tool run by a test that
# forgot setup() must not land in the checkout under test.
cd "$SUITE_TMP" || exit 1

# Wrap a script in a shim that always execs it under $BASH_BIN, and echo the
# shim path. A shim (rather than rewriting call sites to `"$BASH_BIN" "$X"`) is
# required because some scripts under test — the git and Claude hooks — take a
# doc-tools.sh PATH in $DOC_TOOLS and execute it themselves; only a shim reaches
# that nested invocation.
bash_bin_shim() {
  local target="$1"
  local shim="$_SHIM_DIR/$(basename "$target")"
  # /bin/sh for the shim itself: it only execs, so its own interpreter is
  # irrelevant, and using sh makes it obvious the bash choice is the exec'd one.
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH_BIN" "$target" > "$shim"
  chmod +x "$shim"
  printf '%s' "$shim"
}

PASS=0
FAIL=0
SKIP=0
XFAIL=0
TESTS_RUN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

setup() {
  TEST_DIR=$(mktemp -d "$SUITE_TMP/test.XXXXXX")
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  export HOME="$TEST_DIR/home" XDG_CONFIG_HOME="$TEST_DIR/xdg" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  cd "$TEST_DIR"
  # `-b` needs git >= 2.28; older git falls back to re-pointing HEAD.
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  # HOME/XDG live inside the work tree; keep them out of every `git add -A`.
  printf 'home/\nxdg/\n' >> .git/info/exclude
  mkdir -p docs src
  echo "# Architecture" > docs/architecture.md
  echo "console.log('hello')" > src/index.js
  git add -A && git commit -m "init" --quiet
}

teardown() {
  cd "$SUITE_TMP"
  rm -rf "$TEST_DIR"
  TEST_DIR=""
  export HOME="$_HARNESS_TMP/home" XDG_CONFIG_HOME="$_HARNESS_TMP/xdg"
}

_pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}  PASS${NC}: %s\n" "$1"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$expected" "$actual"
  fi
}

# Record a pass/fail from a shell condition without the `[[ … ]]; assert_eq 0 $?`
# pattern, which under `set -e` aborts the suite before the assert can count it.
#   assert_true "msg" test -x "$f"
assert_true() {
  local msg="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    condition failed: %s\n" "$msg" "$*"
  fi
}

# Here-strings, not `echo "$h" | grep -q`: under `set -o pipefail` grep's early
# exit on a match SIGPIPEs the echo, the pipeline reports 141, and the assert
# inverts — a false PASS for assert_not_contains with the needle present. The
# harness self-test in test-doc-tools.sh pins this.
assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -qF -- "$needle" <<<"$haystack"; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected NOT to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
  fi
}

assert_exit_code() {
  local expected="$1" msg="${2:-}"
  shift 2
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$expected" = "$actual" ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected exit: %s\n    actual exit:   %s\n" "$msg" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file not found: %s\n" "$msg" "$path"
  fi
}

assert_file_not_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$path" ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file should not exist: %s\n" "$msg" "$path"
  fi
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" msg="${4:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual
  actual=$(jq -r "$field" <<<"$json" 2>&1) || actual="<jq failed: $actual>"
  if [ "$expected" = "$actual" ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    field: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$field" "$expected" "$actual"
  fi
}

# Record a test that could not run (missing optional tool). Loud, counted, and
# listed in the summary — never a silent pass.
record_skip() {
  local msg="$1"
  SKIP=$((SKIP + 1))
  printf "${YELLOW}  SKIP${NC}: %s\n" "$msg"
}

# A fixture that exposes a verified bug owned by a later fix Task. Both the
# correct value AND the observed wrong value are pinned:
#   actual == expected   → FAIL ("XPASS"): the bug is fixed, so the owning Task
#                          must turn this into an ordinary assertion;
#   actual == known_bad  → XFAIL (reported every run, not counted as a pass);
#   anything else        → FAIL: a new regression must never hide behind the
#                          known-bug marker.
#   assert_eq_known_bug "<owner, e.g. T10/I-9>" expected known_bad actual msg
assert_eq_known_bug() {
  local owner="$1" expected="$2" known_bad="$3" actual="$4" msg="${5:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    XPASS: known bug (%s) no longer reproduces — make this an ordinary assertion\n" "$msg" "$owner"
  elif [ "$known_bad" = "$actual" ]; then
    XFAIL=$((XFAIL + 1))
    printf "${YELLOW}  XFAIL${NC}: %s [known bug, owner %s]\n    expected: %s\n    actual:   %s\n" "$msg" "$owner" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s [known bug %s, but the value changed]\n    expected:  %s\n    known bad: %s\n    actual:    %s\n" \
      "$msg" "$owner" "$expected" "$known_bad" "$actual"
  fi
}

# Condition form of assert_eq_known_bug. It pins no known-bad value, so only
# use it where an ordinary assert bounds the wrong side (e.g. the perf guard's
# 3N+c ceiling next to its N+c target):
#   assert_true_known_bug "<owner>" "msg" test "$n" -le 10
assert_true_known_bug() {
  local owner="$1" msg="$2"
  shift 2
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    XPASS: known bug (%s) no longer reproduces — make this an ordinary assertion\n" "$msg" "$owner"
  else
    XFAIL=$((XFAIL + 1))
    printf "${YELLOW}  XFAIL${NC}: %s [known bug, owner %s]\n    condition failed: %s\n" "$msg" "$owner" "$*"
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

print_summary() {
  echo ""
  echo "================================"
  printf "Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, %d total\n" "$PASS" "$FAIL" "$TESTS_RUN"
  if [ "$SKIP" -gt 0 ] || [ "$XFAIL" -gt 0 ]; then
    printf "         ${YELLOW}%d skipped, %d known failures (xfail)${NC} — see SKIP/XFAIL lines above\n" "$SKIP" "$XFAIL"
  fi
  echo "================================"
  [ "$FAIL" -eq 0 ]
}

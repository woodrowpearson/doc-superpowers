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

# Wrap a script in a shim that always execs it under $BASH_BIN, and echo the
# shim path. A shim (rather than rewriting call sites to `"$BASH_BIN" "$X"`) is
# required because some scripts under test — the git and Claude hooks — take a
# doc-tools.sh PATH in $DOC_TOOLS and execute it themselves; only a shim reaches
# that nested invocation.
#
# The shim directory is created HERE, at source time, rather than lazily inside
# bash_bin_shim(): callers use `DOC_TOOLS="$(bash_bin_shim …)"`, so the function
# body runs in a command-substitution subshell — an EXIT trap registered there
# fires the instant that subshell ends and deletes the directory out from under
# the suite. Registering it in the main shell is the only placement that works.
#
# No suite that sources this file registers its own EXIT trap (only
# test-doc-pr-release.sh does, and it does not source these helpers).
_SHIM_DIR=$(mktemp -d -t doc-sp-shim.XXXXXX) || {
  echo "ERROR: mktemp -d failed for bash shim" >&2
  exit 1
}
# shellcheck disable=SC2064  # expand now, not at trap time
trap "rm -rf '$_SHIM_DIR'" EXIT INT TERM

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
TESTS_RUN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

setup() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  mkdir -p docs src
  echo "# Architecture" > docs/architecture.md
  echo "console.log('hello')" > src/index.js
  git add -A && git commit -m "init" --quiet
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ! echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected NOT to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
  fi
}

assert_exit_code() {
  local expected="$1" msg="${2:-}"
  shift 2
  TESTS_RUN=$((TESTS_RUN + 1))
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected exit: %s\n    actual exit:   %s\n" "$msg" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file not found: %s\n" "$msg" "$path"
  fi
}

assert_file_not_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file should not exist: %s\n" "$msg" "$path"
  fi
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" msg="${4:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual
  actual=$(echo "$json" | jq -r "$field")
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    field: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$field" "$expected" "$actual"
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
  echo "================================"
  [ "$FAIL" -eq 0 ]
}

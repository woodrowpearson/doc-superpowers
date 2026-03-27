#!/usr/bin/env bash
# Shared test helpers for doc-superpowers test suites
# Source this file from test scripts after setting SCRIPT_DIR

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

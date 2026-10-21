#!/usr/bin/env bash
# check-ci.sh — run locally exactly what .github/workflows/tests.yml runs (#27).
#
# tests.yml calls this script for every check (one step per suite, so a failure
# names it), so the two cannot drift apart: what passes here passes there,
# toolchain aside. For this repository only; it is not shipped to a consuming
# project.
#
# Usage: scripts/check-ci.sh [--fast] [--bash <path>]... [--verbose] [<check>...]
#        scripts/check-ci.sh --list | --help
#
# Checks (default: all of them, the suites under every interpreter found):
#   toolchain          jq, git, a YAML parser, node and shellcheck are present
#   doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims
#   ledger             the seven suites, scripts/test-<name>.sh, each run under
#                      every interpreter (BASH_BIN set, so the scripts under
#                      test run under it too)
#   search             the doc-search pytest suite (search/, a uv Python
#                      package): `uv run --project search --frozen
#                      --all-extras pytest -q`, run once whatever the
#                      interpreters (it does not use them). It takes a minute
#                      or three and never touches the network. Not in --fast.
#   self-install       the self-installed CI tier and the .gitattributes block
#                      match what the installer writes (check-self-install.sh)
#   check-version      the five manifests carry RELEASE-NOTES.md's version
#   tag                v<version> is a tag on origin (check-version --tag;
#                      tests.yml runs it on pushes to main only, so the default
#                      run here gives --warn: a missing tag is a WARN line)
#   plugin-validate    `claude plugin validate .` (errors fail, warnings are
#                      shown). Needs the claude CLI: a loud SKIP without it.
#                      Not in tests.yml — GitHub's runners have no
#                      authenticated claude CLI — so it runs only here.
#
# --fast        One interpreter (bash 3.2 when the host has it, the support
#               floor; else the first found), the quick suites only
#               (spec-status-model, doc-pr-release, merge-driver), then
#               self-install and check-version. What the maintainer pre-push
#               hook runs (scripts/install-maintainer-hooks.sh).
# --bash PATH   Run the suites under PATH (repeatable) instead of detecting:
#               detection takes the first bash >= 4 of /opt/homebrew/bin/bash,
#               /usr/local/bin/bash, /home/linuxbrew/.linuxbrew/bin/bash, the
#               bash on PATH, /usr/bin/bash, /bin/bash, and /bin/bash when it is
#               3.x. A host without one of the two is said so, loudly.
# --verbose     Stream every suite's output (tests.yml uses it). Otherwise
#               each suite's output goes to a log, and only its result line —
#               and its FAIL lines, on a failure — is printed.
#
# As in CI, DOC_SP_REQUIRE_YAML_PARSER, DOC_SP_REQUIRE_NODE,
# DOC_SP_REQUIRE_SHELLCHECK and DOC_SP_REQUIRE_UV default to 1, so a missing
# tool is a FAIL, never a SKIP. Export one as 0 to accept that SKIP locally
# (DOC_SP_REQUIRE_UV=0: a host without uv skips the search check, loudly).
#
# Exit status: 0 when every check passed, 1 when one failed, 2 on a usage
# error.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUITES="doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims ledger"
FAST_SUITES="spec-status-model doc-pr-release merge-driver"
CHECKS="toolchain $SUITES search self-install check-version tag plugin-validate"

export DOC_SP_REQUIRE_YAML_PARSER="${DOC_SP_REQUIRE_YAML_PARSER:-1}"
export DOC_SP_REQUIRE_NODE="${DOC_SP_REQUIRE_NODE:-1}"
export DOC_SP_REQUIRE_SHELLCHECK="${DOC_SP_REQUIRE_SHELLCHECK:-1}"
export DOC_SP_REQUIRE_UV="${DOC_SP_REQUIRE_UV:-1}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# An error line: a GitHub annotation inside Actions, plain text elsewhere.
err() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::error::$*" >&2
  else
    echo "ERROR: $*" >&2
  fi
}

FAST=0 VERBOSE=0 BASHES="" NAMED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) FAST=1 ;;
    --verbose | -v) VERBOSE=1 ;;
    --bash)
      [ $# -ge 2 ] || { err "--bash requires a path"; exit 2; }
      BASHES="$BASHES $2"
      shift
      ;;
    --bash=*) BASHES="$BASHES ${1#--bash=}" ;;
    --list) printf '%s\n' $CHECKS; exit 0 ;;
    -h | --help) usage; exit 0 ;;
    -*) err "unknown option '$1' (see --help)"; exit 2 ;;
    *)
      case " $CHECKS " in
        *" $1 "*) NAMED="$NAMED $1" ;;
        *) err "unknown check '$1' (one of: $CHECKS)"; exit 2 ;;
      esac
      ;;
  esac
  shift
done

# bash_major <path>: the interpreter's major version, or nothing.
bash_major() {
  [ -x "$1" ] || return 1
  # shellcheck disable=SC2016  # expands in the bash being probed
  "$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null
}

# The interpreters: a bash >= 4 and a bash 3.x, each the first found.
detect_bashes() {
  local b m new="" old=""
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash \
    "$(command -v bash 2>/dev/null || true)" /usr/bin/bash /bin/bash; do
    [ -n "$b" ] || continue
    m=$(bash_major "$b") || continue
    if [ -z "$new" ] && [ "$m" -ge 4 ] 2>/dev/null; then new="$b"; fi
  done
  m=$(bash_major /bin/bash || true)
  [ "$m" != 3 ] || old=/bin/bash
  if [ -z "$new" ]; then
    echo "NOTE: no bash >= 4 found on this host: the bash 5.x leg (tests.yml's ubuntu) is not run here" >&2
  fi
  if [ -z "$old" ]; then
    echo "NOTE: no bash 3.2 (/bin/bash) on this host: the bash 3.2 leg (tests.yml's macOS) is not run here" >&2
  fi
  if [ "$FAST" = 1 ]; then
    # The floor first: a bash-4-only construct breaks there.
    printf '%s\n' "${old:-$new}"
  else
    printf '%s\n' $new $old
  fi
}

if [ -n "$BASHES" ]; then
  given="$BASHES" BASHES=""
  for b in $given; do
    # A bare name (tests.yml's ubuntu leg passes "bash") is looked up on PATH.
    case "$b" in
      */*) ;;
      *) b=$(command -v "$b" 2>/dev/null || printf '%s' "$b") ;;
    esac
    bash_major "$b" >/dev/null || { err "--bash $b: not an executable bash"; exit 2; }
    BASHES="$BASHES $b"
  done
else
  BASHES=$(detect_bashes)
  [ -n "$BASHES" ] || { err "no bash interpreter found"; exit 2; }
fi

if [ -n "$NAMED" ]; then
  RUN="$NAMED"
elif [ "$FAST" = 1 ]; then
  RUN="$FAST_SUITES self-install check-version"
else
  RUN="$CHECKS"
fi

LOGS=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-check-ci.XXXXXX") || { err "mktemp failed"; exit 1; }
RESULTS=""
FAILED=0
record() { RESULTS="$RESULTS$1"$'\n'; }

# A check's own interpreter for the non-suite checks: the first one.
FIRST_BASH=$(printf '%s\n' $BASHES | head -n 1)

check_toolchain() {
  local rc=0 yaml
  for tool in jq git; do
    command -v "$tool" >/dev/null 2>&1 || { err "$tool not found"; rc=1; }
  done
  # The suites parse the CI templates as YAML (PyYAML, or ruby's psych:
  # macOS's image has no PyYAML), drive the OpenCode plugin under node, and
  # gate the shipped scripts on shellcheck.
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    yaml="python3 + PyYAML"
  elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
    yaml="ruby (psych)"
  else
    err "no YAML parser (need python3 with PyYAML, or ruby) — the workflow-template YAML assertions would not run"
    yaml=none rc=1
  fi
  command -v node >/dev/null 2>&1 || { err "node not found — the OpenCode plugin simulation would not run"; rc=1; }
  command -v shellcheck >/dev/null 2>&1 || { err "shellcheck not found — the shellcheck gate would not run"; rc=1; }
  echo "jq:         $(jq --version 2>/dev/null || echo missing)"
  echo "yaml:       $yaml"
  echo "node:       $(node --version 2>/dev/null || echo missing)"
  echo "shellcheck: $(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }' || true)"
  for b in $BASHES; do
    echo "bash:       $b — $("$b" --version | head -n 1)"
  done
  return "$rc"
}

# run_suite <name> <bash>
run_suite() {
  local s="$1" b="$2" log rc=0 line
  log="$LOGS/$s.$(printf '%s' "$b" | tr '/' '_').log"
  if [ "$VERBOSE" = 1 ]; then
    (cd "$ROOT" && BASH_BIN="$b" "$b" "scripts/test-$s.sh") 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  else
    echo "--- test-$s.sh under $b …"
    (cd "$ROOT" && BASH_BIN="$b" "$b" "scripts/test-$s.sh") > "$log" 2>&1 || rc=$?
  fi
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -a '^Results:' | tail -n 1)
  [ -n "$line" ] || line="(no result line: see $log)"
  if [ "$rc" = 0 ]; then
    record "PASS  test-$s.sh  [$b]  $line"
  else
    if [ "$VERBOSE" = 0 ]; then
      sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -a -A3 '^  FAIL' | head -n 60
    fi
    record "FAIL  test-$s.sh  [$b]  $line  (log: $log)"
    FAILED=1
  fi
}

# run_search: the doc-search pytest suite, once. pytest runs in search/, where
# its pytest.ini_options (testpaths) are found. uv missing is a FAIL, or a loud
# SKIP under DOC_SP_REQUIRE_UV=0.
run_search() {
  local name="search (pytest)" log="$LOGS/search.log" rc=0 line
  echo "--- $name"
  if ! command -v uv >/dev/null 2>&1; then
    if [ "$DOC_SP_REQUIRE_UV" = 0 ]; then
      echo "SKIP: uv not on PATH — the doc-search pytest suite did not run"
      record "SKIP  $name (no uv on PATH)"
    else
      err "uv not found — the doc-search pytest suite would not run (DOC_SP_REQUIRE_UV=0 accepts the SKIP)"
      record "FAIL  $name (no uv on PATH)"
      FAILED=1
    fi
    return 0
  fi
  if [ "$VERBOSE" = 1 ]; then
    (cd "$ROOT/search" && uv run --project "$ROOT/search" --frozen --all-extras pytest -q) 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  else
    (cd "$ROOT/search" && uv run --project "$ROOT/search" --frozen --all-extras pytest -q) > "$log" 2>&1 || rc=$?
  fi
  # pytest's closing line: "270 passed, 1 warning in 53.12s"
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '^[0-9]+ (passed|failed|error|skipped|deselected)|^no tests ran' | tail -n 1)
  [ -n "$line" ] || line="(no result line: see $log)"
  if [ "$rc" = 0 ]; then
    record "PASS  $name  $line"
  else
    if [ "$VERBOSE" = 0 ]; then
      sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '^(FAILED|ERROR) ' | head -n 60
    fi
    record "FAIL  $name  $line  (exit $rc, log: $log)"
    FAILED=1
  fi
}

# run_check <name> <command…>
run_check() {
  local name="$1" rc=0
  shift
  echo "--- $name"
  (cd "$ROOT" && "$@") || rc=$?
  if [ "$rc" = 0 ]; then
    record "PASS  $name"
  else
    record "FAIL  $name (exit $rc)"
    FAILED=1
  fi
}

for c in $RUN; do
  case "$c" in
    toolchain) run_check toolchain check_toolchain ;;
    self-install) run_check self-install env BASH_BIN="$FIRST_BASH" "$FIRST_BASH" scripts/check-self-install.sh ;;
    check-version) run_check check-version "$FIRST_BASH" scripts/doc-tools.sh check-version ;;
    search) run_search ;;
    tag)
      if [ -n "$NAMED" ]; then
        run_check tag "$FIRST_BASH" scripts/doc-tools.sh check-version --tag
      else
        run_check "tag (--warn)" "$FIRST_BASH" scripts/doc-tools.sh check-version --tag --warn
      fi
      ;;
    plugin-validate)
      if command -v claude >/dev/null 2>&1; then
        run_check plugin-validate claude plugin validate .
      else
        echo "--- plugin-validate"
        echo "SKIP: claude CLI not on PATH — claude plugin validate did not run"
        record "SKIP  plugin-validate (no claude CLI on PATH)"
      fi
      ;;
    *)
      for b in $BASHES; do run_suite "$c" "$b"; done
      ;;
  esac
done

echo ""
echo "================ check-ci summary ================"
printf '%s' "$RESULTS"
echo "=================================================="
if [ "$FAILED" = 0 ]; then
  rm -rf "$LOGS"
  echo "check-ci: all passed"
  exit 0
fi
echo "check-ci: FAILED (suite logs kept in $LOGS)"
exit 1

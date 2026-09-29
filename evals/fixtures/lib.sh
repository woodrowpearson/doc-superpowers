#!/usr/bin/env bash
# Shared helpers for the eval fixtures (evals/fixtures/<eval>/setup.sh).
#
# A setup builds, in the CURRENT directory (which must be empty), the project
# its eval's prompt describes: a git repository with the docs, index, code
# history and files the scenario needs. It ends by checking that the scenario
# holds, and exits 1 when it does not — so a fixture that drifts from its
# prompt fails loudly (scripts/test-spec-status-model.sh runs every setup).
#
# Environment:
#   DOC_SUPERPOWERS_ROOT  the plugin checkout (default: three levels above the
#                         setup script, i.e. this repository)
#   BASH_BIN              interpreter for doc-tools.sh / install.sh (default: bash)
#
# bash 3.2 compatible; git + jq + POSIX tools only.
set -euo pipefail

fx_die() {
  echo "fixture: $*" >&2
  exit 1
}

# fx_attach <setup script path>: resolve the plugin and pin a clean git
# identity, for a setup that extends another fixture's repository (it runs the
# other setup first, in the same empty directory).
fx_attach() {
  FX_ROOT=${DOC_SUPERPOWERS_ROOT:-$(cd "$(dirname "$1")/../../.." && pwd -P)}
  FX_BASH=${BASH_BIN:-bash}
  [ -f "$FX_ROOT/scripts/doc-tools.sh" ] || fx_die "no scripts/doc-tools.sh under $FX_ROOT"
  [ "$(pwd -P)" != "$(cd "$FX_ROOT" && pwd -P)" ] || fx_die "refusing to build a fixture inside the plugin checkout"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME=eval GIT_AUTHOR_EMAIL=eval@example.com \
    GIT_COMMITTER_NAME=eval GIT_COMMITTER_EMAIL=eval@example.com
}

# fx_init <setup script path>: fx_attach, refuse a non-empty directory, and
# create the repository.
fx_init() {
  fx_attach "$1"
  [ -z "$(ls -A . 2>/dev/null)" ] || fx_die "run from an empty directory ($(pwd -P) is not empty)"
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
}

# doc-tools.sh / install.sh of the plugin under test, under $BASH_BIN.
dt() { "$FX_BASH" "$FX_ROOT/scripts/doc-tools.sh" "$@"; }
fx_install() { "$FX_BASH" "$FX_ROOT/scripts/hooks/install.sh" "$@"; }

fx_commit() {
  git add -A
  git commit -qm "$1"
}

# fx_write <path>: write stdin to <path>, creating its directory.
fx_write() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

# fx_seal <fragment>: write the line-2 hash the doc-pr-release workflow writes
# (sha256 of the bytes from line 3 on; RELEASE-NOTES.next/README.md).
fx_seal() {
  local f="$1" h
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(tail -n +3 "$f" | sha256sum | cut -d' ' -f1)
  else
    h=$(tail -n +3 "$f" | shasum -a 256 | cut -d' ' -f1)
  fi
  { sed -n 1p "$f"; echo "<!-- doc-superpowers:hash $h -->"; tail -n +3 "$f"; } > "$f.tmp"
  mv "$f.tmp" "$f"
}

# fx_expect <what> <command...>: the scenario check.
fx_expect() {
  local what="$1"
  shift
  "$@" >/dev/null 2>&1 || fx_die "scenario does not hold: $what"
}

# fx_fresh <jq filter>: evaluate a filter over check-freshness output.
fx_fresh() { dt check-freshness 2>/dev/null | jq -r "$1"; }

# fx_release_base: a released CLI (v1.2.0, tagged) with three conventional
# commits since — feat, fix, docs — so the suggested bump is MINOR (v1.3.0).
fx_release_base() {
  fx_write package.json <<'JSON'
{
  "name": "csvtool",
  "version": "1.2.0"
}
JSON
  fx_write README.md <<'MD'
# csvtool

`csvtool parse <file>` prints a CSV file as a table.
MD
  fx_write src/cli.js <<'JS'
require('./parse');
JS
  fx_write src/parse.js <<'JS'
exports.parse = (text) => text.split('\n').map((l) => l.split(','));
JS
  fx_write RELEASE-NOTES.md <<'MD'
# Release Notes

## v1.2.0 (2026-08-01)

### Features
- **Table output**: `csvtool parse` prints a table.

### Fixes
- **Quoted fields**: commas inside quotes no longer split a field.
MD
  fx_commit "release: v1.2.0"
  git tag v1.2.0
  fx_write src/export.js <<'JS'
exports.toCsv = (rows) => rows.map((r) => r.join(',')).join('\n');
JS
  fx_commit "feat: add the export command"
  fx_write src/parse.js <<'JS'
exports.parse = (text) => (text ? text.split('\n').map((l) => l.split(',')) : []);
JS
  fx_commit "fix: handle empty input in the parser"
  printf '\nSee `csvtool --help`.\n' >> README.md
  fx_commit "docs: mention --help in the README"
}

#!/usr/bin/env bash
# check-self-install.sh — this repository's self-installed tiers are exactly
# what the installer writes today (#27: the body of tests.yml's "Self-installed
# CI tier matches its templates" step, moved here so CI and scripts/check-ci.sh
# run the same code). For this repository only: it is not shipped to a
# consuming project's .github/scripts/.
#
# This repository installs its own CI tier (scripts/hooks/install.sh install
# --ci), and nothing else notices those copies going stale: for months its
# freshness workflows called a .github/scripts/doc-tools.sh that was never
# committed. So every self-installed file must be exactly what the installer
# writes today: each workflow that .claude/doc-superpowers/installed.json
# records as installed, rendered from its template with the recorded choices
# (install.sh's render_workflow substitutions), and byte copies of
# doc-tools.sh and of the helpers — with every script a workflow runs present
# and executable. Plus the git tier's one committed piece, the .gitattributes
# merge-driver block. After changing a template, doc-tools.sh or a CI helper
# script, run `bash scripts/hooks/install.sh install --ci` and commit the
# result.
#
# Runs against the checkout it is in (the directory above scripts/), whatever
# the working directory. Each finding is a GitHub "::error file=…::" line;
# exits 1 on any. $BASH_BIN (default: this interpreter) runs doc-tools.sh;
# $RUNNER_TEMP (default: a private temp directory) holds the renders.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
BASH_BIN="${BASH_BIN:-${BASH:-bash}}"
if [ -n "${RUNNER_TEMP:-}" ]; then
  work=$(mktemp -d "$RUNNER_TEMP/self-install.XXXXXX")
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-self-install.XXXXXX")
fi
trap 'rm -rf "$work"' EXIT

state=.claude/doc-superpowers/installed.json
fail=0 git_fail=0
drift() { echo "::error file=$1::$2"; fail=1; }
esc() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
[ -f "$state" ] || { echo "::error::$state is missing"; exit 1; }
base=$(esc "$(jq -r '.tiers.ci.base_branch' "$state")")
cron=$(esc "$(jq -r '.tiers.ci.cron' "$state")")
strict=$(jq -r 'if .tiers.ci.ci_strict == true then 1 else 0 end' "$state")
installed=$(jq -r '.tiers.ci.workflows // {} | to_entries[] | select(.value.state == "installed") | .key' "$state")
[ -n "$installed" ] || drift "$state" "records no installed workflow"
version=""
for t in scripts/hooks/ci/*.yml; do
  w=$(basename "$t" .yml)
  f=.github/workflows/$w.yml
  if ! printf '%s\n' "$installed" | grep -qxF "$w"; then
    [ ! -e "$f" ] || drift "$f" "exists but $state does not record $w as installed"
    continue
  fi
  if [ -z "$version" ] && grep -q '__VERSION__' "$t"; then
    version=$(esc "v$("$BASH_BIN" scripts/doc-tools.sh tools version)")
  fi
  sed -e "s|__BASE_BRANCH__|$base|g" -e "s|__VERSION__|$version|g" \
    -e "s|__CRON_SCHEDULE__|$cron|g" -e "s|__CI_STRICT__|$strict|g" \
    "$t" > "$work/$w.rendered.yml"
  diff -u "$work/$w.rendered.yml" "$f" \
    || drift "$f" "differs from $t rendered with the choices in $state"
  for p in $(grep -oE '\.github/scripts/[A-Za-z0-9._/-]+\.sh' "$f" | sort -u || true); do
    [ -x "$p" ] || drift "$f" "runs $p, which is not vendored (or not executable)"
  done
  # On a ledger host (docs/ledger/config.json), the claims step's V5 reads
  # ledger trackers through the ledger set beside the vendored doc-tools.sh
  # (install --ci ships it there only).
  if [ -f docs/ledger/config.json ] \
    && grep -qF '.github/scripts/doc-superpowers-steps/claims-check.sh' "$f" \
    && [ ! -f .github/scripts/ledger/lib.sh ]; then
    drift "$f" "runs claims-check.sh without the vendored ledger helper set (.github/scripts/ledger/)"
  fi
done
# A doc-superpowers workflow with no template (a retired one, such as
# doc-index-update) is drift too, on disk or recorded in the state.
for f in .github/workflows/*.yml; do
  [ -f "$f" ] || continue
  w=$(basename "$f" .yml)
  [ ! -f "scripts/hooks/ci/$w.yml" ] || continue
  # (awk, not head | grep -q: pipefail would read a SIGPIPE as no match)
  ! awk 'NR <= 5 && /doc-superpowers workflow v[0-9]/ { m = 1 } END { exit !m }' "$f" \
    || drift "$f" "is a doc-superpowers workflow with no template (retired): install --ci removes it"
done
for w in $installed; do
  [ -f "scripts/hooks/ci/$w.yml" ] || drift "$state" "records $w as installed, but it has no template (retired)"
done
cmp scripts/doc-tools.sh .github/scripts/doc-tools.sh \
  || drift .github/scripts/doc-tools.sh "differs from scripts/doc-tools.sh"
[ -x .github/scripts/doc-tools.sh ] || drift .github/scripts/doc-tools.sh "is not executable"
# Each vendored directory against its source: the CI helpers'
# scripts/hooks/ci/<dir>/*.sh, and the ledger helper set's scripts/ledger/
# (*.sh, *.awk, *.jq) and scripts/adapters/*.sh. Scripts must be executable;
# the awk and jq programs are data.
for d in .github/scripts/*/; do
  [ -d "$d" ] || continue
  d=$(basename "$d")
  case "$d" in
    ledger | adapters) src=scripts/$d ;;
    *) src=scripts/hooks/ci/$d ;;
  esac
  for f in ".github/scripts/$d"/*; do
    p="$src/$(basename "$f")"
    if [ ! -f "$p" ]; then
      drift "$f" "is not a plugin helper (no $p)"
      continue
    fi
    cmp "$p" "$f" || drift "$f" "differs from $p"
    case "$f" in
      *.sh) [ -x "$f" ] || drift "$f" "is not executable" ;;
    esac
  done
  for p in "$src"/*.sh "$src"/*.awk "$src"/*.jq; do
    [ -f "$p" ] || continue
    [ -e ".github/scripts/$d/$(basename "$p")" ] \
      || drift ".github/scripts/$d" "lacks $(basename "$p") (a partial helper install)"
  done
done
# The git tier's one committed piece: the index merge-driver attribute.
if [ "$(git check-attr merge -- docs/.doc-index.json)" != "docs/.doc-index.json: merge: doc-index" ]; then
  echo "::error file=.gitattributes::does not route docs/.doc-index.json to the doc-index merge driver"
  git_fail=1
fi
[ "$fail" = 0 ] \
  || echo "::error::the self-installed CI tier drifted: run bash scripts/hooks/install.sh install --ci and commit the result"
[ "$git_fail" = 0 ] \
  || echo "::error::the .gitattributes merge-driver block is missing: run bash scripts/hooks/install.sh install --git and commit .gitattributes"
[ "$fail" = 0 ] && [ "$git_fail" = 0 ] || exit 1
# shellcheck disable=SC2086  # the workflow names, one word each
echo "Self-installed CI tier matches its templates:" $installed

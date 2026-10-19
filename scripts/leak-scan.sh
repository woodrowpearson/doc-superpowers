#!/usr/bin/env bash
# leak-scan.sh — scan a repository's tracked files for leaks (#29): machine
# paths, personal emails and token-shaped strings. The marketplace installs
# this repository whole (`source: "./"`), so every tracked file ships to every
# install. test-spec-status-model.sh runs it over this checkout, so CI and
# scripts/check-ci.sh do too.
#
# Usage: scripts/leak-scan.sh [<repository>]   (default: this script's checkout)
#
# What is a finding (the working-tree contents of `git ls-files`, binary
# files skipped):
#   home-path  /Users/<name> or /home/<name> starting a path (not "$x/home/…").
#              Placeholder names are fine: me, you, user, username, name,
#              example, alice, bob, jane, john, someone, runner (GitHub's
#              runner home), ubuntu, linuxbrew (Homebrew on Linux).
#   volume     /Volumes/<name> (a machine's mounted disk or worktree volume).
#   email      an address, unless its domain is reserved for examples
#              (example.com/.org/.net, *.example, *.invalid, *.test,
#              *.localhost), a test fixture's (test.com, t.com), or GitHub's
#              noreply (users.noreply.github.com); noreply@anthropic.com (the
#              co-author trailer) and git@github.com (an SSH remote) are fine.
#   token      a GitHub token (ghp_/gho_/ghu_/ghs_/ghr_ + 36, github_pat_…),
#              an Anthropic key (sk-ant-…), an OpenAI-style key (sk-… / sk-proj-…),
#              an AWS access key id (AKIA/ASIA + 16), a Slack token (xox?-…),
#              a Google API key (AIza + 35), a GitLab token (glpat-…), an npm
#              token (npm_ + 36), a PEM private key header.
#
# Allowlist — historical records keep the machine paths they recorded
# (home-path and volume only; an email or a token is a finding everywhere):
#   docs/archive/, docs/superpowers/ (design specs and plans), and the dated
#   records docs/plans/YYYY-MM-DD-*.md and docs/issues/YYYY-MM-DD-*.md.
# A line holding the marker "leak-scan:allow" is skipped (say why beside it).
#
# Prints "<file>:<line>: <class>: <match>" per finding. Exit 0: none; 1:
# findings; 2: not a git work tree.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ $# -le 1 ] || { echo "usage: leak-scan.sh [<repository>]" >&2; exit 2; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: leak-scan.sh: $repo is not a git work tree" >&2; exit 2; }

RECORDS=(
  ':(exclude)docs/archive'
  ':(exclude)docs/superpowers'
  ':(exclude,glob)docs/plans/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*'
  ':(exclude,glob)docs/issues/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*'
)
# A path segment starts the match: not after a name character, "$", "}" or "/".
LEAD='(^|[^A-Za-z0-9_.$}/-])'
TOKENS='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|(AKIA|ASIA)[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-leak-scan.XXXXXX")
trap 'rm -rf "$work"' EXIT

# _grep <class> <ERE> [<pathspec>…]: every match, as "<class>\t<file>:<line>:<match>".
_grep() {
  local class="$1" re="$2" rc=0
  shift 2
  git -C "$repo" -c core.quotePath=false grep -nIoE -e "$re" -- "$@" > "$work/m" 2>"$work/err" || rc=$?
  [ "$rc" -le 1 ] || { echo "ERROR: leak-scan.sh: git grep failed: $(cat "$work/err")" >&2; exit 2; }
  awk -v c="$class" '{ print c "\t" $0 }' "$work/m"
}

{
  _grep home-path "$LEAD/(Users|home)/[A-Za-z0-9._-]+" "${RECORDS[@]}"
  _grep volume "$LEAD/Volumes/[A-Za-z0-9._-]+" "${RECORDS[@]}"
  _grep email '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
  _grep token "$TOKENS"
} > "$work/all"
rc=0
git -C "$repo" -c core.quotePath=false grep -nIF -e 'leak-scan:allow' > "$work/allow" 2>/dev/null || rc=$?
[ "$rc" -le 1 ] || { echo "ERROR: leak-scan.sh: git grep failed" >&2; exit 2; }

# shellcheck disable=SC2016  # awk program
awk -F '\t' -v allowf="$work/allow" '
  BEGIN {
    while ((getline l < allowf) > 0) {
      # "<file>:<line>:<text>": keep "<file>:<line>"
      if (match(l, /^[^:]*:[0-9]+:/)) ok[substr(l, 1, RLENGTH - 1)] = 1
    }
    split("me you user username name example alice bob jane john someone runner ubuntu linuxbrew", p, " ")
    for (i in p) placeholder[p[i]] = 1
  }
  {
    cls = $1; rec = $2
    if (!match(rec, /^[^:]*:[0-9]+:/)) next
    where = substr(rec, 1, RLENGTH - 1); m = substr(rec, RLENGTH + 1)
    if (where in ok) next
    if (cls == "home-path" || cls == "volume") {
      sub(/^[^\/]/, "", m)                      # the leading character LEAD took
      if (cls == "home-path") {
        n = split(m, seg, "/")                  # "", Users|home, <name>
        if (seg[3] in placeholder) next
      }
    } else if (cls == "email") {
      a = tolower(m); d = a; sub(/^[^@]*@/, "", d)
      if (a == "noreply@anthropic.com" || a == "git@github.com") next
      if (d ~ /^example\.(com|org|net)$/ || d ~ /\.(example|invalid|test|localhost)$/) next
      if (d == "test.com" || d == "t.com" || d == "users.noreply.github.com" || d ~ /\.users\.noreply\.github\.com$/) next
    }
    print where ": " cls ": " m
    n_found++
  }
  END { exit n_found > 0 }' "$work/all" > "$work/found" || {
  cat "$work/found"
  echo "leak-scan: $(wc -l < "$work/found" | tr -d ' ') finding(s) in tracked files (allowlist and the leak-scan:allow marker: see scripts/leak-scan.sh)"
  exit 1
}
echo "leak-scan: no findings in $(git -C "$repo" ls-files | wc -l | tr -d ' ') tracked files"

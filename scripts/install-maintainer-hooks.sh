#!/usr/bin/env bash
# install-maintainer-hooks.sh — the opt-in maintainer pre-push hook for THIS
# repository (#27): before a push, run `scripts/check-ci.sh --fast`, the quick
# part of what CI runs, and refuse the push when it fails. Not the hooks
# installer's (scripts/hooks/install.sh installs doc-superpowers' tiers into
# any project); this one is for contributors to doc-superpowers itself.
#
# Usage: scripts/install-maintainer-hooks.sh [install | uninstall | status]
#
# The hook is a marked block in pre-push, where git runs it (`git rev-parse
# --git-path hooks`; one per clone, shared by its worktrees). It reads nothing
# from stdin (check-ci.sh gets /dev/null), so whatever else the hook runs still
# reads git's ref lines:
#   - no pre-push hook: one is written, #!/bin/sh and the block;
#   - a pre-push shell script of yours: the block goes right after its #! line
#     (before anything of yours can exit);
#   - the doc-superpowers git tier's own pre-push (install.sh install --git,
#     whole-file): refused, since a re-install of that tier rewrites the file.
#     Uninstall the tier, install this, then install the tier again: it then
#     integrates its block into this hook, and both run;
#   - a hook in another language: refused.
# Re-running install replaces the block; uninstall removes it (and the file,
# when nothing but the #! line would be left).
#
# git push --no-verify skips every pre-push hook; DOC_SP_SKIP_CHECK_CI=1 skips
# this one alone.
set -euo pipefail

BEGIN="# doc-superpowers-maintainer:begin"
END="# doc-superpowers-maintainer:end"

die() { echo "ERROR: $*" >&2; exit 1; }

cmd="${1:-install}"
[ $# -le 1 ] || die "takes one command (install, uninstall or status)"
case "$cmd" in
  install | uninstall | status) ;;
  -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  *) echo "ERROR: unknown command '$cmd' (install, uninstall or status)" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout"
# A core.hooksPath from the global or system config serves every repository:
# this repository's hook does not belong there.
scope=$(git config --show-scope --get core.hooksPath 2>/dev/null | awk '{ print $1 }' || true)
case "$scope" in
  "" | local | worktree) ;;
  *) die "core.hooksPath is set in your $scope git config ($(git config --get core.hooksPath)): a hook there would run in every repository. Set a repository-local one, or unset it, then re-run." ;;
esac
HOOKS_DIR=$(git rev-parse --git-path hooks)
HOOK="$HOOKS_DIR/pre-push"

block() {
  cat <<'BLOCK'
# doc-superpowers-maintainer:begin (scripts/install-maintainer-hooks.sh; its uninstall removes this block)
# The quick part of CI (scripts/check-ci.sh --fast) before every push.
# DOC_SP_SKIP_CHECK_CI=1 skips it; git push --no-verify skips every pre-push hook.
if [ "${DOC_SP_SKIP_CHECK_CI:-}" = 1 ]; then
  echo "maintainer pre-push: check-ci skipped (DOC_SP_SKIP_CHECK_CI=1)" >&2
elif DOC_SP_MT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$DOC_SP_MT_ROOT/scripts/check-ci.sh" ]; then
  echo "maintainer pre-push: scripts/check-ci.sh --fast (DOC_SP_SKIP_CHECK_CI=1 skips it)" >&2
  if ! bash "$DOC_SP_MT_ROOT/scripts/check-ci.sh" --fast </dev/null >&2; then
    echo "maintainer pre-push: push refused: scripts/check-ci.sh --fast failed" >&2
    exit 1
  fi
else
  echo "maintainer pre-push: no scripts/check-ci.sh in this checkout: skipped" >&2
fi
# doc-superpowers-maintainer:end
BLOCK
}

has_block() { [ -f "$1" ] && grep -qF "$BEGIN" "$1"; }

# <file> without our block, on stdout.
strip_block() {
  awk -v b="$BEGIN" -v e="$END" '
    index($0, b) == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }' "$1"
}

# Whether <file> is a shell script (git runs a hook without #! with sh).
is_shell() {
  local first w1 w2
  IFS= read -r first < "$1" || true
  case "$first" in
    '#!'*) ;;
    *) return 0 ;;
  esac
  read -r w1 w2 _ <<<"${first#\#!}"
  [ "${w1##*/}" != env ] || w1="$w2"
  case "${w1##*/}" in
    sh | bash | dash | zsh | ksh | ash) return 0 ;;
  esac
  return 1
}

# The git tier's whole-file hook (install.sh: is_our_hook).
is_tier_hook() { awk 'NR <= 5 && index($0, "doc-superpowers hook v") { m = 1 } END { exit !m }' "$1"; }

# Write <content-file> to the hook: an existing hook keeps its mode, a new
# one is 755.
commit_hook() {
  local tmp
  tmp=$(mktemp "$HOOKS_DIR/.pre-push.XXXXXX")
  if [ -f "$HOOK" ]; then
    cp -p "$HOOK" "$tmp"
    cat "$1" > "$tmp"
  else
    cat "$1" > "$tmp"
    chmod 755 "$tmp"
  fi
  mv -f "$tmp" "$HOOK"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-mt-hooks.XXXXXX")
trap 'rm -rf "$work"' EXIT

case "$cmd" in
  status)
    if has_block "$HOOK"; then
      if [ "$(awk -v b="$BEGIN" -v e="$END" 'index($0, b) == 1 { p = 1 } p { print } p && index($0, e) == 1 { exit }' "$HOOK")" = "$(block)" ]; then
        echo "maintainer pre-push: installed ($HOOK)"
      else
        echo "maintainer pre-push: outdated ($HOOK): re-run scripts/install-maintainer-hooks.sh install"
      fi
    else
      echo "maintainer pre-push: not installed ($HOOK)"
    fi
    ;;
  install)
    mkdir -p "$HOOKS_DIR"
    if [ ! -e "$HOOK" ]; then
      { echo '#!/bin/sh'; block; } > "$work/hook"
      commit_hook "$work/hook"
      echo "Installed the maintainer pre-push hook: $HOOK"
      exit 0
    fi
    [ -f "$HOOK" ] && [ ! -L "$HOOK" ] || die "$HOOK is not a regular file: nothing was changed"
    if is_tier_hook "$HOOK"; then
      die "$HOOK is the doc-superpowers git tier's own pre-push hook (install.sh install --git), which a re-install of that tier rewrites whole. To run both: bash scripts/hooks/install.sh uninstall --git, then scripts/install-maintainer-hooks.sh install, then bash scripts/hooks/install.sh install --git (it integrates its block into this hook). Nothing was changed."
    fi
    is_shell "$HOOK" || die "$HOOK is not a shell script, so no block can go into it: run scripts/check-ci.sh --fast from it yourself. Nothing was changed."
    strip_block "$HOOK" > "$work/rest"
    {
      if IFS= read -r line; then
        case "$line" in
          '#!'*) printf '%s\n' "$line"; block ;;
          *) block; printf '%s\n' "$line" ;;
        esac
        cat
      else
        echo '#!/bin/sh'
        block
      fi
    } < "$work/rest" > "$work/hook"
    commit_hook "$work/hook"
    echo "Installed the maintainer pre-push hook into your existing $HOOK (a marked block after its #! line)"
    ;;
  uninstall)
    if ! has_block "$HOOK"; then
      echo "maintainer pre-push: not installed ($HOOK): nothing to remove"
      exit 0
    fi
    strip_block "$HOOK" > "$work/rest"
    if [ -z "$(grep -v '^#!' "$work/rest" | tr -d '[:space:]')" ]; then
      rm -f "$HOOK"
      echo "Removed the maintainer pre-push hook ($HOOK)"
    else
      commit_hook "$work/rest"
      echo "Removed the maintainer block from $HOOK (the rest of the hook is kept)"
    fi
    ;;
esac

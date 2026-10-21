#!/bin/sh
# doc-search launcher (POSIX sh): runs the doc-search CLI / MCP server through
# uv, from wherever doc-superpowers is installed.
#
#   sh .claude/doc-superpowers/search-mcp.sh serve     (what .mcp.json runs)
#
# install.sh install --search copies this file to
# .claude/doc-superpowers/search-mcp.sh and registers it in .mcp.json. The copy
# holds no machine path: the doc-superpowers root is found at run time, in this
# order:
#   1. $DOC_SUPERPOWERS_ROOT, when it has search/pyproject.toml
#   2. the repository this is run in, when it is doc-superpowers itself
#      (search/pyproject.toml and scripts/doc-tools.sh)
#   3. the newest numeric X.Y.Z directory under
#      ${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}/*/doc-superpowers/
#      that has search/pyproject.toml
#
# Extras: --extra cloud when docs/search/config.json (at the repository top)
# has a non-null "cloud"; --extra local-transformer (after cloud) when its
# docs.model is a string starting "transformer:"; none otherwise. Without jq
# the config cannot be parsed: --all-extras --no-extra local-transformer
# (onnxruntime has no wheel for older macOS or glibc, so a static config must
# not need it), or --all-extras when grep finds a "model" key whose value
# starts "transformer:". --no-dev: the dev group (pytest) is never installed
# for a user.
#
# Failures are one stderr line and exit 2.

fail() {
  echo "doc-search: $*" >&2
  exit 2
}

# The repository top (empty outside a repository): where the config lives.
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""

ROOT=""
if [ -n "${DOC_SUPERPOWERS_ROOT:-}" ] && [ -f "$DOC_SUPERPOWERS_ROOT/search/pyproject.toml" ]; then
  ROOT=$DOC_SUPERPOWERS_ROOT
fi

if [ -z "$ROOT" ] && [ -n "$TOP" ] && [ -f "$TOP/search/pyproject.toml" ] && [ -f "$TOP/scripts/doc-tools.sh" ]; then
  ROOT=$TOP
fi

if [ -z "$ROOT" ]; then
  CACHE=${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}
  # One "<version> <dir>" line per candidate, across every marketplace.
  CANDIDATES=""
  for dir in "$CACHE"/*/doc-superpowers/*; do
    [ -f "$dir/search/pyproject.toml" ] || continue
    version=${dir##*/}
    printf '%s\n' "$version" | grep -Ex "[0-9]+[.][0-9]+[.][0-9]+" >/dev/null 2>&1 || continue
    CANDIDATES="$CANDIDATES$version $dir
"
  done
  if [ -n "$CANDIDATES" ]; then
    ROOT=$(printf '%s' "$CANDIDATES" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f2-)
  fi
fi

[ -n "$ROOT" ] || fail "cannot find doc-superpowers (set DOC_SUPERPOWERS_ROOT)"
command -v uv >/dev/null 2>&1 || fail "uv not found (https://docs.astral.sh/uv/)"

EXTRAS=""
if command -v jq >/dev/null 2>&1; then
  if jq -e '.cloud != null' "${TOP:-.}/docs/search/config.json" >/dev/null 2>&1; then
    EXTRAS="--extra cloud"
  fi
  if jq -e '(.docs.model | type) == "string" and (.docs.model | startswith("transformer:"))' "${TOP:-.}/docs/search/config.json" >/dev/null 2>&1; then
    EXTRAS="${EXTRAS:+$EXTRAS }--extra local-transformer"
  fi
elif grep -Eq '"model"[^",]*:[^",]*"transformer:' "${TOP:-.}/docs/search/config.json" 2>/dev/null; then
  EXTRAS="--all-extras"
else
  EXTRAS="--all-extras --no-extra local-transformer"
fi

# shellcheck disable=SC2086  # $EXTRAS is a fixed flag list: empty, up to two --extra pairs, or --all-extras [--no-extra local-transformer]
exec uv run --project "$ROOT/search" --frozen --no-dev $EXTRAS doc-search "$@"

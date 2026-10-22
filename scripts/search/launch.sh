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
# has a non-null "cloud"; --all-extras when jq is missing, since the config
# cannot be read then; none otherwise. --no-dev: the dev group (pytest) is
# never installed for a user.
#
# The per-user env hook: a POSIX sh file sourced before anything else, so the
# variables it sets reach doc-search and the launcher itself (SEMBLE_CACHE_LOCATION,
# DOC_SEARCH_CACHE_LOCATION, HF_HOME, PATH, DOC_SUPERPOWERS_ROOT, …). It is read
# at every launch, so it can decide them then: a cache on a volume that is not
# always mounted, say. An MCP client starts the server without the user's shell
# profile, so this is where such a choice reaches it. $DOC_SEARCH_ENV_FILE names
# the file (empty is unset), else ${XDG_CONFIG_HOME:-$HOME/.config}/doc-search/env.sh.
# A missing file is skipped; one that does not parse is skipped with one stderr
# line, so a broken hook never keeps doc-search from starting. Its output goes
# to stderr (stdout is the MCP stream). It runs in this shell: it should only
# set variables, and an `exit` in it ends the launcher.
#
# Failures are one stderr line and exit 2.

fail() {
  echo "doc-search: $*" >&2
  exit 2
}

ENV_HOOK=${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/doc-search/env.sh}
case $ENV_HOOK in
  */*) ;;
  *) ENV_HOOK=./$ENV_HOOK ;; # `.` searches PATH for a bare name
esac
if [ -f "$ENV_HOOK" ] && [ -r "$ENV_HOOK" ]; then
  if sh -n "$ENV_HOOK" 2>/dev/null; then
    . "$ENV_HOOK" >&2
  else
    echo "doc-search: ignoring the env hook $ENV_HOOK (it does not parse)" >&2
  fi
fi

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
else
  EXTRAS="--all-extras"
fi

# shellcheck disable=SC2086  # $EXTRAS is a fixed flag list, empty or one or two words
exec uv run --project "$ROOT/search" --frozen --no-dev $EXTRAS doc-search "$@"

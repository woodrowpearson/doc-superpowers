#!/usr/bin/env bash
# The AI templates' step before the agent: the doc-superpowers plugin
# marketplace checked out at exactly the version the installer rendered, the
# HEAD the agent starts from, and a snapshot of the commit checker.
#
# claude-code-action's plugin_marketplaces input takes a local path as it is
# (a Git URL must end in .git, so it cannot name a tag); the workflow hands it
# this checkout, and `plugins: doc-superpowers@doc-superpowers` installs the
# skill from it. Without the plugin, the agent has no /doc-superpowers.
#
# Env:
#   DOC_SUPERPOWERS_VERSION          vX.Y.Z — the workflow's env, rendered by
#                                    the installer from its own version
#   DOC_SUPERPOWERS_MARKETPLACE_URL  default https://github.com/woodrowpearson/doc-superpowers.git
#   RUNNER_TEMP, GITHUB_OUTPUT       set by the runner
#
# The agent edits files in the checkout, and a mistake could reach the
# checker's own copy (.github/scripts/doc-superpowers-steps/commit-changes.sh).
# So this step copies the checker, as it is before the agent runs, to
# $RUNNER_TEMP/doc-superpowers-steps/commit-changes.sh (read-only, outside the
# workspace), and the commit step runs that copy. It is an integrity check
# against agent mistakes, not a sandbox: a steered agent can run code through
# its granted tools, read the job's secrets from its environment, and use the
# job token with every permission `permissions:` grants, repository-wide (the
# doc-superpowers references/hooks.md, "What an AI job's agent can reach").
#
# Outputs: marketplace=<absolute directory>; head=<the checkout's HEAD> (the
# commit step checks the agent left it there); checker=<the checker snapshot>.
#
# Exit codes: 0; 1 (with an ::error::) when the version is not a release, its
# tag cannot be fetched, or the manifests at the tag name another version.
set -euo pipefail

VERSION="${DOC_SUPERPOWERS_VERSION:-}"
URL="${DOC_SUPERPOWERS_MARKETPLACE_URL:-https://github.com/woodrowpearson/doc-superpowers.git}"

err() {
  echo "::error::doc-superpowers: $*"
  exit 1
}

[ -n "${GITHUB_OUTPUT:-}" ] || err "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)"
if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
  err "RUNNER_TEMP is not a directory"
fi
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err "DOC_SUPERPOWERS_VERSION is '$VERSION', not a released vX.Y.Z: the installer that rendered this workflow could not read its plugin version. Re-run 'install --ci' from a released doc-superpowers plugin."
fi
head=$(git rev-parse --verify HEAD 2>/dev/null) || err "no checkout here (git rev-parse HEAD failed)"

dir=$(mktemp -d "$RUNNER_TEMP/doc-superpowers-plugin.XXXXXX") || err "cannot create a directory under $RUNNER_TEMP"
mp="$dir/marketplace"
case "$mp" in
  /*) ;;
  *) mp="$PWD/$mp" ;;
esac
if ! git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$VERSION" -- "$URL" "$mp"; then
  err "cannot fetch doc-superpowers $VERSION from $URL (is the tag $VERSION published there?)"
fi
[ -f "$mp/.claude-plugin/marketplace.json" ] || err "$URL at $VERSION has no .claude-plugin/marketplace.json"
found=$(jq -r '.version // ""' "$mp/.claude-plugin/plugin.json" 2>/dev/null) || found=""
[ "v$found" = "$VERSION" ] || err "$URL at tag $VERSION holds plugin version '${found:-none}', not ${VERSION#v}"

src="$(dirname "$0")/commit-changes.sh"
checker="$RUNNER_TEMP/doc-superpowers-steps/commit-changes.sh"
case "$checker" in
  /*) ;;
  *) checker="$PWD/$checker" ;;
esac
[ -f "$src" ] || err "the commit checker $src is missing (re-run the doc-superpowers installer: install --ci)"
mkdir -p "${checker%/*}" && rm -f "$checker" && cp "$src" "$checker" && chmod 0555 "$checker" \
  || err "cannot snapshot the commit checker to $checker"

printf 'marketplace=%s\nhead=%s\nchecker=%s\n' "$mp" "$head" "$checker" >> "$GITHUB_OUTPUT"
echo "doc-superpowers $VERSION marketplace at $mp; the agent starts from $head."

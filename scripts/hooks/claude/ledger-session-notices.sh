#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code SessionStart hook (work ledger)
# DO NOT EDIT — managed by doc-superpowers hooks installer (install.sh install --ledger-claude)
#
# At session start: the in-flight notices that ask for action — stop and
# heads-up, unacked — for the session's branch. A thin wrapper over
# `doc-tools.sh ledger notices --hook` (the stable entry point a host may
# register in its own .claude/settings.json instead): that verb runs offline
# (DOC_TOOLS_LEDGER_OFFLINE=1: no --fetch, and no fetch when the remote
# cache's TTL has run out — the in-flight refs and branch facts already here
# serve) and prints ONE JSON object, as systemMessage (the user) and
# additionalContext (Claude): a count line, then the notices, held to 15
# lines in all, the rest counted with the command for the full list, and to
# the character bound. info notices are left to `ledger notices`. None:
# nothing printed. What this wrapper adds: the check gets BUDGET (2) seconds
# (hook-lib.sh _bounded) — past that it is killed, with everything it
# started, and one line says so — and the early exits: with in-flight
# awareness off (config inflight.enabled, false by default) there are no
# notices, and doc-tools.sh is not run; silent without
# docs/ledger/config.json, doc-tools.sh or jq. Always exits 0.
# DOC_SUPERPOWERS_LEDGER_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_LEDGER_SKIP:-}" == "1" ]] && exit 0

HOOK_EVENT=SessionStart
BUDGET=2
# The shared library beside this script, as an absolute path: the cd below
# would break a relative one.
case "${BASH_SOURCE[0]}" in
  /*) _lib="${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  */*) _lib="$PWD/${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  *) _lib="$PWD/hook-lib.sh" ;;
esac

# The SessionStart event, kept for the verb (a terminal on stdin is not
# waited on), so the writer never blocks.
payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
[[ -f docs/ledger/config.json ]] || exit 0
[[ -n "${DOC_TOOLS:-}" ]] || DOC_TOOLS=$(__DOC_TOOLS_RESOLVE__)
[[ -f "$DOC_TOOLS" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
have_jq=1
# In-flight awareness off (the default; the host's value replaces it): no
# notices, nothing to run.
jq -e '.inflight.enabled == true' docs/ledger/config.json >/dev/null 2>&1 || exit 0

# shellcheck source=scripts/hooks/claude/hook-lib.sh
if ! . "$_lib" 2>/dev/null; then
  printf '%s\n' '{"systemMessage":"doc-superpowers: hook-lib.sh is missing beside the ledger-session-notices hook, so it cannot report; re-run install.sh install --ledger-claude"}'
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-ledger-start.XXXXXX") || exit 0
trap 'rm -rf "$work"' EXIT
printf '%s' "$payload" > "$work/event" || exit 0

# shellcheck disable=SC2329  # run by _bounded
_notices() {
  DOC_TOOLS_LEDGER_OFFLINE=1 "$DOC_TOOLS" ledger notices --hook < "$work/event"
}

rc=0
_bounded _notices || rc=$?
if [[ "$rc" == 124 ]]; then
  _emit "ledger: in-flight notices skipped (budget): doc-tools.sh ledger notices took longer than ${BUDGET}s (run it to see them)"
  exit 0
fi
if [[ "$rc" != 0 ]]; then
  # The verb always exits 0: a doc-tools.sh that is not the ledger's.
  why=$(_why)
  _emit "ledger: cannot list the in-flight notices: ${why:-doc-tools.sh ledger notices --hook exited $rc} (run doc-tools.sh ledger notices)"
  exit 0
fi
cat "$work/out" 2>/dev/null
exit 0

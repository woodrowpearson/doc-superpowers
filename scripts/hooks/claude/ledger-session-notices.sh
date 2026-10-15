#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code SessionStart hook (work ledger)
# DO NOT EDIT — managed by doc-superpowers hooks installer (install.sh install --ledger-claude)
#
# At session start: the in-flight notices that ask for action — stop and
# heads-up, unacked — for the session's branch, from `doc-tools.sh ledger
# notices` run offline (DOC_TOOLS_LEDGER_OFFLINE=1: no --fetch, and no fetch
# when the remote cache's TTL has run out — the in-flight refs and branch
# facts already here serve). They go out in ONE JSON object on stdout, as
# systemMessage (the user) and additionalContext (Claude): a count line, then
# the notices, held to HOOK_LINES_MAX (15) lines in all, the rest counted
# with the command for the full list, and to the character bound (hook-lib.sh
# _clip). info notices are left to `ledger notices`. None: nothing printed.
# The check gets BUDGET (2) seconds (hook-lib.sh _bounded): past that it is
# killed, with everything it started, and one line says so; a check that
# fails says so in one line. With in-flight awareness off (config
# inflight.enabled, false by default) there are no notices: silent, and
# doc-tools.sh is not run. Silent without docs/ledger/config.json,
# doc-tools.sh or jq. Always exits 0. DOC_SUPERPOWERS_LEDGER_SKIP=1 turns it
# off.

[[ "${DOC_SUPERPOWERS_LEDGER_SKIP:-}" == "1" ]] && exit 0

# The SessionStart event on stdin is not needed; drain it so the writer never
# blocks. A terminal on stdin is not waited on.
[ -t 0 ] || cat >/dev/null 2>&1

HOOK_EVENT=SessionStart
BUDGET=2
# The shared library beside this script, as an absolute path: the cd below
# would break a relative one.
case "${BASH_SOURCE[0]}" in
  /*) _lib="${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  */*) _lib="$PWD/${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  *) _lib="$PWD/hook-lib.sh" ;;
esac

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
# The pointer every cut list ends with (hook-lib.sh's names check-freshness).
HOOK_FULL_LIST="run 'doc-tools.sh ledger notices' for the full list"

work=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-ledger-start.XXXXXX") || exit 0
trap 'rm -rf "$work"' EXIT

# shellcheck disable=SC2329  # run by _bounded
_notices() {
  DOC_TOOLS_LEDGER_OFFLINE=1 "$DOC_TOOLS" ledger notices
}

rc=0
_bounded _notices || rc=$?
if [[ "$rc" == 124 ]]; then
  _emit "ledger: in-flight notices skipped (budget): doc-tools.sh ledger notices took longer than ${BUDGET}s (run it to see them)"
  exit 0
fi
if [[ "$rc" != 0 ]]; then
  why=$(_why)
  _emit "ledger: cannot list the in-flight notices: ${why:-doc-tools.sh ledger notices exited $rc} (run doc-tools.sh ledger notices)"
  exit 0
fi

# One line per notice, "<urgency> <id> …": stop first, then heads-up.
nstop=$(grep -c '^stop ' "$work/out" 2>/dev/null) || nstop=0
nhead=$(grep -c '^heads-up ' "$work/out" 2>/dev/null) || nhead=0
n=$((nstop + nhead))
[[ "$n" -gt 0 ]] || exit 0
# The count line, then at most HOOK_LINES_MAX - 1 lines: past that, the first
# HOOK_LINES_MAX - 2 and "…and M more".
keep=$((HOOK_LINES_MAX - 1))
if [[ "$n" -gt "$keep" ]]; then
  keep=$((keep - 1))
fi
body=$({ grep '^stop ' "$work/out"; grep '^heads-up ' "$work/out"; } 2>/dev/null | head -n "$keep")
if [[ "$n" -gt "$keep" ]]; then
  body="$body
  …and $((n - keep)) more ($HOOK_FULL_LIST)"
fi
msg="ledger: $n in-flight notice(s) on this branch ($nstop stop, $nhead heads-up): act on each before the next chunk, or ack one with a commit trailer 'Ledger-Ack: <id> — <clause>'
$body"
msg=$(_clip "$msg")
_emit "$msg" "$msg"
exit 0

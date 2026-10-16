#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code PostToolUse (Write|Edit) hook (work ledger)
# DO NOT EDIT — managed by doc-superpowers hooks installer (install.sh install --ledger-claude)
#
# `doc-tools.sh ledger note` is the one home for an item's state. When Claude
# writes a file under one of config state_watch.paths (the host's agent-memory
# and scratch directories) and what it wrote — Write's content, Edit's
# new_string — names an item key and holds one of state_watch.patterns, one
# advisory line (additionalContext, for Claude) suggests `doc-tools.sh ledger
# note <key> "…"` instead.
#
# A thin wrapper over `doc-tools.sh ledger state-watch --hook` (the stable
# entry point a host may register in its own .claude/settings.json instead),
# which reads the event on stdin, applies state_watch.paths / patterns and
# prints ONE JSON object or nothing (its --help: the path rules). What this
# wrapper adds: the early exits — silent without docs/ledger/config.json,
# doc-tools.sh or jq, and with no state_watch.paths (nothing can match:
# doc-tools.sh is not run).
#
# Advisory only: always exits 0 and never blocks.
# DOC_SUPERPOWERS_LEDGER_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_LEDGER_SKIP:-}" == "1" ]] && exit 0

# The event, read before the cd (a terminal on stdin is not waited on).
payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
[[ -f docs/ledger/config.json ]] || exit 0
[[ -n "${DOC_TOOLS:-}" ]] || DOC_TOOLS=$(__DOC_TOOLS_RESOLVE__)
[[ -f "$DOC_TOOLS" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# No state_watch.paths: no write can match, nothing to run.
jq -e '(.state_watch | objects | .paths | arrays | length) > 0' docs/ledger/config.json >/dev/null 2>&1 || exit 0

printf '%s' "$payload" | "$DOC_TOOLS" ledger state-watch --hook 2>/dev/null
exit 0

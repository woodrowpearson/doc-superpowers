#!/usr/bin/env bash
# Fixture for eval "update-from-session-report": the update-from-audit project,
# with the report as `audit` leaves it in a session — on disk, neither
# committed nor indexed. Archiving it takes a plain mv (git mv exits 128 on an
# untracked file) and no move-entry (the index never listed it).
. "$(dirname "$0")/../lib.sh"
[ -z "$(ls -A . 2>/dev/null)" ] || fx_die "run from an empty directory ($(pwd -P) is not empty)"
"${BASH_BIN:-bash}" "$(dirname "$0")/../update-from-audit/setup.sh"
fx_attach "$0"

REPORT=docs/plans/2026-09-01-audit-report.md
dt remove-entry "$REPORT" >/dev/null
git rm -q --cached "$REPORT"
git add docs/.doc-index.json
git commit -qm "docs: drop the report from history (as if audit had just written it)"

fx_expect "the report is on disk" test -f "$REPORT"
fx_expect "git does not track the report" sh -c '! git ls-files --error-unmatch "$0" >/dev/null 2>&1' "$REPORT"
fx_expect "the index does not list the report" test "$(fx_fresh ".docs | has(\"$REPORT\")")" = false
fx_expect "three docs are still stale" test "$(fx_fresh '.summary.stale')" = 3

#!/usr/bin/env bash
# The publish step of doc-ledger-publish.yml: runs the vendored
# `doc-tools.sh ledger publish`, which renders the work-ledger views from the
# base commit and pushes them to the views branch (and, with in-flight
# awareness on, prunes the stale in-flight refs). Without
# docs/ledger/config.json the verb prints its one "not enabled" line and
# exits 0, and so does this step.
#
# The ledger verbs run from the helper set vendored beside doc-tools.sh
# (.github/scripts/ledger/ and .github/scripts/adapters/: install --ci ships
# them with this workflow). Without it the step fails before doc-tools.sh
# runs — a config added later would otherwise fail every run with a message
# about scripts/ledger/, and a host without one would pass on a workflow
# that cannot work.
#
# Env:
#   LEDGER_HELPERS  the vendored helper set's entry point (the workflow:
#                   .github/scripts/ledger/lib.sh); it must be a file.
#   DOC_TOOLS       default .github/scripts/doc-tools.sh (the vendored copy)
#   GH_TOKEN        for the reference adapters (gh), when the config names them
#
# Exit: doc-tools.sh's own code (0 published or not enabled; 2 it could not
# run: a views branch that moved meanwhile, a failing adapter, no remote), with
# an ::error:: line for a non-zero one; 1 when the helper set is missing.
set -euo pipefail

DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"
lib="${LEDGER_HELPERS:-.github/scripts/ledger/lib.sh}"

if [ ! -f "$lib" ]; then
  echo "::error::the ledger helper set is not vendored ($lib is missing): run scripts/hooks/install.sh install --ci, which ships .github/scripts/ledger/ and .github/scripts/adapters/ with this workflow, and commit them"
  exit 1
fi

rc=0
"$DOC_TOOLS" ledger publish </dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "::error::doc-tools.sh ledger publish exited $rc (the reason is above); the views branch is unchanged, and the next run retries"
fi
exit "$rc"

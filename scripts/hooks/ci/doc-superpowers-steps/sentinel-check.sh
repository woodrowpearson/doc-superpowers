#!/usr/bin/env bash
# doc-pr-release.yml step "Skip if head is a doc-superpowers sentinel commit".
#
# Writes `skip=true` to $GITHUB_OUTPUT when HEAD's subject is the bot's own
# fragment-sync sentinel (`[doc-superpowers] sync PR-<N> release notes …`),
# else `skip=false`. A defense-in-depth backstop to the workflow's
# `paths-ignore` + actor checks.
#
# Env:
#   GITHUB_OUTPUT  step-output file (set by the runner)
#
# Exit codes: 0 always (unless git or the output write fails).
#
# Extracted verbatim from the workflow's inline `run:` body so it can be
# tested; runs under `set -e`, the runner's default for an unannotated `run:`.
set -e

subject=$(git log -1 --format=%s)
if printf '%s' "$subject" | grep -qE '^\[doc-superpowers\] sync PR-[0-9]+ release notes'; then
  echo "Head commit is a doc-superpowers sentinel — nothing to do."
  echo "skip=true" >> "$GITHUB_OUTPUT"
else
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi

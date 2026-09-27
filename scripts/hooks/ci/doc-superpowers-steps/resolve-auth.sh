#!/usr/bin/env bash
# "Resolve Anthropic auth" step shared by the AI workflow templates
# (doc-pr-release.yml, doc-release.yml).
#
# Writes `use_oauth=true` when CLAUDE_CODE_OAUTH_TOKEN is set (it wins when
# both are), `use_oauth=false` when only ANTHROPIC_API_KEY is set, and fails
# the step with an ::error:: annotation when neither is.
#
# Env:
#   OAUTH          secrets.CLAUDE_CODE_OAUTH_TOKEN
#   API_KEY        secrets.ANTHROPIC_API_KEY
#   GITHUB_OUTPUT  step-output file (set by the runner)
#
# Exit codes:
#   0  one credential selected
#   1  neither secret is set
#
# Extracted verbatim from the workflows' inline `run:` body so it can be
# tested; runs under `set -e`, the runner's default for an unannotated `run:`.
# One shared copy: the installer ships doc-superpowers-steps/ with either
# workflow.
set -e

if [ -n "$OAUTH" ]; then
  echo "use_oauth=true" >> "$GITHUB_OUTPUT"
  if [ -n "$API_KEY" ]; then
    echo "::notice::Both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set; using CLAUDE_CODE_OAUTH_TOKEN."
  fi
elif [ -n "$API_KEY" ]; then
  echo "use_oauth=false" >> "$GITHUB_OUTPUT"
else
  echo "::error::Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set as a repository secret. Add one under Settings > Secrets and variables > Actions." >&2
  exit 1
fi

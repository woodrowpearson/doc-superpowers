#!/usr/bin/env bash
# doc-release.yml step "Check for unreleased commits".
#
# Writes `skip=true` to $GITHUB_OUTPUT when there is nothing to release:
#   - HEAD is doc-superpowers' own release-notes commit, by its exact subject
#     however its pull request was merged: "[doc-superpowers] draft release
#     notes" (rebase), "... (#<n>)" (squash) or "Merge pull request #<n> from
#     <owner>/doc-superpowers/release-notes-<run id>" (merge commit). Never a
#     substring match: a squash commit that merely lists the bot's
#     "[doc-superpowers] sync …" commits is a release like any other;
#   - HEAD is the last release: the nearest release tag (`v[0-9]*` — another
#     tag, such as a deploy marker, is not a release) has no commit after it.
# Otherwise `skip=false` — including the first release, when there is no
# release tag at all.
#
# Before `skip=false` it runs `doc-tools.sh fragments merge <last release |
# ROOT> HEAD`, which refuses (exit 1) when a release consumed fragments that
# are still here — that release's commit never reached this branch, and
# drafting now would release them twice. This step then fails with an
# ::error:: (merge the release branch into this one, or cherry-pick its
# release commit, then push again).
#
# Env:
#   GITHUB_OUTPUT  step-output file (set by the runner)
#   DOC_TOOLS      default .github/scripts/doc-tools.sh (the vendored copy)
#
# Exit codes: 0; 1 when the check above refuses (or git fails).
#
# Runs under `set -e`, the runner's default for an unannotated `run:`.
set -e

DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"

subject=$(git log -1 --format=%s)
if printf '%s\n' "$subject" | grep -qE \
  '^(\[doc-superpowers\] draft release notes( \(#[0-9]+\))?|Merge pull request #[0-9]+ from [^ ]+/doc-superpowers/release-notes-[0-9]+)$'; then
  echo "HEAD is doc-superpowers' own release-notes commit ($subject) — nothing to draft."
  echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "")
if [ -n "$last_tag" ]; then
  commit_count=$(git rev-list "${last_tag}..HEAD" --count)
  if [ "$commit_count" -eq 0 ]; then
    echo "No unreleased commits since $last_tag. Skipping."
    echo "skip=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "$commit_count commits since $last_tag."
else
  echo "No release tag found — first release."
fi

if [ ! -x "$DOC_TOOLS" ]; then
  echo "::error::$DOC_TOOLS is missing or not executable (re-run the doc-superpowers installer: install --ci)"
  exit 1
fi
rc=0
"$DOC_TOOLS" fragments merge "${last_tag:-ROOT}" HEAD > /dev/null || rc=$?
if [ "$rc" -eq 1 ]; then
  echo "::error::doc-superpowers: an earlier release has not reached this branch (fragments merge refused, above). Merge that release's branch into this one, or cherry-pick its release commit, then push again."
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "::error::doc-superpowers: doc-tools.sh fragments merge failed (exit $rc, its message is above)."
  exit 1
fi
echo "skip=false" >> "$GITHUB_OUTPUT"

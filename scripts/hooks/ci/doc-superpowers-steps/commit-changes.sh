#!/usr/bin/env bash
# The AI templates' commit step, after the agent. The agent edits files but
# never commits or pushes (its --allowedTools grant neither); this step
# checks what changed and commits it.
#
# The workflows run the copy prepare-agent.sh took under $RUNNER_TEMP before
# the agent step, and every git call here runs with core.hooksPath=/dev/null
# and core.fsmonitor=false. That is an integrity check against an agent's
# mistakes (an edited checker, a stray hook), not a sandbox. A steered agent
# (a PR, a commit message or a comment can carry instructions) can run code
# through its granted tools, read the job's secrets (the Anthropic credential,
# the job token) from its environment and publish them, and use the token with
# every permission the job's `permissions:` grants, repository-wide — pushing
# to any unprotected branch or tag, or changing the step scripts later jobs run
# with those secrets. The doc-superpowers references/hooks.md, "What an AI
# job's agent can reach", says what to protect.
#
# Usage:
#   commit-changes.sh [--allow <path>|<dir/>]... [--allow-index-keys] [--ignore <dir>]...
#                     (--check-only | --message <subject> --push-to <branch>
#                      [--open-pr <base> | --superseded-fails])
#
#   --allow <path>       a path the change may touch; <dir/> (a trailing /)
#                        allows everything under it
#   --allow-index-keys   also the docs docs/.doc-index.json indexes at HEAD. A
#                        key the agent added does not count: it would
#                        authorize its own path.
#   --ignore <dir>       the workflow's own scratch directory (a trailing /
#                        is implied: --ignore .x never covers .x-y/): never
#                        committed, never a violation
#   --check-only         check only; the caller commits (doc-pr-release.yml
#                        runs doc-pr-release/commit-and-push.sh next)
#   --message <subject>  the commit subject
#   --push-to <branch>   push HEAD to that existing branch, never forced. The
#                        workflows check out the branch, so a run queued in the
#                        shared write group starts from the tip earlier runs
#                        left. When the branch still moved during this run:
#                        someone pushed (a commit in <checkout>..<tip> whose
#                        subject does not start with [doc-superpowers]) → this
#                        run is superseded: exit 0, nothing committed or
#                        pushed (exit 1 with --superseded-fails); moved
#                        only by [doc-superpowers] commits, or in
#                        a way the range cannot show (reset behind the
#                        checkout) → exit 1, never a silent discard. A branch
#                        deleted meanwhile is not recreated (exit 0).
#   --open-pr <base>     with --push-to <new branch>: create that branch (it
#                        must not exist) and open a pull request → <base> (gh,
#                        GH_TOKEN)
#   --superseded-fails   a superseded run fails (exit 1: "re-run this
#                        workflow") instead of ending green. Only for a
#                        workflow the superseding push does not run again
#                        (doc-pr-full-cycle runs only when the PR is opened);
#                        doc-audit-update (push) and doc-pr-release
#                        (synchronize) are re-run by that push, and leave it off.
#
# Env:
#   EXPECTED_HEAD   the HEAD the agent started from (prepare-agent.sh's head)
#   GITHUB_OUTPUT   step-output file (set by the runner)
#   GIT_USER_NAME   commit author name  (default: github-actions[bot])
#   GIT_USER_EMAIL  commit author email (default: 41898282+github-actions[bot]@users.noreply.github.com)
#
# Outputs: changed=true|false, committed=true|false, sha=<commit> when one
# was pushed, superseded=true when the branch moved past the checkout.
#
# Exit codes: 0 nothing changed, committed (and pushed), --check-only passed,
# superseded (without --superseded-fails), or the branch is gone; 1 HEAD
# moved during the agent step, a path outside the allowed set changed, a
# superseded run under --superseded-fails, or git/gh failed (nothing is
# committed on a refusal); 2 bad usage.
#
# Needs git >= 2.25 (--pathspec-from-file).
#
# doc-pr-release/commit-and-push.sh sources this file for the functions
# before the "Sourced" line (err, out, g, remote_tip, moved): the one
# implementation of "the branch moved during the run" for every writer.
set -euo pipefail

err() {
  echo "::error::doc-superpowers: $*"
  exit 1
}
out() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# git without any hook or fsmonitor .git may name (planted during the agent step).
g() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# The tip of $PUSH_TO at origin ("" when it does not exist); non-zero when
# origin cannot be asked. (Callers err: an err inside $(…) would be swallowed.)
remote_tip() {
  local line
  line=$(g ls-remote --heads origin "refs/heads/$PUSH_TO") || return 1
  printf '%s' "${line%%[[:space:]]*}"
}

# moved <what was done>: $PUSH_TO is no longer at the checkout ($head).
# Superseded (exit 0; exit 1 when SUPERSEDED_FAILS=1, --superseded-fails:
# nothing re-runs that workflow) when someone other than doc-superpowers
# pushed during the run — a commit in head..tip whose subject does not start
# with [doc-superpowers]; otherwise (only doc-superpowers commits, or no
# commit in the range: a reset or force-push behind the checkout, or a range
# that cannot be read) a visible failure. Never a push: what someone else did
# to the branch stands.
moved() {
  local new subjects s
  if ! g fetch --quiet --no-tags origin "refs/heads/$PUSH_TO" \
    || ! new=$(g rev-parse --verify --quiet "FETCH_HEAD^{commit}") \
    || ! subjects=$(g log --format=%s "$head..$new"); then
    err "$PUSH_TO moved during this run and its new commits cannot be read. $1"
  fi
  [ -n "$subjects" ] \
    || err "$PUSH_TO moved during this run to ${new:0:12}, which adds no commit to ${head:0:12} (reset behind the checkout?). $1"
  while IFS= read -r s; do
    case "$s" in
      "[doc-superpowers]"*) ;;
      *)
        out changed true
        out committed false
        out superseded true
        if [ "${SUPERSEDED_FAILS:-0}" = 1 ]; then
          err "superseded: $PUSH_TO received new commits during this run (${head:0:12}..${new:0:12}); nothing was committed to it. Re-run this workflow: it runs only when the pull request is opened, so no later run applies these changes."
        fi
        echo "::notice::doc-superpowers: superseded: $PUSH_TO received new commits during this run (${head:0:12}..${new:0:12}). $1"
        exit 0
        ;;
    esac
  done <<<"$subjects"
  err "$PUSH_TO moved during this run (${head:0:12}..${new:0:12}) only by doc-superpowers commits: nobody else's work supersedes this run's changes. $1 Re-run the workflow to apply them."
}

# Sourced (commit-and-push.sh): the functions above only.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

usage() {
  echo "Usage: $0 [--allow <path>|<dir/>]... [--allow-index-keys] [--ignore <dir>]... (--check-only | --message <subject> --push-to <branch> [--open-pr <base> | --superseded-fails])" >&2
  exit 2
}

ALLOW=() IGNORE=() INDEX_KEYS=0 CHECK_ONLY=0 MESSAGE="" PUSH_TO="" OPEN_PR="" SUPERSEDED_FAILS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow | --ignore | --message | --push-to | --open-pr)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || usage
      case "$1" in
        --allow) ALLOW+=("$2") ;;
        --ignore) IGNORE+=("${2%/}/") ;;
        --message) MESSAGE="$2" ;;
        --push-to) PUSH_TO="$2" ;;
        --open-pr) OPEN_PR="$2" ;;
      esac
      shift 2
      ;;
    --allow-index-keys)
      INDEX_KEYS=1
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --superseded-fails)
      SUPERSEDED_FAILS=1
      shift
      ;;
    *) usage ;;
  esac
done
if [ "$CHECK_ONLY" = 1 ]; then
  { [ -z "$MESSAGE$PUSH_TO$OPEN_PR" ] && [ "$SUPERSEDED_FAILS" = 0 ]; } || usage
else
  { [ -n "$MESSAGE" ] && [ -n "$PUSH_TO" ]; } || usage
  { [ -z "$OPEN_PR" ] || [ "$SUPERSEDED_FAILS" = 0 ]; } || usage
  git check-ref-format "refs/heads/$PUSH_TO" || { echo "--push-to '$PUSH_TO' is not a branch name" >&2; exit 2; }
fi
[ -n "${GITHUB_OUTPUT:-}" ] || { echo "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)" >&2; exit 2; }
[ -n "${EXPECTED_HEAD:-}" ] || { echo "EXPECTED_HEAD is not set (prepare-agent.sh's head output)" >&2; exit 2; }
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/doc-sp-commit.XXXXXX") || err "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT

head=$(g rev-parse --verify HEAD 2>/dev/null) || err "no checkout here (git rev-parse HEAD failed)"
expected=$(g rev-parse --verify --quiet "$EXPECTED_HEAD^{commit}") || expected="$EXPECTED_HEAD"
[ "$head" = "$expected" ] \
  || err "HEAD is $head, not $EXPECTED_HEAD where the agent started: a commit was made during the agent step. Nothing was committed or pushed."

NL=$'\n'
KEYS=""
if [ "$INDEX_KEYS" = 1 ] && g cat-file -e "HEAD:docs/.doc-index.json" 2>/dev/null; then
  KEYS=$(g show "HEAD:docs/.doc-index.json" | jq -r '(.docs // {}) | keys[] | select(test("\n") | not)') \
    || err "cannot read the docs/.doc-index.json keys at HEAD"
  KEYS="$NL$KEYS$NL"
fi

allowed() {
  local a
  for a in ${ALLOW[@]+"${ALLOW[@]}"}; do
    case "$a" in
      */)
        case "$1" in
          "$a"*) return 0 ;;
        esac
        ;;
      *) [ "$1" != "$a" ] || return 0 ;;
    esac
  done
  case "$KEYS" in
    *"$NL$1$NL"*) return 0 ;;
  esac
  return 1
}
ignored() {
  local i
  for i in ${IGNORE[@]+"${IGNORE[@]}"}; do
    case "$1" in
      "$i"*) return 0 ;;
    esac
  done
  return 1
}

# Every change: staged, unstaged, untracked (a rename is a deletion + an addition).
g status --porcelain=v1 -z --untracked-files=all --no-renames > "$TMP/status" || err "git status failed"
paths=() bad=""
while IFS= read -r -d '' entry; do
  p="${entry:3}"
  if ignored "$p"; then
    continue
  elif allowed "$p"; then
    paths+=("$p")
  else
    bad="$bad$p$NL"
  fi
done < "$TMP/status"

if [ -n "$bad" ]; then
  echo "::error::doc-superpowers: the agent changed paths this workflow may not commit; nothing was committed or pushed:"
  printf '%s' "$bad" | sed 's/^/  /'
  echo "  (allowed: ${ALLOW[*]+${ALLOW[*]}}$([ "$INDEX_KEYS" = 0 ] || printf ' and the docs indexed at HEAD'))"
  exit 1
fi
if [ "${#paths[@]}" -eq 0 ]; then
  out changed false
  out committed false
  echo "Nothing changed; nothing to commit."
  exit 0
fi
echo "Changed (all allowed):"
printf '  %s\n' "${paths[@]}"
if [ "$CHECK_ONLY" = 1 ]; then
  out changed true
  out committed false
  exit 0
fi

tip=$(remote_tip) || err "cannot ask origin for $PUSH_TO (git ls-remote failed). Nothing was committed or pushed."
if [ -n "$OPEN_PR" ]; then
  [ -z "$tip" ] || err "$PUSH_TO already exists at origin; --open-pr only creates a new branch. Nothing was committed or pushed."
elif [ -z "$tip" ]; then
  out changed true
  out committed false
  echo "::notice::doc-superpowers: $PUSH_TO no longer exists at origin (deleted since the checkout); it is not recreated. Nothing was committed or pushed."
  exit 0
elif [ "$tip" != "$head" ]; then
  moved "Nothing was committed or pushed."
fi

# Stage exactly the checked paths — edits, additions, and deletions whether
# the agent staged them (git rm) or not — then commit only those paths (a
# staged file of the workflow's scratch stays out).
printf '%s\0' "${paths[@]}" > "$TMP/paths"
g --literal-pathspecs update-index --add --remove -z --stdin < "$TMP/paths" || err "git update-index failed"
g --literal-pathspecs -c "user.name=$GIT_USER_NAME" -c "user.email=$GIT_USER_EMAIL" \
  commit -q -m "$MESSAGE" --pathspec-from-file="$TMP/paths" --pathspec-file-nul || err "git commit failed"
sha=$(g rev-parse HEAD)
if ! g push origin "HEAD:refs/heads/$PUSH_TO"; then
  tip=$(remote_tip) || err "the push to $PUSH_TO failed and origin cannot be asked why (git ls-remote failed). Nothing was pushed."
  if [ -z "$OPEN_PR" ] && [ -n "$tip" ] && [ "$tip" != "$head" ]; then
    moved "Nothing was pushed."
  fi
  err "the push to $PUSH_TO failed while the branch was still at the checkout (see git's message above). Nothing was forced."
fi
out changed true
out committed true
out sha "$sha"
echo "Committed $sha to $PUSH_TO."
if [ -n "$OPEN_PR" ]; then
  if ! gh pr create --base "$OPEN_PR" --head "$PUSH_TO" --title "$MESSAGE" \
    --body "Drafted by the doc-superpowers workflow run ${GITHUB_RUN_ID:-} — review before merging."; then
    err "gh pr create failed (the branch $PUSH_TO is pushed). If the log says GitHub Actions may not create pull requests, allow it: Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create and approve pull requests."
  fi
fi

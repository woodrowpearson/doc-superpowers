#!/usr/bin/env bash
# The AI templates' commit step, after the agent. The agent edits files but
# never commits or pushes (its --allowedTools grant neither); this step
# checks what changed and commits it.
#
# The workflows run the copy prepare-agent.sh took under $RUNNER_TEMP before
# the agent step (the agent can edit the checkout's copy), and every git call
# here runs with core.hooksPath=/dev/null and core.fsmonitor=false, so no
# hook or fsmonitor the agent could have planted in .git runs.
#
# Usage:
#   commit-changes.sh [--allow <path>|<dir/>]... [--allow-index-keys] [--ignore <dir/>]...
#                     (--check-only | --message <subject> --push-to <branch> [--open-pr <base>])
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
#   --push-to <branch>   push HEAD to that existing branch, never forced. When
#                        the branch moved past the checkout (the runs of the
#                        shared write group queue in order, and an earlier one
#                        pushed), this run is superseded: exit 0, no commit, no
#                        push — the run the newer push started covers it. A
#                        branch deleted meanwhile is not recreated (exit 0).
#   --open-pr <base>     with --push-to <new branch>: create that branch (it
#                        must not exist) and open a pull request → <base> (gh,
#                        GH_TOKEN)
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
# superseded, or the branch is gone; 1 HEAD moved during the agent step, a
# path outside the allowed set changed, or git/gh failed (nothing is committed
# on a refusal); 2 bad usage.
#
# Needs git >= 2.25 (--pathspec-from-file).
set -euo pipefail

usage() {
  echo "Usage: $0 [--allow <path>|<dir/>]... [--allow-index-keys] [--ignore <dir/>]... (--check-only | --message <subject> --push-to <branch> [--open-pr <base>])" >&2
  exit 2
}

ALLOW=() IGNORE=() INDEX_KEYS=0 CHECK_ONLY=0 MESSAGE="" PUSH_TO="" OPEN_PR=""
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
    *) usage ;;
  esac
done
if [ "$CHECK_ONLY" = 1 ]; then
  [ -z "$MESSAGE$PUSH_TO$OPEN_PR" ] || usage
else
  { [ -n "$MESSAGE" ] && [ -n "$PUSH_TO" ]; } || usage
  git check-ref-format "refs/heads/$PUSH_TO" || { echo "--push-to '$PUSH_TO' is not a branch name" >&2; exit 2; }
fi
[ -n "${GITHUB_OUTPUT:-}" ] || { echo "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)" >&2; exit 2; }
[ -n "${EXPECTED_HEAD:-}" ] || { echo "EXPECTED_HEAD is not set (prepare-agent.sh's head output)" >&2; exit 2; }
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

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

# The branch's tip at origin ("" when it does not exist).
remote_tip() {
  local line
  line=$(g ls-remote --heads origin "refs/heads/$PUSH_TO") || err "cannot ask origin for $PUSH_TO (git ls-remote failed)"
  printf '%s' "${line%%[[:space:]]*}"
}
# superseded <what was done>: the branch moved past the checkout — not a failure.
superseded() {
  out changed true
  out committed false
  out superseded true
  echo "::notice::doc-superpowers: superseded: $PUSH_TO moved past ${head:0:12} since the checkout; a newer run covers it. $1"
  exit 0
}

tip=$(remote_tip)
if [ -n "$OPEN_PR" ]; then
  [ -z "$tip" ] || err "$PUSH_TO already exists at origin; --open-pr only creates a new branch. Nothing was committed or pushed."
elif [ -z "$tip" ]; then
  out changed true
  out committed false
  echo "::notice::doc-superpowers: $PUSH_TO no longer exists at origin (deleted since the checkout); it is not recreated. Nothing was committed or pushed."
  exit 0
elif [ "$tip" != "$head" ]; then
  superseded "Nothing was committed or pushed."
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
  tip=$(remote_tip)
  if [ -z "$OPEN_PR" ] && [ -n "$tip" ] && [ "$tip" != "$head" ]; then
    superseded "Nothing was pushed."
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

#!/usr/bin/env bash
# The step of doc-index-resolve.yml: merges the base branch into every open
# pull request against it whose only conflict is the doc index
# (docs/.doc-index.json), with doc-superpowers' index merge driver, vendored
# beside this script (merge-doc-index.sh).
#
# Which pull requests (one, PR=<n>, or every open one against the base):
#   left out    a fork, another base, labelled no-index-resolve, a head that
#               is the base, not open, or a mergeable state GitHub still
#               reports as unknown after one retry: no comment, a line in the
#               log and in the run's summary.
#   not touched GitHub reports it as mergeable: no comment.
#   considered  GitHub reports it as conflicting. It ends merged, skipped or
#               failed, or left out when its branch moved meanwhile.
# A considered one whose head moved since GitHub named it, or whose branch
# moved before the push, is left out (log only, no comment). It is merged only
# when git without the driver finds docs/.doc-index.json the only conflict,
# the driver merges it cleanly, the merged index keeps every entry both sides
# hold (one deleted since the merge base may go), and the merge brings no file
# under .github/workflows/ (the job token cannot push one). The merge is
# written with `git merge-tree --write-tree` (the working tree is never left
# mid-merge), its first parent the head, and pushed with
# --force-with-lease=refs/heads/<branch>:<head>: a branch that moved meanwhile
# refuses it (left out), and a refusal on a branch that did not move (a branch
# protection rule or ruleset) fails, with a comment that says so. The
# driver and the attribute that routes the index to it are given to git for
# the merge alone (git -c, --attr-source): the repository's config and
# attributes are not read or written for them.
#
# A push with the job token starts no workflow: with TEST_WORKFLOW set, that
# workflow is dispatched on the branch after the push. A dispatch starts that
# one workflow only; the pull request's other checks wait for the author's
# next push (or a close and reopen), which the comment asks for when nothing
# was dispatched. A re-run would check the original commit, not the merge.
# Each merged or skipped pull request gets one comment marked
# <!-- doc-superpowers:index-resolve -->, the resolver's own (author login
# github-actions[bot]) updated in place.
#
# Env:
#   BASE_BRANCH        the base branch (required)
#   GITHUB_REPOSITORY  owner/name (required; set by GitHub)
#   PR                 one pull request number (empty: every open one)
#   TEST_WORKFLOW      a workflow file name to dispatch on a merged branch
#                      (empty: none)
#   TEST_PR_INPUT      that workflow's workflow_dispatch input for the pull
#                      request's number, sent as inputs[<name>]=<number>
#                      (empty: the dispatch sends no inputs)
#   GH_TOKEN           for gh api
#   DOC_SUPERPOWERS_GIT_TOKEN  for the fetches and pushes (the git-token block)
#   GIT_USER_NAME / GIT_USER_EMAIL  the merge commit's author and committer
#                      (default: github-actions[bot])
#   RESOLVE_RETRY_SECONDS  the wait before asking GitHub again for a mergeable
#                      state it is still computing (default 10)
#   RESOLVE_BOT_LOGIN  the login whose marked comment is the resolver's
#                      (default github-actions[bot], the job token's)
#   GITHUB_STEP_SUMMARY  the run's summary (optional)
#
# Needs bash 3.2+, jq 1.6+, gh and git 2.40+ (merge-tree --write-tree,
# --attr-source).
#
# Exit: 0 no pull request failed; 2 one failed, or the run could not start
# (no listing, no base, no driver, an older git); 3 a usage error. A failure
# on one pull request does not stop the others.
set -euo pipefail

# doc-superpowers:git-token
# The job's token, for this step's git calls only. The workflow's checkout keeps
# none (persist-credentials: false), so .git/config holds no token for an agent
# earlier in the job to read. git asks this helper, scoped to the job's own
# GitHub host, and it reads the token from this step's env: nothing reaches disk
# or a command line. The empty first entry drops any helper the checkout's
# config names.
if [ -n "${DOC_SUPERPOWERS_GIT_TOKEN:-}" ]; then
  _git_host="${GITHUB_SERVER_URL:-https://github.com}"
  # After any entries the step's env already holds (core.hooksPath, say).
  _git_n="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$_git_n=credential.$_git_host.helper" "GIT_CONFIG_VALUE_$_git_n="
  _git_n=$((_git_n + 1))
  # shellcheck disable=SC2016  # the helper's own shell text
  export "GIT_CONFIG_KEY_$_git_n=credential.$_git_host.helper" \
    "GIT_CONFIG_VALUE_$_git_n="'!f() { [ "$1" = get ] || return 0; echo username=x-access-token; echo "password=$DOC_SUPERPOWERS_GIT_TOKEN"; }; f'
  export GIT_CONFIG_COUNT=$((_git_n + 1))
fi
# /doc-superpowers:git-token

MARKER='<!-- doc-superpowers:index-resolve -->'
INDEX=docs/.doc-index.json
LABEL=no-index-resolve
# The resolver's own comments are this login's, as in doc-freshness-pr.yml.
BOT_LOGIN="${RESOLVE_BOT_LOGIN:-github-actions[bot]}"
BASE_BRANCH="${BASE_BRANCH:-}"
REPO="${GITHUB_REPOSITORY:-}"
PR="${PR:-}"
TEST_WORKFLOW="${TEST_WORKFLOW:-}"
TEST_PR_INPUT="${TEST_PR_INPUT:-}"
RETRY="${RESOLVE_RETRY_SECONDS:-10}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
DRIVER="$(dirname "$0")/merge-doc-index.sh"
# The cite relocator, beside this script; doc-tools.sh, vendored one level up
# (.github/scripts/doc-tools.sh): the base branch's own copy.
CITE="$(dirname "$0")/cite-resolve.sh"
DOC_TOOLS="$(cd "$(dirname "$0")/.." && pwd)/doc-tools.sh"

usage() {
  echo "::error::index-resolve.sh: $*"
  exit 3
}
cannot_run() {
  echo "::error::index-resolve.sh: $*"
  exit 2
}

[ -n "$BASE_BRANCH" ] || usage "BASE_BRANCH is not set (the workflow renders it from install --ci --base-branch)"
git check-ref-format "refs/heads/$BASE_BRANCH" || usage "BASE_BRANCH '$BASE_BRANCH' is not a branch name"
case "$REPO" in
  */*/* | /* | */ | "") usage "GITHUB_REPOSITORY '$REPO' is not owner/name" ;;
  */*) ;;
  *) usage "GITHUB_REPOSITORY '$REPO' is not owner/name" ;;
esac
case "$PR" in
  "") ;;
  *[!0-9]* | 0*) usage "PR '$PR' is not a pull request number" ;;
esac
if [ -n "$TEST_WORKFLOW" ] && ! [[ "$TEST_WORKFLOW" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
  usage "TEST_WORKFLOW '$TEST_WORKFLOW' is not a workflow file name (install --ci --resolve-test-workflow=<file>)"
fi
if [ -n "$TEST_PR_INPUT" ] && ! [[ "$TEST_PR_INPUT" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  usage "TEST_PR_INPUT '$TEST_PR_INPUT' is not an input name (install --ci --resolve-test-pr-input=<name>)"
fi
case "$RETRY" in
  "" | *[!0-9]*) usage "RESOLVE_RETRY_SECONDS '$RETRY' is not a number of seconds" ;;
esac

[ -f "$DRIVER" ] || cannot_run "the index merge driver is not vendored beside this step ($DRIVER): run scripts/hooks/install.sh install --ci, and commit what it writes"
DRIVER_ABS="$(cd "$(dirname "$DRIVER")" && pwd)/merge-doc-index.sh"

T=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/index-resolve.XXXXXX") || cannot_run "cannot create a scratch directory"
# drop_wt: the re-record's worktree (cite_merge) removed, when there is one.
drop_wt() {
  [ ! -e "$T/wt" ] || git worktree remove --force "$T/wt" >/dev/null 2>&1 || rm -rf "$T/wt"
}
trap 'drop_wt; rm -rf "$T"' EXIT

# Attributes for the merges, from a tree of their own (--attr-source): none,
# for the merge without the driver, and one routing the index to it.
EMPTY_TREE=$(git mktree </dev/null) || cannot_run "git mktree failed"
git --attr-source="$EMPTY_TREE" rev-parse --git-dir >/dev/null 2>&1 \
  || cannot_run "this git ($(git --version)) has no --attr-source: git 2.40 or later is needed"
ATTR_TREE=$(printf '%s\t.gitattributes\n' "100644 blob $(printf '%s merge=doc-index\n' "$INDEX" | git hash-object -w --stdin)" | git mktree) \
  || cannot_run "cannot write the merge attributes"
q=$(printf '%s' "$DRIVER_ABS" | sed "s/'/'\\\\''/g")
DRIVER_CMD="bash '$q' %O %A %B"

# git_plain / git_driver <args…>: git with no attribute, or with the index
# routed to the vendored driver; neither reads the repository's attributes.
git_plain() { git --attr-source="$EMPTY_TREE" -c core.attributesFile=/dev/null "$@"; }
git_driver() {
  git --attr-source="$ATTR_TREE" -c core.attributesFile=/dev/null \
    -c "merge.doc-index.name=doc-superpowers index merge driver" -c "merge.doc-index.driver=$DRIVER_CMD" "$@"
}

# --- the pull requests ---------------------------------------------------------

# One line per pull request, its fields separated by US (\037, which no ref
# or sha holds): number, head ref, head sha, and why it is left out ("" when
# it is a candidate). Reads pages (arrays) or one pull request.
# shellcheck disable=SC2016  # jq program
LIST_JQ='
  (if type == "array" then .[] else . end)
  | [ .number, (.head.ref // ""), (.head.sha // ""),
      (if .state != "open" then "not open"
       elif (.base.ref // "") != $base then "against another base (\(.base.ref // ""))"
       elif (.head.repo.full_name // "") != $repo then "from a fork"
       elif .head.ref == $base then "its head is the base branch"
       elif any(.labels[]?; .name == $lbl) then "labelled \($lbl)"
       else "" end) ]
  | map(tostring) | join("\u001f")'

if [ -n "$PR" ]; then
  gh api "repos/$REPO/pulls/$PR" > "$T/list.json" || cannot_run "cannot read pull request #$PR (gh api failed, above)"
else
  gh api --paginate "repos/$REPO/pulls?state=open&base=$BASE_BRANCH&per_page=100" > "$T/list.json" \
    || cannot_run "cannot list the open pull requests against $BASE_BRANCH (gh api failed, above)"
fi
jq -r --arg base "$BASE_BRANCH" --arg repo "$REPO" --arg lbl "$LABEL" "$LIST_JQ" "$T/list.json" > "$T/list.tsv" \
  || cannot_run "cannot read the pull request listing (not the JSON GitHub returns)"

git fetch -q --no-tags origin "refs/heads/$BASE_BRANCH" || cannot_run "cannot fetch $BASE_BRANCH from origin"
BASE_SHA=$(git rev-parse FETCH_HEAD)

# --- outcomes ------------------------------------------------------------------

N_MERGED=0 N_SKIPPED=0 N_FAILED=0 N_LEFT=0 N_UNTOUCHED=0
: > "$T/summary"

# say <n> <branch> <outcome> <detail>: the run log's line, and the summary's.
say() {
  echo "PR #$1 ($2): $3${4:+: $4}"
  printf -- '- #%s (`%s`): %s%s\n' "$1" "$(printf '%s' "$2" | tr '`' "'")" "$3" "${4:+: $4}" >> "$T/summary"
}

# tick <text>: <text> with each backtick made a quote, for a Markdown code span.
tick() { printf '%s' "$1" | tr '`' "'"; }

# upsert_comment <n> <body file>: update the resolver's comment on <n> (marked,
# and BOT_LOGIN's), or post one. 1 when it cannot be written.
upsert_comment() {
  local id
  if ! gh api --paginate "repos/$REPO/issues/$1/comments?per_page=100" > "$T/comments.json"; then
    return 1
  fi
  id=$(jq -rs --arg m "$MARKER" \
    --arg bot "$BOT_LOGIN" \
    '(add // []) | map(select((.user.login // "") == $bot and ((.body // "") | contains($m)))) | .[0].id // empty' \
    "$T/comments.json") || return 1
  if [ -n "$id" ]; then
    jq -n --rawfile b "$2" '{body: $b}' | gh api -X PATCH "repos/$REPO/issues/comments/$id" --input - >/dev/null
  else
    jq -n --rawfile b "$2" '{body: $b}' | gh api -X POST "repos/$REPO/issues/$1/comments" --input - >/dev/null
  fi
}

# local_fix <headline> <reason, one Markdown sentence>: the comment for a pull
# request the resolver could not merge or could not push, into body.md.
local_fix() {
  {
    echo "$MARKER"
    echo "**$1** $2 Nothing was pushed."
    echo ""
    echo "To merge it yourself, in a clone with doc-superpowers' index merge driver registered (\`/doc-superpowers hooks install --git\`, or \`doc-superpowers hooks install --git\` in a terminal):"
    echo ""
    echo "    git fetch origin"
    echo "    git merge origin/$BASE_BRANCH"
    echo ""
    echo "Resolve any other conflict, commit, and push. The label \`$LABEL\` turns this resolver off for this pull request."
  } > "$T/body.md"
}

# skip <n> <branch> <reason, one Markdown sentence> <log detail>
skip() {
  local_fix "doc-index-resolve could not merge \`$(tick "$BASE_BRANCH")\` into this branch." "$3"
  if upsert_comment "$1" "$T/body.md"; then
    N_SKIPPED=$((N_SKIPPED + 1))
    say "$1" "$2" skipped "$4"
  else
    fail "$1" "$2" "skipped ($4), and the comment that says so could not be written"
  fi
}

# refused <n> <branch> <head>: the push was refused while the branch was still
# at <head> (a branch protection rule or ruleset). Failed, and the author is
# told, since every later run would be refused the same way.
refused() {
  local_fix "doc-index-resolve merged \`$(tick "$BASE_BRANCH")\` into this branch, but GitHub refused its push." \
    "The branch was still at ${3:0:12}, so a branch protection rule or ruleset (signed commits, linear history, restricted updates) refused the workflow token's push; the resolver's run log has git's message."
  if upsert_comment "$1" "$T/body.md"; then
    fail "$1" "$2" "the push was refused while the branch was still at ${3:0:12} (git's message is above; the comment says so)"
  else
    fail "$1" "$2" "the push was refused while the branch was still at ${3:0:12} (git's message is above), and the comment that says so could not be written"
  fi
}

# moved <n> <branch> <detail>: the branch moved while the resolver ran. Left
# out, a line in the log and no comment: one would overwrite an earlier notice
# and tells an author who is pushing nothing. The next run looks again.
moved() {
  N_LEFT=$((N_LEFT + 1))
  say "$1" "$2" "left out" "$3; the next push to $BASE_BRANCH looks again"
}

# fail <n> <branch> <detail>: no comment.
fail() {
  N_FAILED=$((N_FAILED + 1))
  echo "::error::PR #$1 ($2): $3"
  say "$1" "$2" failed "$3"
}

# What starts checks on the merge commit. A re-run does not: it checks the
# commit its run first checked.
PUSH_FOR_CHECKS="Before you merge, push a commit (\`git pull\`, then \`git commit --allow-empty -m 'Run the checks'\` and \`git push\`), or close and reopen the pull request."

# merged <n> <branch> <merge commit> <checks: started | not-started | none>
# [<note>]: the note names the docs whose cites were recomputed (R6).
merged() {
  local checks
  case "$4" in
    started) checks="The \`$(tick "$TEST_WORKFLOW")\` workflow was started on this branch for the merge. The pull request's other checks start on your next push." ;;
    not-started) checks="The \`$(tick "$TEST_WORKFLOW")\` workflow could not be started for the merge (the resolver's run log says why). $PUSH_FOR_CHECKS" ;;
    *) checks="A push by the workflow token starts no workflow, so this merge has no checks yet. $PUSH_FOR_CHECKS" ;;
  esac
  {
    echo "$MARKER"
    if [ -z "${5:-}" ]; then
      echo "**doc-index-resolve merged \`$(tick "$BASE_BRANCH")\` into this branch** (merge commit $3). The only conflict was the doc index (\`$INDEX\`), which doc-superpowers' index merge driver merged entry by entry."
    else
      echo "**doc-index-resolve merged \`$(tick "$BASE_BRANCH")\` into this branch** (merge commit $3). The only conflicts were the doc index (\`$INDEX\`), which doc-superpowers' index merge driver merged entry by entry, and the cite line numbers in $5"
    fi
    echo ""
    echo "- Checks: $checks"
    echo "- Next: run \`git pull\` before you push again."
  } > "$T/body.md"
  if upsert_comment "$1" "$T/body.md"; then
    N_MERGED=$((N_MERGED + 1))
    say "$1" "$2" merged "$3"
  else
    fail "$1" "$2" "merged and pushed $3, but the comment that says so could not be written"
  fi
}

# list_md <names, one per line>: the first ten, each a code span, joined.
list_md() {
  awk 'NF { gsub(/`/, "'"'"'"); n++; if (n <= 10) printf "%s`%s`", (n > 1 ? ", " : ""), $0 } END { if (n > 10) printf ", and %d more", n - 10 }'
}

# The dropped-entry check: keys of the head's or the base's index the merged
# index lacks, unless one side deleted the key since the merge base (it is in
# the merge base and not on that side).
# shellcheck disable=SC2016  # jq program
DROPPED_JQ='
  ($h[0].docs // {}) as $h | ($b[0].docs // {}) as $b | ($m[0].docs // {}) as $m | ($r[0].docs // {}) as $r
  | (($h | keys) + ($b | keys) | unique)[] as $k
  | select(($r | has($k)) | not)
  | select((($m | has($k)) and ((($h | has($k)) | not) or (($b | has($k)) | not))) | not)
  | $k'

# index_at <commit> <file>: the index at <commit> into <file> ({} when absent).
index_at() {
  git cat-file -p "$1:$INDEX" > "$2" 2>/dev/null || echo '{}' > "$2"
}

# --- cite line numbers (design 2026-11-18) -----------------------------------

# plural <n> <word>: "1 cite", "2 cites".
plural() {
  if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# plain_env <command…>: <command>, every git it runs reading no attribute (the
# empty attribute source: no filter, textconv or LFS) and running no hook.
plain_env() {
  (
    c="${GIT_CONFIG_COUNT:-0}"
    export "GIT_CONFIG_KEY_$c=core.hooksPath" "GIT_CONFIG_VALUE_$c=/dev/null"
    c=$((c + 1))
    export "GIT_CONFIG_KEY_$c=core.attributesFile" "GIT_CONFIG_VALUE_$c=/dev/null"
    export GIT_CONFIG_COUNT=$((c + 1)) GIT_ATTR_SOURCE="$EMPTY_TREE"
    "$@"
  )
}

# stage_of <path> <stage> <field: 1 mode | 2 oid>: from $T/stages.
stage_of() {
  awk -F'\t' -v p="$1" -v s="$2" -v f="$3" '$2 == p { split($1, x, " "); if (x[3] == s) print x[f] }' "$T/stages"
}

# cite_doc <path>: whether a conflicted path may be a doc whose cite numbers
# alone differ (R1): Markdown, changed on both sides from one merge base
# (stages 1, 2 and 3), and keyed in the head's and the base's index.
cite_doc() {
  case "$1" in *.md) ;; *) return 1 ;; esac
  [ -n "$(stage_of "$1" 1 2)" ] && [ -n "$(stage_of "$1" 2 2)" ] && [ -n "$(stage_of "$1" 3 2)" ] || return 1
  jq -e --arg k "$1" '(.docs // {}) | has($k)' "$T/h.json" >/dev/null 2>&1 \
    && jq -e --arg k "$1" '(.docs // {}) | has($k)' "$T/b.json" >/dev/null 2>&1
}

# not_fresh <tree-ish> <out>: the docs of $T/docs that check-freshness --tree
# <tree-ish> does not read current with doc_modified false, one per line. 1
# when check-freshness cannot run or its report cannot be read.
not_fresh() {
  plain_env "${BASH:-bash}" "$DOC_TOOLS" check-freshness --tree "$1" > "$T/fresh.json" 2> "$T/fresh.err" || return 1
  jq -r --rawfile d "$T/docs" '.docs as $f | $d | split("\n")[] | select(. != "")
    | select((($f[.] // {}).status != "current") or (($f[.] // {}).doc_modified != false))' "$T/fresh.json" > "$2" 2>> "$T/fresh.err"
}

# cite_merge <n> <branch> <head> <driver tree>: the driver's tree with each
# doc of $T/docs rewritten by cite-resolve.sh and its index entry re-recorded,
# into CITE_TREE; CITE_COUNT the cites recomputed. 1 when it skipped or failed
# the pull request (said already). The worktree goes on every path.
cite_merge() {
  local r=0
  cite_merge_in "$@" || r=$?
  drop_wt
  return "$r"
}

cite_merge_in() {
  local n="$1" ref="$2" head="$3" tree="$4" doc mode blob rc k=0 idx="$T/cite-index" tree2
  CITE_COUNT=0 CITE_TREE=""
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree "$tree" || { fail "$n" "$ref" "git read-tree failed"; return 1; }
  # fd 3: nothing a call in the loop reads from stdin takes the list.
  while IFS= read -r doc <&3; do
    k=$((k + 1))
    rc=0
    "${BASH:-bash}" "$CITE" "$doc" "$head" "$BASE_SHA" "$tree" \
      "$(stage_of "$doc" 1 2)" "$(stage_of "$doc" 2 2)" "$(stage_of "$doc" 3 2)" > "$T/cite-$k.md" 2> "$T/cite.err" || rc=$?
    case "$rc" in
      0) ;;
      1)
        skip "$n" "$ref" "$(head -n 1 "$T/cite.err")" "the cites of $doc cannot be recomputed"
        return 1
        ;;
      *)
        fail "$n" "$ref" "cite-resolve.sh could not run on $doc: $(head -n 1 "$T/cite.err")"
        return 1
        ;;
    esac
    case "$(head -n 1 "$T/cite.err")" in
      "" | *[!0-9]*) fail "$n" "$ref" "cite-resolve.sh gave no count for $doc"; return 1 ;;
    esac
    CITE_COUNT=$((CITE_COUNT + $(head -n 1 "$T/cite.err")))
    mode=$(stage_of "$doc" 2 1)
    if ! blob=$(git hash-object -w --no-filters "$T/cite-$k.md") \
      || ! GIT_INDEX_FILE="$idx" git update-index --cacheinfo "$mode,$blob,$doc"; then
      fail "$n" "$ref" "cannot write the rewritten $doc"
      return 1
    fi
  done 3< "$T/docs"
  tree2=$(GIT_INDEX_FILE="$idx" git write-tree) || { fail "$n" "$ref" "git write-tree failed"; return 1; }

  # The re-record: update-index in a worktree at the head holding the merged
  # files. No hook, filter or LFS process runs there, nor any file of the
  # pull request: the files come in through read-tree with no attribute.
  drop_wt
  if ! plain_env git worktree add -q --detach --no-checkout "$T/wt" "$head" > /dev/null 2> "$T/err" \
    || ! (cd "$T/wt" && plain_env git read-tree --reset -u "$tree2") > /dev/null 2>> "$T/err"; then
    fail "$n" "$ref" "cannot set up the worktree for update-index: $(head -n 1 "$T/err")"
    return 1
  fi
  if ! (
    cd "$T/wt" || exit 1
    set --
    while IFS= read -r doc; do set -- "$@" "$doc"; done < "$T/docs"
    plain_env "${BASH:-bash}" "$DOC_TOOLS" update-index "$@"
  ) > "$T/update.log" 2>&1; then
    sed 's/^/  update-index: /' "$T/update.log"
    skip "$n" "$ref" "doc-tools.sh update-index could not re-record $(list_md < "$T/docs") on the merged files (the resolver's run log says why)." \
      "update-index failed"
    return 1
  fi
  # update-index stamps last_verified now, but the step only read the cites,
  # so it verified nothing (R5): each re-recorded entry keeps the newer of
  # the two sides' last_verified. A jq edit of that one field.
  if ! jq --slurpfile h "$T/h.json" --slurpfile b "$T/b.json" --rawfile d "$T/docs" '
      reduce ($d | split("\n")[] | select(. != "")) as $k (.;
        .docs[$k].last_verified = ([$h[0].docs[$k].last_verified, $b[0].docs[$k].last_verified]
          | map(select(. != null)) | max))' "$T/wt/$INDEX" > "$T/index.json" 2> "$T/err" \
    || ! blob=$(git hash-object -w --no-filters "$T/index.json") \
    || ! GIT_INDEX_FILE="$idx" git update-index --cacheinfo "100644,$blob,$INDEX" \
    || ! CITE_TREE=$(GIT_INDEX_FILE="$idx" git write-tree); then
    fail "$n" "$ref" "cannot write the re-recorded index"
    return 1
  fi

  # On the final tree, each re-recorded doc reads current (R5).
  if ! not_fresh "$CITE_TREE" "$T/stale"; then
    fail "$n" "$ref" "doc-tools.sh check-freshness failed on the merge: $(head -n 1 "$T/fresh.err")"
    return 1
  fi
  if [ -s "$T/stale" ]; then
    skip "$n" "$ref" "After the merge, \`$(tick "$(head -n 1 "$T/stale")")\` does not read current in the re-recorded doc index." \
      "$(head -n 1 "$T/stale") is not current after the re-record"
    return 1
  fi
}

resolve_one() {
  local n="$1" ref="$2" sha mergeable head out rc tree conflicts dropped bring commit tip mb checks p side at who final msg note
  local -a inputs
  # The mergeable state, asked once more while GitHub is still computing it.
  if ! gh api "repos/$REPO/pulls/$n" > "$T/pr.json"; then
    fail "$n" "$ref" "cannot read it (gh api failed, above)"
    return 0
  fi
  mergeable=$(jq -r '.mergeable | if . == null then "unknown" else tostring end' "$T/pr.json") \
    || { fail "$n" "$ref" "cannot read it (GitHub's answer is not JSON)"; return 0; }
  if [ "$mergeable" = unknown ]; then
    sleep "$RETRY"
    if ! gh api "repos/$REPO/pulls/$n" > "$T/pr.json"; then
      fail "$n" "$ref" "cannot read it (gh api failed, above)"
      return 0
    fi
    mergeable=$(jq -r '.mergeable | if . == null then "unknown" else tostring end' "$T/pr.json") \
    || { fail "$n" "$ref" "cannot read it (GitHub's answer is not JSON)"; return 0; }
  fi
  case "$mergeable" in
    true)
      N_UNTOUCHED=$((N_UNTOUCHED + 1))
      say "$n" "$ref" "not touched" "GitHub reports it as mergeable"
      return 0
      ;;
    unknown)
      N_LEFT=$((N_LEFT + 1))
      say "$n" "$ref" "left out" "its mergeable state is still unknown; the next run looks again"
      return 0
      ;;
  esac
  sha=$(jq -r '.head.sha // empty' "$T/pr.json") \
    || { fail "$n" "$ref" "cannot read its head (GitHub's answer is not JSON)"; return 0; }

  # The head, as GitHub named it.
  if ! git fetch -q --no-tags origin "refs/heads/$ref"; then
    fail "$n" "$ref" "cannot fetch the branch from origin"
    return 0
  fi
  head=$(git rev-parse FETCH_HEAD) || { fail "$n" "$ref" "cannot read the fetched head"; return 0; }
  if [ "$head" != "$sha" ]; then
    moved "$n" "$ref" "the branch moved (GitHub named ${sha:0:12}, origin has ${head:0:12})"
    return 0
  fi

  # Without the driver: the index must conflict, and every other conflict
  # must be a doc whose cite numbers may alone differ (cite_doc, R1).
  rc=0
  out=$(git_plain -c core.quotePath=false merge-tree --write-tree --no-messages "$head" "$BASE_SHA" 2>"$T/err") || rc=$?
  if [ "$rc" -gt 1 ]; then
    fail "$n" "$ref" "git merge-tree failed: $(head -n 1 "$T/err")"
    return 0
  fi
  # One line per conflicted stage: "<mode> <oid> <stage><TAB><path>".
  printf '%s\n' "$out" | sed '1d' > "$T/stages" \
    || { fail "$n" "$ref" "cannot read git's conflict list"; return 0; }
  conflicts=$(cut -f2- "$T/stages" | awk 'NF && !seen[$0]++') \
    || { fail "$n" "$ref" "cannot read git's conflict list"; return 0; }
  if [ "$rc" = 0 ] || [ -z "$conflicts" ]; then
    skip "$n" "$ref" "git merges \`$(tick "$BASE_BRANCH")\` into it without a conflict, so there is nothing for the resolver to settle." \
      "git finds no conflict"
    return 0
  fi
  index_at "$head" "$T/h.json"
  index_at "$BASE_SHA" "$T/b.json"
  : > "$T/docs"
  : > "$T/others"
  while IFS= read -r p; do
    [ "$p" != "$INDEX" ] || continue
    if printf '%s\n' "$conflicts" | grep -qxF "$INDEX" && cite_doc "$p"; then
      printf '%s\n' "$p" >> "$T/docs"
    else
      printf '%s\n' "$p" >> "$T/others"
    fi
  done <<<"$conflicts"
  if [ -s "$T/others" ]; then
    skip "$n" "$ref" "Files other than the doc index conflict: $(list_md < "$T/others")." \
      "other files conflict ($(head -n 5 "$T/others" | tr '\n' ' ' | sed 's/ $//'))"
    return 0
  fi

  # A doc's cites are recomputed only from records made against its code:
  # current, and not modified since, on both sides (R5).
  if [ -s "$T/docs" ]; then
    if [ ! -f "$DOC_TOOLS" ]; then
      fail "$n" "$ref" "doc-tools.sh is not vendored beside the step scripts ($DOC_TOOLS): run scripts/hooks/install.sh install --ci"
      return 0
    fi
    for side in head base; do
      if [ "$side" = head ]; then at="$head" who="the head"; else at="$BASE_SHA" who="\`$(tick "$BASE_BRANCH")\`"; fi
      if ! not_fresh "$at" "$T/stale"; then
        fail "$n" "$ref" "doc-tools.sh check-freshness failed on $side: $(head -n 1 "$T/fresh.err")"
        return 0
      fi
      if [ -s "$T/stale" ]; then
        skip "$n" "$ref" "\`$(tick "$(head -n 1 "$T/stale")")\` does not read current, unmodified since its record, in the doc index on $who, so its cites cannot be recomputed." \
          "$(head -n 1 "$T/stale") is not current on $side"
        return 0
      fi
    done
  fi

  # With the driver: the index merges cleanly; the docs may still conflict.
  rc=0
  out=$(git_driver -c core.quotePath=false merge-tree --write-tree --no-messages --name-only "$head" "$BASE_SHA" 2>"$T/err") || rc=$?
  if [ "$rc" -gt 1 ]; then
    fail "$n" "$ref" "git merge-tree failed: $(head -n 1 "$T/err")"
    return 0
  fi
  if [ "$rc" = 1 ] && { [ ! -s "$T/docs" ] || printf '%s\n' "$out" | sed '1d' | grep -qxF "$INDEX"; }; then
    sed 's/^/  driver: /' "$T/err"
    skip "$n" "$ref" "The index merge driver found entries that both sides changed in a way it cannot settle (the resolver's run log names them)." \
      "the merge driver could not merge the index"
    return 0
  fi
  tree=$(printf '%s\n' "$out" | sed -n 1p) || { fail "$n" "$ref" "cannot read the merged tree"; return 0; }

  # The docs' cites recomputed and their entries re-recorded (R3, R5).
  final="$tree"
  if [ -s "$T/docs" ]; then
    cite_merge "$n" "$ref" "$head" "$tree" || return 0
    final="$CITE_TREE"
  fi

  # No entry dropped.
  mb=$(git merge-base "$head" "$BASE_SHA" 2>/dev/null | head -n 1 || true)
  index_at "$final" "$T/r.json"
  if [ -n "$mb" ]; then index_at "$mb" "$T/m.json"; else echo '{}' > "$T/m.json"; fi
  if ! dropped=$(jq -rn --slurpfile h "$T/h.json" --slurpfile b "$T/b.json" --slurpfile m "$T/m.json" \
    --slurpfile r "$T/r.json" "$DROPPED_JQ" 2>"$T/err"); then
    skip "$n" "$ref" "The merged doc index could not be read as JSON." "the merged index is not JSON"
    return 0
  fi
  if [ -n "$dropped" ]; then
    skip "$n" "$ref" "The merged doc index would drop entries that both sides keep: $(printf '%s\n' "$dropped" | list_md)." \
      "the merge would drop index entries ($(printf '%s\n' "$dropped" | head -n 5 | tr '\n' ' ' | sed 's/ $//'))"
    return 0
  fi

  # No workflow file: the job token cannot push one.
  bring=$(git diff --name-only "$head" "$final" -- .github/workflows/) \
    || { fail "$n" "$ref" "git diff failed on the merge"; return 0; }
  if [ -n "$bring" ]; then
    skip "$n" "$ref" "The merge brings files under \`.github/workflows/\` ($(printf '%s\n' "$bring" | list_md)), which the workflow token cannot push." \
      "the merge brings workflow files"
    return 0
  fi

  # The message and the comment name the docs and the cites (R6); an
  # index-only merge says what it always said.
  msg="Only the doc index ($INDEX) conflicted; doc-superpowers' index merge driver merged it (doc-index-resolve)."
  note=""
  if [ -s "$T/docs" ]; then
    msg="The doc index ($INDEX) and the cite line numbers in $(paste -sd ',' "$T/docs" | sed 's/,/, /g') conflicted. doc-superpowers' index merge driver merged the index; doc-index-resolve recomputed $(plural "$CITE_COUNT" cite) against the merged code and re-recorded those docs' index entries, keeping the newer last_verified."
    note="$(list_md < "$T/docs"): the resolver recomputed $(plural "$CITE_COUNT" cite) against the merged code and re-recorded those docs' index entries, keeping the newer \`last_verified\` of the two sides."
  fi
  commit=$(GIT_AUTHOR_NAME="$GIT_USER_NAME" GIT_AUTHOR_EMAIL="$GIT_USER_EMAIL" \
    GIT_COMMITTER_NAME="$GIT_USER_NAME" GIT_COMMITTER_EMAIL="$GIT_USER_EMAIL" \
    git commit-tree "$final" -p "$head" -p "$BASE_SHA" -m "Merge branch '$BASE_BRANCH' into $ref" -m "$msg") \
    || { fail "$n" "$ref" "git commit-tree failed"; return 0; }

  if ! git push -q origin --force-with-lease="refs/heads/$ref:$head" "$commit:refs/heads/$ref"; then
    if ! tip=$(git ls-remote origin "refs/heads/$ref"); then
      fail "$n" "$ref" "the push was refused, and origin cannot be asked why (git ls-remote failed)"
      return 0
    fi
    tip="${tip%%[[:space:]]*}"
    if [ "$tip" != "$head" ]; then
      moved "$n" "$ref" "the push was refused: the branch moved"
    else
      refused "$n" "$ref" "$head"
    fi
    return 0
  fi

  checks=none
  if [ -n "$TEST_WORKFLOW" ]; then
    # Only the number goes in an input, never the pull request's text.
    inputs=()
    [ -z "$TEST_PR_INPUT" ] || inputs=(-f "inputs[$TEST_PR_INPUT]=$n")
    if gh api -X POST "repos/$REPO/actions/workflows/$TEST_WORKFLOW/dispatches" -f "ref=$ref" ${inputs[@]+"${inputs[@]}"} >/dev/null; then
      checks=started
    else
      checks=not-started
      echo "::warning::PR #$n ($ref): merged, but $TEST_WORKFLOW could not be dispatched on it (gh api failed, above)"
    fi
  fi
  merged "$n" "$ref" "$commit" "$checks" "$note"
}

while IFS=$'\037' read -r n ref sha why; do
  [ -n "$n" ] || continue
  if [ -n "$why" ]; then
    N_LEFT=$((N_LEFT + 1))
    say "$n" "$ref" "left out" "$why"
    continue
  fi
  resolve_one "$n" "$ref"
done < "$T/list.tsv"

echo "doc-index-resolve: $N_MERGED merged, $N_SKIPPED skipped, $N_FAILED failed, $N_LEFT left out, $N_UNTOUCHED not touched"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### doc-index-resolve"
    echo ""
    echo "$N_MERGED merged, $N_SKIPPED skipped, $N_FAILED failed, $N_LEFT left out, $N_UNTOUCHED not touched."
    echo ""
    cat "$T/summary"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$N_FAILED" -eq 0 ] || exit 2
exit 0

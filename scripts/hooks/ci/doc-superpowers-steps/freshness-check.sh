#!/usr/bin/env bash
# The freshness step of the CI templates: runs the vendored
# `doc-tools.sh check-freshness`, keeps its result on disk, and writes only
# scalars to $GITHUB_OUTPUT. (An index-sized value in one step output, and
# from there in one env var, breaks at Linux's 128 KiB per-string limit.)
#
# Usage: freshness-check.sh gate|audit|scope
#   gate   doc-freshness-pr.yml. The docs this change leaves stale or missing.
#          A check that cannot run is a ::warning:: with status=failed and no
#          count (never "0 stale"), and under DOC_SUPERPOWERS_STRICT=1 an
#          ::error:: and exit 1. STRICT with docs out of date also exits 1,
#          after the outputs are written (the PR comment step still runs).
#   audit  doc-freshness-schedule.yml. The whole index. A check that cannot
#          run always exits 1 (the tracking issue is never closed on it).
#   scope  the AI templates' gate. How many indexed docs the change touches
#          (through a code ref, or the doc's own path). A check that cannot
#          run exits 1: the agent is neither run nor skipped on a guess.
#
# Env:
#   RANGE          <base>...<head>. Judge only the docs whose code_refs share a
#                  path segment with a path changed in it (check-freshness
#                  --code-refs-from), plus the indexed docs the change edits
#                  or deletes. Unset, or a side empty (no PR context): the
#                  whole index.
#   SCOPE_DOCS     scope only: an ERE (jq test); only index keys matching it
#                  count as affected (doc-spec-verify.yml: the specs).
#   DOC_SUPERPOWERS_STRICT  gate only: "1" = strict.
#   DOC_TOOLS      default .github/scripts/doc-tools.sh (the vendored copy)
#   RUNNER_TEMP    where the files go (set by the runner)
#   GITHUB_OUTPUT  step-output file (set by the runner)
#
# Files, in $RUNNER_TEMP: changed-files.txt; freshness.json (the check's raw
# result); freshness-all.json (with a RANGE: the unscoped result, for the
# docs the change deleted); freshness-report.json ({summary, docs}: only the
# stale and missing docs).
#
# Outputs: status=ok|failed|no-index. With ok also stale, missing, count
# (stale + missing), affected (record and deprecated docs never count) and
# report (the report file's path).
#
# Exit codes: 0; 1 as above; 2 bad usage.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  gate | audit | scope) ;;
  *)
    echo "Usage: $0 gate|audit|scope" >&2
    exit 2
    ;;
esac
if [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)" >&2
  exit 2
fi

INDEX=docs/.doc-index.json
DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"
STRICT="${DOC_SUPERPOWERS_STRICT:-0}"

out() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# fail <why>: the check could not run. Never a count.
fail() {
  out status failed
  if [ "$MODE" = gate ] && [ "$STRICT" != 1 ]; then
    echo "::warning::doc-superpowers: the freshness check could not run: $1. Nothing is known to be current (DOC_SUPERPOWERS_STRICT is off, so the PR is not blocked)."
    exit 0
  fi
  echo "::error::doc-superpowers: the freshness check could not run: $1."
  exit 1
}

if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
  fail "RUNNER_TEMP is not a directory"
fi
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# The range: both sides resolved, or none.
base="" head=""
if [ -n "${RANGE:-}" ]; then
  case "$RANGE" in
    *...*)
      base="${RANGE%%...*}"
      head="${RANGE#*...}"
      ;;
    *) fail "RANGE '$RANGE' is not <base>...<head>" ;;
  esac
  if [ -n "$base" ] && [ -n "$head" ]; then
    b=$(git rev-parse --verify --quiet "$base^{commit}") \
      || fail "cannot resolve the range base '$base' (is the history fetched? actions/checkout needs fetch-depth: 0)"
    h=$(git rev-parse --verify --quiet "$head^{commit}") || fail "cannot resolve the range head '$head'"
    base="$b" head="$h"
  else
    base="" head=""
  fi
fi

if [ ! -e "$INDEX" ]; then
  if [ -n "$base" ] && git cat-file -e "$base:$INDEX" 2>/dev/null; then
    fail "$INDEX exists at the base ($base) but not here: the change deletes the index"
  fi
  echo "::notice::doc-superpowers: no $INDEX here (init has not run), so there is nothing to check."
  out status no-index
  exit 0
fi
[ -x "$DOC_TOOLS" ] || fail "$DOC_TOOLS is missing or not executable (re-run the doc-superpowers installer: install --ci)"

changed="$RUNNER_TEMP/changed-files.txt"
raw="$RUNNER_TEMP/freshness.json"
all="$RUNNER_TEMP/freshness-all.json"
report="$RUNNER_TEMP/freshness-report.json"
: > "$changed"
if [ -n "$base" ]; then
  # -z: git quotes no name (it quotes one holding '"', a backslash or a tab
  # even with core.quotePath=false, and a quoted name matches no ref).
  git diff -z --name-only --no-renames "$base...$head" | tr '\000' '\n' > "$changed" \
    || fail "git diff $base...$head failed"
  "$DOC_TOOLS" check-freshness --code-refs-from "$changed" > "$raw" \
    || fail "doc-tools.sh check-freshness exited non-zero (its message is above)"
  "$DOC_TOOLS" check-freshness > "$all" \
    || fail "doc-tools.sh check-freshness exited non-zero (its message is above)"
else
  "$DOC_TOOLS" check-freshness > "$raw" \
    || fail "doc-tools.sh check-freshness exited non-zero (its message is above)"
  cp "$raw" "$all" || fail "cannot copy $raw"
fi

# The report: the stale and missing docs in scope, plus the indexed docs the
# change deleted (a scoped check misses them when their refs are unchanged).
# Affected: the docs in scope and the indexed docs the change touched,
# neither deprecated nor a record, and matching SCOPE_DOCS when given.
# shellcheck disable=SC2016  # jq program
jq -n --slurpfile s "$raw" --slurpfile a "$all" --rawfile ch "$changed" --arg re "${SCOPE_DOCS:-}" '
  def result($r): if ($r | type) == "object" and ($r.docs | type) == "object" then $r.docs
                  else error("not a check-freshness result") end;
  result($s[0]) as $scoped
  | result($a[0]) as $every
  | ($ch | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $chg
  | (($scoped | with_entries(select(.value.status == "stale" or .value.status == "missing")))
     + ($every | with_entries(select(.value.status == "missing" and ($chg[.key] // false))))) as $bad
  | (($scoped + ($every | with_entries(select($chg[.key] // false))))
     | with_entries(select(.value.status != "deprecated" and .value.record != true))
     | with_entries(select($re == "" or (.key | test($re))))) as $aff
  | {summary: {stale: ([$bad[] | select(.status == "stale")] | length),
               missing: ([$bad[] | select(.status == "missing")] | length),
               affected: ($aff | length)},
     docs: $bad}' > "$report" \
  || fail "cannot read the check's result as check-freshness JSON"

counts=$(jq -r '.summary | "\(.stale) \(.missing) \(.affected)"' "$report") || fail "cannot read $report"
# shellcheck disable=SC2086  # three numbers
set -- $counts
stale="$1" missing="$2" affected="$3"
count=$((stale + missing))
out status ok
out stale "$stale"
out missing "$missing"
out count "$count"
out affected "$affected"
out report "$report"

scope_note="${base:+ for the changes in ${base:0:12}...${head:0:12}}"
case "$MODE" in
  scope)
    if [ "$affected" -eq 0 ]; then
      echo "::notice::doc-superpowers: the change touches no indexed doc${SCOPE_DOCS:+ matching $SCOPE_DOCS} or its code; the agent is skipped."
    else
      echo "$affected indexed doc(s) touched$scope_note ($stale stale, $missing missing)."
    fi
    ;;
  *)
    echo "$stale stale, $missing missing doc(s)$scope_note."
    jq -r '[.docs | to_entries[] | "  \(.value.status): \(.key)"] | .[:200][]' "$report"
    if [ "$MODE" = gate ] && [ "$STRICT" = 1 ] && [ "$count" -gt 0 ]; then
      echo "::error::$count doc(s) stale or missing for this change (DOC_SUPERPOWERS_STRICT=1). Update them (/doc-superpowers update) or, after checking them against their code, re-verify with doc-tools.sh update-index."
      exit 1
    fi
    ;;
esac

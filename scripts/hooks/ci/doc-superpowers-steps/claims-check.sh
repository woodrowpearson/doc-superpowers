#!/usr/bin/env bash
# The claims step of the CI templates: runs the vendored `doc-tools.sh
# claims` verbs, keeps their verdicts on disk, and writes only scalars to
# $GITHUB_OUTPUT. A project without docs/spec-claims/ is left alone: the
# step says so and exits 0 (status=disabled), calling nothing.
#
# Usage: claims-check.sh pr|scheduled
#   pr         doc-spec-verify.yml's claims job. In order: claims validate
#              --all, claims run --all, and claims attest --plan <p> --final
#              for each plan (config "plans") that has a gate-record dir,
#              is Completed or has a final.json, and whose plan file or
#              final.json the PR changes (git diff --name-only --no-renames
#              over RANGE): a plan the PR does not touch is never attested,
#              so an unrelated change is never laid at its door. Then the
#              amendment batch: claims rulings over <merge-base>..<head>.
#              The checkout holds no verdict store, by design: promotions
#              count by their stored digest, so a missing verdict is an
#              unverifiable-here advisory, never a finding. Findings exit 1,
#              whatever DOC_SUPERPOWERS_STRICT says. A check that cannot run
#              is a ::warning:: with status=indeterminate (exit 0), and under
#              DOC_SUPERPOWERS_STRICT=1 an ::error:: and exit 1.
#   scheduled  doc-freshness-schedule.yml. claims run --all --scheduled
#              --judge-sample 3, claims promote --reverify --all, claims
#              validate --all. Never exits 1 on findings (the issue step
#              reports them); exits 1 only when nothing could run.
#
# Env:
#   RANGE          pr only: <base>...<head> (the PR's base and head SHAs).
#                  Every claims call gets --base <base>, so the ratchets
#                  never depend on the base branch's name in this clone.
#   BASE_REF       scheduled only: --base for every claims call
#                  (origin/<base branch>); unset, doc-tools' own default.
#   DOC_SUPERPOWERS_STRICT  pr only: "1" = an indeterminate run fails.
#   DOC_TOOLS      default .github/scripts/doc-tools.sh (the vendored copy)
#   RUNNER_TEMP    where the files go (set by the runner)
#   GITHUB_OUTPUT  step-output file (set by the runner)
#
# Files, in $RUNNER_TEMP: claims-<n>.json (each call's raw output);
# claims-report.json (an array of the verdict objects — validate, run and
# the attests in pr mode; run, promote and validate when scheduled — where a
# call that printed no verdict object is a stand-in {verb, exit: 2, error});
# claims-amendments.md (pr: the amendment batch as Markdown for the PR
# description; empty when there is none).
#
# Outputs: status=disabled|ok|findings|indeterminate; findings (the blocking
# findings only: advisories never count), report, amendments and
# amendments_count; when scheduled also judge_sample (comma-separated ids).
# With disabled (or when nothing could run): status, findings=0 and
# amendments_count=0 only.
#
# Exit codes: 0; 1 as above; 2 bad usage.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  pr | scheduled) ;;
  *)
    echo "Usage: $0 pr|scheduled" >&2
    exit 2
    ;;
esac
if [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "GITHUB_OUTPUT is not set (this runs as a GitHub Actions step)" >&2
  exit 2
fi

DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"
STRICT="${DOC_SUPERPOWERS_STRICT:-0}"
# The config's "plans" default (doc-tools' _JQ_CLAIMS_DEFAULTS).
PLAN_GLOBS_DEFAULT='docs/superpowers/plans/*.md
docs/plans/*.md'

out() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

if [ ! -d docs/spec-claims ]; then
  echo "doc-superpowers: no docs/spec-claims/ here, so there are no spec claims to check."
  out status disabled
  out findings 0
  out amendments_count 0
  exit 0
fi

# cannot_run <why>: nothing could run. Never ok, never a count of findings.
cannot_run() {
  out status indeterminate
  out findings 0
  out amendments_count 0
  if [ "$MODE" = pr ] && [ "$STRICT" != 1 ]; then
    echo "::warning::doc-superpowers: the spec claims could not be checked: $1. Nothing is known to hold (DOC_SUPERPOWERS_STRICT is off, so the PR is not blocked)."
    exit 0
  fi
  echo "::error::doc-superpowers: the spec claims could not be checked: $1."
  exit 1
}

if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
  cannot_run "RUNNER_TEMP is not a directory"
fi
command -v jq >/dev/null 2>&1 || cannot_run "jq is not installed"
[ -x "$DOC_TOOLS" ] || cannot_run "$DOC_TOOLS is missing or not executable (re-run the doc-superpowers installer: install --ci)"

base_args=()
base="" head=""
if [ "$MODE" = pr ]; then
  case "${RANGE:-}" in
    ?*...?*)
      base="${RANGE%%...*}"
      head="${RANGE#*...}"
      ;;
    *) cannot_run "RANGE '${RANGE:-}' is not <base>...<head>" ;;
  esac
  b=$(git rev-parse --verify --quiet "$base^{commit}") \
    || cannot_run "cannot resolve the range base '$base' (is the history fetched? actions/checkout needs fetch-depth: 0)"
  h=$(git rev-parse --verify --quiet "$head^{commit}") || cannot_run "cannot resolve the range head '$head'"
  base="$b" head="$h"
  base_args=(--base "$base")
elif [ -n "${BASE_REF:-}" ]; then
  base_args=(--base "$BASE_REF")
fi

report="$RUNNER_TEMP/claims-report.json"
amendments="$RUNNER_TEMP/claims-amendments.md"
verdicts="$RUNNER_TEMP/claims-verdicts.jsonl"
: > "$verdicts"
: > "$amendments"
calls=0 ran=0 indet=0 amendments_count=0

# claims <verb> [args…]: one doc-tools claims call (stdin closed: an adapter
# never reads the runner's), its raw output kept in
# $RUNNER_TEMP/claims-<n>.json (CLAIMS_OUT) and its verdict object appended
# to the verdicts; a call that prints no single JSON object is recorded as a
# stand-in {verb, exit: 2, error}. An exit other than 0 or 1 (2: could not
# run; 3: usage) makes the run indeterminate.
claims() {
  local rc=0
  calls=$((calls + 1))
  CLAIMS_OUT="$RUNNER_TEMP/claims-$calls.json"
  "$DOC_TOOLS" claims "$@" ${base_args[@]+"${base_args[@]}"} < /dev/null > "$CLAIMS_OUT" || rc=$?
  if jq -se 'length == 1 and (.[0] | type) == "object"' "$CLAIMS_OUT" > /dev/null 2>&1; then
    jq -c --argjson rc "$rc" '. + {exit: (.exit // $rc)}' "$CLAIMS_OUT" >> "$verdicts"
    ran=$((ran + 1))
  else
    jq -nc --arg verb "$1" --argjson rc "$rc" \
      '{verb: $verb, enabled: true, exit: 2, error: "doc-tools.sh claims \($verb) exited \($rc) without a verdict object (its message is above)"}' \
      >> "$verdicts"
  fi
  case "$rc" in
    0 | 1) ;;
    *) indet=1 ;;
  esac
}

# is_completed <plan>: a `**Status**: Completed` line outside a code fence,
# or front matter `status: completed` (the plan parser's rule, any case).
is_completed() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 && /^---[ ]*$/ { fm = 1; next }
    fm == 1 {
      if ($0 ~ /^(---|\.\.\.)[ ]*$/) { fm = 2; next }
      if (tolower($0) ~ /^status[ ]*:[ ]*["\047]?completed["\047]?[ ]*$/) found = 1
      next
    }
    /^[ ]*(```|~~~)/ { fence = !fence; next }
    !fence && tolower($0) ~ /^[ ]*([-+*][ ]+)?\*\*status(\*\*:|:\*\*)[ ]*completed([^a-z]|$)/ { found = 1 }
    END { exit !found }' "$1"
}

judge_sample=""
case "$MODE" in
  pr)
    claims validate --all
    claims run --all
    # The plans to attest. Config "plans" are globs whose * also matches /
    # (as a case pattern's does).
    globs="$PLAN_GLOBS_DEFAULT"
    if [ -f docs/spec-claims/config.json ]; then
      globs=$(jq -r --arg d "$PLAN_GLOBS_DEFAULT" 'if type == "object" and (.plans | type) == "array"
        then .plans[] | strings else $d end' docs/spec-claims/config.json 2>/dev/null) \
        || globs="$PLAN_GLOBS_DEFAULT"
    fi
    changed="$RUNNER_TEMP/claims-changed-files.txt"
    # -z: git quotes no name.
    git diff -z --name-only --no-renames "$base...$head" | tr '\000' '\n' > "$changed" \
      || cannot_run "git diff $base...$head failed"
    while IFS= read -r plan; do
      matched=0
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        # shellcheck disable=SC2254  # the glob is meant to match
        case "$plan" in $g) matched=1 ;; esac
      done <<< "$globs"
      [ "$matched" = 1 ] && [ -f "$plan" ] || continue
      stem=${plan##*/}
      stem=${stem%.*}
      gates="docs/spec-claims/gates/$stem"
      [ -d "$gates" ] || continue
      [ -f "$gates/final.json" ] || is_completed "$plan" || continue
      grep -qxF -- "$plan" "$changed" || grep -qxF -- "$gates/final.json" "$changed" || continue
      claims attest --plan "$plan" --final
    done < <(git ls-files -z | tr '\000' '\n')
    # The amendment batch, read from the merge-base. Its count from the JSON
    # rows; the Markdown only when there is one (it always has a heading).
    mb=$(git merge-base "$base" "$head") || cannot_run "no merge-base of $base and $head"
    rc=0
    "$DOC_TOOLS" claims rulings --range "$mb..$head" ${base_args[@]+"${base_args[@]}"} \
      < /dev/null > "$RUNNER_TEMP/claims-rulings.json" || rc=$?
    if ! amendments_count=$(jq -er '.results | length' "$RUNNER_TEMP/claims-rulings.json" 2>/dev/null); then
      echo "doc-superpowers: claims rulings exited $rc without a verdict object: the amendment batch is unknown."
      amendments_count=0
      indet=1
    elif [ "$amendments_count" -gt 0 ]; then
      rc=0
      "$DOC_TOOLS" claims rulings --range "$mb..$head" --format markdown ${base_args[@]+"${base_args[@]}"} \
        < /dev/null > "$amendments" || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "doc-superpowers: claims rulings --format markdown exited $rc: the amendment batch is not posted."
        : > "$amendments"
        amendments_count=0
        indet=1
      fi
    fi
    ;;
  scheduled)
    claims run --all --scheduled --judge-sample 3
    judge_sample=$(jq -r '(.judge_sample // []) | map(tostring | gsub("[\\s,]"; "")) | join(",")' "$CLAIMS_OUT" 2>/dev/null || true)
    claims promote --reverify --all
    claims validate --all
    ;;
esac

jq -s '.' "$verdicts" > "$report" || cannot_run "cannot write $report"
counts=$(jq -r '[(map(.findings // [] | length) | add // 0),
                 (map(select((.exit // 0) > 1 or .error != null or ((.indeterminate // []) | length) > 0)) | length)]
                | "\(.[0]) \(.[1])"' "$report") || cannot_run "cannot read $report"
# shellcheck disable=SC2086  # two numbers
set -- $counts
findings="$1"
[ "$2" -eq 0 ] || indet=1

if [ "$ran" -eq 0 ]; then
  jq -r '.[] | select(.error != null) | "  \(.verb): \(.error)"' "$report"
  cannot_run "no claims call printed a verdict (is $DOC_TOOLS older than the claims verbs?)"
fi

if [ "$findings" -gt 0 ]; then
  status=findings
elif [ "$indet" = 1 ]; then
  status=indeterminate
else
  status=ok
fi
out status "$status"
out findings "$findings"
out report "$report"
out amendments "$amendments"
out amendments_count "$amendments_count"
if [ "$MODE" = scheduled ]; then
  out judge_sample "$judge_sample"
fi

scope_note="${base:+ for ${base:0:12}...${head:0:12}}"
echo "Spec claims$scope_note: $status, $findings finding(s), $amendments_count amendment(s)."
jq -r '[.[] | .verb as $v | (.findings // [])[] | "  \($v): \(.check // "") \(.claim // .doc // "") \(.message // "")"] | .[:200][]' "$report"
jq -r '[.[] | .verb as $v | ((.indeterminate // [])[] | "  \($v) (indeterminate): \(.claim // .node // "") \(.message // .reason // "")"),
        (select(.error != null) | "  \($v) (could not run): \(.error)")] | .[:200][]' "$report"

case "$status" in
  findings)
    if [ "$MODE" = pr ]; then
      echo "::error::doc-superpowers: $findings spec-claims finding(s) for this change (listed above; the verdicts are in $report)."
      exit 1
    fi
    ;;
  indeterminate)
    if [ "$MODE" = pr ] && [ "$STRICT" = 1 ]; then
      echo "::error::doc-superpowers: some spec claims could not be checked (DOC_SUPERPOWERS_STRICT=1): an adapter reported indeterminate or failed (listed above). A host sets up its test environment before this step."
      exit 1
    fi
    echo "::warning::doc-superpowers: some spec claims could not be checked: an adapter reported indeterminate or failed (listed above). A host sets up its test environment before this step."
    ;;
esac

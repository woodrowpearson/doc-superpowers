#!/usr/bin/env bash
# Tests for the canonical Spec Status Model and its call sites.
#
# These are prose-consistency regression guards, not behavioural tests. Issue #12's
# defect recurred across two releases (v2.12.0 -> v2.12.3) because nothing asserted the
# template text. This suite pins the guarded language and fails if the unconditional
# phrasing returns.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

ACTIONS="$(cat "$REPO_ROOT/references/spec-lifecycle-actions.md")"

echo "=== spec status model tests ==="

echo "--- canonical model section ---"
assert_contains "$ACTIONS" "## Spec Status Model" "canonical model section exists"
assert_contains "$ACTIONS" "any status not listed in the ladder" "exempt class is open-world"
assert_contains "$ACTIONS" "R1 — Read before write" "R1 defined"
assert_contains "$ACTIONS" "R2 — Monotonic" "R2 defined"
assert_contains "$ACTIONS" "R3 — Open-world exemption" "R3 defined"
assert_contains "$ACTIONS" "R4 — Scope-gated advancement" "R4 defined"
assert_contains "$ACTIONS" ":constraint" "constraint role suffix documented"
assert_contains "$ACTIONS" "Evaluation order" "evaluation order documented"

echo "--- plan-phase templates ---"
assert_not_contains "$ACTIONS" 'Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`.' \
  "unconditional per-chunk status write removed"
assert_not_contains "$ACTIONS" "Set all specs to Implemented" \
  "unconditional finalize step heading removed"
assert_not_contains "$ACTIONS" "Update every governing spec's \`Status\` to \`Implemented\`" \
  "unconditional finalize status write removed"
assert_contains "$ACTIONS" "Update spec status (guarded)" \
  "per-chunk step heading is guarded"
assert_contains "$ACTIONS" "Advance implemented specs (scope-gated)" \
  "finalize step heading is scope-gated"
assert_contains "$ACTIONS" "R2 — never regress" \
  "per-chunk template cites monotonicity"
assert_contains "$ACTIONS" "Never write a status earlier than the current value (R2)" \
  "finalize partial-coverage branch is R2-guarded"
assert_contains "$ACTIONS" '`<path>:target` or `<path>:constraint`' \
  "plan-phase --specs input documents the role suffix"

echo "--- execute phase and spec-verify ---"
assert_contains "$ACTIONS" 'per the **Spec Status Model**' \
  "execute-phase aligned branch cites the model"
assert_contains "$ACTIONS" '`Approved` → `Implemented` (verification passes)' \
  "execute-phase ladder includes Approved"
assert_not_contains "$ACTIONS" "Are all governing specs in \`Implemented\` status?" \
  "spec-verify status check no longer requires Implemented unconditionally"
assert_contains "$ACTIONS" "**constraint** → **not a finding**" \
  "spec-verify exempts constraint specs"
assert_contains "$ACTIONS" "never reach \`Implemented\` by design" \
  "spec-verify exempts Active reference specs"
assert_not_contains "$ACTIONS" "**PASS:** All governing specs in \`Implemented\` status AND" \
  "spec-verify verdict no longer requires all specs Implemented"
assert_contains "$ACTIONS" "required to be \`Implemented\` by the Status check" \
  "spec-verify verdict scoped to specs the status check requires"
assert_contains "$ACTIONS" '`Approved` is human-set' \
  "ladder notes that automation never writes Approved"
assert_contains "$ACTIONS" "treated as constraint references by inference" \
  "spec-verify reports inferred constraints informationally"
assert_contains "$ACTIONS" "at an unrecognized status" \
  "spec-verify reports unrecognized statuses informationally"
assert_contains "$ACTIONS" "Constraint references and specs at exempt statuses are excluded" \
  "spec-verify coverage check excludes constraint and exempt specs"

AGENTPROMPT="$(cat "$REPO_ROOT/references/agent-prompt-template.md")"
assert_contains "$AGENTPROMPT" "Exempt specs sit outside the ladder by design" \
  "review-agent template exempts non-ladder statuses from P1"
assert_not_contains "$AGENTPROMPT" 'Spec has `Status: Draft` but code exists' \
  "review-agent template no longer flags any Draft spec with code as P1"

echo "--- template vocabulary and wrapper contract ---"
DOCSPEC="$(cat "$REPO_ROOT/references/doc-spec.md")"
PROTOCOL="$(cat "$REPO_ROOT/references/spec-lifecycle-protocol.md")"

assert_contains "$DOCSPEC" \
  "**Status**: Draft | In Review | Approved | Implemented | Active | Deprecated | Superseded" \
  "spec template vocabulary includes Active and Deprecated"
assert_contains "$DOCSPEC" "Spec Status Model" \
  "spec template points at the canonical model"
assert_contains "$DOCSPEC" "**Status**: Proposed | Active | Superseded | Deprecated" \
  "ADR template vocabulary is unchanged"
assert_contains "$PROTOCOL" '`<path>:target` or `<path>:constraint`' \
  "wrapper-author --specs contract documents the role suffix"
assert_contains "$PROTOCOL" "Constraint specs are never written" \
  "wrapper-author output contract states constraint specs are never written"

echo "--- evals ---"
EVALS="$(cat "$REPO_ROOT/evals/evals.json")"

assert_not_contains "$EVALS" "set all specs to Implemented" \
  "eval no longer asserts the unconditional finalize behaviour"
assert_contains "$EVALS" "spec-inject-plan-mixed-statuses" \
  "issue #12 reproduction eval exists"
assert_not_contains "$EVALS" "all should be Implemented" \
  "eval 11 no longer asserts the unconditional spec-verify status rule"
if jq empty "$REPO_ROOT/evals/evals.json" >/dev/null 2>&1; then JSON_OK=0; else JSON_OK=1; fi
assert_eq "0" "$JSON_OK" "evals.json is valid JSON"

echo "--- final-review fixes ---"
assert_contains "$ACTIONS" 'never write `In Review` over a later status' \
  "canonical partial-coverage branch is R2-qualified"
assert_contains "$ACTIONS" "sanctioned outcome for a partially-covered target" \
  "spec-verify does not flag deliberately-held targets"
assert_contains "$ACTIONS" "Match statuses case-insensitively" \
  "status matching semantics defined"
assert_contains "$AGENTPROMPT" "Rows are evaluated top-down" \
  "review-agent table states row precedence"

TEMPLATES="$(cat "$REPO_ROOT/references/output-templates.md")"
assert_contains "$TEMPLATES" "### Informational (P3)" \
  "compliance report has a surface for the P3 informational lines"

WORKFLOWS="$(cat "$REPO_ROOT/docs/workflows/doc-superpowers.md")"
CONVENTIONS="$(cat "$REPO_ROOT/docs/conventions.md")"
assert_not_contains "$WORKFLOWS" "set all specs to \`Implemented\`" \
  "workflow doc no longer restates the unconditional finalize"
assert_not_contains "$WORKFLOWS" "are all governing specs in \`Implemented\` status?" \
  "workflow doc no longer restates the unconditional status check"
assert_not_contains "$CONVENTIONS" 'Transitions: `Draft` → `In Review` (first implementation chunk) → `Implemented` (verification passes).' \
  "conventions doc no longer states the pre-fix three-rung ladder"

echo "--- closing pass ---"
assert_contains "$DOCSPEC" 'spec-verify` is read-only' \
  "spec template note does not attribute Status writes to spec-verify"
assert_not_contains "$ACTIONS" "two **P3 informational** lines" \
  "P3 informational line count is not stale"
assert_contains "$ACTIONS" 'held at `In Review` by design' \
  "spec-verify reports deliberately-held targets informationally"
assert_contains "$WORKFLOWS" "never writing over a later status" \
  "workflow doc's finalize summary carries the monotonicity qualifier"

GUIDE="$(cat "$REPO_ROOT/docs/codebase-guide.md")"
assert_not_contains "$GUIDE" "all should be Implemented" \
  "codebase guide does not restate the unconditional status check"
assert_not_contains "$WORKFLOWS" "All specs implemented" \
  "workflow diagram source does not restate the unconditional PASS condition"

echo "--- final consistency ---"
NOTES="$(cat "$REPO_ROOT/RELEASE-NOTES.md")"
assert_not_contains "$NOTES" "gains two non-blocking P3 informational lines" \
  "release note states the correct P3 informational line count"
assert_contains "$GUIDE" "targets held at In Review with recorded remaining scope are not findings" \
  "codebase guide lists all three status-check carve-outs"
assert_contains "$EVALS" "targets held at In Review with recorded remaining scope are not findings" \
  "eval 11 lists all three status-check carve-outs"
assert_not_contains "$CONVENTIONS" '| `Superseded` | Exempt | Replaced by another spec | `spec-generate` |' \
  "conventions table does not attribute a Status: Superseded write to spec-generate"
assert_contains "$ACTIONS" "any other non-ladder status — never contribute to a FAIL verdict" \
  "FAIL-exemption sentence keeps the exempt class open-world"

echo "--- coverage-check arity ---"
assert_not_contains "$ACTIONS" "for three-way check" \
  "canonical file does not contradict itself on coverage arity"
assert_not_contains "$WORKFLOWS" "three-way alignment" \
  "workflow doc states five-way coverage alignment"
assert_not_contains "$WORKFLOWS" "Three-way coverage check" \
  "workflow doc diagram and tables state five-way"
assert_not_contains "$GUIDE" "Three-way coverage check" \
  "codebase guide states five-way coverage"
assert_not_contains "$EVALS" "three-way coverage check" \
  "eval 11 states five-way coverage"
assert_contains "$WORKFLOWS" "CLAUDE.md → Filesystem" \
  "workflow doc lists the CLAUDE.md coverage axis"
assert_contains "$WORKFLOWS" "README.md → Capabilities" \
  "workflow doc lists the README.md coverage axis"

echo "--- previously-unpinned surfaces ---"
SKILLMD="$(cat "$REPO_ROOT/skills/doc-superpowers/SKILL.md")"
OVERVIEW="$(cat "$REPO_ROOT/docs/architecture/system-overview.md")"

assert_not_contains "$SKILLMD" "Only update status and Implementation Notes when aligned;" \
  "SKILL.md does not state that alignment alone licenses a status write"
assert_contains "$SKILLMD" "**Spec Status Model** permits the write" \
  "SKILL.md gates status writes on the model"
assert_not_contains "$OVERVIEW" "auto-update spec status" \
  "system overview does not state unconditional status auto-update"
assert_contains "$OVERVIEW" "Spec Status Model" \
  "system overview cites the canonical model"

echo "--- amendment role (:amends) ---"
# The amendment leg has the same failure shape as issue #12: prose is the only
# carrier, so nothing but an assertion stops it regressing to "there are two roles".
assert_contains "$ACTIONS" ":amends" "amends role suffix documented"
assert_contains "$ACTIONS" "constraint reference, amendment" \
  "roles heading names all three roles"
assert_contains "$ACTIONS" "Inference never yields **amendment**" \
  "amendment is explicit-only"
assert_contains "$ACTIONS" "status-neutral by construction" \
  "amendment writes no status"
assert_contains "$ACTIONS" \
  'A co-move of a value or line inside a spec the plan `implements` or `constrains` is not an amendment' \
  "boundary sentence present byte-verbatim"
assert_contains "$ACTIONS" "Task N+1a: Land the spec amendment(s) for this chunk" \
  "per-chunk amendment task template exists"
assert_contains "$ACTIONS" "grep -n -A4 'AMENDED 20'" \
  "landed-check is the two-stage grep, not a bare block search"
assert_contains "$ACTIONS" "passes vacuously on any spec some earlier work amended" \
  "template says why the citation filter is load-bearing"
assert_contains "$ACTIONS" "amendment citation unverified (no \`--plan\`)" \
  "no-plan degradation emits a WARN rather than a silent pass"
assert_contains "$ACTIONS" "P1 Amendment not landed" \
  "review mode has an amendment finding"
assert_contains "$PROTOCOL" ':amends' \
  "wrapper-author --specs contract documents the amends suffix"
assert_contains "$SKILLMD" ':amends' \
  "SKILL.md quick routing documents the amends suffix"

print_summary

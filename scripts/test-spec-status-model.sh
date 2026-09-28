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
assert_contains "$ACTIONS" "Task N+1a: Land the spec amendment for {spec-path}" \
  "per-spec amendment task template exists, titled by spec path"
# I-11 (T12) replaced the `grep -n -A4 'AMENDED 20'` window (not section-aware;
# a citation past line 5 of the block was missed) with a section-aware check of
# the block's first line. It is still two-stage: find the dated block, then
# prove it cites this plan.
assert_contains "$ACTIONS" "awk -v h='{section-heading}'" \
  "landed-check is section-aware (reads only the amended section), not a bare block search"
assert_not_contains "$ACTIONS" "grep -n -A4 'AMENDED 20'" \
  "the -A4 window (misses a citation past the block's fifth line) is gone"
assert_contains "$ACTIONS" "passes vacuously on any spec some earlier work amended" \
  "template says why the citation filter is load-bearing"
assert_contains "$ACTIONS" "WARN: amendment citation unverified (no --plan)" \
  "no-plan degradation emits the verbatim WARN rather than a silent pass"
# Single quotes keep the backticks literal. The old needle escaped them
# ('…(no \`--plan\`)'), and inside single quotes a backslash is literal too, so
# it searched for a string that can never occur and the guard passed on the
# regressed text as well (FU4/V-FU4). The self-check pins the needle's shape.
BACKTICKED_WARN='amendment citation unverified (no `--plan`)'
assert_contains "$BACKTICKED_WARN" '(no `--plan`)' "guard needle carries literal backticks"
assert_not_contains "$BACKTICKED_WARN" '\' "guard needle carries no literal backslash"
assert_not_contains "$ACTIONS" "$BACKTICKED_WARN" \
  "the backticked WARN variant is gone — one literal, both sides"
assert_contains "$ACTIONS" "Status at plan time: {status}" \
  "injector records the plan-time status in the emitted task"
assert_contains "$ACTIONS" "single owner of that call" \
  "update-index on an amendment spec has exactly one owner"
# I-11 (T12): one Task N+1a per spec per chunk made every chunk before the one
# that writes the block FAIL its landed-check. It is injected once, in the chunk
# that holds the plan task quoting the block.
assert_contains "$ACTIONS" "in the chunk that contains Task {N}" \
  "one amendment task per spec, in the chunk that writes the block"
assert_not_contains "$ACTIONS" "per \`:amends\` spec per chunk" \
  "no per-chunk amendment task (it FAILed in every chunk before Task N)"
assert_contains "$ACTIONS" "P1 Amendment not landed" \
  "review mode has an amendment finding"
assert_contains "$PROTOCOL" ':amends' \
  "wrapper-author --specs contract documents the amends suffix"
assert_contains "$SKILLMD" ':amends' \
  "SKILL.md quick routing documents the amends suffix"

# =============================================================================
# I-11 (sweep 05ea982, Task 12) — the skill prompt ↔ tool contract.
#
# The prompt layer is how agents drive the tools, and it drifted from them in
# both directions (routing to verbs that reject the input or replace the index,
# a review-pr base that was always empty, repo scripts auto-run from a PR
# checkout). These guards pin contracts, not paragraphs: the verbs each index
# change routes to, the commands the prompt tells an agent to run — several of
# them are extracted from the markdown and EXECUTED against fixtures below —
# and the forbidden patterns.
# =============================================================================

# assert_line_matches <text> <ERE> <msg>: some line of <text> matches <ERE>.
assert_line_matches() {
  local text="$1" re="$2" msg="$3" rc=0
  grep -qE -- "$re" <<<"$text" || rc=$?
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$rc" -eq 0 ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    no line matches (rc %s): %s\n" "$msg" "$rc" "$re"
  fi
}

# assert_no_line_matches <text> <ERE> <msg>: no line of <text> matches <ERE>.
assert_no_line_matches() {
  local text="$1" re="$2" msg="$3" rc=0 hits
  hits=$(grep -nE -- "$re" <<<"$text") || rc=$?
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$rc" -eq 1 ]; then
    _pass "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    matching lines (rc %s):\n%s\n" "$msg" "$rc" "$hits"
  fi
}

# _section <text> <heading prefix>: the section whose heading line starts with
# <prefix>, up to the next heading of the same or a higher level. Fence-aware:
# a `# comment` inside a code block is not a heading, and a ``` line inside a
# ```` block does not close it.
_section() {
  awk -v h="$2" '
    function fence(s,   m) { if (match(s, /^[[:space:]]*```+/)) { m = substr(s, RSTART, RLENGTH); gsub(/[[:space:]]/, "", m); return length(m) } return 0 }
    { k = fence($0); if (k) { if (!f) f = k; else if (k >= f) f = 0 } }
    !s && index($0, h) == 1 { s = 1; n = index($0, " ") - 1; print; next }
    s && !f && !k && /^#+ / { m = index($0, " ") - 1; if (m <= n) exit }
    s' <<<"$1"
}

# _bash_block_after <text> <line prefix>: the body of the first ```bash block
# after the line starting with <prefix>, its indent (a block inside a numbered
# step) stripped.
_bash_block_after() {
  awk -v h="$2" '
    !s && index($0, h) == 1 { s = 1; next }
    s && !b && /^[[:space:]]*```bash/ { b = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; next }
    b && /^[[:space:]]*```[[:space:]]*$/ { exit }
    b { print substr($0, ind + 1) }' <<<"$1"
}

_read() { cat "$1" 2>/dev/null || true; }

RELREF="$(_read "$REPO_ROOT/references/release.md")"
HOOKSREF="$(_read "$REPO_ROOT/references/hooks.md")"
MAPPINGS="$(_read "$REPO_ROOT/references/tool-mappings.md")"
INTEGRATION="$(_read "$REPO_ROOT/references/integration-patterns.md")"
# The prompt layer: every file an agent reads as instructions.
PROMPTS="$SKILLMD
$ACTIONS
$PROTOCOL
$RELREF
$HOOKSREF
$INTEGRATION
$AGENTPROMPT
$TEMPLATES
$DOCSPEC
$MAPPINGS"
CI="$REPO_ROOT/scripts/hooks/ci"

echo "--- I-11: tool resolution ---"
assert_contains "$SKILLMD" 'ROOT="${CLAUDE_SKILL_DIR}/../.."' \
  "ROOT is the plugin root, two levels above the skill's base directory"
assert_contains "$SKILLMD" 'DOC_TOOLS="$ROOT/scripts/doc-tools.sh"' "DOC_TOOLS is derived from ROOT"
assert_contains "$SKILLMD" '[ -x "$DOC_TOOLS" ] ||' "an unresolved DOC_TOOLS stops the run"
assert_not_contains "$SKILLMD" 'DOC_TOOLS="$(printf' "the plugin-cache-only glob resolution is gone"
assert_no_line_matches "$PROMPTS" 'sort -V' "no GNU-only sort -V in the prompt layer (BSD sort lacks it)"
_root_line=$(grep -nF 'DOC_TOOLS="$ROOT/scripts/doc-tools.sh"' <<<"$SKILLMD" | head -1 | cut -d: -f1 || true)
_cache_line=$(grep -nF 'plugins/cache/doc-superpowers' <<<"$SKILLMD" | head -1 | cut -d: -f1 || true)
assert_true "the plugin cache is only a fallback (tried after \$ROOT: line ${_cache_line:-none} > ${_root_line:-none})" \
  test -n "$_root_line" -a -n "$_cache_line" -a "${_cache_line:-0}" -gt "${_root_line:-0}"
assert_contains "$SKILLMD" '$ROOT/references/' "references are read from \$ROOT"
assert_contains "$SKILLMD" '"$ROOT/scripts/hooks/install.sh" status' "sync's hook summary runs the installer from \$ROOT"
assert_contains "$HOOKSREF" '"$ROOT/scripts/hooks/install.sh"' "hooks routes to the installer under \$ROOT"
assert_contains "$MAPPINGS" "## Tool resolution" "tool-mappings says how every client resolves the tooling"

# Execute the resolution block the way an agent would, in three layouts.
_resolve_block=$(_bash_block_after "$SKILLMD" '### Detect Bundled Tooling')
assert_contains "$_resolve_block" 'ROOT=' "the first bash block under Detect Bundled Tooling is the resolution block"
_rt=$(harness_mktemp_d resolve)
mkdir -p "$_rt/plug/skills/doc-superpowers" "$_rt/plug/scripts" "$_rt/home1" "$_rt/home3" "$_rt/work"
printf '#!/bin/sh\n' > "$_rt/plug/scripts/doc-tools.sh"
chmod +x "$_rt/plug/scripts/doc-tools.sh"
_cache="$_rt/home2/.claude/plugins/cache/doc-superpowers/doc-superpowers"
for _v in 2.9.0 2.10.0 2.11.0 latest; do
  mkdir -p "$_cache/$_v/scripts"
  case "$_v" in 2.11.0) ;; *)
    printf '#!/bin/sh\n' > "$_cache/$_v/scripts/doc-tools.sh"
    chmod +x "$_cache/$_v/scripts/doc-tools.sh" ;;
  esac
done
_plug_real=$(cd "$_rt/plug" && pwd -P)
_cache_real=$(cd "$_cache" && pwd -P)
# 1. Claude Code substituted ${CLAUDE_SKILL_DIR}: the skill's own plugin root.
_sub=$(printf '%s\n' "$_resolve_block" | sed "s|\${CLAUDE_SKILL_DIR}|$_rt/plug/skills/doc-superpowers|g")
_out=$(cd "$_rt/work" && HOME="$_rt/home1" "$BASH_BIN" -c "$_sub" 2>&1) || true
assert_contains "$_out" "DOC_TOOLS=$_plug_real/scripts/doc-tools.sh" \
  "resolution: the substituted skill dir wins (no plugin cache needed)"
# 2. Nothing substituted (another client, or a stale placeholder): the newest
#    plugin-cache version that HAS the tool, in numeric order (2.10.0 > 2.9.0;
#    2.11.0 lacks doc-tools.sh, `latest` is not a version).
_out=$(cd "$_rt/work" && env -u CLAUDE_SKILL_DIR HOME="$_rt/home2" "$BASH_BIN" -c "$_resolve_block" 2>&1) || true
assert_contains "$_out" "DOC_TOOLS=$_cache_real/2.10.0/scripts/doc-tools.sh" \
  "resolution fallback: newest cached version with the tool, numeric order (no sort -V)"
# 3. Neither: stop, non-zero.
_rc=0
_out=$(cd "$_rt/work" && env -u CLAUDE_SKILL_DIR HOME="$_rt/home3" "$BASH_BIN" -c "$_resolve_block" 2>&1) || _rc=$?
assert_true "resolution with no tooling anywhere stops non-zero (rc $_rc)" test "$_rc" -ne 0
assert_contains "$_out" "doc-tools.sh" "…naming what it could not find"
# The agent's Bash tool may be zsh (macOS default): a bare unmatched glob is a
# hard error there, so the block must not depend on one.
if command -v zsh >/dev/null 2>&1; then
  _out=$(cd "$_rt/work" && env -u CLAUDE_SKILL_DIR HOME="$_rt/home2" zsh -f -c "$_resolve_block" 2>&1) || true
  assert_contains "$_out" "DOC_TOOLS=$_cache_real/2.10.0/scripts/doc-tools.sh" "resolution fallback also works under zsh"
  _rc=0
  _out=$(cd "$_rt/work" && env -u CLAUDE_SKILL_DIR HOME="$_rt/home3" zsh -f -c "$_resolve_block" 2>&1) || _rc=$?
  assert_not_contains "$_out" "no matches found" "…and never trips zsh's no-match glob error"
else
  record_skip "resolution under zsh (zsh not installed)"
fi

echo "--- I-11: index-write routing ---"
assert_contains "$SKILLMD" "#### Index-write routing" "SKILL.md carries the index-write routing table"
assert_line_matches "$SKILLMD" '^\| New doc[^|]*\|[^|]*`add-entry[ `]' "routing: new doc → add-entry"
assert_line_matches "$SKILLMD" '^\| Doc moved or renamed[^|]*\|[^|]*`move-entry[ `]' "routing: moved/renamed → move-entry"
assert_line_matches "$SKILLMD" '^\| Doc archived[^|]*\|[^|]*`move-entry[ `][^|]*`deprecate-entry[ `]' \
  "routing: archived → move-entry + deprecate-entry"
assert_line_matches "$SKILLMD" '^\| Doc deleted[^|]*\|[^|]*`remove-entry[ `]' "routing: deleted → remove-entry"
assert_line_matches "$SKILLMD" '^\| Doc edited and read against its code[^|]*\|[^|]*`update-index[ `]' \
  "routing: edited and verified → update-index"
assert_line_matches "$SKILLMD" "^\\| Doc's code refs changed[^|]*\\|[^|]*\`set-code-refs[ \`]" "routing: refs changed → set-code-refs"
assert_line_matches "$SKILLMD" '^\| No index exists yet[^|]*\|[^|]*`build-index[ `]' "routing: build-index only when no index exists"
assert_not_contains "$SKILLMD" "Rebuild doc-index" "no migration step rebuilds (replaces) the index"
# Every instruction to run build-index is conditioned on there being no (valid)
# index: build-index replaces an index, dropping every entry's metadata.
_bi_q='no (`?docs/)?`?\.doc-index\.json|[Nn]o index|[Mm]issing `?(docs/)?\.doc-index|not exist|found no|[Oo]nly when|malformed|refuses'
_bi_unqualified=$(grep -E '(pipe|Pipe|run|Run|call|Call|use|Use|rebuild|Rebuild|suggest|suggesting)[^.]{0,60}build-index' <<<"$SKILLMD
$ACTIONS
$PROTOCOL
$RELREF
$HOOKSREF
$INTEGRATION
$AGENTPROMPT
$TEMPLATES
$(cat "$REPO_ROOT/evals/evals.json")
$(cat "$CI"/*.yml)" | grep -vE -- "$_bi_q" || true)
assert_eq "" "$_bi_unqualified" "every instruction to run build-index says 'only when no index exists'"
_sync=$(_section "$SKILLMD" '### `sync`')
assert_contains "$_sync" '`untracked`' "sync: handles untracked docs…"
assert_contains "$_sync" 'add-entry' "…with add-entry"
assert_contains "$_sync" '`missing`' "sync: handles missing docs…"
assert_contains "$_sync" 'remove-entry' "…deleted → remove-entry"
assert_contains "$_sync" 'move-entry' "…moved → move-entry"
assert_contains "$_sync" "N/8 ci" "sync's hook summary counts the 8 CI templates"
assert_contains "$(_section "$ACTIONS" '### Plan Phase')" 'set-code-refs' "Task N+1 refines code_refs with set-code-refs"
assert_contains "$(_section "$ACTIONS" '### Execute Phase')" 'set-code-refs' "execute phase refines code_refs with set-code-refs"

echo "--- I-11: review-pr base and scope ---"
assert_contains "$SKILLMD" 'BASE=$(git symbolic-ref --short -q refs/remotes/origin/HEAD) || BASE=origin/main' \
  "review-pr: base from origin/HEAD, else origin/main"
assert_not_contains "$SKILLMD" '|| echo "main"' "review-pr: the '|| echo main' that bound to sed (BASE=\"\") is gone"
_review=$(_section "$SKILLMD" '### `review-pr`')
assert_contains "$_review" '[ -s "$CHANGED" ] ||' "review-pr: an empty diff stops the review"
# The range a CI prompt names (its base and head SHAs) is the form review-pr
# takes from the caller.
assert_contains "$_review" '<base-sha>...<head-sha>' "review-pr takes the caller's <base-sha>...<head-sha> range"
assert_contains "$(cat "$CI/doc-review-pr.yml")" 'base.sha }}...${{ github.event.pull_request.head.sha }}' \
  "…which is the form doc-review-pr's prompt passes"
# Execute review-pr's changed-file block the way an agent would, in four layouts.
_review_block=$(_bash_block_after "$_review" '2. **Identify changed files.**')
assert_contains "$_review_block" 'BASE=$(git symbolic-ref' "the first bash block of review-pr step 2 is the changed-file block"
_rp() { # <repo> → _rp_out, _rp_rc
  local tmp
  tmp=$(harness_mktemp_d rp-tmp)
  _rp_rc=0
  _rp_out=$(cd "$1" && TMPDIR="$tmp" "$BASH_BIN" -c "$_review_block" 2>&1) || _rp_rc=$?
}
_bt=$(harness_mktemp_d base)
(
  cd "$_bt" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git update-ref refs/remotes/origin/main HEAD
  mkdir -p src && echo x > src/x.js && git add src/x.js
  git -c user.name=t -c user.email=t@t commit -q -m two
) >/dev/null 2>&1
_rp "$_bt"
assert_contains "$_rp_out" "BASE=origin/main " "review-pr base without origin/HEAD (actions/checkout) is origin/main, never empty"
_rp_changed=$(sed -n 's/.* CHANGED=//p' <<<"$_rp_out" | head -1)
assert_eq "0|src/x.js" "$_rp_rc|$(cat "$_rp_changed" 2>/dev/null)" "…and lists the PR's changed files"
(cd "$_bt" && git update-ref refs/remotes/origin/trunk HEAD~1 && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk) >/dev/null 2>&1
_rp "$_bt"
assert_contains "$_rp_out" "BASE=origin/trunk " "review-pr base follows origin/HEAD when it is set"
(cd "$_bt" && git update-ref refs/remotes/origin/trunk HEAD) >/dev/null 2>&1
_rp "$_bt"
assert_contains "$_rp_out" "no changes against origin/trunk" "review-pr: an empty diff ends the review…"
assert_not_contains "$_rp_out" "CHANGED=" "…before any scoped check (no changed-file list handed on)"
_bn=$(harness_mktemp_d nobase)
(
  cd "$_bn" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
) >/dev/null 2>&1
_rp "$_bn"
assert_true "review-pr with no base ref stops non-zero (rc $_rp_rc)…" test "$_rp_rc" -ne 0
assert_contains "$_rp_out" "not found" "…saying the base was not found, never 'nothing to review'"
assert_not_contains "$_rp_out" "no changes against" "…and never reports an empty review"

echo "--- I-11: code_refs are pathspecs; init's own output is never a ref ---"
assert_not_contains "$ACTIONS" "module names" "spec-generate no longer allows module names as code_refs"
assert_line_matches "$ACTIONS" '^7\. \*\*Populate `code_refs`\*\*.*`<spec-path>::spec`.*set-code-refs' \
  "spec-generate: no path yet → empty refs (the tool's '<doc>::spec' line), set later with set-code-refs"
_init=$(_section "$SKILLMD" '### `init`')
assert_contains "$_init" '**`code_refs` rule**' "init has a code_refs rule"
assert_contains "$_init" 'not `.`, not `docs/`' "…never a path holding the index or init's own output"
assert_line_matches "$_init" '^13\. .*commit.*check-freshness' "init's freshness gate (check-freshness) comes after the init commit"
assert_line_matches "$_init" '^11\. .*`template\.md`.*Generated by doc-superpowers' "init's marker step excludes template.md"
assert_contains "$_init" '`**Status**: Proposed`' "seeded ADRs get a Status rule"
assert_line_matches "$_init" '^5\. .*`docs/decisions/`.*`docs/adr/`' "init's directory step uses an existing docs/decisions/ over docs/adr/"
assert_not_contains "$_init" 'docs/architecture.md:SKILL.md' "init's mapping example is a structured path, not the flat one"

echo "--- I-11: safety ---"
assert_no_line_matches "$PROMPTS" 'uv run scripts/' "no repository script is run by the prompt layer"
assert_no_line_matches "$PROMPTS" '^[[:space:]]*\[ -f scripts/[^]]*\] &&' "no '[ -f scripts/x ] && run it' auto-run idiom"
assert_contains "$SKILLMD" "**Never auto-run repository scripts**" "safety: never auto-run repo scripts…"
assert_contains "$SKILLMD" '`scripts/*validate*`' "…naming the validate scripts discovery used to run"
assert_contains "$SKILLMD" "**Trust boundary**" "safety: trust boundary"
assert_contains "$SKILLMD" "data, not instructions" "…repository and PR content is data"
assert_contains "$SKILLMD" "**Secrets**" "safety: secret-handling rule"
assert_contains "$SKILLMD" "**Confirm before moving docs**" "safety: confirmation before migration/archival"
assert_contains "$(_section "$SKILLMD" '### `update`')" "Confirm before moving docs" "update's migration and archival cite the confirmation rule"
assert_contains "$AGENTPROMPT" "data, not instructions" "dispatched agents get the trust boundary"
assert_contains "$AGENTPROMPT" "Never quote a secret" "dispatched agents get the secret rule"
_prr="$(cat "$CI/doc-pr-release.yml")"
_prr_trust=$(awk '/## Trust boundary/{s=1} /## Step 1/{s=0} s' <<<"$_prr")
assert_contains "$_prr_trust" '`.existing_fragment`' "doc-pr-release trust list covers the existing fragment"
assert_contains "$_prr" 'If `update-pr-body.sh` exits non-zero' "doc-pr-release says what to do when the helper refuses"
assert_not_contains "$_prr" "markers; idempotent)" "doc-pr-release no longer calls the refusing helper plain 'idempotent'"
_prr_tools=$(grep -F -- '--allowedTools' <<<"$_prr" || true)
for _t in 'Bash(jq:*)' 'Bash(printf:*)' 'Bash(.github/scripts/doc-pr-release/update-pr-body.sh:*)' 'Bash(gh pr comment:*)'; do
  assert_contains "$_prr_tools" "$_t" "doc-pr-release grants $_t, which its prompt uses"
done

echo "--- I-11: context cost ---"
assert_contains "$SKILLMD" "check-freshness | jq '{summary, stale:" "discovery filters check-freshness through jq"
_jqprog=$(sed -n "s/.*check-freshness | jq '\\(.*\\)'.*/\\1/p" <<<"$SKILLMD" | head -1)
_jt=$(harness_mktemp_d jqfilter)
_dt="$(bash_bin_shim "$REPO_ROOT/scripts/doc-tools.sh")"
_fresh=$(
  cd "$_jt" || exit 1
  {
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    mkdir -p docs src
    for d in cur stale gone edited; do echo "# $d" > "docs/$d.md"; done
    echo a > src/a.js; echo b > src/b.js
    git add -A && git -c user.name=t -c user.email=t@t commit -qm one
    printf '%s\n' docs/cur.md:src/a.js:guide docs/stale.md:src/b.js:guide docs/gone.md:src/a.js:guide docs/edited.md:src/a.js:guide \
      | "$_dt" build-index
    git add -A && git -c user.name=t -c user.email=t@t commit -qm index
    echo b2 > src/b.js; rm docs/gone.md; echo more >> docs/edited.md; echo "# new" > docs/new.md
    git add -A && git -c user.name=t -c user.email=t@t commit -qm two
  } >/dev/null 2>&1
  "$_dt" check-freshness 2>/dev/null
) || true
_filtered=$(jq -c "$_jqprog" <<<"$_fresh" 2>&1) || true
assert_eq '["stale","summary","untracked"]' "$(jq -c 'keys' <<<"$_filtered" 2>&1)" "the filter keeps only {summary, stale, untracked}"
assert_eq '["docs/edited.md","docs/gone.md","docs/stale.md"]' "$(jq -c '[.stale[].doc] | sort' <<<"$_filtered" 2>&1)" \
  "…stale lists stale, missing and edited docs, never current ones"
assert_eq '["docs/new.md"]' "$(jq -c '.untracked' <<<"$_filtered" 2>&1)" "…untracked lists the docs the index lacks"
assert_contains "$SKILLMD" '**REQUIRED:** Read `$ROOT/references/release.md`' "release body lives behind a REQUIRED pointer"
assert_contains "$SKILLMD" '**REQUIRED:** Read `$ROOT/references/hooks.md`' "hooks body lives behind a REQUIRED pointer"
assert_not_contains "$SKILLMD" '| `doc-pr-full-cycle` (AI) |' "the consent table moved out of SKILL.md (one copy)"
assert_not_contains "$SKILLMD" "**Offer git tag**" "the release steps moved out of SKILL.md (one copy)"
# The moved text keeps every earlier Task's lockstep edit (T8, T9, T10).
assert_contains "$RELREF" '$DOC_TOOLS fragments merge <start> HEAD`' "release.md: merge before drafting (T10)"
assert_contains "$RELREF" '$DOC_TOOLS fragments merge <start> HEAD --remove' "release.md: removal pinned to doc-release's allowedTools (T10)"
assert_contains "$RELREF" '**Exit 3 = refused:**' "release.md: the exit-3 refusal (T10)"
assert_contains "$RELREF" 'git commit -m "release: vX.Y.Z"' "release.md: one release commit before the tag (T10)"
assert_contains "$RELREF" 'the release commit must reach `main`' "release.md: the release commit must reach main (T10)"
assert_contains "$RELREF" "has none of these manifests" "release.md: bump only when the host project has the manifests"
assert_contains "$HOOKSREF" "**Never pass \`--force\` unless the user asked for exactly that.**" "hooks.md: never --force (T8)"
assert_contains "$HOOKSREF" "**Consent before \`--ci\`.**" "hooks.md: consent before --ci (T8)"
assert_contains "$HOOKSREF" '| `doc-pr-full-cycle` (AI) |' "hooks.md: the consent table (T8)"
assert_contains "$HOOKSREF" '**per-user**' "hooks.md: the Claude tier is per-user (R8)"
assert_contains "$HOOKSREF" 'bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/<hook>.sh' "hooks.md: hook commands via CLAUDE_PROJECT_DIR (R8)"
assert_contains "$HOOKSREF" "an integrity check against agent mistakes, not a sandbox" "hooks.md: the checker is not a sandbox (T9)"
assert_contains "$HOOKSREF" "ends green as superseded" "hooks.md: the superseded wording (T9)"
assert_not_contains "$HOOKSREF" "a newer run covers it" "hooks.md: no 'a newer run covers it' (T9)"
# Every doc-tools verb release.md runs is one doc-release's agent may run.
_rel_tools=$(grep -F -- '--allowedTools' "$CI/doc-release.yml" || true)
_rel_verbs=$(grep -oE '\$DOC_TOOLS [a-z-]+' <<<"$RELREF" | sed 's/.* //' | sort -u || true)
assert_true "release.md runs doc-tools verbs (found: $(printf '%s ' $_rel_verbs))" test -n "$_rel_verbs"
for _v in $_rel_verbs; do
  assert_contains "$_rel_tools" "Bash(.github/scripts/doc-tools.sh $_v:*)" "doc-release's --allowedTools grants the release verb '$_v'"
done
# A template whose agent runs discovery (it pipes check-freshness through jq,
# and lists changed files with `git -c core.quotePath=false diff`) grants both.
for _wf in doc-audit-update doc-pr-full-cycle doc-review-pr doc-spec-verify; do
  _tl=$(grep -F -- '--allowedTools' "$CI/$_wf.yml" || true)
  _n=$(grep -c . <<<"$_tl")
  _jq=$(grep -cF 'Bash(jq:*)' <<<"$_tl" || true)
  _gd=$(grep -cF 'Bash(git -c core.quotePath=false diff --name-only:*)' <<<"$_tl" || true)
  assert_eq "$_n/$_n" "$_jq/$_gd" "$_wf: every AI step grants Bash(jq:*) and Bash(git -c core.quotePath=false diff --name-only:*) (discovery)"
done

echo "--- I-11: spec lifecycle ---"
_plan=$(_section "$ACTIONS" '### Plan Phase')
assert_contains "$_plan" 'copied from `--specs`' "injected tasks carry the caller's explicit role markers"
assert_line_matches "$_plan" 'Any other status .*\(R3\).*skip Steps 2–4' \
  "per-chunk Task N+1: an exempt-status target skips Steps 2–4 (no notes, no code_refs, no update-index)"
assert_contains "$ACTIONS" "**One per-chunk writer.**" "one per-chunk Status writer"
assert_contains "$ACTIONS" "four **P3 informational** lines" "four P3 informational lines, as listed"
assert_not_contains "$ACTIONS" "three **P3 informational** lines" "…not three"
assert_contains "$ACTIONS" 'held short of `Implemented`' "spec-verify carve-out keys on the recorded remaining scope…"
assert_line_matches "$ACTIONS" '\*\*target\*\* held .*`In Review`.*`Approved`.*\*\*not a finding\*\*' "…so an Approved partial target is not a finding either"
assert_line_matches "$AGENTPROMPT" '^\| Spec held .*`Approved`.*Not a finding' "review-agent table: an Approved partial target is not a finding"
assert_line_matches "$(_section "$ACTIONS" '### Vocabulary')" '`Active`, `Deprecated` and `Superseded`.*unrecognized-status line' \
  "the unrecognized-status line skips the sanctioned Active/Deprecated/Superseded"
assert_contains "$(_section "$ACTIONS" '### Execute Phase')" '$DOC_TOOLS status' "execute phase queries specs with status (check-freshness takes no doc argument)"
assert_not_contains "$SKILLMD" "in both modes and FAILs" "review mode reports a P1 finding; only post-execute has a FAIL verdict"
assert_not_contains "$PROTOCOL" "must exist and be committed" "protocol: no uncalled-for 'committed' prerequisite"
assert_not_contains "$PROTOCOL" "must exist (bootstrapped if missing)" "protocol: no self-contradicting prerequisite"
assert_eq "1" "$(grep -c -- '^- `--plan=<path>` — Path to the implementation plan' <<<"$PROTOCOL" || true)" "protocol: plan-phase --plan listed once"
for _f in PROTOCOL INTEGRATION; do
  eval "_txt=\$$_f"
  assert_contains "$_txt" "spec-inject --phase=execute --specs=<paths> --plan=<path>" "$_f: execute phase passes --plan"
  assert_contains "$_txt" "spec-verify --mode=post-execute --specs=<paths> --design-doc=<path> --plan=<path>" "$_f: post-execute passes --plan"
  assert_contains "$_txt" "spec-verify --mode=review --changed-files=<paths> --specs=<paths> --plan=<path>" "$_f: review passes --specs and --plan"
done
assert_contains "$TEMPLATES" "Amendments verified" "compliance report surfaces the amendment P3 line"

# Execute the landed-check the way an injected task would.
_lc=$(grep -E "^[[:space:]]*awk -v h='\{section-heading\}'" <<<"$ACTIONS" | head -1 | sed 's/^[[:space:]]*//' || true)
assert_contains "$_lc" "{plan-path}" "the landed-check is one command with {section-heading}, {spec-path} and {plan-path}"
_lt=$(harness_mktemp_d landed)
cat > "$_lt/spec.md" <<'SPEC'
# SPEC-UI-041: Recents

**Status**: Implemented

## Summary

> ⚠️ **AMENDED 2026-09-01 — other.** Landed by `docs/plans/other.md` Task 2. Old claim.

## Design

Text.

```bash
# a comment, not a heading
```

> ⚠️ **AMENDED 2026-09-02 — sort order.** Landed by `docs/plans/p.md` Task 3. The list was
> sorted by name; it is sorted by recency.

### Details

> ⚠️ **AMENDED 2026-09-03 — nested.** Landed by `docs/plans/q.md` Task 1.

> ⚠️ **AMENDED 2026-09-05 — wrapped.** The citation is on the
> second line. Landed by `docs/plans/w.md` Task 1.

> ⚠️ **AMENDED 2026-09-06 — earlier layout.** The section used to say X;
> it says Y now, because Z.
> Landed by `docs/plans/old.md` Task 2.

> ⚠️ **AMENDED 2026-09-07 — no citation.** This block names no plan.

Landed by `docs/plans/out.md` Task 9 — but outside the block.

## Testing

> ⚠️ **AMENDED 2026-09-04 — test.** Landed by `docs/plans/r.md` Task 1.
SPEC
_landed() { # <section heading> <plan path> → PASS | FAIL (NOCMD: no landed-check to run)
  local cmd="$_lc"
  [ -n "$cmd" ] || { echo NOCMD; return 0; }
  cmd=${cmd//\{section-heading\}/$1}
  cmd=${cmd//\{spec-path\}/$_lt/spec.md}
  cmd=${cmd//\{plan-path\}/$2}
  if (cd "$_lt" && "$BASH_BIN" -c "$cmd") >/dev/null 2>&1; then echo PASS; else echo FAIL; fi
}
assert_eq "PASS" "$(_landed '## Design' docs/plans/p.md)" "landed-check: a block in the section, citing this plan → PASS (past a fenced '# comment')"
assert_eq "PASS" "$(_landed '## Design' docs/plans/q.md)" "landed-check: a subsection belongs to its section"
assert_eq "FAIL" "$(_landed '## Design' docs/plans/other.md)" "landed-check: a block in another section → FAIL"
assert_eq "FAIL" "$(_landed '## Design' docs/plans/r.md)" "landed-check: the next section is outside → FAIL"
assert_eq "FAIL" "$(_landed '## Design' docs/plans/nope.md)" "landed-check: a block citing another plan → FAIL"
assert_eq "PASS" "$(_landed '## Design' docs/plans/w.md)" "landed-check: a citation on a later line of the block counts (block-aware)"
assert_eq "PASS" "$(_landed '## Design' docs/plans/old.md)" "landed-check: the earlier layout (citation on the block's last line) still passes"
assert_eq "FAIL" "$(_landed '## Design' docs/plans/out.md)" "landed-check: a citation outside the block (the next paragraph) → FAIL"
# One landed-check: every copy the reference carries is the same command.
_lc_all=$(grep -E "^[[:space:]]*awk -v h='\{section-heading\}'" <<<"$ACTIONS" | sed 's/^[[:space:]]*//' || true)
assert_true "the landed-check appears in the canonical definition and the Task N+1a template ($(grep -c . <<<"$_lc_all") copies)" \
  test "$(grep -c . <<<"$_lc_all")" -ge 2
assert_eq "1" "$(sort -u <<<"$_lc_all" | grep -c .)" "every copy of the landed-check is byte-identical"
assert_contains "$PROTOCOL" 'Landed by `<plan path>` Task <N>' "the wrapper contract states where the citation may go"

echo "--- I-11: generated-doc templates (FU3) ---"
_noslot=$(awk '
  /^!\[[^]]*\]\([^)]*\.png\)/ { want = 1; img = $0; n++; next }
  want && /^[[:space:]]*$/ { next }
  want == 1 { if ($0 != "<details>") { print "no <details> under " img; want = 0 } else want = 2; next }
  want == 2 { if ($0 !~ /<summary>Mermaid source<\/summary>/) print "no Mermaid-source summary under " img; want = 0 }
  END { if (n < 8) print "only " n " PNG links found" }' <<<"$DOCSPEC")
assert_eq "" "$_noslot" "every template PNG has a <details><summary>Mermaid source</summary> slot under it"
assert_not_contains "$DOCSPEC" '\`\`\`' "templates nest real fences (a four-backtick outer fence), never \\\`\\\`\\\`"
assert_contains "$DOCSPEC" "(#docsguidesgetting-startedmd)" "doc-spec ToC anchor for getting-started resolves"
assert_not_contains "$DOCSPEC" "Skip this file entirely if the project has no HTTP/RPC/GraphQL API" \
  "api-contracts.md has one predicate: the api-contracts scope"
assert_contains "$DOCSPEC" 'when the `api-contracts` scope is detected' "…stated in its template"
assert_no_line_matches "$DOCSPEC" '^\| `data-layer.md` \| ERD .*\| Always \|$' "the ERD is not 'Always' while data-layer.md is conditional"
assert_contains "$DOCSPEC" 'when the `data-layer` scope is detected' "…one predicate: the data-layer scope"
assert_line_matches "$DOCSPEC" '^\| `architecture/\{component\}.md` \|' "Required Diagrams has a component row"
assert_line_matches "$DOCSPEC" '^\| Index files \|' "naming table covers the README index files"
assert_not_contains "$DOCSPEC" "workflow-primary.png" "no diagram name that no template references"
assert_not_contains "$DOCSPEC" "diagrams/workflow-{name}.png)" "agentic diagrams do not share the workflow-{slug} namespace"
assert_contains "$DOCSPEC" "agentic-{skill-name}.png" "…they have their own"
assert_line_matches "$(_section "$DOCSPEC" '## docs/conventions.md')" '^## Testing$' "the testing scope has its section in the conventions template"
assert_line_matches "$(_section "$DOCSPEC" '## docs/architecture/system-overview.md')" '^## Packages$' "the monorepo scope has its section in the system-overview template"
assert_line_matches "$(_section "$DOCSPEC" '## docs/codebase-guide.md')" '^## Packages$' "…and in the codebase-guide template"
assert_not_contains "$DOCSPEC" 'Updated by `init` and `audit`' "audit is read-only: it updates no index file"
assert_not_contains "$DOCSPEC" "Sync with actual SKILL.md actions" "README sync is about the host project, not doc-superpowers"
assert_not_contains "$DOCSPEC" "(init, audit, review-pr, update, diagram, sync, hooks, release, spec-*)" "…nor its action list"
assert_contains "$(_section "$DOCSPEC" '### Spec Numbering')" "docs/archive/specs/" "spec numbers count archived specs (never reissued)"
assert_contains "$(_section "$DOCSPEC" '### ADR Numbering')" "docs/archive/adr/" "ADR numbers count archived ADRs"
# R4: T4 corrected the live schema table; T12 verifies it.
assert_contains "$DOCSPEC" '| `schema_version` | integer |' "schema table: schema_version (R4)"
assert_contains "$DOCSPEC" '`docs.<path>.implementation`' "schema table: per-entry implementation (R4)"
assert_not_contains "$DOCSPEC" "(currently 1)" "schema table: no 'version (currently 1)' (R4)"
assert_not_contains "$SKILLMD" "auto-detected from docs/ structure" "the [scope] argument is defined, not 'auto-detected from docs/'"
assert_not_contains "$SKILLMD" "A{Has design doc?}" "spec routing: a lingering design doc does not shadow inject/verify"
assert_contains "$SKILLMD" "[sync]" "action routing has a sync leaf"
assert_contains "$SKILLMD" "[spec-* actions]" "action routing has a spec leaf"
assert_contains "$SKILLMD" '`workflows/{workflow-name}.md`' "the primary workflow doc has a filename"
assert_not_contains "$SKILLMD" '| `adr` (existing) |' "adr/specs README + template are unconditional, as init step 6 says"
assert_contains "$SKILLMD" '| `docs/architecture.md` | `docs/architecture/system-overview.md` |' "update has a flat→structured mapping table"
assert_not_contains "$SKILLMD" "rg -l" "diagram finds Mermaid docs without rg (not a guaranteed tool)"
assert_contains "$SKILLMD" "find .claude/skills skills -maxdepth 2 -name SKILL.md" "agentic discovery finds plugin-layout skills, glob-free"
assert_not_contains "$SKILLMD" "against actual SKILL.md actions" "audit/sync compare README with the host project, not this skill"
_upd=$(_section "$SKILLMD" '### `update`')
assert_contains "$_upd" '`--report=<path>`' "update takes an explicit --report"
assert_not_contains "$_upd" "most recent \`docs/plans/*-audit-report.md\`" "update never picks up the newest report on its own"
assert_contains "$_upd" "docs/archive/plans/" "update archives the report it applied"

echo "--- I-11 fix round 1: archive, tool resolution, wording, verbs ---"
# The applied report is archived whether or not git tracks it or the index
# lists it (audit writes it untracked and unindexed); CI leaves it in place.
_upd=$(_section "$SKILLMD" '### `update`')
_arch_block=$(_bash_block_after "$_upd" '7. **Archive the applied report**')
assert_contains "$_arch_block" 'git ls-files --error-unmatch' "archive: git mv only when git tracks the report…"
assert_line_matches "$_upd" '^7\. \*\*Archive the applied report\*\*.*CI workflow' "…and a CI workflow leaves it in place"
assert_line_matches "$SKILLMD" '^- \*\*Confirm before moving docs\*\*.*`update`.*audit report' "Safety Rules name the one exception: update archiving its applied audit report"
_ar() { # <repo> <report path> → _ar_rc, _ar_out
  local cmd="$_arch_block"
  cmd=${cmd//docs\/plans\/YYYY-MM-DD-audit-report.md/$2}
  _ar_rc=0
  _ar_out=$(cd "$1" && DOC_TOOLS="$_dt" "$BASH_BIN" -c "$cmd" 2>&1) || _ar_rc=$?
}
for _layout in tracked untracked; do
  _at=$(harness_mktemp_d "archive-$_layout")
  (
    cd "$_at" || exit 1
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    mkdir -p docs/plans && echo "# guide" > docs/guide.md
    git add -A && git -c user.name=t -c user.email=t@t commit -qm one
    printf 'docs/guide.md::guide\n' | "$_dt" build-index
    echo "## Documentation Freshness Audit" > docs/plans/2026-09-01-audit-report.md
    if [ "$_layout" = tracked ]; then
      printf 'docs/plans/2026-09-01-audit-report.md::plan\n' | "$_dt" add-entry
      git add -A && git -c user.name=t -c user.email=t@t commit -qm report
    fi
  ) >/dev/null 2>&1
  _ar "$_at" docs/plans/2026-09-01-audit-report.md
  assert_eq "0" "$_ar_rc" "archive ($_layout report) exits 0${_ar_out:+ — $(tr '\n' ' ' <<<"$_ar_out")}"
  assert_true "archive ($_layout): the report is in docs/archive/plans/" test -f "$_at/docs/archive/plans/2026-09-01-audit-report.md"
  assert_true "archive ($_layout): and gone from docs/plans/" test ! -e "$_at/docs/plans/2026-09-01-audit-report.md"
  _keys=$(jq -c '.docs | keys' "$_at/docs/.doc-index.json" 2>&1)
  if [ "$_layout" = tracked ]; then
    assert_eq '["docs/archive/plans/2026-09-01-audit-report.md","docs/guide.md"]' "$_keys" "archive (tracked): the index entry is re-keyed with move-entry"
    assert_contains "$(git -C "$_at" status --porcelain)" "R  docs/plans/2026-09-01-audit-report.md -> docs/archive/plans/2026-09-01-audit-report.md" \
      "archive (tracked): moved with git mv (a staged rename)"
  else
    assert_eq '["docs/guide.md"]' "$_keys" "archive (untracked): the index is left alone (the report was never indexed)"
  fi
done

# Tool resolution runs for every action (hooks and release need $ROOT).
assert_line_matches "$SKILLMD" '^\*\*Discovery is universal\*\*.*Detect Bundled Tooling' "tool resolution runs for every action, hooks and release included"
assert_no_line_matches "$SKILLMD" "audit's read-only|Audit is read-only" "audit is 'edits no doc', not 'read-only' (it writes its report)"
assert_not_contains "$TEMPLATES" "Action list" "the README status rows are the project's own (no 'Action list')"
assert_contains "$RELREF" '$(ls CLAUDE.md README.md 2>/dev/null)' "release commit adds CLAUDE.md / README.md only when they exist"
assert_not_contains "$RELREF" "CLAUDE.md README.md && git commit" "…never a git add of a file the project lacks"
assert_line_matches "$_sync" 'CI workflow.*install\.sh" status' "sync skips the installer's status in a CI workflow"
# Every doc-tools verb the prompt layer names exists: the verb list comes from
# doc-tools.sh's own verb table (the dispatcher), never a list kept here.
_verbs=$(grep -E '^[a-z][a-z-]*( [a-z][a-z-]*)?[|]cmd_[a-z_]+[|](repo|deps|none)[|]' "$REPO_ROOT/scripts/doc-tools.sh" | cut -d'|' -f1 | cut -d' ' -f1 | sort -u || true)
assert_true "the verb table yields verbs ($(grep -c . <<<"$_verbs"))" test "$(grep -c . <<<"$_verbs")" -ge 15
_named=$(cat "$REPO_ROOT/skills/doc-superpowers/SKILL.md" "$REPO_ROOT"/references/*.md | grep -oE '(\$DOC_TOOLS"?|doc-tools\.sh) [a-z][a-z-]*' | sed -E 's/.* //' | sort -u || true)
assert_true "the prompt layer names doc-tools verbs ($(grep -c . <<<"$_named"))" test "$(grep -c . <<<"$_named")" -ge 10
assert_eq "" "$(comm -23 <(printf '%s\n' "$_named") <(printf '%s\n' "$_verbs") | tr '\n' ' ')" "every doc-tools verb named in SKILL.md and references/ is a real verb"
# The narrowed grant covers every quotePath diff the prompt layer runs.
_qp=$(cat "$REPO_ROOT/skills/doc-superpowers/SKILL.md" "$REPO_ROOT"/references/*.md "$CI"/*.yml | grep -oE 'git -c core\.quotePath=false diff[^`|]*' || true)
assert_true "the prompt layer runs quotePath diffs ($(grep -c . <<<"$_qp"))" test "$(grep -c . <<<"$_qp")" -ge 4
assert_eq "" "$(grep -v '^git -c core\.quotePath=false diff --name-only' <<<"$_qp" || true)" "every quotePath diff is a --name-only one (what the CI grant allows)"

echo "--- I-11: evals are machine-checkable ---"
EVALS_JSON="$REPO_ROOT/evals/evals.json"
assert_eq "true" "$(jq '[.evals[].id] | (length == (unique | length)) and all(type == "number")' "$EVALS_JSON")" "eval ids are unique integers"
assert_eq "true" "$(jq '[.evals[].name] | length == (unique | length)' "$EVALS_JSON")" "eval names are unique"
# Field contract per assertion type ($t: type; path/pattern: string or
# non-empty string array; command: string; optional negate/count/before/mode).
_schema_bad=$(jq -r '
  def strs: (type == "string" and length > 0) or (type == "array" and length > 0 and all(type == "string" and length > 0));
  .evals[] | .name as $e | .assertions[] | .name as $a | .type as $t
  | ( if ($t | IN("file_exists","file_not_exists","file_modification","no_file_modification","file_permission","file_read",
                  "content_check","tool_call_check","output_check","behavior_check")) | not then "unknown type \($t)" else empty end,
      if ($t | IN("file_exists","file_not_exists","file_modification","no_file_modification","file_permission","file_read","content_check"))
         and ((.path // null) | strs | not) then "\($t) needs path" else empty end,
      if $t == "content_check" and ((.pattern // null) | strs | not) then "content_check needs pattern" else empty end,
      if $t == "tool_call_check" and ((.command // null) | (type == "string" and length > 0) | not) then "tool_call_check needs command" else empty end,
      if $t == "file_permission" and (.mode // "") != "executable" then "file_permission needs mode: executable" else empty end,
      if has("negate") and (.negate | type) != "boolean" then "negate is not a boolean" else empty end,
      if has("count") and ((.count | type) != "number" or $t != "content_check") then "count is a number, on content_check only" else empty end,
      if has("before") and ((.before | IN("present","absent")) | not) then "before is present|absent" else empty end,
      if has("precedes") and ($t != "tool_call_check" or ((.precedes | type) != "string")) then "precedes is a string, on tool_call_check only" else empty end,
      if [.path // empty] | flatten | any(test("\\*\\*")) then "** in path (bash 3.2 has no globstar)" else empty end
    ) | "    \($e) / \($a): \(.)"' "$EVALS_JSON" 2>&1)
assert_eq "" "$_schema_bad" "every assertion carries the machine fields its type needs"
# Every pattern and command is a valid ERE (what a runner feeds grep -E).
_bad_re=""
while IFS= read -r _re; do
  [ -n "$_re" ] || continue
  _rc=0; grep -E -- "$_re" </dev/null >/dev/null 2>&1 || _rc=$?
  [ "$_rc" -le 1 ] || _bad_re="$_bad_re $_re"
done < <(jq -r '.evals[].assertions[] | (.pattern // empty | if type == "array" then .[] else . end), (.command // empty), (.precedes // empty)' "$EVALS_JSON")
assert_eq "" "$_bad_re" "every pattern and command is a valid ERE"
# A command naming a doc-tools verb names one that exists.
_bad_verb=""
for _v in $(jq -r '.evals[].assertions[] | .command // empty' "$EVALS_JSON" | grep -oE 'doc-tools\\\.sh[^a-z-]*[a-z][a-z-]*' | sed -E 's/.*[^a-z-]([a-z][a-z-]*)$/\1/' | sort -u); do
  "$_dt" "$_v" --help >/dev/null 2>&1 || _bad_verb="$_bad_verb $_v"
done
assert_eq "" "$_bad_verb" "every doc-tools verb an eval command names exists"
assert_not_contains "$EVALS" "update-index for each new spec" "eval 4 no longer asserts the verb that rejects new specs"
assert_not_contains "$EVALS" "freshness markers with current date and commit" "eval 3 no longer asserts a dated marker"
assert_eq "true" "$(jq '[.evals[] | select(.name == "spec-generate-from-design") | .assertions[] | select(.type == "tool_call_check" and (.negate // false | not)) | .command] | any(test("add-entry"))' "$EVALS_JSON")" \
  "eval 4 routes new specs to add-entry"
assert_eq "true" "$(jq '[.evals[] | select(.name == "sync-index") | .assertions[] | select(.type == "tool_call_check" and .negate == true) | .command] | any(test("build-index"))' "$EVALS_JSON")" \
  "eval 9 forbids build-index on an existing index"
# The release evals' merge check tells step 3 (merge before drafting) from
# step 8 (--remove): a pattern that also matched the removal checked nothing.
_rm_cmd='/w/.github/scripts/doc-tools.sh fragments merge v1.2.0 HEAD --remove'
_mg_cmd='/w/.github/scripts/doc-tools.sh fragments merge v1.2.0 HEAD 2>merge.err'
_bad_mg=""
while IFS= read -r _re; do
  [ -n "$_re" ] || continue
  { grep -qE -- "$_re" <<<"$_mg_cmd" && ! grep -qE -- "$_re" <<<"$_rm_cmd"; } || _bad_mg="$_bad_mg [$_re]"
done < <(jq -r '.evals[] | select(.name | IN("release-draft","release-fragment-merge")) | .assertions[]
                | select(.type == "tool_call_check" and ((.command // "") | contains("fragments merge")) and ((.command // "") | contains("remove") | not)) | .command' "$EVALS_JSON")
assert_eq "" "$_bad_mg" "the release evals' step-3 merge check matches the merge and not the --remove call"
assert_eq "true" "$(jq --arg rm "$_rm_cmd" '[.evals[] | select(.name == "release-fragment-merge") | .assertions[] | select(.precedes) | .precedes] | length > 0' "$EVALS_JSON")" \
  "release-fragment-merge orders the merge before the --remove call (precedes)"
_pr=$(jq -r '.evals[] | select(.name == "release-fragment-merge") | .assertions[] | select(.precedes) | .precedes' "$EVALS_JSON" | head -1)
assert_true "…and its precedes pattern matches the --remove call" grep -qE -- "${_pr:-^$}" <<<"$_rm_cmd"
# Required cases: fixtures that build the scenario, runnable here.
_required="update-from-audit update-from-session-report spec-generate-from-design hooks-install-all sync-index release-draft spec-inject-execute spec-verify-review spec-inject-amends release-fragment-merge hooks-status-uninstall"
for _e in $_required; do
  _setup=$(jq -r --arg e "$_e" '.evals[] | select(.name == $e) | .setup // ""' "$EVALS_JSON")
  if [ -z "$_setup" ]; then
    assert_true "eval $_e has a fixture (setup)" false
    continue
  fi
  assert_eq "true" "$(jq --arg e "$_e" --arg s "$_setup" '.evals[] | select(.name == $e) | (.files | index($s)) != null' "$EVALS_JSON")" \
    "eval $_e lists its setup in files"
  _missing=""
  for _f in $(jq -r --arg e "$_e" '.evals[] | select(.name == $e) | .files[]' "$EVALS_JSON"); do
    [ -f "$REPO_ROOT/$_f" ] || _missing="$_missing $_f"
  done
  assert_eq "" "$_missing" "eval $_e: every listed file exists"
  _ft=$(harness_mktemp_d "fx-$_e")
  _rc=0
  _fo=$(cd "$_ft" && DOC_SUPERPOWERS_ROOT="$REPO_ROOT" BASH_BIN="$BASH_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$BASH_BIN" "$REPO_ROOT/$_setup" 2>&1) || _rc=$?
  assert_eq "0" "$_rc" "eval $_e: its fixture builds (and self-checks) its scenario${_fo:+ — $(tail -n 3 <<<"$_fo" | tr '\n' ' ')}"
  assert_true "eval $_e: the fixture is a git repository" git -C "$_ft" rev-parse --is-inside-work-tree
  # Anti-vacuity: a file_exists assertion must not already hold before the
  # skill runs (unless marked before: present); a file_not_exists marked
  # before: present must name a file the fixture has.
  _vac=""
  while IFS=$'\t' read -r _an _ty _bf _p; do
    [ -n "$_an" ] || continue
    # Count paths that exist (nullglob drops an unmatched glob; a plain
    # word stays, so test each one).
    _hits=$(cd "$_ft" && (shopt -s nullglob; _n=0; for _x in $_p; do [ -e "$_x" ] && _n=$((_n + 1)); done; echo "$_n"))
    case "$_ty:$_bf" in
      file_exists:present | file_not_exists:present) [ "$_hits" -gt 0 ] || _vac="$_vac $_an(expected present)" ;;
      file_exists:*) [ "$_hits" -eq 0 ] || _vac="$_vac $_an(already true)" ;;
    esac
  done < <(jq -r --arg e "$_e" '.evals[] | select(.name == $e) | .assertions[]
             | select((.type == "file_exists" or .type == "file_not_exists") and (.negate // false | not))
             | .name as $n | .type as $t | (.before // "-") as $b | ([.path] | flatten | .[]) | [$n, $t, $b, .] | @tsv' "$EVALS_JSON")
  assert_eq "" "$_vac" "eval $_e: file assertions are not vacuous against the fixture"
done

print_summary

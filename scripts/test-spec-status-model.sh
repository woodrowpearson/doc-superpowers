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
DOC_TOOLS_SHIM="$(bash_bin_shim "$REPO_ROOT/scripts/doc-tools.sh")"

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
SPECCLAIMS="$(_read "$REPO_ROOT/references/spec-claims.md")"
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
$MAPPINGS
$SPECCLAIMS"
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
assert_contains "$_sync" 'git log -1 --format=%H --diff-filter=D -- <doc>' "sync: missing → the commit that removed the doc (P-I1)…"
assert_contains "$_sync" 'git show -M --name-status --format= <that commit>' "…whose rename git show pairs"
assert_not_contains "$_sync" 'diff-filter=DR --name-status -- <doc>' "…never a log limited to the old path (it shows a rename as D)"
# Run the route as written on a committed rename: it must say R, not D.
_rn=$(harness_mktemp_d rename)
(
  cd "$_rn" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  mkdir -p docs && printf '# Getting started\n\nRun it.\n' > docs/old.md
  git add -A && git -c user.name=t -c user.email=t@t commit -qm one
  git mv docs/old.md docs/new.md && git -c user.name=t -c user.email=t@t commit -qm rename
) >/dev/null 2>&1
_rm=$(git -C "$_rn" log -1 --format=%H --diff-filter=D -- docs/old.md 2>/dev/null || true)
assert_true "the route's first command finds the renaming commit" test -n "$_rm"
assert_true "…and its second reports the rename (R<score> old new)" \
  grep -qE '^R[0-9]+[[:space:]]+docs/old\.md[[:space:]]+docs/new\.md$' <<<"$(git -C "$_rn" show -M --name-status --format= "${_rm:-HEAD}" 2>/dev/null)"
_nci=0
for _f in "$REPO_ROOT"/scripts/hooks/ci/*.yml; do [ -f "$_f" ] && _nci=$((_nci + 1)); done
assert_contains "$_sync" "N/$_nci ci" "sync's hook summary counts the CI templates ($_nci)"
assert_contains "$_sync" "ledger N/3 git, N/2 claude" "sync's hook summary adds the ledger sets"
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

# The work ledger's filing flow and review-pr's ledger leg (design
# 2026-10-18 §2, §6): step 9 runs upkeep over the PR's range, guarded so that
# it runs no repository script, and only outside CI; the ledger action routes
# /doc-superpowers ledger file to references/ledger.md's procedure.
echo "--- review-pr's ledger leg; the ledger filing flow ---"
assert_contains "$_review" 'ledger upkeep --range "$BASE...HEAD" --no-repo-adapters' \
  "review-pr step 9 runs ledger upkeep over the PR's range with --no-repo-adapters"
assert_contains "$_review" 'not in a CI run' "…and is skipped in a CI run"
assert_contains "$_review" '"could not run: <error>"' "…an upkeep that could not run is said so…"
assert_contains "$_review" 'never "none missing"' "…never as 'none missing'"
assert_contains "$_review" '`git status --porcelain` stays empty' "…and the step edits nothing"
_ledger_act=$(_section "$SKILLMD" '### `ledger`')
assert_contains "$_ledger_act" '/doc-superpowers ledger file [<title>]' "the ledger action routes /doc-superpowers ledger file…"
assert_contains "$_ledger_act" 'new --create' "…through ledger new --create…"
assert_contains "$_ledger_act" '→ **Filing an item**' "…by references/ledger.md's Filing an item"
LEDGERREF="$(_read "$REPO_ROOT/references/ledger.md")"
assert_line_matches "$LEDGERREF" '^### Filing an item$' "references/ledger.md has the Filing an item procedure…"
_filing=$(_section "$LEDGERREF" '### Filing an item')
assert_contains "$_filing" 'ledger find' "…duplicates first (ledger find)…"
assert_contains "$_filing" 'ledger new --create' "…one ledger new --create…"
assert_contains "$_filing" 'Never commit' "…and it never commits"
# The declare flow (design 2026-10-18 §7): the attended confirm-and-link step
# over upkeep. A skill flow, not a verb; review-pr step 9 only names it.
assert_contains "$_ledger_act" '/doc-superpowers ledger declare' "the ledger action routes /doc-superpowers ledger declare…"
assert_contains "$_ledger_act" '→ **Declaring after a change**' "…by references/ledger.md's Declaring after a change"
_upkeep_bullet=$(grep -F -- '- **Merge-time upkeep**' <<<"$_ledger_act")
assert_contains "$_upkeep_bullet" '/doc-superpowers ledger declare' "the Merge-time upkeep bullet points at the declare flow"
_step9=$(grep -F -- '9. **Ledger declarations**' <<<"$_review")
assert_contains "$_step9" '/doc-superpowers ledger declare' "review-pr step 9 names /doc-superpowers ledger declare…"
assert_contains "$_step9" 'never runs it' "…and only names it: the link lines are printed, never run"
assert_line_matches "$LEDGERREF" '^### Declaring after a change$' "references/ledger.md has the Declaring after a change procedure…"
_declaring=$(_section "$LEDGERREF" '### Declaring after a change')
assert_contains "$_declaring" 'never in a CI run' "…never in a CI run or for an unattended caller…"
assert_contains "$_declaring" 'never "none missing"' "…an upkeep that failed is never 'none missing'…"
assert_contains "$_declaring" '--top 0' "…a truncated item offers the same call with --top 0…"
assert_contains "$_declaring" 'ledger link <key> --changes <contract>' "…an unattributed contract the person assigns is linked alone…"
assert_contains "$_declaring" 'or `--consumes` for one the range only reads' "…or with --consumes, for one the range only reads (final review M2)…"
assert_contains "$_declaring" 'never a re-run with `--items`' "…never a re-run with --items…"
assert_contains "$_declaring" 'built from what was confirmed' "…one ledger link per item, built from what was confirmed…"
assert_contains "$_declaring" 'Never commits unless asked' "…and it never commits unless asked"
assert_contains "$(_section "$LEDGERREF" '## Merge-time upkeep')" '- **`/doc-superpowers ledger declare`**' "ledger.md: the upkeep section offers the declare flow"
assert_line_matches "$LEDGERREF" '^## Merge-time upkeep' "references/ledger.md has the Merge-time upkeep section"
assert_line_matches "$LEDGERREF" '^\| `upkeep \(--range' "…and an upkeep row in its Verbs table"

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
# Fix round 1 (18b I1): without a registry, ledger init --report writes no
# decisions file (scripts/ledger/init.sh: the proposal only); step 12b runs a
# second --report against the edited proposal before anyone fills decisions.
assert_contains "$_init" 'ledger init --report <report> --registry docs/ledger/ledgers.proposed.json' "init 12b: a second report against the edited proposal writes the decisions file"
assert_contains "$LEDGERREF" 'and **no decisions file**' "ledger.md: a report without a registry writes no decisions file"

echo "--- I-11: safety ---"
assert_no_line_matches "$PROMPTS" 'uv run scripts/' "no repository script is run by the prompt layer"
assert_no_line_matches "$PROMPTS" '^[[:space:]]*\[ -f scripts/[^]]*\] &&' "no '[ -f scripts/x ] && run it' auto-run idiom"
assert_contains "$SKILLMD" "**Never auto-run repository scripts**" "safety: never auto-run repo scripts…"
assert_contains "$SKILLMD" '`scripts/*validate_docs*`, `*validate_doc_references*`' "…naming the validate scripts discovery used to run"
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
    for d in cur stale gone edited rec-edited rec-gone; do echo "# $d" > "docs/$d.md"; done
    echo a > src/a.js; echo b > src/b.js
    git add -A && git -c user.name=t -c user.email=t@t commit -qm one
    printf '%s\n' docs/cur.md:src/a.js:guide docs/stale.md:src/b.js:guide docs/gone.md:src/a.js:guide docs/edited.md:src/a.js:guide \
      docs/rec-edited.md:src/b.js:plan docs/rec-gone.md:src/b.js:issue \
      | "$_dt" build-index
    git add -A && git -c user.name=t -c user.email=t@t commit -qm index
    echo b2 > src/b.js; rm docs/gone.md docs/rec-gone.md; echo more >> docs/edited.md; echo more >> docs/rec-edited.md; echo "# new" > docs/new.md
    git add -A && git -c user.name=t -c user.email=t@t commit -qm two
  } >/dev/null 2>&1
  "$_dt" check-freshness 2>/dev/null
) || true
_filtered=$(jq -c "$_jqprog" <<<"$_fresh" 2>&1) || true
assert_eq '["stale","summary","untracked"]' "$(jq -c 'keys' <<<"$_filtered" 2>&1)" "the filter keeps only {summary, stale, untracked}"
assert_eq '["docs/edited.md","docs/gone.md","docs/rec-gone.md","docs/stale.md"]' "$(jq -c '[.stale[].doc] | sort' <<<"$_filtered" 2>&1)" \
  "…stale lists stale, missing and edited docs, never current ones"
# C-M9: an edited record doc (a plan, an issue: never compared) is no work for
# the write actions, so the filter drops it; an edited living doc stays, and a
# record doc whose file is gone is still listed (missing).
assert_eq "true" "$(jq '.docs["docs/rec-edited.md"] | .record == true and .doc_modified == true' <<<"$_fresh" 2>&1)" \
  "fixture: check-freshness reports the edited plan as a modified record doc"
assert_eq "false" "$(jq '[.stale[].doc] | any(. == "docs/rec-edited.md")' <<<"$_filtered" 2>&1)" "…the filter drops a modified record doc (C-M9)"
assert_eq "true" "$(jq '[.stale[].doc] | any(. == "docs/edited.md")' <<<"$_filtered" 2>&1)" "…keeps a modified living doc"
assert_eq "true" "$(jq '[.stale[] | select(.doc == "docs/rec-gone.md") | .status] == ["missing"]' <<<"$_filtered" 2>&1)" "…and still lists a missing record doc"
assert_eq '["docs/new.md"]' "$(jq -c '.untracked' <<<"$_filtered" 2>&1)" "…untracked lists the docs the index lacks"
assert_contains "$SKILLMD" '**REQUIRED:** Read `$ROOT/references/release.md`' "release body lives behind a REQUIRED pointer"
assert_contains "$SKILLMD" '**REQUIRED:** Read `$ROOT/references/hooks.md`' "hooks body lives behind a REQUIRED pointer"
assert_not_contains "$SKILLMD" '| `doc-pr-full-cycle` (AI) |' "the consent table moved out of SKILL.md (one copy)"
assert_not_contains "$SKILLMD" "**Offer git tag**" "the release steps moved out of SKILL.md (one copy)"
# The moved text keeps every earlier Task's lockstep edit (T8, T9, T10).
assert_contains "$RELREF" '$DOC_TOOLS fragments merge <start> HEAD`' "release.md: merge before drafting (T10)"
assert_contains "$RELREF" "git log -1 --format=%H -S '## vX.Y.Z' -- RELEASE-NOTES.md" "release.md: an untagged latest release starts the range at its heading's commit (P-I2)"
assert_contains "$RELREF" "Only when RELEASE-NOTES.md has no version entry: the nearest release tag" "…the nearest tag only without a version entry (P-I2)"
assert_contains "$SKILLMD" "else the commit that added its \`## vX.Y.Z\` heading" "SKILL.md's release summary says so too (P-I2)"
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
# Final review fix wave (F1, F2, S-I2, P-M10): what the consent text owes the user.
assert_contains "$HOOKSREF" "**What an AI job's agent can reach**" "hooks.md: what a steered agent can reach (F1)"
assert_contains "$HOOKSREF" "approvals by GitHub Actions must not count" "hooks.md: protect the base branch and release/** with human review (F1)"
assert_contains "$HOOKSREF" "**protect the base branch and \`release/**\`**" "…both named (F1)"
assert_contains "$HOOKSREF" "also lets **any** workflow job with \`pull-requests: write\` approve pull requests" "hooks.md: the approve-PRs side effect of doc-release's setting (F1)"
assert_contains "$HOOKSREF" 'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: "1"' "hooks.md: the env scrub, documented as recommended hardening (F1)"
assert_contains "$HOOKSREF" "start no workflow run" "hooks.md: GITHUB_TOKEN commits and PRs start no workflow run (S-I2)"
assert_contains "$HOOKSREF" '"Expected"' "…so required checks wait at Expected (S-I2)"
assert_contains "$HOOKSREF" "its superseded run fails" "hooks.md: doc-pr-full-cycle's superseded run fails (F2)"
assert_contains "$HOOKSREF" "the audit report itself" "hooks.md: doc-audit-update's consent row says it commits its audit report (P-M10)"
_ceiling=$(grep -lF 'security ceiling' "$REPO_ROOT/references/hooks.md" "$CI"/*.yml "$CI"/*/*.sh 2>/dev/null || true)
assert_eq "" "$_ceiling" "no file claims the job token's permissions: are the security ceiling (F1)"
assert_eq "" "$(grep -lF 'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' "$CI"/*.yml 2>/dev/null || true)" "…and no template sets the scrub (F1: gh auth unconfirmed)"
assert_contains "$SKILLMD" 'In a doc-superpowers CI workflow, do not edit it' "update step 4: CLAUDE.md is reported, not edited, in CI (F3)"
assert_contains "$SKILLMD" 'In a doc-superpowers CI workflow, report what it needs instead of editing it' "sync step 5: likewise (F3)"
assert_contains "$SKILLMD" '`update` and `sync` edit no CLAUDE.md or README.md there' "the CI paragraph says so (F3)"
# Every doc-tools verb release.md runs is one doc-release's agent may run.
_rel_tools=$(grep -F -- '--allowedTools' "$CI/doc-release.yml" || true)
_rel_verbs=$(grep -oE '\$DOC_TOOLS [a-z-]+' <<<"$RELREF" | sed 's/.* //' | sort -u || true)
assert_true "release.md runs doc-tools verbs (found: $(printf '%s ' $_rel_verbs))" test -n "$_rel_verbs"
for _v in $_rel_verbs; do
  assert_contains "$_rel_tools" "Bash(.github/scripts/doc-tools.sh $_v:*)" "doc-release's --allowedTools grants the release verb '$_v'"
done
# A template whose agent runs discovery pipes check-freshness through jq, so
# each of its AI steps grants Bash(jq:*) — except doc-review-pr's @claude
# tag-mode job (F1): no prompt tells it to run jq (the comment is the
# request), and `jq -n env` would print the job's secrets. None grants the
# quotePath diff any more (S-M1): the prompt layer lists changed files with
# `git diff -z`, which Bash(git diff:*) covers.
for _wf in doc-audit-update doc-pr-full-cycle doc-review-pr doc-spec-verify; do
  _tl=$(awk '/^  respond:/ { r = 1; next } /^  [a-z][a-z-]*:$/ { r = 0 } !r && /--allowedTools/' "$CI/$_wf.yml")
  _n=$(grep -c . <<<"$_tl")
  _jq=$(grep -cF 'Bash(jq:*)' <<<"$_tl" || true)
  assert_eq "$_n/$_n" "$_jq/$_n" "$_wf: every AI step (but the tag-mode respond) grants Bash(jq:*) (discovery)"
  assert_eq "" "$(grep -F 'quotePath' "$CI/$_wf.yml" || true)" "$_wf: no quotePath grant or prompt (S-M1: git diff -z)"
done
_resp=$(awk '/^  respond:/ { r = 1; next } /^  [a-z][a-z-]*:$/ { r = 0 } r && /--allowedTools/' "$CI/doc-review-pr.yml")
assert_true "doc-review-pr's respond job has one --allowedTools line" test "$(grep -c . <<<"$_resp")" -eq 1
assert_not_contains "$_resp" 'Bash(jq:' "doc-review-pr's tag-mode respond job is not granted jq (F1)"

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
# The block runs as written in a fresh shell (shell variables do not survive
# between an agent's tool calls): DOC_TOOLS unset, its placeholder replaced by
# the path Detect Bundled Tooling prints (P-M4).
assert_contains "$_arch_block" "DOC_TOOLS='<the DOC_TOOLS path Detect Bundled Tooling printed>'" "archive: the block sets DOC_TOOLS itself (P-M4)"
_ar() { # <repo> <report path> [<doc-tools path>] → _ar_rc, _ar_out
  local cmd="$_arch_block"
  cmd=${cmd//docs\/plans\/YYYY-MM-DD-audit-report.md/$2}
  cmd=${cmd//<the DOC_TOOLS path Detect Bundled Tooling printed>/${3-$_dt}}
  _ar_rc=0
  _ar_out=$(cd "$1" && env -u DOC_TOOLS "$BASH_BIN" -c "$cmd" 2>&1) || _ar_rc=$?
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
# DOC_TOOLS not set to a tool: the block stops before moving anything, never
# silently leaving the index entry missing.
_at=$(harness_mktemp_d archive-unset)
(
  cd "$_at" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  mkdir -p docs/plans && echo "## Documentation Freshness Audit" > docs/plans/2026-09-01-audit-report.md
) >/dev/null 2>&1
_ar "$_at" docs/plans/2026-09-01-audit-report.md ""
assert_eq "1" "$_ar_rc" "archive with DOC_TOOLS unresolved: exits 1"
assert_true "…and moves nothing" test -f "$_at/docs/plans/2026-09-01-audit-report.md"

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
# S-M1: git quotes a name holding `"`, a backslash or a tab even with
# core.quotePath=false, and a quoted name matches no ref. The prompt layer
# lists changed files for check-freshness NUL-separated (Bash(git diff:*)
# covers it), and runs no quotePath diff (no CI grant allows one).
_qp=$(cat "$REPO_ROOT/skills/doc-superpowers/SKILL.md" "$REPO_ROOT"/references/*.md "$CI"/*.yml | grep -oE 'git -c core\.quotePath=false diff[^`|]*' || true)
assert_eq "" "$_qp" "the prompt layer runs no quotePath diff"
assert_contains "$SKILLMD" 'git diff -z --name-only --no-renames <range> | $DOC_TOOLS check-freshness --code-refs-from -' "Scoping: the changed-file list is piped NUL-separated"
assert_contains "$SKILLMD" 'git diff -z --name-only --no-renames "$BASE"...HEAD > "$CHANGED"' "review-pr step 2: likewise"

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
# A command pattern naming doc-tools.sh or install.sh must match both the
# bare and the quoted invocation ("$DOC_TOOLS" expands to a quoted path):
# `doc-tools\.sh"? <verb>`. Without the `"?`, a negated check passed
# vacuously and a positive one failed falsely (P-I3).
_unq=$(jq -r '.evals[] | .name as $e | .assertions[] | .name as $a | (.command // empty), (.precedes // empty)
  | select(test("(doc-tools|install)\\\\\\.sh ")) | "\($e)/\($a): \(.)"' "$EVALS_JSON")
assert_eq "" "$_unq" "every doc-tools.sh / install.sh command pattern allows the closing quote (\"?)"
for _q in '"/w/scripts/doc-tools.sh" check-freshness' '/w/scripts/doc-tools.sh check-freshness'; do
  assert_true "eval 2's check-freshness pattern matches: $_q" \
    grep -qE -- "$(jq -r '.evals[] | select(.name == "audit-stale-docs") | .assertions[] | select(.name == "runs-check-freshness") | .command' "$EVALS_JSON")" <<<"$_q"
done
# The release evals' merge check tells step 3 (merge before drafting) from
# step 8 (--remove): a pattern that also matched the removal checked nothing.
# Both invocation forms: bare, and the quoted path "$DOC_TOOLS" expands to.
_bad_mg=""
for _dtq in '/w/.github/scripts/doc-tools.sh' '"/w/.github/scripts/doc-tools.sh"'; do
  _rm_cmd="$_dtq fragments merge v1.2.0 HEAD --remove"
  _mg_cmd="$_dtq fragments merge v1.2.0 HEAD 2>merge.err"
  while IFS= read -r _re; do
    [ -n "$_re" ] || continue
    { grep -qE -- "$_re" <<<"$_mg_cmd" && ! grep -qE -- "$_re" <<<"$_rm_cmd"; } || _bad_mg="$_bad_mg [$_dtq: $_re]"
  done < <(jq -r '.evals[] | select(.name | IN("release-draft","release-fragment-merge")) | .assertions[]
                  | select(.type == "tool_call_check" and ((.command // "") | contains("fragments merge")) and ((.command // "") | contains("remove") | not)) | .command' "$EVALS_JSON")
done
assert_eq "" "$_bad_mg" "the release evals' step-3 merge check matches the merge and not the --remove call, quoted or not"
assert_eq "true" "$(jq --arg rm "$_rm_cmd" '[.evals[] | select(.name == "release-fragment-merge") | .assertions[] | select(.precedes) | .precedes] | length > 0' "$EVALS_JSON")" \
  "release-fragment-merge orders the merge before the --remove call (precedes)"
_pr=$(jq -r '.evals[] | select(.name == "release-fragment-merge") | .assertions[] | select(.precedes) | .precedes' "$EVALS_JSON" | head -1)
assert_true "…and its precedes pattern matches the --remove call (quoted)" grep -qE -- "${_pr:-^$}" <<<"$_rm_cmd"
assert_true "…and bare" grep -qE -- "${_pr:-^$}" <<<"/w/.github/scripts/doc-tools.sh fragments merge v1.2.0 HEAD --remove"
# P-I2: the untagged-release eval merges from a commit, never from the older tag.
_ut=$(jq -r '.evals[] | select(.name == "release-draft-untagged") | .assertions[] | select(.name == "merges-from-the-release-commit") | .command' "$EVALS_JSON")
assert_true "release-draft-untagged: the merge check matches a commit id" grep -qE -- "${_ut:-^$}" <<<'"/w/scripts/doc-tools.sh" fragments merge 0123abcd HEAD'
assert_false_re() { ! grep -qE -- "$1" <<<"$2"; }
assert_true "…and not the older tag" assert_false_re "${_ut:-^$}" '"/w/scripts/doc-tools.sh" fragments merge v1.1.0 HEAD'
# Re-review A1: an eval that scores a command SKILL.md prescribes must match
# that command as SKILL.md writes it. Eval 7 still wanted `git diff
# --name-only` after review-pr moved to `git diff -z --name-only` (S-M1), so a
# run that followed SKILL.md failed its check. The commands are read from
# SKILL.md, never copied here: each named section's ```bash lines and its
# `$DOC_TOOLS …`, `doc-tools.sh …` and `git …` spans, $DOC_TOOLS replaced by
# the path an agent substitutes. Every eval assertion that scores a SKILL.md
# command is listed with its section (<eval>|<assertion>|<section heading>),
# and each listed eval's negated checks must match none of those commands.
_skill_cmds() {
  _section "$SKILLMD" "$1" | awk '
    /^[[:space:]]*```/ { if (f) f = 0; else { f = 1; b = ($0 ~ /^[[:space:]]*```bash/) }; next }
    f { if (b) { sub(/^[[:space:]]+/, ""); if ($0 != "" && substr($0, 1, 1) != "#") print }; next }
    { s = $0
      while (match(s, /`[^`]+`/)) {
        c = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        if (c ~ /^("?\$DOC_TOOLS"?|doc-tools\.sh|git) /) print c
      } }' | sed 's|\$DOC_TOOLS|/w/scripts/doc-tools.sh|g'
}
_scored='review-pr-scoped|identifies-changed-files|### `review-pr`
review-pr-scoped|base-from-origin-head|### `review-pr`
review-pr-scoped|scoped-freshness-check|### `review-pr`
diagram-regenerate|finds-mermaid-blocks|### `diagram`
audit-stale-docs|runs-check-freshness|### Run Baseline Checks
update-from-audit|runs-verification-gate|### `update`
update-from-audit|re-keys-with-move-entry|### `update`
sync-index|runs-check-freshness|### Run Baseline Checks
sync-index|adds-untracked|### `sync`'
while IFS='|' read -r _e _a _h <&3; do
  _cmds=$(_skill_cmds "$_h")
  assert_true "SKILL.md's $_h section prescribes commands" test -n "$_cmds"
  _re=$(jq -r --arg e "$_e" --arg a "$_a" '.evals[] | select(.name == $e) | .assertions[]
          | select(.name == $a and .type == "tool_call_check" and (.negate // false | not)) | .command' "$EVALS_JSON")
  assert_true "eval $_e has the positive tool_call_check $_a" test -n "$_re"
  assert_line_matches "$_cmds" "${_re:-^$}" "eval $_e / $_a matches the command SKILL.md's $_h section prescribes"
done 3<<<"$_scored"
# …and eval 7's check matches the very command review-pr step 2 lists the
# changed files with (the one line that writes $CHANGED).
_cl=$(_skill_cmds '### `review-pr`' | grep -F '> "$CHANGED"' || true)
assert_eq "1" "$(grep -c . <<<"$_cl")" "review-pr step 2 has one command that writes \$CHANGED: $_cl"
assert_line_matches "${_cl:-<none>}" \
  "$(jq -r '.evals[] | select(.name == "review-pr-scoped") | .assertions[] | select(.name == "identifies-changed-files") | .command' "$EVALS_JSON")" \
  "eval 7 / identifies-changed-files matches review-pr step 2's own command"
for _e in $(cut -d'|' -f1 <<<"$_scored" | sort -u); do
  _cmds=$(grep -F "$_e|" <<<"$_scored" | cut -d'|' -f3 | sort -u | while IFS= read -r _h; do _skill_cmds "$_h"; done)
  while IFS= read -r _re <&3; do
    [ -n "$_re" ] || continue
    assert_no_line_matches "$_cmds" "$_re" "eval $_e: no command SKILL.md prescribes for it trips its negated check $_re"
  done 3< <(jq -r --arg e "$_e" '.evals[] | select(.name == $e) | .assertions[] | select(.type == "tool_call_check" and .negate == true) | .command' "$EVALS_JSON")
done
# The ledger eval's sweep check matches Plan Phase step 1c's command as
# spec-lifecycle-actions.md writes it, its {plan-path} placeholder resolved,
# and its negated check trips on neither ledger command the procedure injects.
_sw=$(grep -o '`\$DOC_TOOLS ledger sweep --plan {plan-path}`' <<<"$ACTIONS" | head -1 | tr -d '`' | sed 's|\$DOC_TOOLS|/w/scripts/doc-tools.sh|; s|{plan-path}|docs/superpowers/plans/2026-10-02-auth-tokens.md|')
assert_true "spec-lifecycle-actions step 1c prescribes \$DOC_TOOLS ledger sweep --plan {plan-path}" test -n "$_sw"
_swre=$(jq -r '.evals[] | select(.name == "spec-inject-ledger") | .assertions[] | select(.name == "runs-the-sweep") | .command' "$EVALS_JSON")
assert_true "eval spec-inject-ledger / runs-the-sweep matches step 1c's command" grep -qE -- "${_swre:-^$}" <<<"${_sw:-none}"
_lgneg=$(jq -r '.evals[] | select(.name == "spec-inject-ledger") | .assertions[] | select(.name == "allocates-no-key") | .command' "$EVALS_JSON")
assert_true "eval spec-inject-ledger / allocates-no-key spares the sweep, validate --plan and notices --gate" \
  assert_false_re "${_lgneg:-^$}" "${_sw:-none}
/w/scripts/doc-tools.sh ledger validate --plan docs/superpowers/plans/2026-10-02-auth-tokens.md
/w/scripts/doc-tools.sh ledger notices --gate"
assert_true "…and trips on a key allocation" grep -qE -- "${_lgneg:-^$}" <<<"/w/scripts/doc-tools.sh ledger new --ledger auth --summary x"
# Required cases: fixtures that build the scenario, runnable here.
_required="update-from-audit update-from-session-report spec-generate-from-design hooks-install-all sync-index release-draft release-draft-untagged spec-inject-execute spec-verify-review spec-inject-amends release-fragment-merge hooks-status-uninstall spec-inject-claims spec-inject-claims-inert spec-inject-ledger"
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


# =============================================================================
# I-12 (sweep 05ea982, Task 13) — cross-client packaging.
#
# The non-Claude clients were packaged on two assumptions: that every client
# shares one naming scheme, and that capability tables copied into six files
# stay in sync. These guards pin the packaging contracts instead: the OpenCode
# plugin is EXECUTED under node against its documented hook shape
# (`experimental.chat.system.transform` gets `output.system: string[]` and must
# mutate it in place); the manifests are read with jq; and the client-specific
# tool names live in exactly one file, references/tool-mappings.md, which the
# INSTALL files, AGENTS.md and GEMINI.md link to.
# =============================================================================
echo "--- I-12: cross-client packaging ---"

# Live files that describe the clients or instruct an agent. Records (plans,
# issues, archive, design specs, RELEASE-NOTES.md) are history: not scanned.
_I12_LIVE="AGENTS.md GEMINI.md README.md CLAUDE.md .cursor-plugin/INSTALL.md .codex/INSTALL.md .opencode/INSTALL.md skills/doc-superpowers/SKILL.md docs/guides/getting-started.md docs/codebase-guide.md docs/conventions.md docs/architecture/system-overview.md docs/workflows/doc-superpowers.md"
for _f in "$REPO_ROOT"/references/*.md; do
  [ "$(basename "$_f")" = tool-mappings.md ] || _I12_LIVE="$_I12_LIVE references/$(basename "$_f")"
done
# _i12_grep <ERE>: every live-file line matching <ERE>, as file:line:text.
_i12_grep() {
  local _g
  for _g in $_I12_LIVE; do
    grep -nHE -- "$1" "$REPO_ROOT/$_g" 2>/dev/null | sed "s|^$REPO_ROOT/||" || true
  done
}

# --- OpenCode: the system-prompt hook (node simulation) ---
# node is a test-time tool only (the plugin it runs is the shipped JS). No node
# → a loud, counted SKIP locally; CI sets DOC_SP_REQUIRE_NODE=1 (tests.yml),
# which turns the SKIP into a FAIL so it can never pass silently there.
node_unavailable() {
  command -v node >/dev/null 2>&1 && return 1
  if [ "${DOC_SP_REQUIRE_NODE:-0}" = "1" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    FAIL=$((FAIL + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: %s — node not found and DOC_SP_REQUIRE_NODE=1\n" "$1"
  else
    record_skip "$1 — node not found (install Node.js to run it)"
  fi
  return 0
}

if ! node_unavailable "OpenCode plugin simulation"; then
  # A copy of the plugin's package layout: the plugin resolves its root two
  # levels up and reads references/tool-mappings.md from there; package.json's
  # "type": "module" is what makes the .js an ES module.
  _oc=$(harness_mktemp_d opencode)
  mkdir -p "$_oc/.opencode/plugins" "$_oc/references"
  cp "$REPO_ROOT/.opencode/plugins/doc-superpowers.js" "$_oc/.opencode/plugins/"
  cp "$REPO_ROOT/package.json" "$_oc/"
  _oc_real=$(cd "$_oc" && pwd -P)
  cat > "$_oc/sim.mjs" <<'JS'
// Drives the plugin the way OpenCode does (anomalyco/opencode
// packages/plugin/src/index.ts, Hooks): the exported factory runs once when the
// plugin loads; "experimental.chat.system.transform" then runs on every LLM
// request with output = { system: string[] } and must mutate it in place.
import { pathToFileURL } from "node:url";
import { readFileSync, rmSync } from "node:fs";
const [plugin, mappings, mode] = process.argv.slice(2);
const expected = readFileSync(mappings, "utf-8");
const mod = await import(pathToFileURL(plugin).href);
const factory = Object.values(mod).find((v) => typeof v === "function");
const hooks = await factory({ directory: process.cwd(), worktree: process.cwd() });
// read-once: after load the hook must not need the file any more.
if (mode === "read-once") rmSync(mappings);
const r = { error: null };
const config = {};
await hooks.config(config);
r.skillsPaths = config.skills && config.skills.paths;
const output = { system: ["You are OpenCode."] };
const original = output.system;
const transform = hooks["experimental.chat.system.transform"];
try {
  await transform({ sessionID: "s1", model: {} }, output);
  // The always-on footprint (#30): what the transform ADDED, measured on the
  // emitted text in characters (UTF-16 code units), not on any source file.
  r.emitted = Array.isArray(output.system)
    ? output.system.slice(1).reduce((n, s) => n + String(s).length, 0)
    : -1;
  r.isArray = Array.isArray(output.system);
  r.sameArray = output.system === original;
  // Another plugin that pushes, running after this one.
  try { output.system.push("later plugin"); r.laterPush = true; } catch { r.laterPush = false; }
  // The same request's array handed in again gains no second copy.
  await transform({ sessionID: "s1", model: {} }, output);
  r.system = Array.isArray(output.system)
    ? output.system.map((s) => (s === expected ? "<mappings>" : s))
    : typeof output.system;
} catch (e) {
  r.error = String((e && e.message) || e);
}
console.log(JSON.stringify(r));
JS
  for _mode in load read-once; do
    cp "$REPO_ROOT/references/tool-mappings.md" "$_oc/references/"
    _rc=0
    _js=$(cd "$_oc" && node sim.mjs "$_oc/.opencode/plugins/doc-superpowers.js" "$_oc/references/tool-mappings.md" "$_mode" 2>&1) || _rc=$?
    _msg="opencode ($_mode): the plugin loads and its hooks run under node"
    [ "$_rc" -eq 0 ] || _msg="$_msg — $(tail -n 3 <<<"$_js" | tr '\n' ' ')"
    assert_eq "0" "$_rc" "$_msg"
    _js=$(tail -n 1 <<<"$_js")
    assert_json_field "$_js" '.error' "null" "opencode ($_mode): system.transform does not throw"
    assert_json_field "$_js" '.isArray' "true" "opencode ($_mode): output.system stays a string[] (the documented shape)"
    assert_json_field "$_js" '.sameArray' "true" "opencode ($_mode): …the same array, mutated in place (never replaced)"
    assert_json_field "$_js" '.laterPush' "true" "opencode ($_mode): …so a push-style plugin running after it still works"
    assert_json_field "$_js" '.system | tojson' '["You are OpenCode.","<mappings>","later plugin"]' \
      "opencode ($_mode): the array keeps its entries and gains the mappings once"
  done
  assert_json_field "$_js" '.skillsPaths | tojson' "[\"$_oc_real\"]" "opencode: the config hook registers the plugin root as a skills path"
  # Always-on footprint ceiling (#30). The plugin adds its text to EVERY
  # OpenCode system prompt, so its size is a per-request cost on every
  # consumer, and nothing else bounds it: references/tool-mappings.md grew
  # from 3,112 to 10,143 chars in two days (2026-09-27/28). Measured on what
  # the transform emits (above), never on the source file — the hook-output
  # bug of v3.0.1 was missed exactly by measuring a source. 10,590 chars at
  # 3.4.0; the ceiling, 12,000, leaves ~13% for a real addition and fails
  # another jump like that one. Raise it only on purpose, saying why in the
  # commit.
  _oc_ceiling=12000
  _oc_emitted=$(jq -r '.emitted' <<<"$_js")
  assert_true "opencode: the transform emits text (${_oc_emitted} chars)" test "$_oc_emitted" -gt 0
  assert_true "opencode: always-on footprint ${_oc_emitted} chars <= ceiling ${_oc_ceiling} (#30)" test "$_oc_emitted" -le "$_oc_ceiling"
fi

# --- Cursor: manifest and install path ---
_json_ok() { jq -e . "$1" >/dev/null 2>&1; }
_cp="$REPO_ROOT/.cursor-plugin/plugin.json"
assert_true ".cursor-plugin/plugin.json is valid JSON" _json_ok "$_cp"
# Cursor reads `skills` as path(s) to skill directories (cursor.com/docs/reference/plugins);
# omitted, it scans the plugin's skills/ directory.
_skills=$(jq -r 'if has("skills") then ([.skills] | flatten | map(sub("^\\./"; "") | sub("/+$"; "")) | join(",")) else "skills" end' "$_cp" 2>&1) || true
assert_eq "skills" "$_skills" ".cursor-plugin/plugin.json: skills points at ./skills/ (or is omitted: Cursor's default)"
assert_file_exists "$REPO_ROOT/$_skills/doc-superpowers/SKILL.md" "…where the skill is"
_cursor="$(_read "$REPO_ROOT/.cursor-plugin/INSTALL.md")"
assert_contains "$_cursor" "~/.cursor/plugins/local/doc-superpowers" \
  "Cursor INSTALL: the manual install goes to Cursor's local-plugin folder"
assert_eq "" "$(_i12_grep '\.cursor/plugins/doc-superpowers')" \
  "…and no live doc installs into ~/.cursor/plugins/<name> (Cursor loads only plugins/local/)"
assert_no_line_matches "$_cursor" 'ln -s' "…as a real directory: Cursor skips a symlink whose target is outside plugins/local"

# --- Gemini CLI: the skill is loaded on demand, not imported ---
_gem="$(_read "$REPO_ROOT/GEMINI.md")"
assert_no_line_matches "$_gem" '^@.*SKILL\.md' \
  "GEMINI.md does not @-import SKILL.md (the extension's skills/ exposes it on demand)"
assert_line_matches "$_gem" '^@\./references/tool-mappings\.md[[:space:]]*$' \
  "GEMINI.md @-imports the tool mapping (how the mapping reaches Gemini)"
_bad=""
while IFS= read -r _imp; do
  [ -n "$_imp" ] || continue
  _p="${_imp#@}"
  [ -f "$REPO_ROOT/${_p#./}" ] || _bad="$_bad $_imp"
done < <(grep -E '^@' <<<"$_gem" || true)
assert_eq "" "$_bad" "GEMINI.md: every @ import resolves to a file"
assert_contains "$_gem" "skills/doc-superpowers/" "GEMINI.md points Gemini at the skill's directory"
_gx="$REPO_ROOT/gemini-extension.json"
assert_eq "GEMINI.md" "$(jq -r '.contextFileName // ""' "$_gx" 2>&1)" "gemini-extension.json loads GEMINI.md as its context file"

# --- One capability matrix ---
# Client-specific tool names appear in references/tool-mappings.md and nowhere
# else live (copied tables drifted in five files).
_names='run_shell_command|write_todos|activate_skill|google_web_search|web_fetch|grep_search|ask_user|invoke_agent|spawn_agent|wait_agent|update_plan|exec_command|apply_patch|request_user_input|todowrite|websearch|webfetch'
assert_eq "" "$(_i12_grep "(^|[^A-Za-z0-9_])($_names)([^A-Za-z0-9_]|\$)")" \
  "client tool names appear only in references/tool-mappings.md"
assert_eq "" "$(_i12_grep '^\|[[:space:]]*(Hook Tier|Capability|Feature)[[:space:]]*\|')" \
  "no capability / hook-tier / feature-parity table outside references/tool-mappings.md"
assert_eq "" "$(_i12_grep '[Ff]ull (feature )?parity|Anthropic-ecosystem|[Ss]ame (tool )?(names )?as Claude Code')" \
  "no parity claims: each client's support is stated once, in the matrix"
for _f in .cursor-plugin/INSTALL.md .codex/INSTALL.md .opencode/INSTALL.md AGENTS.md; do
  assert_contains "$(_read "$REPO_ROOT/$_f")" "references/tool-mappings.md" "$_f links to the capability matrix"
done

# _cell <table text> <row key> <column header>: the trimmed cell of the first
# pipe table in <table text> whose first cell is <row key>.
_cell() {
  awk -F'|' -v key="$2" -v col="$3" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    !hdr && /^\|/ { for (i = 2; i < NF; i++) if (trim($i) == col) c = i; hdr = 1; next }
    hdr && !/^\|/ { exit }
    hdr && c && trim($2) == key { print trim($c); exit }' <<<"$1"
}
_tools=$(_section "$MAPPINGS" "## Tool names")
assert_line_matches "$_tools" '^\| *Claude Code *\| *Cursor *\| *Codex *\| *OpenCode *\| *Gemini CLI *\|' \
  "tool-mappings: one Tool names table, a column per client"
# row|column|token the cell must hold (documented names; sources in the file).
while IFS='|' read -r _row _col _tok; do
  [ -n "$_row" ] || continue
  assert_contains "$(_cell "$_tools" "\`$_row\`" "$_col")" "\`$_tok\`" "tool-mappings: $_row in $_col is \`$_tok\`"
done <<'ROWS'
Read|OpenCode|read
Read|Gemini CLI|read_file
Write|OpenCode|write
Edit|OpenCode|edit
Edit|Codex|apply_patch
Edit|Gemini CLI|replace
Bash|OpenCode|bash
Bash|Codex|exec_command
Bash|Gemini CLI|run_shell_command
Grep|OpenCode|grep
Grep|Gemini CLI|grep_search
Glob|OpenCode|glob
Agent|OpenCode|task
Agent|Codex|spawn_agent
Agent|Gemini CLI|invoke_agent
Skill|OpenCode|skill
Skill|Gemini CLI|activate_skill
AskUserQuestion|OpenCode|question
AskUserQuestion|Codex|request_user_input
AskUserQuestion|Gemini CLI|ask_user
TodoWrite|OpenCode|todowrite
TodoWrite|Codex|update_plan
TodoWrite|Gemini CLI|write_todos
WebSearch|OpenCode|websearch
WebSearch|Gemini CLI|google_web_search
WebFetch|OpenCode|webfetch
WebFetch|Gemini CLI|web_fetch
ROWS
assert_no_line_matches "$_tools" '[Ss]ame (names )?as Claude Code|@mention' \
  "tool-mappings: no Cursor 'same names' claim, no OpenCode @mention dispatch"
_caps=$(_section "$MAPPINGS" "## Capabilities")
_ch=$(_cell "$_caps" 'Claude hook tier (`--claude`)' "Cursor")
assert_contains "$_ch" "settings.local.json" "capabilities: the Cursor Claude-hook cell names the file the tier writes"
assert_contains "$_ch" "unverified" "…and says Cursor loading it is unverified (its docs name only .claude/settings.json)"
assert_contains "$MAPPINGS" "## Tool resolution" "tool-mappings keeps the Tool resolution section (T12)"

# --- Codex: multi_agent is a [features] key ---
# A top-level `multi_agent` is ignored; the key is features.multi_agent
# (Codex config reference: stable, on by default).
_codex="$(_read "$REPO_ROOT/.codex/INSTALL.md")"
_ma=$(awk '/^```toml/ { t = 1; sect = "top-level"; next }
           t && /^```/ { t = 0; next }
           t && /^\[/ { sect = $0; sub(/[[:space:]]*(#.*)?$/, "", sect); next }
           t && /^[[:space:]]*multi_agent[[:space:]]*=/ { print sect }' <<<"$_codex")
assert_eq "[features]" "$_ma" "Codex INSTALL: multi_agent sits under [features] (a top-level key is ignored)"

# --- Install pins and the Claude Code marketplace ---
_pins=""
for _f in .opencode/INSTALL.md .codex/INSTALL.md .cursor-plugin/INSTALL.md README.md GEMINI.md AGENTS.md; do
  _pins="$_pins$(grep -nHE '#v[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/$_f" 2>/dev/null || true)"
done
assert_eq "" "$_pins" "install examples pin with a #vX.Y.Z placeholder, never a concrete version that goes stale"
assert_contains "$(_read "$REPO_ROOT/.opencode/INSTALL.md")" "#vX.Y.Z" "…the OpenCode pin example uses the placeholder"
_readme="$(_read "$REPO_ROOT/README.md")"
_mkt=$(jq -r '.name // ""' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>&1) || true
_plg=$(jq -r '[.plugins[] | select(.source == "./") | .name][0] // ""' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>&1) || true
assert_eq "doc-superpowers@doc-superpowers" "$_plg@$_mkt" "marketplace.json: plugin doc-superpowers in marketplace doc-superpowers (source ./)"
assert_eq "$_plg" "$(jq -r '.name // ""' "$REPO_ROOT/.claude-plugin/plugin.json" 2>&1)" "…the plugin the repo root's .claude-plugin/plugin.json declares"
assert_contains "$_readme" "/plugin marketplace add woodrowpearson/doc-superpowers" "README: Claude Code adds the marketplace by owner/repo"
assert_contains "$_readme" "/plugin install $_plg@$_mkt" "README: …and installs <plugin>@<marketplace>"

# --- claude-code.json: no consumer (R9), so no file ---
assert_file_not_exists "$REPO_ROOT/claude-code.json" "claude-code.json is gone (no client reads it; the R9 search is in the Task 13 report)"
_ccj=""
# README's *Upgrading from 2.x* is the one place that names it: it tells an
# upgrader the file is gone.
for _f in $_I12_LIVE scripts/doc-tools.sh scripts/hooks/ci/doc-release.yml .github/workflows/tests.yml package.json; do
  _ccj="$_ccj$(awk -v f="$_f" '
    f == "README.md" && /^## / { up = ($0 ~ /^## Upgrading from 2\.x/) }
    !up && /claude-code\.json/ { print f ":" FNR ":" $0 }' "$REPO_ROOT/$_f" 2>/dev/null || true)"
done
assert_eq "" "$_ccj" "no live file names claude-code.json (but README's upgrade notes)"
assert_contains "$(awk '/^## / { up = ($0 ~ /^## Upgrading from 2\.x/) } up' "$REPO_ROOT/README.md")" \
  '`claude-code.json` is gone' "README's upgrade notes say claude-code.json is gone (F7)"
_six=$(_i12_grep '(6|six) manifest')
assert_eq "" "$_six" "no live doc counts six manifests"
# The shipped manifests all parse, and each path they name exists.
for _f in package.json gemini-extension.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .cursor-plugin/plugin.json; do
  assert_true "$_f is valid JSON" _json_ok "$REPO_ROOT/$_f"
done
assert_file_exists "$REPO_ROOT/$(jq -r '.main // "-"' "$REPO_ROOT/package.json")" "package.json main (the OpenCode plugin) exists"

echo "--- spec claims: R5 and phases ---"
# Task 24: the Spec Status Model's claim-gated rule and the execute /
# post-execute / review wiring. Every phrase is pinned verbatim: Tasks 25 and 26
# and references/spec-claims.md cite them. Claims-enabled projects only; the
# Drifted branch's text for projects without claims stays byte for byte.
_sq="'"
assert_contains "$ACTIONS" '- **R5 — Claim-gated advancement.** **Claims-enabled projects only** (`docs/spec-claims/` exists): a target spec advances to `Implemented` only when every claim the plan names for it is `built` with a passing verdict at the final gate (`claims attest --final`); with the configuration extension, `gated` also qualifies. `:amends` specs remain exempt from `Status` writes but not from claim checks.' \
  "R5 claim-gated advancement is a rule"
assert_contains "$ACTIONS" "Claims-enabled projects only" "R5 is marked claims-enabled projects only"
assert_contains "$ACTIONS" '**R5** — claims enabled and the final gate does not show every named claim of this spec `built` (or `gated`) and passing → hold short of `Implemented` (R2 still applies).' \
  "evaluation order has the R5 step"
assert_line_matches "$(_section "$ACTIONS" '### Evaluation order')" '\*\*R5\*\*' \
  "R5 sits inside the Evaluation order section"
assert_contains "$ACTIONS" '**With claims enabled**, the plan'"$_sq"'s `Claims gate (chunk N)` task is the chunk'"$_sq"'s verifier: this phase reports its record'"$_sq"'s verdicts and does not judge drift by agent.' \
  "execute phase: the claims gate task is the chunk's verifier"
assert_contains "$ACTIONS" 'It never calls `update-index` while a claim of that spec fails.' \
  "execute phase: Aligned never calls update-index over a failing claim"
assert_contains "$ACTIONS" "Flag for human review with a deviation note" \
  "execute phase: the Drifted branch's existing sentence is unchanged"
assert_contains "$ACTIONS" '**Claims-enabled projects:** rule the direction (**Direction protocol**, `spec-lifecycle-protocol.md`) before editing either side — not in this phase, but at the chunk'"$_sq"'s `Claims gate (chunk N)` task, Step 3, whose record (`docs/spec-claims/gates/<plan-stem>/chunk-<N>.json`) is the ruling'"$_sq"'s `record`. This phase flags the deviation and leaves the ruling to that step.' \
  "execute phase: Drifted gains the conditional direction-protocol sentence, routed to the chunk gate's Step 3 (A-P2-28)"
assert_not_contains "$ACTIONS" 'before editing either side, and record the ruling in the sidecar.' \
  "execute phase: the Drifted branch no longer rules by agent (the gate is the chunk's verifier)"
assert_contains "$ACTIONS" 'With claims enabled an `:amends` spec'"$_sq"'s claims are still checked at the gate.' \
  "execute phase: an amendment spec's claims are still checked"
assert_contains "$ACTIONS" '0. **Claims verdict** (claims-enabled projects only): run `$DOC_TOOLS claims attest --plan <plan> --final`; exit 1 → FAIL; exit 2 → report "claims verdict owed", never PASS; include its amendment batch.' \
  "post-execute step 0 is the claims verdict"
assert_contains "$ACTIONS" 'Claims enabled and no `--plan`: there is no plan to attest, so step 0 reports "claims verdict owed", never PASS.' \
  "post-execute step 0 without --plan: claims verdict owed, never PASS"
assert_contains "$ACTIONS" 'With claims enabled, step 0 needs it: without it the verdict is "claims verdict owed".' \
  "post-execute --plan input: claims-enabled runs need it"
assert_contains "$ACTIONS" 'AND (claims disabled OR `claims attest --final` exit 0)' \
  "PASS rule gains the claims clause"
assert_contains "$ACTIONS" '3c. **Claims** (claims-enabled projects only): `$DOC_TOOLS claims run --planes-of <base>...HEAD` and `claims validate --all`'"$_sq"'s V9 items; a red claim is a **P1 Claim red** finding.' \
  "review step 3c runs the claims"
assert_contains "$ACTIONS" '**P1 Claim red**' "review severity list has P1 Claim red"
# In CI, step 3c is the non-AI claims job's (P0-1): the claims verbs run the
# PR's own adapters, which no CI agent may run, and the AI step is granted
# none of them. The reference says so, and the template's prompt sends the
# agent past step 3c.
assert_contains "$ACTIONS" 'In a doc-superpowers CI run, skip step 3c: `doc-spec-verify.yml`'"$_sq"'s non-AI `claims` job is the 3c check' \
  "review step 3c: in CI the claims job is the 3c check"
_sv_prompt=$(awk '/^  spec-verify:$/ { s = 1; next } s && /^  [A-Za-z_-]+:$/ { exit } s' "$CI/doc-spec-verify.yml")
assert_contains "$_sv_prompt" 'Skip review step 3c (Claims)' "doc-spec-verify.yml: the AI step's prompt skips step 3c"
assert_not_contains "$(grep -F -- '--allowedTools' <<<"$_sv_prompt")" 'doc-tools.sh claims' \
  "doc-spec-verify.yml: …and its --allowedTools grants no claims verb"
assert_contains "$TEMPLATES" "### Claims verdict" "compliance report has a Claims verdict block"
assert_contains "$(_section "$TEMPLATES" '## Spec Compliance Report')" "claims-enabled projects only" \
  "Claims verdict block is marked claims-enabled projects only"

echo "--- spec claims: stubs and injected gates ---"
# Task 25: spec-generate's claim stubs and spec-inject's injected claims
# gates. The titles the reference injects are the ones V12 parses
# (doc-tools.sh _CL_GATE_TITLE_PREFIX / _CL_FINAL_GATE_TITLE), so the
# constants are pinned here too, and the reference is pinned to contain each
# constant's value as read from doc-tools.sh, never re-typed. Their order in
# an injected plan (gate before spec-update) is not pinned on the
# reference's text order (step 2 describes the spec-update template before
# step 2b's gate): test-spec-claims.sh's test_v12_reference_template_passes
# assembles a plan from the reference's fences and runs V12 on it.
assert_contains "$ACTIONS" 'Claims gate (chunk {C})' "the chunk gate's title template"
assert_contains "$ACTIONS" 'Final claims gate' "the final gate's title"
assert_contains "$ACTIONS" '**Claims:** none — <reason>' "the Claims none line form"
assert_contains "$ACTIONS" 'Run by the orchestrating agent, not a delegated implementer' \
  "the gate tasks are run by the orchestrating agent"
assert_contains "$ACTIONS" 'Inject these only when `docs/spec-claims/` exists; otherwise the plan is unchanged.' \
  "the injections are conditional on docs/spec-claims/"
assert_contains "$ACTIONS" '6b. **Claim stubs**' "spec-generate step 6b writes claim stubs"
assert_contains "$ACTIONS" 'DOC-STALE commit (with the record) → `promote` → commit → re-run Step 1' \
  "the gate's DOC-STALE re-promotion order"
# P1-2: --holds without --by exits 3, so the chunk gate's Step 3 gives the
# whole command, and Step 1 routes exit 3 (test-spec-claims.sh runs the
# command: test_gate_reference_holds_command_runs).
_cg=$(awk '/^   ### Task N\+1g:/ { s = 1 } s { print } s && /^   ````$/ { exit }' <<<"$ACTIONS")
assert_contains "$_cg" '`$DOC_TOOLS claims gate --plan {plan-path} --chunk {C} --holds <id> --by <principal>`' \
  "the chunk gate's Step 3 holds a V9 item with --holds <id> --by <principal>"
assert_not_contains "$_cg" '`--holds <id>` when' "…never with a bare --holds <id>"
assert_contains "$_cg" 'Exit 3 → a usage error' "the chunk gate's Step 1 routes exit 3"
assert_contains "$ACTIONS" '**target**, fully covered by this plan → set `Implemented`, subject to R5.' \
  "Task N+2 Step 1's target branch is subject to R5"
_dt_src="$REPO_ROOT/scripts/doc-tools.sh"
assert_eq "1" "$(grep -cF "_CL_GATE_TITLE_PREFIX='Claims gate (chunk '" "$_dt_src" || true)" \
  "doc-tools.sh defines _CL_GATE_TITLE_PREFIX on exactly one line"
assert_eq "1" "$(grep -cF "_CL_FINAL_GATE_TITLE='Final claims gate'" "$_dt_src" || true)" \
  "doc-tools.sh defines _CL_FINAL_GATE_TITLE on exactly one line"
_gp=$(sed -n "s/^_CL_GATE_TITLE_PREFIX='\\(.*\\)'\$/\\1/p" "$_dt_src")
_fg=$(sed -n "s/^_CL_FINAL_GATE_TITLE='\\(.*\\)'\$/\\1/p" "$_dt_src")
assert_contains "$ACTIONS" "### Task N+1g: ${_gp:-<unset>}{C})" \
  "the injected chunk gate's heading starts with the parser's _CL_GATE_TITLE_PREFIX"
assert_contains "$ACTIONS" "### Task N+2g: ${_fg:-<unset>}" \
  "the injected final gate's heading is the parser's _CL_FINAL_GATE_TITLE"

echo "--- spec claims: direction protocol, wiring and update-index wording ---"
# Task 26: the direction protocol (§F) in the wrapper guide, conditional on
# claims being enabled. The wiring lines for projects without claims stay byte
# for byte; each gains a claims-enabled line. update-index is a baseline reset,
# never a verification (§H): prose only, the output tokens are unchanged.
assert_contains "$PROTOCOL" "## Direction protocol" "protocol: Direction protocol section"
assert_contains "$PROTOCOL" "When a doc and the code disagree, neither side is edited until the direction is ruled and recorded." \
  "protocol: neither side is edited until the direction is ruled"
for _d in CODE-DIVERGES DOC-STALE RETIRE in_plan_ruling_requires_gate_record outside_plan_presumption doc_stale_outside_plan_requires; do
  assert_contains "$(_section "$PROTOCOL" '## Direction protocol')" "$_d" "protocol: Direction protocol names $_d"
done
assert_contains "$PROTOCOL" 'This protocol applies to claims-enabled projects (`docs/spec-claims/` exists). Without claims, the wiring below is unchanged, and the three directions are offered as a recommended framing for the question put to the user.' \
  "protocol: the Direction protocol's scope sentence"
assert_contains "$PROTOCOL" "**Deviation is expected; an unreconciled deviation is the failure.**" \
  "protocol: deviation is expected; an unreconciled deviation is the failure"
assert_contains "$(_section "$PROTOCOL" '## Direction protocol')" 'a ruling whose `record` is not a gate record' \
  "protocol: outside a plan means a ruling whose record is not a gate record"
assert_line_matches "$PROTOCOL" '^\| Pipeline Point \| When \| Action \| Mode \| With claims enabled \|$' \
  "protocol: the Lifecycle Overview has the With claims enabled column"
# The two wiring lines for projects without claims, whole-line (an in-place
# extension fails), each directly followed by its claims-enabled line.
_w_exec='    If deviation flags returned → surface to user'
_w_fail='    If FAIL → surface report to user, let them decide'
assert_line_matches "$PROTOCOL" "^${_w_exec}\$" "protocol: execute wiring line unchanged for projects without claims"
assert_line_matches "$PROTOCOL" "^${_w_fail}\$" "protocol: post-execute wiring line unchanged for projects without claims"
assert_eq '    Claims-enabled: a red claim or a flagged deviation → rule the direction (Direction protocol) before editing either side' \
  "$(grep -A1 -x -F -- "$_w_exec" <<<"$PROTOCOL" | sed -n 2p)" \
  "protocol: the execute wiring line is directly followed by its claims-enabled line"
assert_eq '    Claims-enabled: surface the report and its amendment batch; every unreconciled deviation needs a ruling (Direction protocol)' \
  "$(grep -A1 -x -F -- "$_w_fail" <<<"$PROTOCOL" | sed -n 2p)" \
  "protocol: the post-execute wiring line is directly followed by its claims-enabled line"
assert_contains "$PROTOCOL" "Claims-enabled: a red claim or a flagged deviation → rule the direction" \
  "protocol: execute wiring gains the claims-enabled direction line"
assert_contains "$PROTOCOL" "Claims-enabled: surface the report and its amendment batch; every unreconciled deviation needs a ruling (Direction protocol)" \
  "protocol: post-execute wiring gains the claims-enabled amendment-batch line"
assert_contains "$SKILLMD" "Records a baseline reset, never a verification" "SKILL.md: update-index records a baseline reset"
assert_not_contains "$SKILLMD" "The one verb that attests a doc was checked against its code" \
  "SKILL.md: update-index is no longer the verb that attests"
assert_contains "$INTEGRATION" "## Claims-enabled wrappers" "integration patterns: Claims-enabled wrappers section"
assert_contains "$SKILLMD" '| `references/spec-claims.md` | **REQUIRED** when `docs/spec-claims/` exists — ' \
  "SKILL.md: references/spec-claims.md is REQUIRED when docs/spec-claims/ exists"
assert_contains "$SKILLMD" "**Who may re-baseline.**" "SKILL.md: Who may re-baseline"
assert_line_matches "$SKILLMD" '^\| Doc edited and read against its code \| `update-index <doc>` — a baseline reset \|' \
  "SKILL.md: the routing cell calls update-index a baseline reset"
assert_contains "$("$DOC_TOOLS_SHIM" update-index --help)" "never a verification" \
  "doc-tools help: update-index is never a verification"
assert_contains "$("$DOC_TOOLS_SHIM" --help)" "Stored state (who may re-baseline):" \
  "doc-tools help: Stored state (who may re-baseline)"
# The claims help as the 3.2.0 audit left it (P3-12–P3-15), and the
# installer's claims half (P2-23, P3-37).
_gh=$("$DOC_TOOLS_SHIM" claims gate --help)
assert_contains "$_gh" "[--holds <id>]... [--by <principal>]" "claims gate help: --holds repeats, one id each"
assert_contains "$_gh" "(repeatable, one id each)" "…said in words"
assert_contains "$_gh" "V8, V8n and V9 over <from>..HEAD" "claims gate help: the gate runs V8 and V8n too"
assert_contains "$_gh" "every named id no claim has" "…and reports named ids no claim has"
# The 3.3.0 self-audit's code halves (C-1, C-3, C-2): the help says what
# references/spec-claims.md says.
assert_contains "$(printf '%s' "$_gh" | tr '\n' ' ' | tr -s ' ')" "each lint, log or judge claim in the plan's scope (the claims its **Claims:** lines name and every claim of a doc its Specs list names) that the range moved into built or gated" \
  "claims gate help: the moved-in lint, log and judge claims are the plan's scope only (C-1)"
_ah=$("$DOC_TOOLS_SHIM" claims attest --help | tr '\n' ' ' | tr -s ' ')
assert_contains "$_ah" "each lint, log or judge claim in the plan's scope (as for the gate) that the branch moved into built or gated" \
  "claims attest help: …and attest's too (C-1)"
assert_contains "$_ah" "a change in that window the rebuild does not include is a silent reconciliation even when an earlier chunk record holds a matching entry" \
  "claims attest help: the final window's stricter rule (C-3)"
_xh=$("$DOC_TOOLS_SHIM" --help | tr '\n' ' ' | tr -s ' ')
assert_contains "$_xh" "promote it to built once the change is committed; a lint, log or judge claim: move it to built by a reviewed status edit" \
  "doc-tools help: V10's promote-owed remedy for a non-test claim (C-2)"
assert_contains "$_xh" "then promote re-gates it, or a reviewed status edit to gated for a lint, log or judge claim" \
  "doc-tools help: V10's ruling-owed remedy for a non-test claim (C-2)"
assert_contains "$_xh" "fix the code and promote it (a lint, log or judge claim: move it to built by a reviewed status edit), or retire it, first" \
  "doc-tools help: V10's switch-on remedy for a non-test claim (C-2)"
assert_contains "$("$DOC_TOOLS_SHIM" claims run --help)" "claim's absent lint path is its allowed assert-fail" \
  "claims run help: an unbuilt claim's absent lint path is not a finding"
assert_contains "$("$DOC_TOOLS_SHIM" --help)" "tree where one is refused (gate, promote, attest --final)" \
  "doc-tools help: a refused dirty tree is a claims exit 2"
_ih=$("${BASH_BIN:-bash}" "$REPO_ROOT/scripts/hooks/install.sh" help 2>&1 || true)
assert_contains "$_ih" "claims job on a claims check that cannot run" "installer help: --ci-strict's claims half"
assert_contains "$_ih" "claims validate --staged" "installer help: pre-commit's claims leg"
assert_contains "$_ih" "commits (advisory: never blocks)" "installer help: pre-push's claims leg"
assert_contains "$_ih" "a non-AI claims job on every same-repository PR" "installer help: doc-spec-verify's claims job"
assert_contains "$_ih" "its claims step re-runs and re-proves the spec claims" "installer help: the schedule's claims step"
assert_contains "$HOOKSREF" '`doc-spec-verify`'"'"'s `claims` job fails on a claims check that cannot run' \
  "hooks.md: --ci-strict's claims half"
assert_eq "" "$(grep -n 'the one verb that attests\|only verb that attests' "$REPO_ROOT"/references/doc-spec.md "$REPO_ROOT"/docs/codebase-guide.md "$REPO_ROOT"/docs/conventions.md "$REPO_ROOT"/docs/workflows/doc-superpowers.md "$REPO_ROOT"/docs/architecture/system-overview.md "$REPO_ROOT"/skills/doc-superpowers/SKILL.md || true)" \
  "no doc still calls update-index the verb that attests"

echo "--- spec claims: the reference and the template status block ---"
# Task 29: references/spec-claims.md (schema, checks, adapters, the reference
# helpers) and the spec/ADR templates' status-block comment and descriptive
# marker. The helpers are examples, not shipped files, but they must stay
# valid code: every ```python fence compiles under python3 -m py_compile (CI
# has python; without it, a loud SKIP), the ```js fence under node --check
# (node_unavailable: a SKIP, a FAIL under DOC_SP_REQUIRE_NODE=1).
_sc_ref="$REPO_ROOT/references/spec-claims.md"
assert_file_exists "$_sc_ref" "references/spec-claims.md exists"
assert_contains "$SPECCLAIMS" '<!-- spec-claims:status:begin -->' "spec-claims.md: the status block's begin marker"
assert_contains "$SPECCLAIMS" '<!-- spec-claims:descriptive -->' "spec-claims.md: the descriptive marker"
assert_contains "$SPECCLAIMS" 'xfail(strict=True, raises=AssertionError)' \
  "spec-claims.md: diverged is an expected failure on an assertion only"
assert_contains "$SPECCLAIMS" '"subject_imports_ok"' "spec-claims.md: the list row's subject_imports_ok field"
assert_contains "$SPECCLAIMS" '"outcome": "pass"|"assert-fail"|"error"|"not-found"|"indeterminate"' \
  "spec-claims.md: the run row's five outcomes, unescaped"
assert_contains "$DOCSPEC" '<!-- spec-claims:descriptive -->' "doc-spec.md: the descriptive marker"
# The example blocks show what render writes: its table header is read from
# doc-tools.sh, never re-typed.
assert_eq "1" "$(grep -cF '"| Claim | Status | Tracker |"' "$_dt_src" || true)" \
  "doc-tools.sh renders the status table header on exactly one line"
assert_contains "$SPECCLAIMS" '| Claim | Status | Tracker |' "spec-claims.md: the status block example has render's table header"
assert_contains "$DOCSPEC" '| Claim | Status | Tracker |' "doc-spec.md: …and so does the templates' status-block example"
_sc_spec=$(_section "$DOCSPEC" '## docs/specs/template.md')
_sc_adr=$(_section "$DOCSPEC" '## docs/adr/template.md')
_sc_gen='generated by `doc-tools.sh claims render`; do not edit'
# _in_order <text> <a> <b> <c>: the first lines holding a, b and c come in that order.
_in_order() {
  awk -v a="$2" -v b="$3" -v c="$4" '
    !x && index($0, a) { x = NR } !y && index($0, b) { y = NR } !z && index($0, c) { z = NR }
    END { exit !(x && y && z && x < y && y < z) }' <<<"$1"
}
assert_true "spec template: the status-block comment sits between ## Summary and ## Motivation" \
  _in_order "$_sc_spec" '## Summary' "$_sc_gen" '## Motivation'
assert_true "ADR template: the status-block comment sits between ## Context and ## Decision" \
  _in_order "$_sc_adr" '## Context' "$_sc_gen" '## Decision'
assert_eq '<!-- spec-claims:descriptive -->' "$(grep -A1 -x -F '## Implementation Notes' <<<"$_sc_spec" | sed -n 2p)" \
  "spec template: the descriptive marker directly follows ## Implementation Notes (V8 reads it there only)"
assert_contains "$_sc_spec" 'references/spec-claims.md' "spec template: its note links references/spec-claims.md"
assert_not_contains "$DOCSPEC" 'once every claim is built' \
  "doc-spec.md: Claims: N built counts the non-retired claims (render's rule), never every claim"
# The CI claims job's scope, as the template gates it: same-repository PRs,
# never dependabot's. The reference must say so (a fork PR is not checked).
_sc_job=$(awk '/^  claims:$/ { s = 1; print; next } s && /^  [A-Za-z_-]+:/ { exit } s' "$CI/doc-spec-verify.yml")
assert_contains "$_sc_job" 'github.event.pull_request.head.repo.full_name == github.repository &&' \
  "doc-spec-verify.yml: the claims job runs on same-repository PRs only"
assert_contains "$_sc_job" "github.actor != 'dependabot[bot]'" "doc-spec-verify.yml: …and not on dependabot's"
assert_contains "$SPECCLAIMS" 'every same-repository PR (fork and dependabot PRs are not checked)' \
  "spec-claims.md: the CI claims job's scope (fork and dependabot PRs are not checked)"
assert_not_contains "$SPECCLAIMS" 'checks every PR' "spec-claims.md: never says the CI job checks every PR"
# V6 as the promotion fingerprint left it: the direction a change needs,
# what a promotion proved read from promotion.proved (never history), and
# the limit of trusting a promotion by its digest.
assert_contains "$SPECCLAIMS" 'a `states` change, a lowered `enforced_by` or a token-changing re-anchor needs a new `DOC-STALE` or `RETIRE` ruling' \
  "spec-claims.md: V6 — only DOC-STALE or RETIRE licenses a states change, a lowered tier, a re-anchor"
assert_contains "$SPECCLAIMS" 'What a promotion proved is read from `promotion.proved`**, never from the store and never from history' \
  "spec-claims.md: V6 — what a promotion proved is read from promotion.proved"
assert_not_contains "$SPECCLAIMS" 'record at `promotion.at`' \
  "spec-claims.md: no history rule (promotion.at is unreachable after a squash or rebase merge)"
assert_not_contains "$SPECCLAIMS" 'sidecar at `promotion.at`' "spec-claims.md: …nor the sidecar at promotion.at"
assert_contains "$SPECCLAIMS" 'V6 compares each changed promoted claim with its `promotion.proved`' \
  "spec-claims.md: the CI job's V6 decides by promotion.proved"
assert_not_contains "$HOOKSREF" '`unverifiable-here` advisory, never a finding' \
  "hooks.md: a missing verdict in CI is not always only an advisory"
assert_contains "$HOOKSREF" 'V6 compares each changed promoted claim with its `promotion.proved`' \
  "hooks.md: the CI job's V6 decides by promotion.proved"
_ck_src="$(_read "$REPO_ROOT/scripts/hooks/ci/doc-superpowers-steps/claims-check.sh")"
assert_not_contains "$_ck_src" 'unverifiable-here advisory, never a finding' \
  "claims-check.sh: a missing verdict in CI is not always only an advisory"
assert_contains "$_ck_src" 'promoted claim with its promotion.proved' "claims-check.sh: …V6 decides by promotion.proved"
assert_contains "$SPECCLAIMS" 'A forged `proved` is as undetectable outside the promoting clone as a forged `verdict_sha256`' \
  "spec-claims.md: a forged proved is the trust-by-digest limit too"
assert_not_contains "$SPECCLAIMS" 'a missing verdict is the advisory `unverifiable-here`, never a finding' \
  "spec-claims.md: never says a missing verdict is always only an advisory"
assert_contains "$SPECCLAIMS" 'a test, subject or tier swap is a finding whatever the ruling' \
  "spec-claims.md: V6 — re-promote owed covers a states change only"
assert_contains "$SPECCLAIMS" 'A forged digest is undetectable outside the promoting clone' \
  "spec-claims.md: promotions are trusted by digest (a hand-forged promotion passes locally)"
# P1-3 (design §B's status table): a promotion and non-vacuity are a test
# claim's; a lint, log or judge claim enters built by a reviewed status edit,
# and run and the gate run its check (test-spec-claims.sh:
# test_lint_built_by_status_edit, test_lint_built_failing_check_red_at_run_and_gate).
assert_not_contains "$SPECCLAIMS" '**`claims promote <id>` is the only path into `built`.**' \
  "spec-claims.md: promote is not every claim's path into built"
assert_contains "$SPECCLAIMS" '**`claims promote <id>` is a test claim'"$_sq"'s only path into `built`.**' \
  "spec-claims.md: promote is a test claim's only path into built"
assert_contains "$SPECCLAIMS" '**A `lint`, `log` or `judge` claim enters `built` (or `gated`) by a reviewed status edit.**' \
  "spec-claims.md: a lint, log or judge claim enters built by a reviewed status edit"
assert_contains "$SPECCLAIMS" 'and a `test` claim'"$_sq"'s move into `built`/`gated` without a promotion' \
  "spec-claims.md: V6's missing-promotion finding is a test claim's"
assert_contains "$_cg" '`promote` proves test claims only: a `lint` or `log` claim whose check now passes' \
  "the chunk gate's Step 2: a lint or log claim moves to built by a status edit, not promote"
# A DOC-STALE owes a re-promotion only on a test claim (no other tier is
# promoted), at the chunk gate and at the final gate; gated follows built;
# README says the same.
assert_contains "$_cg" '**A `DOC-STALE` on a test claim that is already `built`/`gated`**' \
  "the chunk gate's Step 3: a DOC-STALE owes a re-promotion on a test claim"
assert_contains "$_cg" 'A `lint`, `log` or `judge` claim is not promoted, so its `DOC-STALE` owes no re-promotion' \
  "…and none on a lint, log or judge claim"
assert_not_contains "$ACTIONS" '**A `DOC-STALE` on a claim that is already `built`/`gated`**' \
  "no gate template says every built claim owes a re-promotion"
assert_contains "$(_section "$ACTIONS" '### Plan Phase')" 'A `lint`, `log` or `judge` claim owes no re-promotion. Then re-run Step 1' \
  "the final gate's Step 2: no re-promotion for a lint, log or judge claim"
assert_contains "$SPECCLAIMS" 'required for a `test` claim that is `built` or `gated` (V3). A `lint`, `log` or `judge` claim needs none.' \
  "spec-claims.md: nonvacuity is a test claim's"
assert_contains "$SPECCLAIMS" '- **Tier.** `gated` follows `built`' \
  "spec-claims.md: the extension's As built notes gated follows built"
assert_contains "$_readme" '`promote` is a test claim'"$_sq"'s only path to `built`' \
  "README: promote is a test claim's only path to built"
assert_not_contains "$_readme" '`promote` is the only path to `built`' "README: …never every claim's"

# _fence_blocks <file> <lang> <dir> <ext>: each unindented ```<lang> fence of
# <file> written to <dir>/<n>.<ext>; prints how many.
_fence_blocks() {
  awk -v lang="$2" -v dir="$3" -v ext="$4" '
    !inf && /^```/ { inf = 1; info = substr($0, 4); sub(/[ \t]+$/, "", info); out = ""
                     if (info == lang) { n++; out = dir "/" n "." ext; printf "" > out }
                     next }
    inf && /^```[ \t]*$/ { inf = 0; if (out != "") close(out); out = ""; next }
    inf && out != "" { print > out }
    END { print n + 0 }' "$1"
}
if [ -f "$_sc_ref" ]; then
  _hx=$(harness_mktemp_d spec-claims-helpers)
  assert_eq "3" "$(_fence_blocks "$_sc_ref" python "$_hx" py)" \
    "spec-claims.md: three python examples (conftest.py, a bound test, the runner adapter)"
  assert_eq "1" "$(_fence_blocks "$_sc_ref" js "$_hx" cjs)" "spec-claims.md: one js example (the jest helper)"
  if command -v python3 >/dev/null 2>&1; then
    for _f in "$_hx"/*.py; do
      [ -f "$_f" ] || continue
      _rc=0
      _out=$(python3 -m py_compile "$_f" 2>&1) || _rc=$?
      assert_eq "0" "$_rc" "spec-claims.md: python example $(basename "$_f") compiles${_out:+ — $_out}"
    done
  else
    record_skip "spec-claims.md python examples (py_compile) — python3 not found"
  fi
  if ! node_unavailable "spec-claims.md jest example (node --check)"; then
    for _f in "$_hx"/*.cjs; do
      [ -f "$_f" ] || continue
      _rc=0
      _out=$(node --check "$_f" 2>&1) || _rc=$?
      assert_eq "0" "$_rc" "spec-claims.md: js example $(basename "$_f") passes node --check${_out:+ — $_out}"
    done
  fi
fi

# =============================================================================
echo "--- doc-search: the reference and its wiring ---"
# doc-search (search/, the opt-in MCP server) is documented in one reference,
# which SKILL.md names. Its ten sections are the plan's, in order; the strings
# an agent or a probe acts on are read from the code, so the reference cannot
# drift from what ships.
_ds_ref="$REPO_ROOT/references/search.md"
_ds_src="$REPO_ROOT/search/src/doc_search"
assert_true "references/search.md exists" test -f "$_ds_ref"
_ds=$(_read "$_ds_ref")
assert_contains "$SKILLMD" '`references/search.md`' "SKILL.md's references table names references/search.md"
assert_eq "## Turning it on
## Modes
## Configuration
## CLI
## Tools
## Cloud leg
## Other clients
## Hardware and performance
## Privacy
## Troubleshooting" "$(grep -E '^## ' <<<"$_ds" || true)" "search.md: the ten sections, in order, and no other"
# shellcheck disable=SC2016  # the command is literal text
assert_contains "$_ds" 'gcloud firestore indexes composite create --collection-group=doc_chunks --query-scope=COLLECTION --field-config=field-path=embedding,vector-config='"'"'{"dimension":"768","flat":"{}"}'"'"' --database=<db>' \
  "search.md: the cloud leg's vector-index command"
_ds_inert=$(sed -n 's/^INERT_LINE = "\(.*\)"$/\1/p' "$_ds_src/config.py")
assert_true "config.py defines INERT_LINE" test -n "$_ds_inert"
assert_contains "$_ds" "$_ds_inert" "search.md: the inert line is config.py's"
# The CLI verbs: the keys of cli.py's _VERBS table.
_ds_verbs=$(awk '/^_VERBS = \{/ { s = 1; next } s && /^\}/ { exit } s { gsub(/[" :,]/, " "); print $1 }' "$_ds_src/cli.py" \
  | tr '\n' ' ' | sed 's/ $//')
assert_eq "serve init index query status eval" "$_ds_verbs" "cli.py: the six verbs"
for _v in $_ds_verbs; do
  assert_contains "$(_section "$_ds" '## CLI')" "\`$_v" "search.md: CLI names \`$_v\`"
done
for _t in search fetch related status; do
  assert_contains "$(_section "$_ds" '## Tools')" "\`$_t\`" "search.md: Tools names \`$_t\`"
done
assert_contains "$(_section "$_ds" '## Configuration')" '`timeout_s`' "search.md: the cloud.timeout_s lever is documented"
assert_contains "$HOOKSREF" '--search' "hooks.md documents the --search set"
assert_contains "$HOOKSREF" '.tiers.search' "hooks.md documents status --json's .tiers.search"
assert_contains "$(_section "$MAPPINGS" "## Capabilities")" 'doc-search' "tool-mappings: a capability row for the doc-search MCP server"

# =============================================================================
echo "--- SKILL.md: frontmatter and the paths it names (#31) ---"
# Claude Code loads every skill's name and description at startup, always on:
# the description is capped (1,536 chars, the limit the skill loader
# documents) and must be one plain or quoted line — a block scalar (| or >)
# is easy to grow without noticing and parsed differently by some clients.
_skill="$REPO_ROOT/skills/doc-superpowers/SKILL.md"
# The frontmatter: the lines between a first-line '---' and the next '---'.
_fm=$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } { print }' "$_skill")
assert_true "SKILL.md opens with a YAML frontmatter block" test -n "$_fm"
assert_eq "description name" "$(awk -F: '/^[A-Za-z_-]+:/ { print $1 }' <<<"$_fm" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "…holding exactly name and description"
assert_eq "doc-superpowers" "$(awk '/^name:/ { sub(/^name:[[:space:]]*/, ""); print }' <<<"$_fm")" "…name: doc-superpowers"
_desc_line=$(grep -E '^description:' <<<"$_fm" || true)
assert_true "…description is not a block scalar (| or >)" \
  test -z "$(grep -E '^description:[[:space:]]*[|>]' <<<"$_desc_line" || true)"
assert_eq "" "$(grep -E '^[[:space:]]' <<<"$_fm" || true)" "…and no key continues onto an indented line (each value is one line)"
# Its length in characters (it holds em dashes, so not bytes), parsed as YAML
# by ruby's psych or PyYAML, whichever is here; without either, the one line
# read with its quotes removed and counted in bytes (an over-count: never a
# false pass).
_desc_chars=""
if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  _desc_chars=$(printf '%s\n' "$_fm" | ruby -ryaml -e 'd = YAML.safe_load($stdin.read)["description"]; print(d.is_a?(String) ? d.length : 0)')
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  _desc_chars=$(printf '%s\n' "$_fm" | python3 -c 'import sys, yaml; d = yaml.safe_load(sys.stdin.read()).get("description"); print(len(d) if isinstance(d, str) else 0)')
else
  _desc_chars=$(sed -e 's/^description:[[:space:]]*//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\\1/" <<<"$_desc_line" | tr -d '\n' | wc -c | tr -d ' ')
fi
assert_true "…description is a non-empty string (${_desc_chars:-?} chars)" test "${_desc_chars:-0}" -gt 0
assert_true "…description is at most 1,536 chars (${_desc_chars})" test "$_desc_chars" -le 1536

# Every references/… and scripts/… path SKILL.md names exists in the plugin
# (a path in another project — .github/scripts/… — or a glob/placeholder,
# scripts/*validate_docs*, is not one of the plugin's).
_missing=""
_npaths=0
for _p in $(grep -oE '(^|[^A-Za-z0-9_./-])(references|scripts)/[A-Za-z0-9_./*<>{}-]*' "$_skill" \
  | sed -E 's/^[^rs]//; s/[.,;:]+$//' | sort -u); do
  case "$_p" in *[*\<\>{}]*) continue ;; esac
  _npaths=$((_npaths + 1))
  [ -e "$REPO_ROOT/$_p" ] || _missing="$_missing $_p"
done
assert_true "SKILL.md names references/ and scripts/ paths ($_npaths checked)" test "$_npaths" -ge 10
assert_eq "" "$_missing" "…and every one exists"

# =============================================================================
echo "--- leak scan: tracked files ship to every install (#29) ---"
# scripts/leak-scan.sh, first against a fixture holding one leak of each class
# and each allowlisted form (the leaks are assembled here, so this file holds
# none), then over this checkout.
_LEAK="$REPO_ROOT/scripts/leak-scan.sh"
_lk=$(harness_mktemp_d leak-fixture)
(
  cd "$_lk" || exit 1
  git init -q
  mkdir -p docs/plans docs/issues docs/archive docs/superpowers/plans src
  _U="/Us""ers" _H="/ho""me" _V="/Vol""umes"
  _g="gh""p_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"
  _ak="AK""IAABCDEFGHIJKLMNOP"
  _sk="sk-""ant-api03-$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
  _pem="-----BEGIN RSA PRI""VATE KEY-----"
  _em="jane.doe""@corp.io"
  {
    echo "a home path: $_U/jdoe/proj/x"
    echo "a linux home: $_H/jdoe/src"
    echo "a volume: $_V/scratch/wt"
    echo "an email: $_em"
    echo "a token: $_g"
    echo "an aws key: $_ak"
    echo "a key: $_sk"
    echo "$_pem"
  } > src/leaks.md
  {
    echo "placeholders: $_U/me/proj $_H/runner/work $_H/linuxbrew/.linuxbrew/bin/bash"
    echo "a nested segment: \$HOME$_H/notes and \${dir}$_U/x"
    echo "examples: bob""@example.com, noreply""@anthropic.com, test""@test.com, x""@foo.invalid, git""@github.com:o/r.git"
    echo "skipped on purpose: $_U/jdoe/kept  # leak-scan:allow (a recorded path)"
  } > src/fine.md
  echo "recorded: $_U/jdoe/wt and $_V/scratch" > docs/plans/2026-01-01-plan.md
  echo "recorded: $_U/jdoe/wt" > docs/issues/2026-01-02-issue.md
  echo "recorded: $_U/jdoe/wt" > docs/archive/old.md
  echo "recorded: $_U/jdoe/wt" > docs/superpowers/plans/p.md
  echo "a record with a secret: $_g" > docs/plans/2026-01-03-secret.md
  echo "undated: $_U/jdoe/wt" > docs/plans/undated.md
  echo "untracked: $_g" > untracked.md
  git add src docs
) || true
_rc=0
_out=$("$BASH_BIN" "$_LEAK" "$_lk" 2>&1) || _rc=$?
assert_eq "1" "$_rc" "leak-scan: a fixture with leaks exits 1"
for _want in "src/leaks.md:1: home-path: /Us""ers/jdoe" "src/leaks.md:2: home-path: /ho""me/jdoe" \
  "src/leaks.md:3: volume: /Vol""umes/scratch" "src/leaks.md:4: email: jane.doe""@corp.io" \
  "src/leaks.md:5: token: gh""p_" "src/leaks.md:6: token: AK""IA" "src/leaks.md:7: token: sk-""ant-" \
  "src/leaks.md:8: token: -----BEGIN RSA PRI""VATE KEY-----" \
  "docs/plans/2026-01-03-secret.md:1: token: gh""p_" "docs/plans/undated.md:1: home-path: /Us""ers/jdoe"; do
  assert_contains "$_out" "$_want" "leak-scan: reports $_want"
done
assert_eq "10" "$(grep -cE ': (home-path|volume|email|token): ' <<<"$_out")" \
  "leak-scan: …and nothing else: placeholders, nested segments, example emails, the marker, dated/archived records (paths only) and untracked files pass"
assert_not_contains "$_out" "fine.md" "leak-scan: src/fine.md has no finding"
assert_not_contains "$_out" "untracked.md" "leak-scan: an untracked file is not scanned"
_rc=0
_out=$("$BASH_BIN" "$_LEAK" "$SUITE_TMP" 2>&1) || _rc=$?
assert_eq "2" "$_rc" "leak-scan: not a git work tree: exit 2"
_rc=0
_out=$("$BASH_BIN" "$_LEAK" "$REPO_ROOT" 2>&1) || _rc=$?
_msg="leak-scan: this checkout's tracked files have no finding"
[ "$_rc" = 0 ] || _msg="$_msg — $(tail -n 12 <<<"$_out" | tr '\n' ' ')"
assert_eq "0" "$_rc" "$_msg"

print_summary

# Spec Status Transition Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `spec-inject`'s unconditional spec `Status` writes with a single canonical, guarded, scope-aware transition model that every action cites, closing [issue #12](https://github.com/woodrowpearson/doc-superpowers/issues/12).

**Architecture:** Add one authoritative "Spec Status Model" section to `references/spec-lifecycle-actions.md` defining vocabulary (ladder vs. open-world exempt), four transition rules, spec roles (target vs. constraint), and evaluation order. Rewrite the six call sites that currently restate transition rules so they cite the model instead. Pin the result with a new shell regression suite that asserts the guarded language is present and the unconditional phrasing is gone — the defect recurred across two releases because nothing guarded the template text.

**Tech Stack:** Markdown reference files, `bash` test suite using the repo's existing `scripts/test-helpers.sh` harness, `jq` for `evals/evals.json`, `scripts/doc-tools.sh` for version and index management.

## Global Constraints

- **Design doc:** `docs/superpowers/specs/2026-07-24-spec-status-transition-model-design.md` — the authority for all wording decisions in this plan.
- **No changes to `scripts/doc-tools.sh` logic.** Spec `Status` is a Markdown header field; the shell tooling tracks the separate `.doc-index.json` `status` enum (`current`/`stale`/`deprecated`), which is unrelated and already correct. The only `doc-tools.sh` interaction is invoking `bump-version`, `add-entry`, and `update-index` as a consumer.
- **Backward compatibility is required.** Unsuffixed `--specs` paths must remain valid. The `:target` / `:constraint` suffix is optional.
- **Exempt statuses are open-world.** Always phrase the exempt class as "any status not listed in the ladder", never as a closed enumeration. An enumerated list lets a future status fall back to the unconditional write, reproducing this exact defect.
- **Target version:** `2.13.0` (MINOR — `--specs` gains optional syntax, spec vocabulary gains two values; both additive).
- **Em-dashes:** the reference files use `—` (U+2014). Rule headings in the model are written `R1 — Read before write` etc. and the test suite matches them literally, so keep the character exact.
- **Commit trailer:** every commit ends with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/test-spec-status-model.sh` | Create | Prose-consistency regression suite: asserts the model exists, the guarded language is present at every call site, and the unconditional phrasing is absent |
| `references/spec-lifecycle-actions.md` | Modify | Canonical model section (new) + five call sites rewritten to cite it |
| `references/agent-prompt-template.md` | Modify | Sixth call site — Spec-Aware Review table stops flagging deliberately-unadvanced specs as P1 |
| `docs/codebase-guide.md` | Modify | Four lines restating the old ladder, one of which contradicts the revised `spec-verify` check |
| `references/doc-spec.md` | Modify | Spec template `Status` vocabulary gains `Active` and `Deprecated`, plus a pointer note |
| `references/spec-lifecycle-protocol.md` | Modify | Wrapper-author `--specs` contract documents the role suffix; output section states constraint specs are never written |
| `evals/evals.json` | Modify | Eval 10's assertion currently asserts the bug — rewrite it; add a new eval reproducing issue #12 |
| `RELEASE-NOTES.md` | Modify | v2.13.0 entry (hand-authored — `bump-version` does not touch this file) |
| `package.json`, `claude-code.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `gemini-extension.json` | Modify | Version manifests, all rewritten by `doc-tools.sh bump-version` |
| `CLAUDE.md` | Modify | Directory structure + Key Files table gain the new test script |
| `docs/.doc-index.json` | Modify | Index entries for the new design doc and this plan |

---

### Task 1: Regression test harness + canonical Spec Status Model section

**Files:**
- Create: `scripts/test-spec-status-model.sh`
- Modify: `references/spec-lifecycle-actions.md` (insert new section after line 5)

**Interfaces:**
- Consumes: `scripts/test-helpers.sh` — provides `assert_contains`, `assert_not_contains`, `print_summary`, and the `PASS`/`FAIL`/`TESTS_RUN` counters. Note `setup()`/`teardown()` are NOT used by this suite; it reads repo files in place and needs no temp git repo.
- Produces: the `## Spec Status Model` section, cited by name from every call site rewritten in Tasks 2–4. The exact anchor text later tasks depend on is `**Spec Status Model**` (bolded, in prose) and the rule labels `R1`–`R4`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-spec-status-model.sh`:

```bash
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

print_summary
```

Make it executable:

```bash
chmod +x scripts/test-spec-status-model.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-spec-status-model.sh`
Expected: FAIL — 8 failures, all reporting "expected to contain". Exit code 1.

- [ ] **Step 3: Write the canonical section**

In `references/spec-lifecycle-actions.md`, the file currently opens with a 3-line intro paragraph followed by `---` on line 5. Insert the following **immediately after that `---`**, so the model precedes the `spec-generate` section:

````markdown

## Spec Status Model — Canonical Transition Rules

**Every action in this file MUST follow this model. Do not restate these rules elsewhere — cite this section.**

### Vocabulary

| Class | Statuses | Automation behaviour |
|---|---|---|
| **Ladder** | `Draft` → `In Review` → `Approved` → `Implemented` | Participate in automated transitions |
| **Exempt** | `Active`, `Deprecated`, `Superseded`, **and any status not listed in the ladder** | Never transitioned by any action |

The exempt class is open-world. A spec carrying an unrecognized status is exempt — leave it alone. Do not treat it as a data-entry error to be corrected, and do not extend automation by enumerating exempt values.

### Rules

- **R1 — Read before write.** Parse the spec's current `Status` before assigning any value. Never write `Status` without having read it first.
- **R2 — Monotonic.** Transitions move forward along the ladder only. Never write a status earlier in the ladder than the current value. A regression is always a defect, never an intended outcome.
- **R3 — Open-world exemption.** If the current `Status` is not a ladder value, make no transition, add no Implementation Notes, and make no `code_refs` write. Leave the spec untouched.
- **R4 — Scope-gated advancement.** Advance a spec to `Implemented` only when this work implemented the spec's surface **and** that surface is fully covered.

`Approved` needs no special-casing: it sits past `In Review` on the ladder, so R2 alone prevents a `Draft → In Review` step from regressing it.

### Spec roles — implementation target vs. constraint reference

A path passed via `--specs` is one of:

- **target** — the work is expected to implement this spec's surface and advance its status.
- **constraint** — the work must respect this spec (e.g. a field allowlist it must not violate) but must **not** advance it.

Resolution, in precedence order:

1. **Explicit marker.** `--specs=<path>:target` or `--specs=<path>:constraint`. An explicit marker always wins. The suffix is optional — unsuffixed paths remain valid.
   ```
   --specs=docs/specs/SPEC-UI-010-collection-view.md:target,docs/specs/SPEC-API-006-backend.md:constraint
   ```
2. **Inferred.** For an unsuffixed path, intersect the work's changed files (`git diff` against the branch base) with the spec's `code_refs` in `.doc-index.json`. Non-empty intersection → **target**. Empty intersection → **constraint**.

A spec resolved as **constraint** is never written: no `Status` change, no Implementation Notes, no `code_refs` refinement, no `update-index` call.

**Timing.** Role inference needs the changed-file set, which does not exist during `spec-inject --phase=plan` — nothing is implemented yet at plan-authoring time. So at injection time the explicit marker is the only role signal available, and injected tasks are written as instructions the executing agent evaluates against `git diff` **at execution time**. `spec-inject --phase=plan` never bakes a role decision into the plan text.

### Coverage completeness

For a **target** spec, classify how much of its surface this work implemented:

- **Full** — the whole surface is implemented → eligible for `Implemented`, subject to R2.
- **Partial** — the spec has surfaces this work deliberately deferred → leave at `In Review` and record the remaining scope in Implementation Notes.

### Evaluation order

Check in this order; the first rule that blocks a write wins:

1. **Role** — resolved as constraint → stop, write nothing.
2. **R3** — current status is exempt → stop, write nothing.
3. **R4** — scope and coverage determine the target status.
4. **R2** — target status is earlier on the ladder than the current status → stop, write nothing.
5. Write.

A constraint spec at `Draft` is left alone by step 1; a target spec at `Active` is left alone by step 2. Neither reaches R4.

---
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-spec-status-model.sh`
Expected: PASS — `Results: 8 passed, 0 failed, 8 total`. Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/test-spec-status-model.sh references/spec-lifecycle-actions.md
git commit -m "$(cat <<'EOF'
feat(specs): add canonical Spec Status Model with open-world exemption

Defines the ladder (Draft -> In Review -> Approved -> Implemented), the
open-world exempt class, four transition rules (read-before-write,
monotonic, exempt, scope-gated), target/constraint spec roles with
code_refs inference, and a fixed rule evaluation order.

Adds scripts/test-spec-status-model.sh to pin the wording. Issue #12's
defect recurred across two releases because nothing asserted the
template text.

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Rewrite `spec-inject` plan-phase templates

**Files:**
- Modify: `references/spec-lifecycle-actions.md` (the `### Plan Phase` section — `--specs` input line, per-chunk template, finalize template)
- Modify: `scripts/test-spec-status-model.sh` (append a test block)

**Interfaces:**
- Consumes: the `## Spec Status Model` section and rule labels `R1`–`R4` from Task 1.
- Produces: the two rewritten injected-task templates. Task 5's new eval asserts against this wording, specifically the step headings `Update spec status (guarded)` and `Advance implemented specs (scope-gated)`.

**Context.** These are the two lines issue #12 reports. Current text (post-Task-1 the line numbers shift; locate by content, not number):

- Per-chunk: `` Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`. `` — unconditional, no status read. Applied to an `Implemented` spec it regresses it.
- Finalize: `` **Step 1: Set all specs to Implemented** `` / `` Update every governing spec's `Status` to `Implemented`. `` — no scope check. Marks constraint-only specs as implemented.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-spec-status-model.sh`, **before** the final `print_summary` line:

```bash
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
```

The R2-guard needle is the important one. Without it the partial-coverage branch reads as "write `In Review`", which drives issue #12's own headline spec (`SPEC-UI-032`, at `Implemented`, only partially covered because the plan just added regression guards around it) backward — reproducing failure mode 1 through the finalize door.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-spec-status-model.sh`
Expected: FAIL — 8 new failures (3 `expected NOT to contain`, 5 `expected to contain`). Task 1's 8 assertions still pass.

- [ ] **Step 3: Rewrite the three plan-phase sites**

**3a — `--specs` input line.** Replace:

```markdown
- `--specs=<paths>` — Comma-separated paths to governing specs (output of `spec-generate`)
```

with:

```markdown
- `--specs=<paths>` — Comma-separated paths to governing specs (output of `spec-generate`). Each path may carry an optional role suffix — `<path>:target` or `<path>:constraint` — declaring whether the work is expected to advance that spec. Unsuffixed paths are resolved by inference at execution time. See **Spec Status Model → Spec roles**.
```

**3b — per-chunk template.** Replace these two lines inside the fenced injected-task block:

```markdown
   - [ ] **Step 1: Update spec status**
   Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`.
```

with:

```markdown
   - [ ] **Step 1: Update spec status (guarded)**
   Read SPEC-{CAT}-NNN's current `Status` first, then apply the **Spec Status Model**:
     - Resolved as **constraint** for this work (resolve role per **Spec Status Model → Spec roles**) → leave untouched, and skip Steps 2–4 as well.
     - `Draft` → set `In Review`.
     - `In Review` / `Approved` / `Implemented` → leave unchanged (R2 — never regress).
     - Any other status (`Active`, `Deprecated`, `Superseded`, …) → leave unchanged (R3).
```

**3c — finalize template.** Replace the whole fenced finalization block's three steps:

```markdown
   - [ ] **Step 1: Set all specs to Implemented**
   Update every governing spec's `Status` to `Implemented`.
   - [ ] **Step 2: Fill Implementation Notes**
   For each spec, ensure the Implementation Notes section has actual file paths, decisions made, and any deviations from the original design.
   - [ ] **Step 3: Final index update**
   Run `doc-tools.sh update-index` for all governing specs.
```

with:

```markdown
   - [ ] **Step 1: Advance implemented specs (scope-gated)**
   For each governing spec, resolve its role, then apply the **Spec Status Model**. Resolve role from the caller's explicit `:target` / `:constraint` marker if present; otherwise intersect this plan's changed files (`git diff` against the branch base) with the spec's `code_refs`.
     - **constraint** (marked `:constraint`, or no intersection with `code_refs`) → leave `Status` unchanged and add no Implementation Notes. It was passed as a read-only reference, not an implementation target.
     - **target** at an exempt status (`Active`, `Deprecated`, `Superseded`, …) → leave unchanged (R3). `Active` reference specs sit outside the ladder and never transition.
     - **target**, fully covered by this plan → set `Implemented`.
     - **target**, partially covered (the spec has surfaces this plan deferred) → do **not** advance to `Implemented`. Never write a status earlier than the current value (R2): if the spec is at `Draft` or `In Review`, hold it at `In Review`; if it is already at `Approved` or `Implemented`, leave it exactly as it is. Record the remaining scope in Implementation Notes either way.
   - [ ] **Step 2: Fill Implementation Notes**
   For each spec Step 1 advanced or left at `In Review`, ensure the Implementation Notes section has actual file paths, decisions made, and any deviations from the original design. Skip specs Step 1 left untouched.
   - [ ] **Step 3: Final index update**
   Run `doc-tools.sh update-index` for each spec modified in Steps 1–2. Do not re-index untouched specs.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-spec-status-model.sh`
Expected: PASS — `Results: 16 passed, 0 failed, 16 total`.

- [ ] **Step 5: Commit**

```bash
git add references/spec-lifecycle-actions.md scripts/test-spec-status-model.sh
git commit -m "$(cat <<'EOF'
fix(spec-inject): guard plan-phase status writes against regression

Per-chunk template now reads the spec's current Status before writing and
only advances Draft -> In Review, leaving In Review / Approved /
Implemented and all exempt statuses untouched. Fixes issue #12 failure
mode 1, where an Implemented spec was driven back to In Review.

Finalize template now resolves each spec's role and coverage instead of
setting every listed spec to Implemented. Constraint-only specs and
partially-covered specs are no longer falsely advanced. Fixes issue #12
failure mode 2, which also had the effect of making spec-verify's status
check vacuously pass.

Plan-phase --specs input documents the optional :target / :constraint
role suffix.

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Align `spec-inject` execute phase, `spec-verify`, and the review-agent template with the model

**Files:**
- Modify: `references/spec-lifecycle-actions.md` (Execute Phase steps 2 and 3; `spec-verify` Post-Execute steps 3 and 5)
- Modify: `references/agent-prompt-template.md` (Spec-Aware Review table)
- Modify: `scripts/test-spec-status-model.sh` (append a test block)

**Interfaces:**
- Consumes: the `## Spec Status Model` section from Task 1.
- Produces: no downstream dependency — this is the last edit to `spec-lifecycle-actions.md`.

**Context.** Five sites still restate or assume transition rules independently:

- Execute Phase step 2, "Aligned" branch: "Update the spec's `Status` field." — unqualified, no read, no exemption.
- Execute Phase step 3: a standalone ladder restatement that omits `Approved`. This is the line issue #12 cites as contradicting the plan-phase template.
- `spec-verify` Post-Execute step 3: "Are all governing specs in `Implemented` status?" — no role or exemption awareness.
- `spec-verify` Post-Execute step 5: PASS/FAIL criteria that depend on step 3's wording.
- **`references/agent-prompt-template.md:58-60`** — a sixth site, missed in the original survey. Marked **REQUIRED** for dispatched review agents at `skills/doc-superpowers/SKILL.md:40`, its Spec-Aware Review table independently restates spec `Status` semantics: "Spec has `Status: Draft` but code exists → Flag as P1". Before this change `spec-inject` drove everything to `Implemented`, so that rule rarely fired. After it, constraint references and exempt specs **deliberately** stay at `Draft`/`In Review` while code exists in their `code_refs` — so every audit and review pass would emit false P1 findings on exactly the specs this fix exists to protect.

**Also in this task — reporting, as distinct from writing.** Two of the new rules suppress a *write*; neither should suppress *visibility*:

- Role inference is circular. `code_refs` are best-effort (`spec-lifecycle-actions.md:49`) and get refined by the per-chunk Step 3, which the constraint branch skips. Wrong `code_refs` → inferred constraint → refinement never runs → `code_refs` stay wrong permanently, and a real target silently never advances. The same faulty inference then suppresses `spec-verify`'s check.
- The open-world exemption swallows typos. A spec at `Implemenetd` is exempt forever, invisible to automation *and* verification.

Both hazards are silent by construction — the precise harm issue #12 is about. `spec-verify` therefore gains two **non-blocking P3 informational** lines that never cause a FAIL.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-spec-status-model.sh`, before `print_summary`:

```bash
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

AGENTPROMPT="$(cat "$REPO_ROOT/references/agent-prompt-template.md")"
assert_contains "$AGENTPROMPT" "Exempt specs sit outside the ladder by design" \
  "review-agent template exempts non-ladder statuses from P1"
assert_not_contains "$AGENTPROMPT" 'Spec has `Status: Draft` but code exists' \
  "review-agent template no longer flags any Draft spec with code as P1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-spec-status-model.sh`
Expected: FAIL — 12 new failures. Tasks 1–2's 16 assertions still pass.

- [ ] **Step 3: Rewrite the five sites**

**3a — Execute Phase step 2, "Aligned" branch.** Replace:

```markdown
   - **Aligned** (implementation achieves spec intent): Update the spec's `Status` field. Update the spec's Implementation Notes to reflect actual approach taken. Refine `code_refs` if actual file paths differ from initial estimates. Call `doc-tools.sh update-index` to refresh hashes. No human intervention.
```

with:

```markdown
   - **Aligned** (implementation achieves spec intent): Update the spec's `Status` per the **Spec Status Model** — read the current status first, never regress, and leave exempt statuses and constraint specs untouched. Update the spec's Implementation Notes to reflect actual approach taken. Refine `code_refs` if actual file paths differ from initial estimates. Call `doc-tools.sh update-index` to refresh hashes. No human intervention.
```

**3b — Execute Phase step 3.** Replace:

```markdown
3. **Status transitions**: Draft → In Review (first implementation) → Implemented (verification passes).
```

with:

```markdown
3. **Status transitions**: governed by the **Spec Status Model** — `Draft` → `In Review` (first implementation) → `Approved` → `Implemented` (verification passes). Monotonic (R2); exempt statuses and constraint specs never transition (R3, roles). Never write `Status` without reading the current value first (R1). `Approved` is human-set — no action ever writes it; it appears on the ladder so R2 can protect specs that carry it.
```

**3c — `spec-verify` Post-Execute step 3.** Replace:

```markdown
3. **Status check** — Are all governing specs in `Implemented` status? Any still at `Draft` or `In Review` means implementation tasks were skipped or the plan didn't cover that spec's scope.
```

with:

```markdown
3. **Status check** — For each governing spec, resolve its role and status class per the **Spec Status Model**, then check only what applies:
   - **target** at a ladder status → expect `Implemented`. Still at `Draft`, `In Review`, or `Approved` means implementation tasks were skipped or the plan didn't cover that spec's scope — report which of the two it is.
   - **target** at an exempt status (`Active`, `Deprecated`, `Superseded`, …) → **not a finding**. `Active` reference specs are continuously evolving and never reach `Implemented` by design.
   - **constraint** → **not a finding** at any status. The work was never expected to advance it.

   Then emit two **P3 informational** lines. These are never findings and never cause a FAIL — they exist because the two suppressions above are otherwise silent in the failing direction:
   - **Inferred constraints** — list specs treated as constraint references *by inference* rather than by an explicit `:constraint` marker: "N spec(s) treated as constraint references by inference — pass `:constraint` to confirm, or fix their `code_refs` if they were meant to be implementation targets." Role inference is circular: wrong `code_refs` produce a constraint verdict, the constraint branch skips the `code_refs` refinement step, so the `code_refs` stay wrong and the spec silently never advances. Specs marked `:constraint` explicitly are not listed — the caller already said so.
   - **Unrecognized statuses** — list specs at an unrecognized status, i.e. one outside the documented vocabulary (a typo such as `Implemenetd`, or a value from a downstream vocabulary): "N spec(s) at an unrecognized status — automation will never transition these." R3 correctly declines to write them; reporting them is what keeps them from being invisible forever.
```

**3d — `spec-verify` Post-Execute step 5, PASS/FAIL.** Replace:

```markdown
   - **PASS:** All governing specs in `Implemented` status AND no unresolved deviations AND no "design intent without formal spec" findings AND CLAUDE.md and README.md are current
   - **FAIL:** Any spec not in `Implemented` status, OR any unresolved deviation, OR any "design intent without formal spec" finding, OR CLAUDE.md/README.md staleness detected
```

with:

```markdown
   - **PASS:** Every spec required to be `Implemented` by the Status check (step 3) is `Implemented` AND no unresolved deviations AND no "design intent without formal spec" findings AND CLAUDE.md and README.md are current
   - **FAIL:** Any spec required to be `Implemented` by the Status check (step 3) is not, OR any unresolved deviation, OR any "design intent without formal spec" finding, OR CLAUDE.md/README.md staleness detected

   Specs the Status check exempts — constraint references, and specs at `Active` / `Deprecated` / `Superseded` — never contribute to a FAIL verdict. Neither do the two P3 informational lines.
```

**3e — `references/agent-prompt-template.md`, Spec-Aware Review table.** Replace these two rows:

```markdown
| Spec has `Status: Draft` but code exists | Flag as P1 — spec wasn't updated during implementation |
| Spec has `Status: Implemented` but code diverged | Flag as P0 — spec claims implementation matches but code has changed |
```

with:

```markdown
| Spec at a ladder status (`Draft` / `In Review` / `Approved`) but code exists in its `code_refs` | Flag as P1 — spec wasn't updated during implementation |
| Spec has `Status: Implemented` but code diverged | Flag as P0 — spec claims implementation matches but code has changed |
| Spec at an exempt status (`Active`, `Deprecated`, `Superseded`, or any status not on the ladder) | **Not a finding.** Exempt specs sit outside the ladder by design — see **Spec Status Model** in `references/spec-lifecycle-actions.md` |
| Spec passed as a constraint reference (`:constraint`) for the work under review | **Not a finding** at any status. The work was never expected to advance it |
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-spec-status-model.sh`
Expected: PASS — `Results: 28 passed, 0 failed, 28 total`.

- [ ] **Step 5: Commit**

```bash
git add references/spec-lifecycle-actions.md references/agent-prompt-template.md scripts/test-spec-status-model.sh
git commit -m "$(cat <<'EOF'
fix(spec-verify): scope status check to specs the work was meant to advance

spec-verify's status check required every governing spec to reach
Implemented, which contradicted its own note that a plan may legitimately
not cover a listed spec's scope. It now exempts constraint references and
non-ladder statuses (Active / Deprecated / Superseded), and the PASS/FAIL
verdict follows.

Adds two P3 informational lines so the new suppressions stay visible:
specs treated as constraint by inference rather than an explicit marker,
and specs at unrecognized statuses. Neither can cause a FAIL.

spec-inject's execute phase now cites the Spec Status Model rather than
restating the ladder, and its ladder line gains Approved, which the spec
template has always allowed but no action modelled.

Also fixes a sixth call site missed in the original survey:
agent-prompt-template.md's Spec-Aware Review table flagged any Draft spec
with code as P1. After this change constraint and exempt specs stay at
Draft/In Review deliberately, so that rule would have emitted false P1
findings on exactly the specs the new model protects.

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Spec template vocabulary and wrapper-author contract

**Files:**
- Modify: `references/doc-spec.md` (spec template `Status` line + a pointer note after the template block)
- Modify: `references/spec-lifecycle-protocol.md` (`spec-inject` plan-phase and execute-phase `--specs` lines, plan-phase output line)
- Modify: `scripts/test-spec-status-model.sh` (append a test block)

**Interfaces:**
- Consumes: the `## Spec Status Model` section from Task 1 (referenced by name from both files).
- Produces: the sanctioned spec `Status` vocabulary. Task 5's new eval assumes `Active` is a legal spec status.

**Context.** `references/doc-spec.md` lists the spec template vocabulary as `Draft | In Review | Approved | Implemented | Superseded`. It has **no `Active`** — that value belongs to the *ADR* template further down the same file. Downstream projects nonetheless hold continuously-evolving reference specs at `Status: Active`, a value the template does not currently sanction. `Deprecated` is likewise absent from the spec template.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-spec-status-model.sh`, before `print_summary`. Note this block reads two additional files, so add the two `cat` lines directly above the assertions:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-spec-status-model.sh`
Expected: FAIL — 4 failures. The ADR-template assertion passes already (it is a guard against collateral damage, not a change). Tasks 1–3's 28 assertions still pass.

- [ ] **Step 3: Update both files**

**3a — `references/doc-spec.md`, spec template `Status` line.** Inside the ```` ```markdown ```` block under `## docs/specs/template.md`, replace:

```markdown
**Status**: Draft | In Review | Approved | Implemented | Superseded
```

with:

```markdown
**Status**: Draft | In Review | Approved | Implemented | Active | Deprecated | Superseded
```

Leave the ADR template's `**Status**: Proposed | Active | Superseded | Deprecated` line further down the file untouched.

**3b — `references/doc-spec.md`, pointer note.** Immediately after the spec template's closing ```` ``` ```` fence and before the following `---`, insert:

```markdown
`Draft`, `In Review`, `Approved`, and `Implemented` form the ladder that `spec-inject` and `spec-verify` transition automatically. `Active` (continuously-evolving reference specs), `Deprecated`, and `Superseded` sit outside that ladder and are never transitioned by automation. See **Spec Status Model** in `references/spec-lifecycle-actions.md`.
```

**3c — `references/spec-lifecycle-protocol.md`, plan-phase input.** Replace:

```markdown
- `--specs=<paths>` — Comma-separated paths to governing specs
```

with:

```markdown
- `--specs=<paths>` — Comma-separated paths to governing specs. Each path may carry an optional role suffix — `<path>:target` or `<path>:constraint` — declaring whether the work is expected to advance that spec. Unsuffixed paths are resolved by intersecting changed files with the spec's `code_refs` at execution time.
```

**3d — `references/spec-lifecycle-protocol.md`, plan-phase output.** Replace:

```markdown
**Output (plan phase):**
- Modified plan document with spec maintenance tasks appended to each chunk
```

with:

```markdown
**Output (plan phase):**
- Modified plan document with spec maintenance tasks appended to each chunk. Injected tasks are status-aware and scope-aware: they read a spec's current `Status` before writing and resolve target vs. constraint at execution time. Constraint specs are never written.
```

**3e — `references/spec-lifecycle-protocol.md`, execute-phase input.** The string `- \`--specs=<paths>\` — Paths to governing specs` appears **twice** in this file (the `spec-inject` execute-phase block and the `spec-verify` post-execute block), so match on the preceding heading line to disambiguate. Replace:

```markdown
**Input (execute phase):**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs
```

with:

```markdown
**Input (execute phase):**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs, each with an optional `:target` / `:constraint` role suffix
```

Leave the `spec-verify` block's identical line untouched — `spec-verify` reads roles but does not take them as new input syntax beyond what it inherits from the caller.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-spec-status-model.sh`
Expected: PASS — `Results: 33 passed, 0 failed, 33 total`.

- [ ] **Step 5: Commit**

```bash
git add references/doc-spec.md references/spec-lifecycle-protocol.md scripts/test-spec-status-model.sh
git commit -m "$(cat <<'EOF'
feat(specs): sanction Active and Deprecated in the spec template vocabulary

The spec template listed Draft | In Review | Approved | Implemented |
Superseded and had no Active at all — that value belonged only to the ADR
template. Downstream projects hold continuously-evolving reference specs
at Status: Active, a value the template did not sanction. Adds Active and
Deprecated, with a note on which statuses automation transitions.

Documents the --specs role suffix in the wrapper-author contract so
integrators can mark a spec read-only rather than relying on inference.

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Fix the bug-asserting eval and add the issue #12 reproduction

**Files:**
- Modify: `evals/evals.json` (eval id 10 `spec-inject-plan`; append a new eval)
- Modify: `scripts/test-spec-status-model.sh` (append a test block)

**Interfaces:**
- Consumes: the template wording produced in Task 2 — the new eval's assertions describe the guarded and scope-gated behaviour by name.
- Produces: no downstream dependency.

**Context.** `evals/evals.json` eval id 10 currently *encodes the defect*: its `injects-finalization-task` assertion reads "Last chunk includes a spec finalization task to set all specs to Implemented", and its `expected_output` says the same. An eval asserting the buggy behaviour is worse than no eval — it would mark a correct implementation as failing.

The file's shape is `{"skill_name": ..., "evals": [...]}`. Each eval has `id`, `name`, `prompt`, `expected_output`, `files`, `assertions[]`, where each assertion has `name`, `type`, `description`. Valid `type` values in use are `file_check`, `content_check`, and `tool_call_check`. There are 12 evals; the highest existing `id` is 12.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-spec-status-model.sh`, before `print_summary`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-spec-status-model.sh`
Expected: FAIL — 3 failures (the JSON-validity assertion passes; it guards the hand-edit in Step 3). Tasks 1–4's 33 assertions still pass.

- [ ] **Step 3: Update `evals/evals.json`**

**3a — Fix eval id 10.** Replace its `expected_output` value:

```
Should read the plan, identify chunk boundaries, append spec update tasks at the end of each chunk, add a spec finalization task in the last chunk. Should NOT modify the specs themselves (only the plan). Tasks should use checkbox syntax.
```

with:

```
Should read the plan, identify chunk boundaries, append spec update tasks at the end of each chunk, add a spec finalization task in the last chunk. Injected tasks must be status-aware: the per-chunk step reads the spec's current Status before writing and only advances Draft to In Review, and the finalization step resolves each spec's role and coverage rather than setting everything to Implemented. Should NOT modify the specs themselves (only the plan). Tasks should use checkbox syntax.
```

Then replace that eval's `injects-finalization-task` assertion `description`:

```
Last chunk includes a spec finalization task to set all specs to Implemented
```

with:

```
Last chunk includes a scope-gated spec finalization task that advances only specs this plan implemented, leaving constraint references and exempt statuses untouched
```

**3b — Fix eval 11, a seventh call site.** Eval id 11 (`spec-verify-post-execute`) restates the old status rule twice and now contradicts Task 3's revised check. Replace in its `expected_output`:

```
check Status fields (all should be Implemented)
```

with:

```
check Status fields per the Spec Status Model (target specs at a ladder status should be Implemented; constraint references and specs at exempt statuses such as Active are not findings)
```

and replace its `checks-status-fields` assertion `description`:

```
Verifies all governing specs have Status: Implemented
```

with:

```
Verifies Status only where the model requires it — target specs at a ladder status must be Implemented; constraint references and exempt statuses are not findings
```

**3c — Append the reproduction eval.** Add this object as the last element of the `evals` array:

```json
{
  "id": 13,
  "name": "spec-inject-plan-mixed-statuses",
  "prompt": "I'm about to write an implementation plan at docs/superpowers/plans/2026-07-24-collection-scope.md. Four specs govern it: docs/specs/SPEC-UI-032-collection-search.md is already Implemented (the plan only adds regression guards around it), docs/specs/SPEC-UI-010-collection-view.md is In Review and the plan touches one slice of it, docs/specs/SPEC-API-006-trusted-circle-backend.md is In Review and is a read-only backend constraint the plan makes zero functions/ changes against, and docs/specs/SPEC-ARCH-004-system-overview.md is Active as a continuously-evolving reference spec. Inject spec maintenance tasks. /doc-superpowers spec-inject --phase=plan --plan=docs/superpowers/plans/2026-07-24-collection-scope.md --specs=docs/specs/SPEC-UI-032-collection-search.md,docs/specs/SPEC-UI-010-collection-view.md,docs/specs/SPEC-API-006-trusted-circle-backend.md:constraint,docs/specs/SPEC-ARCH-004-system-overview.md",
  "expected_output": "Injected tasks must be guarded, not unconditional. The per-chunk status step must instruct the executing agent to read each spec's current Status first: advance only Draft to In Review, leave In Review / Approved / Implemented unchanged (never regress SPEC-UI-032 from Implemented back to In Review), and leave Active unchanged (SPEC-ARCH-004 sits outside the ladder). The finalization step must be scope-gated AND still R2-guarded: leave SPEC-API-006 untouched because it carries the :constraint marker, leave SPEC-ARCH-004 untouched because Active is exempt, leave SPEC-UI-032 at Implemented (it is a partially-covered target, and the partial branch must never write In Review over a later status), and for SPEC-UI-010 distinguish full from partial coverage rather than setting it to Implemented outright. Should NOT modify any spec file — only the plan.",
  "files": [],
  "assertions": [
    {
      "name": "per-chunk-step-reads-status-first",
      "type": "content_check",
      "description": "Injected per-chunk status step instructs reading the spec's current Status before writing, rather than an unconditional Draft to In Review assignment"
    },
    {
      "name": "never-regresses-implemented-spec",
      "type": "content_check",
      "description": "Injected tasks explicitly leave Implemented specs unchanged, so SPEC-UI-032 is not driven back to In Review"
    },
    {
      "name": "exempts-active-reference-spec",
      "type": "content_check",
      "description": "Injected tasks leave Active specs unchanged, so SPEC-ARCH-004 never enters the Draft to In Review to Implemented ladder"
    },
    {
      "name": "honors-constraint-role-marker",
      "type": "content_check",
      "description": "Injected finalization task leaves SPEC-API-006 untouched because it was passed with the :constraint role suffix"
    },
    {
      "name": "finalization-distinguishes-coverage",
      "type": "content_check",
      "description": "Injected finalization task distinguishes fully-covered specs (set Implemented) from partially-covered ones (hold, do not advance), and its partial branch never writes a status earlier than the current value"
    },
    {
      "name": "finalize-does-not-regress-implemented",
      "type": "content_check",
      "description": "Injected finalization task leaves SPEC-UI-032 at Implemented despite being only partially covered — the partial-coverage branch is R2-guarded, so failure mode 1 cannot recur through the finalize path"
    },
    {
      "name": "does-not-modify-specs",
      "type": "content_check",
      "description": "Only the plan document is modified; no spec file is written"
    }
  ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-spec-status-model.sh`
Expected: PASS — `Results: 37 passed, 0 failed, 37 total`.

Confirm the JSON parses and the array grew:

Run: `jq '.evals | length' evals/evals.json`
Expected: `13`

- [ ] **Step 5: Commit**

```bash
git add evals/evals.json scripts/test-spec-status-model.sh
git commit -m "$(cat <<'EOF'
test(evals): stop asserting the unconditional finalize behaviour

Eval 10's injects-finalization-task assertion read "set all specs to
Implemented" — it encoded the defect, so a correct implementation would
have failed it.

Adds eval 13 reproducing issue #12 directly: four governing specs at
Implemented / In Review / In Review-as-constraint / Active, asserting that
none is regressed, falsely advanced, or transitioned out of the exempt
class.

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Version bump, release notes, and project metadata

**Files:**
- Modify: `RELEASE-NOTES.md`, `package.json`, `claude-code.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `gemini-extension.json` (all via `doc-tools.sh bump-version`)
- Modify: `docs/codebase-guide.md` (four stale ladder references)
- Modify: `CLAUDE.md` (directory structure + Key Files table)
- Modify: `docs/.doc-index.json` (entries for the new design doc and plan)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: a releasable `2.13.0`.

- [ ] **Step 1: Run the full test suite to confirm nothing regressed**

**Prerequisite:** `test-doc-pr-release.sh` needs PyYAML for its 9 YAML-substitution assertions. Without it that suite reports `1 failed` with `ModuleNotFoundError: No module named 'yaml'` — a environment gap, not a regression from this work. Install it first so the gate is meaningful:

```bash
python3 -c "import yaml" 2>/dev/null || uv pip install --system pyyaml
```

```bash
for t in scripts/test-doc-tools.sh scripts/test-hooks.sh scripts/test-merge-driver.sh scripts/test-doc-pr-release.sh scripts/test-spec-status-model.sh; do
  echo "### $t"
  bash "$t" 2>&1 | tail -4
done
```

Expected: every suite ends `0 failed`. `test-spec-status-model.sh` reports `37 passed, 0 failed, 37 total`. If PyYAML could not be installed, `test-doc-pr-release.sh` will report `1 failed` on the YAML assertions only — confirm the failure text is the `ModuleNotFoundError` and no other assertion failed, then proceed.

- [ ] **Step 2: Grep sweep for surviving unconditional phrasing**

Scope matters. `docs/codebase-guide.md` must be swept (Step 3 fixes it), but `docs/superpowers/` must **not** be — this plan and its design doc quote the defective text verbatim in order to describe it, and so do shipped historical plans. Sweeping them would direct you to edit your own plan.

```bash
rg -n 'Status` (from|to) `' references/ skills/ evals/ docs/codebase-guide.md
rg -n "every governing spec|all specs to Implemented|Set all specs|all should be Implemented" references/ skills/ evals/ docs/codebase-guide.md
```

Expected: no output from either command. Any hit is unconditional status-write phrasing that Tasks 2–5 missed — fix it before continuing.

- [ ] **Step 3: Update `docs/codebase-guide.md`**

Four lines restate the old ladder. `:321` directly contradicts the revised `spec-verify` status check, and `:162` already misattributes status transitions to `SKILL.md`, which contains none.

| Line | Replace | With |
|---|---|---|
| `:162` | `| Spec status transitions | `skills/doc-superpowers/SKILL.md` `spec-inject` and `spec-verify` subsections (Draft -> In Review -> Implemented) |` | `| Spec status transitions | `references/spec-lifecycle-actions.md` **Spec Status Model** section — canonical ladder, exemptions, and roles |` |
| `:313` | `  → Updates spec Status: Draft → In Review` | `  → Updates spec Status per the Spec Status Model (guarded: Draft → In Review only, never regresses)` |
| `:321` | `  → Existence check, staleness check, status check (all should be Implemented)` | `  → Existence check, staleness check, status check (target specs at a ladder status should be Implemented; constraint refs and exempt statuses are not findings)` |
| `:324` | `  → Status transition: In Review → Implemented (if aligned)` | `  → Status transition: In Review → Implemented (if aligned, and only for scope-covered target specs)` |

Verify afterwards:

```bash
rg -n "all should be Implemented|Draft -> In Review -> Implemented" docs/codebase-guide.md
```

Expected: no output.

- [ ] **Step 4: Write the release notes entry**

**Order matters here.** `doc-tools.sh check-version` derives the *canonical* version by grepping the first `## vX.Y.Z` heading out of `RELEASE-NOTES.md` (`scripts/doc-tools.sh:949`), and `bump-version` does **not** touch `RELEASE-NOTES.md` — its `VERSION_FILES` array (`scripts/doc-tools.sh:896`) covers only the six JSON manifests. So the release-notes heading must be authored **by hand, before** the bump; running `check-version` first would compare six manifests at `2.13.0` against a canonical `2.12.3` and exit 1.

Insert this immediately below the `# Release Notes` heading, above the existing `## v2.12.3` entry:

```markdown
## v2.13.0 (2026-07-24)

Replaces `spec-inject`'s unconditional spec `Status` writes with a canonical, guarded, scope-aware transition model that every spec action cites. Adds an optional `:target` / `:constraint` role suffix to `--specs`, and sanctions `Active` and `Deprecated` in the spec template vocabulary. Backward compatible — unsuffixed `--specs` paths keep working.

### Fixes
- **`spec-inject --phase=plan` wrote spec `Status` unconditionally, regressing `Implemented` specs and falsely advancing untouched ones** (`references/spec-lifecycle-actions.md`) — The per-chunk injected task said "Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`" with no read of the current status, so applying it to a spec already at `Implemented` drove it backward, falsely signalling that shipped, verified behaviour was unproven. The finalize task said "Update every governing spec's `Status` to `Implemented`" with no check that the plan touched that spec's surface, so a spec passed as a read-only constraint reference — a backend field allowlist the client work must respect but not implement — was marked `Implemented`, asserting work that was never written. Both failures were silent. Both contradicted contracts stated elsewhere in the same file: the execute phase asserts a monotonic ladder, and `spec-verify` explicitly treats "the plan didn't cover that spec's scope" as a legitimate reason a spec is not `Implemented` — a check the finalize step made vacuously pass by running before it. Root cause was structural: transition rules were restated independently at six call sites — four in `spec-lifecycle-actions.md`, one assumed by `spec-verify`, and one in `references/agent-prompt-template.md`, which is marked REQUIRED for dispatched review agents — and had drifted apart. Fix: a single canonical **Spec Status Model** section defines the ladder (`Draft` → `In Review` → `Approved` → `Implemented`), an **open-world** exempt class (`Active`, `Deprecated`, `Superseded`, and any status not on the ladder), four rules (read-before-write, monotonic, exempt, scope-gated), target vs. constraint spec roles, and a fixed evaluation order; all six call sites now cite it instead of restating it. `spec-verify` also gains two non-blocking P3 informational lines — specs treated as constraint by *inference* rather than an explicit marker, and specs at unrecognized statuses — so the new write-suppressions do not become new silences. The exemption is deliberately open-world so a status added later cannot fall back to the unconditional write. Failure mode 1 had been independently observed twice, ~2 months apart, at v2.12.0 and v2.12.3; the documented downstream workaround was to skip `spec-inject --phase=plan` entirely on mature specs. New suite `scripts/test-spec-status-model.sh` (37 assertions) pins the wording so the phrasing cannot silently return. Closes #12.
- **`evals/evals.json` asserted the defect** (`evals/evals.json`) — Eval 10's `injects-finalization-task` assertion read "Last chunk includes a spec finalization task to set all specs to Implemented", so a correct implementation would have failed it. Rewritten to describe scope-gated finalization. New eval 13 (`spec-inject-plan-mixed-statuses`) reproduces issue #12 directly with four governing specs at `Implemented` / `In Review` / `In Review`-as-constraint / `Active`.

### Features
- **Optional `:target` / `:constraint` role suffix on `--specs`** (`references/spec-lifecycle-actions.md`, `references/spec-lifecycle-protocol.md`) — Callers can now declare whether the work is expected to advance a given governing spec: `--specs=docs/specs/SPEC-UI-010-x.md:target,docs/specs/SPEC-API-006-y.md:constraint`. Constraint specs are never written — no `Status` change, no Implementation Notes, no `code_refs` refinement, no `update-index` call. Unsuffixed paths remain valid and are resolved by intersecting the work's changed files with the spec's `code_refs` at execution time, so no caller change is required; the marker is the escape hatch for when `code_refs` (documented as best-effort) are wrong.
- **`Active` and `Deprecated` sanctioned in the spec template vocabulary** (`references/doc-spec.md`) — The spec template listed `Draft | In Review | Approved | Implemented | Superseded` and contained no `Active` at all; that value belonged only to the ADR template in the same file. Downstream projects nonetheless hold continuously-evolving reference specs (system overviews, schema inventories, cost models) at `Status: Active`. Both values are now legal on specs and documented as outside the automated ladder. Separately, `Approved` — present in the template since inception but never mentioned by any action — is now modelled.
```

- [ ] **Step 5: Bump the version**

```bash
bash scripts/doc-tools.sh bump-version 2.13.0
bash scripts/doc-tools.sh check-version
```

Expected: `bump-version` rewrites the six JSON manifests; `check-version` then reports all files at `2.13.0` and exits 0.

Two things to know if it does not:
- **A mismatch against `2.12.3` means the Step 4 heading was not written.** `check-version` takes the first `## vX.Y.Z` in `RELEASE-NOTES.md` as canonical, so without the new heading it compares six manifests at `2.13.0` against `2.12.3`.
- **The manifests are already inconsistent before this task runs** — `package.json` and `.claude-plugin/plugin.json` are at `2.12.3` while `claude-code.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, and `gemini-extension.json` are still at `2.12.2`. The v2.12.3 release left them behind. `bump-version 2.13.0` writes all six, so this task repairs the drift as a side effect. Do not treat the pre-existing state as something this work broke.

- [ ] **Step 6: Update `CLAUDE.md`**

In the directory-structure code block, add beneath `test-hooks.sh`:

```
│   ├── test-spec-status-model.sh # Test suite for the canonical Spec Status Model + call sites
```

In the Key Files table, add a row after the `scripts/test-hooks.sh` row:

```markdown
| `scripts/test-spec-status-model.sh` | Test suite pinning the canonical Spec Status Model wording and its call sites | Changing spec status transition rules, roles, or vocabulary |
```

- [ ] **Step 7: Index the new docs**

```bash
printf '%s\n' \
  'docs/superpowers/specs/2026-07-24-spec-status-transition-model-design.md:references/,skills/:spec' \
  'docs/superpowers/plans/2026-07-24-spec-status-transition-model.md:references/,scripts/,evals/:plan' \
  | bash scripts/doc-tools.sh add-entry
jq -r '.docs | keys[] | select(contains("2026-07-24"))' docs/.doc-index.json
```

Expected: both new paths listed.

- [ ] **Step 8: Re-run the full suite and commit**

```bash
for t in scripts/test-doc-tools.sh scripts/test-hooks.sh scripts/test-merge-driver.sh scripts/test-doc-pr-release.sh scripts/test-spec-status-model.sh; do
  echo "### $t"; bash "$t" 2>&1 | tail -3
done
bash scripts/doc-tools.sh check-version
```

Expected: all suites `0 failed`; `check-version` clean.

```bash
git add -A
git commit -m "$(cat <<'EOF'
release: doc-superpowers v2.13.0 — guarded, scope-aware spec status transitions

Refs #12

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** Every design section maps to a task: model section A → Task 1; reporting-vs-writing B2 → Task 3; call-site rewrites B → Tasks 2 (plan phase) and 3 (execute phase + spec-verify + `agent-prompt-template.md`); supporting files C → Tasks 4 (`doc-spec.md`, `spec-lifecycle-protocol.md`), 5 (`evals.json`), and 6 step 3 (`codebase-guide.md`); verification D → Task 6 steps 1–2; version E → Task 6 steps 4–5. The design's non-goals are respected — no `doc-tools.sh` logic changes, no downstream changes.

**Placeholder scan.** Every edit step shows the exact before and after text. No "add appropriate X", no "similar to Task N", no TBDs.

**Consistency.** Assertion counts are cumulative and consistent across tasks: 8 → 16 → 28 → 33 → 37.

**Post-review revisions.** Two pre-execution review passes found and this plan now fixes: the finalize partial-coverage branch had no R2 guard, so it reproduced failure mode 1 on issue #12's own headline spec through the finalize door (Task 2); a sixth call site in `references/agent-prompt-template.md` was missed and would have emitted false P1 findings on exactly the specs the model protects (Task 3); `spec-verify` suppressed writes *and* reports, turning two loud failures into quiet ones (Task 3); Task 6 ran `check-version` before the `RELEASE-NOTES.md` heading it derives its canonical version from, and rested on a false claim that `bump-version` writes that heading — a deterministic hard failure (Task 6, now reordered); `docs/codebase-guide.md` restated the old ladder in four places, one contradicting the revised check (Task 6 step 3); one before-string was non-unique (Task 4); and one assertion misbehaved under `set -e` (Task 5). A second mechanical pass then found a *seventh* call site — `evals/evals.json` eval 11 asserts "all should be Implemented", contradicting the revised `spec-verify` check (Task 5) — and that Task 6's grep sweep was scoped to include `docs/superpowers/`, where this plan and its design doc quote the defective text deliberately, so the sweep would have directed the executor to edit its own plan (Task 6 step 2, now scoped to `references/ skills/ evals/ docs/codebase-guide.md`).

**Known-stale environment, called out rather than assumed away.** PyYAML is absent on this host, so `test-doc-pr-release.sh` reports one failure unrelated to this work; Task 6 step 1 installs it and tells the executor how to recognize the benign case. The six version manifests are *already* split between `2.12.3` and `2.12.2` before this work starts — leftover from the v2.12.3 release — so `check-version` fails today; Task 6 step 5 says so explicitly, since an executor seeing that failure would otherwise assume they caused it. The `## Spec Status Model` heading, the `R1`–`R4` labels, the step headings `Update spec status (guarded)` and `Advance implemented specs (scope-gated)`, and the `:target` / `:constraint` suffix are spelled identically everywhere they appear in the plan and in the test needles.

**Known brittleness, accepted.** The test suite matches literal prose, so reworded documentation will fail it. That is the intent — the defect recurred precisely because template text was unguarded — but a future editor who rewords deliberately must update the needles alongside. The suite's header comment says so.

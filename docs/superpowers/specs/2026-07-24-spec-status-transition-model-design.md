# Design: Guarded, Scope-Aware Spec Status Transitions

**Date:** 2026-07-24
**Status:** Approved
**Author:** woodrow pearson
**Issue:** [#12](https://github.com/woodrowpearson/doc-superpowers/issues/12)
**Target version:** 2.13.0

## Problem

The `spec-inject --phase=plan` injection templates in `references/spec-lifecycle-actions.md`
prescribe **unconditional** spec `Status` writes. Applied verbatim they corrupt governing
specs in two directions.

**Failure mode 1 — lifecycle regression** (`:100-101`). The per-chunk task says
"Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`" with no read of the current
status. Applied to a spec at `Implemented`, it regresses that spec to `In Review`, falsely
signalling that shipped behaviour is unverified. This contradicts the same file's
execute-phase contract at `:137`, which asserts a monotonic ladder.

**Failure mode 2 — false advancement** (`:116-117`). The finalize task says "Update every
governing spec's `Status` to `Implemented`" with no check that the plan implemented that
spec's surface. A spec passed as a read-only constraint reference — a spec the work must
respect but not advance — gets marked `Implemented`, asserting work that was never done.
This also contradicts the file's own `spec-verify` contract at `:155`, which treats "the
plan didn't cover that spec's scope" as a legitimate reason a spec is *not* `Implemented`.
Because finalize runs before `spec-verify`, the finalize step makes `spec-verify`'s status
check vacuously pass — a governance check defeated by the action preceding it.

Both failures are silent. Neither produces an error. Failure mode 1 has been independently
observed twice, ~2 months apart, at two plugin versions (v2.12.0 on 2026-05-26, v2.12.3 on
2026-07-24). The documented downstream workaround is to skip `spec-inject --phase=plan`
entirely when most governing specs are already mature — i.e. consumers route around the
action rather than use it.

### Root cause

Not the two lines. The root cause is that **the status-transition rules are restated
independently at each call site**, so the call sites drift apart and contradict each other.
`spec-lifecycle-actions.md` states transition rules in four places (`:100`, `:116`, `:135`,
`:137`) and `spec-verify` assumes a fifth (`:155`). Fixing only `:100-101` and `:116-117`
leaves that structure intact and invites recurrence.

### Taxonomy gap discovered during design

Wider than the issue reports:

- `references/doc-spec.md:188` lists the spec vocabulary as
  `Draft | In Review | Approved | Implemented | Superseded`. It contains **no `Active`** —
  `Active` belongs to the *ADR* template at `:224`. Downstream projects hold
  continuously-evolving reference specs at `Status: Active`, a value the spec template does
  not currently sanction.
- `Approved` appears in the spec template but is **never mentioned** anywhere in
  `spec-lifecycle-actions.md`. No action knows what to do with it.

## Design

### A. Canonical "Spec Status Model" section

A single authoritative block added near the top of `references/spec-lifecycle-actions.md`,
before the `spec-generate` section. Every action cites it rather than restating its rules.
This is the structural fix; the per-site rewrites in section B are its consequences.

**Vocabulary.**

| Class | Statuses | Automation behaviour |
|---|---|---|
| Ladder | `Draft` → `In Review` → `Approved` → `Implemented` | Participate in automated transitions |
| Exempt | `Active`, `Deprecated`, `Superseded`, **and any status not in the ladder** | Never transitioned by any action |

The exemption is stated open-world — "any status not in the ladder" — rather than as an
enumerated list. An enumerated list would let a future status silently fall back to the
unconditional write, reproducing this exact defect class.

**Rules.**

- **R1 — Read before write.** Parse the spec's current `Status` before assigning any value.
  No action may write `Status` without having read it first.
- **R2 — Monotonic.** Transitions move forward along the ladder only. Never write a status
  earlier in the ladder than the current value. Regression is always a defect.
- **R3 — Open-world exemption.** If the current `Status` is not a ladder value, make no
  transition, add no Implementation Notes, and make no `code_refs` write. Leave the spec
  untouched.
- **R4 — Scope-gated advancement.** Advance a spec to `Implemented` only when this work
  implemented the spec's surface **and** that surface is fully covered.

`Approved` requires no special handling: it sits past `In Review` on the ladder, so R2 alone
prevents the per-chunk step from regressing it. This is the concrete payoff of the
open-world rule over an enumerated exempt list.

**Evaluation order.** Rules are checked in a fixed order and the first one that blocks a
write wins: **role** (constraint → stop) → **R3** (exempt status → stop) → **R4** (scope and
coverage) → **R2** (monotonicity) → write. So a constraint spec at `Draft` is left alone
because of its role, and a target spec at `Active` is left alone because of R3 — neither
reaches R4.

**Spec roles.** A path passed via `--specs` is either an *implementation target* (the work
is expected to advance it) or a *constraint reference* (the work must respect it but must
not advance it). Resolution, in precedence order:

1. **Explicit marker.** `--specs=<path>[:target|:constraint]`. An explicit marker always
   wins. Backward compatible — unsuffixed paths remain valid.
2. **Inferred.** For an unsuffixed path, intersect the work's changed files (via `git diff`
   against the branch base) with the spec's `code_refs` from `.doc-index.json`. Non-empty
   intersection → target. Empty intersection → constraint.

A spec resolved as **constraint** is never written: no `Status` change, no Implementation
Notes, no `code_refs` refinement, no `update-index` call.

**Timing constraint (important).** Role inference requires the changed-file set, which does
not exist at plan-authoring time — nothing is implemented yet when `spec-inject --phase=plan`
runs. Therefore:

- At **injection** time, the explicit marker is the only role signal available.
- The injected finalize task is written as an instruction the **executing agent evaluates
  against `git diff` at execution time**, not as a decision `spec-inject` bakes into the
  plan text.

This matches how the existing templates already work (they instruct rather than decide), but
the model states it explicitly so implementers do not attempt inference during injection.

**Coverage completeness.** For a target spec, the executing agent classifies coverage:

- **Fully covered** — the plan implemented the spec's whole surface → set `Implemented`.
- **Partially covered** — the spec has surfaces this plan deliberately deferred → leave at
  `In Review` and record the remaining scope in Implementation Notes.

### B. Call sites rewritten to cite the model

| Location | Change |
|---|---|
| `spec-lifecycle-actions.md:90` (`--specs` input) | Document the `:target` / `:constraint` role suffix and the inference default |
| `:100-101` (per-chunk template) | Guarded, status-aware transition per R1–R3 |
| `:116-117` (finalize template) | Scope-and-coverage branch table per R3–R4 |
| `:135` (execute phase, aligned case) | Unqualified "Update the spec's `Status` field" → cite the model |
| `:137` (execute phase, ladder) | Replace the standalone ladder restatement with a pointer to the model; ladder gains `Approved` |
| `:155` (spec-verify status check) | Require `Implemented` only for fully-covered target specs; exempt statuses and constraint specs are not findings |
| `:169-170` (spec-verify PASS/FAIL) | Align verdict criteria with the revised status check |

### C. Supporting files

- **`references/doc-spec.md:188`** — add `Active` and `Deprecated` to the spec template's
  `Status` vocabulary, plus a one-line note stating which statuses automated transitions
  touch, pointing at the canonical model.
- **`references/spec-lifecycle-protocol.md:62,69,72`** — document the `--specs` role suffix
  in the wrapper-author contract; state in the output section that constraint specs are
  never written.
- **`evals/evals.json`** — eval 10 (`spec-inject-plan`) currently *asserts the bug*: its
  `injects-finalization-task` assertion reads "set all specs to Implemented". Rewrite that
  assertion and the `expected_output`. Add a new eval reproducing issue #12's scenario:
  governing specs at mixed statuses including one `Implemented` and one constraint-only
  spec the plan does not touch.

## Non-goals

- No changes to `scripts/doc-tools.sh`. Spec `Status` is a Markdown header field; the shell
  tooling tracks the separate `.doc-index.json` `status` enum
  (`current` / `stale` / `deprecated`), which is unrelated and already correct.
- No downstream changes. The companion `abundance-mvp` issue covering its `governing_specs:`
  frontmatter vocabulary is tracked separately. The explicit role marker designed here is
  the seam that downstream will consume; inference means downstream cooperation is an
  improvement, not a prerequisite.
- `spec-verify` is not given an `Active`-specific finding suppressor beyond the general
  exemption. The issue reports such a finding exists; no such logic was found in this repo,
  so it appears to live downstream. The exemption stated here is correct either way.

## Verification

No shell code changes, so correctness here is prose consistency, verified three ways:

1. **Existing suites stay green.** `scripts/test-doc-tools.sh`, `test-hooks.sh`,
   `test-merge-driver.sh`, `test-doc-pr-release.sh`.
2. **Grep sweep.** No unconditional status-write phrasing survives anywhere in
   `references/` — specifically no remaining instance of a `Status` assignment that is not
   preceded by a read or a citation of the model.
3. **Eval encodes the reproduction.** The new eval's assertions fail against the v2.12.3
   template text and pass against the revised text.

## Version

**2.13.0** (MINOR, not PATCH). `--specs` gains new optional syntax and the spec status
vocabulary gains two values. Both are additive and backward compatible, but "patch"
understates a documented-contract change.

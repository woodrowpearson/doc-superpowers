---
date: 2026-04-05
status: Open
priority: P2
type: enhancement
component: shared
source: manual
related-files:
  - .claude/plugins/cache/doc-superpowers/doc-superpowers/2.6.0/references/spec-lifecycle-actions.md
screenshots: null
axiom-agent: null
branch: feature/gemma4-on-device-detection
design-doc: docs/plans/2026-04-03-gemma-4-viability-report.md
report: null
---

## Summary

`spec-generate` should flag and pre-update existing specs whose content becomes stale when a design doc modifies their scope (extend/overlap cases), not just create new specs and handle direct supersession.

## Description

When running `spec-generate` on the Gemma-4 viability report, the action correctly:
- Created SPEC-PIPE-008 (new domain: Gemma-4 on-device detection)
- Superseded SPEC-PIPE-004 (EdgeTAM → Gemma-4 direct replacement)

But it missed **5 existing specs** (SPEC-PIPE-005, SPEC-PIPE-007, SPEC-UI-001, SPEC-UI-005, SPEC-UI-006) that contained **111 stale references** to sweep mode and EdgeTAM — architecture that the design doc explicitly removes. These specs weren't being *replaced* but their content was being *invalidated* by the design doc's changes.

The "Specs Requiring Updates" table was appended to the design doc, but no content changes were made to the specs themselves. The spec-inject plan phase deferred content updates to implementation chunks, meaning implementers would work against specs describing dead architecture.

### Impact

- 111 sweep/EdgeTAM references across 5 specs describing removed architecture
- SPEC-UI-005 had sweep as 1/3 of its entire content
- SPEC-PIPE-007 (Living Document, primary pipeline reference) described three-mode branching that no longer applies
- Required manual `spec-inject` → audit → update cycle to fix, adding ~30 minutes of doc work

### Root Cause

The `spec-generate` procedure (spec-lifecycle-actions.md, Step 5) only checks for three relationships:
1. **Replaces** → supersede + archive
2. **Extends** → create new spec with next sequential number
3. **Same scope, same intent** → flag for human review

Missing case:
4. **Design doc invalidates content in existing specs** → should flag with deprecation notices and optionally pre-apply them

### Affected Workflow

```
spec-generate → creates new specs, handles supersession
    ↓
spec-inject (plan phase) → lists "Specs Requiring Updates" but doesn't edit content
    ↓
spec-inject (execute phase) → updates specs AFTER each implementation chunk
    ↓
GAP: between spec-generate and first execute chunk, specs describe dead architecture
```

## Steps to Reproduce

1. Have a design doc that removes a major feature (sweep mode) affecting multiple existing specs
2. Run `spec-generate --design-doc=<path>`
3. Observe: new spec created, direct supersession handled, but 5 overlapping specs still describe removed feature
4. Run `spec-inject --phase=plan`: "Specs Requiring Updates" table added but no content changes

**Frequency:** always (structural gap in procedure)

## Expected Behavior

`spec-generate` should:

1. After creating new specs and handling supersession (Steps 5-8), run a **stale content scan** on all existing specs in the affected categories
2. For each existing spec, grep for key terms from the design doc's "What Gets Deleted" / removal sections
3. If stale references found, either:
   - **Auto-apply deprecation notices** (like the ones we manually added) with `> Deprecated (date): ... see [SPEC-NEW](...)`
   - Or at minimum: output a **P1 warning** listing the stale specs and reference counts, so the user can decide to update immediately rather than deferring to spec-inject execute phase

4. The "Specs Requiring Updates" table in the design doc should include a **stale reference count** column so the severity is visible

## Actual Behavior

`spec-generate` only handles create/supersede. Overlapping specs with invalidated content are listed in a table but not flagged with severity or edited.

## Technical Context

- doc-superpowers v2.6.0
- Procedure defined in: `references/spec-lifecycle-actions.md` (Steps 1-12)
- Gap is between Steps 5 (overlap check) and 8 (update indexes)
- The overlap check identifies extend/overlap but doesn't scan for stale content within those specs

## Proposed Solution

Add a **Step 5b** to `spec-generate` in `references/spec-lifecycle-actions.md`:

```markdown
### Step 5b: Stale content scan for overlapping specs

For specs identified as "extends" or "overlaps" in Step 5:

1. Extract removal/deprecation keywords from the design doc
   (section headings containing "Delete", "Remove", "Drop", component names listed for removal)
2. Grep each overlapping spec for those keywords
3. If >5 matches in a spec: flag as HIGH severity, recommend immediate deprecation notices
4. If 1-5 matches: flag as MEDIUM severity, note in "Specs Requiring Updates"
5. Offer: "N specs have stale content (M total references). Apply deprecation notices now?"
   - If yes: add `> Deprecated (date): ...` blockquotes to affected sections
   - If no: defer to spec-inject execute phase (current behavior)
```

This closes the gap between spec-generate and spec-inject execute phase without requiring a full spec rewrite.
